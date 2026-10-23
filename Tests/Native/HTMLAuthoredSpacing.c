#include "mupdf/fitz.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void check(fz_context *ctx, int source, int explicit_space, const char *expected)
{
    fz_font *font = fz_new_base14_font(ctx, "Helvetica");
    fz_text *text = fz_new_text(ctx);
    const char *letters = explicit_space ? "A B" : "AB";
    for (int i = 0; letters[i]; ++i)
    {
        int c = letters[i];
        float x = c == 'A' ? 0 : c == 'B' ? 10 : 7;
        fz_matrix matrix = fz_pre_translate(fz_scale(10, 10), x / 10, 2);
        fz_show_glyph(ctx, text, font, matrix, fz_encode_character(ctx, font, c), c, 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
        fz_text_item *item = &text->tail->items[text->tail->len - 1];
        item->source_node = source;
        item->source_offset = i;
        item->source_no_separator_before = source && !explicit_space && i > 0;
    }
    fz_stext_page *page = fz_new_stext_page(ctx, fz_make_rect(0, 0, 100, 100));
    fz_stext_options options = {0};
    fz_device *device = fz_new_stext_device(ctx, page, &options);
    float black = 0;
    fz_fill_text(ctx, device, text, fz_identity, fz_device_gray(ctx), &black, 1, fz_default_color_params);
    fz_close_device(ctx, device);
    fz_buffer *buffer = fz_new_buffer_from_stext_page(ctx, page);
    const char *actual = fz_string_from_buffer(ctx, buffer);
    if (strcmp(actual, expected))
        fprintf(stderr, "source=%d explicit_space=%d actual=[%s] expected=[%s]\n", source, explicit_space, actual, expected);
    assert(strcmp(actual, expected) == 0);
    fz_drop_buffer(ctx, buffer);
    fz_drop_device(ctx, device);
    fz_drop_stext_page(ctx, page);
    fz_drop_text(ctx, text);
    fz_drop_font(ctx, font);
}

int main(void)
{
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    assert(ctx);
    check(ctx, 0, 0, "A B\n"); /* PDF-style geometric inference remains available. */
    check(ctx, 1, 0, "AB\n");  /* HTML source owns whether a separator exists. */
    check(ctx, 1, 1, "A B\n");
    fz_drop_context(ctx);
    return 0;
}
