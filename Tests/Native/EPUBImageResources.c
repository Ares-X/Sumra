// Parsed EPUB chapters share raster resources through the existing Fitz store.
#include "mupdf/fitz.h"
#include "html/html-imp.h"
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
static int failures;
static void check(int ok, const char *message) { if (!ok) { fprintf(stderr, "FAIL: %s\n", message); ++failures; } }
static fz_image *first_image(fz_html_tree *tree, fz_html_box *box) {
    for (; box; box = box->next) {
        if (box->type == BOX_FLOW)
            for (fz_html_flow *flow = box->u.flow.head; flow; flow = fz_html_flow_next(tree, flow))
                if (flow->type == FLOW_IMAGE) return flow->content.image;
        if (fz_html_box_has_boxes(box)) {
            fz_image *image = first_image(tree, box->down);
            if (image) return image;
        }
    }
    return NULL;
}
static fz_image *parse_image(fz_context *ctx, fz_html_font_set *fonts, fz_archive *archive,
                            const char *base, const char *source) {
    fz_buffer *buffer = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)source, strlen(source));
    fz_html *html = fz_parse_html(ctx, fonts, archive, base, buffer, NULL, 1, 1, FZ_HTML_FLAVOR_DEFAULT, 1);
    fz_layout_html(ctx, html, 320, 180, 17);
    fz_layout_html(ctx, html, 240, 0, 19);
    fz_image *image = fz_keep_image(ctx, first_image(&html->tree, html->tree.root));
    fz_drop_html(ctx, html); fz_drop_buffer(ctx, buffer);
    return image;
}
static void write_image(fz_context *ctx, const char *directory, const char *name, int red) {
    char path[1024]; snprintf(path, sizeof path, "%s/%s", directory, name);
    fz_pixmap *pixmap = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), fz_make_irect(0,0,2,2), NULL, 0);
    unsigned char *samples = fz_pixmap_samples(ctx, pixmap);
    for (int i = 0; i < 4; ++i) { samples[i*3] = red; samples[i*3+1] = 0; samples[i*3+2] = 255-red; }
    fz_save_pixmap_as_png(ctx, pixmap, path); fz_drop_pixmap(ctx, pixmap);
}
static int red_channel(fz_context *ctx, fz_image *image) {
    fz_pixmap *pixmap = fz_get_unscaled_pixmap_from_image(ctx, image);
    int red = fz_pixmap_samples(ctx, pixmap)[0]; fz_drop_pixmap(ctx, pixmap); return red;
}
int main(void) {
    char first[] = "/private/tmp/Sumra-image-resource-first-XXXXXX", second[] = "/private/tmp/Sumra-image-resource-second-XXXXXX";
    if (!mkdtemp(first) || !mkdtemp(second)) return 2;
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    fz_html_font_set *fonts = fz_new_html_font_set(ctx);
    fz_archive *a = fz_open_directory(ctx, first), *b = fz_open_directory(ctx, second);
    write_image(ctx, first, "image.png", 255); write_image(ctx, second, "image.png", 0);
    fz_image *one = parse_image(ctx, fonts, a, "chapter", "<html><body><img src='../image.png'/></body></html>");
    fz_image *alias = parse_image(ctx, fonts, a, ".", "<html><body><img src='./im%61ge.png'/></body></html>");
    fz_image *other = parse_image(ctx, fonts, b, ".", "<html><body><img src='image.png'/></body></html>");
    check(one && one == alias, "canonical paths in separate parsed chapters must share their raster image");
    check(other && other != one, "different archives with the same resource path must stay distinct");
    check(red_channel(ctx, one) == 255 && red_channel(ctx, other) == 0, "shared image bytes must retain their archive identity");
    char resources[1024], images[1024];
    snprintf(resources, sizeof resources, "%s/OPS", first); mkdir(resources, 0700);
    snprintf(images, sizeof images, "%s/OPS/images", first); mkdir(images, 0700);
    write_image(ctx, images, "1h7m84r.png", 255); write_image(ctx, images, "jwyi64.png", 0);
    fz_image *collision_a = parse_image(ctx, fonts, a, ".", "<html><body><img src='OPS/images/1h7m84r.png'/></body></html>");
    fz_image *collision_b = parse_image(ctx, fonts, a, ".", "<html><body><img src='OPS/images/jwyi64.png'/></body></html>");
    check(collision_a && collision_b && collision_a != collision_b &&
        red_channel(ctx, collision_a) == 255 && red_channel(ctx, collision_b) == 0,
        "distinct full paths with identical FNV32 must retain different pixels");
    fz_drop_image(ctx, collision_a); fz_drop_image(ctx, collision_b);
    fz_drop_archive(ctx, a); fz_drop_archive(ctx, b);
    fz_empty_store(ctx);
    check(red_channel(ctx, one) == 255 && red_channel(ctx, other) == 0, "retained images must survive archive owners and store eviction");
    a = fz_open_directory(ctx, first);
    fz_image *reopened = parse_image(ctx, fonts, a, ".", "<html><body><img src='image.png'/></body></html>");
    check(reopened && reopened != one && red_channel(ctx, reopened) == 255, "a reopened archive must not reuse the old resource identity");
    fz_drop_image(ctx, one); fz_drop_image(ctx, alias); fz_drop_image(ctx, other); fz_drop_image(ctx, reopened);
    fz_drop_archive(ctx, a); fz_drop_html_font_set(ctx, fonts); fz_drop_context(ctx);
    char path[1024];
    snprintf(path,sizeof path,"%s/1h7m84r.png",images); unlink(path);
    snprintf(path,sizeof path,"%s/jwyi64.png",images); unlink(path); rmdir(images); rmdir(resources);
    snprintf(path,sizeof path,"%s/image.png",first); unlink(path); rmdir(first);
    snprintf(path,sizeof path,"%s/image.png",second); unlink(path); rmdir(second);
    printf("EPUB raster resource sharing/lifetime: failures=%d\n", failures);
    return failures ? 1 : 0;
}
