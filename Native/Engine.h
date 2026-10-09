#pragma once
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <limits.h>
#include <math.h>

#define API __attribute__((visibility("default")))

// MuPDF contexts share its process-wide FreeType/HarfBuzz locks. This is an
// internal factory, not an exported engine ABI.
struct fz_context;
struct fz_page;
struct fz_display_list;
struct fz_cookie;
struct fz_context *lf_new_context(size_t max_store);
struct fz_display_list *lf_new_display_list(struct fz_context *ctx, struct fz_page *page,
    int contents_only, struct fz_cookie *cookie);

// MuPDF opens and authenticates one reading/editing document. On a password
// failure needs_password is 1; other failures leave it 0 and retain their cause.
API void *lf_open_classified(const char *path, const char *password, int *needs_password, char *error, int expected_pdf);
// Reader-only Markdown open: authenticate and classify now, then let the
// reader apply its first CSS/layout before querying pages or outline.
// PDF and all other formats retain the eager layout path.
API void *lf_open_classified_deferred(const char *path, const char *password, int *needs_password, char *error, int expected_pdf);
// JSON null identifies a non-PDF MuPDF document. Page labels are read on demand.
API char *lf_pdf_document_info(void *document, char *error);
API char *lf_pdf_page_label(void *document, int page, char *error);

// Per-render FitzAbortCookie. Only abort may run concurrently with rendering;
// the caller retains the opaque cookie until both calls have returned.
API void *lf_render_cookie_new(void);
API void lf_render_cookie_abort(void *cookie);
API int lf_render_cookie_aborted(void *cookie);
API void lf_render_cookie_drop(void *cookie);
API unsigned char *lf_render_cancelable_at(void *document, int chapter, int page, int width,
    const int *region, int alpha, const int *style, const uint32_t *colors, void *cookie, int *info, char *error);

// Native document PDF output; NULL pages selects every page, otherwise the
// zero-based indices are written in the supplied order. The callback is optional;
// return -1 for cancellation, 0 for failure, and 1 for a complete output.
API int lf_export_pdf(void *document, const char *path, const int *pages, int page_count, int (*cancelled)(void), char *error);
// Print uses the live PDF, Print appearances/optional content and PRINT permission.
// Optional regions are packed x/y/width/height in Fitz coordinates;
// region_counts gives the number of rectangles for each selected page.
// Output content_bounds has four floats per emitted page in bottom-left PDF space.
API int lf_print_pdf(void *document, const char *path, const int *pages, int page_count,
    const float *regions, const int *region_counts, int rotation, float *content_bounds, int bounds_count, void *cookie, char *error);
// Markdown Save-as-PDF only: preserve each one-page native PDF's text/font
// resources while AppKit owns the print dialog and physical paper settings.
// matrix is the six-value source-to-paper CGContext CTM immediately before
// drawPDFPage; source_clip is x/y/width/height in that source coordinate space.
API void *lf_print_source_pdf_begin(char *error);
API int lf_print_source_pdf_add(void *writer, const unsigned char *bytes, size_t size,
    double paper_width, double paper_height, const double *matrix, const double *source_clip, char *error);
// The AppKit result is read only; corrected_path is its private sibling copy.
// Finish consumes writer on success or failure. Drop releases an unfinished one.
API int lf_print_source_pdf_finish(void *writer, const char *system_result_path,
    const char *corrected_path, char *error);
API void lf_print_source_pdf_drop(void *writer);
API void *lf_image_pdf_begin(const char *path, char *error);
API int lf_image_pdf_add(void *writer, const unsigned char *data, size_t size, float width, float height, char *error);
// Always releases the writer; finish=0 aborts without finalizing the file.
API int lf_image_pdf_end(void *writer, int finish, char *error);
API int lf_content_bounds_at(void *document, int chapter, int page, float *bounds, void *cookie, char *error);
// UTF-8 text and UTF-16 match ranges with rectangles as JSON.
// flags: 1 = case sensitive, 2 = whole word, 4 = backwards.
// after is the prior hit's UTF-16 start: forward resumes at its real end;
// backward bounds the next anchor's end by that start (Sumatra TextSearch).
// -1 means no cursor (after) or no limit (maximum).
API char *lf_search_options_at(void *document, int chapter, int page, const char *needle, int flags, int64_t after, int64_t maximum, int (*cancelled)(void), char *error);
// Markdown-only document search. flags retain bits 1/2/4 above; bit 8 counts
// from the document start; bit 16 includes the source cursor's occurrence.
// The optional cursor is a source anchor from a prior result. allowed_bits is
// a bitset of zero-based physical pages. One JSON match
// may contain fragments on several pages. maximum is the caller's result budget;
// nonpositive budgets return no matches.
API char *lf_markdown_document_search(void *document, const char *needle, int flags,
    int start_page, uint32_t after_node, uint32_t after_offset, uint32_t after_part,
    int64_t maximum, const uint8_t *allowed_bits, size_t allowed_bytes,
    int (*cancelled)(void), char *error);

// HTML/Markdown source anchors are session-local flow-node identities. Null JSON
// means no visible source glyph; PDF and other handlers do not expose anchors.
API char *lf_html_page_anchor_at(void *document, int chapter, int page, float x, float y, char *error);
API char *lf_html_anchor_position(void *document, int chapter, uint32_t node, uint32_t byte_offset, uint32_t part, char *error);
API char *lf_select_anchors_at(void *document, int chapter, int page,
    uint32_t start_node, uint32_t start_offset, uint32_t start_part,
    uint32_t end_node, uint32_t end_offset, uint32_t end_part, char *error);
API char *lf_html_source_selection_text(void *document,
    const uint32_t *nodes, const uint32_t *offsets, const uint32_t *parts,
    const int32_t *unicode, int count, char *error);

// JSON is the UTF-8 boundary shared by the on-demand engines and Swift.
// Allocation errors are reported by the exported function, never as partial JSON.
typedef struct { char *data; size_t len, cap; int failed; } SumraJSON;
static void lf_json_append(SumraJSON *j, const char *s, size_t n) {
    if (j->failed) return;
    if (n > SIZE_MAX - j->len - 1) { j->failed = 1; return; }
    size_t needed = j->len + n + 1;
    if (needed > j->cap) {
        size_t cap = j->cap ? j->cap : 256;
        while (cap < needed) { if (cap > SIZE_MAX / 2) { cap = needed; break; } cap *= 2; }
        char *data = realloc(j->data, cap);
        if (!data) { j->failed = 1; return; }
        j->data = data; j->cap = cap;
    }
    memcpy(j->data + j->len, s, n); j->len += n; j->data[j->len] = 0;
}
static void lf_json(SumraJSON *j, const char *s) { lf_json_append(j, s, strlen(s)); }
static void lf_json_number(SumraJSON *j, double n) {
    char value[64];
    if (!isfinite(n)) { lf_json(j, "null"); return; }
    snprintf(value, sizeof(value), "%.9g", n); lf_json(j, value);
}
static void lf_json_string(SumraJSON *j, const char *s) {
    lf_json(j, "\"");
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; ++p) {
        if (*p == '"' || *p == '\\') { char v[] = {'\\', (char)*p}; lf_json_append(j, v, 2); }
        else if (*p < 32) { char v[7]; snprintf(v, sizeof(v), "\\u%04x", *p); lf_json(j, v); }
        else lf_json_append(j, (const char *)p, 1);
    }
    lf_json(j, "\"");
}
static void lf_json_rect(SumraJSON *j, double x, double y, double w, double h) {
    lf_json(j, "["); lf_json_number(j, x); lf_json(j, ","); lf_json_number(j, y);
    lf_json(j, ","); lf_json_number(j, w); lf_json(j, ","); lf_json_number(j, h); lf_json(j, "]");
}
static char *lf_json_finish(SumraJSON *j, char *error) {
    if (!j->failed) return j->data;
    free(j->data); snprintf(error, 512, "Cannot allocate document metadata"); return NULL;
}
