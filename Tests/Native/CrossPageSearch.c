// Physical-page phrase search must count a span once and retain every page's ink.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>

API void lf_close(SumraMuPDFDocument *);
API int lf_relayout_css(SumraMuPDFDocument *, float, float, float, const char *, int, char *);
static int failures;
static void check(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); ++failures; }
}
static int occurrences(const char *text, const char *needle) {
    int count = 0;
    while (text && (text = strstr(text, needle))) { ++count; text += strlen(needle); }
    return count;
}
static SumraMuPDFDocument *open_body(const char *path, const char *body) {
    FILE *file = fopen(path, "w");
    fprintf(file, "<html><head><style>p{margin:0;page-break-after:always}</style></head><body>%s</body></html>", body);
    fclose(file);
    char error[512] = {0}; int password = 0;
    SumraMuPDFDocument *document = lf_open_classified_deferred(path, NULL, &password, error, 0);
    check(document != NULL, error);
    if (document) check(lf_relayout_css(document, 240, 100, 17, "@page{margin:0}", 1, error) > 0, error);
    return document;
}
static char *find(SumraMuPDFDocument *document, const char *query, int page, int flags, int64_t after, int64_t last) {
    char error[512] = {0};
    char *result = lf_search_pages_at(document, 0, page, query, flags, after, -1, last, NULL, NULL, error);
    check(result != NULL, error);
    return result;
}
int main(void) {
    char path[] = "/private/tmp/Sumra-cross-page-XXXXXX.xhtml";
    int descriptor = mkstemps(path, 6); if (descriptor < 0) return 2; close(descriptor);
    SumraMuPDFDocument *document = open_body(path, "<p>alpha</p><p>beta</p><p>gamma</p><p>delta</p>");
    char *hit = find(document, "alpha beta gamma delta", 0, 0, -1, -1);
    check(occurrences(hit, "\"start\":") == 1, "four pages must form one logical hit");
    check(occurrences(hit, "\"page\":") == 4, "all four pages must retain real glyph rectangles");
    char *reverse = find(document, "alpha beta gamma delta", 0, 4, -1, -1);
    check(reverse && hit && !strcmp(reverse, hit), "backward search must return the same span");
    char *hole = find(document, "alpha beta gamma delta", 0, 0, -1, 1);
    check(occurrences(hole, "\"start\":") == 0, "excluded physical pages cannot be bridged");
    free(hole); free(reverse); free(hit); lf_close(document);

    document = open_body(path, "<p>普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通</p>");
    const char *cjk = "普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通普通";
    hit = find(document, cjk, 0, 0, -1, -1);
    check(occurrences(hit, "\"start\":") == 1 && occurrences(hit, "\"page\":") > 1,
        "Chinese without spaces must span a physical page boundary");
    free(hit); lf_close(document);

    const char *bodies[] = {"<p>inter-</p><p>national</p>", "<p>inter&#xad;national</p>",
        "<p>inter-<br/>national</p>"};
    for (size_t i = 0; i < sizeof(bodies)/sizeof(*bodies); ++i) {
        document = open_body(path, bodies[i]); hit = find(document, "international", 0, 0, -1, -1);
        check(occurrences(hit, "\"start\":") == 1, "line/page hyphens and soft hyphens must join a word");
        free(hit); lf_close(document);
    }
    document = open_body(path, "<p>fi é alpha</p>");
    const char *normalized[] = {"ﬁ", "e\xcc\x81", "\xcc\x81" "alpha"};
    for (int i = 0; i < 3; ++i) {
        hit = find(document, normalized[i], 0, i == 1 ? 1 : 0, -1, -1);
        check(occurrences(hit, "\"start\":") == 1, "candidate must retain ligatures, canonical marks and leading ignored marks");
        free(hit);
    }
    lf_close(document);
    document = open_body(path, "<p>unrelated text</p>");
    hit = find(document, "缺失跨页", 0, 0, -1, -1);
    check(occurrences(hit, "\"start\":") == 0 && document->text_page == NULL,
        "a necessary owner-page rune must reject before glyph extraction");
    free(hit); lf_close(document);

    document = open_body(path, "<p>well-known</p>");
    hit = find(document, "wellknown", 0, 0, -1, -1);
    check(occurrences(hit, "\"start\":") == 0, "an authored inline hyphen must remain significant");
    free(hit); lf_close(document); unlink(path);
    printf("cross-page phrase search: failures=%d\n", failures);
    return failures ? 1 : 0;
}
