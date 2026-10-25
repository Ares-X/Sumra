// Isolated native search regression: negative chapters must not extract glyphs.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
API char *lf_text_at(SumraMuPDFDocument *, int, int, char *);
API int lf_relayout_css(SumraMuPDFDocument *, float, float, float, const char *, int, char *);
API void lf_close(SumraMuPDFDocument *);
API int lf_chapter_pages(SumraMuPDFDocument *, int, char *);
static int failures;
#define FLOW16 "groupword groupword groupword groupword groupword groupword groupword groupword groupword groupword groupword groupword groupword groupword groupword groupword "
#define FLOW256 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16 FLOW16
static void check(int ok, const char *why) { if (!ok) { fprintf(stderr, "FAIL: %s\n", why); ++failures; } }
static SumraMuPDFDocument *open_book(const char *path) {
    char error[512] = {0}; int password = 0;
    SumraMuPDFDocument *d = lf_open_classified_deferred(path, NULL, &password, error, 0);
    check(d != NULL, error);
    if (d) check(lf_relayout_css(d, 320, 0, 17, "p.generated:after{content:'customCSS中'}", 1, error) == 1, error);
    return d;
}
static char *search(SumraMuPDFDocument *d, const char *query, int flags, int64_t after) {
    char error[512] = {0};
    char *json = lf_search_options_at(d, 0, 0, query, flags, after, 1, NULL, error);
    check(json != NULL, error); return json;
}

static int cancelled(void) { return 1; }
static void *walking_cookie;
static int visited_boundaries;
static int abort_while_walking(void) {
    if (++visited_boundaries == 10) lf_render_cookie_abort(walking_cookie);
    return 0;
}
static void write_file(const char *directory, const char *name, const char *text) {
    char path[PATH_MAX]; snprintf(path, sizeof path, "%s/%s", directory, name);
    FILE *f = fopen(path, "w"); if (!f) abort(); fputs(text, f); fclose(f);
}
static const char *fixture(char *directory) {
    if (!mkdtemp(directory)) abort();
    char meta[PATH_MAX]; snprintf(meta, sizeof meta, "%s/META-INF", directory); mkdir(meta, 0700);
    write_file(directory, "mimetype", "application/epub+zip");
    write_file(directory, "META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>");
    write_file(directory, "book.opf", "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='one' href='one.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='one'/></spine></package>");
    write_file(directory, "one.xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>p.generated:before{content:'before CONTENT 甲'} body{font-family:serif}</style></head><body><p>马<span>尾</span>拂尘</p><p>马尾 <em>拂尘</em></p><p class='generated'>inline café CAFÉ ß ﬁ exact</p><ol><li>list item</li></ol><ul><li>bullet</li></ul><p>e&#x301; A&#xad;B</p><p>wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap</p><p>" FLOW256 "indexEND</p><p>bottomEND</p></body></html>");
    static char book[PATH_MAX]; snprintf(book, sizeof book, "%s.epub", directory);
    pid_t child = fork(); if (!child) { execl("/usr/bin/ditto", "ditto", "-c", "-k", directory, book, NULL); _exit(2); }
    int status; waitpid(child, &status, 0); if (status) abort(); return book;
}
static void cleanup_fixture(const char *directory, const char *book) {
    const char *files[] = {"mimetype", "META-INF/container.xml", "book.opf", "one.xhtml"};
    char path[PATH_MAX];
    for (size_t i = 0; i < sizeof(files)/sizeof(*files); ++i) { snprintf(path, sizeof path, "%s/%s", directory, files[i]); unlink(path); }
    snprintf(path, sizeof path, "%s/META-INF", directory); rmdir(path); rmdir(directory); unlink(book);
}

static void finite_page_parity(const char *path) {
    const char *queries[] = {"马尾拂尘", "马尾 拂尘", "before", "CONTENT", "cafe", "ss", "fi", "1. list", "•", "e\xCC\x81", "-", "customCSS中", "groupword", "indexEND", "bottomEND", "不存在的目标"};
    const float heights[] = {180, 360, 0};
    SumraMuPDFDocument *fast = open_book(path), *reference = open_book(path);
    char error[512] = {0};
    for (size_t layout = 0; layout < sizeof(heights)/sizeof(*heights); ++layout) {
        float width = layout == 1 ? 240 : 320, em = layout == 1 ? 19 : 17;
        const char *css = "p.generated:after{content:'customCSS中'} @page{margin:0} sup{vertical-align:super} sub{vertical-align:sub}";
        check(lf_relayout_css(fast, width, heights[layout], em, css, 1, error) == 1, error);
        check(lf_relayout_css(reference, width, heights[layout], em, css, 1, error) == 1, error);
        int pages = lf_chapter_pages(fast, 0, error);
        check(pages == lf_chapter_pages(reference, 0, error), "finite page counts must agree after reflow");
        check(heights[layout] == 0 ? pages == 1 : pages > 1, "fixture must exercise finite and natural canvases");
        for (int page = 0; page < pages; ++page) {
            char *text = lf_text_at(reference, 0, page, error); check(text != NULL, error); free(text);
            for (size_t query = 0; query < sizeof(queries)/sizeof(*queries); ++query) {
                for (int flags = 0; flags < 8; ++flags) {
                    lf_drop_render_page(fast);
                    char *a = lf_search_options_at(fast, 0, page, queries[query], flags, -1, -1, NULL, error);
                    char *b = lf_search_options_at(reference, 0, page, queries[query], flags, -1, -1, NULL, error);
                    check(a && b && !strcmp(a, b), "page candidate/index must preserve exact glyph JSON across finite borders and reflow");
                    free(a); free(b);
                }
            }
        }
    }
    lf_close(fast); lf_close(reference);
}

static void parsed_phrase_parity(const char *directory, const char *path) {
    struct Case { const char *body, *query; int negative; } cases[] = {
        {"<p>甲丁乙甲丙丁</p>", "甲乙丙", 1},
        {"<p>甲乙丙丁戊己庚辛</p>", "甲乙丙丁戊己庚辛"},
        {"<p>甲乙甲乙甲丙</p>", "甲乙甲丙"},
        {"<p>甲<span>乙</span>丙</p>", "甲乙丙"},
        {"<p>甲<span style='visibility:hidden'>丁</span>乙丙</p>", "甲乙丙"},
        {"<p>甲<span style='color:transparent'>丁</span>乙丙</p>", "甲乙丙"},
        {"<p>甲<span style='display:none'>丁</span>乙丙</p>", "甲乙丙"},
        {"<p>甲<span style='font-size:0'>丁</span>乙丙</p>", "甲乙丙"},
        {"<p style='margin-top:-100px'>丁</p><p>甲乙丙</p>", "甲乙丙"},
        {"<div style='position:absolute;top:-10000px'>丁</div><p>甲乙丙</p>", "甲乙丙"},
        {"<p style='height:0'>甲乙丙</p>", "甲乙丙"},
        {"<p>甲<sup>丁</sup>乙丙</p>", "甲乙丙"},
        {"<p dir='rtl'>甲乙丙</p>", "甲丙乙"},
        {"<p>甲乙אבג丙丁</p>", "甲乙丙丁"},
        {"<table><tr><td>甲乙</td><td>丙丁</td></tr></table>", "甲乙丙丁"},
        {"<p>甲神乙</p>", "甲神乙"},
        {"<p>alpha X beta Z</p>", "alpha beta", 1},
        {"<p>glass gap glass</p>", "glass"},
        {"<p>g<span>l</span>ass</p>", "glass"},
        {"<p>fi ﬁ file ﬁle Straße</p>", "file"},
        {"<p>fi ﬁ file ﬁle Straße</p>", "ss"},
        {"<p>SS ß</p>", "ß"},
        {"<p>caf&#x65;&#x301; café</p>", "café"},
        {"<p>alpha-beta</p>", "alphabeta"},
        {"<style>p:before{content:'glass '}</style><p>paragraph</p>", "glass"},
        {"<p>g<span style='font-size:0'>X</span>lass</p>", "glass"},
        {"<p>alpha123 beta124</p>", "alpha124", 1},
        {"<p>甲alpha乙123丙</p>", "alpha乙123"}
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(*cases); ++i) {
        char body[2048];
        snprintf(body, sizeof body, "<html xmlns='http://www.w3.org/1999/xhtml'><body>%s</body></html>", cases[i].body);
        write_file(directory, "one.xhtml", body);
        pid_t child = fork();
        if (!child) { execl("/usr/bin/ditto", "ditto", "-c", "-k", directory, path, NULL); _exit(2); }
        int status; waitpid(child, &status, 0); check(!status, "parsed phrase fixture archive");
        for (int flags = 0; flags < 8; ++flags) {
            SumraMuPDFDocument *fast = open_book(path), *reference = open_book(path);
            char error[512] = {0};
            const char *css = "@page{margin:0}body{margin:0}p{margin:0}";
            check(lf_relayout_css(fast, 120, 100, 30, css, 1, error) == 1, error);
            check(lf_relayout_css(reference, 120, 100, 30, css, 1, error) == 1, error);
            int candidate = lf_search_chapter_candidate(fast, 0, cases[i].query, flags, NULL, NULL, error);
            check(candidate >= 0 && fast->render_page == NULL && fast->text_page == NULL, "parsed phrase check must precede page/glyph loading");
            if (cases[i].negative) {
                if (candidate != 0) fprintf(stderr, "negative parsed case=%zu flags=%d candidate=%d\n", i, flags, candidate);
                check(candidate == 0, "ordered negative chapter must skip pagination");
            }
            int pages = lf_chapter_pages(reference, 0, error);
            for (int page = 0; page < pages; ++page) {
                char *text = lf_text_at(reference, 0, page, error); check(text != NULL, error); free(text);
                char *b = lf_search_pages_at(reference, 0, page, cases[i].query, flags, -1, -1, -1, NULL, NULL, error);
                char *a = candidate ? lf_search_pages_at(fast, 0, page, cases[i].query, flags, -1, -1, -1, NULL, NULL, error)
                    : strdup("{\"text\":\"\",\"matches\":[]}");
                if (!(a && b && !strcmp(a, b))) fprintf(stderr, "parsed case=%zu flags=%d page=%d candidate=%d\n", i, flags, page, candidate);
                check(a && b && !strcmp(a, b), "parsed/finite projection must retain exact glyph-window JSON");
                free(a); free(b);
            }
            lf_close(fast); lf_close(reference);
        }
    }
    // A source-prefix suffix remains a candidate before an adjacent spine
    // chapter supplies the rest; no page loading is required to retain it.
    write_file(directory, "one.xhtml", "<html><body><p>unrelated text 甲乙</p></body></html>");
    pid_t child = fork(); if (!child) { execl("/usr/bin/ditto", "ditto", "-c", "-k", directory, path, NULL); _exit(2); }
    int status; waitpid(child, &status, 0); check(!status, "prefix fixture archive");
    SumraMuPDFDocument *d = open_book(path); char error[512] = {0};
    check(lf_relayout_css(d, 120, 100, 30, "@page{margin:0}", 1, error) == 1, error);
    check(lf_search_chapter_candidate(d, 0, "甲乙丙丁", 0, NULL, NULL, error) == 1 && d->render_page == NULL,
        "a chapter's trailing query prefix cannot reject a spine continuation");
    lf_close(d);
    printf("parsed phrase candidate: %zu fixtures x 8 options/directions + spine prefix; failures=%d\n", sizeof(cases)/sizeof(*cases), failures);
}

int main(int argc, char **argv) {
    char directory[] = "/private/tmp/Sumra-search-candidate-XXXXXX";
    const char *path = argc == 2 ? argv[1] : fixture(directory);
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    fz_search *empty = fz_new_search(ctx, "\xCC\x81", FZ_SEARCH_IGNORE_CASE | FZ_SEARCH_IGNORE_DIACRITICS);
    check(fz_search_forwards(ctx, empty).reason == FZ_SEARCH_COMPLETE, "normalized empty Fitz search must finish without input");
    check(fz_search_backwards(ctx, empty).reason == FZ_SEARCH_COMPLETE, "normalized empty reverse Fitz search must finish without input");
    fz_drop_search(ctx, empty); fz_drop_context(ctx);
    SumraMuPDFDocument *d = open_book(path); if (!d) return 1;
    char chapter_error[512] = {0};
    check(lf_search_chapter_candidate(d, 0, "不存在的目标", 0, NULL, NULL, chapter_error) == 0, "negative parsed chapter candidate");
    check(d->render_page == NULL, "negative candidate must not load/layout a page");
    char *json = search(d, "不存在的目标", 0, -1);
    check(json && strstr(json, "\"matches\":[]"), "negative result");
    check(d->text_page == NULL, "negative chapter must skip full glyph extraction");
    free(json); lf_close(d);
    void *cookie = lf_render_cookie_new(); check(cookie != NULL, "search request cookie");
    const char *queries[] = {"马尾拂尘", "马尾 拂尘", "马尾", "before", "CONTENT", "cafe", "CAFÉ", "ss", "fi", "1.", "•", "甲", "inline", "wrap", "exact", "e\xCC\x81", " ", "-", "\xCC\x81", "customCSS中", "1. list", "不存在的目标"};
    for (size_t i = 0; i < sizeof(queries)/sizeof(*queries); ++i) {
        for (int flags = 0; flags < 8; ++flags) {
            SumraMuPDFDocument *fast = open_book(path), *reference = open_book(path);
            if (!fast || !reference) return 1;
            char error[512] = {0}; char *text = lf_text_at(reference, 0, 0, error);
            check(text != NULL, error); free(text);
            int candidate = lf_search_chapter_candidate(fast, 0, queries[i], flags, NULL, cookie, error);
            check(candidate >= 0, error);
            check(fast->render_page == NULL, "candidate proof must precede page loading");
            char *b = search(reference, queries[i], flags, -1);
            if (b && !strstr(b, "\"matches\":[]")) check(candidate == 1, "prelayout candidate must retain every rendered hit");
            char *a = candidate ? search(fast, queries[i], flags, -1) : strdup("{\"text\":\"\",\"matches\":[]}");
            if (flags == 0 && (i < 15 || i == 19 || i == 20)) check(b && !strstr(b, "\"matches\":[]"), "fixture query must exercise a rendered hit");
            check(a && b && !strcmp(a,b), "semantic precheck must retain exact native search JSON");
            if (i == 18 && !(flags & 1)) check(a && strstr(a, "\"matches\":[]"), "normalized empty needle must return no matches");
            free(a); free(b); lf_close(fast); lf_close(reference);
        }
    }
    d = open_book(path);
    char error[512] = {0};
    check(lf_search_chapter_candidate(d, 0, "newCSS生成", 0, NULL, NULL, error) == 0, "initial CSS candidate absence");
    check(lf_relayout_css(d, 480, 0, 19, "p.generated:after{content:'newCSS生成'}", 1, error) == 1, error);
    check(lf_search_chapter_candidate(d, 0, "newCSS生成", 0, NULL, NULL, error) == 1, "CSS change must purge and regenerate parsed candidates");
    json = search(d, "newCSS生成", 0, -1);
    check(json && !strstr(json, "\"matches\":[]"), "generated candidate must retain rendered hit after CSS change");
    free(json);
    check(lf_relayout_css(d, 320, 0, 17, NULL, 1, error) == 1, error);
    check(lf_search_chapter_candidate(d, 0, "newCSS生成", 0, NULL, NULL, error) == 0, "removed generated CSS text must not survive in the parsed cache");
    check(lf_search_chapter_candidate(d, 0, "不存在的目标", 0, cancelled, NULL, error) == -1 && strstr(error, "Search cancelled"), "prelayout candidate cancellation");
    json = lf_search_options_at(d, 0, 0, "不存在的目标", 0, -1, 1, cancelled, error);
    check(!json && strstr(error, "Search cancelled"), "candidate walk must honor cancellation");
    free(json); lf_close(d);
    d = open_book(path);
    walking_cookie = cookie; visited_boundaries = 0;
    check(lf_search_chapter_candidate(d, 0, "不存在的目标", 0, abort_while_walking, cookie, error) == -1 && strstr(error, "Search cancelled"), "parsed traversal must observe a cookie aborted after entry");
    check(visited_boundaries == 10 && d->render_page == NULL, "parsed traversal must stop at its next cancellation boundary before layout");
    lf_render_cookie_drop(cookie); cookie = lf_render_cookie_new();
    walking_cookie = cookie; visited_boundaries = 0;
    json = lf_search_pages_at(d, 0, 0, "不存在的目标", 0, -1, 1, -1, abort_while_walking, cookie, error);
    check(!json && strstr(error, "Search cancelled"), "natural candidate traversal must observe a cookie aborted after entry"); free(json);
    check(visited_boundaries == 10 && d->text_page == NULL, "natural candidate must stop at its next cancellation boundary without caching glyph text");
    lf_render_cookie_drop(cookie); cookie = lf_render_cookie_new();
    lf_close(d); d = open_book(path);
    lf_render_cookie_abort(cookie);
    check(lf_search_chapter_candidate(d, 0, "不存在的目标", 0, NULL, cookie, error) == -1 && strstr(error, "Search cancelled"), "parsed candidate must read its request cookie");
    check(d->render_page == NULL && d->text_page == NULL, "cancelled candidate must not load or cache glyph text");
    json = lf_search_pages_at(d, 0, 0, "马尾", 0, -1, 1, -1, NULL, cookie, error);
    check(!json, "aborted page-search cookie must return no partial result"); free(json);
    lf_render_cookie_drop(cookie); cookie = lf_render_cookie_new();
    check(lf_search_chapter_candidate(d, 0, "马尾", 0, NULL, cookie, error) == 1, "fresh candidate cookie must recover after cancellation");
    json = lf_search_pages_at(d, 0, 0, "马尾", 0, -1, 1, -1, NULL, cookie, error);
    check(json && !strstr(json, "\"matches\":[]"), "fresh page-search cookie must recover a real match"); free(json);
    check(lf_search_chapter_candidate(d, 0, "马尾", 0, cancelled, cookie, error) == -1, "an explicit callback must still cancel when a cookie is supplied");
    lf_render_cookie_drop(cookie); lf_close(d);
    if (argc != 2) finite_page_parity(path);
    printf("candidate parity: %zu queries x 8 option/direction combinations; failures=%d\n", sizeof(queries)/sizeof(*queries), failures);
    if (argc != 2) { parsed_phrase_parity(directory, path); cleanup_fixture(directory, path); }
    return failures ? 1 : 0;
}
