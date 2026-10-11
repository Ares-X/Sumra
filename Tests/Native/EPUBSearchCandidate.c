// Isolated native search regression: negative chapters must not extract glyphs.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
API int lf_search_chapter_candidate(void *, int, const char *, int, int (*)(void), char *);
API char *lf_text_at(SumraMuPDFDocument *, int, int, char *);
API int lf_relayout_css(SumraMuPDFDocument *, float, float, float, const char *, int, char *);
API void lf_close(SumraMuPDFDocument *);
static int failures;
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
    write_file(directory, "one.xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>p.generated:before{content:'before CONTENT 甲'} body{font-family:serif}</style></head><body><p>马<span>尾</span>拂尘</p><p>马尾 <em>拂尘</em></p><p class='generated'>inline café CAFÉ ß ﬁ exact</p><ol><li>list item</li></ol><ul><li>bullet</li></ul><p>e&#x301; A&#xad;B</p><p>wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap</p></body></html>");
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
    check(lf_search_chapter_candidate(d, 0, "不存在的目标", 0, NULL, chapter_error) == 0, "negative parsed chapter candidate");
    check(d->render_page == NULL, "negative candidate must not load/layout a page");
    char *json = search(d, "不存在的目标", 0, -1);
    check(json && strstr(json, "\"matches\":[]"), "negative result");
    check(d->text_page == NULL, "negative chapter must skip full glyph extraction");
    free(json); lf_close(d);
    const char *queries[] = {"马尾拂尘", "马尾 拂尘", "马尾", "before", "CONTENT", "cafe", "CAFÉ", "ss", "fi", "1.", "•", "甲", "inline", "wrap", "exact", "e\xCC\x81", " ", "-", "\xCC\x81", "customCSS中", "1. list", "不存在的目标"};
    for (size_t i = 0; i < sizeof(queries)/sizeof(*queries); ++i) {
        for (int flags = 0; flags < 8; ++flags) {
            SumraMuPDFDocument *fast = open_book(path), *reference = open_book(path);
            if (!fast || !reference) return 1;
            char error[512] = {0}; char *text = lf_text_at(reference, 0, 0, error);
            check(text != NULL, error); free(text);
            int candidate = lf_search_chapter_candidate(fast, 0, queries[i], flags, NULL, error);
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
    check(lf_search_chapter_candidate(d, 0, "newCSS生成", 0, NULL, error) == 0, "initial CSS candidate absence");
    check(lf_relayout_css(d, 480, 0, 19, "p.generated:after{content:'newCSS生成'}", 1, error) == 1, error);
    check(lf_search_chapter_candidate(d, 0, "newCSS生成", 0, NULL, error) == 1, "CSS change must purge and regenerate parsed candidates");
    json = search(d, "newCSS生成", 0, -1);
    check(json && !strstr(json, "\"matches\":[]"), "generated candidate must retain rendered hit after CSS change");
    free(json);
    check(lf_relayout_css(d, 320, 0, 17, NULL, 1, error) == 1, error);
    check(lf_search_chapter_candidate(d, 0, "newCSS生成", 0, NULL, error) == 0, "removed generated CSS text must not survive in the parsed cache");
    check(lf_search_chapter_candidate(d, 0, "不存在的目标", 0, cancelled, error) == -1 && strstr(error, "Search cancelled"), "prelayout candidate cancellation");
    json = lf_search_options_at(d, 0, 0, "不存在的目标", 0, -1, 1, cancelled, error);
    check(!json && strstr(error, "Search cancelled"), "candidate walk must honor cancellation");
    free(json); lf_close(d);
    printf("candidate parity: %zu queries x 8 option/direction combinations; failures=%d\n", sizeof(queries)/sizeof(*queries), failures);
    if (argc != 2) cleanup_fixture(directory, path);
    return failures ? 1 : 0;
}
