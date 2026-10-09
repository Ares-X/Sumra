#if os(macOS)
import AppKit
import Darwin
import SumraCore
import Security

struct PDFSignatureAppearance: OptionSet, Sendable {
    let rawValue: Int32
    static let labels = Self(rawValue: 1)
    static let distinguishedName = Self(rawValue: 2)
    static let date = Self(rawValue: 4)
    static let textName = Self(rawValue: 8)
    static let graphicName = Self(rawValue: 16)
    static let logo = Self(rawValue: 32)
    static let standard: Self = [.labels, .date, .textName]
}


struct PDFSignatureInfo: Decodable, Sendable {
    struct Timestamp: Decodable, Sendable {
        let hashAlgorithm: String?
        let policyOID: String?
        /// Parsed TSTInfo time; trust is reported by Security separately.
        let generationTime: Double?
    }
    struct Signer: Decodable, Sendable {
        let name: String?
        let certificateDER: [Data]?
        let certificateTrusted: Bool
        let trustError: String?
        let trustErrorCode: Int?
        let signingTime: Double?
        let signingTimeError: String?
        let timestampTime: Double?
        let timestampCertificateCount: Int
        let timestampCertificateDER: [Data]?
        let timestampError: String?
        let qualifiedCertificate: Bool?
        let certificateMetadataError: String?
        let hashAlgorithm: String?
        let signatureAlgorithm: String?
        let documentHash: String?
        let policyOID: String?
        let generationTime: Double?
        let cadesAttribute: Bool?
        let signaturePolicyAttribute: Bool?
        let timestamps: [Timestamp]?
        let metadataError: String?
    }
    struct Field: Decodable, Sendable {
        let name: String
        /// Zero-based first page, or nil for a field without a page widget.
        let page: Int?
        let readOnly: Bool
        let isSigned: Bool
        let pending: Bool?
        let subFilter: String
        let isDocumentTimestamp: Bool
        let cades: Bool
        let pdfSigningTime: String
        let reason: String
        let location: String
        let contact: String
        let digestValid: Bool?
        let digestError: String
        let certificateTrusted: Bool?
        let certificateError: String
        let changedSinceSigning: Bool?
        let changeError: String
        let signers: [Signer]
    }
    let trustPolicy: String
    let dssCertificates: Int
    let dssOCSPResponses: Int
    let dssCRLs: Int
    let dssValidationInfoEntries: Int
    let signatures: [Field]

    var unsignedFields: [Field] { signatures.filter { !$0.isSigned } }
    var report: String {
        var rows = [trustPolicy]
        if signatures.isEmpty { rows.append("No digital signature fields.") }
        for (index, field) in signatures.enumerated() {
            let page = field.page.map { " (page \($0 + 1))" } ?? ""
            rows.append("Signature \(index + 1): \(field.name)\(page)")
            guard field.isSigned else {
                rows.append(field.readOnly ? "  Not signed; field is read-only." : "  Not signed.")
                continue
            }
            if field.pending == true {
                rows.append("  Pending signature; save has not completed and its digest has not been verified.")
                continue
            }
            rows.append("  SubFilter: \(field.subFilter)")
            if field.isDocumentTimestamp { rows.append("  Document timestamp.") }
            rows.append("  Signed byte-range digest: \(verdict(field.digestValid, yes: "valid", no: "invalid"))")
            rows.append("  Certificate: \(verdict(field.certificateTrusted, yes: "trusted locally", no: "not trusted locally"))")
            if let changed = field.changedSinceSigning { rows.append(changed ? "  Document changed after signing." : "  No later incremental changes.") }
            for value in [field.digestError, field.certificateError, field.changeError] where !value.isEmpty { rows.append("  \(value)") }
            for signer in field.signers {
                rows.append("  Signed by: \(signer.name ?? "(unknown)")")
                if signer.qualifiedCertificate == true { rows.append("  " + L("Certificate contains eIDAS qcStatements; qualification has not been validated.")) }
                for (key, value) in [("Hash algorithm", signer.hashAlgorithm), ("Signature algorithm", signer.signatureAlgorithm),
                    ("Signed content digest", signer.documentHash), ("Timestamp policy OID", signer.policyOID)] {
                    if let value { rows.append("  \(L(key)): \(value)") }
                }
                if signer.signaturePolicyAttribute == true { rows.append("  " + L("Signature policy attribute present.")) }
                if let time = signer.generationTime {
                    rows.append("  \(L("Timestamp time (token metadata)")): \(Date(timeIntervalSince1970: time).formatted())")
                }
                for error in [signer.metadataError, signer.certificateMetadataError].compactMap({ $0 }) { rows.append("  \(error)") }
                if let error = signer.trustError { rows.append("  \(error)") }
                if let time = signer.signingTime { rows.append("  Signing time (signer's clock): \(Date(timeIntervalSince1970: time).formatted())") }
                if signer.timestampCertificateCount > 0 || signer.timestampTime != nil || signer.timestampError != nil {
                    rows.append("  Included timestamp certificates: \(signer.timestampCertificateCount)")
                    if let time = signer.timestampTime { rows.append("  Timestamp time (verified offline): \(Date(timeIntervalSince1970: time).formatted())") }
                    else if let error = signer.timestampError { rows.append("  Timestamp: \(error)") }
                }
                for timestamp in signer.timestamps ?? [] {
                    if let algorithm = timestamp.hashAlgorithm { rows.append("  \(L("Timestamp hash algorithm")): \(algorithm)") }
                    if let policy = timestamp.policyOID { rows.append("  \(L("Timestamp policy OID")): \(policy)") }
                    if let time = timestamp.generationTime {
                        rows.append("  \(L("Timestamp time (token metadata)")): \(Date(timeIntervalSince1970: time).formatted())")
                    }
                }
            }
            if !field.pdfSigningTime.isEmpty { rows.append("  PDF signature date: \(field.pdfSigningTime) (device supplied)") }
            for (key, value) in [("Reason", field.reason), ("Location", field.location), ("Contact", field.contact)] where !value.isEmpty { rows.append("  \(key): \(value)") }
            if field.cades || field.signers.contains(where: { $0.cadesAttribute == true }) { rows.append("  " + L("CAdES metadata present; PAdES conformance has not been established.")) }
        }
        if dssCertificates + dssOCSPResponses + dssCRLs + dssValidationInfoEntries > 0 {
            rows.append("DSS material: \(dssCertificates) certificates, \(dssOCSPResponses) OCSP responses, \(dssCRLs) CRLs, \(dssValidationInfoEntries) VRI entries. Presence does not establish LTV validity.")
        }
        return rows.joined(separator: "\n")
    }
    private func verdict(_ value: Bool?, yes: String, no: String) -> String {
        value.map { $0 ? yes : no } ?? "not verified"
    }
}


enum PDFAdvancedOperation: String, CaseIterable, Sendable {
    case compress, decompress, flatten, bake, redact
}

// File-level MuPDF tools for output copies and saved-source reports.
// NativeFile/Pages own the live PDF document and its reading/editing operations.
enum NativePDFTools {
    @MainActor
    final class SourcePrintPDF {
        private typealias Begin = @convention(c) (UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        private typealias Add = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>, Int,
            Double, Double, UnsafePointer<Double>, UnsafePointer<Double>, UnsafeMutablePointer<CChar>) -> Int32
        private typealias Finish = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>,
            UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
        private typealias Drop = @convention(c) (UnsafeMutableRawPointer) -> Void

        private let library: UnsafeMutableRawPointer
        private let addPage: Add
        private let finishPages: Finish
        private let dropPages: Drop
        private var writer: UnsafeMutableRawPointer?

        init() throws {
            let path = try NativeFile.libraryURL(for: .mupdf)
            guard let library = dlopen(path.path, RTLD_LOCAL | RTLD_NOW) else {
                throw ReadError("Cannot load MuPDF print writer: \(dlerror().map { String(cString: $0) } ?? "unknown loader error")")
            }
            do {
                func symbol<T>(_ name: String, as type: T.Type) throws -> T {
                    guard let pointer = dlsym(library, name) else { throw ReadError("MuPDF engine lacks print writer: \(name)") }
                    return unsafeBitCast(pointer, to: T.self)
                }
                let begin = try symbol("lf_print_source_pdf_begin", as: Begin.self)
                let add = try symbol("lf_print_source_pdf_add", as: Add.self)
                let finish = try symbol("lf_print_source_pdf_finish", as: Finish.self)
                let drop = try symbol("lf_print_source_pdf_drop", as: Drop.self)
                var error = [CChar](repeating: 0, count: 512)
                guard let writer = begin(&error) else { try NativePDFTools.check(0, error: error); throw ReadError("Cannot start source PDF print") }
                self.library = library; addPage = add; finishPages = finish; dropPages = drop; self.writer = writer
            } catch {
                dlclose(library)
                throw error
            }
        }

        deinit {
            if let writer { dropPages(writer) }
            dlclose(library)
        }

        func add(_ bytes: Data, paperSize: CGSize, transform: CGAffineTransform, clip: CGRect) throws {
            guard let writer, !bytes.isEmpty else { throw ReadError("Cannot add an empty source PDF print page") }
            let matrix = [Double(transform.a), Double(transform.b), Double(transform.c),
                          Double(transform.d), Double(transform.tx), Double(transform.ty)]
            let sourceClip = [Double(clip.minX), Double(clip.minY), Double(clip.width), Double(clip.height)]
            var error = [CChar](repeating: 0, count: 512)
            let result = bytes.withUnsafeBytes { raw in
                matrix.withUnsafeBufferPointer { values in
                    sourceClip.withUnsafeBufferPointer { region in
                        addPage(writer, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count,
                                Double(paperSize.width), Double(paperSize.height),
                                values.baseAddress!, region.baseAddress!, &error)
                    }
                }
            }
            try NativePDFTools.check(result, error: error)
        }

        func finish(_ output: URL) throws {
            guard let writer else { throw ReadError("Source PDF print was already finished") }
            guard output.isFileURL else { throw ReadError("Choose a local PDF print destination") }
            var original = stat()
            guard lstat(output.path, &original) == 0,
                  original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  let checkpoint = try NativeFile.FileCheckpoint(output) else {
                throw ReadError("The saved PDF changed before source text could be preserved")
            }
            let staging = output.deletingLastPathComponent().appendingPathComponent(".Sumra-Print-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let temporary = staging.appendingPathComponent("corrected.pdf")
            // The AppKit result stays in place while MuPDF fully rewrites the
            // sibling. MuPDF recreates that file, so copy its metadata again
            // after writing; the initial copy protects the source checkpoint.
            try FileManager.default.copyItem(at: output, to: temporary)
            guard let copied = try NativeFile.FileCheckpoint(temporary), copied.digest == checkpoint.digest,
                  try checkpoint.matches(output) else {
                throw ReadError("The saved PDF changed while preserving source text")
            }
            var error = [CChar](repeating: 0, count: 512)
            self.writer = nil // Native finish consumes it on success or failure.
            let result = finishPages(writer, output.path, temporary.path, &error)
            try NativePDFTools.check(result, error: error)
            guard copyfile(output.path, temporary.path, nil,
                           copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var current = stat()
            guard lstat(output.path, &current) == 0,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                  try checkpoint.matches(output) else {
                throw ReadError("The saved PDF changed while preserving source text")
            }
            guard Darwin.rename(temporary.path, output.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    static func information(source: URL, password: String = "") throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: inspect(source: source, password: password, symbol: "lf_pdf_information"))
    }

    static func resourceReport(source: URL, password: String = "") throws -> String {
        guard source.isFileURL else { throw ReadError("Choose a local PDF") }
        try validatePasswordText(password)
        typealias Report = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        var result = ""
        try withEngine("lf_pdf_resource_report", as: Report.self) { fn in
            var error = [CChar](repeating: 0, count: 512), count = 0
            guard let bytes = fn(source.path, password, &count, &error) else { try check(0, error: error); return }
            defer { free(bytes) }
            // The resource report can contain embedded XML, so use its byte
            // count rather than truncating at a NUL in that source stream.
            result = String(decoding: Data(bytes: bytes, count: count), as: UTF8.self)
        }
        return result
    }

    private static func inspect(source: URL, password: String, symbol: String) throws -> Data {
        guard source.isFileURL else { throw ReadError("Choose a local PDF") }
        try validatePasswordText(password)
        typealias Inspect = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        var result: Data?
        try withEngine(symbol, as: Inspect.self) { fn in
            var error = [CChar](repeating: 0, count: 512)
            guard let bytes = fn(source.path, password, &error) else {
                try check(0, error: error)
                return
            }
            defer { free(bytes) }
            result = Data(bytes: bytes, count: strlen(bytes))
        }
        guard let result else { throw ReadError("Cannot read PDF information") }
        return result
    }

    private static let permissionBits = [2, 11, 3, 10, 4, 9, 5, 8]
    private typealias Operation = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32, Int32, UnsafeMutablePointer<CChar>) -> Int32
    private typealias Sign = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeRawPointer?, UnsafePointer<CChar>, Int32, UnsafePointer<Float>, Int32, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<CChar>) -> Int32
    static func unwrap(source: URL, destination: URL) throws {
        typealias Unwrap = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
        try withDestination(source: source, destination: destination) { temporary in
            try withEngine("lf_pdf_unwrap", as: Unwrap.self) { fn in
                var error = [CChar](repeating: 0, count: 512)
                try check(fn(source.path, temporary.path, &error), error: error)
            }
        }
    }
    static func transform(source: URL, destination: URL, operation: PDFAdvancedOperation, password: String = "", invalidateSignatures: Bool = false) throws {
        try rewrite(source: source, destination: destination, operation: operation.rawValue, documentPassword: password, invalidateSignatures: invalidateSignatures)
    }
    static func selectPages(source: URL, destination: URL, pages: [Int], annotationsOnly: Bool = false,
                            password: String = "", invalidateSignatures: Bool = false) throws {
        try validatePasswordText(password)
        let indices = try pages.map { page -> Int32 in
            guard let value = Int32(exactly: page) else { throw ReadError("Invalid PDF page selection") }
            return value
        }
        typealias Select = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32, UnsafePointer<Int32>?, Int32, Int32, UnsafeMutablePointer<CChar>) -> Int32
        try withDestination(source: source, destination: destination) { temporary in
            try withEngine("lf_pdf_select_pages", as: Select.self) { fn in
                var error = [CChar](repeating: 0, count: 512)
                try check(fn(source.path, temporary.path, password, Int32(indices.count), indices,
                             annotationsOnly ? 1 : 0, invalidateSignatures ? 1 : 0, &error), error: error)
            }
        }
    }
    static func merge(sources: [(url: URL, password: String)], destination: URL, invalidateSignatures: Bool = false) throws {
        guard let first = sources.first else { throw ReadError("Choose PDFs to merge") }
        for source in sources {
            try validateDestination(source: source.url, destination: destination)
            try validatePasswordText(source.password)
        }
        let paths = sources.map { strdup($0.url.path) }, passwords = sources.map { strdup($0.password) }
        defer { paths.forEach { free($0) }; passwords.forEach { free($0) } }
        guard paths.allSatisfy({ $0 != nil }), passwords.allSatisfy({ $0 != nil }) else { throw ReadError("Cannot allocate PDF filenames") }
        let pathPointers = paths.map { $0.map { UnsafePointer($0) } }, passwordPointers = passwords.map { $0.map { UnsafePointer($0) } }
        typealias Merge = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>, UnsafePointer<UnsafePointer<CChar>?>, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<CChar>) -> Int32
        try withDestination(source: first.url, destination: destination) { temporary in
            try withEngine("lf_pdf_merge", as: Merge.self) { fn in
                var error = [CChar](repeating: 0, count: 512)
                try check(fn(Int32(sources.count), pathPointers, passwordPointers, temporary.path,
                             invalidateSignatures ? 1 : 0, &error), error: error)
            }
        }
    }
    // Nil preserves the source's stored permissions; a plain source grants all.
    // Explicit masks use CoreGraphics' eight operation bits.
    static func encrypt(source: URL, destination: URL, ownerPassword: String, userPassword: String = "", documentPassword: String = "", permissions: UInt? = nil, invalidateSignatures: Bool = false) throws {
        try validatePasswords(owner: ownerPassword, user: userPassword)
        try rewrite(source: source, destination: destination, operation: "encrypt", documentPassword: documentPassword, ownerPassword: ownerPassword, userPassword: userPassword, permissions: nativePermissions(permissions), invalidateSignatures: invalidateSignatures)
    }
    static func decrypt(source: URL, destination: URL, password: String, invalidateSignatures: Bool = false) throws {
        try rewrite(source: source, destination: destination, operation: "decrypt", documentPassword: password, invalidateSignatures: invalidateSignatures)
    }
    enum SigningIdentity: @unchecked Sendable {
        case pkcs12(URL, password: String)
        case keychain(SecIdentity)
    }

    static func sign(source: URL, destination: URL, identity: URL, password: String, fieldName: String = "Signature", page: Int = 0, bounds: CGRect = .zero, documentPassword: String = "", reason: String = "", location: String = "", image: URL? = nil, appearance: PDFSignatureAppearance = .standard) throws {
        try sign(source: source, destination: destination, identity: .pkcs12(identity, password: password), fieldName: fieldName,
            page: page, bounds: bounds, documentPassword: documentPassword, reason: reason, location: location, image: image, appearance: appearance)
    }

    static func sign(source: URL, destination: URL, identity: SecIdentity, fieldName: String = "Signature", page: Int = 0, bounds: CGRect = .zero, documentPassword: String = "", reason: String = "", location: String = "", image: URL? = nil, appearance: PDFSignatureAppearance = .standard) throws {
        try sign(source: source, destination: destination, identity: .keychain(identity), fieldName: fieldName,
            page: page, bounds: bounds, documentPassword: documentPassword, reason: reason, location: location, image: image, appearance: appearance)
    }

    static func sign(source: URL, destination: URL, identity: SigningIdentity, fieldName: String = "Signature", page: Int = 0, bounds: CGRect = .zero, boundsInPDFSpace: Bool = false, documentPassword: String = "", reason: String = "", location: String = "", image: URL? = nil, appearance: PDFSignatureAppearance = .standard) throws {
        try validateSignature(fieldName: fieldName, page: page, bounds: bounds)
        guard !reason.contains("\0"), !location.contains("\0"), appearance.rawValue & ~63 == 0 else { throw ReadError("Invalid signature appearance or metadata") }
        guard image?.isFileURL != false else { throw ReadError("Choose a local signature image") }
        try validatePasswordText(documentPassword)
        var path = "", password = "", reference: UnsafeRawPointer?
        switch identity {
        case .pkcs12(let url, let secret):
            guard url.isFileURL else { throw ReadError("Choose a local PKCS#12 file") }
            try validatePasswordText(secret); path = url.path; password = secret
        case .keychain(let identity): reference = UnsafeRawPointer(Unmanaged.passUnretained(identity).toOpaque())
        }
        try withExtendedLifetime(identity) {
            try withDestination(source: source, destination: destination, copyingSource: true) { temporary in
                try withEngine("lf_pdf_sign_with_identity", as: Sign.self) { fn in
                    var error = [CChar](repeating: 0, count: 512)
                    let box = bounds.raster.map(Float.init)
                    // Parse and append to the same copied snapshot. MuPDF alone
                    // converts selected PDF coordinates and owns the incremental writer.
                    let ok = box.withUnsafeBufferPointer { fn(temporary.path, temporary.path, documentPassword, path, password, reference, fieldName, Int32(page), $0.baseAddress!, boundsInPDFSpace ? 1 : 0, reason, location, image?.path ?? "", appearance.rawValue, &error) }
                    try check(ok, error: error)
                }
            }
        }
    }
    static func validatePasswords(owner: String, user: String) throws {
        guard !owner.isEmpty else { throw ReadError("An owner password is required") }
        guard owner.utf8.count <= 127, user.utf8.count <= 127, !owner.contains("\0"), !user.contains("\0") else {
            throw ReadError("PDF passwords must fit within 127 UTF-8 bytes and contain no NUL")
        }
    }
    static func validateSignature(fieldName: String, page: Int, bounds: CGRect) throws {
        // An author-provided unsigned field may legitimately be unnamed.
        // The native owner rejects an empty name only when creating a field.
        guard !fieldName.contains("\0") else { throw ReadError("Invalid signature field name") }
        guard page >= 0, page <= Int(Int32.max) else { throw ReadError("Signature page out of range") }
        guard (bounds.raster + [Double(bounds.maxX), Double(bounds.maxY)]).allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) }), bounds.width >= 0, bounds.height >= 0 else {
            throw ReadError("Invalid signature bounds")
        }
    }
    // PDFKit/CoreGraphics' eight operation bits and the PDF specification's
    // permission bits have different positions. Translate once at this boundary.
    private static func nativePermissions(_ permissions: UInt?) -> Int32 {
        guard let permissions else { return -1 }
        return permissionBits.enumerated().reduce(Int32(0)) { value, bit in
            value | ((permissions & (UInt(1) << bit.offset)) != 0 ? Int32(1) << bit.element : 0)
        }
    }
    private static func rewrite(source: URL, destination: URL, operation: String, documentPassword: String, ownerPassword: String = "", userPassword: String = "", permissions: Int32 = -1, invalidateSignatures: Bool = false) throws {
        try validatePasswordText(documentPassword)
        try withDestination(source: source, destination: destination) { temporary in
            try withEngine("lf_pdf_operation", as: Operation.self) { fn in
                var error = [CChar](repeating: 0, count: 512)
                let ok = fn(source.path, temporary.path, documentPassword, operation, ownerPassword, userPassword, permissions, invalidateSignatures ? 1 : 0, &error)
                try check(ok, error: error)
            }
        }
    }
    private static func validatePasswordText(_ password: String) throws {
        guard !password.contains("\0") else { throw ReadError("Passwords cannot contain NUL") }
    }
    static func validateDestination(source: URL, destination: URL) throws {
        guard source.isFileURL, destination.isFileURL else { throw ReadError("PDF tools require file URLs") }
        guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            throw ReadError("Choose a file destination, not a directory")
        }
        guard !PDFTools.sameFile(source, destination) else {
            throw ReadError("Choose a different output file to preserve the source PDF")
        }
    }
    private static func withDestination(source: URL, destination: URL, copyingSource: Bool = false, _ body: (URL) throws -> Void) throws {
        try validateDestination(source: source, destination: destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Sumra-PDF-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if copyingSource { try FileManager.default.copyItem(at: source.standardizedFileURL.resolvingSymlinksInPath(), to: temporary) }
        try body(temporary)
        // The temporary sibling is on the same filesystem; rename atomically
        // replaces an existing output without Foundation's backup/remove pass.
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    private static func withEngine<T>(_ name: String, as type: T.Type, _ body: (T) throws -> Void) throws {
        let path = try NativeFile.libraryURL(for: .mupdf)
        guard let library = dlopen(path.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load MuPDF PDF tools: \(dlerror().map { String(cString: $0) } ?? "unknown loader error")")
        }
        defer { dlclose(library) }
        guard let pointer = dlsym(library, name) else { throw ReadError("MuPDF engine lacks PDF tools: \(name)") }
        try body(unsafeBitCast(pointer, to: T.self))
    }
    private static func check(_ result: Int32, error: [CChar]) throws {
        guard result != 0 else {
            let message = String(cString: error)
            throw ReadError(message.isEmpty ? "PDF operation failed" : message)
        }
    }
}

#endif
