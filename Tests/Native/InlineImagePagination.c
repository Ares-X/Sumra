// Mixed image/prose lines must fit before page placement, as in FB2/MOBI Alice.
#include "html-imp.h"
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures, checked, images;
static void walk(fz_html_tree *tree, fz_html_box *box, float page_h) {
    for (; box; box = box->next) {
        if (box->type == BOX_FLOW) {
            for (fz_html_flow *flow = box->u.flow.head; flow; flow = fz_html_flow_next(tree, flow)) {
                if (flow->type != FLOW_IMAGE) continue;
                ++images;
                if (page_h > 0 && floorf(flow->y / page_h) != floorf((flow->y + flow->h - .01f) / page_h)) {
                    fprintf(stderr, "FAIL image crosses page: y=%g height=%g page=%g\n", flow->y, flow->h, page_h);
                    ++failures;
                }
            }
        }
        if (fz_html_box_has_boxes(box)) walk(tree, box->down, page_h);
    }
}
static void check_text(fz_context *ctx, fz_html *html, float w, float h, int mode) {
    fz_buffer *all = fz_new_buffer(ctx, 256);
    int pages = h > 0 ? (int)ceilf(html->tree.root->s.layout.b / h) : 1;
    for (int page = 0; page < pages; ++page) {
        fz_stext_page *text = fz_new_stext_page(ctx, fz_make_rect(0, 0, w, h > 0 ? h : html->tree.root->s.layout.b));
        fz_device *device = fz_new_stext_device(ctx, text, NULL);
        fz_draw_html(ctx, device, fz_identity, html, page, NULL);
        fz_close_device(ctx, device); fz_drop_device(ctx, device);
        fz_buffer *buffer = fz_new_buffer_from_stext_page(ctx, text);
        fz_append_string(ctx, all, fz_string_from_buffer(ctx, buffer));
        fz_drop_buffer(ctx, buffer); fz_drop_stext_page(ctx, text);
    }
    const char *source = fz_string_from_buffer(ctx, all);
    char compact[4096]; size_t count = 0;
    for (; *source && count + 1 < sizeof compact; ++source)
        if (!isspace((unsigned char)*source)) compact[count++] = *source;
    compact[count] = 0;
    const char *phrase = "Alicewasbeginningtogetverytired.";
    char *found = strstr(compact, phrase);
    if ((mode && (!found || strstr(found + strlen(phrase), phrase))) || (!mode && found)) {
        fprintf(stderr, "FAIL neighboring text must remain complete exactly once: %s\n", compact); ++failures;
    }
    fz_drop_buffer(ctx, all);
}
static void fixture(fz_context *ctx, fz_html_font_set *fonts, fz_html_flavor flavor, int mode, int full_page, const char *align, float w, float h) {
    const char *image = "<img style='vertical-align:%s;width:80px;height:%dpx' src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='/>",
        *text = "Alice was beginning to get very tired.";
    char art[1024];
    snprintf(art, sizeof art, image, align, full_page ? 1600 : 160);
    fz_buffer *buffer = fz_new_buffer_from_printf(ctx,
        "<html><head><style>@page{margin:0}body,p{margin:0;padding:0}body{font-size:17px;line-height:1.2}</style></head>"
        "<body><div style='height:%gpx'>%s</div><p>%s%s%s</p>%s</body></html>",
        (full_page ? 0 : (h > 0 ? h : 400) - 24), full_page ? "" : "CHAPTERMARKER", mode == 2 ? text : "", art, mode == 1 ? text : "", full_page ? "" : "<p>After the illustration.</p>");
    fz_html *html = fz_parse_html(ctx, fonts, NULL, ".", buffer, NULL, 1, 1, flavor, 1);
    fz_layout_html(ctx, html, w, h, 17);
    int before = images;
    walk(&html->tree, html->tree.root, h);
    if (images != before + 1) { fprintf(stderr, "FAIL expected one image\n"); ++failures; }
    if (full_page && h > 0 && html->tree.root->s.layout.b > h + .01f) {
        fprintf(stderr, "FAIL full-page inline image introduced an extra page\n"); ++failures;
    }
    check_text(ctx, html, w, h, mode);
    ++checked;
    fz_drop_html(ctx, html); fz_drop_buffer(ctx, buffer);
}
static void find_icon(fz_html_tree *tree, fz_html_box *box, fz_html_flow **icon, fz_html_flow **word) {
    for (; box; box = box->next) {
        if (box->type == BOX_FLOW)
            for (fz_html_flow *flow = box->u.flow.head; flow; flow = fz_html_flow_next(tree, flow)) {
                if (flow->type == FLOW_IMAGE && flow->h < 20) *icon = flow;
                if (flow->type == FLOW_WORD && !*word) *word = flow;
            }
        if (fz_html_box_has_boxes(box)) find_icon(tree, box->down, icon, word);
    }
}
static void small_icon(fz_context *ctx, fz_html_font_set *fonts, int align, const char *alignment, int large) {
    const char *data = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
    char icon_html[512], page_html[512];
    snprintf(icon_html, sizeof icon_html, "<img style='width:8px;height:8px;vertical-align:%s' src='%s'/>", alignment, data);
    snprintf(page_html, sizeof page_html, "<img style='width:80px;height:1600px' src='%s'/>", data);
    fz_buffer *buffer = fz_new_buffer_from_printf(ctx,
        "<html><head><style>@page{margin:0}body,p{margin:0;padding:0}body{font-size:17px;line-height:1.2}</style></head>"
        "<body><p>Alice was beginning to get very tired.%s%s%s</p></body></html>",
        large == 1 ? page_html : "", icon_html, large == 2 ? page_html : "");
    fz_html *html = fz_parse_html(ctx, fonts, NULL, ".", buffer, NULL, 1, 1, FZ_HTML_FLAVOR_MOBI, 1);
    fz_layout_html(ctx, html, 500, 400, 17);
    fz_html_flow *icon = NULL, *word = NULL;
    find_icon(&html->tree, html->tree.root, &icon, &word);
    if (!icon || !word || fabsf(icon->w - 8) > .01f || fabsf(icon->h - 8) > .01f) {
        fprintf(stderr, "FAIL small %s icon must retain its authored size\n", alignment); ++failures;
    } else {
        float expected = align == 1 ? -8.25f : align == 4 ? -4.6f : align == 5 ? -8 - 17.0f/3 : -8;
        float actual = icon->y - word->y;
        if (align == 2) { expected = 0; actual = icon->y; }
        if (align == 3) { expected = html->tree.root->s.layout.b; actual = icon->y + icon->h; }
        if (fabsf(actual - expected) > .01f) {
            fprintf(stderr, "FAIL small %s icon lost its alignment: actual=%g expected=%g\n", alignment, actual, expected); ++failures;
        }
    }
    if (html->tree.root->s.layout.b > 400.01f) { fprintf(stderr, "FAIL decorative mixed line added a page\n"); ++failures; }
    walk(&html->tree, html->tree.root, 400);
    check_text(ctx, html, 500, 400, 1);
    ++checked;
    fz_drop_html(ctx, html); fz_drop_buffer(ctx, buffer);
}
int main(void) {
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    fz_html_font_set *fonts = fz_new_html_font_set(ctx);
    fz_html_flavor flavors[] = { FZ_HTML_FLAVOR_DEFAULT, FZ_HTML_FLAVOR_MOBI, FZ_HTML_FLAVOR_EPUB_REFLOW };
    const char *alignments[] = { "baseline", "middle", "top", "bottom", "sub", "super" };
    float sizes[][2] = { {500,400}, {720,660}, {1512,860}, {360,480}, {480,720}, {360,0} };
    for (int flavor = 0; flavor < 3; ++flavor)
        for (int mode = 0; mode < 3; ++mode)
            for (int size = 0; size < 6; ++size)
                for (int full_page = 0; full_page < 2; ++full_page)
                    for (int align = 0; align < 6; ++align)
                        fixture(ctx, fonts, flavors[flavor], mode, full_page, alignments[align], sizes[size][0], sizes[size][1]);
    for (int align = 0; align < 6; ++align)
        for (int large = 0; large < 3; ++large) small_icon(ctx, fonts, align, alignments[align], large);
    fz_drop_html_font_set(ctx, fonts); fz_drop_context(ctx);
    printf("Inline image pagination: %d layouts, failures=%d\n", checked, failures);
    return failures ? 1 : 0;
}
