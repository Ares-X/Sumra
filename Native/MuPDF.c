#include "Engine.h"
#include "MuPDFDocument.h"
#include <mupdf/ucdn.h>
#include <CoreText/CoreText.h>
#include <pthread.h>
#include <ft2build.h>
#include FT_FREETYPE_H

static void lf_json_u32(SumraJSON *j, uint32_t value) {
    char number[16]; snprintf(number, sizeof(number), "%u", value); lf_json(j, number);
}
static int lf_has_html_source(SumraMuPDFDocument *d) {
    fz_buffer *source = fz_htdoc_source_document(d->ctx, d->doc);
    if (!source) return 0;
    fz_drop_buffer(d->ctx, source);
    return 1;
}

// HarfBuzz's allocator context is process-global even for independent books.
// Reuse MuPDF's required lock callbacks across every context in this dylib.
static pthread_mutex_t context_mutexes[FZ_LOCK_MAX] = {
    [FZ_LOCK_ALLOC] = PTHREAD_MUTEX_INITIALIZER,
    [FZ_LOCK_FREETYPE] = PTHREAD_MUTEX_INITIALIZER,
    [FZ_LOCK_GLYPHCACHE] = PTHREAD_MUTEX_INITIALIZER,
};
static void context_lock(void *user, int lock) { pthread_mutex_lock(&((pthread_mutex_t *)user)[lock]); }
static void context_unlock(void *user, int lock) { pthread_mutex_unlock(&((pthread_mutex_t *)user)[lock]); }
fz_context *lf_new_context(size_t max_store) {
    static const fz_locks_context locks = { context_mutexes, context_lock, context_unlock };
    return fz_new_context(NULL, &locks, max_store);
}

void lf_drop_render_page(SumraMuPDFDocument *d) {
    fz_drop_stext_page(d->ctx, d->text_page); d->text_page = NULL;
    fz_drop_device(d->ctx, d->color_analysis); d->color_analysis = NULL;
    fz_drop_display_list(d->ctx, d->display_list); d->display_list = NULL;
    fz_drop_page(d->ctx, d->render_page); d->render_page = NULL;
}
static fz_page *load_render_page(SumraMuPDFDocument *d, int chapter, int index, fz_cookie *cookie) {
    if (cookie && cookie->abort) fz_throw(d->ctx, FZ_ERROR_ABORT, "Reading cancelled");
    if (!d->render_page || d->render_chapter != chapter || d->render_index != index) {
        lf_drop_render_page(d);
        d->render_page = fz_load_chapter_page(d->ctx, d->doc, chapter, index);
        d->render_chapter = chapter; d->render_index = index;
    }
    if (cookie && cookie->abort) fz_throw(d->ctx, FZ_ERROR_ABORT, "Reading cancelled");
    return d->render_page;
}
static fz_display_list *page_display_list(SumraMuPDFDocument *d, int chapter, int index, fz_cookie *cookie);
API int lf_pdf_set_annotations_visible(void *opaque, int visible, char *error) {
    SumraMuPDFDocument *d = opaque; int ok = 0;
    fz_try(d->ctx) {
        if (!pdf_specifics(d->ctx, d->doc)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document is not a PDF");
        int hide = !visible;
        if (d->hide_annotations != hide) {
            d->hide_annotations = hide;
            fz_drop_device(d->ctx, d->color_analysis); d->color_analysis = NULL;
            fz_drop_display_list(d->ctx, d->display_list); d->display_list = NULL;
        }
        ok = 1;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); }
    return ok;
}
API char *lf_pdf_live_page_boxes(void *opaque, int index, char *error) {
    SumraMuPDFDocument *d = opaque; SumraJSON json = {0}; fz_var(json);
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (!pdf) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document is not a PDF");
        pdf_obj *page = pdf_lookup_page_obj(d->ctx, pdf, index);
        const fz_box_type types[] = { FZ_MEDIA_BOX, FZ_CROP_BOX, FZ_BLEED_BOX, FZ_TRIM_BOX, FZ_ART_BOX };
        pdf_obj *names[] = { PDF_NAME(MediaBox), PDF_NAME(CropBox), PDF_NAME(BleedBox), PDF_NAME(TrimBox), PDF_NAME(ArtBox) };
        lf_json(&json, "[");
        for (int i = 0; i < 5; ++i) {
            if (i) lf_json(&json, ",");
            // EngineMupdf::GetPdfPageBoxes shows declared/inherited boxes,
            // not the fallback geometry used when rendering a missing box.
            pdf_obj *declared = pdf_dict_get_inheritable(d->ctx, page, names[i]);
            if (!pdf_is_array(d->ctx, declared) || fz_is_empty_rect(pdf_to_rect(d->ctx, declared))) {
                lf_json(&json, "null"); continue;
            }
            fz_rect box; fz_matrix ctm;
            // Same geometry as pdf_bound_page, without loading the page's
            // content or annotations just to draw the optional box overlay.
            pdf_page_obj_transform_box(d->ctx, page, &box, &ctm, types[i]);
            box = fz_transform_rect(box, ctm);
            if (fz_is_empty_rect(box)) lf_json(&json, "null");
            else lf_json_rect(&json, box.x0, box.y0, box.x1-box.x0, box.y1-box.y0);
        }
        lf_json(&json, "]");
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}
// Sumatra's mupdf_load_system_font.c::load_and_cache_font shares file bytes,
// not fz_font: PDF font descriptors have independent widths/substitution flags.
typedef struct SystemFontFile {
    struct SystemFontFile *next;
    unsigned char *data;
    size_t size;
    char path[];
} SystemFontFile;
static SystemFontFile *system_font_files;
static pthread_mutex_t system_font_mutex = PTHREAD_MUTEX_INITIALIZER;

static SystemFontFile *find_system_font_file(const char *path) {
    for (SystemFontFile *file = system_font_files; file; file = file->next)
        if (!strcmp(file->path, path)) return file;
    return NULL;
}
static fz_buffer *load_system_font_data(fz_context *ctx, const char *path) {
    pthread_mutex_lock(&system_font_mutex);
    SystemFontFile *file = find_system_font_file(path);
    pthread_mutex_unlock(&system_font_mutex);
    if (!file) {
        SystemFontFile *loaded = NULL;
        fz_buffer *data = NULL;
        fz_var(loaded); fz_var(data);
        fz_try(ctx) {
            data = fz_read_file(ctx, path);
            loaded = fz_calloc(ctx, 1, sizeof(*loaded) + strlen(path) + 1);
            strcpy(loaded->path, path);
            loaded->size = fz_buffer_extract(ctx, data, &loaded->data);
            // Like upstream, read outside the lock and reuse a concurrent
            // winner. No allocation or throwing call runs while locked.
            pthread_mutex_lock(&system_font_mutex);
            file = find_system_font_file(path);
            if (!file) {
                loaded->next = system_font_files;
                system_font_files = file = loaded; loaded = NULL;
            }
            pthread_mutex_unlock(&system_font_mutex);
        }
        fz_always(ctx) {
            fz_drop_buffer(ctx, data);
            if (loaded) { fz_free(ctx, loaded->data); fz_free(ctx, loaded); }
        }
        fz_catch(ctx) { fz_rethrow(ctx); }
    }
    return fz_new_buffer_from_shared_data(ctx, file->data, file->size);
}
__attribute__((destructor)) static void drop_system_font_files(void) {
    // Callers drop documents/contexts before dlclose. lf_new_context uses the
    // default malloc allocator, as does Sumatra's destroy_system_font_list.
    while (system_font_files) {
        SystemFontFile *file = system_font_files;
        system_font_files = file->next;
        free(file->data); free(file);
    }
}

// CoreText locates installed fonts; MuPDF's bundled FreeType remains the sole
// font decoder. Match the PostScript name so TTC collections use the right face.
static fz_font *load_coretext_font(fz_context *ctx, CTFontRef font, const char *name, int exact, uint32_t codepoint) {
    CFStringRef postscript = CTFontCopyPostScriptName(font);
    CFURLRef url = CTFontCopyAttribute(font, kCTFontURLAttribute);
    char path[PATH_MAX], ps[512];
    int found = url && postscript && CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)) &&
        CFStringGetCString(postscript, ps, sizeof(ps), kCFStringEncodingUTF8);
    if (postscript) CFRelease(postscript); if (url) CFRelease(url);
    // LastResort draws missing-script boxes rather than the requested glyph.
    if (!found || !strcmp(ps, "LastResort") || (exact && strcmp(name, ps))) return NULL;
    fz_buffer *data = NULL; fz_font *result = NULL;
    fz_var(data); fz_var(result);
    fz_try(ctx) {
        data = load_system_font_data(ctx, path);
        int faces = 1;
        for (int i = 0; i < faces; ++i) {
            result = fz_new_font_from_buffer(ctx, NULL, data, i, 0);
            FT_Face face = fz_font_ft_face(ctx, result);
            fz_ft_lock(ctx);
            faces = face->num_faces;
            const char *actual = FT_Get_Postscript_Name(face);
            int matches = actual && !strcmp(actual, ps);
            fz_ft_unlock(ctx);
            if (matches) break;
            fz_drop_font(ctx, result); result = NULL;
        }
        // CoreText can choose a substitute; only an actual FreeType glyph
        // makes it a usable script fallback for MuPDF.
        if (result && codepoint && !fz_encode_character(ctx, result, codepoint)) {
            fz_drop_font(ctx, result); result = NULL;
        }
    }
    fz_always(ctx) { fz_drop_buffer(ctx, data); }
    fz_catch(ctx) {
        fz_drop_font(ctx, result); result = NULL;
        fz_warn(ctx, "Cannot load system font '%s': %s", name, fz_convert_error(ctx, NULL));
    }
    return result;
}
// Adopt the reference and preserve an available face if the requested style
// does not exist. MuPDF reads the resulting face's real style attributes.
static CTFontRef style_system_font(CTFontRef font, int bold, int italic) {
    CTFontSymbolicTraits traits = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(font, 0, NULL, traits, kCTFontBoldTrait | kCTFontItalicTrait);
    if (styled) { CFRelease(font); return styled; }
    return font;
}
static fz_font *load_system_font(fz_context *ctx, const char *name, int bold, int italic, int exact) {
    if (!name || !strcmp(name, "serif") || !strcmp(name, "sans-serif") || !strcmp(name, "monospace")) return NULL;
    CFStringRef requested = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (!requested) return NULL;
    CTFontRef font = CTFontCreateWithNameAndOptions(requested, 12, NULL,
        kCTFontOptionsPreventAutoActivation | kCTFontOptionsPreventAutoDownload);
    CFRelease(requested);
    if (!font) return NULL;
    font = style_system_font(font, bold, italic);
    fz_font *result = load_coretext_font(ctx, font, name, exact, 0);
    CFRelease(font);
    return result;
}
// These representatives select an installed face, not a promise of complete
// script coverage. CJK uses the compact bundled face, avoiding a full system
// TTC copy for default fallback. Explicit named document fonts remain available.
// Values follow the pinned MuPDF UCDN database.
static const uint32_t script_representatives[UCDN_LAST_SCRIPT + 1] = {
    [UCDN_SCRIPT_LATIN] = 0x41,
    [UCDN_SCRIPT_GREEK] = 0x391,
    [UCDN_SCRIPT_CYRILLIC] = 0x410,
    [UCDN_SCRIPT_ARMENIAN] = 0x531,
    [UCDN_SCRIPT_HEBREW] = 0x5D0,
    [UCDN_SCRIPT_ARABIC] = 0x627,
    [UCDN_SCRIPT_SYRIAC] = 0x710,
    [UCDN_SCRIPT_THAANA] = 0x780,
    [UCDN_SCRIPT_DEVANAGARI] = 0x915,
    [UCDN_SCRIPT_BENGALI] = 0x985,
    [UCDN_SCRIPT_GURMUKHI] = 0xA15,
    [UCDN_SCRIPT_GUJARATI] = 0xA95,
    [UCDN_SCRIPT_ORIYA] = 0xB15,
    [UCDN_SCRIPT_TAMIL] = 0xB85,
    [UCDN_SCRIPT_TELUGU] = 0xC15,
    [UCDN_SCRIPT_KANNADA] = 0xC85,
    [UCDN_SCRIPT_MALAYALAM] = 0xD05,
    [UCDN_SCRIPT_SINHALA] = 0xD9A,
    [UCDN_SCRIPT_THAI] = 0xE01,
    [UCDN_SCRIPT_LAO] = 0xE81,
    [UCDN_SCRIPT_TIBETAN] = 0xF40,
    [UCDN_SCRIPT_MYANMAR] = 0x1000,
    [UCDN_SCRIPT_GEORGIAN] = 0x10D0,
    [UCDN_SCRIPT_ETHIOPIC] = 0x1200,
    [UCDN_SCRIPT_CHEROKEE] = 0x13A0,
    [UCDN_SCRIPT_CANADIAN_ABORIGINAL] = 0x1401,
    [UCDN_SCRIPT_OGHAM] = 0x1681,
    [UCDN_SCRIPT_RUNIC] = 0x16A0,
    [UCDN_SCRIPT_KHMER] = 0x1780,
    [UCDN_SCRIPT_MONGOLIAN] = 0x1820,
    [UCDN_SCRIPT_YI] = 0xA000,
    [UCDN_SCRIPT_OLD_ITALIC] = 0x10300,
    [UCDN_SCRIPT_GOTHIC] = 0x10330,
    [UCDN_SCRIPT_DESERET] = 0x10400,
    [UCDN_SCRIPT_INHERITED] = 0x301,
    [UCDN_SCRIPT_TAGALOG] = 0x1700,
    [UCDN_SCRIPT_HANUNOO] = 0x1720,
    [UCDN_SCRIPT_BUHID] = 0x1740,
    [UCDN_SCRIPT_TAGBANWA] = 0x1760,
    [UCDN_SCRIPT_LIMBU] = 0x1900,
    [UCDN_SCRIPT_TAI_LE] = 0x1950,
    [UCDN_SCRIPT_LINEAR_B] = 0x10000,
    [UCDN_SCRIPT_UGARITIC] = 0x10380,
    [UCDN_SCRIPT_SHAVIAN] = 0x10450,
    [UCDN_SCRIPT_OSMANYA] = 0x10480,
    [UCDN_SCRIPT_CYPRIOT] = 0x10800,
    [UCDN_SCRIPT_BRAILLE] = 0x2801,
    [UCDN_SCRIPT_BUGINESE] = 0x1A00,
    [UCDN_SCRIPT_COPTIC] = 0x3E2,
    [UCDN_SCRIPT_NEW_TAI_LUE] = 0x1980,
    [UCDN_SCRIPT_GLAGOLITIC] = 0x2C00,
    [UCDN_SCRIPT_TIFINAGH] = 0x2D30,
    [UCDN_SCRIPT_SYLOTI_NAGRI] = 0xA800,
    [UCDN_SCRIPT_OLD_PERSIAN] = 0x103A0,
    [UCDN_SCRIPT_KHAROSHTHI] = 0x10A00,
    [UCDN_SCRIPT_BALINESE] = 0x1B05,
    [UCDN_SCRIPT_CUNEIFORM] = 0x12000,
    [UCDN_SCRIPT_PHOENICIAN] = 0x10900,
    [UCDN_SCRIPT_PHAGS_PA] = 0xA840,
    [UCDN_SCRIPT_NKO] = 0x7CA,
    [UCDN_SCRIPT_SUNDANESE] = 0x1B83,
    [UCDN_SCRIPT_LEPCHA] = 0x1C00,
    [UCDN_SCRIPT_OL_CHIKI] = 0x1C5A,
    [UCDN_SCRIPT_VAI] = 0xA500,
    [UCDN_SCRIPT_SAURASHTRA] = 0xA882,
    [UCDN_SCRIPT_KAYAH_LI] = 0xA90A,
    [UCDN_SCRIPT_REJANG] = 0xA930,
    [UCDN_SCRIPT_LYCIAN] = 0x10280,
    [UCDN_SCRIPT_CARIAN] = 0x102A0,
    [UCDN_SCRIPT_LYDIAN] = 0x10920,
    [UCDN_SCRIPT_CHAM] = 0xAA00,
    [UCDN_SCRIPT_TAI_THAM] = 0x1A20,
    [UCDN_SCRIPT_TAI_VIET] = 0xAA80,
    [UCDN_SCRIPT_AVESTAN] = 0x10B00,
    [UCDN_SCRIPT_EGYPTIAN_HIEROGLYPHS] = 0x13000,
    [UCDN_SCRIPT_SAMARITAN] = 0x800,
    [UCDN_SCRIPT_LISU] = 0xA4D0,
    [UCDN_SCRIPT_BAMUM] = 0xA6A0,
    [UCDN_SCRIPT_JAVANESE] = 0xA984,
    [UCDN_SCRIPT_MEETEI_MAYEK] = 0xAAE0,
    [UCDN_SCRIPT_IMPERIAL_ARAMAIC] = 0x10840,
    [UCDN_SCRIPT_OLD_SOUTH_ARABIAN] = 0x10A60,
    [UCDN_SCRIPT_INSCRIPTIONAL_PARTHIAN] = 0x10B40,
    [UCDN_SCRIPT_INSCRIPTIONAL_PAHLAVI] = 0x10B60,
    [UCDN_SCRIPT_OLD_TURKIC] = 0x10C00,
    [UCDN_SCRIPT_KAITHI] = 0x11083,
    [UCDN_SCRIPT_BATAK] = 0x1BC0,
    [UCDN_SCRIPT_BRAHMI] = 0x11003,
    [UCDN_SCRIPT_MANDAIC] = 0x840,
    [UCDN_SCRIPT_CHAKMA] = 0x11103,
    [UCDN_SCRIPT_MEROITIC_CURSIVE] = 0x109A0,
    [UCDN_SCRIPT_MEROITIC_HIEROGLYPHS] = 0x10980,
    [UCDN_SCRIPT_MIAO] = 0x16F00,
    [UCDN_SCRIPT_SHARADA] = 0x11183,
    [UCDN_SCRIPT_SORA_SOMPENG] = 0x110D0,
    [UCDN_SCRIPT_TAKRI] = 0x11680,
    [UCDN_SCRIPT_BASSA_VAH] = 0x16AD0,
    [UCDN_SCRIPT_CAUCASIAN_ALBANIAN] = 0x10530,
    [UCDN_SCRIPT_DUPLOYAN] = 0x1BC00,
    [UCDN_SCRIPT_ELBASAN] = 0x10500,
    [UCDN_SCRIPT_GRANTHA] = 0x11305,
    [UCDN_SCRIPT_KHOJKI] = 0x11200,
    [UCDN_SCRIPT_KHUDAWADI] = 0x112B0,
    [UCDN_SCRIPT_LINEAR_A] = 0x10600,
    [UCDN_SCRIPT_MAHAJANI] = 0x11150,
    [UCDN_SCRIPT_MANICHAEAN] = 0x10AC0,
    [UCDN_SCRIPT_MENDE_KIKAKUI] = 0x1E800,
    [UCDN_SCRIPT_MODI] = 0x11600,
    [UCDN_SCRIPT_MRO] = 0x16A40,
    [UCDN_SCRIPT_NABATAEAN] = 0x10880,
    [UCDN_SCRIPT_OLD_NORTH_ARABIAN] = 0x10A80,
    [UCDN_SCRIPT_OLD_PERMIC] = 0x10350,
    [UCDN_SCRIPT_PAHAWH_HMONG] = 0x16B00,
    [UCDN_SCRIPT_PALMYRENE] = 0x10860,
    [UCDN_SCRIPT_PAU_CIN_HAU] = 0x11AC0,
    [UCDN_SCRIPT_PSALTER_PAHLAVI] = 0x10B80,
    [UCDN_SCRIPT_SIDDHAM] = 0x11580,
    [UCDN_SCRIPT_TIRHUTA] = 0x11480,
    [UCDN_SCRIPT_WARANG_CITI] = 0x118A0,
    [UCDN_SCRIPT_AHOM] = 0x11700,
    [UCDN_SCRIPT_ANATOLIAN_HIEROGLYPHS] = 0x14400,
    [UCDN_SCRIPT_HATRAN] = 0x108E0,
    [UCDN_SCRIPT_MULTANI] = 0x11280,
    [UCDN_SCRIPT_OLD_HUNGARIAN] = 0x10C80,
    [UCDN_SCRIPT_SIGNWRITING] = 0x1D800,
    [UCDN_SCRIPT_ADLAM] = 0x1E900,
    [UCDN_SCRIPT_BHAIKSUKI] = 0x11C00,
    [UCDN_SCRIPT_MARCHEN] = 0x11C72,
    [UCDN_SCRIPT_NEWA] = 0x11400,
    [UCDN_SCRIPT_OSAGE] = 0x104B0,
    [UCDN_SCRIPT_TANGUT] = 0x17000,
    [UCDN_SCRIPT_MASARAM_GONDI] = 0x11D00,
    [UCDN_SCRIPT_NUSHU] = 0x1B170,
    [UCDN_SCRIPT_SOYOMBO] = 0x11A50,
    [UCDN_SCRIPT_ZANABAZAR_SQUARE] = 0x11A00,
    [UCDN_SCRIPT_DOGRA] = 0x11800,
    [UCDN_SCRIPT_GUNJALA_GONDI] = 0x11D60,
    [UCDN_SCRIPT_HANIFI_ROHINGYA] = 0x10D00,
    [UCDN_SCRIPT_MAKASAR] = 0x11EE0,
    [UCDN_SCRIPT_MEDEFAIDRIN] = 0x16E40,
    [UCDN_SCRIPT_OLD_SOGDIAN] = 0x10F00,
    [UCDN_SCRIPT_SOGDIAN] = 0x10F30,
    [UCDN_SCRIPT_ELYMAIC] = 0x10FE0,
    [UCDN_SCRIPT_NANDINAGARI] = 0x119A0,
    [UCDN_SCRIPT_NYIAKENG_PUACHUE_HMONG] = 0x1E100,
    [UCDN_SCRIPT_WANCHO] = 0x1E2C0,
    [UCDN_SCRIPT_CHORASMIAN] = 0x10FB0,
    [UCDN_SCRIPT_DIVES_AKURU] = 0x11900,
    [UCDN_SCRIPT_KHITAN_SMALL_SCRIPT] = 0x18B00,
    [UCDN_SCRIPT_YEZIDI] = 0x10E80,
    [UCDN_SCRIPT_VITHKUQI] = 0x10570,
    [UCDN_SCRIPT_OLD_UYGHUR] = 0x10F70,
    [UCDN_SCRIPT_CYPRO_MINOAN] = 0x12F90,
    [UCDN_SCRIPT_TANGSA] = 0x16A70,
    [UCDN_SCRIPT_TOTO] = 0x1E290,
    [UCDN_SCRIPT_KAWI] = 0x11F02,
    [UCDN_SCRIPT_NAG_MUNDARI] = 0x1E4D0,
    [UCDN_SCRIPT_TODHRI] = 0x105C0,
    [UCDN_SCRIPT_GARAY] = 0x10D4A,
    [UCDN_SCRIPT_TULU_TIGALARI] = 0x11380,
    [UCDN_SCRIPT_SUNUWAR] = 0x11BC0,
    [UCDN_SCRIPT_GURUNG_KHEMA] = 0x16100,
    [UCDN_SCRIPT_KIRAT_RAI] = 0x16D40,
    [UCDN_SCRIPT_OL_ONAL] = 0x1E5D0,
};
static fz_font *load_system_script_font(fz_context *ctx, uint32_t codepoint, int language, int serif, int bold, int italic) {
    UniChar chars[2]; CFIndex count = 1;
    if (codepoint > 0xFFFF) {
        chars[0] = 0xD800 + ((codepoint - 0x10000) >> 10);
        chars[1] = 0xDC00 + ((codepoint - 0x10000) & 0x3FF); count = 2;
    } else chars[0] = codepoint;
    CFStringRef sample = CFStringCreateWithCharacters(NULL, chars, count);
    if (!sample) return NULL;
    CTFontRef base = CTFontCreateWithNameAndOptions(serif ? CFSTR("Times") : CFSTR("Helvetica"), 12, NULL,
        kCTFontOptionsPreventAutoActivation | kCTFontOptionsPreventAutoDownload);
    if (!base) { CFRelease(sample); return NULL; }
    base = style_system_font(base, bold, italic);
    char language_name[8];
    fz_string_from_text_language(language_name, language);
    CFStringRef locale = language_name[0] ? CFStringCreateWithCString(NULL, language_name, kCFStringEncodingUTF8) : NULL;
    CTFontRef font = CTFontCreateForStringWithLanguage(base, sample, CFRangeMake(0, count), locale);
    if (locale) CFRelease(locale);
    CFRelease(base); CFRelease(sample);
    if (!font) return NULL;
    font = style_system_font(font, bold, italic);
    fz_font *result = load_coretext_font(ctx, font, "script fallback", 0, codepoint);
    CFRelease(font);
    // fz_new_font_from_buffer retains these bytes and reads the face's real
    // embedding restrictions. Embedded document fonts never take this path.
    return result;
}
static fz_font *load_system_fallback_font(fz_context *ctx, int script, int language, int serif, int bold, int italic) {
    if (script < 0 || script > UCDN_LAST_SCRIPT || !script_representatives[script]) return NULL;
    return load_system_script_font(ctx, script_representatives[script], language, serif, bold, italic);
}
void lf_install_system_fonts(fz_context *ctx) {
    // PDF CID substitutes use the bundled wide CJK face: that path has no
    // per-character fallback. Unicode/reflow also keeps bundled CJK; other
    // scripts can use the installed system fonts through the existing callback.
    fz_install_load_system_font_funcs(ctx, load_system_font, NULL, load_system_fallback_font);
}
// Sumatra's EPUB image fix (#5805): publisher height:100% collapses
// images in flow containers without a fixed height.
static const char *image_css = "img { height: auto !important; max-width: 100% !important; }\n";
// LegacyText's extracted KF8 resources retain their MOBI-relative indexes.
// Reuse MuPDF's public MOBI HTML adapter and its existing typography rules.
static const fz_htdoc_format mobi_html = { "MOBI", NULL, 1, 1, FZ_HTML_FLAVOR_MOBI };
API void lf_close(SumraMuPDFDocument *d) {
    if (!d) return;
    lf_drop_render_page(d);
    fz_drop_document(d->ctx, d->doc); fz_drop_context(d->ctx); free(d);
}
typedef enum { INPUT_DEFAULT, INPUT_MARKDOWN, INPUT_MOBI_HTML, INPUT_XPS } InputKind;
static InputKind input_kind(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return INPUT_DEFAULT;
    if (!strcasecmp(ext, ".md") || !strcasecmp(ext, ".markdown")) return INPUT_MARKDOWN;
    if (!strcasecmp(ext, ".mobihtml")) return INPUT_MOBI_HTML;
    if (!strcasecmp(ext, ".xod") || !strcasecmp(ext, ".dwfx")) return INPUT_XPS;
    return INPUT_DEFAULT;
}

// Recognize input without opening a PDF, enabling its journal, or executing its
// document-level JavaScript. Swift snapshots PDFs before authenticated opening.
API int lf_pdf_source(const char *path, char *error) {
    fz_context *ctx = lf_new_context(0);
    if (!ctx) { snprintf(error, 512, "Cannot create MuPDF context"); return -1; }
    fz_stream *stream = NULL; fz_var(stream);
    int result = -1; fz_var(result);
    fz_try(ctx) {
        fz_register_document_handlers(ctx);
        InputKind kind = input_kind(path);
        if (kind == INPUT_MOBI_HTML || kind == INPUT_XPS) result = 0;
        else {
            stream = fz_open_file(ctx, path);
            const char *magic = kind == INPUT_MARKDOWN ? "" : path;
            const fz_document_handler *handler = fz_recognize_document_stream_content(ctx, stream, magic);
            result = handler && handler == fz_recognize_document(ctx, "application/pdf");
        }
    }
    fz_always(ctx) { fz_drop_stream(ctx, stream); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx);
    return result;
}

static void *open_document_input(const char *path, const char *password, int *needs_password, char *error, int expected_pdf, int defer_markdown_layout) {
    if (needs_password) *needs_password = 0;
    if (!path || !*path) { snprintf(error, 512, "Missing document path"); return NULL; }
    SumraMuPDFDocument *d = calloc(1, sizeof(*d));
    if (!d) { snprintf(error, 512, "Cannot allocate document"); return NULL; }
    d->ctx = lf_new_context(FZ_STORE_DEFAULT);
    if (!d->ctx) { snprintf(error, 512, "Cannot create MuPDF context"); free(d); return NULL; }
    fz_try(d->ctx) {
        fz_register_document_handlers(d->ctx);
        lf_install_system_fonts(d->ctx);
        InputKind kind = input_kind(path);
        int markdown = kind == INPUT_MARKDOWN;
        if (markdown || kind == INPUT_MOBI_HTML) {
            // EngineMupdf::Load supplies Markdown's parent directory for images.
            // Explicit magic also covers .markdown, absent from MuPDF's suffix list.
            char directory[PATH_MAX];
            fz_dirname(directory, path, sizeof(directory));
            fz_archive *dir = NULL;
            fz_stream *stream = NULL;
            fz_var(dir); fz_var(stream);
            fz_try(d->ctx) {
                dir = fz_open_directory(d->ctx, directory);
                stream = fz_open_file(d->ctx, path);
                if (markdown) {
                    // A PDF may have a Markdown filename and heading-like leading
                    // garbage. Preserve content recognition before adding MIME weight.
                    const fz_document_handler *actual = fz_recognize_document_stream_content(d->ctx, stream, "");
                    const char *magic = actual && actual == fz_recognize_document(d->ctx, "application/pdf")
                        ? "application/pdf" : "text/markdown";
                    d->doc = fz_open_document_with_stream_and_dir(d->ctx, magic, stream, dir);
                } else d->doc = fz_htdoc_open_document_with_stream_and_dir(d->ctx, stream, dir, &mobi_html);
            }
            fz_always(d->ctx) { fz_drop_stream(d->ctx, stream); fz_drop_archive(d->ctx, dir); }
            fz_catch(d->ctx) { fz_rethrow(d->ctx); }
        } else if (kind == INPUT_XPS) {
            fz_stream *s = fz_open_file(d->ctx, path);
            fz_try(d->ctx) { d->doc = fz_open_document_with_stream(d->ctx, "xps", s); }
            fz_always(d->ctx) { fz_drop_stream(d->ctx, s); }
            fz_catch(d->ctx) { fz_rethrow(d->ctx); }
        } else d->doc = fz_open_document(d->ctx, path);
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (expected_pdf >= 0 && !!pdf != expected_pdf)
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "The file changed while opening. Open it again.");
        if (fz_needs_password(d->ctx, d->doc) && (!password || !*password)) {
            if (needs_password) *needs_password = 1;
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document requires a password");
        }
        d->authentication = fz_authenticate_password(d->ctx, d->doc, password ? password : "");
        if (!d->authentication) {
            if (needs_password) *needs_password = 1;
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Incorrect document password");
        }
        if (pdf) {
            // EngineMupdf::FinishLoading keeps journal and MuJS on the same
            // document/context used to render, edit and eventually save it.
            pdf_enable_journal(d->ctx, pdf);
            pdf_enable_js(d->ctx, pdf);
            int steps;
            d->saved_journal_position = pdf_undoredo_state(d->ctx, pdf, &steps);
        }
        if (fz_is_document_reflowable(d->ctx, d->doc) && !(defer_markdown_layout && markdown && !pdf)) {
            fz_style_document(d->ctx, d->doc, 1, image_css);
            fz_layout_document(d->ctx, d->doc, 420, 595, 11);
        }
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); lf_close(d); return NULL; }
    return d;
}
API void *lf_open_classified(const char *path, const char *password, int *needs_password, char *error, int expected_pdf) {
    return open_document_input(path, password, needs_password, error, expected_pdf, 0);
}
API void *lf_open_classified_deferred(const char *path, const char *password, int *needs_password, char *error, int expected_pdf) {
    return open_document_input(path, password, needs_password, error, expected_pdf, 1);
}
API char *lf_pdf_document_info(void *opaque, char *error) {
    SumraMuPDFDocument *d = opaque;
    SumraJSON json = {0}; fz_var(json);
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (!pdf) {
            lf_json(&json, "null");
        } else {
            pdf_obj *root = pdf_dict_get(d->ctx, pdf_trailer(d->ctx, pdf), PDF_NAME(Root));
            pdf_obj *preferences = pdf_dict_gets(d->ctx, root, "ViewerPreferences");
            int position = -1, steps = 0; fz_var(position); fz_var(steps);
            // EngineMupdfUndoPos: an open annotation/appearance operation has
            // no stable undo state yet. Other failures retain their cause.
            if (!d->journal_nesting) {
                fz_try(d->ctx) { position = pdf_undoredo_state(d->ctx, pdf, &steps); }
                fz_catch(d->ctx) {
                    if (fz_caught(d->ctx) != FZ_ERROR_ARGUMENT) fz_rethrow(d->ctx);
                    fz_ignore_error(d->ctx);
                }
            }
            lf_json(&json, "{\"pageCount\":"); lf_json_number(&json, pdf_count_pages(d->ctx, pdf));
            lf_json(&json, ",\"permissions\":{");
            const struct { const char *name; fz_permission value; } permissions[] = {
                { "copy", FZ_PERMISSION_COPY }, { "print", FZ_PERMISSION_PRINT },
                { "printHighQuality", FZ_PERMISSION_PRINT_HQ }, { "annotate", FZ_PERMISSION_ANNOTATE },
                { "form", FZ_PERMISSION_FORM }, { "assemble", FZ_PERMISSION_ASSEMBLE },
                { "edit", FZ_PERMISSION_EDIT }, { "accessibility", FZ_PERMISSION_ACCESSIBILITY }
            };
            for (size_t i = 0; i < sizeof(permissions)/sizeof(permissions[0]); ++i) {
                if (i) lf_json(&json, ",");
                lf_json_string(&json, permissions[i].name); lf_json(&json, ":");
                lf_json(&json, pdf_has_permission(d->ctx, pdf, permissions[i].value) ? "true" : "false");
            }
            // Match the rewrite owner's access boundary: unencrypted documents
            // (1) and owner authentication (4) require no further password.
            lf_json(&json, "},\"ownerAuthenticated\":"); lf_json(&json, d->authentication & 5 ? "true" : "false");
            lf_json(&json, ",\"editingEnabled\":"); lf_json(&json, d->editing_enabled ? "true" : "false");
            lf_json(&json, ",\"hasPageLabels\":");
            lf_json(&json, pdf_is_dict(d->ctx, pdf_dict_get(d->ctx, root, PDF_NAME(PageLabels))) ? "true" : "false");
            lf_json(&json, ",\"layout\":");
            pdf_obj *value = pdf_dict_gets(d->ctx, root, "PageLayout");
            if (pdf_is_name(d->ctx, value)) lf_json_string(&json, pdf_to_name(d->ctx, value)); else lf_json(&json, "null");
            lf_json(&json, ",\"pageMode\":");
            value = pdf_dict_get(d->ctx, root, PDF_NAME(PageMode));
            if (pdf_is_name(d->ctx, value)) lf_json_string(&json, pdf_to_name(d->ctx, value)); else lf_json(&json, "null");
            // GetPreferredLayout/GetPdfViewerPrintPrefs read only the catalog;
            // loading information never enumerates all pages or annotations.
            lf_json(&json, ",\"viewerPreferences\":{");
            const struct { const char *pdf_name; const char *key; } names[] = {
                { "Direction", "direction" }, { "PrintScaling", "printScaling" }, { "Duplex", "duplex" }
            };
            int first = 1;
            for (size_t i = 0; i < sizeof(names)/sizeof(names[0]); ++i) {
                value = pdf_dict_gets(d->ctx, preferences, names[i].pdf_name);
                if (!pdf_is_name(d->ctx, value)) continue;
                if (!first) lf_json(&json, ","); first = 0;
                lf_json_string(&json, names[i].key); lf_json(&json, ":"); lf_json_string(&json, pdf_to_name(d->ctx, value));
            }
            value = pdf_dict_gets(d->ctx, preferences, "PickTrayByPDFSize");
            if (pdf_is_bool(d->ctx, value)) {
                if (!first) lf_json(&json, ","); first = 0;
                lf_json(&json, "\"pickTrayByPDFSize\":"); lf_json(&json, pdf_to_bool(d->ctx, value) ? "true" : "false");
            }
            value = pdf_dict_gets(d->ctx, preferences, "NumCopies");
            if (pdf_is_int(d->ctx, value)) {
                if (!first) lf_json(&json, ",");
                lf_json(&json, "\"numCopies\":"); lf_json_number(&json, pdf_to_int(d->ctx, value));
            }
            lf_json(&json, "},\"dirty\":");
            int dirty = position >= 0 ? position != d->saved_journal_position : pdf_has_unsaved_changes(d->ctx, pdf);
            lf_json(&json, dirty ? "true" : "false");
            lf_json(&json, ",\"undoPosition\":"); lf_json_number(&json, position);
            lf_json(&json, ",\"undoSteps\":"); lf_json_number(&json, steps);
            lf_json(&json, ",\"undoTitle\":");
            const char *title = position > 0 ? pdf_undoredo_step(d->ctx, pdf, position - 1) : NULL;
            if (title) lf_json_string(&json, title); else lf_json(&json, "null");
            lf_json(&json, ",\"redoTitle\":");
            title = position >= 0 && position < steps ? pdf_undoredo_step(d->ctx, pdf, position) : NULL;
            if (title) lf_json_string(&json, title); else lf_json(&json, "null");
            lf_json(&json, "}");
        }
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}
API char *lf_pdf_page_label(void *opaque, int page, char *error) {
    SumraMuPDFDocument *d = opaque;
    char *label = NULL; fz_var(label);
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (!pdf) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document is not a PDF");
        if (page < 0 || page >= pdf_count_pages(d->ctx, pdf)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Page out of range");
        // pdf_page_label has no size query. Grow only this requested label so
        // a publisher's Unicode prefix is not silently truncated.
        for (size_t capacity = 256;; capacity *= 2) {
            char *next = realloc(label, capacity);
            if (!next) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "Cannot allocate page label");
            label = next;
            pdf_page_label(d->ctx, pdf, page, label, capacity);
            if (strlen(label) < capacity - 1) break;
            if (capacity > SIZE_MAX / 2) fz_throw(d->ctx, FZ_ERROR_LIMIT, "Page label is too large");
        }
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(label); return NULL; }
    return label;
}
API int lf_count_error(SumraMuPDFDocument *d, char *error) {
    int n = 0; fz_var(n);
    fz_try(d->ctx) { n = fz_count_pages(d->ctx, d->doc); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return -1; }
    return n;
}
API int lf_count(SumraMuPDFDocument *d) { char error[512]; return lf_count_error(d, error); }
API char *lf_html_source(SumraMuPDFDocument *d, char *error) {
    fz_buffer *buffer = NULL; char *out = NULL; fz_var(buffer); fz_var(out);
    fz_try(d->ctx) {
        buffer = fz_htdoc_source_document(d->ctx, d->doc);
        if (buffer) {
            out = strdup(fz_string_from_buffer(d->ctx, buffer));
            if (!out) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "Cannot copy generated HTML");
        }
    }
    fz_always(d->ctx) { fz_drop_buffer(d->ctx, buffer); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(out); return NULL; }
    return out;
}
API char *lf_metadata(SumraMuPDFDocument *d, char *error) {
    const char *keys[] = { "format", "encryption", "info:Title", "info:Author", "info:Subject", "info:Keywords",
        "info:Creator", "info:Producer", "info:CreationDate", "info:ModDate", "info:ReadingDirection", "info:EPUBLayout", NULL };
    SumraJSON json = {0}; char *value = NULL; int first = 1;
    fz_var(json); fz_var(value);
    fz_try(d->ctx) {
        lf_json(&json, "{");
        for (int i = 0; keys[i]; ++i) {
            int size = fz_lookup_metadata(d->ctx, d->doc, keys[i], NULL, 0);
            if (size <= 1) continue;
            value = fz_malloc(d->ctx, size);
            if (fz_lookup_metadata(d->ctx, d->doc, keys[i], value, size) > 0) {
                if (!first) lf_json(&json, ","); first = 0;
                lf_json_string(&json, !strncmp(keys[i], "info:", 5) ? keys[i]+5 : keys[i]);
                lf_json(&json, ":"); lf_json_string(&json, value);
            }
            fz_free(d->ctx, value); value = NULL;
        }
        lf_json(&json, "}");
    }
    fz_always(d->ctx) { fz_free(d->ctx, value); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}
API int lf_reflowable(SumraMuPDFDocument *d) { return fz_is_document_reflowable(d->ctx, d->doc); }
API int lf_relayout_css(SumraMuPDFDocument *d, float em, const char *css, int publisher_css, char *error) {
    if (!fz_is_document_reflowable(d->ctx, d->doc)) return 0;
    lf_drop_render_page(d);
    int n = 0; fz_buffer *style = NULL; fz_var(n); fz_var(style);
    fz_try(d->ctx) {
        style = fz_new_buffer_from_printf(d->ctx, "%s%s", image_css, css ? css : "");
        fz_style_document(d->ctx, d->doc, publisher_css != 0, fz_string_from_buffer(d->ctx, style));
        fz_layout_document(d->ctx, d->doc, 420, 595, em > 0 ? em : 11);
        n = 1;
    }
    fz_always(d->ctx) { fz_drop_buffer(d->ctx, style); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return -1; }
    return n;
}
// Explicit locations avoid fz_load_page's scan/count of every preceding chapter.
static fz_stext_page *stext_at(SumraMuPDFDocument *d, int chapter, int index, fz_stext_options *options, fz_cookie *cookie) {
    fz_page *page = load_render_page(d, chapter, index, cookie);
    // EngineBase::GetTextForPage caches extracted text between drag events.
    // Keep the existing contents-only extraction semantics; image-preserving
    // requests have different options and do not replace the text cache.
    if (!options && d->text_page) return fz_keep_stext_page(d->ctx, d->text_page);
    fz_stext_options clipped = options ? *options : (fz_stext_options){0};
    if (fz_is_epub_chapter_fixed(d->ctx, d->doc, chapter)) clipped.flags |= FZ_STEXT_CLIP;
    fz_stext_page *text = fz_new_stext_page_from_page_with_cookie(d->ctx, page, &clipped, cookie);
    if (cookie && cookie->abort) {
        fz_drop_stext_page(d->ctx, text);
        fz_throw(d->ctx, FZ_ERROR_ABORT, "Text extraction cancelled");
    }
    if (!options) d->text_page = fz_keep_stext_page(d->ctx, text);
    return text;
}
API int lf_chapters(SumraMuPDFDocument *d, char *error) {
    int n = 0; fz_var(n);
    fz_try(d->ctx) { n = fz_count_chapters(d->ctx, d->doc); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return -1; }
    return n;
}
API int lf_chapter_pages(SumraMuPDFDocument *d, int chapter, char *error) {
    int n = 0; fz_var(n);
    fz_try(d->ctx) { n = fz_count_chapter_pages(d->ctx, d->doc, chapter); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return -1; }
    return n;
}
API int lf_bounds_at(SumraMuPDFDocument *d, int chapter, int index, float *bounds, char *error) {
    fz_page *p = NULL; fz_var(p);
    fz_try(d->ctx) {
        fz_rect r;
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (pdf) {
            if (chapter != 0 || index < 0 || index >= pdf_count_pages(d->ctx, pdf))
                fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Page out of range");
            // EngineMupdf::FinishLoading reads geometry without loading every
            // page's annotations, links and transparency resources.
            pdf_obj *page = pdf_lookup_page_obj(d->ctx, pdf, index);
            fz_matrix ctm;
            pdf_page_obj_transform(d->ctx, page, &r, &ctm);
            r = fz_transform_rect(r, ctm);
        } else {
            p = fz_load_chapter_page(d->ctx, d->doc, chapter, index);
            r = fz_bound_page(d->ctx, p);
        }
        bounds[0] = r.x0; bounds[1] = r.y0; bounds[2] = r.x1-r.x0; bounds[3] = r.y1-r.y0;
    }
    fz_always(d->ctx) { fz_drop_page(d->ctx, p); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return 0; }
    return 1;
}
API int lf_content_bounds_at(void *opaque, int chapter, int index, float *bounds, void *opaque_cookie, char *error) {
    SumraMuPDFDocument *d = opaque;
    fz_cookie *cookie = opaque_cookie;
    fz_device *device = NULL; fz_rect content = fz_empty_rect;
    fz_var(device); fz_var(content);
    fz_try(d->ctx) {
        // EngineMupdf::PageContentBox replays the same cached View list used
        // by rendering rather than interpreting the page's resources twice.
        fz_display_list *list = page_display_list(d, chapter, index, cookie);
        fz_rect page_box = fz_bound_page(d->ctx, d->render_page);
        device = fz_new_bbox_device(d->ctx, &content);
        fz_run_display_list(d->ctx, list, device, fz_identity, page_box, cookie);
        if (cookie && cookie->abort) fz_throw(d->ctx, FZ_ERROR_ABORT, "Content measurement cancelled");
        fz_close_device(d->ctx, device);
        content = fz_intersect_rect(content, page_box);
        if (fz_is_empty_rect(content) || !isfinite(content.x0) || !isfinite(content.y0) ||
            !isfinite(content.x1) || !isfinite(content.y1)) content = page_box;
        bounds[0] = content.x0; bounds[1] = content.y0; bounds[2] = content.x1-content.x0; bounds[3] = content.y1-content.y0;
    }
    fz_always(d->ctx) {
        if (cookie && cookie->abort && device) device->close_device = NULL;
        fz_drop_device(d->ctx, device);
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return 0; }
    return 1;
}
static int write_pdf(SumraMuPDFDocument *d, const char *path, const int *pages, int page_count,
        const float *regions, const int *region_counts, int rotation, int printing, float *content_bounds, int bounds_count,
        fz_cookie *cookie, int (*cancelled)(void), char *error) {
    fz_document_writer *writer = NULL; fz_page *page = NULL; fz_path *clip = NULL; fz_device *device = NULL;
    fz_display_list *list = NULL; fz_device *measure = NULL;
    fz_var(writer); fz_var(page); fz_var(clip); fz_var(device); fz_var(list); fz_var(measure);
    fz_try(d->ctx) {
        if (printing) {
            pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
            if (!pdf) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document is not a PDF");
            // EngineMupdf::AllowsPrinting/Print.cpp use PRINT, not COPY or an
            // invented raster fallback for the separately reported PRINT_HQ bit.
            if (!pdf_has_permission(d->ctx, pdf, FZ_PERMISSION_PRINT))
                fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "This PDF does not allow printing");
            if (rotation % 90 || (regions && (!pages || !region_counts))) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid print selection");
        }
        int count = fz_count_pages(d->ctx, d->doc);
        if (printing && count <= 0) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "This PDF has no pages to print");
        if (pages) {
            if (page_count <= 0) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Choose at least one page to export");
            for (int i = 0; i < page_count; ++i)
                if (pages[i] < 0 || pages[i] >= count) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Page out of range");
        } else page_count = count;
        if (content_bounds && bounds_count != page_count)
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid print bounds buffer");
        if ((cookie && cookie->abort) || (cancelled && cancelled())) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF output cancelled");
        char format[32] = {0};
        int subset_markdown = !printing &&
            fz_lookup_metadata(d->ctx, d->doc, FZ_META_FORMAT, format, sizeof(format)) > 0 &&
            !strcmp(format, "Markdown document");
        // Generated Markdown PDFs need only the glyphs used by the selected
        // pages. Subset at the writer owner before its one compact save.
        writer = fz_new_pdf_writer(d->ctx, path, subset_markdown
            ? "compress=yes,compress-fonts=yes,compress-images=yes,garbage=deduplicate,subset-fonts=yes"
            : "compress=yes,compress-fonts=yes,compress-images=yes,garbage=deduplicate");
        for (int i = 0; i < page_count; ++i) {
            int index = pages ? pages[i] : i;
            if ((cookie && cookie->abort) || (cancelled && cancelled())) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF output cancelled");
            page = fz_load_page(d->ctx, d->doc, index);
            fz_rect box = fz_bound_page(d->ctx, page);
            if (regions) {
                if (region_counts[i] <= 0)
                    fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid print selection");
                fz_rect selection = fz_empty_rect;
                clip = fz_new_path(d->ctx);
                // Print.cpp bounds the selection for sizing, but leaves gaps
                // between selected lines blank. Clip their union in one pass.
                for (int j = 0; j < region_counts[i]; ++j, regions += 4) {
                    const float *r = regions;
                    if (!isfinite(r[0]) || !isfinite(r[1]) || !isfinite(r[2]) || !isfinite(r[3]) || r[2] <= 0 || r[3] <= 0)
                        fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid print selection");
                    fz_rect area = fz_intersect_rect(box, fz_make_rect(r[0], r[1], r[0]+r[2], r[1]+r[3]));
                    if (fz_is_empty_rect(area)) continue;
                    selection = fz_union_rect(selection, area);
                    fz_rectto(d->ctx, clip, area.x0, area.y0, area.x1, area.y1);
                }
                box = selection;
            }
            if (!isfinite(box.x0) || !isfinite(box.y0) || !isfinite(box.x1) || !isfinite(box.y1) ||
                !(box.x1 > box.x0) || !(box.y1 > box.y0))
                fz_throw(d->ctx, FZ_ERROR_FORMAT, "Invalid page dimensions");
            // Translate pinned muconvert.c::runpage. The convenience
            // fz_write_document path leaves nonzero page origins unchanged.
            fz_matrix ctm = fz_rotate(rotation);
            fz_rect rotated = fz_transform_rect(box, ctm);
            ctm = fz_concat(ctm, fz_translate(-rotated.x0, -rotated.y0));
            fz_rect output_box = fz_transform_rect(box, ctm);
            if (content_bounds) {
                fz_rect content = output_box;
                if (!regions) {
                    // EngineMupdf::PageContentBox / Print.cpp: measure Print
                    // appearances, not the viewer's annotation/OCG state. A
                    // single page list feeds both bounds and vector output.
                    list = fz_new_display_list(d->ctx, output_box);
                    measure = fz_new_list_device(d->ctx, list);
                    pdf_run_page_with_usage(d->ctx, (pdf_page *)page, measure, ctm, "Print", cookie);
                    fz_close_device(d->ctx, measure); fz_drop_device(d->ctx, measure); measure = NULL;
                    measure = fz_new_bbox_device(d->ctx, &content);
                    fz_run_display_list(d->ctx, list, measure, fz_identity, output_box, cookie);
                    fz_close_device(d->ctx, measure); fz_drop_device(d->ctx, measure); measure = NULL;
                    content = fz_intersect_rect(content, output_box);
                    if (fz_is_empty_rect(content) || !isfinite(content.x0) || !isfinite(content.y0) ||
                        !isfinite(content.x1) || !isfinite(content.y1)) content = output_box;
                }
                // The print view consumes the emitted PDF's bottom-left space.
                float *r = content_bounds + i*4;
                r[0] = content.x0; r[1] = output_box.y1-content.y1;
                r[2] = content.x1-content.x0; r[3] = content.y1-content.y0;
            }
            device = fz_begin_page(d->ctx, writer, output_box);
            if (printing) {
                // A writer does not implicitly clip content to its page box.
                // Keep a selected area's vectors and text, clipped by MuPDF.
                if (!clip) {
                    clip = fz_new_path(d->ctx);
                    fz_rectto(d->ctx, clip, output_box.x0, output_box.y0, output_box.x1, output_box.y1);
                }
                fz_clip_path(d->ctx, device, clip, 0, regions ? ctm : fz_identity, output_box);
                // Sumatra normally prints a fresh engine whose viewer-only
                // hideAnnotations is false. Print flags and OCP decide here.
                if (list) fz_run_display_list(d->ctx, list, device, fz_identity, output_box, cookie);
                else pdf_run_page_with_usage(d->ctx, (pdf_page *)page, device, ctm, "Print", cookie);
                if (cookie && cookie->abort) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF printing cancelled");
                fz_pop_clip(d->ctx, device);
                fz_drop_path(d->ctx, clip); clip = NULL;
            } else fz_run_page(d->ctx, page, device, ctm, NULL);
            device = NULL; // end_page consumes it, including on an exception.
            fz_end_page(d->ctx, writer);
            fz_drop_display_list(d->ctx, list); list = NULL;
            fz_drop_page(d->ctx, page); page = NULL;
        }
        if ((cookie && cookie->abort) || (cancelled && cancelled())) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF output cancelled");
        fz_close_document_writer(d->ctx, writer);
    }
    fz_always(d->ctx) {
        if (cookie && cookie->abort && device) device->close_device = NULL;
        fz_drop_device(d->ctx, measure); fz_drop_display_list(d->ctx, list);
        fz_drop_path(d->ctx, clip); fz_drop_page(d->ctx, page); fz_drop_document_writer(d->ctx, writer);
    }
    fz_catch(d->ctx) {
        int code;
        snprintf(error, 512, "%s", fz_convert_error(d->ctx, &code));
        return code == FZ_ERROR_ABORT ? -1 : 0;
    }
    return 1;
}
// Keep encoded PDF text and its ToUnicode resources. Sending it through the
// Fitz PDF writer rebuilds character maps from glyphs and loses source Unicode.
// MuPDF's View processor chooses current appearances. A locked static Stamp
// keeps them outside the page-content transparency group, without form fields,
// actions or scripts. Putting APs in Contents changes opaque-backdrop blending.
typedef struct {
    pdf_processor super;
    fz_buffer *buffer;
    pdf_document *source;
    pdf_graft_map *map;
    pdf_obj *xobjects;
    int next_name;
} ExportPDFProcessor;
static void export_pdf_q(fz_context *ctx, pdf_processor *proc) {
    fz_append_string(ctx, ((ExportPDFProcessor *)proc)->buffer, "q\n");
}
static void export_pdf_Q(fz_context *ctx, pdf_processor *proc) {
    fz_append_string(ctx, ((ExportPDFProcessor *)proc)->buffer, "Q\n");
}
static void export_pdf_cm(fz_context *ctx, pdf_processor *proc, float a, float b, float c, float d, float e, float f) {
    fz_append_printf(ctx, ((ExportPDFProcessor *)proc)->buffer, "%g %g %g %g %g %g cm\n", a, b, c, d, e, f);
}
static void export_pdf_form(fz_context *ctx, pdf_processor *proc, const char *unused, pdf_obj *ap) {
    ExportPDFProcessor *p = (ExportPDFProcessor *)proc;
    pdf_graft_map *local = NULL; fz_var(local);
    char name[40];
    do { fz_snprintf(name, sizeof name, "SumraAnnot%d", p->next_name++); }
    while (pdf_dict_gets(ctx, p->xobjects, name));
    fz_try(ctx) {
        // Synthesis can use an annotation-local xref with reused object IDs.
        // Keep its map local too; normal source resources share the page map.
        if (pdf_is_local_object(ctx, p->source, ap))
            local = pdf_new_graft_map(ctx, pdf_get_bound_document(ctx, p->xobjects));
        pdf_dict_puts_drop(ctx, p->xobjects, name, pdf_graft_mapped_object(ctx, local ? local : p->map, ap));
        fz_append_printf(ctx, p->buffer, "/%s Do\n", name);
    }
    fz_always(ctx) { pdf_drop_graft_map(ctx, local); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
static void export_pdf_annot(fz_context *ctx, pdf_processor *proc, pdf_annot *annot) {
    // pdf_run_annot_with_usage's widget and local-appearance boundary. The
    // processor owns visibility, optional content, flags and AP transforms.
    pdf_annot_push_local_xref(ctx, annot);
    fz_try(ctx) {
        pdf_obj *obj = pdf_annot_obj(ctx, annot);
        if (pdf_annot_type(ctx, annot) != PDF_ANNOT_WIDGET ||
            (pdf_dict_get_inheritable(ctx, obj, PDF_NAME(FT)) && pdf_dict_get_inheritable(ctx, obj, PDF_NAME(T))))
            pdf_process_annot(ctx, proc, annot, NULL);
    }
    fz_always(ctx) { pdf_annot_pop_local_xref(ctx, annot); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
static pdf_obj *export_pdf_appearance(fz_context *ctx, pdf_document *output,
        fz_buffer *buffer, pdf_obj *resources, fz_rect box, int isolated) {
    pdf_obj *dictionary = NULL, *form = NULL;
    fz_var(dictionary); fz_var(form);
    fz_try(ctx) {
        dictionary = pdf_new_dict(ctx, output, 5);
        pdf_dict_put(ctx, dictionary, PDF_NAME(Type), PDF_NAME(XObject));
        pdf_dict_put(ctx, dictionary, PDF_NAME(Subtype), PDF_NAME(Form));
        pdf_dict_put_rect(ctx, dictionary, PDF_NAME(BBox), box);
        pdf_dict_put_matrix(ctx, dictionary, PDF_NAME(Matrix), fz_identity);
        pdf_dict_put(ctx, dictionary, PDF_NAME(Resources), resources);
        if (isolated) {
            pdf_obj *group = pdf_dict_put_dict(ctx, dictionary, PDF_NAME(Group), 2);
            pdf_dict_put(ctx, group, PDF_NAME(S), PDF_NAME(Transparency));
            pdf_dict_put_bool(ctx, group, PDF_NAME(I), 1);
        }
        form = pdf_add_stream(ctx, output, buffer, dictionary, 0);
    }
    fz_always(ctx) { pdf_drop_obj(ctx, dictionary); }
    fz_catch(ctx) { pdf_drop_obj(ctx, form); fz_rethrow(ctx); }
    return form;
}
static int export_pdf_pages(SumraMuPDFDocument *d, pdf_document *source, const char *path,
        const int *pages, int page_count, int (*cancelled)(void), char *error) {
    pdf_document *output = NULL; pdf_graft_map *map = NULL; pdf_page *page = NULL;
    pdf_obj *resources = NULL, *form = NULL, *group = NULL, *annotation = NULL, *semantic = NULL, *page_resources = NULL;
    fz_buffer *buffer = NULL, *suffix = NULL;
    ExportPDFProcessor *proc = NULL;
    fz_var(output); fz_var(map); fz_var(page); fz_var(resources); fz_var(form); fz_var(group); fz_var(annotation); fz_var(semantic); fz_var(page_resources); fz_var(buffer); fz_var(suffix); fz_var(proc);
    fz_try(d->ctx) {
        if (!pdf_has_permission(d->ctx, source, FZ_PERMISSION_COPY))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "This PDF does not allow content extraction");
        if (d->journal_nesting || pdf_has_unsaved_sigs(d->ctx, source))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Finish the current PDF edit before exporting");
        int count = pdf_count_pages(d->ctx, source);
        if (count <= 0 || (pages && page_count <= 0)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Choose pages to export");
        if (pages) {
            for (int i = 0; i < page_count; ++i)
                if (pages[i] < 0 || pages[i] >= count) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Page out of range");
        } else page_count = count;
        if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF output cancelled");
        output = pdf_create_document(d->ctx); map = pdf_new_graft_map(d->ctx, output);
        pdf_obj *root = pdf_dict_get(d->ctx, pdf_trailer(d->ctx, output), PDF_NAME(Root));
        pdf_obj *source_root = pdf_dict_get(d->ctx, pdf_trailer(d->ctx, source), PDF_NAME(Root));
        pdf_obj *keys[] = {PDF_NAME(OCProperties), PDF_NAME(OutputIntents)};
        for (int i = 0; i < 2; ++i) {
            pdf_obj *value = pdf_dict_get(d->ctx, source_root, keys[i]);
            if (value) pdf_dict_put_drop(d->ctx, root, keys[i], pdf_graft_mapped_object(d->ctx, map, value));
        }
        for (int i = 0; i < page_count; ++i) {
            if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF output cancelled");
            int index = pages ? pages[i] : i;
            page = pdf_load_page(d->ctx, source, index);
            pdf_update_page(d->ctx, page);
            fz_rect box = fz_bound_page(d->ctx, (fz_page *)page), pdf_box; fz_matrix transform;
            if (fz_is_empty_rect(box) || !isfinite(box.x0) || !isfinite(box.y0) || !isfinite(box.x1) || !isfinite(box.y1))
                fz_throw(d->ctx, FZ_ERROR_FORMAT, "Invalid page dimensions");
            pdf_page_transform(d->ctx, page, &pdf_box, &transform);
            pdf_graft_mapped_page(d->ctx, map, -1, source, index);
            pdf_obj *out_page = pdf_lookup_page_obj(d->ctx, output, i);
            pdf_obj *page_group = pdf_page_group(d->ctx, page);
            if (page->transparency) {
                // pdf_run_page_contents always isolates page contents without
                // knockout, including pages whose resources imply transparency.
                group = pdf_new_dict(d->ctx, output, 4);
                pdf_dict_put(d->ctx, group, PDF_NAME(S), PDF_NAME(Transparency));
                pdf_dict_put_bool(d->ctx, group, PDF_NAME(I), 1);
                pdf_dict_put_bool(d->ctx, group, PDF_NAME(K), 0);
                pdf_obj *colorspace = pdf_dict_get(d->ctx, page_group, PDF_NAME(CS));
                if (colorspace) pdf_dict_put_drop(d->ctx, group, PDF_NAME(CS), pdf_graft_mapped_object(d->ctx, map, colorspace));
                else if (!page_group && pdf_document_output_intent(d->ctx, source)) {
                    pdf_obj *profile = pdf_dict_get(d->ctx, pdf_array_get(d->ctx, pdf_dict_get(d->ctx, root, PDF_NAME(OutputIntents)), 0), PDF_NAME(DestOutputProfile));
                    if (profile) {
                        pdf_obj *cs = pdf_dict_put_array(d->ctx, group, PDF_NAME(CS), 2);
                        pdf_array_push(d->ctx, cs, PDF_NAME(ICCBased)); pdf_array_push(d->ctx, cs, profile);
                    }
                }
                pdf_dict_put(d->ctx, out_page, PDF_NAME(Group), group);
            }
            // Keep original Contents/Resources and boxes intact. The appearance
            // has its own resource dictionary and original PDF coordinates.
            resources = pdf_new_dict(d->ctx, output, 1);
            pdf_dict_put_dict(d->ctx, resources, PDF_NAME(XObject), 4);
            buffer = fz_new_buffer(d->ctx, 1024);
            fz_append_string(d->ctx, buffer, "q\n");
            proc = pdf_new_processor(d->ctx, sizeof(*proc));
            proc->super.usage = "View"; proc->super.op_q = export_pdf_q; proc->super.op_Q = export_pdf_Q;
            proc->super.op_cm = export_pdf_cm; proc->super.op_Do_form = export_pdf_form;
            proc->buffer = buffer; proc->source = source; proc->map = map;
            proc->xobjects = pdf_dict_get(d->ctx, resources, PDF_NAME(XObject));
            for (pdf_annot *annot = pdf_first_annot(d->ctx, page); annot; annot = pdf_next_annot(d->ctx, annot)) export_pdf_annot(d->ctx, &proc->super, annot);
            for (pdf_annot *widget = pdf_first_widget(d->ctx, page); widget; widget = pdf_next_widget(d->ctx, widget)) export_pdf_annot(d->ctx, &proc->super, widget);
            pdf_close_processor(d->ctx, &proc->super);
            pdf_drop_processor(d->ctx, &proc->super); proc = NULL;
            fz_append_string(d->ctx, buffer, "Q\n");
            if (pdf_dict_len(d->ctx, pdf_dict_get(d->ctx, resources, PDF_NAME(XObject)))) {
                form = export_pdf_appearance(d->ctx, output, buffer, resources, pdf_box, 0);
                annotation = pdf_new_dict(d->ctx, output, 5);
                pdf_dict_put(d->ctx, annotation, PDF_NAME(Type), PDF_NAME(Annot));
                pdf_dict_put(d->ctx, annotation, PDF_NAME(Subtype), PDF_NAME(Stamp));
                pdf_dict_put_rect(d->ctx, annotation, PDF_NAME(Rect), pdf_box);
                pdf_dict_put_int(d->ctx, annotation, PDF_NAME(F), PDF_ANNOT_IS_PRINT | PDF_ANNOT_IS_READ_ONLY | PDF_ANNOT_IS_LOCKED | PDF_ANNOT_IS_LOCKED_CONTENTS);
                pdf_dict_put(d->ctx, pdf_dict_put_dict(d->ctx, annotation, PDF_NAME(AP), 1), PDF_NAME(N), form);
                pdf_array_push_drop(d->ctx, pdf_dict_put_array(d->ctx, out_page, PDF_NAME(Annots), 1), pdf_add_object(d->ctx, output, annotation));
                pdf_drop_obj(d->ctx, annotation); annotation = NULL;
                // Annotations are excluded by contents-only text extractors.
                // Retain their original encoded text in a zero-alpha isolated
                // Form; inner appearance states cannot make that group visible.
                semantic = export_pdf_appearance(d->ctx, output, buffer, resources, pdf_box, 1);
                pdf_obj *original_resources = pdf_dict_get(d->ctx, out_page, PDF_NAME(Resources));
                page_resources = original_resources ? pdf_copy_dict(d->ctx, original_resources) : pdf_new_dict(d->ctx, output, 2);
                pdf_dict_put(d->ctx, out_page, PDF_NAME(Resources), page_resources);
                pdf_obj *xobjects = pdf_dict_get(d->ctx, page_resources, PDF_NAME(XObject));
                pdf_dict_put_drop(d->ctx, page_resources, PDF_NAME(XObject), xobjects ? pdf_copy_dict(d->ctx, xobjects) : pdf_new_dict(d->ctx, output, 1));
                xobjects = pdf_dict_get(d->ctx, page_resources, PDF_NAME(XObject));
                pdf_obj *states = pdf_dict_get(d->ctx, page_resources, PDF_NAME(ExtGState));
                pdf_dict_put_drop(d->ctx, page_resources, PDF_NAME(ExtGState), states ? pdf_copy_dict(d->ctx, states) : pdf_new_dict(d->ctx, output, 1));
                states = pdf_dict_get(d->ctx, page_resources, PDF_NAME(ExtGState));
                int n = 0; char form_name[40], state_name[40];
                do { fz_snprintf(form_name, sizeof form_name, "SumraText%d", n++); } while (pdf_dict_gets(d->ctx, xobjects, form_name));
                n = 0;
                do { fz_snprintf(state_name, sizeof state_name, "SumraTextAlpha%d", n++); } while (pdf_dict_gets(d->ctx, states, state_name));
                pdf_dict_puts(d->ctx, xobjects, form_name, semantic);
                pdf_obj *state = pdf_new_dict(d->ctx, output, 2);
                pdf_dict_puts_drop(d->ctx, states, state_name, state);
                pdf_dict_put_real(d->ctx, state, PDF_NAME(ca), 0); pdf_dict_put_real(d->ctx, state, PDF_NAME(CA), 0);
                suffix = fz_new_buffer(d->ctx, 128);
                fz_append_printf(d->ctx, suffix, "Q\nq /%s gs /%s Do Q\n", state_name, form_name);
                pdf_obj *original = NULL; fz_buffer *prefix = NULL;
                fz_var(original); fz_var(prefix);
                fz_try(d->ctx) {
                    original = pdf_keep_obj(d->ctx, pdf_dict_get(d->ctx, out_page, PDF_NAME(Contents)));
                    pdf_obj *contents = pdf_dict_put_array(d->ctx, out_page, PDF_NAME(Contents), 3);
                    prefix = fz_new_buffer_from_copied_data(d->ctx, (const unsigned char *)"q\n", 2);
                    pdf_array_push_drop(d->ctx, contents, pdf_add_stream(d->ctx, output, prefix, NULL, 0));
                    if (pdf_is_array(d->ctx, original)) {
                        for (int j = 0; j < pdf_array_len(d->ctx, original); ++j) pdf_array_push(d->ctx, contents, pdf_array_get(d->ctx, original, j));
                    } else if (original) pdf_array_push(d->ctx, contents, original);
                    pdf_array_push_drop(d->ctx, contents, pdf_add_stream(d->ctx, output, suffix, NULL, 0));
                }
                fz_always(d->ctx) { pdf_drop_obj(d->ctx, original); fz_drop_buffer(d->ctx, prefix); }
                fz_catch(d->ctx) { fz_rethrow(d->ctx); }
            }
            pdf_drop_obj(d->ctx, form); form = NULL; pdf_drop_obj(d->ctx, group); group = NULL;
            pdf_drop_obj(d->ctx, resources); resources = NULL; fz_drop_buffer(d->ctx, buffer); buffer = NULL;
            pdf_drop_obj(d->ctx, semantic); semantic = NULL; pdf_drop_obj(d->ctx, page_resources); page_resources = NULL;
            fz_drop_buffer(d->ctx, suffix); suffix = NULL;
            fz_drop_page(d->ctx, (fz_page *)page); page = NULL;
        }
        if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "PDF output cancelled");
        pdf_write_options options = pdf_default_write_options;
        options.do_compress = options.do_compress_fonts = options.do_compress_images = 1; options.do_garbage = 3;
        pdf_save_document(d->ctx, output, path, &options);
    }
    fz_always(d->ctx) {
        pdf_drop_processor(d->ctx, (pdf_processor *)proc); fz_drop_page(d->ctx, (fz_page *)page);
        pdf_drop_obj(d->ctx, resources); pdf_drop_obj(d->ctx, form); pdf_drop_obj(d->ctx, group); pdf_drop_obj(d->ctx, annotation);
        pdf_drop_obj(d->ctx, semantic); pdf_drop_obj(d->ctx, page_resources);
        fz_drop_buffer(d->ctx, buffer); fz_drop_buffer(d->ctx, suffix); pdf_drop_graft_map(d->ctx, map); pdf_drop_document(d->ctx, output);
    }
    fz_catch(d->ctx) {
        int code; snprintf(error, 512, "%s", fz_convert_error(d->ctx, &code));
        return code == FZ_ERROR_ABORT ? -1 : 0;
    }
    return 1;
}
API int lf_export_pdf(void *opaque, const char *path, const int *pages, int page_count, int (*cancelled)(void), char *error) {
    SumraMuPDFDocument *d = opaque;
    pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
    if (pdf) return export_pdf_pages(d, pdf, path, pages, page_count, cancelled, error);
    return write_pdf(d, path, pages, page_count, NULL, NULL, 0, 0, NULL, 0, NULL, cancelled, error);
}
API int lf_print_pdf(void *opaque, const char *path, const int *pages, int page_count,
        const float *regions, const int *region_counts, int rotation, float *content_bounds, int bounds_count, void *cookie, char *error) {
    return write_pdf(opaque, path, pages, page_count, regions, region_counts, rotation, 1, content_bounds, bounds_count, cookie, NULL, error);
}
// Image collections feed the existing PDF writer one original image at a time.
// pdf_add_image preserves supported JPEG/JPX compression; other images remain
// at their source pixel dimensions. Orientation follows MuPDF's cbz_run_page.
typedef struct { fz_context *ctx; fz_document_writer *writer; } ImagePDFWriter;
API void *lf_image_pdf_begin(const char *path, char *error) {
    ImagePDFWriter *w = calloc(1, sizeof(*w));
    if (!w) { snprintf(error, 512, "Cannot allocate PDF writer"); return NULL; }
    w->ctx = lf_new_context(32 << 20);
    if (!w->ctx) { free(w); snprintf(error, 512, "Cannot create PDF writer context"); return NULL; }
    fz_try(w->ctx) { w->writer = fz_new_pdf_writer(w->ctx, path, "compress=yes,compress-images=yes,garbage=deduplicate"); }
    fz_catch(w->ctx) { snprintf(error, 512, "%s", fz_convert_error(w->ctx, NULL)); fz_drop_context(w->ctx); free(w); return NULL; }
    return w;
}
API int lf_image_pdf_add(void *opaque, const unsigned char *data, size_t size, float width, float height, char *error) {
    ImagePDFWriter *w = opaque; fz_image *image = NULL; fz_buffer *buffer = NULL;
    fz_var(image); fz_var(buffer);
    fz_try(w->ctx) {
        buffer = fz_new_buffer_from_copied_data(w->ctx, data, size);
        image = fz_new_image_from_buffer(w->ctx, buffer);
        if (!isfinite(width) || !isfinite(height) || !(width > 0) || !(height > 0))
            fz_throw(w->ctx, FZ_ERROR_FORMAT, "Invalid image PDF page dimensions");
        fz_device *device = fz_begin_page(w->ctx, w->writer, fz_make_rect(0, 0, width, height));
        fz_matrix matrix = fz_post_scale(fz_image_orientation_matrix(w->ctx, image), width, height);
        fz_fill_image(w->ctx, device, image, matrix, 1, fz_default_color_params);
        fz_end_page(w->ctx, w->writer);
    }
    fz_always(w->ctx) { fz_drop_image(w->ctx, image); fz_drop_buffer(w->ctx, buffer); }
    fz_catch(w->ctx) { snprintf(error, 512, "%s", fz_convert_error(w->ctx, NULL)); return 0; }
    return 1;
}
API int lf_image_pdf_end(void *opaque, int finish, char *error) {
    ImagePDFWriter *w = opaque; int ok = 1; fz_var(ok);
    fz_try(w->ctx) { if (finish) fz_close_document_writer(w->ctx, w->writer); }
    fz_catch(w->ctx) { snprintf(error, 512, "%s", fz_convert_error(w->ctx, NULL)); ok = 0; }
    fz_drop_document_writer(w->ctx, w->writer); fz_drop_context(w->ctx); free(w);
    return ok;
}
// EngineMupdf::FitzAbortCookie: one cookie per request, never a document-wide
// stop flag that could cancel the next page. MuPDF defines this cross-thread API.
API void *lf_render_cookie_new(void) {
    fz_cookie *cookie = calloc(1, sizeof(*cookie));
    if (cookie) cookie->progress_max = (size_t)-1;
    return cookie;
}
API void lf_render_cookie_abort(void *opaque) { if (opaque) ((fz_cookie *)opaque)->abort = 1; }
API int lf_render_cookie_aborted(void *opaque) { return opaque && ((fz_cookie *)opaque)->abort; }
API void lf_render_cookie_drop(void *opaque) { free(opaque); }
// MuPDF util.c::fz_new_display_list_from_page[_contents], with the request
// cookie preserved. Raster and PDF color rendering share this construction.
enum { PAGE_ALL, PAGE_CONTENTS_ONLY, PAGE_CONTENTS_AND_WIDGETS };
fz_display_list *lf_new_display_list(fz_context *ctx, fz_page *page, int parts, fz_cookie *cookie) {
    fz_display_list *list = fz_new_display_list(ctx, fz_bound_page(ctx, page));
    fz_device *dev = NULL;
    fz_var(dev);
    fz_try(ctx) {
        if (cookie && cookie->abort) fz_throw(ctx, FZ_ERROR_ABORT, "Rendering cancelled");
        dev = fz_new_list_device(ctx, list);
        if (parts == PAGE_ALL) fz_run_page(ctx, page, dev, fz_identity, cookie);
        else {
            fz_run_page_contents(ctx, page, dev, fz_identity, cookie);
            // EngineMupdf::RenderPage keeps form fields visible when hiding annotations.
            if (parts == PAGE_CONTENTS_AND_WIDGETS && !(cookie && cookie->abort))
                fz_run_page_widgets(ctx, page, dev, fz_identity, cookie);
        }
        if (cookie && cookie->abort) fz_throw(ctx, FZ_ERROR_ABORT, "Rendering cancelled");
        fz_close_device(ctx, dev);
    }
    fz_always(ctx) {
        if (cookie && cookie->abort && dev) dev->close_device = NULL;
        fz_drop_device(ctx, dev);
    }
    fz_catch(ctx) { fz_drop_display_list(ctx, list); fz_rethrow(ctx); }
    return list;
}
static fz_display_list *page_display_list(SumraMuPDFDocument *d, int chapter, int index, fz_cookie *cookie) {
    fz_page *page = load_render_page(d, chapter, index, cookie);
    if (!d->display_list) d->display_list = lf_new_display_list(d->ctx, page,
        d->hide_annotations ? PAGE_CONTENTS_AND_WIDGETS : PAGE_ALL, cookie);
    return d->display_list;
}
API unsigned char *lf_render_cancelable_at(void *opaque, int chapter, int index, int width,
        const int *region, int alpha, const int *style, const uint32_t *colors, void *opaque_cookie, int *info, char *error) {
    SumraMuPDFDocument *d = opaque;
    fz_cookie *cookie = opaque_cookie;
    fz_pixmap *pix = NULL; fz_device *dev = NULL; unsigned char *out = NULL;
    fz_var(pix); fz_var(dev); fz_var(out);
    fz_try(d->ctx) {
        // EngineMupdf::GetOrBuildPageDisplayList: tiles replay the same page's
        // drawing commands. This serial decoder retains only its current page.
        load_render_page(d, chapter, index, cookie);
        fz_rect box = fz_bound_page(d->ctx, d->render_page);
        float page_width = box.x1-box.x0;
        if (width <= 0 || !(page_width > 0)) fz_throw(d->ctx, FZ_ERROR_GENERIC, "Invalid render width");
        float scale = (float)width/page_width;
        fz_matrix ctm = fz_concat(fz_translate(-box.x0, -box.y0), fz_scale(scale, scale));
        fz_rect rendered = fz_transform_rect(box, ctm);
        fz_rect page_area = box;
        if (!isfinite(rendered.x0) || !isfinite(rendered.y0) || !isfinite(rendered.x1) || !isfinite(rendered.y1))
            fz_throw(d->ctx, FZ_ERROR_GENERIC, "Invalid page dimensions");
        if (region) {
            if (region[0] < 0 || region[1] < 0 || region[2] <= 0 || region[3] <= 0 ||
                region[0] > INT_MAX-region[2] || region[1] > INT_MAX-region[3])
                fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid render region");
            rendered = fz_make_rect(region[0], region[1], region[0]+region[2], region[1]+region[3]);
            page_area = fz_transform_rect(rendered, fz_invert_matrix(ctm));
        }
        // Check transformed dimensions before MuPDF allocates its pixmap.
        double w = region ? region[2] : ceil(rendered.x1)-floor(rendered.x0);
        double h = region ? region[3] : ceil(rendered.y1)-floor(rendered.y0);
        if (!(w > 0 && h > 0) || w > INT_MAX/4 || h > INT_MAX)
            fz_throw(d->ctx, FZ_ERROR_GENERIC, "Page bitmap is too large");
        fz_irect bbox = region ? fz_make_irect(region[0], region[1], region[0]+region[2], region[1]+region[3]) : fz_round_rect(rendered);
        // EngineMupdf::RenderPage keeps the full-page matrix and an absolute
        // pixmap origin, preserving the same rasterization phase across tiles.
        // Only coordinates beyond MuPDF's 2^24 raster bound need rebasing.
        if (region && (bbox.x1 > (1 << 24) || bbox.y1 > (1 << 24))) {
            ctm = fz_concat(ctm, fz_translate(-region[0], -region[1]));
            bbox = fz_make_irect(0, 0, region[2], region[3]);
        }
        info[0] = bbox.x1-bbox.x0; info[1] = bbox.y1-bbox.y0; info[3] = alpha || style ? 4 : 3; info[2] = info[0]*info[3];
        out = malloc((size_t)info[2]*(size_t)info[1]);
        if (!out) fz_throw(d->ctx, FZ_ERROR_GENERIC, "Cannot allocate page bitmap");
        // The supplied buffer remains malloc-owned. Translate MuPDF's util.c
        // render path to avoid a second full-size pixmap copy.
        pix = fz_new_pixmap_with_bbox_and_data(d->ctx, fz_device_rgb(d->ctx), bbox, NULL, alpha || style, out);
        if (alpha) fz_clear_pixmap(d->ctx, pix);
        else fz_clear_pixmap_with_value(d->ctx, pix, 255);
        // Assignment occurs only after the full list is successfully closed.
        page_display_list(d, chapter, index, cookie);
        if (style) lf_run_pdf_colors(d->ctx, d->display_list, &d->color_analysis,
            box, page_area, ctm, scale, pix, style, colors, cookie);
        else {
            dev = fz_new_draw_device(d->ctx, ctm, pix);
            fz_run_display_list(d->ctx, d->display_list, dev, fz_identity, page_area, cookie);
            if (cookie && cookie->abort) fz_throw(d->ctx, FZ_ERROR_ABORT, "Rendering cancelled");
            fz_close_device(d->ctx, dev);
        }
    }
    fz_always(d->ctx) {
        // EngineMupdf::UnhookAbortedDevices: an interrupted clip stack cannot
        // be closed. Drop it and its discarded output without a false error.
        if (cookie && cookie->abort && dev) dev->close_device = NULL;
        fz_drop_device(d->ctx, dev); fz_drop_pixmap(d->ctx, pix);
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(out); return NULL; }
    return out;
}
API char *lf_text_at(SumraMuPDFDocument *d, int chapter, int index, char *error) {
    fz_stext_page *text = NULL; fz_buffer *buffer = NULL; char *out = NULL;
    fz_var(text); fz_var(buffer); fz_var(out);
    fz_try(d->ctx) {
        text = stext_at(d, chapter, index, NULL, NULL);
        buffer = fz_new_buffer_from_stext_page(d->ctx, text);
        out = strdup(fz_string_from_buffer(d->ctx, buffer));
        if (!out) fz_throw(d->ctx, FZ_ERROR_GENERIC, "Cannot allocate extracted text");
    }
    fz_always(d->ctx) { fz_drop_buffer(d->ctx, buffer); fz_drop_stext_page(d->ctx, text); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(out); return NULL; }
    return out;
}
// Reuse MuPDF's flattening map so UTF-16 selection and speech offsets refer to
// exactly the same text as lf_text_at, including its paragraph/ligature handling.
API char *lf_words_at(SumraMuPDFDocument *d, int chapter, int index, char *error) {
    fz_stext_page *text = NULL; fz_buffer *buffer = NULL; fz_stext_position *map = NULL; SumraJSON j = {0};
    fz_var(text); fz_var(buffer); fz_var(map); fz_var(j);
    fz_try(d->ctx) {
        text = stext_at(d, chapter, index, NULL, NULL);
        int source_enabled = lf_has_html_source(d);
        fz_try(d->ctx) { buffer = fz_new_buffer_from_flattened_stext_page(d->ctx, text, FZ_TEXT_FLATTEN_KEEP_PARAGRAPHS, &map); }
        fz_catch(d->ctx) { map = NULL; fz_rethrow(d->ctx); } // util.c frees its map when flattening fails.
        const char *p = fz_string_from_buffer(d->ctx, buffer); int i = 0;
        lf_json(&j, "[");
        while (*p) {
            int rune, n = fz_chartorune(&rune, p); char glyph[8] = {0};
            memcpy(glyph, p, n); p += n;
            // Fitz's negative-extent empty sentinel becomes a huge CGRect.
            // Inserted paragraph separators have no on-page geometry.
            fz_rect box = map[i].ch ? fz_rect_from_quad(map[i].ch->quad) : fz_make_rect(0, 0, 0, 0);
            if (i++) lf_json(&j, ",");
            lf_json(&j, "{\"text\":"); lf_json_string(&j, glyph); lf_json(&j, ",\"rect\":");
            lf_json_rect(&j, box.x0, box.y0, box.x1-box.x0, box.y1-box.y0);
            if (source_enabled && map[i-1].ch && map[i-1].ch->source_node) {
                fz_stext_char *ch = map[i-1].ch;
                lf_json(&j, ",\"source\":["); lf_json_u32(&j, ch->source_node); lf_json(&j, ",");
                lf_json_u32(&j, ch->source_offset); lf_json(&j, ","); lf_json_u32(&j, ch->source_part); lf_json(&j, "]");
            }
            lf_json(&j, "}");
        }
        lf_json(&j, "]");
    }
    fz_always(d->ctx) { fz_free(d->ctx, map); fz_drop_buffer(d->ctx, buffer); fz_drop_stext_page(d->ctx, text); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}
API int lf_image_dimensions_at(SumraMuPDFDocument *d, int chapter, int index, int *size, char *error) {
    fz_stext_page *text = NULL; int found = 0; fz_var(text); fz_var(found);
    fz_try(d->ctx) {
        fz_stext_options options = { .flags = FZ_STEXT_PRESERVE_IMAGES };
        text = stext_at(d, chapter, index, &options, NULL);
        for (fz_stext_block *block = text->first_block; block; block = block->next) {
            if (block->type != FZ_STEXT_BLOCK_IMAGE) continue;
            fz_image *image = block->u.i.image;
            int rotation = fz_image_orientation(d->ctx, image);
            int swapped = rotation == 2 || rotation == 4 || rotation == 6 || rotation == 8;
            size[0] = swapped ? image->h : image->w; size[1] = swapped ? image->w : image->h;
            found = 1; break;
        }
    }
    fz_always(d->ctx) { fz_drop_stext_page(d->ctx, text); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return -1; }
    return found;
}
API char *lf_image_bounds_at(SumraMuPDFDocument *d, int chapter, int index, char *error) {
    fz_stext_page *text = NULL; SumraJSON j = {0}; fz_var(text); fz_var(j);
    fz_try(d->ctx) {
        fz_stext_options options = { .flags = FZ_STEXT_PRESERVE_IMAGES };
        text = stext_at(d, chapter, index, &options, NULL);
        lf_json(&j, "["); int first = 1;
        for (fz_stext_block *block = text->first_block; block; block = block->next) {
            if (block->type != FZ_STEXT_BLOCK_IMAGE) continue;
            if (!first) lf_json(&j, ","); first = 0;
            fz_rect box = block->bbox;
            lf_json_rect(&j, box.x0, box.y0, box.x1-box.x0, box.y1-box.y0);
        }
        lf_json(&j, "]");
    }
    fz_always(d->ctx) { fz_drop_stext_page(d->ctx, text); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}
// EngineMupdf::FzOrientPixmap: copy samples for orthogonal page transforms;
// arbitrary skew/angles retain the stored bitmap, as in the upstream extractor.
static fz_pixmap *orient_image(fz_context *ctx, fz_pixmap *src, fz_matrix ctm) {
    int rotated = ctm.a == 0 && ctm.d == 0 && ctm.b != 0 && ctm.c != 0;
    int aligned = ctm.b == 0 && ctm.c == 0 && ctm.a != 0 && ctm.d != 0;
    if ((!rotated && !aligned) || (aligned && ctm.a > 0 && ctm.d > 0)) return NULL;
    int w = src->w, h = src->h, n = src->n;
    fz_pixmap *dst = fz_new_pixmap(ctx, src->colorspace, rotated ? h : w, rotated ? w : h, src->seps, src->alpha);
    dst->xres = rotated ? src->yres : src->xres; dst->yres = rotated ? src->xres : src->yres;
    for (int sy = 0; sy < h; ++sy) {
        const unsigned char *row = src->samples + (size_t)sy * src->stride;
        for (int sx = 0; sx < w; ++sx) {
            int dx = rotated ? (ctm.c > 0 ? sy : h-1-sy) : (ctm.a > 0 ? sx : w-1-sx);
            int dy = rotated ? (ctm.b > 0 ? sx : w-1-sx) : (ctm.d > 0 ? sy : h-1-sy);
            memcpy(dst->samples + (size_t)dy * dst->stride + (size_t)dx*n, row + (size_t)sx*n, n);
        }
    }
    return dst;
}
API unsigned char *lf_image_at(SumraMuPDFDocument *d, int chapter, int index, float x, float y, size_t *size, char *error) {
    fz_stext_page *text = NULL; fz_buffer *buffer = NULL; unsigned char *out = NULL;
    fz_pixmap *pixmap = NULL, *mask = NULL, *oriented = NULL;
    fz_var(text); fz_var(buffer); fz_var(out); fz_var(pixmap); fz_var(mask); fz_var(oriented); *size = 0;
    fz_try(d->ctx) {
        fz_stext_options options = { .flags = FZ_STEXT_PRESERVE_IMAGES };
        text = stext_at(d, chapter, index, &options, NULL);
        fz_image *image = NULL; fz_matrix ctm = fz_identity;
        for (fz_stext_block *block = text->first_block; block; block = block->next)
            if (block->type == FZ_STEXT_BLOCK_IMAGE && fz_is_point_inside_rect(fz_make_point(x, y), block->bbox)) {
                image = block->u.i.image; ctm = block->u.i.transform;
            }
        if (image) {
            // GetImageDataForPageElement: a complete upright image keeps its
            // original compression and metadata, without another encoder.
            fz_compressed_buffer *compressed = fz_compressed_image_buffer(d->ctx, image);
            int upright = ctm.a > 0 && ctm.d > 0 && ctm.b == 0 && ctm.c == 0;
            int type = compressed ? compressed->params.type : FZ_IMAGE_UNKNOWN;
            int standalone = type == FZ_IMAGE_JPEG || type == FZ_IMAGE_PNG || type == FZ_IMAGE_GIF ||
                type == FZ_IMAGE_BMP || type == FZ_IMAGE_TIFF;
            if (upright && !image->mask && !image->use_colorkey && compressed && compressed->buffer) {
                if (type == FZ_IMAGE_JPEG && image->n == 4) {
                    // PDF CMYK polarity differs from standalone Adobe JPEG.
                    pixmap = fz_get_unscaled_pixmap_from_image(d->ctx, image);
                    if (pixmap->colorspace && fz_colorspace_is_cmyk(d->ctx, pixmap->colorspace) && !pixmap->alpha && pixmap->s == 0) {
                        if (pixmap->colorspace != fz_device_cmyk(d->ctx)) {
                            fz_pixmap *converted = fz_convert_pixmap(d->ctx, pixmap, fz_device_cmyk(d->ctx), NULL, NULL, fz_default_color_params, 1);
                            fz_drop_pixmap(d->ctx, pixmap); pixmap = converted;
                        }
                        buffer = fz_new_buffer_from_pixmap_as_jpeg(d->ctx, pixmap, fz_default_color_params, 95, 1);
                    }
                } else if (standalone && !image->use_decode) buffer = fz_keep_buffer(d->ctx, compressed->buffer);
            }
            if (!buffer) {
                if (!pixmap) pixmap = fz_get_unscaled_pixmap_from_image(d->ctx, image);
                // Converting also gives the mask compositor its own samples;
                // never modify MuPDF's cached original image pixmap.
                fz_pixmap *converted = fz_convert_pixmap(d->ctx, pixmap, fz_device_rgb(d->ctx), NULL, NULL, fz_default_color_params, 1);
                fz_drop_pixmap(d->ctx, pixmap); pixmap = converted;
                if (image->mask) {
                    mask = fz_get_unscaled_pixmap_from_image(d->ctx, image->mask);
                    if (mask->n != 1 || mask->w <= 0 || mask->h <= 0) fz_throw(d->ctx, FZ_ERROR_FORMAT, "Invalid embedded image mask");
                    // EngineMupdf::GetPageImage composites soft masks over white,
                    // including a mask whose resolution differs from the image.
                    for (int sy = 0; sy < pixmap->h; ++sy) for (int sx = 0; sx < pixmap->w; ++sx) {
                        int my = (int)((int64_t)sy * mask->h / pixmap->h), mx = (int)((int64_t)sx * mask->w / pixmap->w);
                        int alpha = mask->samples[(size_t)my * mask->stride + mx];
                        unsigned char *pixel = pixmap->samples + (size_t)sy * pixmap->stride + (size_t)sx * pixmap->n;
                        int coverage = pixmap->alpha ? alpha*pixel[pixmap->n-1]/255 : alpha;
                        for (int k = 0; k < 3; ++k) pixel[k] = (unsigned char)(pixel[k]*alpha/255 + 255-coverage);
                        if (pixmap->alpha) pixel[pixmap->n-1] = 255;
                    }
                }
                oriented = orient_image(d->ctx, pixmap, ctm);
                buffer = fz_new_buffer_from_pixmap_as_png(d->ctx, oriented ? oriented : pixmap, fz_default_color_params);
            }
            unsigned char *data;
            *size = fz_buffer_storage(d->ctx, buffer, &data);
            if (!*size) fz_throw(d->ctx, FZ_ERROR_FORMAT, "Empty embedded image");
            out = malloc(*size);
            if (!out) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "Cannot allocate embedded image");
            memcpy(out, data, *size);
        }
    }
    fz_always(d->ctx) { fz_drop_pixmap(d->ctx, oriented); fz_drop_pixmap(d->ctx, mask); fz_drop_pixmap(d->ctx, pixmap); fz_drop_buffer(d->ctx, buffer); fz_drop_stext_page(d->ctx, text); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(out); return NULL; }
    return out;
}

// Outline traversal and lazy URI destinations follow SumatraPDF's
// EngineMupdf::ResolveLinkChapterOnly: a path lookup does not lay out its
// chapter; resolving a #fragment does. Keep outline population lazy.
static int outline_chapter(SumraMuPDFDocument *d, const char *uri) {
    if (!uri || !*uri) return -1;
    char *path = NULL; int chapter = -1; fz_var(path); fz_var(chapter);
    fz_try(d->ctx) {
        path = fz_strdup(d->ctx, uri);
        char *fragment = strchr(path, '#');
        if (fragment) *fragment = 0;
        chapter = fz_resolve_link_dest(d->ctx, d->doc, path).loc.chapter;
    }
    fz_always(d->ctx) { fz_free(d->ctx, path); }
    fz_catch(d->ctx) { fz_ignore_error(d->ctx); }
    return chapter;
}
// EngineMupdf::BuildTocTree (012d997f): preserve group titles and hierarchy,
// resolve chaptered destinations only when activated.
API char *lf_outline(SumraMuPDFDocument *d, char *error) {
    fz_outline *outline = NULL; SumraJSON j = {0}; int first = 1;
    struct { fz_list(fz_outline *, next); } stack = {0};
    fz_var(outline); fz_var(stack); fz_var(j);
    fz_try(d->ctx) {
        // Follow MuPDF's outline.c list traversal, retaining the original
        // nodes: its editing iterator omits already resolved page coordinates.
        outline = fz_load_outline(d->ctx, d->doc);
        int chaptered = fz_count_chapters(d->ctx, d->doc) > 1;
        int depth = 0; lf_json(&j, "[");
        for (fz_outline *item = outline; item && !j.failed;) {
            if (!first) lf_json(&j, ","); first = 0;
            lf_json(&j, "{\"title\":"); lf_json_string(&j, item->title);
            lf_json(&j, ",\"target\":"); lf_json_string(&j, item->uri);
            lf_json(&j, ",\"depth\":"); lf_json_number(&j, depth);
            if (chaptered) {
                int chapter = outline_chapter(d, item->uri);
                if (chapter >= 0) { lf_json(&j, ",\"chapter\":"); lf_json_number(&j, chapter); }
            } else if (item->uri && *item->uri && !fz_is_external_link(d->ctx, item->uri) &&
                       item->page.chapter == 0 && item->page.page >= 0) {
                lf_json(&j, ",\"page\":"); lf_json_number(&j, item->page.page);
                lf_json(&j, ",\"x\":"); lf_json_number(&j, item->x);
                lf_json(&j, ",\"y\":"); lf_json_number(&j, item->y);
            }
            lf_json(&j, "}");
            if (item->down) {
                fz_outline **next = fz_push_list(d->ctx, stack.next);
                *next = item->next; item = item->down; ++depth; continue;
            }
            item = item->next;
            while (!item && stack.next_len) {
                item = stack.next[--stack.next_len];
                --depth;
            }
        }
        lf_json(&j, "]");
    }
    fz_always(d->ctx) { fz_drop_outline(d->ctx, outline); fz_free(d->ctx, stack.next); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}
API char *lf_links_at(SumraMuPDFDocument *d, int chapter, int index, char *error) {
    fz_page *p = NULL; fz_link *links = NULL; SumraJSON j = {0};
    fz_var(p); fz_var(links); fz_var(j);
    fz_try(d->ctx) {
        p = fz_load_chapter_page(d->ctx, d->doc, chapter, index); links = fz_load_links(d->ctx, p); lf_json(&j, "[");
        for (fz_link *l = links; l; l = l->next) {
            if (l != links) lf_json(&j, ","); lf_json(&j, "{\"uri\":"); lf_json_string(&j, l->uri);
            lf_json(&j, ",\"rect\":"); lf_json_rect(&j, l->rect.x0, l->rect.y0, l->rect.x1-l->rect.x0, l->rect.y1-l->rect.y0); lf_json(&j, "}");
        }
        lf_json(&j, "]");
    }
    fz_always(d->ctx) { fz_drop_link(d->ctx, links); fz_drop_page(d->ctx, p); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}
static int search_word_char(int c) {
    if (c == '_') return 1;
    int category = ucdn_get_general_category(c);
    return category >= UCDN_GENERAL_CATEGORY_LL && category <= UCDN_GENERAL_CATEGORY_NO;
}
static int search_word_match(fz_search_match *match) {
    fz_stext_char *before = NULL;
    for (fz_stext_char *ch = match->begin.line->first_char; ch && ch != match->begin.ch; ch = ch->next) before = ch;
    if (before && search_word_char(before->c) && search_word_char(match->begin.ch->c)) return 0;
    fz_stext_char *after = match->end.ch->next;
    return !after || !search_word_char(match->end.ch->c) || !search_word_char(after->c);
}
static size_t search_hit(fz_context *ctx, fz_search_match *match, const char *text, int backwards,
                         const char **cursor, fz_stext_position **position, size_t *offset) {
    const char *p = *cursor;
    fz_stext_position *map = *position;
    size_t start = *offset, end;
    while (!*p || map->ch != match->begin.ch) {
        int rune;
        if (backwards) {
            if (p == text) fz_throw(ctx, FZ_ERROR_FORMAT, "Cannot locate search match start");
            // stext-search.c::retreat_one_utf8, paired with the same map entry.
            do { --p; } while (p > text && (*p & 0xc0) == 0x80);
            fz_chartorune(&rune, p); start -= rune > 0xffff ? 2 : 1; --map;
        } else {
            if (!*p) fz_throw(ctx, FZ_ERROR_FORMAT, "Cannot locate search match start");
            p += fz_chartorune(&rune, p); start += rune > 0xffff ? 2 : 1; ++map;
        }
    }
    // Keep the cursor at each hit, including skipped ones, so locating the
    // next native match never rescans the page from its beginning.
    *cursor = p; *position = map; *offset = start;
    end = start;
    for (;;) {
        if (!*p) fz_throw(ctx, FZ_ERROR_FORMAT, "Cannot locate search match end");
        int rune; p += fz_chartorune(&rune, p);
        end += rune > 0xffff ? 2 : 1;
        if (map->ch == match->end.ch) break; // MuPDF's end character is inclusive.
        ++map;
    }
    return end;
}
API char *lf_search_options_at(void *document, int chapter, int index, const char *needle, int flags, int64_t after, int64_t maximum, int (*cancelled)(void), char *error) {
    SumraMuPDFDocument *d = document;
    fz_search *search = NULL, *anchor_search = NULL; char *anchor = NULL;
    fz_buffer *buffer = NULL; fz_stext_position *map = NULL;
    SumraJSON j = {0}; fz_var(search); fz_var(anchor_search); fz_var(anchor); fz_var(buffer); fz_var(map); fz_var(j);
    if (maximum == 0) {
        lf_json(&j, "{\"text\":\"\",\"matches\":[]}");
        return lf_json_finish(&j, error);
    }
    fz_try(d->ctx) {
        // TextSearch::FoldCaseForSearch folds both case and diacritics.
        fz_search_options options = flags & 1 ? FZ_SEARCH_EXACT : FZ_SEARCH_IGNORE_CASE | FZ_SEARCH_IGNORE_DIACRITICS;
        search = fz_new_search(d->ctx, needle, options);
        // MuPDF owns normalization and match quads. Its iterative API exposes
        // real characters for Sumatra's word-boundary check and cancellation.
        fz_feed_search(d->ctx, search, stext_at(d, chapter, index, NULL, NULL), 0);
        const char *text = NULL, *cursor = NULL; fz_stext_position *position = NULL; size_t offset = 0;
        int backwards = (flags & 4) != 0, locating = !backwards && after >= 0;
        int64_t emitted = 0, boundary = after, last_start = -1;
        fz_search_match *anchor_match = NULL;
        size_t anchor_length = 0;
        if (backwards && *needle) {
            // TextSearch::SetText: first non-CJK word, otherwise one symbol.
            // Hyphen/quote searches have no anchor and advance by character.
            int rune; const char *p = needle + fz_chartorune(&rune, needle);
            if (rune < 0x2e80 && search_word_char(rune)) {
                while (*p) {
                    int next, size = fz_chartorune(&next, p);
                    if (next >= 0x2e80 || !search_word_char(next)) break;
                    p += size;
                }
            } else if (rune == '-' || rune == '\'' || rune == '"' || rune == ' ' || (rune >= 9 && rune <= 13)) p = needle;
            anchor_length = (size_t)(p - needle);
        }
        while (maximum < 0 || emitted < maximum) {
            if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "Search cancelled");
            fz_search_result result = backwards || locating ? fz_search_backwards(d->ctx, search) : fz_search_forwards(d->ctx, search);
            int restart = 0;
            if (result.reason == FZ_SEARCH_COMPLETE) {
                if (!locating) break;
                restart = 1;
            }
            if (result.reason == FZ_SEARCH_MORE_INPUT) fz_feed_search(d->ctx, search, NULL, result.u.seq_needed);
            else if (result.reason == FZ_SEARCH_MATCH && result.u.match->num_quads && (!(flags & 2) || search_word_match(result.u.match))) {
                if (!buffer) {
                    // BuildSnippet uses real character positions, not intersecting
                    // glyph boxes. Flatten only once, and only for a matching page.
                    fz_try(d->ctx) { buffer = fz_new_buffer_from_flattened_stext_page(d->ctx, result.u.match->begin.page, FZ_TEXT_FLATTEN_KEEP_PARAGRAPHS, &map); }
                    fz_catch(d->ctx) { map = NULL; fz_rethrow(d->ctx); } // util.c already freed a failed map.
                    text = cursor = fz_string_from_buffer(d->ctx, buffer); position = map;
                    if (backwards || locating) {
                        while (*cursor) {
                            int rune; cursor += fz_chartorune(&rune, cursor);
                            offset += rune > 0xffff ? 2 : 1; ++position;
                        }
                    }
                }
                size_t end = search_hit(d->ctx, result.u.match, text, backwards || locating, &cursor, &position, &offset);
                size_t start = offset;
                if (locating) {
                    if (start > (uint64_t)after) continue;
                    locating = 0;
                    if (start == (uint64_t)after) {
                        // Resume the previous hit through MuPDF's direction
                        // switch, which advances past its real normalized end.
                        last_start = after;
                        continue;
                    }
                    restart = 1;
                } else {
                    if (boundary >= 0 && (backwards ? start >= (uint64_t)boundary : start <= (uint64_t)boundary)) continue;
                    // Normalization can expand one source glyph into several
                    // hits. Its UTF-16 start identifies one selectable result.
                    if (last_start >= 0 && start == (uint64_t)last_start) continue;
                    if (backwards && boundary >= 0 && anchor_length && end > (uint64_t)boundary) {
                        if (!needle[anchor_length]) continue; // The whole query is the anchor.
                        // StrRStr bounds only the anchor, not MatchEnd's full
                        // phrase. Ask MuPDF for its real normalized prefix end;
                        // query byte/scalar counts cannot account for e.g. ß/ss.
                        if (!anchor_search) {
                            anchor = fz_malloc(d->ctx, anchor_length + 1);
                            memcpy(anchor, needle, anchor_length); anchor[anchor_length] = 0;
                            anchor_search = fz_new_search(d->ctx, anchor, options);
                            fz_feed_search(d->ctx, anchor_search, stext_at(d, chapter, index, NULL, NULL), 0);
                        }
                        while (!anchor_match || anchor_match->begin.ch != result.u.match->begin.ch) {
                            if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "Search cancelled");
                            fz_search_result prefix = fz_search_backwards(d->ctx, anchor_search);
                            if (prefix.reason == FZ_SEARCH_COMPLETE) { anchor_match = NULL; break; }
                            if (prefix.reason == FZ_SEARCH_MORE_INPUT) fz_feed_search(d->ctx, anchor_search, NULL, prefix.u.seq_needed);
                            else anchor_match = prefix.u.match;
                        }
                        if (!anchor_match) continue;
                        const char *p = cursor; fz_stext_position *at = position; size_t anchor_start = start;
                        size_t anchor_end = search_hit(d->ctx, anchor_match, text, 0, &p, &at, &anchor_start);
                        if (anchor_end > (uint64_t)boundary) continue;
                    }
                    if (!j.len) {
                        lf_json(&j, "{\"text\":"); lf_json_string(&j, text); lf_json(&j, ",\"matches\":[");
                    } else lf_json(&j, ",");
                    lf_json(&j, "{\"start\":"); lf_json_number(&j, start);
                    lf_json(&j, ",\"length\":"); lf_json_number(&j, end - start);
                    lf_json(&j, ",\"rects\":[");
                    for (int i = 0; i < result.u.match->num_quads; ++i) {
                        if (i) lf_json(&j, ","); fz_rect r = fz_rect_from_quad(result.u.match->quads[i].quad);
                        lf_json_rect(&j, r.x0, r.y0, r.x1-r.x0, r.y1-r.y0);
                    }
                    lf_json(&j, "]}");
                    last_start = (int64_t)start;
                    if (backwards) boundary = (int64_t)start;
                    ++emitted;
                }
            }
            if (restart) {
                // An arbitrary cursor may not identify an old hit. Fall back
                // once to the normal forward start-offset filter.
                locating = 0;
                fz_drop_search(d->ctx, search); search = NULL;
                search = fz_new_search(d->ctx, needle, options);
                fz_feed_search(d->ctx, search, stext_at(d, chapter, index, NULL, NULL), 0);
                cursor = text; position = map; offset = 0;
            }
            if (j.failed) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "Cannot allocate search results");
        }
        lf_json(&j, j.len ? "]}" : "{\"text\":\"\",\"matches\":[]}");
    }
    fz_always(d->ctx) {
        fz_free(d->ctx, map); fz_drop_buffer(d->ctx, buffer);
        fz_drop_search(d->ctx, anchor_search); fz_free(d->ctx, anchor); fz_drop_search(d->ctx, search);
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}
typedef struct { uint32_t node, offset, part; } SumraSource;
typedef struct { SumraJSON *json; SumraSource first, last; int source_enabled; } SumraSelectionWriter;
static SumraSource source_of(fz_stext_char *ch) { return (SumraSource){ch->source_node, ch->source_offset, ch->source_part}; }
static int source_less(SumraSource a, SumraSource b) {
    if (a.node != b.node) return a.node < b.node;
    if (a.offset != b.offset) return a.offset < b.offset;
    return a.part < b.part;
}
static void lf_json_source(SumraJSON *j, SumraSource source) {
    lf_json(j, "["); lf_json_u32(j, source.node); lf_json(j, ",");
    lf_json_u32(j, source.offset); lf_json(j, ","); lf_json_u32(j, source.part); lf_json(j, "]");
}

typedef struct {
    SumraSource first, last;
    int begin_page;
    int *pages;
    size_t page_count, page_capacity;
    char *context;
} MarkdownSearchHit;
enum { MARKDOWN_PAINTED = 1u << 13, MARKDOWN_WORD_BEFORE = 1u << 14, MARKDOWN_WORD_AFTER = 1u << 15 };
typedef struct {
    SumraMuPDFDocument *document;
    fz_search *search;
    fz_search_chunker *chunker;
    fz_stext_page *building;
    fz_stext_line *line;
    fz_stext_char *last_char;
    int last_source_rune, last_char_after_assigned;
    size_t normalized_bytes, chunk_goal, maximum;
    int sequence, requested, finished, backwards, counting, whole_word, start_page, wrap_only, inclusive;
    SumraSource after, last_start;
    const uint8_t *allowed_bits;
    size_t allowed_bytes;
    int (*cancelled)(void);
    MarkdownSearchHit *primary, *wrap;
    size_t primary_count, wrap_count;
} MarkdownSearchState;

static void markdown_drop_hit(fz_context *ctx, MarkdownSearchHit *hit) {
    fz_free(ctx, hit->pages); fz_free(ctx, hit->context);
    memset(hit, 0, sizeof(*hit));
}
static void markdown_hit_page(fz_context *ctx, MarkdownSearchHit *hit, int page) {
    if (page < 0) return;
    for (size_t i = 0; i < hit->page_count; ++i) if (hit->pages[i] == page) return;
    if (hit->page_count == hit->page_capacity) {
        size_t next = hit->page_capacity ? hit->page_capacity * 2 : 4;
        hit->pages = fz_realloc_array(ctx, hit->pages, next, int); hit->page_capacity = next;
    }
    hit->pages[hit->page_count++] = page;
}
static int markdown_allowed(MarkdownSearchState *state, const MarkdownSearchHit *hit) {
    if (!state->allowed_bits) return 1;
    if (!hit->page_count) return 0;
    size_t first = (size_t)hit->pages[0], last = first;
    for (size_t i = 1; i < hit->page_count; ++i) {
        size_t page = (size_t)hit->pages[i];
        if (page < first) first = page;
        if (page > last) last = page;
    }
    /* A restricted range may not join text across an excluded physical page,
       including a page containing only normalized-away source characters. */
    for (size_t page = first; page <= last; ++page) {
        if (page / 8 >= state->allowed_bytes || !(state->allowed_bits[page / 8] & (1u << (page & 7)))) return 0;
    }
    return 1;
}
static void markdown_keep_hit(MarkdownSearchState *state, MarkdownSearchHit *hit, int primary) {
    fz_context *ctx = state->document->ctx;
    MarkdownSearchHit *slots = primary ? state->primary : state->wrap;
    size_t *count = primary ? &state->primary_count : &state->wrap_count;
    if (*count == state->maximum) {
        if (!state->backwards) { markdown_drop_hit(ctx, hit); return; }
        markdown_drop_hit(ctx, &slots[0]);
        memmove(slots, slots + 1, (state->maximum - 1) * sizeof(*slots));
        --*count;
    }
    slots[(*count)++] = *hit;
    memset(hit, 0, sizeof(*hit));
}
static void markdown_collect_match(MarkdownSearchState *state, const fz_search_match *match) {
    fz_context *ctx = state->document->ctx;
    MarkdownSearchHit hit = {0};
    fz_buffer *snippet = NULL;
    fz_var(hit); fz_var(snippet);
    fz_try(ctx) { do {
        if (!match->begin.ch || !match->end.ch) break;
        /* Every nonfinal chunk contains at least the normalized needle's byte
           length. A match cannot consume a whole middle chunk plus characters
           on both sides, so the two endpoints span at most two chunks. */
        if (match->end_seq < match->begin_seq || match->end_seq - match->begin_seq > 1)
            fz_throw(ctx, FZ_ERROR_FORMAT, "Markdown search span exceeds two chunks");
        snippet = fz_new_buffer(ctx, 128);
        fz_stext_page *page = match->begin.page;
        fz_stext_char *ch = match->begin.ch;
        size_t visited = 0;
        for (;;) {
            if (((++visited) & 1023) == 0 && state->cancelled && state->cancelled())
                fz_throw(ctx, FZ_ERROR_ABORT, "Search cancelled");
            if (ch->source_node) markdown_hit_page(ctx, &hit, (int)ch->argb);
            if ((ch->flags & MARKDOWN_PAINTED) && ch->source_node) {
                if (!hit.first.node) { hit.first = source_of(ch); hit.begin_page = (int)ch->argb; }
                hit.last = source_of(ch);
            }
            if (snippet->len < 240) fz_append_rune(ctx, snippet, ch->c);
            if (ch == match->end.ch && page == match->end.page) break;
            ch = ch->next;
            if (!ch) {
                if (page == match->end.page) fz_throw(ctx, FZ_ERROR_FORMAT, "Invalid Markdown search span");
                page = match->end.page;
                ch = page->first_block->u.t.first_line->first_char;
                if (!ch) fz_throw(ctx, FZ_ERROR_FORMAT, "Empty Markdown search continuation");
            }
        }
        if (!hit.first.node || source_less(hit.last, hit.first) ||
            (state->last_start.node && !source_less(state->last_start, hit.first))) break;
        state->last_start = hit.first;
        if (!hit.page_count || !markdown_allowed(state, &hit)) break;
        fz_terminate_buffer(ctx, snippet);
        hit.context = fz_strdup(ctx, fz_string_from_buffer(ctx, snippet));
        int primary = state->counting || (state->after.node
            ? (state->backwards ? source_less(hit.first, state->after) : source_less(state->after, hit.first))
            : (state->backwards ? hit.begin_page <= state->start_page : hit.begin_page >= state->start_page));
        if (state->after.node && state->inclusive && !source_less(hit.first, state->after) &&
            !source_less(state->after, hit.first)) primary = 1;
        markdown_keep_hit(state, &hit, primary);
        if (!state->backwards && (state->primary_count >= state->maximum ||
            (state->wrap_only && state->wrap_count >= state->maximum))) state->finished = 1;
    } while (0); }
    fz_always(ctx) { fz_drop_buffer(ctx, snippet); markdown_drop_hit(ctx, &hit); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}
static void markdown_drain_search(MarkdownSearchState *state) {
    fz_context *ctx = state->document->ctx;
    while (!state->finished) {
        if (state->cancelled && state->cancelled()) fz_throw(ctx, FZ_ERROR_ABORT, "Search cancelled");
        fz_search_result result = fz_search_forwards(ctx, state->search);
        if (result.reason == FZ_SEARCH_MORE_INPUT) { state->requested = result.u.seq_needed; return; }
        if (result.reason == FZ_SEARCH_COMPLETE) { state->finished = 1; return; }
        if (result.reason == FZ_SEARCH_MATCH && result.u.match->num_quads) {
            fz_search_match *match = result.u.match;
            int word = !state->whole_word || (
                !((match->begin.ch->flags & MARKDOWN_WORD_BEFORE) && search_word_char(match->begin.ch->c)) &&
                !((match->end.ch->flags & MARKDOWN_WORD_AFTER) && search_word_char(match->end.ch->c)));
            if (word) markdown_collect_match(state, match);
        }
    }
}
static void markdown_begin_chunk(MarkdownSearchState *state) {
    fz_context *ctx = state->document->ctx;
    fz_stext_page *page = fz_new_stext_page(ctx, fz_empty_rect);
    state->building = page;
    fz_stext_block *block = fz_pool_alloc(ctx, page->pool, sizeof(*block));
    fz_stext_line *line = fz_pool_alloc(ctx, page->pool, sizeof(*line));
    memset(block, 0, sizeof(*block)); memset(line, 0, sizeof(*line));
    block->type = FZ_STEXT_BLOCK_TEXT;
    block->u.t.first_line = block->u.t.last_line = line;
    page->first_block = page->last_block = block;
    line->dir.x = 1;
    state->line = line; state->last_char = NULL;
}
static void markdown_append_char(MarkdownSearchState *state, const fz_html_search_char *source) {
    fz_context *ctx = state->document->ctx;
    if (!state->building) markdown_begin_chunk(state);
    fz_stext_char *ch = fz_pool_alloc(ctx, state->building->pool, sizeof(*ch));
    memset(ch, 0, sizeof(*ch));
    ch->c = source->unicode; ch->source_node = source->source_node;
    ch->source_offset = source->source_offset; ch->source_part = source->source_part;
    ch->argb = (uint32_t)source->page; ch->size = 1;
    if (source->paintable) ch->flags |= MARKDOWN_PAINTED;
    if (search_word_char(state->last_source_rune)) ch->flags |= MARKDOWN_WORD_BEFORE;
    float x = state->last_char ? state->last_char->quad.ur.x : 0;
    ch->quad.ul = fz_make_point(x, 0); ch->quad.ur = fz_make_point(x + 1, 0);
    ch->quad.ll = fz_make_point(x, 1); ch->quad.lr = fz_make_point(x + 1, 1);
    if (state->last_char) state->last_char->next = ch;
    else state->line->first_char = ch;
    state->line->last_char = state->last_char = ch;
    state->last_char_after_assigned = 0;
}
static void markdown_feed_chunk(MarkdownSearchState *state) {
    if (!state->building || !state->last_char || state->finished) return;
    fz_context *ctx = state->document->ctx;
    state->line->flags |= FZ_STEXT_LINE_FLAGS_NO_TRAILING_SEPARATOR;
    if (state->sequence && state->requested != state->sequence)
        fz_throw(ctx, FZ_ERROR_FORMAT, "Markdown search chunk sequence is inconsistent");
    /* fz_feed_search owns the page, including when preparing its haystack throws. */
    fz_stext_page *page = state->building;
    state->building = NULL; state->line = NULL; state->last_char = NULL;
    fz_feed_search(ctx, state->search, page, state->sequence++);
    state->requested = -1;
    markdown_drain_search(state);
}
static int markdown_search_source_char(fz_context *ctx, void *opaque, const fz_html_search_char *source) {
    MarkdownSearchState *state = opaque;
    if (state->finished) return 1;
    /* MuPDF's default page flattening removes authored soft hyphens. */
    if (source->unicode == 0xad) return 0;
    if (state->last_char && !state->last_char_after_assigned) {
        if (search_word_char(source->unicode)) state->last_char->flags |= MARKDOWN_WORD_AFTER;
        state->last_char_after_assigned = 1;
    }
    fz_search_chunk_step step = fz_feed_search_chunker(ctx, state->chunker, source->unicode);
    state->normalized_bytes += step.normalized_before;
    if (step.safe_before && state->normalized_bytes >= state->chunk_goal && state->last_char) {
        markdown_feed_chunk(state);
        state->normalized_bytes = step.normalized_current;
    } else state->normalized_bytes += step.normalized_current;
    if (!state->finished && step.keep_rune) markdown_append_char(state, source);
    state->last_source_rune = source->unicode;
    return state->finished;
}

static void markdown_write_hit(SumraMuPDFDocument *d, SumraJSON *json, const MarkdownSearchHit *hit,
                               int (*cancelled)(void)) {
    fz_context *ctx = d->ctx;
    int emitted = 0, owner_page = -1, owner_index = 0;
    SumraSource last = {hit->last.node, hit->last.offset, UINT32_MAX};
    lf_json(json, "{\"source\":"); lf_json_source(json, hit->first);
    lf_json(json, ",\"context\":"); lf_json_string(json, hit->context ? hit->context : "");
    lf_json(json, ",\"fragments\":[");
    for (size_t i = 0; i < hit->page_count; ++i) {
        if (cancelled && cancelled()) fz_throw(ctx, FZ_ERROR_ABORT, "Search cancelled");
        int page_number = hit->pages[i];
        fz_stext_page *page = NULL;
        fz_buffer *buffer = NULL;
        fz_stext_position *map = NULL;
        fz_var(page); fz_var(buffer); fz_var(map);
        fz_try(ctx) {
            page = stext_at(d, 0, page_number, NULL, NULL);
            fz_try(ctx) {
                buffer = fz_new_buffer_from_flattened_stext_page(ctx, page, FZ_TEXT_FLATTEN_KEEP_PARAGRAPHS, &map);
            } fz_catch(ctx) { map = NULL; fz_rethrow(ctx); }
            const char *text = fz_string_from_buffer(ctx, buffer);
            size_t utf16 = 0, start = SIZE_MAX, end = 0;
            for (size_t at = 0, serial = 0; text[at]; ++serial) {
                if ((serial & 1023) == 0 && cancelled && cancelled()) fz_throw(ctx, FZ_ERROR_ABORT, "Search cancelled");
                int rune, bytes = fz_chartorune(&rune, text + at);
                fz_stext_char *ch = map[serial].ch;
                if (ch && ch->source_node) {
                    SumraSource source = source_of(ch);
                    if (!source_less(source, hit->first) && !source_less(last, source)) {
                        if (start == SIZE_MAX) start = utf16;
                        end = utf16 + (rune > 0xffff ? 2 : 1);
                    }
                }
                at += bytes; utf16 += rune > 0xffff ? 2 : 1;
            }
            if (start != SIZE_MAX) {
                if (emitted++) lf_json(json, ",");
                lf_json(json, "{\"page\":"); lf_json_number(json, page_number);
                lf_json(json, ",\"start\":"); lf_json_number(json, start);
                lf_json(json, ",\"length\":"); lf_json_number(json, end - start);
                lf_json(json, ",\"rects\":[");
                int rectangles = 0;
                size_t visited = 0;
                for (fz_stext_block *block = page->first_block; block; block = block->next) {
                    if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
                    for (fz_stext_line *line = block->u.t.first_line; line; line = line->next)
                        for (fz_stext_char *ch = line->first_char; ch; ch = ch->next) {
                            if (((++visited) & 1023) == 0 && cancelled && cancelled())
                                fz_throw(ctx, FZ_ERROR_ABORT, "Search cancelled");
                            if (!ch->source_node) continue;
                            SumraSource source = source_of(ch);
                            if (source_less(source, hit->first) || source_less(last, source)) continue;
                            fz_rect rect = fz_rect_from_quad(fz_search_source_quad(line, ch));
                            if (fz_is_empty_rect(rect)) continue;
                            if (rectangles++) lf_json(json, ",");
                            lf_json_rect(json, rect.x0, rect.y0, rect.x1 - rect.x0, rect.y1 - rect.y0);
                        }
                }
                lf_json(json, "]}");
                if (owner_page < 0) { owner_page = page_number; owner_index = (int)start; }
            }
        }
        fz_always(ctx) { fz_free(ctx, map); fz_drop_buffer(ctx, buffer); fz_drop_stext_page(ctx, page); }
        fz_catch(ctx) { fz_rethrow(ctx); }
        if (json->failed) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate Markdown search results");
    }
    lf_json(json, "],\"page\":"); lf_json_number(json, owner_page);
    if (!emitted) fz_throw(ctx, FZ_ERROR_FORMAT, "Markdown search source has no rendered fragment");
    lf_json(json, ",\"index\":"); lf_json_number(json, owner_index);
    lf_json(json, "}");
}

API char *lf_markdown_document_search(void *opaque, const char *needle, int flags,
    int start_page, uint32_t after_node, uint32_t after_offset, uint32_t after_part,
    int64_t maximum, const uint8_t *allowed_bits, size_t allowed_bytes,
    int (*cancelled)(void), char *error) {
    SumraMuPDFDocument *d = opaque;
    MarkdownSearchState state = {0};
    SumraJSON json = {0};
    fz_var(state); fz_var(json);
    if (!d || !needle || !*needle || maximum <= 0) {
        lf_json(&json, "{\"matches\":[]}");
        return lf_json_finish(&json, error);
    }
    fz_try(d->ctx) {
        if (!fz_htdoc_is_markdown(d->ctx, d->doc))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document is not Markdown");
        state.document = d; state.requested = -1;
        state.counting = (flags & 8) != 0;
        state.inclusive = (flags & 16) != 0;
        state.backwards = !state.counting && (flags & 4) != 0;
        state.whole_word = (flags & 2) != 0;
        state.start_page = start_page;
        state.after = (SumraSource){after_node, after_offset, after_part};
        state.allowed_bits = allowed_bits; state.allowed_bytes = allowed_bytes;
        state.cancelled = cancelled;
        state.maximum = (size_t)maximum;
        state.primary = fz_calloc(d->ctx, state.maximum, sizeof(*state.primary));
        if (!state.counting) state.wrap = fz_calloc(d->ctx, state.maximum, sizeof(*state.wrap));
        fz_search_options options = flags & 1 ? FZ_SEARCH_EXACT : FZ_SEARCH_IGNORE_CASE | FZ_SEARCH_IGNORE_DIACRITICS;
        state.search = fz_new_search(d->ctx, needle, options);
        state.chunker = fz_new_search_chunker(d->ctx, state.search);
        size_t needle_bytes = fz_search_needle_bytes(state.search);
        state.chunk_goal = needle_bytes > 32768 ? needle_bytes : 32768;
        if (needle_bytes) {
            int suffix = !state.counting && !state.backwards && !state.after.node && start_page > 0;
            for (int pass = 0; pass < (suffix ? 2 : 1); ++pass) {
                if (pass) {
                    /* Suffix wrap hits are not authoritative: an earlier
                       paragraph may have the first wrap result. Start fresh;
                       never join the document's end to its beginning. */
                    for (size_t i = 0; i < state.wrap_count; ++i) markdown_drop_hit(d->ctx, &state.wrap[i]);
                    state.wrap_count = 0;
                    fz_drop_stext_page(d->ctx, state.building); state.building = NULL;
                    state.line = NULL; state.last_char = NULL;
                    fz_drop_search_chunker(d->ctx, state.chunker); state.chunker = NULL;
                    fz_drop_search(d->ctx, state.search); state.search = NULL;
                    state.sequence = 0; state.requested = -1; state.finished = 0;
                    state.normalized_bytes = 0; state.last_source_rune = 0;
                    state.last_char_after_assigned = 0; state.last_start = (SumraSource){0};
                    state.wrap_only = 1;
                    state.search = fz_new_search(d->ctx, needle, options);
                    state.chunker = fz_new_search_chunker(d->ctx, state.search);
                }
                if (suffix && !pass)
                    fz_htdoc_walk_search_source_from_page(d->ctx, d->doc, start_page,
                        markdown_search_source_char, &state, cancelled);
                else
                    fz_htdoc_walk_search_source(d->ctx, d->doc, markdown_search_source_char, &state, cancelled);
                if (!state.finished) {
                    state.normalized_bytes += fz_finish_search_chunker(d->ctx, state.chunker);
                    markdown_feed_chunk(&state);
                    while (!state.finished) {
                        if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "Search cancelled");
                        fz_feed_search(d->ctx, state.search, NULL, state.requested < 0 ? 0 : state.requested);
                        markdown_drain_search(&state);
                    }
                }
                if (!suffix || state.primary_count) break;
            }
        }
        MarkdownSearchHit *hits = state.primary_count ? state.primary : state.wrap;
        size_t count = state.primary_count ? state.primary_count : state.wrap_count;
        lf_json(&json, "{\"matches\":[");
        for (size_t i = 0; i < count; ++i) {
            if (cancelled && cancelled()) fz_throw(d->ctx, FZ_ERROR_ABORT, "Search cancelled");
            if (i) lf_json(&json, ",");
            size_t at = state.backwards ? count - i - 1 : i;
            markdown_write_hit(d, &json, &hits[at], cancelled);
        }
        lf_json(&json, "]}");
        if (json.failed) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "Cannot allocate Markdown search results");
    }
    fz_always(d->ctx) {
        for (size_t i = 0; i < state.primary_count; ++i) markdown_drop_hit(d->ctx, &state.primary[i]);
        for (size_t i = 0; i < state.wrap_count; ++i) markdown_drop_hit(d->ctx, &state.wrap[i]);
        fz_free(d->ctx, state.primary); fz_free(d->ctx, state.wrap);
        fz_drop_stext_page(d->ctx, state.building);
        fz_drop_search_chunker(d->ctx, state.chunker);
        fz_drop_search(d->ctx, state.search);
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(json.data); return NULL; }
    return lf_json_finish(&json, error);
}
static void selection_word(fz_context *ctx, void *arg, fz_stext_line *line, fz_stext_char *ch) {
    SumraSelectionWriter *writer = arg; SumraJSON *j = writer->json; char glyph[8] = {0};
    if (j->failed) return;
    if (j->data[j->len-1] != '[') lf_json(j, ",");
    if (ch) fz_runetochar(glyph, ch->c < 32 ? FZ_REPLACEMENT_CHARACTER : ch->c);
    else glyph[0] = '\n';
    fz_rect r = ch ? fz_rect_from_quad(ch->quad) : fz_make_rect(0, 0, 0, 0);
    lf_json(j, "{\"text\":"); lf_json_string(j, glyph); lf_json(j, ",\"rect\":");
    lf_json_rect(j, r.x0, r.y0, r.x1-r.x0, r.y1-r.y0);
    if (writer->source_enabled && ch && ch->source_node) {
        SumraSource source = source_of(ch);
        if (!writer->first.node || source_less(source, writer->first)) writer->first = source;
        if (!writer->last.node || source_less(writer->last, source)) writer->last = source;
        lf_json(j, ",\"source\":"); lf_json_source(j, source);
    }
    lf_json(j, "}");
}
static void selection_line(fz_context *ctx, void *arg, fz_stext_line *line) { selection_word(ctx, arg, line, NULL); }
API char *lf_select_at(SumraMuPDFDocument *d, int chapter, int index, float ax, float ay, float bx, float by, int mode, void *opaque_cookie, char *error) {
    fz_cookie *cookie = opaque_cookie;
    fz_stext_page *text = NULL; char *selected = NULL; fz_quad *quads = NULL; SumraJSON j = {0};
    SumraSelectionWriter writer = { .json = &j };
    fz_var(text); fz_var(selected); fz_var(quads); fz_var(j); fz_var(writer);
    fz_try(d->ctx) {
        text = stext_at(d, chapter, index, NULL, cookie);
        writer.source_enabled = lf_has_html_source(d);
        fz_point a = {ax, ay}, b = {bx, by};
        if (mode == FZ_SELECT_WORDS || mode == FZ_SELECT_LINES) fz_snap_selection(d->ctx, text, &a, &b, mode);
        if (mode == 3) {
            fz_rect box = { fminf(ax, bx), fminf(ay, by), fmaxf(ax, bx), fmaxf(ay, by) };
            selected = fz_copy_rectangle(d->ctx, text, box, 0);
            lf_json(&j, "{\"text\":"); lf_json_string(&j, selected); lf_json(&j, ",\"rects\":[");
            lf_json_rect(&j, box.x0, box.y0, box.x1-box.x0, box.y1-box.y0); lf_json(&j, "]");
        } else {
        selected = fz_copy_selection(d->ctx, text, a, b, 0);
        int capacity = 32, n;
        do {
            fz_free(d->ctx, quads); quads = fz_malloc_array(d->ctx, capacity, fz_quad);
            n = fz_highlight_selection(d->ctx, text, a, b, quads, capacity);
            if (n < capacity) break;
            if (capacity > INT_MAX / 2)
                fz_throw(d->ctx, FZ_ERROR_GENERIC, "Selection is too large");
            capacity *= 2;
        } while (1);
        lf_json(&j, "{\"text\":"); lf_json_string(&j, selected); lf_json(&j, ",\"rects\":[");
        for (int i = 0; i < n; ++i) { if (i) lf_json(&j, ","); fz_rect r = fz_rect_from_quad(quads[i]); lf_json_rect(&j, r.x0, r.y0, r.x1-r.x0, r.y1-r.y0); }
        lf_json(&j, "],\"quads\":[");
        for (int i = 0; i < n; ++i) {
            if (i) lf_json(&j, ",");
            fz_point points[] = {quads[i].ul, quads[i].ur, quads[i].ll, quads[i].lr};
            lf_json(&j, "[");
            for (int k = 0; k < 4; ++k) {
                if (k) lf_json(&j, ",");
                lf_json(&j, "["); lf_json_number(&j, points[k].x); lf_json(&j, ",");
                lf_json_number(&j, points[k].y); lf_json(&j, "]");
            }
            lf_json(&j, "]");
        }
        lf_json(&j, "]");
        }
        lf_json(&j, ",\"words\":[");
        fz_process_stext_selection(d->ctx, text, a, b, mode == 3, selection_word, selection_line, &writer);
        lf_json(&j, "]");
        if (mode != 3 && writer.first.node && writer.last.node) {
            lf_json(&j, ",\"sourceStart\":"); lf_json_source(&j, writer.first);
            lf_json(&j, ",\"sourceEnd\":"); lf_json_source(&j, writer.last);
        }
        lf_json(&j, "}");
    }
    fz_always(d->ctx) { fz_free(d->ctx, selected); fz_free(d->ctx, quads); fz_drop_stext_page(d->ctx, text); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}

API char *lf_html_page_anchor_at(void *opaque, int chapter, int index, float x, float y, char *error) {
    SumraMuPDFDocument *d = opaque;
    fz_stext_page *page = NULL; SumraJSON j = {0}; fz_var(page); fz_var(j);
    fz_try(d->ctx) {
        if (!isfinite(x) || !isfinite(y)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid anchor point");
        if (!lf_has_html_source(d)) lf_json(&j, "null");
        else {
            page = stext_at(d, chapter, index, NULL, NULL);
            fz_stext_char *nearest = NULL; double best = INFINITY;
            for (fz_stext_block *block = page->first_block; block; block = block->next) {
                if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
                for (fz_stext_line *line = block->u.t.first_line; line; line = line->next)
                    for (fz_stext_char *ch = line->first_char; ch; ch = ch->next) {
                        // A line-break space can disappear at a different
                        // font size. Anchor reading positions to visible text.
                        if (!ch->source_node || fz_is_unicode_whitespace(ch->c)) continue;
                        fz_rect r = fz_rect_from_quad(ch->quad);
                        double dx = fmax(fmax(r.x0-x, 0), x-r.x1), dy = fmax(fmax(r.y0-y, 0), y-r.y1);
                        double distance = dx*dx + dy*dy;
                        if (distance < best) { best = distance; nearest = ch; }
                    }
            }
            if (!nearest) lf_json(&j, "null");
            else {
                fz_rect r = fz_rect_from_quad(nearest->quad);
                lf_json(&j, "{\"source\":"); lf_json_source(&j, source_of(nearest)); lf_json(&j, ",\"rect\":");
                lf_json_rect(&j, r.x0, r.y0, r.x1-r.x0, r.y1-r.y0); lf_json(&j, "}");
            }
        }
    }
    fz_always(d->ctx) { fz_drop_stext_page(d->ctx, page); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}

API char *lf_html_anchor_position(void *opaque, int chapter, uint32_t node, uint32_t byte_offset, uint32_t part, char *error) {
    SumraMuPDFDocument *d = opaque;
    fz_stext_page *text = NULL; SumraJSON j = {0}; fz_var(text); fz_var(j);
    fz_try(d->ctx) {
        (void)fz_count_chapter_pages(d->ctx, d->doc, chapter); // Ensure current layout is complete.
        int page = chapter == 0 ? fz_htdoc_source_page(d->ctx, d->doc, node, byte_offset) : -1;
        if (page < 0) lf_json(&j, "null");
        else {
            text = stext_at(d, chapter, page, NULL, NULL);
            fz_stext_char *found = NULL;
            for (fz_stext_block *block = text->first_block; block && !found; block = block->next) {
                if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
                for (fz_stext_line *line = block->u.t.first_line; line && !found; line = line->next)
                    for (fz_stext_char *ch = line->first_char; ch; ch = ch->next)
                        if (ch->source_node == node && ch->source_offset == byte_offset && ch->source_part == part) { found = ch; break; }
            }
            if (!found) lf_json(&j, "null");
            else {
                fz_rect r = fz_rect_from_quad(found->quad);
                lf_json(&j, "{\"page\":"); lf_json_number(&j, page); lf_json(&j, ",\"rect\":");
                lf_json_rect(&j, r.x0, r.y0, r.x1-r.x0, r.y1-r.y0);
                lf_json(&j, fz_is_unicode_whitespace(found->c) ? ",\"whitespace\":true}" : ",\"whitespace\":false}");
            }
        }
    }
    fz_always(d->ctx) { fz_drop_stext_page(d->ctx, text); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}

typedef struct { fz_stext_char *ch; fz_stext_line *line; } SumraSelectedChar;
static int source_in_range(fz_stext_char *ch, SumraSource first, SumraSource last) {
    if (!ch->source_node) return 0;
    SumraSource value = source_of(ch);
    return !source_less(value, first) && !source_less(last, value);
}
API char *lf_select_anchors_at(void *opaque, int chapter, int index,
    uint32_t start_node, uint32_t start_offset, uint32_t start_part,
    uint32_t end_node, uint32_t end_offset, uint32_t end_part, char *error) {
    SumraMuPDFDocument *d = opaque;
    SumraSource first = { start_node, start_offset, start_part }, last = { end_node, end_offset, end_part };
    fz_stext_page *page = NULL; fz_buffer *buffer = NULL; SumraSelectedChar *items = NULL;
    size_t count = 0, capacity = 0; SumraJSON j = {0}; SumraSelectionWriter writer = { .json = &j, .source_enabled = 1 };
    fz_var(page); fz_var(buffer); fz_var(items); fz_var(j); fz_var(writer);
    fz_try(d->ctx) {
        if (!first.node || !last.node || source_less(last, first)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid source selection");
        if (!lf_has_html_source(d)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document has no HTML source anchors");
        page = stext_at(d, chapter, index, NULL, NULL);
        size_t serial = 0, first_serial = SIZE_MAX, last_serial = 0;
        for (fz_stext_block *block = page->first_block; block; block = block->next) {
            if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
            for (fz_stext_line *line = block->u.t.first_line; line; line = line->next)
                for (fz_stext_char *ch = line->first_char; ch; ch = ch->next, ++serial)
                    if (source_in_range(ch, first, last)) { if (first_serial == SIZE_MAX) first_serial = serial; last_serial = serial; }
        }
        serial = 0;
        if (first_serial != SIZE_MAX)
            for (fz_stext_block *block = page->first_block; block; block = block->next) {
                if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
                for (fz_stext_line *line = block->u.t.first_line; line; line = line->next)
                    for (fz_stext_char *ch = line->first_char; ch; ch = ch->next, ++serial) {
                        if (serial < first_serial || serial > last_serial || (ch->source_node && !source_in_range(ch, first, last))) continue;
                        if (count == capacity) {
                            size_t next = capacity ? capacity * 2 : 256;
                            SumraSelectedChar *grown = fz_realloc_array(d->ctx, items, next, SumraSelectedChar);
                            items = grown; capacity = next;
                        }
                        items[count++] = (SumraSelectedChar){ch, line};
                    }
        }
        buffer = fz_new_buffer(d->ctx, 256);
        for (size_t i = 0; i < count; ++i) {
            if (i && items[i].line != items[i-1].line) fz_append_byte(d->ctx, buffer, '\n');
            fz_append_rune(d->ctx, buffer, items[i].ch->c < 32 ? FZ_REPLACEMENT_CHARACTER : items[i].ch->c);
        }
        fz_terminate_buffer(d->ctx, buffer);
        lf_json(&j, "{\"text\":"); lf_json_string(&j, fz_string_from_buffer(d->ctx, buffer));
        lf_json(&j, ",\"rects\":[");
        int emitted = 0;
        for (size_t i = 0; i < count; ++i) {
            fz_rect r = fz_rect_from_quad(items[i].ch->quad);
            if (fz_is_empty_rect(r)) continue;
            if (emitted++) lf_json(&j, ",");
            lf_json_rect(&j, r.x0, r.y0, r.x1-r.x0, r.y1-r.y0);
        }
        lf_json(&j, "],\"quads\":["); emitted = 0;
        for (size_t i = 0; i < count; ++i) {
            fz_rect r = fz_rect_from_quad(items[i].ch->quad);
            if (fz_is_empty_rect(r)) continue;
            if (emitted++) lf_json(&j, ",");
            fz_quad q = items[i].ch->quad;
            fz_point points[] = {q.ul, q.ur, q.ll, q.lr}; lf_json(&j, "[");
            for (int k = 0; k < 4; ++k) { if (k) lf_json(&j, ","); lf_json(&j, "[");
                lf_json_number(&j, points[k].x); lf_json(&j, ","); lf_json_number(&j, points[k].y); lf_json(&j, "]"); }
            lf_json(&j, "]");
        }
        lf_json(&j, "],\"words\":[");
        for (size_t i = 0; i < count; ++i) {
            if (i && items[i].line != items[i-1].line) selection_line(d->ctx, &writer, items[i].line);
            selection_word(d->ctx, &writer, items[i].line, items[i].ch);
        }
        lf_json(&j, "]");
        if (writer.first.node && writer.last.node) {
            lf_json(&j, ",\"sourceStart\":"); lf_json_source(&j, writer.first);
            lf_json(&j, ",\"sourceEnd\":"); lf_json_source(&j, writer.last);
        }
        lf_json(&j, "}");
    }
    fz_always(d->ctx) { fz_free(d->ctx, items); fz_drop_buffer(d->ctx, buffer); fz_drop_stext_page(d->ctx, page); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}
API char *lf_html_source_selection_text(void *opaque,
    const uint32_t *nodes, const uint32_t *offsets, const uint32_t *parts,
    const int32_t *unicode, int count, char *error) {
    SumraMuPDFDocument *d = opaque;
    fz_html_selection_char *chars = NULL;
    fz_buffer *buffer = NULL; SumraJSON j = {0};
    fz_var(chars); fz_var(buffer); fz_var(j);
    fz_try(d->ctx) {
        if (count < 0 || (count && (!nodes || !offsets || !parts || !unicode)))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid Markdown source selection");
        if (!lf_has_html_source(d)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Document has no HTML source anchors");
        chars = count ? fz_malloc_array(d->ctx, count, fz_html_selection_char) : NULL;
        for (int i = 0; i < count; ++i) {
            if (!nodes[i] || unicode[i] < 0 || unicode[i] > 0x10ffff ||
                (i && (nodes[i] < nodes[i-1] || (nodes[i] == nodes[i-1] &&
                    (offsets[i] < offsets[i-1] || (offsets[i] == offsets[i-1] && parts[i] < parts[i-1]))))))
                fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Invalid Markdown source selection order");
            chars[i] = (fz_html_selection_char){ nodes[i], offsets[i], parts[i], unicode[i] };
        }
        buffer = fz_new_buffer(d->ctx, 256);
        fz_htdoc_source_selection_text(d->ctx, d->doc, chars, count, buffer);
        fz_terminate_buffer(d->ctx, buffer);
        lf_json(&j, "{\"text\":"); lf_json_string(&j, fz_string_from_buffer(d->ctx, buffer)); lf_json(&j, "}");
    }
    fz_always(d->ctx) { fz_free(d->ctx, chars); fz_drop_buffer(d->ctx, buffer); }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); free(j.data); return NULL; }
    return lf_json_finish(&j, error);
}
API int lf_resolve_at(SumraMuPDFDocument *d, const char *uri, int *location, float *point, char *error) {
    int found = 0; fz_var(found);
    fz_try(d->ctx) {
        fz_link_dest dest = fz_resolve_link_dest(d->ctx, d->doc, uri);
        found = dest.loc.chapter >= 0 && dest.loc.page >= 0;
        location[0] = dest.loc.chapter; location[1] = dest.loc.page;
        point[0] = dest.x; point[1] = dest.y;
    }
    fz_catch(d->ctx) { snprintf(error, 512, "%s", fz_convert_error(d->ctx, NULL)); return -1; }
    return found;
}

// Sumatra SvgIcons.cpp::RenderSvgToFzPixmap (012d997f), using the SVG parser
// already linked into MuPDF. currentColor substitution belongs to the caller.
API unsigned char *lf_svg_icon(const unsigned char *data, size_t length, int size, char *error) {
    if (!data || !length) { snprintf(error, 512, "Missing SVG icon data"); return NULL; }
    fz_context *ctx = lf_new_context(32 << 20);
    if (!ctx) { snprintf(error, 512, "Cannot create SVG context"); return NULL; }
    fz_buffer *buffer = NULL; fz_display_list *list = NULL; fz_device *device = NULL;
    fz_pixmap *pixmap = NULL; unsigned char *output = NULL;
    fz_var(buffer); fz_var(list); fz_var(device); fz_var(pixmap); fz_var(output);
    fz_try(ctx) {
        lf_install_system_fonts(ctx);
        buffer = fz_new_buffer_from_copied_data(ctx, data, length);
        float width = 0, height = 0;
        list = fz_new_display_list_from_svg(ctx, buffer, NULL, NULL, &width, &height);
        if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0)
            fz_throw(ctx, FZ_ERROR_FORMAT, "SVG icon needs positive finite dimensions");
        pixmap = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), fz_make_irect(0, 0, size, size), NULL, 1);
        fz_clear_pixmap(ctx, pixmap);
        device = fz_new_draw_device(ctx, fz_scale(size / width, size / height), pixmap);
        fz_run_display_list(ctx, list, device, fz_identity, fz_infinite_rect, NULL);
        fz_close_device(ctx, device);
        output = malloc((size_t)size * size * 4);
        if (!output) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate SVG icon pixels");
        for (int y = 0; y < size; ++y)
            memcpy(output + (size_t)y * size * 4, pixmap->samples + (size_t)y * pixmap->stride, (size_t)size * 4);
    }
    fz_always(ctx) { fz_drop_device(ctx, device); fz_drop_pixmap(ctx, pixmap); fz_drop_display_list(ctx, list); fz_drop_buffer(ctx, buffer); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(output); output = NULL; }
    fz_drop_context(ctx);
    return output;
}
