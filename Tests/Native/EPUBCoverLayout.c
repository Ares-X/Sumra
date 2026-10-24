// Regression against issue #31's reporter EPUBs, supplied as test-only arguments.
#include "mupdf/fitz.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int ok, const char *message, const char *path, float w, float h) {
    if (!ok) { fprintf(stderr, "FAIL %s %.0fx%.0f: %s\n", path, w, h, message); ++failures; }
}

static void zip_text(fz_context *ctx, fz_zip_writer *zip, const char *name, const char *source) {
    fz_buffer *buffer = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)source, strlen(source));
    fz_write_zip_entry(ctx, zip, name, buffer, 1);
    fz_drop_buffer(ctx, buffer);
}

// These generated EPUBs distinguish resource declarations from filenames/classes.
// Every mode uses the same unrelated chapter id and canonicalized image reference.
static fz_document *declared_cover(fz_context *ctx, int mode) {
    fz_buffer *buffer = fz_new_buffer(ctx, 1024);
    fz_zip_writer *zip = fz_new_zip_writer_with_output(ctx, fz_new_output_with_buffer(ctx, buffer));
    zip_text(ctx, zip, "mimetype", "application/epub+zip");
    zip_text(ctx, zip, "META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='OPS/package.opf' media-type='application/oebps-package+xml'/></rootfiles></container>");
    const char *metadata = mode == 0 || mode == 6 ? "<meta name='cover' content='art-resource'/>" : mode == 7 ? "<meta name='cover' content='other-resource'/>" : "";
    const char *properties = mode == 1 ? " properties='cover-image'" : "";
    const char *guide = mode == 2 || mode == 9 ? "<guide><reference type='cover' href='art/cover.png'/></guide>" : mode == 4 ? "<guide><reference type='cover' href='chapters/presentation.xhtml#cover-target'/></guide>" : "";
    const char *spine = mode == 7 || mode == 10 ? "<itemref idref='front'/><itemref idref='presentation'/>" : mode == 11 ? "<itemref idref='front' linear='no'/><itemref idref='presentation'/>" : "<itemref idref='presentation'/>";
    char package[4096];
    snprintf(package, sizeof package,
        "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata>%s</metadata><manifest>"
        "<item id='presentation' href='chapters/presentation.xhtml' media-type='application/xhtml+xml'/>"
        "<item id='front' href='chapters/front.xhtml' media-type='application/xhtml+xml'/>"
        "<item id='body' href='chapters/body.xhtml' media-type='application/xhtml+xml'/>"
        "<item id='art-resource' href='art/cover.png' media-type='image/png'%s/>"
        "<item id='other-resource' href='art/other.png' media-type='image/png'/>"
        "<item id='navigation' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>"
        "<item id='ncx' href='toc.ncx' media-type='application/x-dtbncx+xml'/>"
        "</manifest><spine toc='ncx'>%s<itemref idref='body'/></spine>%s</package>", metadata, properties, spine, guide);
    zip_text(ctx, zip, "OPS/package.opf", package);
    zip_text(ctx, zip, "OPS/chapters/front.xhtml", mode == 11 ?
        "<html xmlns='http://www.w3.org/1999/xhtml'><body><img style='width:20px;height:40px' src='../art/cover.png'/></body></html>" :
        "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>Authored first linear title page</p></body></html>");
    zip_text(ctx, zip, "OPS/toc.ncx", "<ncx><navMap><navPoint><navLabel><text>NCX outline</text></navLabel><content src='chapters/presentation.xhtml'/></navPoint></navMap></ncx>");
    zip_text(ctx, zip, "OPS/nav.xhtml", mode == 3 ?
        "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><ol><li><a href='chapters/presentation.xhtml'>Nav outline</a></li></ol></nav><nav epub:type='landmarks'><ol><li><a epub:type='cover' href='chapters/presentation.xhtml#cover-target'>Cover</a></li></ol></nav></body></html>" :
        "<html xmlns='http://www.w3.org/1999/xhtml'><body/></html>");
    zip_text(ctx, zip, "OPS/chapters/presentation.xhtml", mode == 8 ?
        "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>@page{margin:0}body{margin:0;padding:0}h1{margin:0;text-align:center}div{width:33%;margin-left:33.5%}img{width:100%;height:auto}</style></head><body><h1>1</h1><div><img src='../art/cov%65r.png'/></div></body></html>" : mode == 9 ?
        "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>@page{margin:40px}body{margin:30px}</style></head><body><div id='cover-target'><svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='20' height='40' viewBox='0 0 600 900'><image width='600' height='900' xlink:href='../art/cov%65r.png'/></svg></div></body></html>" :
        mode == 6 ?
        "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>@page{margin:40px}body{margin:30px}img{width:20px;height:40px}</style></head><body><p>Authored title</p><div id='cover-target'><img src='../art/cov%65r.png'/></div></body></html>" :
        "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>@page{margin:40px}body{margin:30px}img{width:20px;height:40px}</style></head><body><div id='cover-target'><img src='../art/cov%65r.png'/></div></body></html>");
    fz_buffer *body = fz_new_buffer(ctx, 1024);
    fz_append_string(ctx, body, "<html xmlns='http://www.w3.org/1999/xhtml'><body><p id='body-anchor'>Ordinary chapter</p>");
    for (int paragraph = 0; paragraph < 120; ++paragraph)
        fz_append_printf(ctx, body, "<p>Paragraph %d has ordinary flowing text that must keep its requested pagination.</p>", paragraph);
    fz_append_string(ctx, body, "</body></html>");
    fz_write_zip_entry(ctx, zip, "OPS/chapters/body.xhtml", body, 1);
    fz_drop_buffer(ctx, body);
    int image_width = mode == 12 ? 600 : mode == 13 ? 300 : 2;
    int image_height = mode == 12 ? 300 : mode == 13 ? 600 : 3;
    fz_pixmap *pixmap = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), fz_make_irect(0, 0, image_width, image_height), NULL, 0);
    fz_clear_pixmap_with_value(ctx, pixmap, 128);
    fz_buffer *png = fz_new_buffer_from_pixmap_as_png(ctx, pixmap, fz_default_color_params);
    fz_write_zip_entry(ctx, zip, "OPS/art/cover.png", png, 0);
    fz_write_zip_entry(ctx, zip, "OPS/art/other.png", png, 0);
    fz_drop_buffer(ctx, png); fz_drop_pixmap(ctx, pixmap);
    fz_close_zip_writer(ctx, zip); fz_drop_zip_writer(ctx, zip);
    fz_stream *stream = fz_open_buffer(ctx, buffer);
    fz_document *doc = fz_open_document_with_stream(ctx, "application/epub+zip", stream);
    fz_drop_stream(ctx, stream); fz_drop_buffer(ctx, buffer);
    return doc;
}

static void declared_cover_regressions(fz_context *ctx) {
    for (int mode = 0; mode < 14; ++mode) {
        int before = failures;
        fz_document *doc = declared_cover(ctx, mode);
        const char *name = (const char *[]){"EPUB2 image metadata", "EPUB3 cover-image", "guide image", "landmark with NCX", "guide chapter", "undeclared image", "text plus cover image", "different declared resource", "percentage box", "SVG guide image", "later undeclared image", "first linear after nonlinear image", "landscape 2:1 cover", "portrait 1:2 cover"}[mode];
        const float sizes[][2] = {{720,480}, {360,480}, {480,720}, {360,0}};
        for (int size = 0; size < 4; ++size) {
            float w = sizes[size][0], h = sizes[size][1];
            if (mode == 8 && h) h = 720; // Keep height fitting separate from horizontal percentage sizing.
            if (h) fz_layout_document(ctx, doc, w, h, 17);
            else fz_layout_document_continuous(ctx, doc, w, 17);
            int chapter = mode == 7 || mode == 10 || mode == 11 ? 1 : 0;
            fz_page *page = fz_load_chapter_page(ctx, doc, chapter, 0);
            fz_rect canvas = fz_bound_page(ctx, page);
            fz_stext_options options = {0}; options.flags = FZ_STEXT_PRESERVE_IMAGES;
            fz_stext_page *text = fz_new_stext_page_from_page(ctx, page, &options);
            int images = 0;
            for (fz_stext_block *b = text->first_block; b; b = b->next) {
                if (b->type != FZ_STEXT_BLOCK_IMAGE) continue;
                ++images;
                fz_rect r = b->bbox;
                float width = r.x1-r.x0, height = r.y1-r.y0;
                printf("GENERATED-GEOMETRY %s %.0fx%.0f source=%dx%d image=[%.3f,%.3f,%.3f,%.3f]\n",
                    name,w,h,b->u.i.image->w,b->u.i.image->h,r.x0,r.y0,r.x1,r.y1);
                if (mode == 8) {
                    check(fabsf(width-w*.33f) < .02f && fabsf((r.x0+r.x1)/2-w/2) < .02f,
                        "percentage width and margin must use the same containing block", name, w, h);
                } else if (mode == 6 || mode == 7 || mode == 10) {
                    check(width < 40 && height < 50, "later undeclared, unrelated and text pages must retain authored sizing", name, w, h);
                } else {
                    check(fz_count_chapter_pages(ctx, doc, chapter) == 1, "recognized cover must occupy one page", name, w, h);
                    check(fabsf(width/height-(mode == 12 ? 2.f : mode == 13 ? .5f : 2.f/3)) < .002f, "declared cover must preserve image ratio", name, w, h);
                    check(fabsf((r.x0+r.x1-canvas.x0-canvas.x1)/2) < .02f && fabsf((r.y0+r.y1-canvas.y0-canvas.y1)/2) < .02f,
                        "declared cover must center on its complete canvas", name, w, h);
                    check(fabsf(width-(canvas.x1-canvas.x0)) < .02f && fabsf(height-(canvas.y1-canvas.y0)) < .02f,
                        "normalized cover must fill its intrinsic canvas in both dimensions", name, w, h);
                    fz_link_dest target = fz_resolve_link_dest(ctx, doc, "OPS/chapters/presentation.xhtml#cover-target");
                    check(target.loc.chapter == chapter && target.loc.page == 0, "cover normalization must preserve fragment identity", name, w, h);
                }
            }
            check(images == 1, "fixture must render one image", name, w, h);
            fz_drop_stext_page(ctx, text); fz_drop_page(ctx, page);
            if (mode == 11) {
                page = fz_load_chapter_page(ctx, doc, 0, 0);
                text = fz_new_stext_page_from_page(ctx, page, &options);
                for (fz_stext_block *b = text->first_block; b; b = b->next)
                    if (b->type == FZ_STEXT_BLOCK_IMAGE)
                        check(b->bbox.x1-b->bbox.x0 < 40 && b->bbox.y1-b->bbox.y0 < 50,
                            "a preceding nonlinear image page must retain authored sizing", name, w, h);
                fz_drop_stext_page(ctx, text); fz_drop_page(ctx, page);
            }
        }
        if (mode == 3) {
            fz_outline *outline = fz_load_outline(ctx, doc);
            check(outline && !strcmp(outline->title, "NCX outline"), "cover landmark parsing must preserve the NCX outline", name, 0, 0);
            fz_drop_outline(ctx, outline);
        }
        fz_drop_document(ctx, doc);
        printf("GENERATED %s failures=%d\n", name, failures-before);
    }
}

// Native page geometry stays intrinsic while the reader moves between one
// full-width row, two half-width pages, and natural continuous chapters.
static void cover_canvas_transitions(fz_context *ctx) {
    fz_document *cover = declared_cover(ctx, 12), *reference = declared_cover(ctx, 6);
    const float layouts[][2] = {{720,480}, {360,480}, {360,0}, {480,720}, {360,480}};
    for (int layout = 0; layout < 5; ++layout) {
        float w = layouts[layout][0], h = layouts[layout][1];
        if (h) { fz_layout_document(ctx, cover, w,h,17); fz_layout_document(ctx, reference,w,h,17); }
        else { fz_layout_document_continuous(ctx,cover,w,17); fz_layout_document_continuous(ctx,reference,w,17); }
        fz_page *page = fz_load_chapter_page(ctx,cover,0,0);
        fz_rect canvas = fz_bound_page(ctx,page);
        check(fabsf((canvas.x1-canvas.x0)/(canvas.y1-canvas.y0)-2) < .002f,
            "landscape cover canvas must retain intrinsic aspect through layout transitions", "cover canvas",w,h);
        float scale = fminf(720/(canvas.x1-canvas.x0),480/(canvas.y1-canvas.y0));
        check(fabsf((canvas.x1-canvas.x0)*scale-720) < .02f,
            "a full-width row must be able to fill the window width", "cover canvas",w,h);
        fz_drop_page(ctx,page);
        int a = fz_count_chapters(ctx,cover)-1, b = fz_count_chapters(ctx,reference)-1;
        int count = fz_count_chapter_pages(ctx,cover,a);
        check(count == fz_count_chapter_pages(ctx,reference,b),
            "cover geometry must not change ordinary chapter pagination", "ordinary chapter",w,h);
        for (int edge = 0; edge < 2; ++edge) {
            int index = edge ? count-1 : 0;
            fz_page *pa = fz_load_chapter_page(ctx,cover,a,index), *pb = fz_load_chapter_page(ctx,reference,b,index);
            fz_rect ra = fz_bound_page(ctx,pa), rb = fz_bound_page(ctx,pb);
            check(fabsf(ra.x1-rb.x1) < .02f && fabsf(ra.y1-rb.y1) < .02f,
                "ordinary pages must retain their requested canvas", "ordinary chapter",w,h);
            fz_stext_page *ta = fz_new_stext_page_from_page(ctx,pa,NULL), *tb = fz_new_stext_page_from_page(ctx,pb,NULL);
            fz_buffer *ba = fz_new_buffer_from_stext_page(ctx,ta), *bb = fz_new_buffer_from_stext_page(ctx,tb);
            check(!strcmp(fz_string_from_buffer(ctx,ba),fz_string_from_buffer(ctx,bb)),
                "ordinary chapter page text must remain identical", "ordinary chapter",w,h);
            fz_drop_buffer(ctx,ba);fz_drop_buffer(ctx,bb);fz_drop_stext_page(ctx,ta);fz_drop_stext_page(ctx,tb);
            fz_drop_page(ctx,pa);fz_drop_page(ctx,pb);
        }
        fz_link_dest target = fz_resolve_link_dest(ctx,cover,"OPS/chapters/body.xhtml#body-anchor");
        check(target.loc.chapter==a && target.loc.page==0,
            "ordinary chapter anchors must survive cover transitions", "ordinary chapter",w,h);
        printf("TRANSITION %.0fx%.0f cover=[%.3f,%.3f] ordinary-pages=%d\n",w,h,canvas.x1,canvas.y1,count);
    }
    fz_drop_document(ctx,cover);fz_drop_document(ctx,reference);
}


// Authored sizes and prose distinguish page art from logos and decorations.
static fz_document *image_pages(fz_context *ctx, int mode, int rtl) {
    fz_buffer *buffer = fz_new_buffer(ctx, 1024);
    fz_zip_writer *zip = fz_new_zip_writer_with_output(ctx, fz_new_output_with_buffer(ctx, buffer));
    zip_text(ctx, zip, "mimetype", "application/epub+zip");
    zip_text(ctx, zip, "META-INF/container.xml", "<container><rootfiles><rootfile full-path='package.opf' media-type='application/oebps-package+xml'/></rootfiles></container>");
    char package[2048];
    snprintf(package, sizeof package,
        "<package version='3.0'><metadata><meta name='cover' content='art0'/></metadata><manifest>"
        "<item id='front' href='front.xhtml' media-type='application/xhtml+xml'/>"
        "<item id='pages' href='pages.xhtml' media-type='application/xhtml+xml'/>"
        "<item id='art0' href='art0.png' media-type='image/png'/>"
        "<item id='art1' href='art1.png' media-type='image/png'/></manifest>"
        "<spine page-progression-direction='%s'><itemref idref='front'%s/><itemref idref='pages'/></spine>"
        "<guide><reference type='cover' href='front.xhtml'/></guide></package>", rtl ? "rtl" : "ltr", mode == 8 ? " linear='no'" : "");
    zip_text(ctx, zip, "package.opf", package);
    zip_text(ctx, zip, "front.xhtml", "<html><body><img id='front-art' src='art0.png'/></body></html>");
    const char *css = mode == 2 ? "div{width:25%}img{width:100%;height:auto}" :
        mode == 3 ? "img{max-width:25%}" : mode == 7 ? "div{max-height:25%}" :
        mode == 9 ? "img{width:20px;height:30px}" : mode == 10 ? "div{height:200px}" :
        mode == 11 ? "div{width:25%;margin-left:auto;margin-right:auto}img{width:100%}" :
        mode == 12 ? "body{text-align:center}div{display:inline-block;width:8em}img{width:100%}" :
        mode == 13 ? "div{width:25%;margin-left:auto;margin-right:0}img{width:100%}" :
        mode == 14 ? "div{width:25%;margin-left:0;margin-right:auto}img{width:100%}" : "";
    fz_buffer *html = fz_new_buffer(ctx, 1024);
    fz_append_printf(ctx, html, "<html dir='%s'><head><style>@page{margin:5px 9px}body{margin:0 5px}p{margin:17px 0}%s</style></head><body>", rtl ? "rtl" : "ltr", css);
    for (int image = 0; image < (mode == 8 ? 1 : 2); ++image) {
        if (mode == 4) fz_append_printf(ctx, html, "<p>Authored caption %d</p>", image);
        if (mode != 5 || image == 0) fz_append_string(ctx, html, "<div><p>");
        fz_append_printf(ctx, html, "<a id='art%d'/>", image);
        if (mode == 6)
            fz_append_printf(ctx, html, "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 %d %d'><image width='%d' height='%d' href='art%d.png'/></svg>", image ? 200 : 100, image ? 100 : 200, image ? 200 : 100, image ? 100 : 200, image);
        else
            fz_append_printf(ctx, html, "<img src='art%d.png'%s/>", mode == 8 ? 1 : image, mode == 1 || mode == 8 ? " width='20' height='30'" : "");
        if (mode != 5 || image == 1) fz_append_string(ctx, html, "</p></div>");
    }
    fz_append_string(ctx, html, "</body></html>");
    fz_write_zip_entry(ctx, zip, "pages.xhtml", html, 1); fz_drop_buffer(ctx, html);
    for (int image = 0; image < 2; ++image) {
        fz_pixmap *pixmap = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), fz_make_irect(0, 0, image ? 200 : 100, image ? 100 : 200), NULL, 0);
        fz_clear_pixmap_with_value(ctx, pixmap, image ? 160 : 80);
        fz_buffer *png = fz_new_buffer_from_pixmap_as_png(ctx, pixmap, fz_default_color_params);
        fz_write_zip_entry(ctx, zip, image ? "art1.png" : "art0.png", png, 0);
        fz_drop_buffer(ctx, png); fz_drop_pixmap(ctx, pixmap);
    }
    fz_close_zip_writer(ctx, zip); fz_drop_zip_writer(ctx, zip);
    fz_stream *stream = fz_open_buffer(ctx, buffer);
    fz_document *doc = fz_open_document_with_stream(ctx, "application/epub+zip", stream);
    fz_drop_stream(ctx, stream); fz_drop_buffer(ctx, buffer);
    return doc;
}

static void image_page_regressions(fz_context *ctx) {
    const char *names[] = {"unsized page art", "HTML-sized logos", "percentage wrapper", "max-width constraint", "prose and images", "inline image pair", "SVG page art", "ancestor max-height", "logo after nonlinear cover", "CSS-sized logos", "height-sized wrapper", "centered auto margins", "centered inline block", "right auto margin", "left auto margin"};
    const float sizes[][2] = {{720,480}, {360,480}, {480,720}, {1200,800}, {360,0}};
    for (int mode = 0; mode < 15; ++mode) for (int rtl = 0; rtl < 2; ++rtl) {
        int before = failures;
        fz_document *doc = image_pages(ctx, mode, rtl);
        for (int css = 0; css < 4; ++css) {
            int publisher = css != 2;
            const char *user = css == 1 ? "@page{margin:23px 31px!important}body{margin:11px!important}" :
                css == 3 ? "img,svg{width:20px!important;height:30px!important}" : NULL;
            fz_style_document(ctx, doc, publisher, user);
            for (int size = 0; size < 5; ++size) {
                float w = sizes[size][0], h = sizes[size][1];
                if (h) fz_layout_document(ctx, doc,w,h,17); else fz_layout_document_continuous(ctx,doc,w,17);
                int count = fz_count_chapter_pages(ctx,doc,1), images = 0, identities = 0;
                int art = (mode == 0 || mode == 6 || (!publisher && (mode == 2 || mode == 3 || mode == 7 || mode == 9 || mode == 10 || mode >= 11))) && css != 3;
                if (art && h) check(count == 2, "independent page art must retain one page per image",names[mode],w,h);
                for (int page = 0; page < count; ++page) {
                    fz_page *p = fz_load_chapter_page(ctx,doc,1,page);
                    fz_rect canvas = fz_bound_page(ctx,p);
                    fz_stext_options opts = {0}; opts.flags = FZ_STEXT_PRESERVE_IMAGES;
                    fz_stext_page *text = fz_new_stext_page_from_page(ctx,p,&opts);
                    for (fz_stext_block *block = text->first_block; block; block = block->next) {
                        if (block->type != FZ_STEXT_BLOCK_IMAGE) continue;
                        fz_rect r = block->bbox;
                        float width = r.x1-r.x0, height = r.y1-r.y0;
                        int identity = block->u.i.image->w > block->u.i.image->h;
                        identities |= 1 << identity; ++images;
                        if (mode != 1 && mode != 8 && mode != 9 && css != 3)
                            check(fabsf(width/height-(identity ? 2.f : .5f)) < .002f,"images must preserve their source aspect",names[mode],w,h);
                        check(r.x0 >= canvas.x0-.02f && r.y0 >= canvas.y0-.02f && r.x1 <= canvas.x1+.02f && r.y1 <= canvas.y1+.02f,
                            "an image must fit its own page without drawing on its neighbor",names[mode],w,h);
                        if (publisher && css != 3 && mode >= 11) {
                            float inset = css == 1 ? 42 : 14;
                            if (mode == 11 || mode == 12)
                                check(fabsf((r.x0+r.x1-w)/2) < .03f,"authored auto margins and inline blocks must center in their containing block",names[mode],w,h);
                            else
                                check(fabsf(mode == 13 ? r.x1-(w-inset) : r.x0-inset) < .03f,"one automatic margin must assign the remaining horizontal space",names[mode],w,h);
                            check(fabsf(width-(mode == 12 ? 136 : (w-2*inset)/4)) < .03f,"centering must preserve the authored width",names[mode],w,h);
                        }
                        if (art && h) {
                            check(fabsf((r.x0+r.x1-canvas.x0-canvas.x1)/2) < .03f && fabsf((r.y0+r.y1-canvas.y0-canvas.y1)/2) < .03f,
                                "page art must center horizontally and vertically",names[mode],w,h);
                            check(width > 150 || height > 200,"page art must grow beyond its source pixels",names[mode],w,h);
                        } else if (mode == 1 || mode == 8 || (mode == 9 && publisher) || css == 3) {
                            check(width <= 21 && height <= 31,"explicit small logos must retain authored dimensions",names[mode],w,h);
                        } else if (mode == 3 || mode == 7 || mode == 4 || mode == 5 || mode == 10) {
                            check(width <= (h ? 150 : 200)+.03f,"max constraints, prose and inline pairs must not enter page-art enlargement",names[mode],w,h);
                        }
                    }
                    fz_drop_stext_page(ctx,text); fz_drop_page(ctx,p);
                }
                check(images == (mode == 8 ? 1 : 2),"image count must be conserved across every page",names[mode],w,h);
                check(identities == (mode == 8 ? 2 : 3),"each source image identity must be retained",names[mode],w,h);
                fz_link_dest target = fz_resolve_link_dest(ctx,doc,"pages.xhtml#art0");
                check(target.loc.chapter == 1 && target.loc.page == 0,"the first image anchor must remain on its image page",names[mode],w,h);
                if (art && h) {
                    target = fz_resolve_link_dest(ctx,doc,"pages.xhtml#art1");
                    check(target.loc.chapter == 1 && target.loc.page == 1,"the second image anchor must follow its own page",names[mode],w,h);
                }
            }
        }
        fz_drop_document(ctx,doc);
        printf("PAGE-ART %s %s failures=%d\n",names[mode],rtl ? "RTL" : "LTR",failures-before);
    }
}


static void reporter_repeat_sweep(fz_context *ctx, fz_document *doc, const char *path) {
    int before = failures, placements = 0;
    const float widths[] = {360,720,1200};
    for (int width = 0; width < 3; ++width) for (int height = 0; height < 50; ++height) {
        float w = widths[width], h = 240 + height*19;
        fz_layout_document(ctx,doc,w,h,17);
        int count = fz_count_chapter_pages(ctx,doc,1), images = 0, identities = 0;
        for (int page = 0; page < count; ++page) {
            fz_page *p = fz_load_chapter_page(ctx,doc,1,page);
            fz_rect canvas = fz_bound_page(ctx,p);
            fz_stext_options opts = {0}; opts.flags = FZ_STEXT_PRESERVE_IMAGES;
            fz_stext_page *text = fz_new_stext_page_from_page(ctx,p,&opts);
            for (fz_stext_block *b = text->first_block; b; b = b->next) {
                if (b->type != FZ_STEXT_BLOCK_IMAGE) continue;
                ++images; ++placements;
                if (b->u.i.image->w == 657 && b->u.i.image->h == 850) identities |= 1;
                else if (b->u.i.image->w == 943 && b->u.i.image->h == 1200) identities |= 2;
                else check(0,"the page must use an original image resource",path,w,h);
                fz_rect r = b->bbox;
                check(r.y0 >= -.02f && r.y1 <= canvas.y1+.02f,"an image must stay on its assigned page",path,w,h);
                check(fabsf((r.x1-r.x0)/(r.y1-r.y0)-(float)b->u.i.image->w/b->u.i.image->h) < .002f,"the image must retain its source aspect",path,w,h);
            }
            fz_drop_stext_page(ctx,text);fz_drop_page(ctx,p);
        }
        check(images == 2 && identities == 3,"each of the two original images must draw exactly once across all pages",path,w,h);
    }
    printf("REPEAT-SWEEP viewports=150 placements=%d identities=300 failures=%d\n",placements,failures-before);
}

int main(int argc, char **argv) {
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    fz_register_document_handlers(ctx);
    declared_cover_regressions(ctx);
    cover_canvas_transitions(ctx);
    image_page_regressions(ctx);
    const float sizes[][2] = {{720,480}, {360,480}, {480,720}, {1200,800}, {360,0}};
    for (int a = 1; a < argc; ++a) {
        fz_document *doc = fz_open_document(ctx, argv[a]);
        for (int s = 0; s < 5; ++s) {
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
                int title_page = strstr(argv[a], "misalignedepubthirdroundA.epub") != NULL;
                check(fabsf((r.x0+r.x1-canvas.x0-canvas.x1)/2) < 0.01f &&
                    (title_page || fabsf((r.y0+r.y1-canvas.y0-canvas.y1)/2) < 0.01f),
                    "the cover or authored title page must be centered", argv[a], w, h);
                check(r.x0 >= canvas.x0-0.01f && r.y0 >= canvas.y0-0.01f &&
                    r.x1 <= canvas.x1+0.01f && r.y1 <= canvas.y1+0.01f,
                    "the whole cover must fit the page", argv[a], w, h);
                if (!title_page)
                    check(fabsf(width-(canvas.x1-canvas.x0)) < 0.01f && fabsf(height-(canvas.y1-canvas.y0)) < 0.01f,
                        "the cover must fill its intrinsic page canvas", argv[a], w, h);
                printf("GEOMETRY %s %.0fx%.0f cover-pages=%d image=[%.3f,%.3f,%.3f,%.3f]\n", argv[a], w,h,count,r.x0,r.y0,r.x1,r.y1);
            }
            check(images == 1, "the cover must render exactly one image", argv[a], w, h);
            fz_drop_stext_page(ctx, text); fz_drop_page(ctx, page);
            const char *name = strrchr(argv[a], '/'); name = name ? name+1 : argv[a];
            if (!strcmp(name,"misalignedepubthirdroundA.epub") || !strcmp(name,"misalignedepubthirdroundB.epub") || !strcmp(name,"misalignedepubthirdroundC.epub")) {
                int chapter = !strcmp(name,"misalignedepubthirdroundA.epub") ? 4 : !strcmp(name,"misalignedepubthirdroundB.epub") ? 2 : 1;
                page = fz_load_chapter_page(ctx,doc,chapter,0);
                text = fz_new_stext_page_from_page(ctx,page,&options);
                int found = 0;
                for (fz_stext_block *b = text->first_block; b; b = b->next) if (b->type == FZ_STEXT_BLOCK_IMAGE) {
                    ++found;
                    check(fabsf((b->bbox.x0+b->bbox.x1-w)/2) < .03f,"the authored ornament or logo must be centered",name,w,h);
                    if (chapter == 1)
                        check(b->bbox.x1-b->bbox.x0 <= 200.03f && b->bbox.y1-b->bbox.y0 <= 281.03f,"the publisher logo must remain small",name,w,h);
                }
                check(found == 1,"the ornament or logo must remain visible once",name,w,h);
                fz_drop_stext_page(ctx,text);fz_drop_page(ctx,page);
            }
            if (!strcmp(name,"repeat-misalignedepubsecondroundC.epub")) {
                int pages = fz_count_chapter_pages(ctx,doc,1), found = 0;
                check(pages == (h ? 4 : 1),"full-page interior art must keep each image on its page",name,w,h);
                for (int p = 0; p < pages; ++p) {
                    page = fz_load_chapter_page(ctx,doc,1,p);canvas = fz_bound_page(ctx,page);
                    text = fz_new_stext_page_from_page(ctx,page,&options);
                    for (fz_stext_block *b = text->first_block; b; b = b->next) if (b->type == FZ_STEXT_BLOCK_IMAGE) {
                        ++found;
                        check(fabsf((b->bbox.x1-b->bbox.x0)/(b->bbox.y1-b->bbox.y0)-(float)b->u.i.image->w/b->u.i.image->h) < .002f,"interior art must preserve its source aspect",name,w,h);
                        if (h)
                            check(fabsf((b->bbox.x0+b->bbox.x1-canvas.x1)/2) < .03f && fabsf((b->bbox.y0+b->bbox.y1-canvas.y1)/2) < .03f,"interior page art must center on its page",name,w,h);
                        else
                            check(fabsf((b->bbox.x1-b->bbox.x0)-fminf(b->u.i.image->w*.75f,w-78)) < .03f,"continuous art must retain its natural width within the reading column",name,w,h);
                    }
                    fz_drop_stext_page(ctx,text);fz_drop_page(ctx,page);
                }
                check(found == 4,"every original interior image must remain visible once",name,w,h);
                for (int image = 1; image <= 4; ++image) {
                    char link[32];snprintf(link,sizeof link,"index.html#p%d",image);
                    fz_link_dest dest = fz_resolve_link_dest(ctx,doc,link);
                    check(dest.loc.chapter == 1 && dest.loc.page == (h ? image-1 : 0),"interior image anchors must stay with their image",name,w,h);
                }
            }
            if (!strcmp(name, "misalignedepubsecondroundA.epub")) {
                const char *chapters[] = {"OPS/c001.xhtml", "OPS/c01.xhtml"};
                for (int c = 0; c < 2; ++c) {
                    fz_link_dest location = fz_resolve_link_dest(ctx, doc, chapters[c]);
                    page = fz_load_chapter_page(ctx, doc, location.loc.chapter, 0);
                    canvas = fz_bound_page(ctx, page);
                    text = fz_new_stext_page_from_page(ctx, page, &options);
                    int rectangles = 0;
                    for (fz_stext_block *block = text->first_block; block; block = block->next) {
                        if (block->type != FZ_STEXT_BLOCK_IMAGE) continue;
                        ++rectangles;
                        fz_rect r = block->bbox;
                        check(fabsf((r.x0+r.x1-canvas.x0-canvas.x1)/2) < .02f,
                            "the chapter rectangle must center under its heading", argv[a], w, h);
                        printf("RECTANGLE %s %s %.0fx%.0f image=[%.3f,%.3f,%.3f,%.3f]\n",
                            argv[a], chapters[c], w, h, r.x0,r.y0,r.x1,r.y1);
                    }
                    check(rectangles == 1, "the chapter rectangle must remain visible", argv[a], w, h);
                    fz_drop_stext_page(ctx, text); fz_drop_page(ctx, page);
                }
            }
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
        const char *name = strrchr(argv[a], '/'); name = name ? name+1 : argv[a];
        if (!strcmp(name,"misalignedepubthirdroundD.epub")) reporter_repeat_sweep(ctx,doc,argv[a]);
        fz_drop_document(ctx, doc);
    }
    fz_drop_context(ctx);
    printf("EPUB reporter cover geometry/caption: failures=%d\n", failures);
    return failures ? 1 : 0;
}
