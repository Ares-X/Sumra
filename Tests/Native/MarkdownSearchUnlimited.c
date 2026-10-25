// Unlimited Markdown search grows with actual hits and preserves real results.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>
API void lf_close(SumraMuPDFDocument *);
API char *lf_text_at(SumraMuPDFDocument *, int, int, char *);
API int lf_relayout_css(SumraMuPDFDocument *, float, float, float, const char *, int, char *);
static int failures;
static void check(int ok, const char *why) { if (!ok) { fprintf(stderr, "FAIL: %s\n", why); ++failures; } }
static int hits(const char *json) {
    int count = 0;
    while (json && (json = strstr(json, "\"source\":["))) { ++count; ++json; }
    return count;
}
static char *find(SumraMuPDFDocument *d, int64_t maximum) {
    char error[512] = {0};
    char *json = lf_markdown_document_search(d, "glass", 8, 0, 0, 0, 0, 0, 0, maximum, NULL, 0, NULL, error);
    check(json != NULL, error); return json;
}
static int cancellation_requested;
static int cancelled(void) { return cancellation_requested; }
static void incremental_parity(SumraMuPDFDocument *d, const char *expected) {
    char error[512] = {0};
    void *session = lf_markdown_search_begin(d, "glass", 0, NULL, 0, error);
    check(session != NULL, error); if (!session) return;
    fz_buffer *matches = fz_new_buffer(d->ctx, 1024);
    size_t steps = 0; int count = 0, complete = 0;
    while (!complete) {
        char *json = lf_markdown_search_step(session, 8192, NULL, error);
        check(json != NULL, error); if (!json) break;
        const char *begin = strstr(json, "\"matches\":[");
        begin = begin ? begin + strlen("\"matches\":[") : NULL;
        const char *end = begin ? strstr(begin, "],\"complete\":") : NULL;
        check(begin && end, "incremental result has its precise match batch");
        if (begin && end && end != begin) {
            if (count) fz_append_byte(d->ctx, matches, ',');
            fz_append_data(d->ctx, matches, begin, (size_t)(end - begin));
            count += hits(json);
        }
        complete = strstr(json, "\"complete\":true") != NULL;
        free(json); ++steps;
        if (steps == 2) {
            // Real reading work can run between scan steps. The cursor must
            // retain its current tree even after unrelated page/store eviction.
            char *text = lf_text_at(d, 0, 0, error); check(text != NULL, error); free(text);
            lf_drop_render_page(d); fz_empty_store(d->ctx);
        }
    }
    fz_terminate_buffer(d->ctx, matches);
    const char *begin = strstr(expected, "\"matches\":[") + strlen("\"matches\":[");
    const char *end = strstr(begin, "],\"chapterPages\":");
    size_t bytes = end ? (size_t)(end - begin) : 0;
    check(complete && steps > 1 && count == 1507, "incremental full scan must yield and publish every match");
    check(end && strlen(fz_string_from_buffer(d->ctx, matches)) == bytes && !memcmp(begin, fz_string_from_buffer(d->ctx, matches), bytes),
        "incremental publication must preserve complete synchronous source/geometry JSON in order");
    fz_drop_buffer(d->ctx, matches); lf_markdown_search_drop(session);

    session = lf_markdown_search_begin(d, "glass", 0, NULL, 0, error);
    check(session != NULL, error);
    char *part = lf_markdown_search_step(session, 1, cancelled, error);
    check(part != NULL && !strstr(part, "\"complete\":true"), "one source unit must yield inside the first paragraph"); free(part);
    cancellation_requested = 1;
    part = lf_markdown_search_step(session, 8192, cancelled, error);
    check(!part && strstr(error, "Search cancelled"), "cancellation between actual work steps must retain its cause and return no partial batch");
    free(part); lf_markdown_search_drop(session); cancellation_requested = 0;
}
int main(void) {
    char path[] = "/private/tmp/Sumra-unlimited-search-XXXXXX.md";
    int descriptor = mkstemps(path, 3); if (descriptor < 0) return 2;
    FILE *file = fdopen(descriptor, "w");
    for (int i = 0; i < 1507; ++i) fprintf(file, "glass paragraph %d\n\n", i);
    fclose(file);
    char error[512] = {0}; int password = 0;
    SumraMuPDFDocument *d = lf_open_classified_deferred(path, NULL, &password, error, 0);
    check(d != NULL, error); if (!d) { unlink(path); return 1; }
    check(lf_relayout_css(d, 320, 0, 17, "@page{margin:0}", 1, error) == 1, error);
    // NativeFile prepares its location/chapter table before calling the
    // synchronous source-search API; apply the same lazy layout boundary.
    check(fz_count_chapters(d->ctx, d->doc) > 0, "prepare native Markdown chapters");
    char *bounded = find(d, 1507), *all = find(d, -1);
    check(hits(bounded) == 1507 && hits(all) == 1507, "full count must exceed the old UI sentinel without losing any occurrence");
    check(bounded && all && !strcmp(bounded, all), "unlimited matches must preserve complete bounded-reference source/geometry JSON");
    incremental_parity(d, all);
    free(bounded); free(all);
    char *few = find(d, 3); check(hits(few) == 3, "an explicit caller budget remains effective"); free(few);
    char *huge = find(d, INT64_MAX); check(hits(huge) == 1507, "a large explicit budget must allocate only actual hits"); free(huge);
    char *none = find(d, 0); check(hits(none) == 0, "zero budget remains empty"); free(none);
    lf_close(d); unlink(path);
    printf("unlimited Markdown search: 1507 complete source/geometry records; failures=%d\n", failures);
    return failures ? 1 : 0;
}
