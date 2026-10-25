// Cooperative Markdown source traversal: exact source parity and read interleave.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <unistd.h>

API char *lf_text_at(SumraMuPDFDocument *, int, int, char *);
API int lf_relayout_css(SumraMuPDFDocument *, float, float, float, const char *, int, char *);
API void lf_close(SumraMuPDFDocument *);

typedef struct {
    fz_html_search_char *items;
    size_t count, capacity, stop_after;
} Source;
static int failures;
static void check(int ok, const char *why) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", why); ++failures; }
}
static int collect(fz_context *ctx, void *opaque, const fz_html_search_char *ch) {
    Source *source = opaque;
    if (source->count == source->capacity) {
        source->capacity = source->capacity ? source->capacity * 2 : 128;
        source->items = fz_realloc_array(ctx, source->items, source->capacity, fz_html_search_char);
    }
    source->items[source->count++] = *ch;
    return source->stop_after && source->count == source->stop_after;
}
static int same_char(const fz_html_search_char *a, const fz_html_search_char *b) {
    return a->unicode == b->unicode && a->page == b->page && a->paintable == b->paintable &&
        a->source_node == b->source_node && a->source_offset == b->source_offset &&
        a->source_part == b->source_part && a->text_y0 == b->text_y0 &&
        a->text_y1 == b->text_y1 && a->chapter == b->chapter;
}
static int cancelled(void) { return 1; }

static void read_and_render_between_steps(SumraMuPDFDocument *document) {
    char error[512] = {0};
    int chapter = fz_count_chapters(document->ctx, document->doc) - 1;
    char *text = lf_text_at(document, chapter, 0, error);
    check(text != NULL, error);
    free(text);
    int region[4] = {0, 0, 240, 160}, info[4] = {0};
    unsigned char *pixels = lf_render_cancelable_at(document, chapter, 0, 240,
        region, 0, NULL, NULL, NULL, info, error);
    check(pixels != NULL, error);
    free(pixels);
    // This process owns its isolated document/store. The cursor's retained HTML
    // must survive reading another chapter and eviction of cached store values.
    fz_empty_store(document->ctx);
}

static void cursor_parity(SumraMuPDFDocument *document, size_t budget, int interleave, int chapter, int page) {
    Source reference = {0}, actual = {0};
    fz_htdoc_search_source *cursor = NULL;
    size_t steps = 0;
    int complete = 0, read_during_walk = 0;
    fz_var(cursor); fz_var(reference); fz_var(actual);
    fz_try(document->ctx) {
        if (chapter >= 0)
            fz_htdoc_walk_search_source_from_page(document->ctx, document->doc, chapter, page, collect, &reference, NULL);
        else fz_htdoc_walk_search_source(document->ctx, document->doc, collect, &reference, NULL);
        cursor = chapter >= 0 ? fz_new_htdoc_search_source_from_page(document->ctx, document->doc, chapter, page)
            : fz_new_htdoc_search_source(document->ctx, document->doc);
        while (!complete) {
            size_t before = actual.count;
            complete = fz_step_htdoc_search_source(document->ctx, cursor, collect, &actual, NULL, budget);
            ++steps;
            check(actual.count - before <= budget, "a step must bound source work inside a long word");
            if (interleave && actual.count && !complete && !read_during_walk) {
                read_and_render_between_steps(document);
                read_during_walk = 1;
                check(actual.count < reference.count, "reading must complete before source traversal ends");
            }
        }
        check(actual.count == reference.count, "cursor must retain every source character without duplication");
        size_t count = actual.count < reference.count ? actual.count : reference.count;
        for (size_t i = 0; i < count; ++i) {
            if (!same_char(&actual.items[i], &reference.items[i])) {
                fprintf(stderr, "source mismatch at %zu: scalar %d/%d chapter %d/%d node %u/%u offset %u/%u\n",
                    i, actual.items[i].unicode, reference.items[i].unicode,
                    actual.items[i].chapter, reference.items[i].chapter,
                    actual.items[i].source_node, reference.items[i].source_node,
                    actual.items[i].source_offset, reference.items[i].source_offset);
                check(0, "cursor must preserve source identity, geometry, separators and visibility");
                break;
            }
        }
        if (reference.count > budget)
            check(steps > 1, "a source longer than the work quantum must resume before completion");
        if (interleave) check(read_during_walk, "reader operation must run during an unfinished source traversal");
        printf("cursor start=%d/%d budget=%zu steps=%zu sourceCharacters=%zu readInterleaved=%d\n",
            chapter, page, budget, steps, actual.count, read_during_walk);
    }
    fz_always(document->ctx) {
        fz_drop_htdoc_search_source(document->ctx, cursor);
        fz_free(document->ctx, reference.items);
        fz_free(document->ctx, actual.items);
    }
    fz_catch(document->ctx) { check(0, fz_caught_message(document->ctx)); }
}

static void cursor_cancellation(SumraMuPDFDocument *document) {
    fz_htdoc_search_source *cursor = NULL;
    Source actual = {0};
    int did_cancel = 0;
    fz_var(cursor); fz_var(actual); fz_var(did_cancel);
    fz_try(document->ctx) {
        cursor = fz_new_htdoc_search_source(document->ctx, document->doc);
        check(!fz_step_htdoc_search_source(document->ctx, cursor, collect, &actual, NULL, 100),
            "cancellation fixture must have an active unfinished traversal");
        fz_try(document->ctx) {
            fz_step_htdoc_search_source(document->ctx, cursor, collect, &actual, cancelled, 100);
        }
        fz_catch(document->ctx) {
            did_cancel = fz_caught(document->ctx) == FZ_ERROR_ABORT;
        }
        check(did_cancel, "an active cursor must observe cancellation at the next step");
        fz_drop_htdoc_search_source(document->ctx, cursor); cursor = NULL;
        read_and_render_between_steps(document);
        actual.count = 0; actual.stop_after = 1;
        cursor = fz_new_htdoc_search_source(document->ctx, document->doc);
        int complete = 0;
        while (!complete) complete = fz_step_htdoc_search_source(document->ctx, cursor, collect, &actual, NULL, 7);
        check(actual.count == 1, "callback stop must retain exactly its final delivered source character");
        check(fz_step_htdoc_search_source(document->ctx, cursor, collect, &actual, NULL, 7) && actual.count == 1,
            "a stopped cursor must not resume or publish stale source characters");
    }
    fz_always(document->ctx) {
        fz_drop_htdoc_search_source(document->ctx, cursor);
        fz_free(document->ctx, actual.items);
    }
    fz_catch(document->ctx) { check(0, fz_caught_message(document->ctx)); }
}

static void exercise(const char *path, float height) {
    char error[512] = {0}; int password = 0;
    SumraMuPDFDocument *document = lf_open_classified_deferred(path, NULL, &password, error, 0);
    check(document != NULL, error);
    if (!document) return;
    check(lf_relayout_css(document, 320, height, 17,
        "@page{margin:0} .hidden{visibility:hidden} .transparent{color:transparent} "
        ".restored{visibility:visible} sup{vertical-align:super}", 1, error) > 0, error);
    // As NativeFile.relayout does, resolve the scheduled style/layout before
    // entering the low-level source walker on a deferred document.
    check(fz_count_chapters(document->ctx, document->doc) > 0, "prepared Markdown chapters");
    cursor_parity(document, 1, 1, -1, -1);
    cursor_parity(document, 7, 0, -1, -1);
    cursor_parity(document, 4096, 0, -1, -1);
    int last_chapter = fz_count_chapters(document->ctx, document->doc) - 1;
    int last_page = fz_count_chapter_pages(document->ctx, document->doc, last_chapter) - 1;
    cursor_parity(document, 7, 1, last_chapter, last_page);
    cursor_parity(document, 4096, 0, last_chapter, last_page);
    cursor_cancellation(document);
    lf_close(document);
}

int main(void) {
    char directory[] = "/tmp/sumra-markdown-cursor-XXXXXX";
    if (!mkdtemp(directory)) return 2;
    char multi[PATH_MAX], giant[PATH_MAX], indexed[PATH_MAX];
    snprintf(multi, sizeof multi, "%s/chapters.md", directory);
    snprintf(giant, sizeof giant, "%s/long-paragraph.md", directory);
    snprintf(indexed, sizeof indexed, "%s/indexed.md", directory);
    FILE *file = fopen(multi, "w"); if (!file) return 2;
    fputs("# First\n\nLeading **bold** text *italic* café e\xcc\x81 ﬁ ß.\n\n"
        "<p>visible<span class='hidden'>unseen</span>after "
        "<span class='hidden'>hidden<span class='restored'>restored</span></span> "
        "<span class='transparent'>transparent</span>end</p>\n\n"
        "> quoted\n> second line\n\n- first list\n- second list\n\n"
        "## Second\n\n中文**跨**样式 text אבג mixed.\n\n"
        "| one | two |\n| --- | --- |\n| alpha | beta |\n\n"
        "<p>soft&#173;hyphen<br>hard break<sup>super</sup></p>\n\n"
        "## Final\n\nFinal source marker.\n", file);
    fclose(file);
    file = fopen(giant, "w"); if (!file) return 2;
    // No heading or paragraph break: resumption must work inside one section,
    // one source node and a single long word, with real source-offset ordering.
    for (int i = 0; i < 30000; ++i) fputs("abcdef", file);
    fputs(" אבג 中文 trailing source marker.\n", file);
    fclose(file);
    file = fopen(indexed, "w"); if (!file) return 2;
    for (int chapter = 0; chapter < 3; ++chapter) {
        fprintf(file, "# Section %d\n\n", chapter);
        for (int paragraph = 0; paragraph < 300; ++paragraph)
            fprintf(file, "Paragraph %d contains ordinary searchable text.\n\n", paragraph);
    }
    fclose(file);
    exercise(indexed, 180);
    exercise(multi, 0);
    exercise(multi, 180);
    exercise(giant, 0);
    unlink(multi); unlink(giant); unlink(indexed); rmdir(directory);
    printf("Markdown cursor failures=%d\n", failures);
    return failures ? 1 : 0;
}
