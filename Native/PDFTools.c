#include "Engine.h"
#include "MuPDFDocument.h"
#include <mupdf/pdf.h>
#include "pdf/pdf-annot-imp.h"
#include "html/html-imp.h"
#include <Security/Security.h>
#include <Security/CMSEncoder.h>
#include <Security/CMSDecoder.h>
#include <CommonCrypto/CommonDigest.h>
#include <openssl/cms.h>
#include <openssl/err.h>
#include <openssl/ts.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>

// Share the reader's CoreText locator instead of inventing a second font map.
void lf_install_system_fonts(fz_context *ctx);
static fz_context *new_pdf_context(void) {
    fz_context *ctx = lf_new_context(32 << 20);
    if (ctx) lf_install_system_fonts(ctx);
    return ctx;
}

// The Windows-specific signer in Sumatra PdfSign.cpp is replaced by the
// public macOS Security CMS encoder. MuPDF retains ownership of the PDF field,
// ByteRange reservation, incremental writer, and final signature insertion.
typedef struct {
    pdf_pkcs7_signer base;
    int refs;
    SecIdentityRef identity;
    CFArrayRef certificates;
    SecKeychainRef temporary_keychain;
    char *temporary_directory;
    size_t digest_capacity;
} AppleSigner;

static void security_error(fz_context *ctx, OSStatus status, const char *operation) {
    if (status == errSecSuccess) return;
    char message[300] = {0};
    CFStringRef reason = SecCopyErrorMessageString(status, NULL);
    if (reason) { CFStringGetCString(reason, message, sizeof(message), kCFStringEncodingUTF8); CFRelease(reason); }
    fz_throw(ctx, FZ_ERROR_GENERIC, "%s: %s (%d)", operation, message[0] ? message : "Security error", (int)status);
}
static pdf_pkcs7_signer *apple_keep(fz_context *ctx, pdf_pkcs7_signer *base) {
    AppleSigner *signer = (AppleSigner *)base;
    return fz_keep_imp(ctx, signer, &signer->refs);
}
static void apple_drop_keychain(fz_context *ctx, SecKeychainRef keychain, char *directory) {
    if (keychain) {
        OSStatus status = SecKeychainDelete(keychain);
        if (status != errSecSuccess) fz_warn(ctx, "Cannot delete temporary signing keychain (%d)", (int)status);
        CFRelease(keychain);
    }
    if (directory && rmdir(directory) && errno != ENOENT)
        fz_warn(ctx, "Cannot remove temporary signing directory: %s", strerror(errno));
    fz_free(ctx, directory);
}
static void apple_drop(fz_context *ctx, pdf_pkcs7_signer *base) {
    AppleSigner *signer = (AppleSigner *)base;
    if (fz_drop_imp(ctx, signer, &signer->refs)) {
        if (signer->identity) CFRelease(signer->identity);
        if (signer->certificates) CFRelease(signer->certificates);
        apple_drop_keychain(ctx, signer->temporary_keychain, signer->temporary_directory);
        fz_free(ctx, signer);
    }
}
static pdf_pkcs7_distinguished_name *apple_name(fz_context *ctx, pdf_pkcs7_signer *base) {
    AppleSigner *signer = (AppleSigner *)base;
    SecCertificateRef certificate = NULL; CFStringRef name = NULL;
    pdf_pkcs7_distinguished_name *dn = NULL;
    fz_var(certificate); fz_var(name); fz_var(dn);
    fz_try(ctx) {
        security_error(ctx, SecIdentityCopyCertificate(signer->identity, &certificate), "Read signing certificate");
        name = SecCertificateCopySubjectSummary(certificate);
        if (!name) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot read signing name");
        dn = fz_malloc_struct(ctx, pdf_pkcs7_distinguished_name);
        CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(name), kCFStringEncodingUTF8) + 1;
        dn->cn = fz_malloc(ctx, (size_t)capacity);
        if (!CFStringGetCString(name, dn->cn, capacity, kCFStringEncodingUTF8)) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot decode signing name");
    }
    fz_always(ctx) { if (name) CFRelease(name); if (certificate) CFRelease(certificate); }
    fz_catch(ctx) { pdf_signature_drop_distinguished_name(ctx, dn); fz_rethrow(ctx); }
    return dn;
}
static size_t apple_max_digest(fz_context *ctx, pdf_pkcs7_signer *base) {
    (void)ctx; return ((AppleSigner *)base)->digest_capacity;
}
static CMSEncoderRef apple_encoder(fz_context *ctx, AppleSigner *signer) {
    CMSEncoderRef encoder = NULL; fz_var(encoder);
    fz_try(ctx) {
        security_error(ctx, CMSEncoderCreate(&encoder), "Create CMS signer");
        security_error(ctx, CMSEncoderAddSigners(encoder, signer->identity), "Select signing identity");
        security_error(ctx, CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256), "Select SHA-256");
        security_error(ctx, CMSEncoderSetHasDetachedContent(encoder, true), "Set detached signature");
        // Both identity sources provide the selected signer's chain explicitly.
        security_error(ctx, CMSEncoderSetCertificateChainMode(encoder, kCMSCertificateSignerOnly), "Set certificate chain");
        if (CFArrayGetCount(signer->certificates)) security_error(ctx, CMSEncoderAddSupportingCerts(encoder, signer->certificates), "Add certificate chain");
        security_error(ctx, CMSEncoderAddSignedAttributes(encoder, kCMSAttrSigningTime), "Set signing time");
    }
    fz_catch(ctx) { if (encoder) CFRelease(encoder); fz_rethrow(ctx); }
    return encoder;
}
static int apple_digest(fz_context *ctx, pdf_pkcs7_signer *base, fz_stream *input, unsigned char *digest, size_t capacity) {
    CMSEncoderRef encoder = NULL; CFDataRef result = NULL; int length = 0;
    fz_var(encoder); fz_var(result); fz_var(length);
    fz_try(ctx) {
        encoder = apple_encoder(ctx, (AppleSigner *)base);
        unsigned char bytes[16384]; size_t count;
        while ((count = fz_read(ctx, input, bytes, sizeof(bytes)))) security_error(ctx, CMSEncoderUpdateContent(encoder, bytes, count), "Hash PDF byte ranges");
        security_error(ctx, CMSEncoderCopyEncodedContent(encoder, &result), "Sign PDF byte ranges");
        CFIndex size = CFDataGetLength(result);
        if (size <= 0 || (size_t)size > capacity || size > INT_MAX) fz_throw(ctx, FZ_ERROR_GENERIC, "CMS signature exceeds reserved space");
        memcpy(digest, CFDataGetBytePtr(result), (size_t)size); length = (int)size;
    }
    fz_always(ctx) { if (result) CFRelease(result); if (encoder) CFRelease(encoder); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return length;
}
static pdf_pkcs7_signer *apple_identity(fz_context *ctx, SecIdentityRef identity, CFArrayRef supplied_chain) {
    AppleSigner *signer = NULL; SecCertificateRef leaf = NULL; SecKeyRef key = NULL;
    SecPolicyRef policy = NULL; SecTrustRef trust = NULL; CFArrayRef chain = NULL;
    fz_var(signer); fz_var(leaf); fz_var(key); fz_var(policy); fz_var(trust); fz_var(chain);
    fz_try(ctx) {
        signer = fz_malloc_struct(ctx, AppleSigner); signer->refs = 1;
        signer->base.keep = apple_keep; signer->base.drop = apple_drop; signer->base.get_signing_name = apple_name;
        signer->base.max_digest_size = apple_max_digest; signer->base.create_digest = apple_digest;
        signer->identity = (SecIdentityRef)CFRetain(identity);
        security_error(ctx, SecIdentityCopyCertificate(identity, &leaf), "Read signing certificate");
        security_error(ctx, SecIdentityCopyPrivateKey(identity, &key), "Read signing key");
        if (supplied_chain) chain = CFRetain(supplied_chain);
        else {
            // Build only the selected identity's locally available chain.
            // Trust is reported separately; signing does not require a trusted CA.
            policy = SecPolicyCreateBasicX509();
            security_error(ctx, SecTrustCreateWithCertificates(leaf, policy, &trust), "Read signing certificate chain");
            security_error(ctx, SecTrustSetNetworkFetchAllowed(trust, false), "Use local signing certificate chain");
            (void)SecTrustEvaluateWithError(trust, NULL);
            chain = SecTrustCopyCertificateChain(trust);
        }
        signer->certificates = chain ? CFRetain(chain) : CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        if (!signer->certificates) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot prepare certificate chain");
        CFDataRef der = SecCertificateCopyData(leaf);
        if (!der) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot read signing certificate DER");
        size_t certificate_bytes = (size_t)CFDataGetLength(der); CFRelease(der);
        for (CFIndex i = 0; i < CFArrayGetCount(signer->certificates); ++i) {
            der = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(signer->certificates, i));
            if (!der) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot read certificate chain DER");
            certificate_bytes += (size_t)CFDataGetLength(der); CFRelease(der);
        }
        // SignedData includes certificates, issuer, key signature and attributes.
        signer->digest_capacity = 4096 + certificate_bytes * 2 + SecKeyGetBlockSize(key) * 2;
    }
    fz_always(ctx) {
        if (chain) CFRelease(chain); if (trust) CFRelease(trust); if (policy) CFRelease(policy);
        if (key) CFRelease(key); if (leaf) CFRelease(leaf);
    }
    fz_catch(ctx) { if (signer) apple_drop(ctx, &signer->base); fz_rethrow(ctx); }
    return &signer->base;
}
static pdf_pkcs7_signer *apple_import(fz_context *ctx, const char *path, const char *password) {
    pdf_pkcs7_signer *signer = NULL; fz_buffer *buffer = NULL;
    CFStringRef passphrase = NULL; CFDataRef data = NULL; CFArrayRef items = NULL;
    CFMutableDictionaryRef options = NULL; SecKeychainRef keychain = NULL;
    char *directory = NULL, *keychain_path = NULL;
    fz_var(signer); fz_var(buffer); fz_var(passphrase); fz_var(data); fz_var(items);
    fz_var(options); fz_var(keychain); fz_var(directory); fz_var(keychain_path);
    fz_try(ctx) {
        buffer = fz_read_file(ctx, path);
        unsigned char *bytes; size_t count = fz_buffer_storage(ctx, buffer, &bytes);
        data = CFDataCreateWithBytesNoCopy(NULL, bytes, (CFIndex)count, kCFAllocatorNull);
        passphrase = CFStringCreateWithCString(NULL, password, kCFStringEncodingUTF8);
        if (!data || !passphrase) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot prepare signing certificate");
        options = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (!options) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot prepare signing import options");
        CFDictionarySetValue(options, kSecImportExportPassphrase, passphrase);
        if (__builtin_available(macOS 15.0, *)) {
            CFDictionarySetValue(options, kSecImportToMemoryOnly, kCFBooleanTrue);
        } else {
            // Before macOS 15, a NULL SecItemImport keychain returns certificates
            // without private keys. Import only into this private, short-lived store.
            const char *temp = getenv("TMPDIR"); if (!temp || !*temp) temp = "/tmp";
            char *candidate = fz_asprintf(ctx, "%s/Sumra-sign.XXXXXX", temp);
            if (!mkdtemp(candidate)) {
                int error = errno; fz_free(ctx, candidate);
                fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot create temporary signing directory: %s", strerror(error));
            }
            directory = candidate;
            keychain_path = fz_asprintf(ctx, "%s/identity.keychain", directory);
            unsigned char random[32]; char secret[65]; arc4random_buf(random, sizeof(random));
            for (size_t i = 0; i < sizeof(random); ++i) snprintf(secret + i * 2, 3, "%02x", random[i]);
            OSStatus status = SecKeychainCreate(keychain_path, 64, secret, false, NULL, &keychain);
            memset_s(secret, sizeof(secret), 0, sizeof(secret)); memset_s(random, sizeof(random), 0, sizeof(random));
            security_error(ctx, status, "Create temporary signing keychain");
            CFDictionarySetValue(options, kSecImportExportKeychain, keychain);
        }
        security_error(ctx, SecPKCS12Import(data, options, &items), "Read PKCS#12 identity");
        SecIdentityRef identity = NULL; CFArrayRef certificates = NULL; int identities = 0;
        for (CFIndex i = 0; items && i < CFArrayGetCount(items); ++i) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
            SecIdentityRef found = (SecIdentityRef)CFDictionaryGetValue(item, kSecImportItemIdentity);
            if (found) {
                ++identities; identity = found;
                certificates = CFDictionaryGetValue(item, kSecImportItemCertChain);
            }
        }
        if (identities != 1) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Choose a PKCS#12 containing exactly one signing identity");
        signer = apple_identity(ctx, identity, certificates);
        ((AppleSigner *)signer)->temporary_keychain = keychain; keychain = NULL;
        ((AppleSigner *)signer)->temporary_directory = directory; directory = NULL;
    }
    fz_always(ctx) {
        if (items) CFRelease(items); if (options) CFRelease(options);
        if (passphrase) CFRelease(passphrase); if (data) CFRelease(data); fz_drop_buffer(ctx, buffer);
        apple_drop_keychain(ctx, keychain, directory); fz_free(ctx, keychain_path);
    }
    fz_catch(ctx) { pdf_drop_signer(ctx, signer); fz_rethrow(ctx); }
    return signer;
}
static pdf_document *open_pdf(fz_context *ctx, const char *path, const char *password, int owner_required) {
    pdf_document *doc = pdf_open_document(ctx, path);
    fz_try(ctx) {
        int access = pdf_authenticate_password(ctx, doc, password);
        if (!access || (owner_required && !(access & 5))) fz_throw(ctx, FZ_ERROR_ARGUMENT, (access & 2) ? "The PDF owner password is required for this operation" : "Incorrect PDF password");
    }
    fz_catch(ctx) { pdf_drop_document(ctx, doc); fz_rethrow(ctx); }
    return doc;
}

// Sumatra EngineCreate unwraps attached CMS content before passing it to the
// PDF engine. Security owns ASN.1/CMS parsing; unwrapping is not trust validation.
API int lf_pdf_unwrap(const char *source, const char *destination, char *error) {
    fz_context *ctx = new_pdf_context();
    if (!ctx) { snprintf(error, 512, "Cannot create PDF context"); return 0; }
    CMSDecoderRef decoder = NULL; CFDataRef content = NULL;
    fz_stream *input = NULL; fz_output *output = NULL; int ok = 0;
    fz_var(decoder); fz_var(content); fz_var(input); fz_var(output); fz_var(ok);
    fz_try(ctx) {
        security_error(ctx, CMSDecoderCreate(&decoder), "Create CMS decoder");
        input = fz_open_file(ctx, source);
        unsigned char bytes[16384]; size_t count;
        while ((count = fz_read(ctx, input, bytes, sizeof(bytes))))
            security_error(ctx, CMSDecoderUpdateMessage(decoder, bytes, count), "Read CMS envelope");
        security_error(ctx, CMSDecoderFinalizeMessage(decoder), "Decode CMS envelope");
        security_error(ctx, CMSDecoderCopyContent(decoder, &content), "Read attached PDF");
        if (!content || CFDataGetLength(content) <= 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This CMS envelope has no attached content");
        output = fz_new_output_with_path(ctx, destination, 0);
        fz_write_data(ctx, output, CFDataGetBytePtr(content), (size_t)CFDataGetLength(content));
        fz_close_output(ctx, output); ok = 1;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, output); fz_drop_stream(ctx, input);
        if (content) CFRelease(content); if (decoder) CFRelease(decoder);
    }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx); return ok;
}
// EngineMupdf::GetPropertyTemp/GetProperties, using the existing MuPDF parser.
// Output intents describe declarations in the file, not a conformance check.
API char *lf_pdf_information(const char *source, const char *password, char *error) {
    fz_context *ctx = new_pdf_context();
    if (!ctx) { snprintf(error, 512, "Cannot create PDF context"); return NULL; }
    pdf_document *doc = NULL; SumraJSON json = {0};
    fz_var(doc); fz_var(json);
    fz_try(ctx) {
        doc = open_pdf(ctx, source, password, 0);
        int version = pdf_version(ctx, doc), extension = 0;
        if (version == 17 && pdf_crypt_version(ctx, doc->crypt) == 5) {
            int revision = pdf_crypt_revision(ctx, doc->crypt);
            extension = revision == 5 ? 3 : revision == 6 ? 8 : 0;
        }
        char value[256];
        if (extension) snprintf(value, sizeof(value), "%d.%d Adobe Extension Level %d", version / 10, version % 10, extension);
        else snprintf(value, sizeof(value), "%d.%d", version / 10, version % 10);
        lf_json(&json, "{\"PDFVersion\":"); lf_json_string(&json, value);
        pdf_lookup_metadata(ctx, doc, FZ_META_ENCRYPTION, value, sizeof(value));
        lf_json(&json, ",\"Encryption\":"); lf_json_string(&json, value);
        lf_json(&json, ",\"Linearized\":"); lf_json_string(&json, pdf_doc_was_linearized(ctx, doc) ? "Yes" : "No");
        pdf_obj *root = pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Root));
        lf_json(&json, ",\"Tagged\":"); lf_json_string(&json, pdf_to_bool(ctx, pdf_dict_getp(ctx, root, "MarkInfo/Marked")) ? "Yes" : "No");
        pdf_obj *intents = pdf_dict_gets(ctx, root, "OutputIntents");
        int pdfx = 0, pdfa = 0, pdfe = 0;
        for (int index = 0; index < pdf_array_len(ctx, intents); ++index) {
            const char *name = pdf_dict_get_name(ctx, pdf_array_get(ctx, intents, index), PDF_NAME(S));
            if (!strcmp(name, "GTS_PDFX")) pdfx = 1;
            else if (!strcmp(name, "GTS_PDFA1")) pdfa = 1;
            else if (!strcmp(name, "GTS_PDFE1")) pdfe = 1;
        }
        snprintf(value, sizeof(value), "%s%s%s%s%s", pdfx ? "PDF/X (ISO 15930)" : "", pdfx && pdfa ? ", " : "", pdfa ? "PDF/A (ISO 19005)" : "", (pdfx || pdfa) && pdfe ? ", " : "", pdfe ? "PDF/E (ISO 24517)" : "");
        lf_json(&json, ",\"OutputIntents\":"); lf_json_string(&json, value);
        pdf_obj *xfa = pdf_dict_getp(ctx, root, "AcroForm/XFA");
        lf_json(&json, ",\"UnsupportedFeatures\":"); lf_json_string(&json, pdf_is_array(ctx, xfa) || pdf_is_stream(ctx, xfa) ? "XFA" : "");
        lf_json(&json, "}");
    }
    fz_always(ctx) { pdf_drop_document(ctx, doc); }
    fz_catch(ctx) { free(json.data); json.data = NULL; snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx); return json.data ? lf_json_finish(&json, error) : NULL;
}

// Translate Sumatra's signature-field report, keeping the cryptographic owner
// in MuPDF and replacing only its Windows verifier with public Security APIs.
typedef struct {
    pdf_pkcs7_verifier base;
    CMSDecoderRef decoder;
    CFArrayRef policies, timestamp_policies;
    int legacy_sha1;
    SumraJSON signers;
} AppleVerifier;

static void json_cf_string(SumraJSON *json, CFStringRef value) {
    if (!value) { lf_json(json, "null"); return; }
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), kCFStringEncodingUTF8) + 1;
    if (capacity <= 0) { json->failed = 1; return; }
    char *bytes = malloc((size_t)capacity);
    if (!bytes || !CFStringGetCString(value, bytes, capacity, kCFStringEncodingUTF8)) json->failed = 1;
    else lf_json_string(json, bytes);
    free(bytes);
}
static void json_status(SumraJSON *json, OSStatus status) {
    if (status == errSecSuccess || status == errSecSigningTimeMissing || status == errSecTimestampMissing || status == errSecItemNotFound) { lf_json(json, "null"); return; }
    CFStringRef description = SecCopyErrorMessageString(status, NULL);
    CFStringRef message = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ (%d)"),
        description ? description : CFSTR("Security error"), (int)status);
    json_cf_string(json, message);
    if (message) CFRelease(message); if (description) CFRelease(description);
}
static void json_signature_time(SumraJSON *json, CFAbsoluteTime time) {
    char number[64];
    if (!isfinite(time)) { lf_json(json, "null"); return; }
    snprintf(number, sizeof(number), "%.17g", time + kCFAbsoluteTimeIntervalSince1970);
    lf_json(json, number);
}
static void json_certificate_chain(fz_context *ctx, SumraJSON *json, CFArrayRef chain) {
    CFDataRef der = NULL; fz_buffer *base64 = NULL;
    fz_var(der); fz_var(base64);
    fz_try(ctx) {
        lf_json(json, "[");
        for (CFIndex n = 0; chain && n < CFArrayGetCount(chain); ++n) {
            der = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(chain, n));
            if (!der) fz_throw(ctx, FZ_ERROR_FORMAT, "Cannot read signing certificate DER");
            base64 = fz_new_buffer(ctx, 0);
            fz_append_base64(ctx, base64, CFDataGetBytePtr(der), (size_t)CFDataGetLength(der), 0);
            if (n) lf_json(json, ",");
            lf_json_string(json, fz_string_from_buffer(ctx, base64));
            fz_drop_buffer(ctx, base64); base64 = NULL;
            CFRelease(der); der = NULL;
        }
        lf_json(json, "]");
    }
    fz_always(ctx) { fz_drop_buffer(ctx, base64); if (der) CFRelease(der); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
static void json_certificate_qualification(SumraJSON *json, SecCertificateRef certificate) {
    const void *oid = kSecOIDQC_Statements;
    CFArrayRef keys = CFArrayCreate(NULL, &oid, 1, &kCFTypeArrayCallBacks);
    CFErrorRef error = NULL;
    CFDictionaryRef values = SecCertificateCopyValues(certificate, keys, &error);
    // Like Sumatra's cert_has_qc_statement, this reports the extension's
    // presence. It is not an eIDAS validation result or an added trust anchor.
    lf_json(json, ",\"qualifiedCertificate\":");
    lf_json(json, !values ? "null" : CFDictionaryContainsKey(values, oid) ? "true" : "false");
    lf_json(json, ",\"certificateMetadataError\":");
    CFStringRef message = error ? CFErrorCopyDescription(error) : NULL;
    json_cf_string(json, message);
    if (message) CFRelease(message); if (error) CFRelease(error);
    if (values) CFRelease(values); if (keys) CFRelease(keys);
}
static void json_oid(SumraJSON *json, const ASN1_OBJECT *oid, int names) {
    if (!oid) { lf_json(json, "null"); return; }
    int count = OBJ_obj2txt(NULL, 0, oid, !names);
    char *text = count > 0 ? malloc((size_t)count + 1) : NULL;
    if (!text) { json->failed = 1; return; }
    OBJ_obj2txt(text, count + 1, oid, !names); lf_json_string(json, text); free(text);
}
static void json_algorithm(SumraJSON *json, const X509_ALGOR *algorithm) {
    const ASN1_OBJECT *oid = NULL;
    if (algorithm) X509_ALGOR_get0(&oid, NULL, NULL, algorithm);
    json_oid(json, oid, 1);
}
static void json_digest(SumraJSON *json, const ASN1_OCTET_STRING *digest) {
    if (!digest) { lf_json(json, "null"); return; }
    const unsigned char *bytes = ASN1_STRING_get0_data(digest);
    int count = ASN1_STRING_length(digest);
    char *hex = malloc((size_t)count * 2 + 1);
    if (!hex) { json->failed = 1; return; }
    static const char digits[] = "0123456789abcdef";
    for (int i = 0; i < count; ++i) { hex[2*i] = digits[bytes[i] >> 4]; hex[2*i+1] = digits[bytes[i] & 15]; }
    hex[2*count] = 0; lf_json_string(json, hex); free(hex);
}
static TS_TST_INFO *cms_timestamp_info(CMS_ContentInfo *cms) {
    if (!cms || OBJ_obj2nid(CMS_get0_eContentType(cms)) != NID_id_smime_ct_TSTInfo) return NULL;
    ASN1_OCTET_STRING **content = CMS_get0_content(cms);
    if (!content || !*content) return NULL;
    const unsigned char *bytes = ASN1_STRING_get0_data(*content);
    return d2i_TS_TST_INFO(NULL, &bytes, ASN1_STRING_length(*content));
}
static void json_timestamp_info(SumraJSON *json, TS_TST_INFO *timestamp) {
    lf_json(json, ",\"policyOID\":"); json_oid(json, timestamp ? TS_TST_INFO_get_policy_id(timestamp) : NULL, 0);
    lf_json(json, ",\"generationTime\":");
    struct tm time = {0};
    if (timestamp && ASN1_TIME_to_tm((const ASN1_TIME *)TS_TST_INFO_get_time(timestamp), &time)) {
        char number[64]; snprintf(number, sizeof(number), "%lld", (long long)timegm(&time)); lf_json(json, number);
    } else lf_json(json, "null");
}
// Sumatra pkcs7-windows.c::pkcs7_windows_inspect uses CryptoAPI's decoded
// signer information. OpenSSL supplies that public CMS/TS parser on macOS;
// Security remains the sole signature and local certificate trust verifier.
static void json_cms_metadata(SumraJSON *json, CMS_ContentInfo *cms, SecCertificateRef certificate, size_t index, const char *parse_error) {
    CFDataRef der = SecCertificateCopyData(certificate);
    const unsigned char *bytes = der ? CFDataGetBytePtr(der) : NULL;
    X509 *cert = der ? d2i_X509(NULL, &bytes, CFDataGetLength(der)) : NULL;
    STACK_OF(CMS_SignerInfo) *signers = cms ? CMS_get0_SignerInfos(cms) : NULL;
    CMS_SignerInfo *signer = NULL;
    for (int i = 0; cert && i < sk_CMS_SignerInfo_num(signers); ++i) {
        CMS_SignerInfo *candidate = sk_CMS_SignerInfo_value(signers, i);
        if (!CMS_SignerInfo_cert_cmp(candidate, cert)) {
            signer = candidate;
            if ((size_t)i == index) break;
        }
    }
    X509_free(cert); if (der) CFRelease(der);
    lf_json(json, ",\"metadataError\":");
    if (!signer) { lf_json_string(json, parse_error[0] ? parse_error : "Cannot find CMS signer matching the signing certificate"); return; }
    lf_json(json, "null");
    X509_ALGOR *digest = NULL, *signature = NULL;
    CMS_SignerInfo_get0_algs(signer, NULL, NULL, &digest, &signature);
    lf_json(json, ",\"hashAlgorithm\":"); json_algorithm(json, digest);
    lf_json(json, ",\"signatureAlgorithm\":"); json_algorithm(json, signature);
    lf_json(json, ",\"documentHash\":");
    json_digest(json, CMS_signed_get0_data_by_OBJ(signer, OBJ_nid2obj(NID_pkcs9_messageDigest), -3, V_ASN1_OCTET_STRING));
    lf_json(json, ",\"cadesAttribute\":");
    lf_json(json, CMS_signed_get_attr_by_NID(signer, NID_id_smime_aa_signingCertificate, -1) >= 0 ||
        CMS_signed_get_attr_by_NID(signer, NID_id_smime_aa_signingCertificateV2, -1) >= 0 ? "true" : "false");
    lf_json(json, ",\"signaturePolicyAttribute\":");
    lf_json(json, CMS_signed_get_attr_by_NID(signer, NID_id_smime_aa_ets_sigPolicyId, -1) >= 0 ? "true" : "false");
    TS_TST_INFO *timestamp = cms_timestamp_info(cms);
    json_timestamp_info(json, timestamp); TS_TST_INFO_free(timestamp);
    lf_json(json, ",\"timestamps\":[");
    int emitted = 0;
    // The upstream inspector exposes at most eight included timestamp tokens.
    for (int i = 0; i < CMS_unsigned_get_attr_count(signer) && emitted < 8; ++i) {
        X509_ATTRIBUTE *attribute = CMS_unsigned_get_attr(signer, i);
        if (OBJ_obj2nid(X509_ATTRIBUTE_get0_object(attribute)) != NID_id_smime_aa_timeStampToken) continue;
        for (int n = 0; n < X509_ATTRIBUTE_count(attribute) && emitted < 8; ++n) {
            ASN1_TYPE *value = X509_ATTRIBUTE_get0_type(attribute, n);
            if (!value || value->type != V_ASN1_SEQUENCE) continue;
            bytes = ASN1_STRING_get0_data(value->value.sequence);
            CMS_ContentInfo *token = d2i_CMS_ContentInfo(NULL, &bytes, ASN1_STRING_length(value->value.sequence));
            timestamp = cms_timestamp_info(token);
            if (!timestamp) { CMS_ContentInfo_free(token); continue; }
            if (emitted++) lf_json(json, ",");
            STACK_OF(CMS_SignerInfo) *token_signers = CMS_get0_SignerInfos(token);
            X509_ALGOR *hash = NULL;
            if (sk_CMS_SignerInfo_num(token_signers) > 0) CMS_SignerInfo_get0_algs(sk_CMS_SignerInfo_value(token_signers, 0), NULL, NULL, &hash, NULL);
            lf_json(json, "{\"hashAlgorithm\":"); json_algorithm(json, hash);
            json_timestamp_info(json, timestamp);
            lf_json(json, "}");
            TS_TST_INFO_free(timestamp); CMS_ContentInfo_free(token);
        }
    }
    lf_json(json, "]");
    ERR_clear_error();
}
static void verifier_reset(AppleVerifier *verifier) {
    if (verifier->decoder) CFRelease(verifier->decoder);
    verifier->decoder = NULL;
    free(verifier->signers.data); memset(&verifier->signers, 0, sizeof(verifier->signers));
}
static void verifier_drop(fz_context *ctx, pdf_pkcs7_verifier *base) {
    AppleVerifier *verifier = (AppleVerifier *)base;
    verifier_reset(verifier);
    if (verifier->policies) CFRelease(verifier->policies);
    if (verifier->timestamp_policies) CFRelease(verifier->timestamp_policies);
    fz_free(ctx, verifier);
}
static CFArrayRef offline_policies(fz_context *ctx, SecPolicyRef purpose) {
    SecPolicyRef revocation = SecPolicyCreateRevocation(kSecRevocationUseAnyAvailableMethod | kSecRevocationNetworkAccessDisabled);
    CFArrayRef policies = NULL;
    if (purpose && revocation) {
        const void *values[] = {purpose, revocation};
        policies = CFArrayCreate(NULL, values, 2, &kCFTypeArrayCallBacks);
    }
    if (purpose) CFRelease(purpose); if (revocation) CFRelease(revocation);
    if (!policies) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot create local certificate trust policy");
    return policies;
}
static void verifier_decode(fz_context *ctx, AppleVerifier *verifier, unsigned char *signature, size_t length) {
    if (verifier->decoder) return;
    CMSDecoderRef decoder = NULL; fz_var(decoder);
    fz_try(ctx) {
        security_error(ctx, CMSDecoderCreate(&decoder), "Create CMS verifier");
        // The system decoder owns DER/BER parsing; no local ASN.1 parser.
        security_error(ctx, CMSDecoderUpdateMessage(decoder, signature, length), "Read PDF CMS signature");
        security_error(ctx, CMSDecoderFinalizeMessage(decoder), "Decode PDF CMS signature");
        verifier->decoder = decoder; decoder = NULL;
    }
    fz_always(ctx) { if (decoder) CFRelease(decoder); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
static pdf_signature_error verifier_digest(fz_context *ctx, pdf_pkcs7_verifier *base, fz_stream *input, unsigned char *signature, size_t length) {
    AppleVerifier *verifier = (AppleVerifier *)base;
    CFMutableDataRef content = NULL; CFDataRef attached = NULL; SecTrustRef trust = NULL;
    pdf_signature_error result = PDF_SIGNATURE_ERROR_OKAY;
    fz_var(content); fz_var(attached); fz_var(trust); fz_var(result);
    fz_try(ctx) {
        verifier_decode(ctx, verifier, signature, length);
        security_error(ctx, CMSDecoderCopyContent(verifier->decoder, &attached), "Read CMS signed content");
        content = CFDataCreateMutable(NULL, 0);
        if (!content) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot allocate CMS detached content");
        CC_SHA1_CTX sha1; if (verifier->legacy_sha1) CC_SHA1_Init(&sha1);
        unsigned char bytes[16384]; size_t count;
        while ((count = fz_read(ctx, input, bytes, sizeof(bytes)))) {
            if (verifier->legacy_sha1) CC_SHA1_Update(&sha1, bytes, (CC_LONG)count);
            else {
                CFDataAppendBytes(content, bytes, (CFIndex)count);
            }
        }
        if (verifier->legacy_sha1) {
            unsigned char digest[CC_SHA1_DIGEST_LENGTH]; CC_SHA1_Final(digest, &sha1);
            if (!attached || CFDataGetLength(attached) != sizeof(digest) ||
                memcmp(CFDataGetBytePtr(attached), digest, sizeof(digest))) result = PDF_SIGNATURE_ERROR_DIGEST_FAILURE;
        } else if (attached) {
            // An attached CMS payload could verify independently of the PDF.
            // Only legacy pkcs7.sha1 is allowed to embed a byte-range hash.
            result = PDF_SIGNATURE_ERROR_DIGEST_FAILURE;
        } else security_error(ctx, CMSDecoderSetDetachedContent(verifier->decoder, content), "Set PDF signature byte ranges");
        size_t signers = 0;
        security_error(ctx, CMSDecoderGetNumSigners(verifier->decoder, &signers), "Count CMS signers");
        if (!signers) result = PDF_SIGNATURE_ERROR_NO_SIGNATURES;
        for (size_t i = 0; i < signers; ++i) {
            CMSSignerStatus status = kCMSSignerUnsigned;
            security_error(ctx, CMSDecoderCopySignerStatus(verifier->decoder, i, verifier->policies, false, &status, &trust, NULL), "Verify CMS signature and content digest");
            if (status != kCMSSignerValid) result = PDF_SIGNATURE_ERROR_DIGEST_FAILURE;
            if (trust) CFRelease(trust); trust = NULL;
        }
    }
    fz_always(ctx) { if (trust) CFRelease(trust); if (attached) CFRelease(attached); if (content) CFRelease(content); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return result;
}
static pdf_signature_error verifier_certificate(fz_context *ctx, pdf_pkcs7_verifier *base, unsigned char *signature, size_t length) {
    AppleVerifier *verifier = (AppleVerifier *)base;
    CFArrayRef certificates = NULL, timestamp_certificates = NULL; CFMutableArrayRef chain = NULL;
    SecCertificateRef certificate = NULL; SecTrustRef trust = NULL; CFErrorRef trust_error = NULL;
    CFStringRef name = NULL, description = NULL;
    CMS_ContentInfo *cms = NULL;
    char metadata_error[256] = {0};
    pdf_signature_error result = PDF_SIGNATURE_ERROR_OKAY;
    fz_var(certificates); fz_var(timestamp_certificates); fz_var(chain); fz_var(certificate);
    fz_var(trust); fz_var(trust_error); fz_var(name); fz_var(description); fz_var(result);
    fz_var(cms);
    fz_try(ctx) {
        verifier_decode(ctx, verifier, signature, length);
        const unsigned char *encoded = signature;
        ERR_clear_error();
        if (length <= LONG_MAX) cms = d2i_CMS_ContentInfo(NULL, &encoded, (long)length);
        if (!cms) {
            unsigned long code = ERR_get_error();
            if (code) ERR_error_string_n(code, metadata_error, sizeof(metadata_error));
            else snprintf(metadata_error, sizeof(metadata_error), "Cannot decode CMS signer metadata");
        }
        size_t signers = 0;
        security_error(ctx, CMSDecoderGetNumSigners(verifier->decoder, &signers), "Count CMS signers");
        security_error(ctx, CMSDecoderCopyAllCerts(verifier->decoder, &certificates), "Read CMS certificate chain");
        if (!signers) result = PDF_SIGNATURE_ERROR_NO_SIGNATURES;
        lf_json(&verifier->signers, "[");
        for (size_t i = 0; i < signers; ++i) {
            security_error(ctx, CMSDecoderCopySignerCert(verifier->decoder, i, &certificate), "Read signer certificate");
            if (!certificate) fz_throw(ctx, FZ_ERROR_FORMAT, "CMS signer has no certificate");
            name = SecCertificateCopySubjectSummary(certificate);
            chain = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
            if (!chain) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot prepare local certificate verification");
            CFArrayAppendValue(chain, certificate);
            for (CFIndex n = 0; certificates && n < CFArrayGetCount(certificates); ++n) {
                CFTypeRef item = CFArrayGetValueAtIndex(certificates, n);
                if (!CFEqual(item, certificate)) CFArrayAppendValue(chain, item);
            }
            security_error(ctx, SecTrustCreateWithCertificates(chain, verifier->policies, &trust), "Create local signer trust");
            security_error(ctx, SecTrustSetNetworkFetchAllowed(trust, false), "Disable certificate network fetching");
            int trusted = SecTrustEvaluateWithError(trust, &trust_error);
            if (!trusted) result = PDF_SIGNATURE_ERROR_NOT_TRUSTED;
            if (i) lf_json(&verifier->signers, ",");
            lf_json(&verifier->signers, "{\"name\":"); json_cf_string(&verifier->signers, name);
            // Reuse the already decoded, leaf-first CMS chain for the system
            // certificate viewer; private keys never enter this metadata.
            lf_json(&verifier->signers, ",\"certificateDER\":"); json_certificate_chain(ctx, &verifier->signers, chain);
            json_certificate_qualification(&verifier->signers, certificate);
            json_cms_metadata(&verifier->signers, cms, certificate, i, metadata_error);
            lf_json(&verifier->signers, ",\"certificateTrusted\":"); lf_json(&verifier->signers, trusted ? "true" : "false");
            lf_json(&verifier->signers, ",\"trustError\":");
            if (trust_error) description = CFErrorCopyDescription(trust_error);
            json_cf_string(&verifier->signers, description);
            lf_json(&verifier->signers, ",\"trustErrorCode\":");
            if (trust_error) {
                char code[64]; snprintf(code, sizeof(code), "%ld", (long)CFErrorGetCode(trust_error)); lf_json(&verifier->signers, code);
            } else lf_json(&verifier->signers, "null");
            CFAbsoluteTime time = 0;
            OSStatus status = CMSDecoderCopySignerSigningTime(verifier->decoder, i, &time);
            lf_json(&verifier->signers, ",\"signingTime\":");
            if (status == errSecSuccess) json_signature_time(&verifier->signers, time); else lf_json(&verifier->signers, "null");
            lf_json(&verifier->signers, ",\"signingTimeError\":"); json_status(&verifier->signers, status);
            // Set the offline timestamp policy before requesting timestamp
            // certificate metadata; no default-policy evaluation runs first.
            status = CMSDecoderCopySignerTimestampWithPolicy(verifier->decoder, verifier->timestamp_policies, i, &time);
            if (status != errSecTimestampMissing) {
                OSStatus certificate_status = CMSDecoderCopySignerTimestampCertificates(verifier->decoder, i, &timestamp_certificates);
                if (status == errSecSuccess && certificate_status != errSecSuccess) status = certificate_status;
            }
            CFIndex timestamps = timestamp_certificates ? CFArrayGetCount(timestamp_certificates) : 0;
            lf_json(&verifier->signers, ",\"timestampCertificateCount\":"); lf_json_number(&verifier->signers, timestamps);
            lf_json(&verifier->signers, ",\"timestampCertificateDER\":"); json_certificate_chain(ctx, &verifier->signers, timestamp_certificates);
            lf_json(&verifier->signers, ",\"timestampTime\":");
            // The offline revocation policy disables both revocation requests
            // and intermediate-CA fetching inside the timestamp API.
            if (status == errSecSuccess) json_signature_time(&verifier->signers, time); else lf_json(&verifier->signers, "null");
            lf_json(&verifier->signers, ",\"timestampError\":"); json_status(&verifier->signers, status);
            lf_json(&verifier->signers, "}");
            if (timestamp_certificates) CFRelease(timestamp_certificates); timestamp_certificates = NULL;
            if (description) CFRelease(description); description = NULL;
            if (name) CFRelease(name); name = NULL;
            if (trust_error) CFRelease(trust_error); trust_error = NULL;
            CFRelease(trust); trust = NULL; CFRelease(chain); chain = NULL;
            CFRelease(certificate); certificate = NULL;
        }
        lf_json(&verifier->signers, "]");
        if (verifier->signers.failed) fz_throw(ctx, FZ_ERROR_GENERIC, "Cannot allocate signer metadata");
    }
    fz_always(ctx) {
        CMS_ContentInfo_free(cms); ERR_clear_error();
        if (timestamp_certificates) CFRelease(timestamp_certificates); if (certificates) CFRelease(certificates);
        if (description) CFRelease(description); if (name) CFRelease(name); if (trust_error) CFRelease(trust_error);
        if (trust) CFRelease(trust); if (chain) CFRelease(chain); if (certificate) CFRelease(certificate);
    }
    fz_catch(ctx) {
        free(verifier->signers.data); memset(&verifier->signers, 0, sizeof(verifier->signers));
        fz_rethrow(ctx);
    }
    return result;
}
static AppleVerifier *new_verifier(fz_context *ctx) {
    AppleVerifier *verifier = fz_malloc_struct(ctx, AppleVerifier);
    fz_try(ctx) {
        verifier->base.drop = verifier_drop;
        verifier->base.check_digest = verifier_digest; verifier->base.check_certificate = verifier_certificate;
        verifier->policies = offline_policies(ctx, SecPolicyCreateBasicX509());
        verifier->timestamp_policies = offline_policies(ctx, SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, NULL));
    }
    fz_catch(ctx) { verifier_drop(ctx, &verifier->base); fz_rethrow(ctx); }
    return verifier;
}
static void collect_signature_field(fz_context *ctx, pdf_obj *field, void *opaque, pdf_obj **inherited) {
    if (!inherited || !pdf_name_eq(ctx, inherited[0], PDF_NAME(Sig))) return;
    pdf_obj *parent = pdf_dict_get(ctx, field, PDF_NAME(Parent));
    // One terminal field may own several page widgets. Report its signature
    // once rather than repeating the parent's inherited V for each widget.
    if (parent && pdf_name_eq(ctx, pdf_dict_get(ctx, field, PDF_NAME(Subtype)), PDF_NAME(Widget)) &&
        !pdf_dict_get(ctx, field, PDF_NAME(T)) && !pdf_dict_get(ctx, field, PDF_NAME(V))) return;
    pdf_obj *kids = pdf_dict_get(ctx, field, PDF_NAME(Kids));
    for (int i = 0; i < pdf_array_len(ctx, kids); ++i) {
        pdf_obj *child = pdf_array_get(ctx, kids, i);
        if (!pdf_name_eq(ctx, pdf_dict_get(ctx, child, PDF_NAME(Subtype)), PDF_NAME(Widget)) ||
            pdf_dict_get(ctx, child, PDF_NAME(T)) || pdf_dict_get(ctx, child, PDF_NAME(V))) return;
    }
    if (!pdf_array_contains(ctx, (pdf_obj *)opaque, field)) pdf_array_push(ctx, (pdf_obj *)opaque, field);
}
static int pending_signature(fz_context *ctx, pdf_document *doc, pdf_obj *field) {
    // The field tree and a page's Annots can hold distinct references to the
    // same PDF object; a value snapshot must compare their object identity.
    for (int i = 0; i < doc->num_incremental_sections; ++i)
        for (pdf_unsaved_sig *sig = doc->xref_sections[i].unsaved_sigs; sig; sig = sig->next)
            if (!pdf_objcmp(ctx, sig->field, field)) return 1;
    return 0;
}
static void append_signature_field(fz_context *ctx, pdf_document *doc, pdf_obj *field, int page,
    AppleVerifier *verifier, SumraJSON *json) {
    char *name = NULL, *contents = NULL;
    char digest_error[512] = {0}, certificate_error[512] = {0}, change_error[512] = {0};
    pdf_signature_error digest = PDF_SIGNATURE_ERROR_UNKNOWN, certificate = PDF_SIGNATURE_ERROR_UNKNOWN;
    int changed = -1;
    fz_var(name); fz_var(contents); fz_var(digest); fz_var(certificate); fz_var(changed);
    fz_var(digest_error); fz_var(certificate_error); fz_var(change_error);
    verifier_reset(verifier);
    pdf_obj *value = pdf_dict_get_inheritable(ctx, field, PDF_NAME(V));
    const char *subfilter = pdf_to_name(ctx, pdf_dict_get(ctx, value, PDF_NAME(SubFilter)));
    int document_timestamp = !strcmp(subfilter, "ETSI.RFC3161");
    int is_signed = pdf_signature_is_signed(ctx, doc, field) || (document_timestamp && pdf_dict_get(ctx, value, PDF_NAME(Contents)));
    int pending = pending_signature(ctx, doc, field);
    fz_try(ctx) {
        name = pdf_load_field_name(ctx, field);
        if (is_signed && !pending) {
            verifier->legacy_sha1 = !strcmp(subfilter, "adbe.pkcs7.sha1");
            fz_try(ctx) {
                if (document_timestamp || (strcmp(subfilter, "adbe.pkcs7.detached") && strcmp(subfilter, "ETSI.CAdES.detached") && !verifier->legacy_sha1))
                    fz_throw(ctx, FZ_ERROR_ARGUMENT, document_timestamp ? "RFC3161 document timestamp imprint verification is not exposed by Security CMSDecoder" : "Unsupported PDF signature SubFilter");
                digest = pdf_check_digest(ctx, &verifier->base, doc, field);
            }
            fz_catch(ctx) { snprintf(digest_error, sizeof(digest_error), "%s", fz_convert_error(ctx, NULL)); }
            fz_try(ctx) {
                if (document_timestamp) {
                    size_t length = pdf_signature_contents(ctx, doc, field, &contents);
                    certificate = verifier_certificate(ctx, &verifier->base, (unsigned char *)contents, length);
                } else certificate = pdf_check_certificate(ctx, &verifier->base, doc, field);
            }
            fz_catch(ctx) { snprintf(certificate_error, sizeof(certificate_error), "%s", fz_convert_error(ctx, NULL)); }
            fz_try(ctx) {
                if (!document_timestamp) changed = pdf_signature_incremental_change_since_signing(ctx, doc, field);
            }
            fz_catch(ctx) { snprintf(change_error, sizeof(change_error), "%s", fz_convert_error(ctx, NULL)); }
        }
        lf_json(json, "{\"name\":"); lf_json_string(json, name);
        lf_json(json, ",\"page\":"); if (page >= 0) lf_json_number(json, page); else lf_json(json, "null");
        lf_json(json, ",\"readOnly\":"); lf_json(json, (pdf_field_flags(ctx, field) & PDF_FIELD_IS_READ_ONLY) ? "true" : "false");
        lf_json(json, ",\"isSigned\":"); lf_json(json, is_signed ? "true" : "false");
        lf_json(json, ",\"pending\":"); lf_json(json, pending ? "true" : "false");
        lf_json(json, ",\"subFilter\":"); lf_json_string(json, subfilter);
        lf_json(json, ",\"isDocumentTimestamp\":"); lf_json(json, document_timestamp ? "true" : "false");
        lf_json(json, ",\"cades\":"); lf_json(json, !strncmp(subfilter, "ETSI.CAdES", 10) ? "true" : "false");
        const char *keys[] = {"pdfSigningTime", "reason", "location", "contact"};
        pdf_obj *names[] = {PDF_NAME(M), PDF_NAME(Reason), PDF_NAME(Location), PDF_NAME(ContactInfo)};
        for (int i = 0; i < 4; ++i) {
            lf_json(json, ","); lf_json_string(json, keys[i]); lf_json(json, ":");
            lf_json_string(json, pdf_to_text_string(ctx, pdf_dict_get(ctx, value, names[i])));
        }
        lf_json(json, ",\"digestValid\":"); lf_json(json, !is_signed || pending || digest_error[0] ? "null" : digest == PDF_SIGNATURE_ERROR_OKAY ? "true" : "false");
        lf_json(json, ",\"digestError\":"); lf_json_string(json, digest_error[0] ? digest_error : is_signed && !pending && digest ? pdf_signature_error_description(digest) : "");
        lf_json(json, ",\"certificateTrusted\":"); lf_json(json, !is_signed || pending || certificate_error[0] ? "null" : certificate == PDF_SIGNATURE_ERROR_OKAY ? "true" : "false");
        lf_json(json, ",\"certificateError\":"); lf_json_string(json, certificate_error[0] ? certificate_error : is_signed && !pending && certificate ? pdf_signature_error_description(certificate) : "");
        lf_json(json, ",\"changedSinceSigning\":"); lf_json(json, changed < 0 ? "null" : changed ? "true" : "false");
        lf_json(json, ",\"changeError\":"); lf_json_string(json, change_error);
        lf_json(json, ",\"signers\":"); lf_json(json, verifier->signers.data ? verifier->signers.data : "[]");
        lf_json(json, "}");
    }
    fz_always(ctx) { fz_free(ctx, name); fz_free(ctx, contents); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
static char *signature_info(fz_context *ctx, pdf_document *doc, char *error) {
    pdf_obj *fields = NULL; pdf_page *page = NULL;
    AppleVerifier *verifier = NULL; int *pages = NULL; SumraJSON json = {0};
    fz_var(fields); fz_var(page); fz_var(verifier); fz_var(pages); fz_var(json);
    fz_try(ctx) {
        fields = pdf_new_array(ctx, doc, 4);
        pdf_obj *inherited = NULL, *names[] = {PDF_NAME(FT), NULL};
        pdf_walk_tree(ctx, pdf_dict_getp(ctx, pdf_trailer(ctx, doc), "Root/AcroForm/Fields"), PDF_NAME(Kids),
            collect_signature_field, NULL, fields, names, &inherited);
        int count = pdf_array_len(ctx, fields);
        if (count) {
            verifier = new_verifier(ctx);
            pages = fz_malloc_array(ctx, count, int);
            for (int i = 0; i < count; ++i) pages[i] = -1;
            for (int index = 0; index < pdf_count_pages(ctx, doc); ++index) {
                page = pdf_load_page(ctx, doc, index);
                for (pdf_annot *widget = pdf_first_widget(ctx, page); widget; widget = pdf_next_widget(ctx, widget)) {
                    if (pdf_widget_type(ctx, widget) != PDF_WIDGET_TYPE_SIGNATURE) continue;
                    pdf_obj *obj = pdf_annot_obj(ctx, widget);
                    int n = pdf_array_find(ctx, fields, obj);
                    if (n < 0) n = pdf_array_find(ctx, fields, pdf_dict_get(ctx, obj, PDF_NAME(Parent)));
                    if (n >= 0 && pages[n] < 0) pages[n] = index;
                }
                fz_drop_page(ctx, (fz_page *)page); page = NULL;
            }
        }
        pdf_obj *dss = pdf_dict_getp(ctx, pdf_trailer(ctx, doc), "Root/DSS");
        lf_json(&json, "{\"trustPolicy\":\"macOS local trust at the current time; network fetching disabled; cached revocation information only\",\"dssCertificates\":");
        lf_json_number(&json, pdf_array_len(ctx, pdf_dict_gets(ctx, dss, "Certs")));
        lf_json(&json, ",\"dssOCSPResponses\":"); lf_json_number(&json, pdf_array_len(ctx, pdf_dict_gets(ctx, dss, "OCSPs")));
        lf_json(&json, ",\"dssCRLs\":"); lf_json_number(&json, pdf_array_len(ctx, pdf_dict_gets(ctx, dss, "CRLs")));
        lf_json(&json, ",\"dssValidationInfoEntries\":"); lf_json_number(&json, pdf_dict_len(ctx, pdf_dict_gets(ctx, dss, "VRI")));
        lf_json(&json, ",\"signatures\":[");
        for (int i = 0; i < count; ++i) {
            if (i) lf_json(&json, ",");
            append_signature_field(ctx, doc, pdf_array_get(ctx, fields, i), pages[i], verifier, &json);
        }
        lf_json(&json, "]}");
    }
    fz_always(ctx) {
        if (verifier) pdf_drop_verifier(ctx, &verifier->base);
        fz_free(ctx, pages); fz_drop_page(ctx, (fz_page *)page); pdf_drop_obj(ctx, fields);
    }
    fz_catch(ctx) { free(json.data); json.data = NULL; snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    return json.data ? lf_json_finish(&json, error) : NULL;
}

// EngineMupdf::GetSignatures inspects the live field tree while MuPDF's
// verifier reads the original signed byte ranges through doc->file.
API char *lf_pdf_live_signature_info(void *opaque, char *error) {
    SumraMuPDFDocument *d = opaque;
    pdf_document *doc = pdf_specifics(d->ctx, d->doc);
    if (!doc) { snprintf(error, 512, "This document is not a PDF"); return NULL; }
    return signature_info(d->ctx, doc, error);
}
typedef struct { pdf_document *doc; int count; } SignedFields;
static void count_signed_field(fz_context *ctx, pdf_obj *field, void *opaque, pdf_obj **inherited) {
    (void)inherited;
    SignedFields *fields = opaque;
    if (pdf_signature_is_signed(ctx, fields->doc, field)) fields->count = 1;
}
static int signed_fields(fz_context *ctx, pdf_document *doc) {
    SignedFields fields = {doc, 0};
    pdf_obj *roots = pdf_dict_getp(ctx, pdf_trailer(ctx, doc), "Root/AcroForm/Fields");
    pdf_walk_tree(ctx, roots, PDF_NAME(Kids), count_signed_field, NULL, &fields, NULL, NULL);
    return fields.count;
}
// Follow the same parent-chain/cycle rule as MuPDF's pdf_walk_parent.
// pdf_dict_get_inheritable returns the value, not the dictionary owning it.
static pdf_obj *signature_value_owner(fz_context *ctx, pdf_obj *field) {
    pdf_obj *node = field, *slow = field;
    int halfbeat = 11;
    while (node) {
        if (pdf_dict_get(ctx, node, PDF_NAME(V))) return node;
        node = pdf_dict_get(ctx, node, PDF_NAME(Parent));
        if (node == slow) fz_throw(ctx, FZ_ERROR_FORMAT, "cycle in signature field parent chain");
        if (--halfbeat == 0) { slow = pdf_dict_get(ctx, slow, PDF_NAME(Parent)); halfbeat = 2; }
    }
    return NULL;
}
static void rewrite_signatures(fz_context *ctx, pdf_document *doc, int invalidate) {
    if (!invalidate) {
        if (signed_fields(ctx, doc)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Rewriting this PDF would invalidate its digital signatures; explicitly allow clearing signatures in the output copy");
        return;
    }
    pdf_page *page = NULL; pdf_obj *owners = NULL; fz_var(page); fz_var(owners);
    fz_try(ctx) {
        owners = pdf_new_array(ctx, doc, 4);
        int count = pdf_count_pages(ctx, doc);
        for (int i = 0; i < count; ++i) {
            page = pdf_load_page(ctx, doc, i);
            for (pdf_annot *widget = pdf_first_widget(ctx, page); widget; widget = pdf_next_widget(ctx, widget)) {
                if (pdf_widget_type(ctx, widget) != PDF_WIDGET_TYPE_SIGNATURE || !pdf_widget_is_signed(ctx, widget)) continue;
                pdf_obj *owner = signature_value_owner(ctx, pdf_annot_obj(ctx, widget));
                // This public operation validates the widget's inherited
                // ReadOnly flag and regenerates its unsigned appearance.
                pdf_clear_signature(ctx, widget);
                if (owner && !pdf_array_contains(ctx, owners, owner)) pdf_array_push(ctx, owners, owner);
            }
            fz_drop_page(ctx, (fz_page *)page); page = NULL;
        }
        // A separated field owns V on its parent, not on its page widget.
        // Keep parent values until all sibling widgets have been cleared so
        // every widget goes through the permission check and appearance update.
        for (int i = 0; i < pdf_array_len(ctx, owners); ++i) pdf_dict_del(ctx, pdf_array_get(ctx, owners, i), PDF_NAME(V));
        // A signed field can lack a page widget. The public clearing API
        // cannot clear it legally; keep that failure instead of emitting an
        // output whose preserved signature no longer matches its bytes.
        if (signed_fields(ctx, doc)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF contains a signed field that cannot be cleared through its page widget");
    }
    fz_always(ctx) { fz_drop_page(ctx, (fz_page *)page); pdf_drop_obj(ctx, owners); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
static pdf_write_options compact_pdf_options(void) {
    // PdfTools.cpp: clean -gggg -e 100 -f -i -t -Z.
    pdf_write_options options = pdf_default_write_options;
    options.do_compress = 1; options.do_compress_images = 1;
    options.do_compress_fonts = 1; options.do_garbage = 4;
    options.compression_effort = 100; options.do_pretty = 0;
    options.do_use_objstms = 1;
    return options;
}
API int lf_pdf_operation(const char *source, const char *destination, const char *password, const char *operation, const char *owner_password, const char *user_password, int permissions, int invalidate_signatures, char *error) {
    fz_context *ctx = new_pdf_context();
    if (!ctx) { snprintf(error, 512, "Cannot create PDF context"); return 0; }
    pdf_document *doc = NULL; int ok = 0; fz_var(doc); fz_var(ok);
    fz_try(ctx) {
        doc = open_pdf(ctx, source, password, 1);
        rewrite_signatures(ctx, doc, invalidate_signatures);
        pdf_write_options options = pdf_default_write_options;
        if (!strcmp(operation, "compress")) options = compact_pdf_options();
        else if (!strcmp(operation, "decompress")) options.do_decompress = 1;
        else if (!strcmp(operation, "bake") || !strcmp(operation, "flatten")) {
            // pdfbake's -F option leaves form fields interactive.
            pdf_bake_document(ctx, doc, 1, !strcmp(operation, "bake"));
            options.do_compress = 1; options.do_garbage = 3;
        }
        else if (!strcmp(operation, "redact")) {
            // Same removal policy as Sumatra EngineMupdf::ApplyRedactions.
            pdf_redact_options redact = { 1, PDF_REDACT_IMAGE_PIXELS,
                PDF_REDACT_LINE_ART_REMOVE_IF_TOUCHED, PDF_REDACT_TEXT_REMOVE };
            pdf_page *page = NULL; int applied = 0; fz_var(page); fz_var(applied);
            fz_try(ctx) {
                for (int i = 0; i < pdf_count_pages(ctx, doc); ++i) {
                    page = pdf_load_page(ctx, doc, i);
                    applied |= pdf_redact_page(ctx, doc, page, &redact);
                    fz_drop_page(ctx, (fz_page *)page); page = NULL;
                }
                if (!applied) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF has no redaction marks");
            }
            fz_always(ctx) { fz_drop_page(ctx, (fz_page *)page); }
            fz_catch(ctx) { fz_rethrow(ctx); }
            // A full garbage-collected rewrite removes unreachable old content.
            options.do_garbage = 4; options.do_compress = 1;
        }
        else if (!strcmp(operation, "encrypt")) {
            if (!owner_password[0]) fz_throw(ctx, FZ_ERROR_ARGUMENT, "An owner password is required");
            if (strlen(owner_password) >= sizeof(options.opwd_utf8) || strlen(user_password) >= sizeof(options.upwd_utf8))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "PDF passwords must fit within 127 UTF-8 bytes");
            options.do_encrypt = PDF_ENCRYPT_AES_256;
            // An unspecified mask preserves the stored reader permissions,
            // not the authenticated owner's effective all-access permissions.
            options.permissions = permissions == -1 && doc->crypt ? pdf_crypt_permissions(ctx, doc->crypt) : permissions;
            memcpy(options.opwd_utf8, owner_password, strlen(owner_password)+1);
            memcpy(options.upwd_utf8, user_password, strlen(user_password)+1);
        }
        else if (!strcmp(operation, "decrypt")) options.do_encrypt = PDF_ENCRYPT_NONE;
        else fz_throw(ctx, FZ_ERROR_ARGUMENT, "Unknown PDF operation");
        pdf_save_document(ctx, doc, destination, &options); ok = 1;
    }
    fz_always(ctx) { pdf_drop_document(ctx, doc); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx); return ok;
}

API int lf_pdf_select_pages(const char *source, const char *destination, const char *password,
                           int count, const int *pages, int annotations_only, int invalidate_signatures, char *error) {
    fz_context *ctx = new_pdf_context();
    if (!ctx) { snprintf(error, 512, "Cannot create PDF context"); return 0; }
    pdf_document *doc = NULL; int *selected = NULL; int ok = 0;
    fz_var(doc); fz_var(selected); fz_var(ok);
    fz_try(ctx) {
        doc = open_pdf(ctx, source, password, 0);
        if (!pdf_has_permission(ctx, doc, FZ_PERMISSION_COPY)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF does not allow content extraction");
        if (count <= 0 || !pages) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Choose PDF pages to extract");
        pdf_check_document(ctx, doc); // pdfclean repairs before changing objects.
        rewrite_signatures(ctx, doc, invalidate_signatures);
        int total = pdf_count_pages(ctx, doc), retained = 0;
        selected = fz_malloc_array(ctx, count, int);
        for (int i = 0; i < count; ++i) {
            if (pages[i] < 0 || pages[i] >= total) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid PDF page selection");
            int keep = !annotations_only;
            if (!keep) {
                pdf_obj *annots = pdf_dict_get(ctx, pdf_lookup_page_obj(ctx, doc, pages[i]), PDF_NAME(Annots));
                for (int j = 0, n = pdf_array_len(ctx, annots); j < n && !keep; ++j) {
                    pdf_obj *type = pdf_dict_get(ctx, pdf_array_get(ctx, annots, j), PDF_NAME(Subtype));
                    keep = !pdf_name_eq(ctx, type, PDF_NAME(Link)) && !pdf_name_eq(ctx, type, PDF_NAME(Widget)) &&
                           !pdf_name_eq(ctx, type, PDF_NAME(Popup));
                }
            }
            if (keep) selected[retained++] = pages[i];
        }
        if (!retained) fz_throw(ctx, FZ_ERROR_ARGUMENT, "No selected pages contain annotations");
        // This is pdfclean's page-subset policy, including its removal of
        // AcroForm/document scripts/structure. It is an output-copy operation.
        pdf_rearrange_pages(ctx, doc, retained, selected, PDF_CLEAN_STRUCTURE_DROP);
        pdf_write_options options = compact_pdf_options();
        pdf_save_document(ctx, doc, destination, &options); ok = 1;
    }
    fz_always(ctx) { fz_free(ctx, selected); pdf_drop_document(ctx, doc); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx); return ok;
}

// MuPDF tools/pdfmerge.c's outline walk, specialized to whole input documents.
// Pending parent headings are copied when their first retained child is seen.
typedef struct {
    fz_context *ctx; pdf_document *source;
    fz_outline_iterator *from, *to;
    int page_count, page_offset, copied_depth;
    fz_list(fz_outline_item, items);
} MergeOutline;
static void merge_outline_items(MergeOutline *s) {
    fz_context *ctx = s->ctx;
    do {
        float x, y;
        fz_outline_item *item = fz_outline_iterator_item(ctx, s->from);
        int page = fz_page_number_from_location(ctx, (fz_document *)s->source,
            fz_resolve_link(ctx, (fz_document *)s->source, item->uri, &x, &y));
        fz_outline_item *copy = fz_push_list(ctx, s->items);
        *copy = *item; copy->title = NULL; copy->uri = NULL;
        copy->title = item->title ? fz_strdup(ctx, item->title) : NULL;
        if (item->uri) {
            const char *tail = strchr(item->uri, '&');
            copy->uri = !strncmp(item->uri, "#page=", 6)
                ? fz_asprintf(ctx, "#page=%d%s", page + s->page_offset + 1, tail ? tail : "")
                : fz_strdup(ctx, item->uri);
        }
        if (page >= 0 && page < s->page_count) {
            while (s->copied_depth < s->items_len) {
                fz_outline_item parent = s->items[s->copied_depth];
                parent.uri = s->items[s->items_len - 1].uri;
                fz_outline_iterator_insert(ctx, s->to, &parent); ++s->copied_depth;
                fz_outline_iterator_prev(ctx, s->to); fz_outline_iterator_down(ctx, s->to);
            }
        }
        int children = fz_outline_iterator_down(ctx, s->from);
        if (children == 0) merge_outline_items(s);
        if (children >= 0) fz_outline_iterator_up(ctx, s->from);
        int depth = s->items_len - 1;
        if (s->copied_depth > depth) { s->copied_depth = depth; fz_outline_iterator_up(ctx, s->to); }
        fz_outline_iterator_next(ctx, s->to);
        fz_free(ctx, s->items[depth].title); fz_free(ctx, s->items[depth].uri); --s->items_len;
    } while (fz_outline_iterator_next(ctx, s->from) == 0);
}
static void merge_outline(fz_context *ctx, pdf_document *source, pdf_document *output, int offset) {
    MergeOutline state = {0}; state.ctx = ctx; state.source = source;
    state.page_count = pdf_count_pages(ctx, source); state.page_offset = offset;
    fz_var(state);
    fz_try(ctx) {
        state.from = fz_new_outline_iterator(ctx, (fz_document *)source);
        state.to = fz_new_outline_iterator(ctx, (fz_document *)output);
        if (fz_outline_iterator_item(ctx, state.to)) while (fz_outline_iterator_next(ctx, state.to) == 0) {}
        if (fz_outline_iterator_item(ctx, state.from)) merge_outline_items(&state);
    }
    fz_always(ctx) {
        for (int i = 0; i < state.items_len; ++i) { fz_free(ctx, state.items[i].title); fz_free(ctx, state.items[i].uri); }
        fz_free(ctx, state.items);
        fz_drop_outline_iterator(ctx, state.from); fz_drop_outline_iterator(ctx, state.to);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
API int lf_pdf_merge(int count, const char *const *sources, const char *const *passwords,
                     const char *destination, int invalidate_signatures, char *error) {
    fz_context *ctx = new_pdf_context();
    if (!ctx) { snprintf(error, 512, "Cannot create PDF context"); return 0; }
    pdf_document *source = NULL, *output = NULL; pdf_graft_map *map = NULL;
    pdf_page *from = NULL, *to = NULL; fz_link *links = NULL; int ok = 0;
    fz_var(source); fz_var(output); fz_var(map); fz_var(from); fz_var(to); fz_var(links); fz_var(ok);
    fz_try(ctx) {
        if (count <= 0 || !sources || !passwords) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Choose PDFs to merge");
        output = pdf_create_document(ctx);
        for (int i = 0; i < count; ++i) {
            source = open_pdf(ctx, sources[i], passwords[i], 0);
            if (!pdf_has_permission(ctx, source, FZ_PERMISSION_COPY)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF does not allow content extraction");
            if (!invalidate_signatures && signed_fields(ctx, source))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Merging does not preserve digital signatures; explicitly allow an unsigned output copy");
            map = pdf_new_graft_map(ctx, output);
            int offset = pdf_count_pages(ctx, output), pages = pdf_count_pages(ctx, source);
            for (int page = 0; page < pages; ++page) {
                pdf_graft_mapped_page(ctx, map, -1, source, page);
                from = pdf_load_page(ctx, source, page); to = pdf_load_page(ctx, output, offset + page);
                links = fz_load_links(ctx, (fz_page *)from);
                // pdfmerge preserves external links. Internal links and other
                // annotations/forms are deliberately outside its graft policy.
                for (fz_link *link = links; link; link = link->next)
                    if (fz_is_external_link(ctx, link->uri)) fz_drop_link(ctx, fz_create_link(ctx, (fz_page *)to, link->rect, link->uri));
                fz_drop_link(ctx, links); links = NULL;
                fz_drop_page(ctx, (fz_page *)from); from = NULL; fz_drop_page(ctx, (fz_page *)to); to = NULL;
            }
            merge_outline(ctx, source, output, offset);
            pdf_drop_graft_map(ctx, map); map = NULL; pdf_drop_document(ctx, source); source = NULL;
        }
        if (!pdf_count_pages(ctx, output)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The input PDFs have no pages");
        pdf_write_options options = compact_pdf_options();
        pdf_save_document(ctx, output, destination, &options); ok = 1;
    }
    fz_always(ctx) {
        fz_drop_link(ctx, links); fz_drop_page(ctx, (fz_page *)from); fz_drop_page(ctx, (fz_page *)to);
        pdf_drop_graft_map(ctx, map); pdf_drop_document(ctx, source); pdf_drop_document(ctx, output);
    }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx); return ok;
}

// A Markdown print page is already a one-page, source-faithful MuPDF PDF.
// Quartz can paint it, but replaying its fonts loses ToUnicode and merges
// distinct Unicode aliases. Keep the original contents/resources and place
// them on the AppKit paper using the CTM captured immediately before replay.
typedef struct PrintSourceFontProgram {
    struct PrintSourceFontProgram *next;
    pdf_obj *ref;
    pdf_obj *metadata;
    fz_buffer *decoded;
    unsigned char digest[16];
    int kind;
} PrintSourceFontProgram;

typedef struct PrintSourceDuplicateFont {
    struct PrintSourceDuplicateFont *next;
    int num;
} PrintSourceDuplicateFont;

typedef struct {
    fz_context *ctx;
    pdf_document *pages;
    PrintSourceFontProgram *fonts;
    int count;
    int failed;
} PrintSourcePDFWriter;

API void lf_print_source_pdf_drop(void *opaque) {
    PrintSourcePDFWriter *writer = opaque;
    if (!writer) return;
    PrintSourceFontProgram *font = writer->fonts;
    while (font) {
        PrintSourceFontProgram *next = font->next;
        pdf_drop_obj(writer->ctx, font->ref);
        pdf_drop_obj(writer->ctx, font->metadata);
        fz_drop_buffer(writer->ctx, font->decoded);
        fz_free(writer->ctx, font);
        font = next;
    }
    pdf_drop_document(writer->ctx, writer->pages);
    fz_drop_context(writer->ctx);
    free(writer);
}

API void *lf_print_source_pdf_begin(char *error) {
    PrintSourcePDFWriter *writer = calloc(1, sizeof(*writer));
    if (!writer) { snprintf(error, 512, "Cannot allocate PDF print writer"); return NULL; }
    writer->ctx = new_pdf_context();
    if (!writer->ctx) { snprintf(error, 512, "Cannot create PDF context"); free(writer); return NULL; }
    fz_try(writer->ctx) { writer->pages = pdf_create_document(writer->ctx); }
    fz_catch(writer->ctx) {
        snprintf(error, 512, "%s", fz_convert_error(writer->ctx, NULL));
        lf_print_source_pdf_drop(writer);
        return NULL;
    }
    return writer;
}

static int print_source_equal(double a, double b) { return fabs(a - b) <= 0.01; }
static int print_source_box(fz_rect box, double width, double height) {
    return isfinite(box.x0) && isfinite(box.y0) && isfinite(box.x1) && isfinite(box.y1) &&
        print_source_equal(box.x0, 0) && print_source_equal(box.y0, 0) &&
        print_source_equal(box.x1, width) && print_source_equal(box.y1, height);
}

static int print_source_encoding_key(fz_context *ctx, pdf_obj *key) {
    return pdf_name_eq(ctx, key, PDF_NAME(Length)) || pdf_name_eq(ctx, key, PDF_NAME(Filter)) ||
        pdf_name_eq(ctx, key, PDF_NAME(DecodeParms));
}

// The decoded program and every non-encoding stream entry must agree. A
// FontDescriptor's mappings and ToUnicode are deliberately not shared.
static pdf_obj *print_source_font_metadata(fz_context *ctx, pdf_document *doc, pdf_obj *stream) {
    pdf_obj *metadata = pdf_new_dict(ctx, doc, pdf_dict_len(ctx, stream));
    fz_try(ctx) {
        for (int i = 0; i < pdf_dict_len(ctx, stream); ++i) {
            pdf_obj *key = pdf_dict_get_key(ctx, stream, i);
            if (!print_source_encoding_key(ctx, key))
                pdf_dict_put(ctx, metadata, key, pdf_dict_get_val(ctx, stream, i));
        }
    }
    fz_catch(ctx) { pdf_drop_obj(ctx, metadata); fz_rethrow(ctx); }
    return metadata;
}

static void print_source_record_duplicate(fz_context *ctx, PrintSourceDuplicateFont **list, int num) {
    for (PrintSourceDuplicateFont *entry = *list; entry; entry = entry->next)
        if (entry->num == num) return;
    PrintSourceDuplicateFont *entry = fz_malloc_struct(ctx, PrintSourceDuplicateFont);
    entry->num = num;
    entry->next = *list;
    *list = entry;
}

static void print_source_drop_duplicates(fz_context *ctx, PrintSourceDuplicateFont *list) {
    while (list) {
        PrintSourceDuplicateFont *next = list->next;
        fz_free(ctx, list);
        list = next;
    }
}

static void print_source_share_font(fz_context *ctx, PrintSourcePDFWriter *writer,
    pdf_obj *descriptor, pdf_obj *key, int kind, PrintSourceDuplicateFont **duplicates) {
    pdf_obj *ref = pdf_dict_get(ctx, descriptor, key);
    if (!pdf_is_indirect(ctx, ref) || !pdf_is_stream(ctx, ref)) return;
    int num = pdf_to_num(ctx, ref);
    for (PrintSourceFontProgram *font = writer->fonts; font; font = font->next)
        if (pdf_to_num(ctx, font->ref) == num) return;
    fz_buffer *decoded = NULL;
    pdf_obj *metadata = NULL;
    PrintSourceFontProgram *fresh = NULL;
    fz_var(decoded); fz_var(metadata); fz_var(fresh);
    fz_try(ctx) {
        decoded = pdf_load_stream(ctx, ref);
        metadata = print_source_font_metadata(ctx, writer->pages, ref);
        unsigned char digest[16];
        fz_md5_buffer(ctx, decoded, digest);
        unsigned char *data = NULL;
        size_t length = fz_buffer_storage(ctx, decoded, &data);
        for (PrintSourceFontProgram *font = writer->fonts; font; font = font->next) {
            if (font->kind != kind || memcmp(font->digest, digest, sizeof(digest)) ||
                pdf_objcmp_deep(ctx, font->metadata, metadata)) continue;
            unsigned char *other = NULL;
            size_t other_length = fz_buffer_storage(ctx, font->decoded, &other);
            if (length != other_length || (length && memcmp(data, other, length))) continue;
            pdf_dict_put(ctx, descriptor, key, font->ref);
            print_source_record_duplicate(ctx, duplicates, num);
            break;
        }
        if (pdf_to_num(ctx, pdf_dict_get(ctx, descriptor, key)) == num) {
            fresh = fz_malloc_struct(ctx, PrintSourceFontProgram);
            fresh->ref = pdf_keep_obj(ctx, ref);
            fresh->metadata = metadata; metadata = NULL;
            fresh->decoded = decoded; decoded = NULL;
            memcpy(fresh->digest, digest, sizeof(digest));
            fresh->kind = kind;
            fresh->next = writer->fonts;
            writer->fonts = fresh; fresh = NULL;
        }
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, decoded);
        pdf_drop_obj(ctx, metadata);
        if (fresh) {
            pdf_drop_obj(ctx, fresh->ref);
            pdf_drop_obj(ctx, fresh->metadata);
            fz_drop_buffer(ctx, fresh->decoded);
            fz_free(ctx, fresh);
        }
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

static void print_source_share_fonts(fz_context *ctx, PrintSourcePDFWriter *writer,
    pdf_obj *obj, PrintSourceDuplicateFont **duplicates) {
    if (!obj) return;
    if (!pdf_is_dict(ctx, obj) && !pdf_is_array(ctx, obj)) return;
    if (pdf_mark_obj(ctx, obj)) return;
    fz_try(ctx) {
        if (pdf_is_dict(ctx, obj)) {
            print_source_share_font(ctx, writer, obj, PDF_NAME(FontFile), 1, duplicates);
            print_source_share_font(ctx, writer, obj, PDF_NAME(FontFile2), 2, duplicates);
            print_source_share_font(ctx, writer, obj, PDF_NAME(FontFile3), 3, duplicates);
            for (int i = 0; i < pdf_dict_len(ctx, obj); ++i)
                print_source_share_fonts(ctx, writer, pdf_dict_get_val(ctx, obj, i), duplicates);
        } else {
            for (int i = 0; i < pdf_array_len(ctx, obj); ++i)
                print_source_share_fonts(ctx, writer, pdf_array_get(ctx, obj, i), duplicates);
        }
    }
    fz_always(ctx) { pdf_unmark_obj(ctx, obj); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

static int print_source_references(fz_context *ctx, pdf_obj *obj, int num) {
    if (!obj) return 0;
    if (pdf_is_indirect(ctx, obj) && pdf_to_num(ctx, obj) == num) return 1;
    if (!pdf_is_dict(ctx, obj) && !pdf_is_array(ctx, obj)) return 0;
    if (pdf_mark_obj(ctx, obj)) return 0;
    int found = 0;
    fz_var(found);
    fz_try(ctx) {
        if (pdf_is_dict(ctx, obj)) {
            for (int i = 0; i < pdf_dict_len(ctx, obj) && !found; ++i) {
                pdf_obj *key = pdf_dict_get_key(ctx, obj, i);
                // The page tree is outside this newly grafted page's graph.
                if (pdf_name_eq(ctx, key, PDF_NAME(Parent))) continue;
                found = print_source_references(ctx, pdf_dict_get_val(ctx, obj, i), num);
            }
        } else {
            for (int i = 0; i < pdf_array_len(ctx, obj) && !found; ++i)
                found = print_source_references(ctx, pdf_array_get(ctx, obj, i), num);
        }
    }
    fz_always(ctx) { pdf_unmark_obj(ctx, obj); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return found;
}

API int lf_print_source_pdf_add(void *opaque, const unsigned char *bytes, size_t size,
    double paper_width, double paper_height, const double *matrix, const double *source_clip, char *error) {
    PrintSourcePDFWriter *writer = opaque;
    if (!writer || !writer->ctx || writer->failed || !bytes || !size || !matrix || !source_clip ||
        !isfinite(paper_width) || !isfinite(paper_height) || paper_width <= 0 || paper_height <= 0 ||
        paper_width > FLT_MAX || paper_height > FLT_MAX || writer->count == INT_MAX) {
        snprintf(error, 512, "Invalid source PDF print page"); return 0;
    }
    for (int i = 0; i < 6; ++i) if (!isfinite(matrix[i]) || fabs(matrix[i]) > FLT_MAX) {
        snprintf(error, 512, "Invalid source PDF print transform"); return 0;
    }
    for (int i = 0; i < 4; ++i) if (!isfinite(source_clip[i]) || fabs(source_clip[i]) > FLT_MAX) {
        snprintf(error, 512, "Invalid source PDF print clip"); return 0;
    }
    if (source_clip[2] <= 0 || source_clip[3] <= 0 ||
        !isfinite(matrix[0] * matrix[3] - matrix[1] * matrix[2]) ||
        fabs(matrix[0] * matrix[3] - matrix[1] * matrix[2]) < 1e-12) {
        snprintf(error, 512, "Invalid source PDF print geometry"); return 0;
    }
    fz_context *ctx = writer->ctx;
    fz_stream *stream = NULL;
    pdf_document *source = NULL;
    pdf_graft_map *map = NULL;
    pdf_obj *original = NULL;
    PrintSourceDuplicateFont *duplicates = NULL;
    fz_buffer *prefix = NULL, *suffix = NULL;
    int ok = 0;
    fz_var(stream); fz_var(source); fz_var(map); fz_var(original);
    fz_var(prefix); fz_var(suffix); fz_var(duplicates); fz_var(ok);
    fz_try(ctx) {
        stream = fz_open_memory(ctx, bytes, size);
        source = pdf_open_document_with_stream(ctx, stream);
        if (pdf_dict_get(ctx, pdf_trailer(ctx, source), PDF_NAME(Encrypt)))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Encrypted source print pages are unsupported");
        if (pdf_count_pages(ctx, source) != 1)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Print source must contain exactly one PDF page");
        pdf_obj *page = pdf_lookup_page_obj(ctx, source, 0);
        pdf_obj *media_obj = pdf_dict_get_inheritable(ctx, page, PDF_NAME(MediaBox));
        if (!media_obj) fz_throw(ctx, FZ_ERROR_FORMAT, "Source print page has no MediaBox");
        fz_rect media = pdf_to_rect(ctx, media_obj);
        pdf_obj *crop_obj = pdf_dict_get_inheritable(ctx, page, PDF_NAME(CropBox));
        fz_rect crop = crop_obj ? pdf_to_rect(ctx, crop_obj) : media;
        if (!isfinite(media.x0) || !isfinite(media.y0) || !isfinite(media.x1) || !isfinite(media.y1) ||
            media.x1 <= 0 || media.y1 <= 0 || !print_source_equal(media.x0, 0) ||
            !print_source_equal(media.y0, 0) || !print_source_equal(crop.x0, media.x0) ||
            !print_source_equal(crop.y0, media.y0) || !print_source_equal(crop.x1, media.x1) ||
            !print_source_equal(crop.y1, media.y1) ||
            pdf_dict_get_inheritable_int(ctx, page, PDF_NAME(Rotate)) % 360 != 0)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Source print page has unsupported boxes or rotation");
        pdf_obj *annots = pdf_dict_get(ctx, page, PDF_NAME(Annots));
        if (annots && (!pdf_is_array(ctx, annots) || pdf_array_len(ctx, annots) != 0))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Source print page has annotations or links");
        if (pdf_dict_get(ctx, page, PDF_NAME(Group)))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Source print page has an unsupported transparency group");
        if (source_clip[0] < -0.01 || source_clip[1] < -0.01 ||
            source_clip[0] + source_clip[2] > media.x1 + 0.01 ||
            source_clip[1] + source_clip[3] > media.y1 + 0.01)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Source print clip is outside its page");
        map = pdf_new_graft_map(ctx, writer->pages);
        pdf_graft_mapped_page(ctx, map, -1, source, 0);
        pdf_obj *placed = pdf_lookup_page_obj(ctx, writer->pages, writer->count);
        pdf_obj *resources = pdf_dict_get_inheritable(ctx, placed, PDF_NAME(Resources));
        if (!resources) fz_throw(ctx, FZ_ERROR_FORMAT, "Source print page has no resources");
        print_source_share_fonts(ctx, writer, resources, &duplicates);
        // Grafting has finished for this source page. All FontFile references
        // were redirected before reclaiming any duplicate stream buffers.
        for (PrintSourceDuplicateFont *entry = duplicates; entry; entry = entry->next)
            if (!print_source_references(ctx, placed, entry->num))
                pdf_delete_object(ctx, writer->pages, entry->num);
        fz_rect paper = {0, 0, (float)paper_width, (float)paper_height};
        pdf_dict_put_rect(ctx, placed, PDF_NAME(MediaBox), paper);
        pdf_dict_del(ctx, placed, PDF_NAME(CropBox));
        pdf_dict_put_int(ctx, placed, PDF_NAME(Rotate), 0);
        original = pdf_keep_obj(ctx, pdf_dict_get(ctx, placed, PDF_NAME(Contents)));
        prefix = fz_new_buffer(ctx, 256);
        fz_append_printf(ctx, prefix,
            "q\n%.12g %.12g %.12g %.12g %.12g %.12g cm\n%.12g %.12g %.12g %.12g re W n\n",
            matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5],
            source_clip[0], source_clip[1], source_clip[2], source_clip[3]);
        suffix = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)"Q\n", 2);
        pdf_obj *contents = pdf_dict_put_array(ctx, placed, PDF_NAME(Contents),
            (original && pdf_is_array(ctx, original) ? pdf_array_len(ctx, original) : 1) + 2);
        pdf_array_push_drop(ctx, contents, pdf_add_stream(ctx, writer->pages, prefix, NULL, 0));
        if (original && pdf_is_array(ctx, original)) {
            for (int i = 0; i < pdf_array_len(ctx, original); ++i)
                pdf_array_push(ctx, contents, pdf_array_get(ctx, original, i));
        } else if (original) pdf_array_push(ctx, contents, original);
        pdf_array_push_drop(ctx, contents, pdf_add_stream(ctx, writer->pages, suffix, NULL, 0));
        ++writer->count;
        ok = 1;
    }
    fz_always(ctx) {
        print_source_drop_duplicates(ctx, duplicates);
        fz_drop_buffer(ctx, prefix); fz_drop_buffer(ctx, suffix);
        pdf_drop_obj(ctx, original); pdf_drop_graft_map(ctx, map);
        pdf_drop_document(ctx, source); fz_drop_stream(ctx, stream);
    }
    fz_catch(ctx) {
        writer->failed = 1;
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL));
    }
    return ok;
}

API int lf_print_source_pdf_finish(void *opaque, const char *system_result_path,
    const char *corrected_path, char *error) {
    PrintSourcePDFWriter *writer = opaque;
    if (!writer) { snprintf(error, 512, "No source PDF print writer"); return 0; }
    fz_context *ctx = writer->ctx;
    pdf_document *result = NULL;
    pdf_graft_map *map = NULL;
    int ok = 0;
    fz_var(result); fz_var(map); fz_var(ok);
    fz_try(ctx) {
        if (!system_result_path || !corrected_path || !strcmp(system_result_path, corrected_path) ||
            writer->failed || writer->count <= 0)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid source PDF print output");
        // Read the completed AppKit result and write only the private sibling
        // copy. A compact rewrite discards its obsolete Quartz font streams.
        result = pdf_open_document(ctx, system_result_path);
        if (pdf_dict_get(ctx, pdf_trailer(ctx, result), PDF_NAME(Encrypt)))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Encrypted PDF output cannot preserve source text; the system PDF was kept");
        if (signed_fields(ctx, result))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Signed PDF output cannot be rewritten; the system PDF was kept");
        if (pdf_count_pages(ctx, result) != writer->count)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Print layout changed the physical page count; the system PDF was kept");
        if (pdf_dict_getp(ctx, pdf_trailer(ctx, result), "Root/StructTreeRoot"))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Tagged PDF output cannot be replaced safely; the system PDF was kept");
        // Preflight every physical page before changing even the private copy.
        for (int i = 0; i < writer->count; ++i) {
            pdf_obj *target = pdf_lookup_page_obj(ctx, result, i);
            pdf_obj *staged = pdf_lookup_page_obj(ctx, writer->pages, i);
            fz_rect expected = pdf_dict_get_inheritable_rect(ctx, staged, PDF_NAME(MediaBox));
            fz_rect actual = pdf_dict_get_inheritable_rect(ctx, target, PDF_NAME(MediaBox));
            fz_rect crop = pdf_dict_get_inheritable(ctx, target, PDF_NAME(CropBox)) ?
                pdf_dict_get_inheritable_rect(ctx, target, PDF_NAME(CropBox)) : actual;
            pdf_obj *annots = pdf_dict_get(ctx, target, PDF_NAME(Annots));
            if (!print_source_box(actual, expected.x1, expected.y1) ||
                !print_source_box(crop, expected.x1, expected.y1) ||
                pdf_dict_get_inheritable_int(ctx, target, PDF_NAME(Rotate)) % 360 != 0 ||
                (annots && (!pdf_is_array(ctx, annots) || pdf_array_len(ctx, annots) != 0)) ||
                pdf_dict_get(ctx, target, PDF_NAME(Group)))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Print page geometry or content changed; the system PDF was kept");
        }
        map = pdf_new_graft_map(ctx, result);
        for (int i = 0; i < writer->count; ++i) {
            pdf_obj *target = pdf_lookup_page_obj(ctx, result, i);
            pdf_obj *staged = pdf_lookup_page_obj(ctx, writer->pages, i);
            pdf_obj *resources = pdf_dict_get_inheritable(ctx, staged, PDF_NAME(Resources));
            pdf_obj *contents = pdf_dict_get(ctx, staged, PDF_NAME(Contents));
            if (!resources || !contents)
                fz_throw(ctx, FZ_ERROR_FORMAT, "Source print page has no content resources");
            pdf_dict_put_drop(ctx, target, PDF_NAME(Resources), pdf_graft_mapped_object(ctx, map, resources));
            pdf_dict_put_drop(ctx, target, PDF_NAME(Contents), pdf_graft_mapped_object(ctx, map, contents));
        }
        pdf_write_options options = compact_pdf_options();
        pdf_save_document(ctx, result, corrected_path, &options);
        ok = 1;
    }
    fz_always(ctx) { pdf_drop_graft_map(ctx, map); pdf_drop_document(ctx, result); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    lf_print_source_pdf_drop(writer);
    return ok;
}

// Translate Sumatra FindUnsignedSignatureWidget: retain the annotation AND
// its page until signing ends; dropping the page first unbinds the widget.
static pdf_annot *find_signature(fz_context *ctx, pdf_document *doc, const char *name, pdf_page **owner) {
    pdf_page *page = NULL; pdf_annot *found = NULL; char *field_name = NULL;
    fz_var(page); fz_var(found); fz_var(field_name);
    fz_try(ctx) {
        int count = pdf_count_pages(ctx, doc);
        for (int i = 0; i < count && !found; ++i) {
            page = pdf_load_page(ctx, doc, i);
            for (pdf_annot *widget = pdf_first_widget(ctx, page); widget; widget = pdf_next_widget(ctx, widget)) {
                field_name = pdf_load_field_name(ctx, pdf_annot_obj(ctx, widget));
                int match = field_name && !strcmp(field_name, name); fz_free(ctx, field_name); field_name = NULL;
                if (!match) continue;
                if (pdf_widget_type(ctx, widget) != PDF_WIDGET_TYPE_SIGNATURE) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field is not a signature field");
                if (pdf_widget_is_signed(ctx, widget)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This signature field is already signed");
                if (pdf_widget_is_readonly(ctx, widget)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This signature field is read-only");
                found = pdf_keep_annot(ctx, widget); *owner = page; page = NULL; break;
            }
            fz_drop_page(ctx, (fz_page *)page); page = NULL;
        }
    }
    fz_always(ctx) { fz_free(ctx, field_name); fz_drop_page(ctx, (fz_page *)page); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return found;
}
API int lf_pdf_sign_with_identity(const char *source, const char *destination, const char *document_password,
                    const char *pkcs12, const char *certificate_password, SecIdentityRef identity, const char *field_name,
                    int index, const float *bounds, int bounds_in_pdf_space, const char *reason, const char *location,
                    const char *image_path, int appearance, char *error) {
    fz_context *ctx = new_pdf_context();
    if (!ctx) { snprintf(error, 512, "Cannot create PDF context"); return 0; }
    pdf_document *doc = NULL; pdf_page *page = NULL; pdf_annot *widget = NULL; pdf_pkcs7_signer *signer = NULL; fz_image *graphic = NULL; int ok = 0;
    fz_var(doc); fz_var(page); fz_var(widget); fz_var(signer); fz_var(graphic); fz_var(ok);
    fz_try(ctx) {
        doc = open_pdf(ctx, source, document_password, 0);
        if (!pdf_has_permission(ctx, doc, FZ_PERMISSION_FORM))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF does not permit signing form fields");
        if (!pdf_can_be_saved_incrementally(ctx, doc)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF needs repair before it can be signed incrementally");
        if (index < 0 || index >= pdf_count_pages(ctx, doc)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Signature page out of range");
        signer = identity ? apple_identity(ctx, identity, NULL) : apple_import(ctx, pkcs12, certificate_password);
        widget = find_signature(ctx, doc, field_name, &page);
        int created = widget == NULL;
        if (!widget) {
            if (!field_name[0]) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Choose a name for a new signature field");
            pdf_obj *fields = pdf_dict_getp(ctx, pdf_trailer(ctx, doc), "Root/AcroForm/Fields");
            if (pdf_lookup_field(ctx, fields, field_name)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "A field with this name already exists");
            page = pdf_load_page(ctx, doc, index);
            widget = pdf_create_signature_widget(ctx, page, (char *)field_name);
            // An ordinary approval signature does not request locking every
            // form field. Preserve author-provided locks on existing fields.
            pdf_obj *lock = pdf_dict_put_dict(ctx, pdf_annot_obj(ctx, widget), PDF_NAME(Lock), 2);
            pdf_dict_put(ctx, lock, PDF_NAME(Action), PDF_NAME(Include));
            pdf_dict_put_array(ctx, lock, PDF_NAME(Fields), 0);
        }
        // Explicit positive bounds also relocate an existing unsigned field.
        // With no bounds, reuse its authored rectangle; new fields are invisible.
        if (created || (bounds[2] > 0 && bounds[3] > 0)) {
            fz_rect rect = {bounds[0], bounds[1], bounds[0]+bounds[2], bounds[1]+bounds[3]};
            if (!isfinite(rect.x0) || !isfinite(rect.y0) || !isfinite(rect.x1) || !isfinite(rect.y1) || bounds[2] < 0 || bounds[3] < 0)
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid signature bounds");
            if (pdf_lookup_page_number(ctx, doc, page->obj) != index)
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "The selected signature field is on another page");
            if (bounds_in_pdf_space) {
                // Keep rotation, CropBox origins and UserUnit conversion in MuPDF.
                fz_matrix transform; fz_rect cropbox;
                pdf_page_transform(ctx, page, &cropbox, &transform);
                rect = fz_transform_rect(rect, transform);
            }
            pdf_set_annot_rect(ctx, widget, rect);
        }
        if (image_path[0]) graphic = fz_new_image_from_file(ctx, image_path);
        pdf_sign_signature(ctx, widget, signer, appearance, graphic, reason[0] ? reason : NULL, location[0] ? location : NULL);
        pdf_write_options options = pdf_default_write_options; options.do_incremental = 1;
        // Swift copied the original bytes to destination before this call.
        // Appending preserves existing signed byte ranges, as Sumatra does.
        pdf_save_document(ctx, doc, destination, &options); ok = 1;
    }
    fz_always(ctx) {
        pdf_drop_annot(ctx, widget); fz_drop_page(ctx, (fz_page *)page);
        pdf_drop_document(ctx, doc); pdf_drop_signer(ctx, signer); fz_drop_image(ctx, graphic);
    }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx); return ok;
}

// The reader's MuPDF document is the edit and save owner. These entry points
// are serialized by Pages; page/object numbers are resolved on every call so
// no pdf_annot pointer survives an undo, deletion or page-tree change.

static pdf_document *live_pdf(SumraMuPDFDocument *d) {
    pdf_document *doc = pdf_specifics(d->ctx, d->doc);
    if (!doc) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "This document is not a PDF");
    return doc;
}
API int lf_pdf_live_page_geometry(void *opaque, int page, float *matrix, float *media, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d);
        pdf_obj *object = pdf_lookup_page_obj(d->ctx, doc, page);
        fz_matrix transform, media_transform; fz_rect box;
        pdf_page_obj_transform(d->ctx, object, NULL, &transform);
        pdf_page_obj_transform_box(d->ctx, object, &box, &media_transform, FZ_MEDIA_BOX);
        matrix[0] = transform.a; matrix[1] = transform.b; matrix[2] = transform.c;
        matrix[3] = transform.d; matrix[4] = transform.e; matrix[5] = transform.f;
        media[0] = box.x0; media[1] = box.y0; media[2] = box.x1-box.x0; media[3] = box.y1-box.y0;
        ok = 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}

// EngineMupdf::PageNoFromPdfDest/GetOpenActionPageNo, zero-based here.
// Only an initial local page is returned; URI/Launch/JavaScript stay untouched.
API int lf_pdf_live_initial_page(void *opaque, int *page, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    *page = -1;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d);
        pdf_obj *dest = pdf_dict_getp(d->ctx, pdf_trailer(d->ctx, doc), "Root/OpenAction");
        if (pdf_is_dict(d->ctx, dest)) {
            pdf_obj *kind = pdf_dict_get(d->ctx, dest, PDF_NAME(S));
            if (pdf_name_eq(d->ctx, kind, PDF_NAME(GoTo))) dest = pdf_dict_get(d->ctx, dest, PDF_NAME(D));
            else {
                if (pdf_name_eq(d->ctx, kind, PDF_NAME(Named))) {
                    pdf_obj *name = pdf_dict_get(d->ctx, dest, PDF_NAME(N));
                    if (pdf_name_eq(d->ctx, name, PDF_NAME(FirstPage))) *page = 0;
                    else if (pdf_name_eq(d->ctx, name, PDF_NAME(LastPage))) *page = pdf_count_pages(d->ctx, doc)-1;
                }
                dest = NULL;
            }
        }
        if (pdf_is_name(d->ctx, dest) || pdf_is_string(d->ctx, dest)) dest = pdf_lookup_dest(d->ctx, doc, dest);
        if (pdf_is_dict(d->ctx, dest)) dest = pdf_dict_get(d->ctx, dest, PDF_NAME(D));
        if (pdf_is_array(d->ctx, dest) && pdf_array_len(d->ctx, dest)) {
            pdf_obj *object = pdf_array_get(d->ctx, dest, 0);
            *page = pdf_is_int(d->ctx, object) ? pdf_to_int(d->ctx, object) : pdf_lookup_page_number(d->ctx, doc, object);
        }
        if (*page < 0 || *page >= pdf_count_pages(d->ctx, doc)) *page = -1;
        ok = 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
static void live_text_lines(fz_context *ctx, fz_stext_block *block, SumraJSON *json, int *first) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down)
            live_text_lines(ctx, block->u.s.down->first_block, json, first);
        else if (block->type == FZ_STEXT_BLOCK_TEXT) {
            for (fz_stext_line *line = block->u.t.first_line; line; line = line->next) {
                fz_buffer *text = fz_new_buffer(ctx, 128);
                fz_try(ctx) {
                    for (fz_stext_char *ch = line->first_char; ch; ch = ch->next) fz_append_rune(ctx, text, ch->c);
                    if (!*first) lf_json(json, ","); *first = 0;
                    lf_json(json, "{\"text\":"); lf_json_string(json, fz_string_from_buffer(ctx, text));
                    lf_json(json, ",\"rect\":"); lf_json_rect(json, line->bbox.x0, line->bbox.y0, line->bbox.x1-line->bbox.x0, line->bbox.y1-line->bbox.y0);
                    lf_json(json, "}");
                }
                fz_always(ctx) { fz_drop_buffer(ctx, text); }
                fz_catch(ctx) { fz_rethrow(ctx); }
            }
        }
    }
}
// GenerateTocFromHeadings consumes physical structured-text lines, not the
// flattened paragraph stream used by selection and speech.
API char *lf_pdf_live_text_lines(void *opaque, int number, char *error) {
    SumraMuPDFDocument *d = opaque; fz_page *page = NULL; fz_stext_page *text = NULL; SumraJSON json = {0};
    fz_var(page); fz_var(text); fz_var(json);
    fz_try(d->ctx) {
        (void)live_pdf(d);
        page = fz_load_page(d->ctx, d->doc, number);
        text = fz_new_stext_page_from_page(d->ctx, page, NULL);
        int first = 1;
        lf_json(&json, "["); live_text_lines(d->ctx, text->first_block, &json, &first); lf_json(&json, "]");
    }
    fz_always(d->ctx) { fz_drop_stext_page(d->ctx, text); fz_drop_page(d->ctx, page); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}
static void live_editable(SumraMuPDFDocument *d, pdf_document *doc, fz_permission permission) {
    if (!d->editing_enabled) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Enable PDF editing first");
    if (!pdf_has_permission(d->ctx, doc, permission))
        fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "This PDF does not permit this edit");
}
static void live_begin(SumraMuPDFDocument *d, pdf_document *doc, const char *title) {
    if (!d->journal_nesting) { int steps; d->journal_start_position = pdf_undoredo_state(d->ctx, doc, &steps); }
    pdf_begin_operation(d->ctx, doc, title);
    ++d->journal_nesting;
}
static void live_end(SumraMuPDFDocument *d, pdf_document *doc) {
    if (d->journal_nesting <= 0) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "No PDF edit is in progress");
    if (d->journal_nesting == 1) {
        // MuPDF prepare_for_save's deferred work belongs to the edit that
        // caused it; a later Save Copy must not run scripts or discard redo.
        if (doc->recalculate) pdf_calculate_form(d->ctx, doc);
        if (doc->resynth_required) pdf_update_open_pages(d->ctx, doc);
    }
    pdf_end_operation(d->ctx, doc);
    if (!--d->journal_nesting) {
        int steps, position = pdf_undoredo_state(d->ctx, doc, &steps);
        if (position != d->journal_start_position && d->journal_start_position < d->saved_journal_position)
            d->saved_journal_position = -1;
    }
    lf_drop_render_page(d);
}
static void live_abort(SumraMuPDFDocument *d, pdf_document *doc) {
    if (d->journal_nesting <= 0) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "No PDF edit is in progress");
    pdf_abandon_operation(d->ctx, doc); --d->journal_nesting;
    if (!d->journal_nesting) {
        int steps; pdf_undoredo_state(d->ctx, doc, &steps);
        // MuPDF discards the redo branch on the first mutation; abandoning
        // restores the objects, but cannot restore a saved point on that branch.
        if (d->saved_journal_position > steps) d->saved_journal_position = -1;
    }
    // Abandon swaps journal fragments but, unlike pdf_undo, does not resync
    // open pages or purge resources keyed by object numbers it may roll back.
    lf_drop_render_page(d);
    pdf_sync_open_pages(d->ctx, doc); pdf_empty_store(d->ctx, doc);
}
API int lf_pdf_live_set_editing(void *opaque, int enabled, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d);
        if (d->journal_nesting) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Finish the current PDF edit first");
        if (enabled && !pdf_has_permission(d->ctx, doc, FZ_PERMISSION_ANNOTATE) &&
            !pdf_has_permission(d->ctx, doc, FZ_PERMISSION_FORM) && !pdf_has_permission(d->ctx, doc, FZ_PERMISSION_EDIT))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "This PDF does not permit editing");
        d->editing_enabled = !!enabled; ok = 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
API int lf_pdf_live_begin(void *opaque, const char *title, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d);
        if (!d->editing_enabled) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Enable PDF editing first");
        live_begin(d, doc, title); ok = 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
API int lf_pdf_live_end(void *opaque, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) { live_end(d, live_pdf(d)); ok = 1; }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
API int lf_pdf_live_abort(void *opaque, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) { live_abort(d, live_pdf(d)); ok = 1; }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
API int lf_pdf_live_undo(void *opaque, int redo, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d);
        if (!d->editing_enabled) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Enable PDF editing first");
        // EngineMupdfUndoRedo checks the live journal before stepping. Key
        // repeats can arrive after the UI's last available step was consumed.
        if (redo ? pdf_can_redo(d->ctx, doc) : pdf_can_undo(d->ctx, doc)) {
            if (redo) pdf_redo(d->ctx, doc); else pdf_undo(d->ctx, doc);
        }
        // EngineMupdf::SyncPagesAfterUndoRedo: live annotation references and
        // cached drawing commands must be discarded after journal restoration.
        lf_drop_render_page(d); ok = 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
// Validate the actual retained input, including after its pathname is replaced
// or unlinked. This reads the same stream used by the incremental writer.
API int lf_pdf_live_source_digest(void *opaque, unsigned char *digest, int (*cancelled)(void), char *error) {
    SumraMuPDFDocument *d = opaque;
    fz_stream *stream = NULL; int64_t position = -1; int ok = 0;
    fz_var(stream); fz_var(position); fz_var(ok);
    error[0] = 0;
    fz_try(d->ctx) {
        stream = live_pdf(d)->file;
        if (!stream || !stream->seek)
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Cannot verify the retained PDF input stream");
        if (stream->error) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "The PDF input stream has a read error");
        position = fz_tell(d->ctx, stream);
        fz_try(d->ctx) {
            unsigned char buffer[65536]; fz_sha256 hash;
            fz_sha256_init(&hash);
            fz_seek(d->ctx, stream, 0, SEEK_SET);
            for (;;) {
                if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF input verification cancelled");
                size_t count = fz_read(d->ctx, stream, buffer, sizeof(buffer));
                // fz_available reports a failed read as EOF and sets this flag.
                if (stream->error) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "The PDF input stream has a read error");
                if (!count) break;
                fz_sha256_update(&hash, buffer, count);
            }
            fz_sha256_final(&hash, digest); ok = 1;
        }
        fz_catch(d->ctx) {
            ok = fz_caught(d->ctx) == FZ_ERROR_ABORT ? -1 : 0;
            snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL));
        }
    }
    fz_always(d->ctx) {
        if (stream && position >= 0) {
            fz_try(d->ctx) { fz_seek(d->ctx, stream, position, SEEK_SET); }
            fz_catch(d->ctx) {
                size_t length = strlen(error);
                snprintf(error + length, 512 - length, "%sCannot restore the PDF input stream: %s",
                    length ? "\n" : "", fz_convert_error(d->ctx, NULL));
                ok = 0;
            }
        }
    }
    fz_catch(d->ctx) {
        ok = fz_caught(d->ctx) == FZ_ERROR_ABORT ? -1 : 0;
        snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL));
    }
    return ok;
}

// Returns 1 for an incremental snapshot, 2 for a full snapshot. Like Sumatra's
// SaveUpdatedPdf, the latter must be reopened after committing an ordinary
// Save. Save Copy keeps the live document and never changes its save point.
API int lf_pdf_live_write(void *opaque, const char *destination, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d);
        if (d->journal_nesting) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Finish the current PDF edit first");
        if (pdf_has_unsaved_sigs(d->ctx, doc))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Finish the pending PDF signature before saving");
        // The actor writes a sibling temporary file and replaces the target
        // only after this succeeds. Snapshot preserves the original base and
        // journal. The snapshot writer emits new/repaired documents in full,
        // without finalizing their live xref or rewriting encryption/streams.
        // Applied redactions still belong to the garbage-collected file tool.
        int full = !doc->file || doc->repair_attempted;
        pdf_save_snapshot(d->ctx, doc, destination); ok = full ? 2 : 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
// Signing is an output operation: keep the live journal and signed source
// bytes intact if identity access, the writer, or final replacement fails.
// The short-lived output is then completed by the same AppleSigner and MuPDF
// incremental writer used by PdfSign.cpp, never a second editing owner.
API int lf_pdf_live_signing_snapshot(void *opaque, const char *destination, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d);
        live_editable(d, doc, FZ_PERMISSION_FORM);
        if (!doc->file || !pdf_can_be_saved_incrementally(d->ctx, doc))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "This PDF needs a full save and reopen before it can be signed incrementally");
        ok = lf_pdf_live_write(opaque, destination, error);
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
API int lf_pdf_live_mark_saved(void *opaque, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        pdf_document *doc = live_pdf(d); int steps;
        if (d->journal_nesting) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Finish the current PDF edit first");
        // Called only after the same actor's atomic replacement has succeeded;
        // Save Copy and failed writes leave the existing save point untouched.
        d->saved_journal_position = pdf_undoredo_state(d->ctx, doc, &steps); ok = 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
static pdf_annot *live_annotation(fz_context *ctx, pdf_page *page, int number) {
    for (pdf_annot *a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a))
        if (pdf_to_num(ctx, pdf_annot_obj(ctx, a)) == number) return a;
    for (pdf_annot *a = pdf_first_widget(ctx, page); a; a = pdf_next_widget(ctx, a))
        if (pdf_to_num(ctx, pdf_annot_obj(ctx, a)) == number) return a;
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "The PDF annotation no longer exists");
}
API void *lf_pdf_live_xmp(void *opaque, size_t *length, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    fz_buffer *buffer = NULL; void *result = NULL; *length = 0;
    fz_var(buffer); fz_var(result);
    fz_try(ctx) {
        pdf_document *doc = live_pdf(d);
        pdf_obj *metadata = pdf_dict_getp(ctx, pdf_trailer(ctx, doc), "Root/Metadata");
        if (metadata) {
            buffer = pdf_load_stream(ctx, metadata);
            unsigned char *bytes; size_t count = fz_buffer_storage(ctx, buffer, &bytes);
            result = malloc(count ? count : 1);
            if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate XMP metadata");
            if (count) memcpy(result, bytes, count);
            *length = count;
        }
    }
    fz_always(ctx) { fz_drop_buffer(ctx, buffer); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(result); *length = 0; return NULL; }
    return result;
}
typedef void (*LiveAttachmentOutput)(void *, const char *, const char *, const unsigned char *, size_t);
static void live_export_filespec(fz_context *ctx, pdf_obj *filespec, pdf_obj *seen,
                                LiveAttachmentOutput output, void *opaque) {
    pdf_obj *files = pdf_dict_get(ctx, filespec, PDF_NAME(EF));
    pdf_obj *keys[] = {PDF_NAME(UF), PDF_NAME(F), PDF_NAME(DOS), PDF_NAME(Mac), PDF_NAME(Unix)};
    for (int i = 0; i < 5; ++i) {
        pdf_obj *stream = pdf_dict_get(ctx, files, keys[i]);
        if (!pdf_is_stream(ctx, stream) || pdf_array_contains(ctx, seen, stream)) continue;
        fz_buffer *buffer = NULL; fz_var(buffer);
        fz_try(ctx) {
            pdf_array_push(ctx, seen, stream);
            buffer = pdf_load_stream(ctx, stream);
            unsigned char *bytes; size_t count = fz_buffer_storage(ctx, buffer, &bytes);
            pdf_obj *name = pdf_dict_get(ctx, filespec, keys[i]);
            if (!name) name = pdf_dict_geta(ctx, filespec, PDF_NAME(UF), PDF_NAME(F));
            pdf_obj *description = pdf_dict_get(ctx, filespec, PDF_NAME(Desc));
            output(opaque, name ? pdf_to_text_string(ctx, name) : "attachment",
                   description ? pdf_to_text_string(ctx, description) : NULL, bytes, count);
        }
        fz_always(ctx) { fz_drop_buffer(ctx, buffer); }
        fz_catch(ctx) { fz_rethrow(ctx); }
    }
}
API int lf_pdf_live_attachments(void *opaque, LiveAttachmentOutput output, void *user, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_obj *names = NULL, *seen = NULL; int ok = 0;
    fz_var(names); fz_var(seen); fz_var(ok);
    fz_try(ctx) {
        pdf_document *doc = live_pdf(d);
        if (!pdf_has_permission(ctx, doc, FZ_PERMISSION_COPY))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF does not permit copying attachments");
        seen = pdf_new_array(ctx, doc, 8);
        // EngineMupdf::PdfLoadAttachments delegates name-tree traversal to MuPDF.
        names = pdf_load_name_tree(ctx, doc, PDF_NAME(EmbeddedFiles));
        for (int i = 0, n = pdf_dict_len(ctx, names); i < n; ++i)
            live_export_filespec(ctx, pdf_dict_get_val(ctx, names, i), seen, output, user);
        // Retain the existing export coverage for associated files and page
        // attachments, de-duplicating shared streams across all containers.
        for (int page = -1, count = pdf_count_pages(ctx, doc); page < count; ++page) {
            pdf_obj *object = page < 0 ? pdf_dict_get(ctx, pdf_trailer(ctx, doc), PDF_NAME(Root)) : pdf_lookup_page_obj(ctx, doc, page);
            pdf_obj *associated = pdf_dict_get(ctx, object, PDF_NAME(AF));
            for (int i = 0, n = pdf_array_len(ctx, associated); i < n; ++i)
                live_export_filespec(ctx, pdf_array_get(ctx, associated, i), seen, output, user);
            if (page < 0) continue;
            pdf_obj *annotations = pdf_dict_get(ctx, object, PDF_NAME(Annots));
            for (int i = 0, n = pdf_array_len(ctx, annotations); i < n; ++i)
                live_export_filespec(ctx, pdf_dict_get(ctx, pdf_array_get(ctx, annotations, i), PDF_NAME(FS)), seen, output, user);
        }
        ok = 1;
    }
    fz_always(ctx) { pdf_drop_obj(ctx, names); pdf_drop_obj(ctx, seen); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    return ok;
}
API void *lf_pdf_live_attachment(void *opaque, int page_number, int object_number,
                                 size_t *length, char **name, char **description, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_page *page = NULL; fz_buffer *contents = NULL; void *result = NULL;
    *length = 0; *name = NULL; *description = NULL;
    fz_var(page); fz_var(contents); fz_var(result);
    fz_try(ctx) {
        pdf_document *doc = live_pdf(d);
        if (!pdf_has_permission(ctx, doc, FZ_PERMISSION_COPY))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF does not permit copying attachments");
        page = pdf_load_page(ctx, doc, page_number);
        pdf_annot *annot = live_annotation(ctx, page, object_number);
        pdf_obj *filespec = pdf_annot_filespec(ctx, annot);
        pdf_filespec_params params;
        pdf_get_filespec_params(ctx, filespec, &params);
        contents = pdf_load_embedded_file_contents(ctx, filespec);
        if (!contents) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This annotation has no embedded file");
        unsigned char *bytes; size_t count = fz_buffer_storage(ctx, contents, &bytes);
        result = malloc(count ? count : 1);
        *name = strdup(params.filename ? params.filename : "attachment");
        pdf_obj *desc = pdf_dict_get(ctx, filespec, PDF_NAME(Desc));
        if (desc) *description = strdup(pdf_to_text_string(ctx, desc));
        if (!result || !*name || (desc && !*description))
            fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate attachment");
        if (count) memcpy(result, bytes, count);
        *length = count;
    }
    fz_always(ctx) { fz_drop_buffer(ctx, contents); fz_drop_page(ctx, (fz_page *)page); }
    fz_catch(ctx) {
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL));
        free(result); free(*name); free(*description); *name = NULL; *description = NULL; *length = 0;
        return NULL;
    }
    return result;
}
// Annotation.cpp::GetStampImage: copy the image asset, not the page or /AP
// object graph. MuPDF's draw device also preserves an independent soft mask.
API void *lf_pdf_live_stamp_image(void *opaque, int page_number, int object_number, size_t *length, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_page *page = NULL; fz_image *image = NULL; fz_pixmap *pixmap = NULL;
    fz_device *device = NULL; fz_buffer *buffer = NULL; void *result = NULL;
    *length = 0;
    fz_var(page); fz_var(image); fz_var(pixmap); fz_var(device); fz_var(buffer); fz_var(result);
    fz_try(ctx) {
        pdf_document *doc = live_pdf(d);
        if (!pdf_has_permission(ctx, doc, FZ_PERMISSION_COPY))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This PDF does not permit copying images");
        page = pdf_load_page(ctx, doc, page_number);
        pdf_annot *annot = live_annotation(ctx, page, object_number);
        if (pdf_annot_type(ctx, annot) == PDF_ANNOT_STAMP) {
            pdf_obj *asset = pdf_annot_stamp_image_obj(ctx, annot);
            if (!asset && !pdf_annot_is_standard_stamp(ctx, annot))
                fz_throw(ctx, FZ_ERROR_UNSUPPORTED, "Copying this stamp's custom vector artwork is not supported");
            if (asset) {
                image = pdf_load_image(ctx, doc, asset);
                if (image->w <= 0 || image->h <= 0)
                    fz_throw(ctx, FZ_ERROR_LIMIT, "Stamp image is too large");
                pixmap = fz_new_pixmap(ctx, fz_device_rgb(ctx), image->w, image->h, NULL, 1);
                fz_clear_pixmap(ctx, pixmap);
                device = fz_new_draw_device(ctx, fz_identity, pixmap);
                fz_matrix ctm = fz_scale(image->w, image->h);
                // pdf-op-run.c::pdf_show_image applies the separate mask as
                // a clip; fill_image alone intentionally does not consume it.
                if (image->mask) fz_clip_image_mask(ctx, device, image->mask, ctm, fz_make_rect(0, 0, image->w, image->h));
                fz_fill_image(ctx, device, image, ctm, 1, fz_default_color_params);
                if (image->mask) fz_pop_clip(ctx, device);
                fz_close_device(ctx, device);
                buffer = fz_new_buffer_from_pixmap_as_png(ctx, pixmap, fz_default_color_params);
                unsigned char *bytes; size_t count = fz_buffer_storage(ctx, buffer, &bytes);
                if (!count) fz_throw(ctx, FZ_ERROR_FORMAT, "Stamp image is empty");
                result = malloc(count);
                if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate stamp image");
                memcpy(result, bytes, count); *length = count;
            }
        }
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buffer); fz_drop_device(ctx, device); fz_drop_pixmap(ctx, pixmap);
        fz_drop_image(ctx, image); fz_drop_page(ctx, (fz_page *)page);
    }
    fz_catch(ctx) {
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(result); *length = 0; return NULL;
    }
    return result;
}
static fz_rect live_rect(fz_context *ctx, const float *r) {
    if (!r || !isfinite(r[0]) || !isfinite(r[1]) || !isfinite(r[2]) || !isfinite(r[3]) || r[2] < 0 || r[3] < 0)
        fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid annotation rectangle");
    return fz_make_rect(r[0], r[1], r[0] + r[2], r[1] + r[3]);
}

static pdf_link *live_link(fz_context *ctx, pdf_page *page, int object_number) {
    pdf_obj *annots = pdf_dict_get(ctx, page->obj, PDF_NAME(Annots));
    for (int i = 0, n = pdf_array_len(ctx, annots); i < n; ++i) {
        pdf_obj *obj = pdf_array_get(ctx, annots, i);
        if (pdf_to_num(ctx, obj) != object_number || !pdf_name_eq(ctx, pdf_dict_get(ctx, obj, PDF_NAME(Subtype)), PDF_NAME(Link))) continue;
        if (pdf_dict_get_int(ctx, obj, PDF_NAME(F)) & (PDF_ANNOT_IS_READ_ONLY | PDF_ANNOT_IS_LOCKED))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This link is locked");
        for (fz_link *link = page->links; link; link = link->next)
            if (pdf_obj_parent_num(ctx, ((pdf_link *)link)->obj) == object_number) return (pdf_link *)link;
        // MuPDF's URI loader omits links whose only action is JavaScript.
        // Bind the existing dictionary with its upstream link constructor so
        // those links can still be moved, retargeted or deleted.
        fz_rect box; fz_matrix ctm; pdf_page_transform(ctx, page, &box, &ctm);
        fz_link *link = pdf_new_link(ctx, page, fz_transform_rect(pdf_dict_get_rect(ctx, obj, PDF_NAME(Rect)), ctm), "", obj);
        link->next = page->links; page->links = link;
        return (pdf_link *)link;
    }
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "This link no longer exists");
}
API int lf_pdf_live_create_link(void *opaque, int page_number, const float *rect, const char *uri, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_document *doc = NULL; pdf_page *page = NULL; fz_link *link = NULL; int begun = 0, id = 0;
    fz_var(doc); fz_var(page); fz_var(link); fz_var(begun); fz_var(id);
    fz_try(ctx) {
        doc = live_pdf(d); live_editable(d, doc, FZ_PERMISSION_ANNOTATE);
        if (!uri || !*uri) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Missing link destination");
        live_begin(d, doc, "Add link"); begun = 1;
        page = pdf_load_page(ctx, doc, page_number);
        link = pdf_create_link(ctx, page, live_rect(ctx, rect), uri);
        id = pdf_obj_parent_num(ctx, ((pdf_link *)link)->obj);
        // The constructor retains a direct dictionary; reload its indirect
        // /Annots reference for pdf_delete_link's identity comparison.
        pdf_sync_open_pages(ctx, doc);
        live_end(d, doc); begun = 0;
    }
    fz_always(ctx) { fz_drop_link(ctx, link); fz_drop_page(ctx, (fz_page *)page); }
    fz_catch(ctx) {
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); id = 0;
        if (begun) { fz_try(ctx) { live_abort(d, doc); } fz_catch(ctx) { fz_report_error(ctx); } }
    }
    return id;
}
API int lf_pdf_live_edit_link(void *opaque, int page_number, int object_number, const float *rect, const char *uri, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_document *doc = NULL; pdf_page *page = NULL; int begun = 0, ok = 0;
    fz_var(doc); fz_var(page); fz_var(begun); fz_var(ok);
    fz_try(ctx) {
        doc = live_pdf(d); live_editable(d, doc, FZ_PERMISSION_ANNOTATE);
        if (uri && !*uri) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Missing link destination");
        live_begin(d, doc, "Edit link"); begun = 1;
        page = pdf_load_page(ctx, doc, page_number);
        pdf_link *link = live_link(ctx, page, object_number);
        fz_rect box; fz_matrix transform; pdf_page_transform(ctx, page, &box, &transform);
        // pdf_create_link accepts page coordinates; its rect setter writes
        // the PDF dictionary directly, so convert with the same page matrix.
        fz_set_link_rect(ctx, &link->super, fz_transform_rect(live_rect(ctx, rect), fz_invert_matrix(transform)));
        // A nil URI moves the existing action, including actions that have
        // no URI representation (JavaScript, ResetForm and their /Next chain).
        if (uri && strcmp(link->super.uri, uri)) {
            fz_set_link_uri(ctx, &link->super, uri);
            pdf_dict_del(ctx, link->obj, PDF_NAME(Dest));
        }
        pdf_sync_open_pages(ctx, doc);
        live_end(d, doc); begun = 0; ok = 1;
    }
    fz_always(ctx) { fz_drop_page(ctx, (fz_page *)page); }
    fz_catch(ctx) {
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL));
        if (begun) { fz_try(ctx) { live_abort(d, doc); } fz_catch(ctx) { fz_report_error(ctx); } }
    }
    return ok;
}
API int lf_pdf_live_delete_link(void *opaque, int page_number, int object_number, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_document *doc = NULL; pdf_page *page = NULL; int begun = 0, ok = 0;
    fz_var(doc); fz_var(page); fz_var(begun); fz_var(ok);
    fz_try(ctx) {
        doc = live_pdf(d); live_editable(d, doc, FZ_PERMISSION_ANNOTATE);
        live_begin(d, doc, "Delete link"); begun = 1;
        page = pdf_load_page(ctx, doc, page_number);
        pdf_delete_link(ctx, page, &live_link(ctx, page, object_number)->super);
        live_end(d, doc); begun = 0; ok = 1;
    }
    fz_always(ctx) { fz_drop_page(ctx, (fz_page *)page); }
    fz_catch(ctx) {
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL));
        if (begun) { fz_try(ctx) { live_abort(d, doc); } fz_catch(ctx) { fz_report_error(ctx); } }
    }
    return ok;
}

// Shared transaction boilerplate only; each exported operation calls the
// corresponding MuPDF setter directly, with no command dictionary or parser.
#define LIVE_ANNOT_BEGIN(permission, title) \
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx; \
    pdf_document *doc = NULL; pdf_page *page = NULL; int begun = 0, ok = 0; \
    fz_var(doc); fz_var(page); fz_var(begun); fz_var(ok); \
    fz_try(ctx) { \
        doc = live_pdf(d); live_editable(d, doc, permission); \
        live_begin(d, doc, title); begun = 1; \
        page = pdf_load_page(ctx, doc, page_number); \
        pdf_annot *annot = live_annotation(ctx, page, object_number); \
        if (permission == FZ_PERMISSION_ANNOTATE && pdf_annot_type(ctx, annot) == PDF_ANNOT_WIDGET) \
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Use the form controls to edit fields"); \
        if (permission == FZ_PERMISSION_ANNOTATE && \
            (pdf_annot_flags(ctx, annot) & (PDF_ANNOT_IS_READ_ONLY | PDF_ANNOT_IS_LOCKED))) \
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This annotation is locked");
#define LIVE_ANNOT_END \
        live_end(d, doc); begun = 0; ok = 1; \
    } \
    fz_always(ctx) { fz_drop_page(ctx, (fz_page *)page); } \
    fz_catch(ctx) { \
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); \
        if (begun) { fz_try(ctx) { live_abort(d, doc); } fz_catch(ctx) { fz_report_error(ctx); } } \
    } \
    return ok;

API int lf_pdf_live_create(void *opaque, int page_number, const char *type, const float *rect, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_document *doc = NULL; pdf_page *page = NULL; pdf_annot *annot = NULL; int begun = 0, number = 0;
    fz_var(doc); fz_var(page); fz_var(annot); fz_var(begun); fz_var(number);
    fz_try(ctx) {
        doc = live_pdf(d); live_editable(d, doc, FZ_PERMISSION_ANNOTATE);
        enum pdf_annot_type kind = pdf_annot_type_from_string(ctx, type);
        if (kind == PDF_ANNOT_UNKNOWN || kind == PDF_ANNOT_WIDGET || kind == PDF_ANNOT_LINK || kind == PDF_ANNOT_POPUP)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This annotation type uses its own PDF tool");
        fz_rect bounds = live_rect(ctx, rect);
        live_begin(d, doc, "Add annotation"); begun = 1;
        page = pdf_load_page(ctx, doc, page_number);
        annot = pdf_create_annot(ctx, page, kind);
        // Geometry-backed types are populated by their public setters below,
        // inside the caller's outer placement transaction.
        if (pdf_annot_has_rect(ctx, annot)) pdf_set_annot_rect(ctx, annot, bounds);
        pdf_update_annot(ctx, annot);
        number = pdf_to_num(ctx, pdf_annot_obj(ctx, annot));
        live_end(d, doc); begun = 0;
    }
    fz_always(ctx) { pdf_drop_annot(ctx, annot); fz_drop_page(ctx, (fz_page *)page); }
    fz_catch(ctx) {
        snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); number = 0;
        if (begun) { fz_try(ctx) { live_abort(d, doc); } fz_catch(ctx) { fz_report_error(ctx); } }
    }
    return number;
}
API int lf_pdf_live_delete(void *opaque, int page_number, int object_number, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Delete annotation")
    pdf_delete_annot(ctx, page, annot);
    LIVE_ANNOT_END
}
// Annotation.cpp::SetRect translates geometry-backed annotations instead of
// rewriting their Rect, which MuPDF correctly rejects for these subtypes.
static void live_move_annot(fz_context *ctx, pdf_annot *annot, float dx, float dy) {
    fz_point *points = NULL; fz_quad *quads = NULL; int *counts = NULL;
    fz_var(points); fz_var(quads); fz_var(counts);
    fz_matrix transform = fz_translate(dx, dy);
    fz_try(ctx) {
        if (pdf_annot_has_line(ctx, annot)) {
            fz_point a, b; pdf_annot_line(ctx, annot, &a, &b);
            pdf_set_annot_line(ctx, annot, fz_transform_point(a, transform), fz_transform_point(b, transform));
        } else if (pdf_annot_has_vertices(ctx, annot)) {
            int count = pdf_annot_vertex_count(ctx, annot);
            points = fz_malloc_array(ctx, count, fz_point);
            for (int i = 0; i < count; ++i) points[i] = fz_transform_point(pdf_annot_vertex(ctx, annot, i), transform);
            pdf_set_annot_vertices(ctx, annot, count, points);
        } else if (pdf_annot_has_quad_points(ctx, annot) && pdf_annot_quad_point_count(ctx, annot)) {
            int count = pdf_annot_quad_point_count(ctx, annot);
            quads = fz_malloc_array(ctx, count, fz_quad);
            for (int i = 0; i < count; ++i) quads[i] = fz_transform_quad(pdf_annot_quad_point(ctx, annot, i), transform);
            pdf_set_annot_quad_points(ctx, annot, count, quads);
        } else if (pdf_annot_has_ink_list(ctx, annot)) {
            int strokes = pdf_annot_ink_list_count(ctx, annot), total = 0;
            counts = fz_malloc_array(ctx, strokes, int);
            for (int i = 0; i < strokes; ++i) {
                counts[i] = pdf_annot_ink_list_stroke_count(ctx, annot, i);
                if (counts[i] > INT_MAX-total) fz_throw(ctx, FZ_ERROR_LIMIT, "Too many ink points");
                total += counts[i];
            }
            points = fz_malloc_array(ctx, total, fz_point); total = 0;
            for (int i = 0; i < strokes; ++i) for (int j = 0; j < counts[i]; ++j)
                points[total++] = fz_transform_point(pdf_annot_ink_list_stroke_vertex(ctx, annot, i, j), transform);
            pdf_set_annot_ink_list(ctx, annot, strokes, counts, points);
        } else {
            // The getter reads local display appearances, whereas the setter
            // edits the original graph. Discard the local xref just as MuPDF's
            // first object alteration does, before reading its design rectangle
            // (a synthesized RD must not shrink the original on the first move).
            pdf_drop_local_xref_and_resources(ctx, pdf_get_bound_document(ctx, pdf_annot_obj(ctx, annot)));
            pdf_set_annot_rect(ctx, annot, fz_transform_rect(pdf_annot_rect(ctx, annot), transform));
        }
    }
    fz_always(ctx) { fz_free(ctx, points); fz_free(ctx, quads); fz_free(ctx, counts); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
API int lf_pdf_live_move(void *opaque, int page_number, int object_number, float dx, float dy, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Move annotation")
    if (!isfinite(dx) || !isfinite(dy)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid annotation position");
    live_move_annot(ctx, annot, dx, dy); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_rect(void *opaque, int page_number, int object_number, const float *rect, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Resize annotation")
    fz_rect target = live_rect(ctx, rect);
    if (pdf_annot_has_line(ctx, annot) || pdf_annot_has_vertices(ctx, annot) || pdf_annot_has_ink_list(ctx, annot) ||
        (pdf_annot_has_quad_points(ctx, annot) && pdf_annot_quad_point_count(ctx, annot))) {
        fz_rect original = pdf_bound_annot(ctx, annot);
        live_move_annot(ctx, annot, target.x0 - original.x0, target.y0 - original.y0);
    } else pdf_set_annot_rect(ctx, annot, target);
    pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_contents(void *opaque, int page_number, int object_number, const char *text, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Edit annotation text")
    if (pdf_annot_flags(ctx, annot) & PDF_ANNOT_IS_LOCKED_CONTENTS)
        fz_throw(ctx, FZ_ERROR_ARGUMENT, "This annotation's contents are locked");
    pdf_set_annot_contents(ctx, annot, text); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_color(void *opaque, int page_number, int object_number, int interior, int count, const float *color, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation color")
    if (count != 0 && count != 3) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Expected an RGB annotation color");
    if (interior) pdf_set_annot_interior_color(ctx, annot, count, color); else pdf_set_annot_color(ctx, annot, count, color);
    pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_opacity(void *opaque, int page_number, int object_number, float opacity, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation opacity")
    if (!isfinite(opacity) || opacity < 0 || opacity > 1) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid opacity");
    if (pdf_annot_type(ctx, annot) == PDF_ANNOT_STAMP && !pdf_annot_is_standard_stamp(ctx, annot))
        fz_throw(ctx, FZ_ERROR_UNSUPPORTED, "Opacity editing is unavailable for this stamp's custom vector appearance");
    pdf_set_annot_opacity(ctx, annot, opacity); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_border(void *opaque, int page_number, int object_number, float width, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation border")
    if (!isfinite(width) || width < 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid border width");
    pdf_set_annot_border_width(ctx, annot, width); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_quads(void *opaque, int page_number, int object_number, int count, const float *points, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation selection")
    if (count < 0 || (count && !points)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid annotation quadrilaterals");
    pdf_set_annot_quad_points(ctx, annot, count, (const fz_quad *)points); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_vertices(void *opaque, int page_number, int object_number, int count, const float *points, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation vertices")
    if (count < 2 || !points) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Expected at least two vertices");
    pdf_set_annot_vertices(ctx, annot, count, (const fz_point *)points); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_ink(void *opaque, int page_number, int object_number, int strokes, const int *counts, const float *points, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Draw ink")
    if (strokes < 0 || (strokes && (!counts || !points))) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid ink strokes");
    for (int i = 0; i < strokes; ++i) if (counts[i] <= 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Empty ink stroke");
    pdf_set_annot_ink_list(ctx, annot, strokes, counts, (const fz_point *)points); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_line(void *opaque, int page_number, int object_number, const float *points, int start, int end, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation line")
    if (!points) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Missing line endpoints");
    pdf_set_annot_line(ctx, annot, fz_make_point(points[0], points[1]), fz_make_point(points[2], points[3]));
    pdf_set_annot_line_ending_styles(ctx, annot, start, end); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_line_ends(void *opaque, int page_number, int object_number, int start, int end, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change line endings")
    pdf_set_annot_line_ending_styles(ctx, annot, start, end); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
// Annotation.cpp::ReadFreeTextFontLocked/WriteFreeTextFontLocked, using the
// already-linked MuPDF CSS parser instead of copying Sumatra's CSS lexer.
static int live_font_bold(const char *s) { return !strcasecmp(s, "bold") || !strcasecmp(s, "bolder") || atoi(s) >= 600; }
static int live_font_italic(const char *s) { return !strcasecmp(s, "italic") || !strcasecmp(s, "oblique"); }
static void live_read_font(fz_context *ctx, pdf_annot *annot, char **family, int *style) {
    const char *font; float size, color[4]; int n;
    pdf_annot_default_appearance(ctx, annot, &font, &size, &n, color);
    *family = fz_strdup(ctx, font && !strcasecmp(font, "Cour") ? "Courier" : font && !strcasecmp(font, "TiRo") ? "Times" : "Helvetica");
    *style = 0;
    fz_pool *pool = NULL; fz_buffer *name = NULL;
    fz_var(pool); fz_var(name);
    fz_try(ctx) {
        pool = fz_new_pool(ctx);
        for (fz_css_property *p = fz_parse_css_properties(ctx, pool, pdf_annot_rich_defaults(ctx, annot)); p; p = p->next) {
            if (p->name == PRO_FONT_FAMILY || p->name == PRO_FONT) {
                name = fz_new_buffer(ctx, 32);
                for (fz_css_value *v = p->value; v; v = v->next) {
                    if (!strcmp(v->data, ",")) break;
                    if (p->name == PRO_FONT) {
                        if (live_font_bold(v->data)) { *style |= 1; continue; }
                        if (live_font_italic(v->data)) { *style |= 2; continue; }
                        if (v->type != CSS_KEYWORD && v->type != CSS_STRING) continue;
                        if (!strcasecmp(v->data, "normal") || !strcasecmp(v->data, "small-caps")) continue;
                    }
                    if (fz_buffer_storage(ctx, name, NULL)) fz_append_byte(ctx, name, ' ');
                    fz_append_string(ctx, name, v->data);
                }
                if (fz_buffer_storage(ctx, name, NULL)) {
                    char *replacement = fz_strdup(ctx, fz_string_from_buffer(ctx, name));
                    fz_free(ctx, *family); *family = replacement;
                }
                fz_drop_buffer(ctx, name); name = NULL;
            } else for (fz_css_value *v = p->value; v; v = v->next) {
                if (p->name == PRO_FONT_WEIGHT && live_font_bold(v->data)) *style |= 1;
                if (p->name == PRO_FONT_STYLE && live_font_italic(v->data)) *style |= 2;
                if (p->name == PRO_TEXT_DECORATION && !strcasecmp(v->data, "underline")) *style |= 4;
            }
        }
    }
    fz_always(ctx) { fz_drop_buffer(ctx, name); fz_drop_pool(ctx, pool); }
    fz_catch(ctx) {
        if (fz_caught(ctx) != FZ_ERROR_SYNTAX) fz_rethrow(ctx);
        fz_ignore_error(ctx); // A malformed optional /DS still has its /DA fallback.
    }
}
static int live_custom_font(const char *family, int style) {
    return style || (strcasecmp(family, "Courier") && strcasecmp(family, "Helvetica") && strcasecmp(family, "Times"));
}
static void live_write_font(fz_context *ctx, pdf_annot *annot, const char *family, int style) {
    const char *font; float size, color[4], rgb[3] = {0}; int n;
    pdf_annot_default_appearance(ctx, annot, &font, &size, &n, color);
    pdf_set_annot_default_appearance(ctx, annot, !strcasecmp(family, "Courier") ? "Cour" : !strcasecmp(family, "Times") ? "TiRo" : "Helv", size, n, color);
    if (!live_custom_font(family, style)) return;
    fz_buffer *css = fz_new_buffer(ctx, 128);
    fz_try(ctx) {
        fz_append_string(ctx, css, "font-family:'");
        for (const char *p = family; *p; ++p) if (!strchr("'\";{}", *p)) fz_append_byte(ctx, css, *p);
        if (n) fz_convert_color(ctx, n == 1 ? fz_device_gray(ctx) : n == 3 ? fz_device_rgb(ctx) : fz_device_cmyk(ctx), color,
                               fz_device_rgb(ctx), rgb, NULL, fz_default_color_params);
        int alignment = fz_clampi(pdf_annot_quadding(ctx, annot), 0, 2);
        fz_append_printf(ctx, css, "';font-size:%gpt;color:#%02x%02x%02x;text-align:%s", size,
                         (int)(fz_clamp(rgb[0], 0, 1) * 255 + 0.5f), (int)(fz_clamp(rgb[1], 0, 1) * 255 + 0.5f),
                         (int)(fz_clamp(rgb[2], 0, 1) * 255 + 0.5f), alignment == 1 ? "center" : alignment == 2 ? "right" : "left");
        if (style & 1) fz_append_string(ctx, css, ";font-weight:bold");
        if (style & 2) fz_append_string(ctx, css, ";font-style:italic");
        if (style & 4) fz_append_string(ctx, css, ";text-decoration:underline");
        pdf_set_annot_rich_defaults(ctx, annot, fz_string_from_buffer(ctx, css));
    }
    fz_always(ctx) { fz_drop_buffer(ctx, css); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
API int lf_pdf_live_set_text_style(void *opaque, int page_number, int object_number, const char *family, int style, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation font style")
    if (!family || !*family || (style & ~7)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid annotation font style");
    live_write_font(ctx, annot, family, style); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_default_appearance(void *opaque, int page_number, int object_number, const char *font, float size, const float *color, int alignment, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation font")
    if (!isfinite(size) || size < 0 || !color || alignment < 0 || alignment > 2) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid annotation text appearance");
    char *family = NULL; int style = 0; fz_var(family);
    fz_try(ctx) {
        if (pdf_annot_type(ctx, annot) == PDF_ANNOT_FREE_TEXT) live_read_font(ctx, annot, &family, &style);
        pdf_set_annot_default_appearance(ctx, annot, font, size, 3, color);
        pdf_set_annot_quadding(ctx, annot, alignment);
        if (family && live_custom_font(family, style)) live_write_font(ctx, annot, family, style);
        pdf_update_annot(ctx, annot);
    }
    fz_always(ctx) { fz_free(ctx, family); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_icon(void *opaque, int page_number, int object_number, const char *name, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation icon")
    pdf_set_annot_icon_name(ctx, annot, name); pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_widget_value(void *opaque, int page_number, int object_number, const char *value, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_FORM, "Fill form field")
    if (pdf_widget_is_readonly(ctx, annot)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This form field is read-only");
    int accepted = 0;
    switch (pdf_widget_type(ctx, annot)) {
    case PDF_WIDGET_TYPE_TEXT: accepted = pdf_set_text_field_value(ctx, annot, value); break;
    case PDF_WIDGET_TYPE_COMBOBOX:
    case PDF_WIDGET_TYPE_LISTBOX: accepted = pdf_set_choice_field_value(ctx, annot, value); break;
    default: fz_throw(ctx, FZ_ERROR_ARGUMENT, "This form field does not accept text");
    }
    if (!accepted) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The form's validation rejected this value");
    pdf_update_page(ctx, page); pdf_update_open_pages(ctx, doc);
    LIVE_ANNOT_END
}
API int lf_pdf_live_widget_toggle(void *opaque, int page_number, int object_number, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_FORM, "Toggle form field")
    if (pdf_widget_is_readonly(ctx, annot)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This form field is read-only");
    int kind = pdf_widget_type(ctx, annot);
    if (kind != PDF_WIDGET_TYPE_RADIOBUTTON && kind != PDF_WIDGET_TYPE_CHECKBOX)
        fz_throw(ctx, FZ_ERROR_ARGUMENT, "This form field is not a checkbox or radio button");
    pdf_toggle_widget(ctx, annot);
    pdf_update_page(ctx, page); pdf_update_open_pages(ctx, doc);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_author(void *opaque, int page_number, int object_number, const char *author, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation author")
    pdf_set_annot_author(ctx, annot, author);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_border_style(void *opaque, int page_number, int object_number, int style, int count, const float *dash, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Change annotation border style")
    if (style < PDF_BORDER_STYLE_SOLID || style > PDF_BORDER_STYLE_UNDERLINE || count < 0 || (count && !dash))
        fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid annotation border style");
    pdf_set_annot_border_style(ctx, annot, style); pdf_clear_annot_border_dash(ctx, annot);
    for (int i = 0; i < count; ++i) {
        if (!isfinite(dash[i]) || dash[i] < 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Invalid border dash length");
        pdf_add_annot_border_dash_item(ctx, annot, dash[i]);
    }
    pdf_update_annot(ctx, annot);
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_stamp_image(void *opaque, int page_number, int object_number, const char *path, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Insert stamp image")
    fz_image *image = NULL; fz_var(image);
    fz_try(ctx) {
        image = fz_new_image_from_file(ctx, path);
        pdf_set_annot_stamp_image(ctx, annot, image); pdf_update_annot(ctx, annot);
    }
    fz_always(ctx) { fz_drop_image(ctx, image); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    LIVE_ANNOT_END
}
API int lf_pdf_live_set_attachment(void *opaque, int page_number, int object_number, const char *path, const char *name, const char *mime, char *error) {
    LIVE_ANNOT_BEGIN(FZ_PERMISSION_ANNOTATE, "Attach file")
    fz_buffer *contents = NULL; pdf_obj *filespec = NULL; fz_stream *input = NULL;
    fz_var(contents); fz_var(filespec); fz_var(input);
    fz_try(ctx) {
        input = fz_open_file(ctx, path); fz_seek(ctx, input, 0, SEEK_END);
        int64_t length = fz_tell(ctx, input);
        if (length < 0) fz_throw(ctx, FZ_ERROR_FORMAT, "Invalid attachment length");
        fz_seek(ctx, input, 0, SEEK_SET); contents = fz_read_all(ctx, input, (size_t)length);
        filespec = pdf_add_embedded_file(ctx, doc, name, mime, contents, 0, 0, 1);
        // The pinned pdf_add_embedded_file starts "Embed file" but only closes
        // it on failure. Balance its successful operation before our own end.
        pdf_end_operation(ctx, doc);
        pdf_set_annot_filespec(ctx, annot, filespec); pdf_update_annot(ctx, annot);
    }
    fz_always(ctx) { pdf_drop_obj(ctx, filespec); fz_drop_buffer(ctx, contents); fz_drop_stream(ctx, input); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    LIVE_ANNOT_END
}
#undef LIVE_ANNOT_BEGIN
#undef LIVE_ANNOT_END

static void live_json_color(fz_context *ctx, SumraJSON *json, int n, const float *color) {
    float rgb[3];
    lf_json(json, "[");
    if (n) {
        fz_colorspace *space = n == 1 ? fz_device_gray(ctx) : n == 3 ? fz_device_rgb(ctx) : fz_device_cmyk(ctx);
        fz_convert_color(ctx, space, color, fz_device_rgb(ctx), rgb, NULL, fz_default_color_params);
        for (int i = 0; i < 3; ++i) { if (i) lf_json(json, ","); lf_json_number(json, rgb[i]); }
    }
    lf_json(json, "]");
}
static void live_json_point(SumraJSON *json, fz_point point) {
    lf_json(json, "["); lf_json_number(json, point.x); lf_json(json, ","); lf_json_number(json, point.y); lf_json(json, "]");
}
static void live_json_annotation(fz_context *ctx, SumraJSON *json, pdf_annot *annot) {
    pdf_obj *object = pdf_annot_obj(ctx, annot);
    enum pdf_annot_type kind = pdf_annot_type(ctx, annot);
    int n; float color[4]; fz_rect rect = pdf_bound_annot(ctx, annot);
    lf_json(json, "{\"id\":"); lf_json_number(json, pdf_to_num(ctx, object));
    lf_json(json, ",\"type\":"); lf_json_string(json, pdf_string_from_annot_type(ctx, kind));
    lf_json(json, ",\"rect\":"); lf_json_rect(json, rect.x0, rect.y0, rect.x1-rect.x0, rect.y1-rect.y0);
    // Annotation.cpp::GetAnnotRect: copying the expanded appearance bounds
    // would add the border width on every paste. Geometry-only types use bounds.
    fz_rect design = pdf_annot_has_rect(ctx, annot) ? pdf_annot_rect(ctx, annot) : rect;
    lf_json(json, ",\"designRect\":"); lf_json_rect(json, design.x0, design.y0, design.x1-design.x0, design.y1-design.y0);
    lf_json(json, ",\"flags\":"); lf_json_number(json, pdf_annot_flags(ctx, annot));
    lf_json(json, ",\"contents\":"); lf_json_string(json, pdf_annot_contents(ctx, annot));
    lf_json(json, ",\"author\":"); lf_json_string(json, pdf_annot_has_author(ctx, annot) ? pdf_annot_author(ctx, annot) : "");
    lf_json(json, ",\"icon\":"); lf_json_string(json, pdf_annot_has_icon_name(ctx, annot) ? pdf_annot_icon_name(ctx, annot) : "");
    pdf_annot_color(ctx, annot, &n, color);
    lf_json(json, ",\"color\":"); live_json_color(ctx, json, n, color);
    n = 0; if (pdf_annot_has_interior_color(ctx, annot)) pdf_annot_interior_color(ctx, annot, &n, color);
    lf_json(json, ",\"interiorColor\":"); live_json_color(ctx, json, n, color);
    lf_json(json, ",\"opacity\":"); lf_json_number(json, pdf_annot_opacity(ctx, annot));
    int has_border = pdf_annot_has_border(ctx, annot);
    lf_json(json, ",\"borderWidth\":"); lf_json_number(json, has_border ? pdf_annot_border_width(ctx, annot) : 0);
    lf_json(json, ",\"borderStyle\":"); lf_json_number(json, has_border ? pdf_annot_border_style(ctx, annot) : 0);
    lf_json(json, ",\"dash\":[");
    for (int i = 0, count = has_border ? pdf_annot_border_dash_count(ctx, annot) : 0; i < count; ++i) {
        if (i) lf_json(json, ","); lf_json_number(json, pdf_annot_border_dash_item(ctx, annot, i));
    }
    int alignment = 0;
    if (kind == PDF_ANNOT_WIDGET) {
        pdf_obj *q = pdf_dict_get_inheritable(ctx, object, PDF_NAME(Q));
        if (!q) q = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf_get_bound_document(ctx, object)), "Root/AcroForm/Q");
        alignment = pdf_to_int(ctx, q);
        if (alignment < 0 || alignment > 2) alignment = 0;
    } else if (pdf_annot_has_quadding(ctx, annot)) alignment = pdf_annot_quadding(ctx, annot);
    lf_json(json, "],\"alignment\":"); lf_json_number(json, alignment);
    const char *font = ""; float size = 0; n = 0;
    if (pdf_annot_has_default_appearance(ctx, annot)) pdf_annot_default_appearance(ctx, annot, &font, &size, &n, color);
    lf_json(json, ",\"font\":"); lf_json_string(json, font);
    lf_json(json, ",\"fontSize\":"); lf_json_number(json, size);
    lf_json(json, ",\"textColor\":"); live_json_color(ctx, json, n, color);
    if (kind == PDF_ANNOT_FREE_TEXT) {
        char *family = NULL; int style = 0; fz_var(family);
        fz_try(ctx) {
            live_read_font(ctx, annot, &family, &style);
            lf_json(json, ",\"fontFamily\":"); lf_json_string(json, family);
            lf_json(json, ",\"fontStyle\":"); lf_json_number(json, style);
        }
        fz_always(ctx) { fz_free(ctx, family); }
        fz_catch(ctx) { fz_rethrow(ctx); }
    }
    lf_json(json, ",\"line\":[");
    if (pdf_annot_has_line(ctx, annot)) {
        fz_point a, b; pdf_annot_line(ctx, annot, &a, &b);
        live_json_point(json, a); lf_json(json, ","); live_json_point(json, b);
    }
    lf_json(json, "],\"lineEnds\":[");
    if (pdf_annot_has_line_ending_styles(ctx, annot)) {
        lf_json_number(json, pdf_annot_line_start_style(ctx, annot)); lf_json(json, ","); lf_json_number(json, pdf_annot_line_end_style(ctx, annot));
    }
    lf_json(json, "],\"quads\":[");
    if (pdf_annot_has_quad_points(ctx, annot)) for (int i = 0, count = pdf_annot_quad_point_count(ctx, annot); i < count; ++i) {
        fz_quad q = pdf_annot_quad_point(ctx, annot, i);
        if (i) lf_json(json, ","); lf_json(json, "[");
        live_json_point(json, q.ul); lf_json(json, ","); live_json_point(json, q.ur); lf_json(json, ",");
        live_json_point(json, q.ll); lf_json(json, ","); live_json_point(json, q.lr); lf_json(json, "]");
    }
    lf_json(json, "],\"vertices\":[");
    if (pdf_annot_has_vertices(ctx, annot)) for (int i = 0, count = pdf_annot_vertex_count(ctx, annot); i < count; ++i) {
        if (i) lf_json(json, ","); live_json_point(json, pdf_annot_vertex(ctx, annot, i));
    }
    lf_json(json, "],\"ink\":[");
    if (pdf_annot_has_ink_list(ctx, annot)) for (int i = 0, count = pdf_annot_ink_list_count(ctx, annot); i < count; ++i) {
        if (i) lf_json(json, ","); lf_json(json, "[");
        for (int j = 0, size = pdf_annot_ink_list_stroke_count(ctx, annot, i); j < size; ++j) {
            if (j) lf_json(json, ","); live_json_point(json, pdf_annot_ink_list_stroke_vertex(ctx, annot, i, j));
        }
        lf_json(json, "]");
    }
    lf_json(json, "]");
    if (kind == PDF_ANNOT_WIDGET) {
        char *name = NULL; fz_var(name);
        fz_try(ctx) {
            name = pdf_load_field_name(ctx, object);
            lf_json(json, ",\"fieldName\":"); lf_json_string(json, name);
            lf_json(json, ",\"fieldLabel\":"); lf_json_string(json, pdf_field_label(ctx, object));
            lf_json(json, ",\"fieldType\":"); lf_json_number(json, pdf_widget_type(ctx, annot));
            if (pdf_widget_type(ctx, annot) == PDF_WIDGET_TYPE_SIGNATURE) {
                lf_json(json, ",\"isSigned\":"); lf_json(json, pdf_widget_is_signed(ctx, annot) ? "true" : "false");
            }
            lf_json(json, ",\"fieldFlags\":"); lf_json_number(json, pdf_annot_field_flags(ctx, annot));
            lf_json(json, ",\"value\":"); lf_json_string(json, pdf_field_value(ctx, object));
            lf_json(json, ",\"readOnly\":"); lf_json(json, pdf_widget_is_readonly(ctx, annot) ? "true" : "false");
            lf_json(json, ",\"maxLength\":"); lf_json_number(json, pdf_widget_type(ctx, annot) == PDF_WIDGET_TYPE_TEXT ? pdf_text_widget_max_len(ctx, annot) : 0);
            lf_json(json, ",\"options\":[");
            for (int i = 0, count = pdf_choice_field_option_count(ctx, object); i < count; ++i) {
                if (i) lf_json(json, ","); lf_json(json, "{\"label\":"); lf_json_string(json, pdf_choice_field_option(ctx, object, 0, i));
                lf_json(json, ",\"value\":"); lf_json_string(json, pdf_choice_field_option(ctx, object, 1, i)); lf_json(json, "}");
            }
            lf_json(json, "]");
        }
        fz_always(ctx) { fz_free(ctx, name); }
        fz_catch(ctx) { fz_rethrow(ctx); }
    }
    lf_json(json, "}");
}
API char *lf_pdf_live_annotations(void *opaque, int page_number, char *error) {
    SumraMuPDFDocument *d = opaque; pdf_page *page = NULL; SumraJSON json = {0};
    fz_var(page); fz_var(json);
    fz_try(d->ctx) {
        page = pdf_load_page(d->ctx, live_pdf(d), page_number);
        lf_json(&json, "["); int first = 1;
        for (pdf_annot *a = pdf_first_annot(d->ctx, page); a; a = pdf_next_annot(d->ctx, a)) {
            if (!first) lf_json(&json, ","); first = 0; live_json_annotation(d->ctx, &json, a);
        }
        for (pdf_annot *a = pdf_first_widget(d->ctx, page); a; a = pdf_next_widget(d->ctx, a)) {
            if (!first) lf_json(&json, ","); first = 0; live_json_annotation(d->ctx, &json, a);
        }
        lf_json(&json, "]");
    }
    fz_always(d->ctx) { fz_drop_page(d->ctx, (fz_page *)page); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}

// EngineMupdf.cpp uses these same MuPDF link converters. They are exported by
// pdf-link.c, but deliberately not declared in the public annotation header.
extern char *pdf_parse_link_action(fz_context *, pdf_document *, pdf_obj *, int);
extern char *pdf_parse_link_dest(fz_context *, pdf_document *, pdf_obj *);

static void live_json_link_dest(SumraJSON *json, fz_link_dest dest) {
    if (dest.loc.page < 0) { lf_json(json, "null"); return; }
    lf_json(json, "{\"page\":"); lf_json_number(json, dest.loc.page);
    lf_json(json, ",\"type\":"); lf_json_number(json, dest.type);
    lf_json(json, ",\"x\":"); lf_json_number(json, dest.x);
    lf_json(json, ",\"y\":"); lf_json_number(json, dest.y);
    lf_json(json, ",\"width\":"); lf_json_number(json, dest.w);
    lf_json(json, ",\"height\":"); lf_json_number(json, dest.h);
    lf_json(json, ",\"zoom\":"); lf_json_number(json, dest.zoom); lf_json(json, "}");
}

static void live_json_destination(fz_context *ctx, pdf_document *doc, SumraJSON *json, const char *uri) {
    if (!uri || fz_is_external_link(ctx, uri)) { lf_json(json, "null"); return; }
    live_json_link_dest(json, pdf_resolve_link_dest(ctx, doc, uri));
}

static void live_json_pdf_destination(fz_context *ctx, pdf_document *doc, SumraJSON *json, const char *uri) {
    int remote = uri && !strncmp(uri, "file:", 5);
    if (!uri || (fz_is_external_link(ctx, uri) && !remote)) { lf_json(json, "null"); return; }
    pdf_obj *owned = NULL; fz_var(owned);
    fz_try(ctx) {
        // MuPDF reverses its link URI into the unrotated PDF coordinate system.
        // Resolving it as a navigation destination first would clamp coordinates
        // to the CropBox and discard valid off-page positions before conversion.
        owned = pdf_new_dest_from_link(ctx, doc, uri, remote);
        pdf_obj *array = owned;
        // Same bounded name/dictionary resolution as pdf-link.c:resolve_dest_rec.
        // A remote named destination belongs to the other document, not this one.
        for (int depth = 0; !remote && depth < 10 && !pdf_is_array(ctx, array); ++depth) {
            if (pdf_is_name(ctx, array) || pdf_is_string(ctx, array)) array = pdf_lookup_dest(ctx, doc, array);
            else if (pdf_is_dict(ctx, array)) array = pdf_dict_get(ctx, array, PDF_NAME(D));
            else break;
        }
        fz_link_dest dest = fz_make_link_dest_none();
        if (pdf_is_array(ctx, array)) {
            pdf_obj *page = pdf_array_get(ctx, array, 0), *type = pdf_array_get(ctx, array, 1);
            dest.loc.page = pdf_is_int(ctx, page) ? pdf_to_int(ctx, page) : pdf_lookup_page_number(ctx, doc, page);
            float values[4];
            for (int i = 0; i < 4; ++i) {
                pdf_obj *value = pdf_array_get(ctx, array, i + 2);
                values[i] = pdf_is_number(ctx, value) ? pdf_to_real(ctx, value) : NAN;
            }
            if (type == PDF_NAME(Fit)) dest.type = FZ_LINK_DEST_FIT;
            else if (type == PDF_NAME(FitB)) dest.type = FZ_LINK_DEST_FIT_B;
            else if (type == PDF_NAME(FitH) || type == PDF_NAME(FitBH)) {
                dest.type = type == PDF_NAME(FitH) ? FZ_LINK_DEST_FIT_H : FZ_LINK_DEST_FIT_BH;
                dest.y = values[0];
            } else if (type == PDF_NAME(FitV) || type == PDF_NAME(FitBV)) {
                dest.type = type == PDF_NAME(FitV) ? FZ_LINK_DEST_FIT_V : FZ_LINK_DEST_FIT_BV;
                dest.x = values[0];
            } else if (type == PDF_NAME(FitR)) {
                dest.type = FZ_LINK_DEST_FIT_R; dest.x = values[0]; dest.y = values[1];
                dest.w = values[2] - values[0]; dest.h = values[3] - values[1];
            } else {
                dest.type = FZ_LINK_DEST_XYZ; dest.x = values[0]; dest.y = values[1]; dest.zoom = values[2];
            }
        }
        live_json_link_dest(json, dest);
    }
    fz_always(ctx) { pdf_drop_obj(ctx, owned); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

API char *lf_pdf_live_resolve_destination(void *opaque, const char *uri, int pdf_coordinates, char *error) {
    SumraMuPDFDocument *d = opaque; SumraJSON json = {0};
    fz_var(json);
    fz_try(d->ctx) {
        if (pdf_coordinates) live_json_pdf_destination(d->ctx, live_pdf(d), &json, uri);
        else live_json_destination(d->ctx, live_pdf(d), &json, uri);
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}

static void live_json_action(fz_context *ctx, pdf_document *doc, SumraJSON *json,
                             pdf_obj *action, pdf_obj *dest, int page, int index) {
    char *uri = NULL, *javascript = NULL;
    fz_var(uri); fz_var(javascript);
    fz_try(ctx) {
        const char *kind = dest ? "GoTo" : pdf_dict_get_name(ctx, action, PDF_NAME(S));
        uri = dest ? pdf_parse_link_dest(ctx, doc, dest) : pdf_parse_link_action(ctx, doc, action, page);
        if (!strcmp(kind, "JavaScript")) {
            pdf_obj *body = pdf_dict_get(ctx, action, PDF_NAME(JS));
            if (body) javascript = pdf_load_stream_or_string_as_utf8(ctx, body);
        }
        if (index) lf_json(json, ",");
        lf_json(json, "{\"index\":"); lf_json_number(json, index);
        lf_json(json, ",\"kind\":"); lf_json_string(json, kind);
        lf_json(json, ",\"uri\":"); if (uri) lf_json_string(json, uri); else lf_json(json, "null");
        lf_json(json, ",\"name\":"); lf_json_string(json, pdf_dict_get_name(ctx, action, PDF_NAME(N)));
        lf_json(json, ",\"flags\":"); lf_json_number(json, pdf_dict_get_int(ctx, action, PDF_NAME(Flags)));
        lf_json(json, ",\"newWindow\":");
        pdf_obj *new_window = pdf_dict_gets(ctx, action, "NewWindow");
        lf_json(json, new_window ? (pdf_to_bool(ctx, new_window) ? "true" : "false") : "null");
        // Keep unsupported actions identifiable without executing them. Submit,
        // Reset and Hide are not navigation branches in Sumatra's LinkFollow.
        lf_json(json, ",\"fields\":");
        pdf_obj *fields = pdf_dict_get(ctx, action, PDF_NAME(Fields));
        if (!fields) lf_json(json, "null");
        else {
            lf_json(json, "[");
            for (int i = 0, n = pdf_array_len(ctx, fields); i < n; ++i) {
                pdf_obj *field = pdf_array_get(ctx, fields, i);
                char *name = NULL; fz_var(name);
                fz_try(ctx) {
                    if (pdf_is_dict(ctx, field)) name = pdf_load_field_name(ctx, field);
                    if (i) lf_json(json, ",");
                    lf_json_string(json, name ? name : pdf_to_text_string(ctx, field));
                }
                fz_always(ctx) { fz_free(ctx, name); }
                fz_catch(ctx) { fz_rethrow(ctx); }
            }
            lf_json(json, "]");
        }
        lf_json(json, ",\"javascript\":");
        if (javascript) lf_json_string(json, javascript); else lf_json(json, "null");
        lf_json(json, ",\"destination\":"); live_json_destination(ctx, doc, json, uri);
        lf_json(json, "}");
    }
    fz_always(ctx) { fz_free(ctx, uri); fz_free(ctx, javascript); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

// Read in the order used by MuPDF's pdf_execute_action_chain: an action first,
// then /Next, with arrays traversed in order. Reuse its ancestry cycle check;
// do not globally deduplicate shared actions, which may occur twice in a chain.
static void live_json_action_chain(fz_context *ctx, pdf_document *doc, SumraJSON *json,
                                   pdf_obj *action, int page, int *index, pdf_cycle_list *up) {
    pdf_cycle_list cycle;
    if (pdf_cycle(ctx, &cycle, up, action)) fz_throw(ctx, FZ_ERROR_FORMAT, "cycle in action chain");
    if (pdf_is_array(ctx, action)) {
        for (int i = 0, n = pdf_array_len(ctx, action); i < n; ++i)
            live_json_action_chain(ctx, doc, json, pdf_array_get(ctx, action, i), page, index, &cycle);
    } else {
        live_json_action(ctx, doc, json, action, NULL, page, (*index)++);
        pdf_obj *next = pdf_dict_get(ctx, action, PDF_NAME(Next));
        if (next) live_json_action_chain(ctx, doc, json, next, page, index, &cycle);
    }
}

API char *lf_pdf_live_links(void *opaque, int page_number, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx; SumraJSON json = {0};
    fz_var(json);
    fz_try(ctx) {
        pdf_document *doc = live_pdf(d);
        pdf_obj *page = pdf_lookup_page_obj(ctx, doc, page_number);
        pdf_obj *annots = pdf_dict_get(ctx, page, PDF_NAME(Annots));
        fz_rect mediabox; fz_matrix ctm;
        pdf_page_obj_transform(ctx, page, &mediabox, &ctm);
        lf_json(&json, "["); int first = 1;
        for (int i = 0, n = pdf_array_len(ctx, annots); i < n; ++i) {
            pdf_obj *annot = pdf_array_get(ctx, annots, i);
            pdf_obj *type = pdf_dict_get(ctx, annot, PDF_NAME(Subtype));
            int attachment = pdf_name_eq(ctx, type, PDF_NAME(FileAttachment));
            if (!attachment && !pdf_name_eq(ctx, type, PDF_NAME(Link)) &&
                !(pdf_name_eq(ctx, type, PDF_NAME(Widget)) && pdf_field_type(ctx, annot) == PDF_WIDGET_TYPE_BUTTON)) continue;
            // EngineMupdf::MakePushButtonWidgetLinks and MuPDF pdf_load_link
            // use /Dest, then /A, then /AA/U or /AA/D in this order.
            pdf_obj *dest = pdf_dict_get(ctx, annot, PDF_NAME(Dest));
            pdf_obj *action = pdf_dict_get(ctx, annot, PDF_NAME(A));
            if (!action) action = pdf_dict_geta(ctx, pdf_dict_get(ctx, annot, PDF_NAME(AA)), PDF_NAME(U), PDF_NAME(D));
            if (!attachment && !dest && !action) continue;
            fz_rect rect = fz_transform_rect(pdf_dict_get_rect(ctx, annot, PDF_NAME(Rect)), ctm);
            if (!first) lf_json(&json, ","); first = 0;
            lf_json(&json, "{\"id\":"); lf_json_number(&json, pdf_to_num(ctx, annot));
            lf_json(&json, ",\"type\":"); lf_json_string(&json, pdf_to_name(ctx, type));
            lf_json(&json, ",\"flags\":"); lf_json_number(&json, pdf_dict_get_int(ctx, annot, PDF_NAME(F)));
            lf_json(&json, ",\"rect\":"); lf_json_rect(&json, rect.x0, rect.y0, rect.x1-rect.x0, rect.y1-rect.y0);
            lf_json(&json, ",\"actions\":[");
            if (dest) live_json_action(ctx, doc, &json, NULL, dest, page_number, 0);
            else if (action) { int index = 0; live_json_action_chain(ctx, doc, &json, action, page_number, &index, NULL); }
            lf_json(&json, "]}");
        }
        lf_json(&json, "]");
    }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}

// EngineMupdf::LookupNamedJavaScript, used only by the existing Altium menu
// string parser. Neither this endpoint nor link enumeration executes script.
API char *lf_pdf_live_named_javascript(void *opaque, const char *name, char *error) {
    SumraMuPDFDocument *d = opaque; fz_context *ctx = d->ctx;
    pdf_obj *needle = NULL; char *source = NULL, *result = NULL;
    fz_var(needle); fz_var(source); fz_var(result);
    fz_try(ctx) {
        pdf_document *doc = live_pdf(d);
        needle = pdf_new_string(ctx, name, strlen(name));
        pdf_obj *found = pdf_lookup_name(ctx, doc, PDF_NAME(JavaScript), needle);
        if (pdf_is_dict(ctx, found)) found = pdf_dict_get(ctx, found, PDF_NAME(JS));
        if (found) source = pdf_load_stream_or_string_as_utf8(ctx, found);
        result = strdup(source ? source : "");
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate JavaScript metadata");
    }
    fz_always(ctx) { pdf_drop_obj(ctx, needle); fz_free(ctx, source); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(result); return NULL; }
    return result;
}
