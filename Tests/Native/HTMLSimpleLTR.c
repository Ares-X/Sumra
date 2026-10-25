// HTML's simple-LTR shortcut must retain the upstream bidi/script metadata.
#include "html-imp.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static int failures, checked;
static uint32_t text[4096];
static int levels[4096], scripts[4096];
static size_t count;
static void compare_fragment(const uint32_t *fragment, size_t length, int level, int script, void *opaque) {
    size_t at = (size_t)(fragment - text);
    for (size_t i = 0; i < length; ++i) {
        if (levels[at+i] != level || scripts[at+i] != script) {
            fprintf(stderr, "bidi metadata mismatch rune=%x actual=%d/%d reference=%d/%d\n", text[at+i], levels[at+i], scripts[at+i], level, script);
            ++failures; break;
        }
    }
}
static void flush(fz_context *ctx, int direction) {
    if (!count) return;
    fz_bidi_direction dir = direction;
    fz_bidi_fragment_text(ctx, text, count, &dir, compare_fragment, NULL, 0);
    ++checked; count = 0;
}
static void append(int rune, const fz_html_flow *flow) {
    assert(count < sizeof(text)/sizeof(*text));
    text[count] = rune; levels[count] = flow->bidi_level; scripts[count++] = flow->script;
}
static void walk(fz_context *ctx, fz_html_tree *tree, fz_html_box *box) {
    for (; box; box = box->next) {
        if (box->type == BOX_FLOW) {
            for (fz_html_flow *flow = box->u.flow.head; flow; flow = fz_html_flow_next(tree, flow)) {
                if (flow->type == FLOW_WORD) {
                    for (const char *s = fz_html_flow_text(flow); *s;) { int rune; s += fz_chartorune(&rune,s); append(rune,flow); }
                } else if (flow->type == FLOW_SPACE) append(' ',flow);
                else if (flow->type == FLOW_BREAK || flow->type == FLOW_IMAGE) flush(ctx,box->markup_dir);
            }
            flush(ctx,box->markup_dir);
        }
        if (fz_html_box_has_boxes(box)) walk(ctx,tree,box->down);
    }
}
static void fixture(fz_context *ctx, fz_html_font_set *set, const char *body) {
    fz_buffer *buf = fz_new_buffer_from_printf(ctx,"<html><body>%s</body></html>",body);
    fz_html *html = fz_parse_html(ctx,set,NULL,".",buf,NULL,1,1,FZ_HTML_FLAVOR_EPUB_REFLOW,1);
    walk(ctx,&html->tree,html->tree.root);
    fz_drop_html(ctx,html); fz_drop_buffer(ctx,buf);
}
int main(void) {
    fz_context *ctx = fz_new_context(NULL,NULL,FZ_STORE_DEFAULT);
    fz_html_font_set *set = fz_new_html_font_set(ctx);
    const char *cases[] = {
        "<p>普通汉字，。！？『标点』１２３＋—……</p>",
        "<p>（123）甲<span>乙</span>丙<span>丁</span>，‘引号’。</p>",
        "<p>甲<span style='font-style:italic'>乙</span><b>丙</b>丁&#173;戊</p>",
        "<p>plain ASCII 123 punctuation (brackets)!</p>",
        "<p>Latin mixed 中文 and Greek Ελληνικά</p>",
        "<p>甲אבג乙 العربية丙</p>",
        "<p dir='rtl'>甲乙丙 123</p>",
        "<p dir='auto'>甲乙丙 123</p>",
        "<p>&#x202e;甲乙&#x202c;丙&#x2067;丁&#x2069;戊</p>",
        "<p>甲&#x301;乙&#x200d;丙 😀丁</p>",
        "<p>甲<br/>乙</p><p>123 punctuation only!</p>",
        "<p>甲乙，丙丁<br/>plain ASCII 123<br/>戊己。庚辛<br/>Latin mixed 中文<br/>壬癸</p>",
        "<p>甲乙<br/>אבג 123<br/>丙丁<br/>العربية 456<br/>戊己</p>",
        "<p>甲&#x301;乙<br/>&#x202e;甲乙&#x202c;<br/>丙&#x2067;丁&#x2069;戊<br/>庚辛</p>",
        "<p dir='rtl'>甲乙<br/>Latin 123<br/>丙丁</p>",
        "<p dir='auto'>甲乙<br/>אבג 123<br/>丙丁</p>",
        "<p>甲乙<img src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='/>丙丁</p>",
        "<p>甲乙<br/><br/>丙丁<br/></p>"
    };
    for (size_t i=0;i<sizeof(cases)/sizeof(*cases);++i) fixture(ctx,set,cases[i]);
    uint32_t random=19; char body[4096];
    const char *units[]={"甲","乙","丙","丁","，","。","！","？","‘","’","（","）","1","2","3"," ","…"};
    for (int run=0;run<256;++run) {
        strcpy(body,"<p>甲");
        for(int i=0;i<64;++i) { random=random*1664525u+1013904223u;strcat(body,units[random%(sizeof(units)/sizeof(*units))]); }
        strcat(body,"</p>");fixture(ctx,set,body);
    }
    fz_drop_html_font_set(ctx,set);fz_drop_context(ctx);
    printf("HTML LTR flow metadata: %d upstream bidi comparisons; failures=%d\n",checked,failures);
    return failures?1:0;
}
