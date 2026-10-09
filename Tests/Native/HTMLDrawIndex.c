// Compare paginated drawing with the existing structure-callback traversal.
// The reference devices preserve the same text/raster behavior and callbacks
// force the conservative traversal, independent of the sibling spatial index.
#include <mupdf/fitz.h>
#include <stdio.h>
#include <string.h>

static int begins, ends;
static void begin(fz_context *ctx, fz_device *dev, fz_structure type, const char *raw, int index) { begins++; }
static void end(fz_context *ctx, fz_device *dev) { ends++; }

static fz_buffer *extract(fz_context *ctx, fz_page *page, int callbacks, int structured)
{
	fz_stext_options options = { .flags = structured ? FZ_STEXT_COLLECT_STRUCTURE : 0 };
	fz_stext_page *text = fz_new_stext_page(ctx, fz_bound_page(ctx, page));
	fz_device *dev = fz_new_stext_device(ctx, text, &options);
	if (!structured)
	{
		if (callbacks & 1) dev->begin_structure = begin;
		if (callbacks & 2) dev->end_structure = end;
	}
	fz_run_page_contents(ctx, page, dev, fz_identity, NULL);
	fz_close_device(ctx, dev);
	fz_drop_device(ctx, dev);
	fz_buffer *buffer = fz_new_buffer_from_stext_page(ctx, text);
	fz_drop_stext_page(ctx, text);
	return buffer;
}

static void raster(fz_context *ctx, fz_page *page, int callbacks, unsigned char digest[16])
{
	fz_pixmap *pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), fz_round_rect(fz_bound_page(ctx, page)), NULL, 0);
	fz_clear_pixmap_with_value(ctx, pix, 255);
	fz_device *dev = fz_new_draw_device(ctx, fz_identity, pix);
	if (callbacks)
	{
		dev->begin_structure = begin;
		dev->end_structure = end;
	}
	fz_run_page_contents(ctx, page, dev, fz_identity, NULL);
	fz_close_device(ctx, dev);
	fz_drop_device(ctx, dev);
	fz_md5_pixmap(ctx, pix, digest);
	fz_drop_pixmap(ctx, pix);
}

static int equal(fz_context *ctx, fz_buffer *a, fz_buffer *b)
{
	unsigned char *ap, *bp;
	size_t an = fz_buffer_storage(ctx, a, &ap), bn = fz_buffer_storage(ctx, b, &bp);
	return an == bn && !memcmp(ap, bp, an);
}

static int check_layout(fz_context *ctx, fz_document *doc, float w, float h, float em)
{
	fz_layout_document(ctx, doc, w, h, em);
	int pages = fz_count_pages(ctx, doc);
	fz_buffer *all = fz_new_buffer(ctx, 1024), *structured = fz_new_buffer(ctx, 1024);
	for (int p = 0; p < pages; p++)
	{
		fz_page *page = fz_load_page(ctx, doc, p);
		fz_buffer *plain = extract(ctx, page, 0, 0);
		for (int callbacks = 1; callbacks <= 3; callbacks++)
		{
			fz_buffer *reference = extract(ctx, page, callbacks, 0);
			if (!equal(ctx, plain, reference)) { fprintf(stderr, "text mismatch page=%d callbacks=%d\n", p, callbacks); return 1; }
			fz_drop_buffer(ctx, reference);
		}
		fz_append_buffer(ctx, all, plain);
		fz_drop_buffer(ctx, plain);
		fz_buffer *tags = extract(ctx, page, 0, 1);
		fz_append_buffer(ctx, structured, tags);
		fz_drop_buffer(ctx, tags);
		unsigned char fast[16], reference[16];
		raster(ctx, page, 0, fast);
		raster(ctx, page, 1, reference);
		if (memcmp(fast, reference, sizeof(fast))) { fprintf(stderr, "raster mismatch page=%d\n", p); return 2; }
		fz_drop_page(ctx, page);
	}
	const char *plain = fz_string_from_buffer(ctx, all), *tags = fz_string_from_buffer(ctx, structured);
	for (int i = 0; i < 300; i++)
	{
		char needle[16]; snprintf(needle, sizeof(needle), "ITEM%04d", i);
		if (!strstr(plain, needle) || !strstr(tags, needle)) { fprintf(stderr, "missing %s layout=%gx%g@%g\n", needle, w, h, em); return 3; }
	}
	for (const char **word = (const char *[]){"PADDED", "FLOAT", "CELL", "TAIL", NULL}; *word; word++)
		if (!strstr(plain, *word) || !strstr(tags, *word)) return 4;
	printf("layout=%gx%g@%g pages=%d text+raster+structure OK\n", w, h, em, pages);
	fz_drop_buffer(ctx, all);
	fz_drop_buffer(ctx, structured);
	return 0;
}

int main(void)
{
	fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
	fz_register_document_handlers(ctx);
	fz_buffer *input = fz_new_buffer(ctx, 16384);
	fz_append_string(ctx, input, "<html><body><h1>START</h1>");
	for (int i = 0; i < 300; i++)
	{
		if (i == 63) fz_append_string(ctx, input, "<div style='padding-top:400px;border:2px solid red'><p>PADDED</p></div>");
		if (i == 130) fz_append_string(ctx, input, "<p style='float:right'>FLOAT</p><table><tr><td>CELL</td></tr></table>");
		fz_append_printf(ctx, input, "<p%s>ITEM%04d alpha beta gamma delta.</p>", i == 170 ? " style='margin-top:-200px'" : "", i);
	}
	fz_append_string(ctx, input, "<h2>TAIL</h2></body></html>");
	fz_stream *stream = fz_open_buffer(ctx, input);
	fz_document *doc = fz_open_document_with_stream(ctx, "text/html", stream);
	int result = check_layout(ctx, doc, 300, 400, 12);
	if (!result) result = check_layout(ctx, doc, 450, 260, 17);
	if (!result) result = check_layout(ctx, doc, 300, 400, 12);
	if (!begins || begins != ends) result = 5;
	// Story uses restarted layout and must retain the complete ordered content.
	fz_buffer *story_input = fz_new_buffer(ctx, 8192);
	for (int i = 0; i < 300; i++) fz_append_printf(ctx, story_input, "<p>STORY%04d alpha beta gamma.</p>", i);
	fz_story *story = fz_new_story(ctx, story_input, NULL, 12, NULL);
	fz_buffer *story_text = fz_new_buffer(ctx, 8192);
	int more = 1, steps = 0;
	while (more && steps++ < 300)
	{
		fz_rect filled;
		more = fz_place_story(ctx, story, fz_make_rect(0, 0, 300, 200), &filled);
		fz_stext_page *text = fz_new_stext_page(ctx, filled);
		fz_device *dev = fz_new_stext_device(ctx, text, NULL);
		fz_draw_story(ctx, story, dev, fz_identity);
		fz_close_device(ctx, dev);
		fz_drop_device(ctx, dev);
		fz_buffer *part = fz_new_buffer_from_stext_page(ctx, text);
		fz_append_buffer(ctx, story_text, part);
		fz_drop_buffer(ctx, part);
		fz_drop_stext_page(ctx, text);
	}
	const char *text = fz_string_from_buffer(ctx, story_text);
	for (int i = 0; i < 300; i++) { char needle[16]; snprintf(needle, sizeof(needle), "STORY%04d", i); if (!strstr(text, needle)) result = 6; }
	if (more) result = 7;
	printf("story steps=%d complete=%d callbacks begin=%d end=%d\n", steps, !more, begins, ends);
	fz_drop_buffer(ctx, story_text);
	fz_drop_story(ctx, story);
	fz_drop_buffer(ctx, story_input);
	fz_drop_document(ctx, doc);
	fz_drop_stream(ctx, stream);
	fz_drop_buffer(ctx, input);
	fz_drop_context(ctx);
	return result;
}
