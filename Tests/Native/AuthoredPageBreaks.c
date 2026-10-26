// Authored block breaks must survive placement and retain every page's text.
#include "mupdf/fitz.h"
#include <stdio.h>
#include <string.h>

static int checked, failures;
static void fixture(fz_context *ctx, const char *label, const char *body,
                    float height, int expected_pages, int second_page) {
    fz_buffer *source = fz_new_buffer_from_printf(ctx,
        "<html><head><style>@page{margin:0}body,p,div,h1,h2,h3,h4,h5,h6{margin:0;padding:0;"
        "font-size:17px;line-height:1.2}</style></head><body>%s</body></html>", body);
    fz_stream *stream = fz_open_buffer(ctx, source);
    fz_document *doc = fz_open_document_with_stream(ctx, "text/html", stream);
    if (height > 0) fz_layout_document(ctx, doc, 500, height, 17);
    else fz_layout_document_continuous(ctx, doc, 500, 17);
    int pages = fz_count_pages(ctx, doc), first_count = 0, second_count = 0, third_count = 0;
    if (pages != expected_pages) {
        fprintf(stderr, "FAIL %s pages=%d expected=%d\n", label, pages, expected_pages); ++failures;
    }
    for (int page = 0; page < pages; ++page) {
        fz_stext_page *text = fz_new_stext_page_from_page_number(ctx, doc, page, NULL);
        fz_buffer *buffer = fz_new_buffer_from_stext_page(ctx, text);
        const char *value = fz_string_from_buffer(ctx, buffer);
        if (strstr(value, "FIRST")) { ++first_count; if (page != 0) ++failures; }
        if (strstr(value, "SECOND")) {
            ++second_count;
            if (page != second_page) {
                fprintf(stderr, "FAIL %s SECOND on page %d expected %d\n", label, page, second_page); ++failures;
            }
        }
        if (strstr(value, "THIRD")) { ++third_count; if (page != second_page) ++failures; }
        fz_drop_buffer(ctx, buffer); fz_drop_stext_page(ctx, text);
    }
    if (first_count != 1 || second_count != 1 || third_count != 1) {
        fprintf(stderr, "FAIL %s text counts %d/%d/%d\n", label, first_count, second_count, third_count); ++failures;
    }
    ++checked;
    fz_drop_document(ctx, doc); fz_drop_stream(ctx, stream); fz_drop_buffer(ctx, source);
}
static void leading_fixture(fz_context *ctx, const char *label, const char *source,
                            const char *mime, float height, int expected_pages,
                            int expected_text_page, const char *title, const char *body, int paint_page) {
    fz_buffer *buffer = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)source, strlen(source));
    fz_stream *stream = fz_open_buffer(ctx, buffer);
    fz_document *doc = fz_open_document_with_stream(ctx, mime, stream);
    if (height > 0) fz_layout_document(ctx, doc, 500, height, 17);
    else fz_layout_document_continuous(ctx, doc, 500, 17);
    int pages = fz_count_pages(ctx, doc), titles = 0, bodies = 0;
    if (pages != expected_pages) {
        fprintf(stderr, "FAIL %s pages=%d expected=%d\n", label, pages, expected_pages); ++failures;
    }
    for (int page = 0; page < pages; ++page) {
        fz_stext_page *text = fz_new_stext_page_from_page_number(ctx, doc, page, NULL);
        fz_buffer *words = fz_new_buffer_from_stext_page(ctx, text);
        const char *value = fz_string_from_buffer(ctx, words);
        if (strstr(value, title)) {
            ++titles;
            if (page != expected_text_page) { fprintf(stderr, "FAIL %s title page=%d expected=%d\n", label, page, expected_text_page); ++failures; }
        }
        if (strstr(value, body)) {
            ++bodies;
            if (page != expected_text_page) { fprintf(stderr, "FAIL %s body page=%d expected=%d\n", label, page, expected_text_page); ++failures; }
        }
        fz_drop_buffer(ctx, words); fz_drop_stext_page(ctx, text);
    }
    if (paint_page >= 0) {
        fz_pixmap *pixmap = fz_new_pixmap_from_page_number(ctx, doc, paint_page, fz_identity, fz_device_rgb(ctx), 0);
        unsigned char *samples = fz_pixmap_samples(ctx, pixmap);
        int components = fz_pixmap_components(ctx, pixmap), red = 0;
        for (int pixel = 0; pixel < fz_pixmap_width(ctx, pixmap) * fz_pixmap_height(ctx, pixmap); ++pixel)
            if (samples[pixel * components] == 255 && samples[pixel * components + 1] == 0 && samples[pixel * components + 2] == 0) { red = 1; break; }
        if (!red) { fprintf(stderr, "FAIL %s page lost its painted spacer\n", label); ++failures; }
        fz_drop_pixmap(ctx, pixmap);
    }
    if (titles != 1 || bodies != 1) { fprintf(stderr, "FAIL %s missing/duplicate title or body\n", label); ++failures; }
    ++checked;
    fz_drop_document(ctx, doc); fz_drop_stream(ctx, stream); fz_drop_buffer(ctx, buffer);
}
int main(void) {
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    fz_register_document_handlers(ctx);
    const char *tags[] = {"p", "div", "h1", "h2", "h3", "h4", "h5", "h6"};
    const char *values[] = {"auto", "avoid", "always", "left", "right"};
    for (int tag = 0; tag < 8; ++tag)
        for (int side = 0; side < 2; ++side)
            for (int value = 0; value < 5; ++value)
                for (int continuous = 0; continuous < 2; ++continuous) {
                    char body[1024], label[128];
                    snprintf(body, sizeof body,
                        "<%s style='page-break-after:%s'>FIRST</%s>"
                        "<%s style='page-break-before:%s'>SECOND</%s><%s>THIRD</%s>",
                        tags[tag], side ? values[value] : "auto", tags[tag],
                        tags[tag], side ? "auto" : values[value], tags[tag], tags[tag], tags[tag]);
                    snprintf(label, sizeof label, "%s break-%s:%s %s", tags[tag],
                        side ? "after" : "before", values[value], continuous ? "continuous" : "paged");
                    int second = continuous || value < 2 ? 0 : value == 4 ? 2 : 1;
                    fixture(ctx, label, body, continuous ? 0 : 400, second + 1, second);
                }
    fixture(ctx, "nested break-before", "<div><p>FIRST</p><div style='page-break-before:always'><p>SECOND</p></div><p>THIRD</p></div>", 400, 2, 1);
    fixture(ctx, "adjacent breaks collapse", "<p style='page-break-before:always;page-break-after:always'>FIRST</p><div style='page-break-before:always'>SECOND</div><p>THIRD</p>", 400, 2, 1);
    fixture(ctx, "empty block break-before", "<p>FIRST</p><div style='page-break-before:always'></div><p>SECOND</p><p>THIRD</p>", 400, 2, 1);
    const char *fb2 = "<?xml version='1.0' encoding='utf-8'?>"
        "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><description><title-info>"
        "<book-title>Archive Fixture</book-title><lang>en</lang></title-info></description><body><section>"
        "<title><p>Chapter One</p></title><p>Compressed FB2 retained text.</p></section></body></FictionBook>";
    leading_fixture(ctx, "FB2 first chapter with default stylesheet", fb2, "application/x-fictionbook", 595, 1, 0,
        "Chapter One", "Compressed FB2 retained text.", -1);
    leading_fixture(ctx, "continuous FB2 first chapter", fb2, "application/x-fictionbook", 0, 1, 0,
        "Chapter One", "Compressed FB2 retained text.", -1);
    const char *chapters = "<?xml version='1.0' encoding='utf-8'?>"
        "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section>"
        "<title><p>Chapter One</p></title><p>First chapter text.</p></section><section>"
        "<title><p>Chapter Two</p></title><p>Second chapter text.</p></section></body></FictionBook>";
    leading_fixture(ctx, "FB2 first chapter stays on page one", chapters, "application/x-fictionbook", 595, 2, 0,
        "Chapter One", "First chapter text.", -1);
    leading_fixture(ctx, "FB2 later title keeps its authored break", chapters, "application/x-fictionbook", 595, 2, 1,
        "Chapter Two", "Second chapter text.", -1);
    for (int value = 2; value < 5; ++value)
        for (int nested = 0; nested < 2; ++nested) {
            char source[2048], label[128];
            snprintf(source, sizeof source, "<html><body>%s<h1 style='page-break-before:%s'>Leading title</h1>"
                "<p>Retained body text.</p>%s</body></html>", nested ? "<div style='margin-top:1em'><div style='margin-top:2em'>" : "",
                values[value], nested ? "</div></div>" : "");
            snprintf(label, sizeof label, "default margins leading %s %s", values[value], nested ? "nested" : "direct");
            int page = value == 3 ? 1 : 0;
            leading_fixture(ctx, label, source, "text/html", 595, page + 1, page, "Leading title", "Retained body text.", -1);
        }
    leading_fixture(ctx, "explicit blank spacer retains its break", "<html><body><div style='height:100px'></div>"
        "<h1 style='page-break-before:always'>Leading title</h1><p>Retained body text.</p></body></html>",
        "text/html", 595, 2, 1, "Leading title", "Retained body text.", -1);
    leading_fixture(ctx, "painted padding and border retain their page", "<html><body>"
        "<div style='background:red;padding:20px;border:2px solid blue'></div>"
        "<h1 style='page-break-before:always'>Leading title</h1><p>Retained body text.</p></body></html>",
        "text/html", 595, 2, 1, "Leading title", "Retained body text.", 0);
    leading_fixture(ctx, "ancestor padding prevents break propagation", "<html><body>"
        "<div style='background:red;padding:20px;border:2px solid blue'>"
        "<h1 style='page-break-before:always'>Leading title</h1><p>Retained body text.</p></div></body></html>",
        "text/html", 595, 2, 1, "Leading title", "Retained body text.", 0);
    leading_fixture(ctx, "leading title and inline image keep first page", "<html><body>"
        "<h1 style='page-break-before:always'>Leading title</h1>"
        "<img style='width:80px;height:80px' src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='/><p>Retained body text.</p></body></html>",
        "text/html", 595, 1, 0, "Leading title", "Retained body text.", -1);
    for (int side = 0; side < 2; ++side)
        for (int value = 2; value < 5; ++value) {
            char source[2048], label[128];
            snprintf(source, sizeof source, "<html><body><h1>Leading title</h1>"
                "<p style='page-break-after:%s'>Retained body text.</p>"
                "<div style='page-break-before:%s'></div><a></a> <a></a> <a></a></body></html>",
                side ? values[value] : "auto", side ? "auto" : values[value]);
            snprintf(label, sizeof label, "terminal break-%s:%s with empty anchors", side ? "after" : "before", values[value]);
            leading_fixture(ctx, label, source, "text/html", 595, 1, 0, "Leading title", "Retained body text.", -1);
        }
    leading_fixture(ctx, "nested terminal margin-only blocks", "<html><body><div style='margin:1em'>"
        "<h1>Leading title</h1><p>Retained body text.</p><div style='page-break-before:always'>"
        "<div style='margin:2em'><a></a> <a></a></div></div></div></body></html>",
        "text/html", 595, 1, 0, "Leading title", "Retained body text.", -1);
    leading_fixture(ctx, "terminal explicit-height blank page stays", "<html><body>"
        "<h1>Leading title</h1><p>Retained body text.</p><div style='page-break-before:always;height:100px'></div></body></html>",
        "text/html", 595, 2, 0, "Leading title", "Retained body text.", -1);
    leading_fixture(ctx, "terminal painted padding page stays", "<html><body>"
        "<h1>Leading title</h1><p>Retained body text.</p>"
        "<div style='page-break-before:always;background:red;padding:20px;border:2px solid blue'></div></body></html>",
        "text/html", 595, 2, 0, "Leading title", "Retained body text.", 1);
    leading_fixture(ctx, "terminal image page stays", "<html><body><h1>Leading title</h1><p>Retained body text.</p>"
        "<div style='page-break-before:always'><img style='width:80px;height:80px' "
        "src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='/></div></body></html>",
        "text/html", 595, 2, 0, "Leading title", "Retained body text.", -1);
    fz_drop_context(ctx);
    printf("Authored page breaks: %d public document layouts, failures=%d\n", checked, failures);
    return failures ? 1 : 0;
}
