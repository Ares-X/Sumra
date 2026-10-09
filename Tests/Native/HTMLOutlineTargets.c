/* Native HTML outline behavior, independent of the temporary query layout.
 * The executable is an internal regression fixture, not a product interface. */
#include "html-imp.h"
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(fz_context *ctx, int condition, const char *message)
{
	if (!condition)
		fz_throw(ctx, FZ_ERROR_GENERIC, "%s", message);
}

static void append_string(fz_context *ctx, fz_buffer *buffer, const char *value)
{
	int is_null = value == NULL;
	size_t length = value ? strlen(value) : 0;
	fz_append_data(ctx, buffer, &is_null, sizeof(is_null));
	fz_append_data(ctx, buffer, &length, sizeof(length));
	if (length)
		fz_append_data(ctx, buffer, value, length);
}

static int check_outline(fz_context *ctx, fz_document *doc, fz_outline *node, fz_buffer *snapshot)
{
	int count = 0;
	for (; node; node = node->next)
	{
		fz_link_dest expected = fz_resolve_link_dest(ctx, doc, node->uri);
		require(ctx, node->page.chapter == expected.loc.chapter && node->page.page == expected.loc.page,
			"outline page differs from the single URI resolver");
		require(ctx, !memcmp(&node->x, &expected.x, sizeof(node->x)) &&
			!memcmp(&node->y, &expected.y, sizeof(node->y)),
			"outline coordinates differ from the single URI resolver");
		fz_append_byte(ctx, snapshot, 'N');
		append_string(ctx, snapshot, node->title);
		append_string(ctx, snapshot, node->uri);
		fz_append_data(ctx, snapshot, &node->page, sizeof(node->page));
		fz_append_data(ctx, snapshot, &node->x, sizeof(node->x));
		fz_append_data(ctx, snapshot, &node->y, sizeof(node->y));
		fz_append_byte(ctx, snapshot, '[');
		count += 1 + check_outline(ctx, doc, node->down, snapshot);
		fz_append_byte(ctx, snapshot, ']');
	}
	fz_append_byte(ctx, snapshot, 'E');
	return count;
}

static int buffers_equal(fz_context *ctx, fz_buffer *a, fz_buffer *b)
{
	unsigned char *ap, *bp;
	size_t an = fz_buffer_storage(ctx, a, &ap), bn = fz_buffer_storage(ctx, b, &bp);
	return an == bn && !memcmp(ap, bp, an);
}

static void check_document(void)
{
	static const char *source =
		"<html><body>"
		"<div><h1 id='negative' style='margin-top:-900px'>NEGATIVE FIRST</h1>"
		"<h2 id='negative'>SAME LEVEL DUPLICATE</h2></div>"
		"<h1 id='negative'>OUTER DUPLICATE</h1>"
		"<h1 id='duplicate'>FIRST BOX</h1><p><a id='duplicate'></a>FLOW DUPLICATE</p>"
		"<h2 id='duplicate'>LATER BOX</h2>"
		"<p><a id='flow-first'></a>FLOW ANCHOR TEXT</p><h2 id='flow-first'>FLOW TARGET HEADING</h2>"
		"<div style='display:none'><h3 id='hidden'>HIDDEN HEADING</h3></div>"
		"<h2 id='hidden'>VISIBLE SAME ID</h2><h2 id=''>EMPTY FRAGMENT</h2>"
		"<section><h2>GENERATED NESTED HEADING</h2><section><h3 id='nested'>INNER HEADING</h3>"
		"<p><a href='#missing'>MISSING LINK</a><a href='#duplicate'>DUPLICATE LINK</a></p>"
		"</section></section><h1 id='empty'></h1><p>TAIL</p>"
		"</body></html>";
	static const fz_htdoc_format format = { "HTML", NULL, 0, 1, FZ_HTML_FLAVOR_DEFAULT };
	static const struct { float w, h, em; const char *css; } layouts[] = {
		{ 300, 400, 12, "body{line-height:1.25;}" },
		{ 450, 260, 19, "@page{margin:25pt;} body{line-height:1.8;font-family:serif;}" },
		{ 300, 400, 12, "body{line-height:1.25;}" }
	};
	fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
	fz_document *doc = NULL;
	fz_buffer *input = NULL, *first = NULL, *snapshot = NULL;
	fz_outline *outline = NULL;
	int initial_pages = 0, initial_headings = 0, failed = 0;
	fz_var(doc); fz_var(input); fz_var(first); fz_var(snapshot); fz_var(outline); fz_var(failed);
	if (!ctx)
		abort();
	fz_try(ctx)
	{
		input = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)source, strlen(source));
		doc = fz_htdoc_open_document_with_buffer(ctx, NULL, fz_keep_buffer(ctx, input), &format);
		for (int i = 0; i < 3; ++i)
		{
			fz_style_document(ctx, doc, 1, layouts[i].css);
			fz_layout_document(ctx, doc, layouts[i].w, layouts[i].h, layouts[i].em);
			int pages = fz_count_pages(ctx, doc);
			outline = fz_load_outline(ctx, doc);
			snapshot = fz_new_buffer(ctx, 1024);
			int headings = check_outline(ctx, doc, outline, snapshot);
			require(ctx, pages > 0 && headings > 0, "HTML fixture has no pages or headings");
			if (i == 0)
			{
				initial_pages = pages;
				initial_headings = headings;
				first = fz_keep_buffer(ctx, snapshot);
			}
			if (i == 2)
				require(ctx, pages == initial_pages && headings == initial_headings && buffers_equal(ctx, first, snapshot),
					"CSS and layout restoration changed the complete outline tree");
			require(ctx, fz_resolve_link_dest(ctx, doc, "#missing").loc.page < 0 &&
				fz_resolve_link_dest(ctx, doc, "#").loc.page < 0, "absent/empty fragment unexpectedly resolves");
			printf("document layout=%gx%g@%g pages=%d headings=%d single URI equivalence OK\n",
				layouts[i].w, layouts[i].h, layouts[i].em, pages, headings);
			fz_drop_outline(ctx, outline); outline = NULL;
			fz_drop_buffer(ctx, snapshot); snapshot = NULL;
		}
	}
	fz_always(ctx)
	{
		fz_drop_outline(ctx, outline);
		fz_drop_buffer(ctx, snapshot);
		fz_drop_buffer(ctx, first);
		fz_drop_document(ctx, doc);
		fz_drop_buffer(ctx, input);
	}
	fz_catch(ctx)
	{
		fprintf(stderr, "document fixture failed: %s\n", fz_caught_message(ctx));
		fz_report_error(ctx); failed = 1;
	}
	fz_drop_context(ctx);
	if (failed)
		exit(1);
}

typedef union { max_align_t alignment; struct { size_t size; } data; } allocation;
typedef struct { size_t count, bytes; int refuse, refusals; } tracking;

static void *tracked_alloc(void *state, size_t size)
{
	tracking *t = state;
	if (t->refuse) { ++t->refusals; return NULL; }
	allocation *a = malloc(sizeof(*a) + size);
	if (!a) return NULL;
	a->data.size = size; ++t->count; t->bytes += size;
	return a + 1;
}

static void tracked_free(void *state, void *ptr)
{
	if (!ptr) return;
	tracking *t = state;
	allocation *a = (allocation *)ptr - 1;
	--t->count; t->bytes -= a->data.size; free(a);
}

static void *tracked_realloc(void *state, void *ptr, size_t size)
{
	if (!ptr) return tracked_alloc(state, size);
	if (!size) { tracked_free(state, ptr); return NULL; }
	tracking *t = state;
	if (t->refuse) { ++t->refusals; return NULL; }
	allocation *a = (allocation *)ptr - 1;
	size_t old = a->data.size;
	a = realloc(a, sizeof(*a) + size);
	if (!a) return NULL;
	a->data.size = size; t->bytes = t->bytes - old + size;
	return a + 1;
}

typedef struct { fz_html *html; int calls, throw_on_callback; } target_check;

static void check_target(fz_context *ctx, void *state, fz_outline *outline, float y)
{
	target_check *check = state;
	++check->calls;
	if (check->throw_on_callback)
		fz_throw(ctx, FZ_ERROR_GENERIC, "intentional outline callback failure");
	const char *fragment = outline->uri ? strchr(outline->uri, '#') : NULL;
	float expected = fragment && fragment[1] ? fz_find_html_target(ctx, check->html, fragment + 1) : -1;
	require(ctx, !memcmp(&y, &expected, sizeof(y)), "bulk target differs from original target traversal");
}

static void check_targets_and_lifetime(void)
{
	tracking t = {0};
	fz_alloc_context allocator = { &t, tracked_alloc, tracked_realloc, tracked_free };
	fz_context *ctx = fz_new_context(&allocator, NULL, FZ_STORE_DEFAULT);
	if (!ctx) abort();
	fz_html html = {0};
	fz_html_box root = {0}, other_root = {0}, scope[2] = {{0}}, negative[3] = {{0}}, nan_boxes[3] = {{0}};
	fz_html_box text_box = {0}, image_box = {0}, anchor[2] = {{0}}, plain[2] = {{0}}, zero = {0};
	fz_html_flow text[2] = {{0}}, image[2] = {{0}};
	/* These literal fixtures borrow stable stack storage through the same
	 * full-pointer directories used by a document-owned flow graph. */
	void *box_directory[] = { NULL, &anchor[0], &anchor[1], &plain[0], &plain[1] };
	void *flow_escape[] = { &text[1], &image[1] };
	html.tree.box_directory = box_directory;
	html.tree.box_count = 4;
	html.tree.box_capacity = 5;
	html.tree.flow_escape = flow_escape;
	html.tree.flow_escape_count = html.tree.flow_escape_capacity = 2;
	root.type = other_root.type = BOX_BLOCK;
	root.id = other_root.id = "root-negative"; root.s.layout.y = -7; other_root.s.layout.y = 700;
	root.next = &other_root; root.down = &scope[0]; html.tree.root = &root;
	scope[0].type = scope[1].type = BOX_BLOCK;
	scope[0].down = &negative[0]; scope[0].next = &negative[2]; negative[2].next = &scope[1];
	scope[1].down = &nan_boxes[0]; scope[1].next = &nan_boxes[2]; nan_boxes[2].next = &text_box;
	for (int i = 0; i < 3; ++i)
	{
		negative[i].type = nan_boxes[i].type = BOX_BLOCK;
		negative[i].id = "negative"; nan_boxes[i].id = "nan";
	}
	negative[0].next = &negative[1]; negative[0].s.layout.y = -50;
	negative[1].s.layout.y = 17; negative[2].s.layout.y = 120;
	nan_boxes[0].next = &nan_boxes[1]; nan_boxes[0].s.layout.y = NAN;
	nan_boxes[1].s.layout.y = 19; nan_boxes[2].s.layout.y = 130;
	text_box.type = image_box.type = BOX_FLOW;
	text_box.u.flow.head = text; text_box.next = &image_box;
	image_box.u.flow.head = image; image_box.next = &zero;
	zero.type = BOX_BLOCK; zero.id = "zero";
	for (int i = 0; i < 2; ++i)
	{
		anchor[i].type = plain[i].type = BOX_INLINE;
		anchor[i].index = (uint32_t)i + 1;
		plain[i].index = (uint32_t)i + 3;
		text[i].box_index = i ? 3 : 1;
		image[i].box_index = i ? 4 : 2;
	}
	anchor[0].id = "text-anchor"; anchor[1].id = "image-anchor";
	text[0].type = image[0].type = FLOW_ANCHOR;
	text[0].next_ref = HTML_FLOW_ESCAPE_BIT;
	image[0].next_ref = HTML_FLOW_ESCAPE_BIT | 1;
	text[1].type = FLOW_WORD; text[1].y = 100;
	text[1].compact_height_phase = HTML_SPACE_HEIGHT_LAID_OUT;
	plain[0].s.layout.em = 20;
	image[1].type = FLOW_IMAGE; image[1].y = 222;
	const char *uris[] = { "#negative", "#nan", "#root-negative", "#text-anchor", "#image-anchor", "#missing", "#", "#zero", "#negative" };
	fz_outline outlines[sizeof(uris) / sizeof(uris[0])];
	memset(outlines, 0, sizeof(outlines));
	int count = (int)(sizeof(outlines) / sizeof(outlines[0]));
	for (int i = 0; i < count; ++i)
	{
		outlines[i].uri = (char *)uris[i];
		outlines[i].next = i + 1 < count ? &outlines[i + 1] : NULL;
	}
	target_check check = { &html, 0, 0 };
	int failed = 0;
	fz_var(t); fz_var(check);
	fz_var(failed);
	fz_try(ctx)
	{
		require(ctx, fz_find_html_target(ctx, &html, "negative") == 120 &&
			fz_find_html_target(ctx, &html, "nan") == 130 &&
			fz_find_html_target(ctx, &html, "root-negative") == -7,
			"synthetic tree does not exercise layer-sensitive early returns");
		for (int pass = 0; pass < 3; ++pass)
		{
			size_t before_count = t.count, before_bytes = t.bytes;
			int caught = 0, refusals = t.refusals;
			fz_var(caught);
			check.calls = 0;
			t.refuse = pass == 0;
			check.throw_on_callback = pass == 1;
			fz_try(ctx)
				fz_resolve_html_outline_targets(ctx, &html, outlines, check_target, &check);
			fz_catch(ctx)
			{
				caught = 1;
				printf("target operation pass=%d propagated cause=%s\n", pass, fz_caught_message(ctx));
				fz_report_error(ctx);
			}
			t.refuse = 0; check.throw_on_callback = 0;
			require(ctx, caught == (pass < 2), "unexpected target-operation exception outcome");
			require(ctx, pass != 0 || (t.refusals > refusals && check.calls == 0), "allocation failure did not precede callbacks");
			require(ctx, pass != 1 || check.calls == 1, "callback exception was not propagated immediately");
			require(ctx, pass != 2 || check.calls == count, "not all outline targets were updated");
			require(ctx, t.count == before_count && t.bytes == before_bytes, "temporary target allocations survived operation");
			printf("target operation pass=%d baseline allocations restored; callbacks=%d\n", pass, check.calls);
		}
		check.calls = 0;
		fz_resolve_html_outline_targets(ctx, &html, NULL, check_target, &check);
		require(ctx, check.calls == 0, "empty outline invoked callback");
	}
	fz_catch(ctx)
	{
		fprintf(stderr, "target fixture failed: %s\n", fz_caught_message(ctx));
		fz_report_error(ctx); failed = 1;
	}
	fz_drop_context(ctx);
	if (failed) exit(2);
	puts("synthetic target semantics, allocation failure and callback lifetime OK");
}

int main(void)
{
	check_document();
	check_targets_and_lifetime();
	return 0;
}
