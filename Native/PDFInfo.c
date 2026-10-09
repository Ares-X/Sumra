#include "Engine.h"
// Keep MuPDF's resource traversal, formatting, and cleanup in one owner.
// A qualified include avoids this file's case-insensitive macOS name.
#include <tools/pdfinfo.c>

static void info_write(fz_context *ctx, void *opaque, const void *data, size_t count) {
    SumraJSON *text = opaque;
    lf_json_append(text, data, count);
    if (text->failed) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate PDF information");
}

API char *lf_pdf_resource_report(const char *source, const char *password, size_t *length, char *error) {
    *length = 0;
    fz_context *ctx = lf_new_context(32 << 20);
    if (!ctx) { snprintf(error, 512, "Cannot create PDF context"); return NULL; }
    fz_output *output = NULL; SumraJSON text = {0};
    fz_var(output); fz_var(text);
    fz_try(ctx) {
        output = fz_new_output(ctx, 4096, &text, info_write, NULL, NULL);
        char *arguments[] = {(char *)source};
        pdfinfo_info(ctx, output, (char *)source, (char *)password, ALL, arguments, 1);
        fz_close_output(ctx, output);
    }
    fz_always(ctx) { fz_drop_output(ctx, output); }
    fz_catch(ctx) { free(text.data); text.data = NULL; snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); }
    fz_drop_context(ctx);
    if (text.data) *length = text.len;
    return text.data;
}
