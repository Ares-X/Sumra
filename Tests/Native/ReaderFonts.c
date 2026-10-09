// Link the production callbacks and font archive, without starting the app.
#include <mupdf/fitz.h>
#include <mupdf/ucdn.h>
#include <mupdf/pdf.h>
#include <string.h>
#include <stdio.h>

extern fz_context *lf_new_context(size_t max_store);
extern void lf_install_system_fonts(fz_context *ctx);

static int failures;
static void check(int ok, const char *message)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); ++failures; }
}

static const struct { int scalar, script, language; const char *label; } samples[] = {
    {0x00E9, UCDN_SCRIPT_LATIN, FZ_LANG_UNSET, "Latin e acute"},
    {0x03A9, UCDN_SCRIPT_GREEK, FZ_LANG_UNSET, "Greek omega"},
    {0x0416, UCDN_SCRIPT_CYRILLIC, FZ_LANG_UNSET, "Cyrillic zhe"},
    {0x0645, UCDN_SCRIPT_ARABIC, FZ_LANG_UNSET, "Arabic meem"},
    {0x05E9, UCDN_SCRIPT_HEBREW, FZ_LANG_UNSET, "Hebrew shin"},
    {0x4E2D, UCDN_SCRIPT_HAN, FZ_LANG_zh_Hans, "Simplified Chinese"},
    {0x570B, UCDN_SCRIPT_HAN, FZ_LANG_zh_Hant, "Traditional Chinese"},
    {0x3042, UCDN_SCRIPT_HIRAGANA, FZ_LANG_ja, "Hiragana"},
    {0x30A2, UCDN_SCRIPT_KATAKANA, FZ_LANG_ja, "Katakana"},
    {0xD55C, UCDN_SCRIPT_HANGUL, FZ_LANG_ko, "Hangul"},
    {0x3105, UCDN_SCRIPT_BOPOMOFO, FZ_LANG_zh_Hant, "Bopomofo"},
    {0x300C, UCDN_SCRIPT_COMMON, FZ_LANG_ja, "CJK opening quotation mark"},
    {0x9F98, UCDN_SCRIPT_HAN, FZ_LANG_zh_Hant, "Rare traditional Chinese character"},
    {0x0E01, UCDN_SCRIPT_THAI, FZ_LANG_UNSET, "Thai ko kai"},
    {0x0915, UCDN_SCRIPT_DEVANAGARI, FZ_LANG_UNSET, "Devanagari ka"},
    {0x222B, UCDN_SCRIPT_COMMON, FZ_LANG_UNSET, "Math integral"},
    {0x1D11E, UCDN_SCRIPT_COMMON, FZ_LANG_UNSET, "Music G clef"},
    {0x1F600, UCDN_SCRIPT_COMMON, FZ_LANG_UNSET, "Emoji grinning face"},
};

static void check_samples(fz_context *ctx)
{
    fz_font *base = NULL;
    fz_var(base);
    fz_try(ctx) {
        base = fz_new_base14_font(ctx, "Helvetica");
        for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); ++i) {
            fz_font *font = NULL;
            int gid = fz_encode_character_with_fallback(ctx, base, samples[i].scalar,
                samples[i].script, samples[i].language, &font);
            check(gid > 0 && font, samples[i].label);
            if (gid > 0 && font) {
                // A missing-character box or unrelated glyph is not coverage.
                check(fz_encode_character(ctx, font, samples[i].scalar) == gid, samples[i].label);
                check(!fz_is_empty_rect(fz_bound_glyph(ctx, font, gid, fz_identity)), samples[i].label);
            }
        }
    }
    fz_always(ctx) { fz_drop_font(ctx, base); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

// Helvetica regular and bold are faces of macOS's installed collection.
// PDF reuse must distinguish those faces while still reusing the same face.
static void check_collection_resources(fz_context *ctx)
{
    fz_font *regular = NULL, *bold = NULL;
    pdf_document *doc = NULL;
    pdf_obj *r = NULL, *b = NULL, *again = NULL;
    fz_var(regular); fz_var(bold); fz_var(doc);
    fz_var(r); fz_var(b); fz_var(again);
    fz_try(ctx) {
        lf_install_system_fonts(ctx);
        regular = fz_load_system_font(ctx, "Helvetica", 0, 0, 1);
        bold = fz_load_system_font(ctx, "Helvetica", 1, 0, 0);
        check(regular && bold, "Installed regular and bold faces are available");
        if (regular && bold) {
            unsigned char rd[16], bd[16];
            fz_font_digest(ctx, regular, rd); fz_font_digest(ctx, bold, bd);
            check(regular->buffer && regular->buffer->len >= 4 &&
                !memcmp(regular->buffer->data, "ttcf", 4) && !memcmp(rd, bd, 16) &&
                regular->subfont != bold->subfont, "Collection fixture has distinct faces of the same font bytes");
            doc = pdf_create_document(ctx);
            r = pdf_add_cid_font(ctx, doc, regular);
            b = pdf_add_cid_font(ctx, doc, bold);
            again = pdf_add_cid_font(ctx, doc, regular);
            check(pdf_to_num(ctx, r) != pdf_to_num(ctx, b), "PDF resources retain distinct TTC faces");
            check(pdf_to_num(ctx, r) == pdf_to_num(ctx, again), "PDF resources still deduplicate the same face");
        }
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, again); pdf_drop_obj(ctx, b); pdf_drop_obj(ctx, r);
        pdf_drop_document(ctx, doc); fz_drop_font(ctx, bold); fz_drop_font(ctx, regular);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

int main(void)
{
    // Keep one independent font alive while the context that first populated
    // the shared file cache disappears. Then load it repeatedly in fresh contexts.
    fz_context *first = lf_new_context(FZ_STORE_UNLIMITED);
    fz_context *survivor = lf_new_context(FZ_STORE_UNLIMITED);
    if (!first || !survivor) return 2;
    fz_font *warm = NULL, *live = NULL;
    int failed = 0;
    fz_var(first); fz_var(warm); fz_var(live); fz_var(failed);
    fz_try(first) {
        lf_install_system_fonts(first);
        warm = fz_load_system_font(first, "Helvetica", 0, 0, 1);
    }
    fz_catch(first) { fprintf(stderr, "%s\n", fz_caught_message(first)); failed = 1; }
    fz_try(survivor) {
        lf_install_system_fonts(survivor);
        live = fz_load_system_font(survivor, "Helvetica", 0, 0, 1);
        check(warm && live, "Load an installed exact named font in independent contexts");
        fz_drop_font(first, warm); warm = NULL;
        fz_drop_context(first); first = NULL;
        if (live) {
            int gid = fz_encode_character(survivor, live, 'W');
            check(gid > 0 && !fz_is_empty_rect(fz_bound_glyph(survivor, live, gid, fz_identity)),
                "Font bytes survive the first context's teardown");
        }
        check_samples(survivor);
        check_collection_resources(survivor);
    }
    fz_catch(survivor) { fprintf(stderr, "%s\n", fz_caught_message(survivor)); failed = 1; }
    if (first) { fz_drop_font(first, warm); fz_drop_context(first); }
    fz_drop_font(survivor, live); fz_drop_context(survivor);
    for (int i = 0; i < 4 && !failed; ++i) {
        fz_context *ctx = lf_new_context(FZ_STORE_UNLIMITED);
        if (!ctx) return 2;
        fz_font *named = NULL;
        fz_var(named);
        fz_try(ctx) {
            lf_install_system_fonts(ctx);
            named = fz_load_system_font(ctx, "Helvetica", 0, 0, 1);
            check(named && fz_encode_character(ctx, named, 'W') > 0,
                "Repeated named-font loads reuse valid bytes after context teardown");
            check_samples(ctx);
        }
        fz_always(ctx) { fz_drop_font(ctx, named); }
        fz_catch(ctx) { fprintf(stderr, "%s\n", fz_caught_message(ctx)); failed = 1; }
        fz_drop_context(ctx);
    }
    return failed || failures ? 1 : 0;
}
