// Natural EPUB/HTML candidates are necessary projections; glyph search is truth.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>
API void lf_close(SumraMuPDFDocument *);
API char *lf_text_at(SumraMuPDFDocument *, int, int, char *);
API int lf_relayout_css(SumraMuPDFDocument *, float, float, float, const char *, int, char *);
static int failures;
static void check(int ok, const char *message) { if (!ok) { fprintf(stderr, "FAIL: %s\n", message); ++failures; } }
static SumraMuPDFDocument *open_html(const char *path) {
    char error[512] = {0}; int password = 0;
    SumraMuPDFDocument *d = lf_open_classified_deferred(path, NULL, &password, error, 0);
    check(d != NULL, error);
    if (d) check(lf_relayout_css(d, 320, 0, 17, "@page{margin:0}", 1, error) == 1, error);
    return d;
}
int main(void) {
    // expected_hit: zero means parity-only, -1 requires an exact reference
    // miss, positive values require that many real glyph hits (flags=0).
    struct Case { const char *body, *query; int skip, expected_hit; } cases[] = {
        {"<p>甲乙丙</p>", "甲丙乙", 1},
        {"<p>甲<span>乙</span>丙丁</p>", "甲乙丙丁", 0},
        {"<p>甲<span style='visibility:hidden'>丙</span>乙</p>", "甲乙", 0},
        {"<p>甲<span style='color:transparent'>丙</span>乙</p>", "甲乙", 0},
        {"<p>甲<span style='display:none'>丙</span>乙</p>", "甲乙", 0},
        {"<p>甲<span style='font-size:0'>丙</span>乙</p>", "甲乙", 0},
        {"<div style='position:absolute;top:-10000px'>丙</div><p>甲乙</p>", "甲乙", 0},
        {"<p style='margin-top:-100px'>丙</p><p>甲乙</p>", "甲乙", 0},
        {"<div style='position:absolute;left:0;top:0'>甲乙</div><div style='position:absolute;left:1em;top:0'>乙丙</div><div style='height:100px'></div>", "甲乙丙", 0},
        {"<p>甲乙乙丙</p>", "甲乙丙", 0},
        {"<p>甲神乙</p>", "甲神乙", 0},
        {"<style>p:before{content:'甲乙'}</style><p>丙丁</p>", "甲乙丙丁", 0},
        {"<ol><li>甲乙</li><li>丙丁</li></ol>", "甲乙丙丁", 0},
        {"<p dir='rtl'>甲乙丙</p>", "甲丙乙", 0},
        {"<p>甲乙אבג丙丁</p>", "甲乙丙丁", 0},
        {"<table><tr><td>甲乙</td><td>丙丁</td></tr></table>", "甲乙丙丁", 0},
        {"<p>甲乙丙</p><p>丁甲乙</p>", "丙丁甲", 0},
        {"<p>甲 乙-丙 丁</p>", "甲乙丙丁", 0},
        // These literal paint cases are exact glyph-reference misses. Require
        // their zero counts, then separately require the real-hit cases below.
        {"<p>甲<span style='font-size:0'>丙</span>乙丙</p>", "甲乙丙", 0, -1},
        {"<p>甲<span style='visibility:hidden'>丙</span>乙丙</p>", "甲乙丙", 0, -1},
        {"<p>甲<span style='color:transparent'>丙</span>乙丙</p>", "甲乙丙", 0, -1},
        {"<p>甲<span style='display:none'>丙</span>乙丙</p>", "甲乙丙", 0, 1},
        {"<p>甲<span style='visibility:hidden;font-size:0'>丙</span>乙丙</p>", "甲乙丙", 0, -1},
        {"<p>甲<span style='color:transparent;font-size:0'>丙</span>乙丙</p>", "甲乙丙", 0, -1},
        {"<div style='position:absolute;left:0;top:0'>甲</div><div style='position:absolute;left:1em;top:-10000px'>丙</div><div style='position:absolute;left:1em;top:0'>乙丙</div><div style='height:100px'></div>", "甲乙丙", 0, 1},
        {"<div style='position:absolute;left:0;top:0'>甲乙</div><div style='position:absolute;left:1em;top:0'>乙丙丁</div><div style='height:100px'></div>", "甲乙丙丁", 0, 1}
    };
    char path[] = "/private/tmp/Sumra-natural-phrase-XXXXXX.xhtml";
    int fd = mkstemps(path, 6); if (fd < 0) return 2; close(fd);
    char error[512] = {0};
    for (size_t i = 0; i < sizeof(cases)/sizeof(*cases); ++i) {
        FILE *f = fopen(path, "w"); fprintf(f, "<html><body>%s</body></html>", cases[i].body); fclose(f);
        for (int flags = 0; flags < 8; ++flags) {
            SumraMuPDFDocument *fast = open_html(path), *reference = open_html(path);
            char *text = lf_text_at(reference, 0, 0, error); check(text != NULL, error); free(text);
            char *a = lf_search_options_at(fast, 0, 0, cases[i].query, flags, -1, -1, NULL, error);
            char *b = lf_search_options_at(reference, 0, 0, cases[i].query, flags, -1, -1, NULL, error);
            if (!(a && b && !strcmp(a,b))) { fprintf(stderr, "case=%zu flags=%d\n", i, flags); check(0, "necessary projection must retain exact glyph JSON"); }
            if (cases[i].expected_hit && flags == 0) {
                int count = 0; const char *at = b;
                while (at && (at = strstr(at, "\"start\":"))) { ++count; ++at; }
                int expected = cases[i].expected_hit < 0 ? 0 : cases[i].expected_hit;
                if (count != expected) fprintf(stderr, "case=%zu reference_hits=%d expected=%d\n", i, count, expected);
                check(count == expected, "paint eligibility fixture must exercise its expected real glyph hit count");
            }
            if (i == 8 && flags == 0) check(b && !strstr(b, "\"matches\":[]"), "overprinted repeated CJK must exercise a real joined glyph hit");
            if (cases[i].skip) check(fast->text_page == NULL, "ordered negative must skip whole natural glyph extraction");
            free(a); free(b); lf_close(fast); lf_close(reference);
        }
    }
    // Force a real match across the projected stream's 4,096-character chunks.
    FILE *f = fopen(path, "w"); fputs("<html><body><p>", f);
    for (int i = 0; i < 4095; ++i) fputs(i & 1 ? "乙" : "甲", f);
    fputs("乙丙丁甲</p></body></html>", f); fclose(f);
    SumraMuPDFDocument *fast = open_html(path), *reference = open_html(path);
    char *text = lf_text_at(reference, 0, 0, error); check(text != NULL, error); free(text);
    char *a = lf_search_options_at(fast, 0, 0, "乙丙丁甲", 0, -1, -1, NULL, error);
    char *b = lf_search_options_at(reference, 0, 0, "乙丙丁甲", 0, -1, -1, NULL, error);
    check(a && b && !strcmp(a,b) && !strstr(b, "\"matches\":[]"), "projection chunks must preserve boundary-spanning glyph matches");
    free(a); free(b); lf_close(fast); lf_close(reference); unlink(path);
    printf("natural phrase projection: %zu fixtures x 8 options/directions + chunk boundary; failures=%d\n", sizeof(cases)/sizeof(*cases), failures);
    return failures ? 1 : 0;
}
