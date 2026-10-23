// Regression against issue #31's reporter EPUBs, supplied as test-only arguments.
#include "mupdf/fitz.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int ok, const char *message, const char *path, float w, float h) {
    if (!ok) { fprintf(stderr, "FAIL %s %.0fx%.0f: %s\n", path, w, h, message); ++failures; }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "Supply the reporter EPUB samples.\n"); return 2; }
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    fz_register_document_handlers(ctx);
    const float sizes[][2] = {{720,480}, {360,480}, {480,720}, {360,0}};
    for (int a = 1; a < argc; ++a) {
        fz_document *doc = fz_open_document(ctx, argv[a]);
        for (int s = 0; s < 4; ++s) {
            float w = sizes[s][0], h = sizes[s][1];
            if (h) fz_layout_document(ctx, doc, w, h, 17);
            else fz_layout_document_continuous(ctx, doc, w, 17);
            int count = fz_count_chapter_pages(ctx, doc, 0);
            check(count == 1, "the cover must occupy exactly one page", argv[a], w, h);
            fz_page *page = fz_load_chapter_page(ctx, doc, 0, 0);
            fz_rect canvas = fz_bound_page(ctx, page);
            fz_stext_options options = {0}; options.flags = FZ_STEXT_PRESERVE_IMAGES;
            fz_stext_page *text = fz_new_stext_page_from_page(ctx, page, &options);
            int images = 0;
            for (fz_stext_block *b = text->first_block; b; b = b->next) {
                if (b->type != FZ_STEXT_BLOCK_IMAGE) continue;
                ++images;
                fz_rect r = b->bbox;
                float width = r.x1-r.x0, height = r.y1-r.y0;
                float ratio = (float)b->u.i.image->w / b->u.i.image->h;
                check(fabsf(width/height-ratio) < 0.002f, "the cover must keep the source image ratio", argv[a], w, h);
                check(fabsf((r.x0+r.x1-canvas.x0-canvas.x1)/2) < 0.01f &&
                    fabsf((r.y0+r.y1-canvas.y0-canvas.y1)/2) < 0.01f,
                    "the cover must be centered", argv[a], w, h);
                check(r.x0 >= canvas.x0-0.01f && r.y0 >= canvas.y0-0.01f &&
                    r.x1 <= canvas.x1+0.01f && r.y1 <= canvas.y1+0.01f,
                    "the whole cover must fit the page", argv[a], w, h);
                check(fabsf(width-(canvas.x1-canvas.x0)) < 0.01f || fabsf(height-(canvas.y1-canvas.y0)) < 0.01f,
                    "the cover must fill one available page dimension", argv[a], w, h);
                printf("PASS %s %.0fx%.0f cover-pages=%d image=[%.3f,%.3f,%.3f,%.3f]\n", argv[a], w,h,count,r.x0,r.y0,r.x1,r.y1);
            }
            check(images == 1, "the cover must render exactly one image", argv[a], w, h);
            fz_drop_stext_page(ctx, text); fz_drop_page(ctx, page);
            const char *name = strrchr(argv[a], '/'); name = name ? name+1 : argv[a];
            if (!strcmp(name, "misalignedepubC.epub")) {
                fz_link_dest cover = fz_resolve_link_dest(ctx, doc, "OPS/xhtml/01-cover.xhtml#page_Cover");
                check(cover.loc.chapter == 0 && cover.loc.page == 0, "the cover's authored fragment must survive wrapper normalization", argv[a], w, h);
                check(fz_count_chapter_pages(ctx, doc, 1) == 1, "the insert and caption must remain together", argv[a], w, h);
                page = fz_load_chapter_page(ctx, doc, 1, 0);
                text = fz_new_stext_page_from_page(ctx, page, &options);
                fz_buffer *buffer = fz_new_buffer_from_stext_page(ctx, text);
                check(strstr(fz_string_from_buffer(ctx, buffer), "IMAGE SUBTITLE") != NULL,
                    "the caption must remain visible on its image page", argv[a], w, h);
                fz_drop_buffer(ctx, buffer); fz_drop_stext_page(ctx, text); fz_drop_page(ctx, page);
            }
        }
        fz_drop_document(ctx, doc);
    }
    fz_drop_context(ctx);
    printf("EPUB reporter cover geometry/caption: failures=%d\n", failures);
    return failures ? 1 : 0;
}
