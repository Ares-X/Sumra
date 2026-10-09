// Exercise public PDF annotation appearance, saving, extraction and raster APIs.
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

extern fz_context *lf_new_context(size_t max_store);
extern void lf_install_system_fonts(fz_context *ctx);
static int failures, warnings, unsupported_copy;
static void check(int ok, const char *label, const char *condition)
{
    if (!ok) { fprintf(stderr, "FAIL %s: %s\n", label, condition); ++failures; }
}
static void warning(void *user, const char *message)
{
    (void)user; ++warnings; fprintf(stderr, "MuPDF warning: %s\n", message);
}
static int embedded(fz_context *ctx, pdf_obj *font)
{
    pdf_obj *desc = pdf_dict_get(ctx, font, PDF_NAME(FontDescriptor));
    pdf_obj *children = pdf_dict_get(ctx, font, PDF_NAME(DescendantFonts));
    if (pdf_array_len(ctx, children))
        desc = pdf_dict_get(ctx, pdf_array_get(ctx, children, 0), PDF_NAME(FontDescriptor));
    return !!(pdf_dict_get(ctx, desc, PDF_NAME(FontFile)) ||
        pdf_dict_get(ctx, desc, PDF_NAME(FontFile2)) || pdf_dict_get(ctx, desc, PDF_NAME(FontFile3)));
}
static pdf_document *make_document(fz_context *ctx, const char *text, fz_text_language lang, int rich)
{
    pdf_document *doc = pdf_create_document(ctx);
    pdf_page *page = NULL; pdf_annot *annot = NULL; pdf_obj *obj = NULL;
    fz_var(page); fz_var(annot); fz_var(obj);
    fz_try(ctx) {
        obj = pdf_add_page(ctx, doc, fz_make_rect(0, 0, 640, 160), 0, NULL, NULL);
        pdf_insert_page(ctx, doc, 0, obj);
        page = pdf_load_page(ctx, doc, 0);
        annot = pdf_create_annot(ctx, page, PDF_ANNOT_FREE_TEXT);
        pdf_set_annot_rect(ctx, annot, fz_make_rect(30, 50, 610, 100));
        pdf_set_annot_border_width(ctx, annot, 0);
        float color[3] = {0, 0, 0};
        pdf_set_annot_default_appearance(ctx, annot, "Helv", 12, 3, color);
        pdf_set_annot_contents(ctx, annot, text);
        if (lang != FZ_LANG_UNSET) pdf_set_annot_language(ctx, annot, lang);
        if (rich) pdf_set_annot_rich_defaults(ctx, annot,
            "font-family:Helvetica;font-size:12pt;color:#000000;text-align:left;");
        pdf_update_annot(ctx, annot);
    }
    fz_always(ctx) { pdf_drop_annot(ctx, annot); fz_drop_page(ctx, (fz_page *)page); pdf_drop_obj(ctx, obj); }
    fz_catch(ctx) { pdf_drop_document(ctx, doc); fz_rethrow(ctx); }
    return doc;
}
static fz_pixmap *inspect(fz_context *ctx, pdf_document *doc, const char *label, const char *text, int rich, int require_text)
{
    pdf_page *page = NULL; fz_stext_page *stext = NULL; char *copied = NULL; fz_pixmap *pix = NULL; fz_device *dev = NULL;
    fz_var(page); fz_var(stext); fz_var(copied); fz_var(pix); fz_var(dev);
    fz_try(ctx) {
        check(pdf_count_pages(ctx, doc) == 1, label, "one saved page");
        page = pdf_load_page(ctx, doc, 0);
        pdf_annot *annot = pdf_first_annot(ctx, page);
        check(annot && pdf_annot_type(ctx, annot) == PDF_ANNOT_FREE_TEXT, label, "interactive FreeText survives");
        check(!strcmp(pdf_annot_contents(ctx, annot), text), label, "Unicode contents survive");
        pdf_obj *fonts = pdf_dict_getp(ctx, pdf_annot_obj(ctx, annot), "AP/N/Resources/Font");
        int embedded_count = 0, cmap_count = 0;
        for (int i = 0; i < pdf_dict_len(ctx, fonts); ++i) {
            pdf_obj *font = pdf_dict_get_val(ctx, fonts, i);
            embedded_count += embedded(ctx, font);
            const char *encoding = pdf_to_name(ctx, pdf_dict_get(ctx, font, PDF_NAME(Encoding)));
            cmap_count += !strncmp(encoding, "Uni", 3);
        }
        check(pdf_dict_len(ctx, fonts) > 0, label, "appearance fonts resolve");
        if (rich) {
            check(embedded_count > 0, label, "rich fallback embeds its font bytes");
            check(cmap_count == 0, label, "rich fallback avoids incomplete standard CJK Encoding");
        } else {
            check(cmap_count > 0, label, "encodable authored-language text retains standard CJK path");
        }
        stext = fz_new_stext_page(ctx, fz_make_rect(0, 0, 640, 160));
        dev = fz_new_stext_device(ctx, stext, NULL);
        // The page-only convenience extractor intentionally omits annotations.
        fz_run_page(ctx, (fz_page *)page, dev, fz_identity, NULL);
        fz_close_device(ctx, dev);
        copied = fz_copy_rectangle(ctx, stext, fz_make_rect(0, 0, 640, 160), 0);
        if (require_text) check(strstr(copied, text) != NULL, label, "copied appearance text contains every Unicode scalar");
        else if (!strstr(copied, text)) {
            ++unsupported_copy;
            printf("NOT_SUPPORTED copied-text %s expected=[%s] actual=[%s]\n", label, text, copied);
        }
        int before = warnings;
        pix = fz_new_pixmap_from_page(ctx, (fz_page *)page, fz_identity, fz_device_rgb(ctx), 0);
        fz_flush_warnings(ctx);
        check(warnings == before, label, "native rendering has no warnings");
        int ink = 0;
        for (int y = 0; y < fz_pixmap_height(ctx, pix); ++y) {
            unsigned char *row = fz_pixmap_samples(ctx, pix) + y * fz_pixmap_stride(ctx, pix);
            for (int x = 0; x < fz_pixmap_width(ctx, pix); ++x)
                if (row[x*3] < 128 && row[x*3+1] < 128 && row[x*3+2] < 128) ++ink;
        }
        check(ink > 10, label, "glyphs actually draw");
        printf("%s fonts=%d embedded=%d standardCJK=%d ink=%d\n", label,
            pdf_dict_len(ctx, fonts), embedded_count, cmap_count, ink);
    }
    fz_always(ctx) { fz_drop_device(ctx, dev); fz_free(ctx, copied); fz_drop_stext_page(ctx, stext); fz_drop_page(ctx, (fz_page *)page); }
    fz_catch(ctx) { fz_drop_pixmap(ctx, pix); fz_rethrow(ctx); }
    return pix;
}
static int equal_pixmaps(fz_context *ctx, fz_pixmap *a, fz_pixmap *b)
{
    int stride = fz_pixmap_stride(ctx, a), height = fz_pixmap_height(ctx, a);
    return stride == fz_pixmap_stride(ctx, b) && height == fz_pixmap_height(ctx, b) &&
        fz_pixmap_width(ctx, a) == fz_pixmap_width(ctx, b) &&
        !memcmp(fz_pixmap_samples(ctx, a), fz_pixmap_samples(ctx, b), (size_t)stride * height);
}
static const struct { const char *label, *text; fz_text_language lang; int rich, optional_probe; } cases[] = {
    {"unset-missing", "观", FZ_LANG_UNSET, 1},
    {"unset-mixed", "Sumra848 中英混排，保存后保持外观。", FZ_LANG_UNSET, 1},
    {"japanese-missing", "Latin 观", FZ_LANG_ja, 1},
    {"simplified", "Latin 观", FZ_LANG_zh_Hans, 0},
    {"traditional", "Latin 觀", FZ_LANG_zh_Hant, 0},
    {"japanese", "Latin 日本語", FZ_LANG_ja, 0},
    {"unset-jis", "Latin 日本語", FZ_LANG_UNSET, 0},
    {"jis-common", "漢字 。", FZ_LANG_UNSET, 0},
    {"jis-euro", "漢字 €", FZ_LANG_UNSET, 0},
    // Existing simple/rich engines have extraction or glyph limits for these.
    // Preserve measured parity and warnings, but do not claim full Unicode support.
    {"jis-inherited", "漢字 ́", FZ_LANG_UNSET, 1, 1},
    {"hant-common-missing", "漢字 ¤", FZ_LANG_zh_Hant, 1},
    {"korean-euro", "漢字 €", FZ_LANG_ko, 1},
    {"korean", "Latin 한글", FZ_LANG_ko, 0},
    {"korean-missing", "Latin 观", FZ_LANG_ko, 1},
    {"supplementary", "Latin 𠀀", FZ_LANG_UNSET, 1, 1},
    {"emoji", "Latin 😀", FZ_LANG_UNSET, 1, 1},
};
int main(int argc, char **argv)
{
    if (argc != 2) return 2; // Test-only output directory, never a product interface.
    fz_context *ctx = lf_new_context(64 << 20);
    if (!ctx) return 2;
    lf_install_system_fonts(ctx);
    fz_set_warning_callback(ctx, warning, NULL);
    fz_try(ctx) {
        for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); ++i) {
            const char *label = cases[i].label;
            pdf_document *doc = NULL, *reference = NULL, *saved = NULL;
            fz_pixmap *live = NULL, *expected = NULL, *reopened = NULL;
            fz_var(doc); fz_var(reference); fz_var(saved); fz_var(live); fz_var(expected); fz_var(reopened);
            fz_try(ctx) {
                doc = make_document(ctx, cases[i].text, cases[i].lang, 0);
                live = inspect(ctx, doc, label, cases[i].text, cases[i].rich, !cases[i].optional_probe);
                if (cases[i].rich) {
                    reference = make_document(ctx, cases[i].text, cases[i].lang, 1);
                    expected = inspect(ctx, reference, label, cases[i].text, 1, !cases[i].optional_probe);
                    check(equal_pixmaps(ctx, live, expected), label, "automatic fallback matches existing rich reference pixel-for-pixel");
                }
                char path[4096]; snprintf(path, sizeof path, "%s/%s.pdf", argv[1], label);
                pdf_write_options options = pdf_default_write_options;
                options.do_compress = 1;
                pdf_save_document(ctx, doc, path, &options);
                saved = pdf_open_document(ctx, path);
                reopened = inspect(ctx, saved, label, cases[i].text, cases[i].rich, !cases[i].optional_probe);
                check(equal_pixmaps(ctx, live, reopened), label, "saved appearance raster remains exact after reopening");
                snprintf(path, sizeof path, "%s/%s.png", argv[1], label);
                fz_save_pixmap_as_png(ctx, reopened, path);
            }
            fz_always(ctx) {
                fz_drop_pixmap(ctx, live); fz_drop_pixmap(ctx, expected); fz_drop_pixmap(ctx, reopened);
                pdf_drop_document(ctx, doc); pdf_drop_document(ctx, reference); pdf_drop_document(ctx, saved);
            }
            fz_catch(ctx) { fprintf(stderr, "FAIL %s exception: %s\n", label, fz_caught_message(ctx)); ++failures; }
        }
        fz_flush_warnings(ctx);
        check(warnings == 0, "matrix", "appearance generation, extraction and rendering are warning-free");
    }
    fz_catch(ctx) { fprintf(stderr, "FAIL exception: %s\n", fz_caught_message(ctx)); ++failures; }
    fz_drop_context(ctx);
    printf("appearance cases=%zu warnings=%d failures=%d optional-copy-limit-observations=%d\n",
        sizeof(cases)/sizeof(cases[0]), warnings, failures, unsupported_copy);
    return failures ? 1 : 0;
}
