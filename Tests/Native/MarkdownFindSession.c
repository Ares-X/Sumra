// Incremental interactive find retains the synchronous source/seek semantics.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>
API void lf_close(SumraMuPDFDocument *);
API char *lf_text_at(SumraMuPDFDocument *, int, int, char *);
API int lf_relayout_css(SumraMuPDFDocument *, float, float, float, const char *, int, char *);
static int failures;
static void check(int ok, const char *why) { if (!ok) { fprintf(stderr, "FAIL: %s\n", why); ++failures; } }
typedef struct { uint32_t node, offset, part; int chapter; } anchor;
static anchor first_source(const char *json) {
    anchor a = {0}; const char *p = strstr(json, "\"source\":[");
    if (p) sscanf(p + strlen("\"source\":["), "%u,%u,%u,%d", &a.node, &a.offset, &a.part, &a.chapter);
    return a;
}
static int matches(const char *json) { int n = 0; while (json && (json = strstr(json, "\"source\":["))) { ++n; ++json; } return n; }
static char *reference(SumraMuPDFDocument *d, const char *query, int flags, int chapter, int page, anchor after,
    int64_t maximum, const uint8_t *bits, size_t bytes) {
    char error[512] = {0};
    char *json = lf_markdown_document_search(d, query, flags, chapter, page, after.chapter,
        after.node, after.offset, after.part, maximum, bits, bytes, NULL, error);
    check(json != NULL, error); return json;
}
static void parity(SumraMuPDFDocument *d, const char *query, int flags, int chapter, int page, anchor after,
    int64_t maximum, const uint8_t *bits, size_t bytes, size_t budget) {
    char *expected = reference(d, query, flags, chapter, page, after, maximum, bits, bytes);
    char error[512] = {0}; uint8_t *mask = NULL;
    if (bits) { mask = malloc(bytes ? bytes : 1); memcpy(mask, bits, bytes); }
    void *session = lf_markdown_find_begin(d, query, flags, chapter, page, after.chapter,
        after.node, after.offset, after.part, maximum, mask, bytes, error);
    if (mask) { memset(mask, 0, bytes); free(mask); }
    check(session != NULL, error); if (!session) { free(expected); return; }
    fz_buffer *body = fz_new_buffer(d->ctx, 1024);
    int complete = 0, count = 0; size_t steps = 0;
    while (!complete) {
        char *json = lf_markdown_search_step(session, budget, NULL, error);
        check(json != NULL, error); if (!json) break;
        const char *begin = strstr(json, "\"matches\":["); begin = begin ? begin + strlen("\"matches\":[") : NULL;
        const char *end = begin ? strstr(begin, "],\"complete\":") : NULL;
        check(begin && end, "interactive session result shape");
        if (begin && end && end > begin) {
            if (count) fz_append_byte(d->ctx, body, ',');
            fz_append_data(d->ctx, body, begin, (size_t)(end - begin)); count += matches(json);
        }
        complete = strstr(json, "\"complete\":true") != NULL;
        free(json); ++steps;
        if (steps == 16 && !complete) {
            char *text = lf_text_at(d, chapter, page, error); check(text != NULL, error); free(text);
            lf_drop_render_page(d); fz_empty_store(d->ctx);
        }
    }
    fz_terminate_buffer(d->ctx, body);
    const char *begin = expected ? strstr(expected, "\"matches\":[") : NULL;
    begin = begin ? begin + strlen("\"matches\":[") : NULL;
    const char *end = begin ? strstr(begin, "],\"chapterPages\":") : NULL;
    if (begin && !end && !strcmp(begin, "]}")) end = begin;
    const char *actual = fz_string_from_buffer(d->ctx, body);
    if (!(complete && begin && end && strlen(actual) == (size_t)(end-begin) && !memcmp(actual, begin, (size_t)(end-begin)))) {
        fprintf(stderr, "find parity query=%s flags=%d chapter=%d page=%d budget=%zu steps=%zu actual=%d expected=%d\n", query, flags, chapter, page, budget, steps, count, matches(expected));
        check(0, "interactive sessions must retain exact synchronous ordered source/geometry JSON");
    }
    lf_markdown_search_drop(session); fz_drop_buffer(d->ctx, body); free(expected);
}
static int cancel_requested;
static int cancelled(void) { return cancel_requested; }
int main(void) {
    char path[] = "/private/tmp/Sumra-find-session-XXXXXX.md";
    int fd = mkstemps(path, 3); if (fd < 0) return 2; FILE *f = fdopen(fd, "w");
    for (int ch = 0; ch < 3; ++ch) {
        fprintf(f, "# %s\n\nneedle café ﬁle Straße beginning.\n\n", ch == 0 ? "First" : ch == 1 ? "Middle" : "Last");
        for (int p = 0; p < 150; ++p) fprintf(f, "Ordinary paragraph %d with words for a paginated seek.\n\n", p);
        fputs("needle later in the chapter.\n\n", f);
        for (int p = 0; p < 20; ++p) fputs("Trailing text after the final occurrence.\n\n", f);
    }
    fputs("documentend\n", f); fclose(f);
    char error[512] = {0}; int password = 0;
    SumraMuPDFDocument *d = lf_open_classified_deferred(path, NULL, &password, error, 0);
    check(d != NULL, error); if (!d) { unlink(path); return 1; }
    const float heights[] = {180, 0};
    for (size_t mode = 0; mode < 2; ++mode) {
        check(lf_relayout_css(d, 260, heights[mode], 17, "@page{margin:0}", 1, error) == 1, error);
        int chapters = fz_count_chapters(d->ctx, d->doc); check(chapters == 3, "fixture has three lazy source sections");
        int final_page = fz_count_chapter_pages(d->ctx, d->doc, chapters - 1) - 1;
        char *first = reference(d, "needle", 0, 0, 0, (anchor){0}, 1, NULL, 0);
        anchor after = first_source(first); check(after.node != 0, "reference exposes an actual source cursor"); free(first);
        for (int flags = 0; flags < 8; ++flags) {
            parity(d, "needle", flags, 0, 0, (anchor){0}, 1, NULL, 0, 7);
            parity(d, "needle", flags, chapters - 1, final_page, (anchor){0}, 1, NULL, 0, 7);
            parity(d, "needle", flags, after.chapter, 0, after, 1, NULL, 0, 7);
            parity(d, "needle", flags | 16, after.chapter, 0, after, 1, NULL, 0, 7);
        }
        parity(d, "needle", 0, 0, 0, after, 3, NULL, 0, 8192);
        parity(d, "needle", 4, chapters - 1, final_page, (anchor){0}, 2, NULL, 0, 8192);
        parity(d, "NEEDLE", 1, chapters - 1, final_page, (anchor){0}, 1, NULL, 0, 8192);
        parity(d, "not-present", 0, chapters - 1, final_page, (anchor){0}, 1, NULL, 0, 7);
        parity(d, "documentend First", 0, chapters - 1, final_page, (anchor){0}, 1, NULL, 0, 8192);
        const char *normalized[] = {"cafe", "file", "ss"};
        for (size_t i = 0; i < 3; ++i) parity(d, normalized[i], 0, 0, 0, (anchor){0}, 1, NULL, 0, 8192);
        int pages = fz_count_pages(d->ctx, d->doc); size_t bytes = ((size_t)pages + 7) / 8;
        uint8_t *bits = calloc(bytes, 1); bits[(pages-1)/8] |= 1u << ((pages-1)%8);
        parity(d, "needle", 0, 0, 0, (anchor){0}, 1, bits, bytes, 8192);
        parity(d, "needle", 4, chapters - 1, final_page, (anchor){0}, 1, bits, bytes, 8192);
        free(bits); uint8_t empty = 0;
        parity(d, "needle", 0, 0, 0, (anchor){0}, 1, &empty, 0, 8192);
        parity(d, "needle", 0, 0, 0, (anchor){0}, 0, NULL, 0, 8192);
    }
    void *session = lf_markdown_find_begin(d, "not-present", 0, 0, 0, 0, 0, 0, 0, 1, NULL, 0, error);
    for (int i = 0; i < 128; ++i) { char *part = lf_markdown_search_step(session, 1, cancelled, error); check(part != NULL, error); free(part); }
    cancel_requested = 1; char *part = lf_markdown_search_step(session, 8192, cancelled, error);
    check(!part && strstr(error, "Search cancelled"), "interactive cancellation after actual source work returns no stale batch"); free(part);
    lf_markdown_search_drop(session); cancel_requested = 0;
    parity(d, "needle", 0, 0, 0, (anchor){0}, 1, NULL, 0, 8192);
    lf_close(d); unlink(path);
    printf("interactive Markdown session parity, ranges, wrap, seek and cancellation: failures=%d\n", failures);
    return failures ? 1 : 0;
}
