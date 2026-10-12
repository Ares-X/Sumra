#include "Engine.h"
#include "MuPDFDocument.h"
// Keep MuPDF's resource traversal, formatting, and cleanup in one owner.
// A qualified include avoids this file's case-insensitive macOS name.
#include <tools/pdfinfo.c>

static void info_write(fz_context *ctx, void *opaque, const void *data, size_t count) {
    SumraJSON *text = opaque;
    lf_json_append(text, data, count);
    if (text->failed) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate PDF information");
}

API char *lf_pdf_live_resource_report(void *opaque, size_t *length, char *error) {
    SumraMuPDFDocument *document = opaque;
    *length = 0;
    fz_context *ctx = document->ctx;
    fz_output *output = NULL; SumraJSON text = {0};
    globals report = {0};
    fz_var(output); fz_var(text); fz_var(report);
    fz_try(ctx) {
        report.doc = pdf_specifics(ctx, document->doc);
        if (!report.doc) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Document is not a PDF");
        output = fz_new_output(ctx, 4096, &text, info_write, NULL, NULL);
        report.ctx = ctx; report.out = output;
        report.pagecount = pdf_count_pages(ctx, report.doc);
        showglobalinfo(ctx, &report);
        showzugferd(ctx, &report);
        showinfo(ctx, &report, "Current document", ALL, "1-N");
        fz_close_output(ctx, output);
    }
    fz_always(ctx) { clearinfo(ctx, &report); fz_drop_output(ctx, output); }
    fz_catch(ctx) { free(text.data); text.data = NULL; snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    if (text.data) *length = text.len;
    return text.data;
}
