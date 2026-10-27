// HTML shaping must ignore the transform left on a shared FreeType face by rendering.
#include "mupdf/fitz.h"
#include "mupdf/ucdn.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int check_layout(fz_context *ctx, const char *path, float width, float height)
{
	fz_document *doc = NULL;
	fz_font *font;
	FT_Face face;
	FT_Matrix transformed = { 32768, 0, 0, 65536 }, actual;
	FT_Vector shifted = { 128, 0 }, delta;
	int pages = 0;
	int ok = 0;
	fz_var(doc);
	fz_try(ctx)
	{
		doc = fz_open_document(ctx, path);
		fz_style_document(ctx, doc, 1, "body{line-height:1.6 !important}");
		fz_layout_document(ctx, doc, width, height, 17);
		font = fz_load_fallback_font(ctx, UCDN_SCRIPT_HAN, FZ_LANG_zh_Hans, 1, 0, 0);
		face = fz_font_ft_face(ctx, font);
		fz_hb_lock(ctx);
		FT_Set_Transform(face, &transformed, &shifted);
		fz_hb_unlock(ctx);
		pages = fz_count_chapter_pages(ctx, doc, 0);
		fz_hb_lock(ctx);
		FT_Get_Transform(face, &actual, &delta);
		fz_hb_unlock(ctx);
		ok = pages > 1 && actual.xx == 65536 && actual.xy == 0 && actual.yx == 0 && actual.yy == 65536 && delta.x == 0 && delta.y == 0;
	}
	fz_always(ctx)
		fz_drop_document(ctx, doc);
	fz_catch(ctx)
	{
		fz_report_error(ctx);
		return 0;
	}
	if (!ok)
		fprintf(stderr, "HTML shaping retained a raster transform (%g x %g, %d pages)\n", width, height, pages);
	return ok;
}

int main(void)
{
	char path[] = "/private/tmp/Sumra-html-font-transform-XXXXXX.xhtml";
	int descriptor = mkstemps(path, 6);
	if (descriptor < 0) return 2;
	FILE *file = fdopen(descriptor, "w");
	if (!file) { close(descriptor); unlink(path); return 2; }
	fputs("<html lang='zh'><head><meta charset='utf-8'/></head><body><p>", file);
	for (int i = 0; i < 120; ++i)
		fputs("女主走过山川河流，回到安静的街道。女主拿起书，慢慢翻开新的一页。", file);
	fputs("</p></body></html>", file);
	fclose(file);
	fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
	if (!ctx) { unlink(path); return 2; }
	fz_register_document_handlers(ctx);
	int ok = check_layout(ctx, path, 300, 210) && check_layout(ctx, path, 440, 280);
	fz_drop_context(ctx);
	unlink(path);
	if (ok) puts("HTML font transform reset: passed");
	return ok ? 0 : 1;
}
