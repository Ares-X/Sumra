// Physical-page phrase search must count a span once and retain every page's ink.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>

API void lf_close(SumraMuPDFDocument *);
API char *lf_text_at(SumraMuPDFDocument *, int, int, char *);
API int lf_chapter_pages(SumraMuPDFDocument *, int, char *);
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
static void finite_han_parity(const char *path) {
    struct Case { const char *body, *query; int hits; } cases[] = {
        {"<p>甲丁乙甲丙丁</p>", "甲乙丙", 0},
        {"<p>甲乙丙丁</p>", "甲乙丙丁", 1},
        {"<p>甲乙丙丁戊己庚辛</p>", "甲乙丙丁戊己庚辛", 1},
        {"<p>甲乙甲乙甲丙</p>", "甲乙甲丙", 1},
        {"<p>甲<span>乙</span>丙</p>", "甲乙丙", 1},
        {"<p>甲甲乙乙丙</p>", "甲甲乙乙丙", 1},
        {"<p>甲神乙</p>", "甲神乙", 1},
        {"<p>甲<span style='display:none'>丁</span>乙丙</p>", "甲乙丙", 1},
        {"<p>甲<span style='font-size:0'>丁</span>乙</p><p>丙</p>", "甲乙丙", 0},
        {"<p dir='rtl'>甲乙丙</p><p>丁</p>", "甲乙丙丁", -1},
        {"<p>甲אבג乙</p><p>丙</p>", "甲乙丙", -1},
        {"<p>甲乙甲丙</p><p>乙甲乙甲丙</p>", "甲乙甲丙", 2}
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(*cases); ++i) {
        SumraMuPDFDocument *fast = open_body(path, cases[i].body), *reference = open_body(path, cases[i].body);
        char error[512] = {0};
        const char *css = "@page{margin:0}body{margin:0}p{margin:0;font-family:monospace !important}";
        check(lf_relayout_css(fast, 80, 80, 40, css, 1, error) == 1, error);
        check(lf_relayout_css(reference, 80, 80, 40, css, 1, error) == 1, error);
        int pages = lf_chapter_pages(fast, 0, error);
        check(pages == lf_chapter_pages(reference, 0, error), "finite Han candidate page counts");
        if (i == 2) check(pages > 1, "long finite Han fixture must exercise physical seams");
        for (int flags = 0; flags < 8; ++flags) {
            int count = 0;
            for (int page = 0; page < pages; ++page) {
                lf_drop_render_page(fast);
                // Pre-extracted owner glyphs bypass the candidate in the same
                // physical-window API, retaining its complete seam behavior.
                char *text = lf_text_at(reference, 0, page, error); check(text != NULL, error); free(text);
                char *a = find(fast, cases[i].query, page, flags, -1, -1);
                char *b = find(reference, cases[i].query, page, flags, -1, -1);
                if (!(a && b && !strcmp(a, b))) fprintf(stderr, "finite case=%zu page=%d flags=%d\n", i, page, flags);
                check(a && b && !strcmp(a, b), "finite ordered candidate must preserve exact glyph-window JSON");
                count += occurrences(b, "\"start\":");
                if (i == 0) check(fast->text_page == NULL, "unrelated Han must reject a common-first-rune page before shaping");
                free(a); free(b);
            }
            if (!flags && cases[i].hits >= 0) {
                if (count != cases[i].hits) fprintf(stderr, "finite case=%zu hits=%d expected=%d\n", i, count, cases[i].hits);
                check(count == cases[i].hits, "finite fixture must exercise its required real glyph hits");
            }
        }
        lf_close(fast); lf_close(reference);
    }
}

static void *walking_cookie;
static int candidate_boundaries;
static int abort_finite_candidate(void) {
    if (++candidate_boundaries == 2) lf_render_cookie_abort(walking_cookie);
    return 0;
}
static void finite_candidate_cancellation(const char *path) {
    SumraMuPDFDocument *document = open_body(path, "<p>甲<span>丁</span>乙甲<span>丁</span>乙</p>");
    char error[512] = {0};
    walking_cookie = lf_render_cookie_new(); candidate_boundaries = 0;
    char *result = lf_search_pages_at(document, 0, 0, "甲乙", 0, -1, -1, -1,
        abort_finite_candidate, walking_cookie, error);
    check(!result && strstr(error, "Search cancelled"), "finite candidate must retain the cancellation cause and return no partial JSON");
    check(candidate_boundaries == 2 && document->text_page == NULL, "finite candidate must stop after an in-walk abort before glyph extraction");
    free(result); lf_render_cookie_drop(walking_cookie);
    walking_cookie = lf_render_cookie_new();
    result = lf_search_pages_at(document, 0, 0, "甲丁", 0, -1, -1, -1, NULL, walking_cookie, error);
    check(result && occurrences(result, "\"start\":") == 2, "fresh finite candidate request must recover real glyph hits after cancellation");
    free(result); lf_render_cookie_drop(walking_cookie); walking_cookie = NULL;
    lf_close(document);
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
    free(hit); lf_close(document);
    finite_han_parity(path);
    finite_candidate_cancellation(path);
    unlink(path);
    printf("cross-page phrase search: failures=%d\n", failures);
    return failures ? 1 : 0;
}
