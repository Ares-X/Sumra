#include "Engine.h"
#include <libdjvu/ddjvuapi.h>
#include <libdjvu/miniexp.h>
#include <CoreGraphics/CoreGraphics.h>
#include <errno.h>

typedef struct { ddjvu_context_t *ctx; ddjvu_document_t *doc; } Document;
static int messages(Document *d, char *error) {
    const ddjvu_message_t *m;
    ddjvu_message_wait(d->ctx);
    while ((m = ddjvu_message_peek(d->ctx))) {
        if (m->m_any.tag == DDJVU_ERROR) { snprintf(error, 512, "%s", m->m_error.message); ddjvu_message_pop(d->ctx); return 0; }
        ddjvu_message_pop(d->ctx);
    }
    return 1;
}
API void lf_close(Document *d) {
    if (!d) return;
    if (d->doc) ddjvu_document_release(d->doc);
    if (d->ctx) ddjvu_context_release(d->ctx);
    free(d);
}
API Document *lf_open(const char *path, char *error) {
    Document *d = calloc(1, sizeof(*d)); if (!d) return NULL;
    d->ctx = ddjvu_context_create("Sumra");
    if (!d->ctx) { lf_close(d); return NULL; }
    d->doc = ddjvu_document_create_by_filename_utf8(d->ctx, path, 1);
    if (!d->doc) { lf_close(d); return NULL; }
    while (!ddjvu_document_decoding_done(d->doc)) if (!messages(d, error)) { lf_close(d); return NULL; }
    if (ddjvu_document_decoding_error(d->doc)) { snprintf(error, 512, "DjVu decoding failed"); lf_close(d); return NULL; }
    return d;
}
API int lf_count(Document *d) { return ddjvu_document_get_pagenum(d->doc); }
API char *lf_metadata(Document *d, char *error) {
    miniexp_t annotations;
    while ((annotations = ddjvu_document_get_anno(d->doc, 1)) == miniexp_dummy) if (!messages(d, error)) return NULL;
    if (miniexp_symbolp(annotations)) { snprintf(error, 512, "Cannot read DjVu metadata"); return NULL; }
    SumraJSON json = {0}; int first = 1;
    miniexp_t *keys = ddjvu_anno_get_metadata_keys(annotations);
    lf_json(&json, "{");
    if (keys) for (int i = 0; keys[i]; ++i) {
        const char *name = miniexp_to_name(keys[i]), *value = ddjvu_anno_get_metadata(annotations, keys[i]);
        if (!name || !value) continue;
        if (!first) lf_json(&json, ","); first = 0;
        lf_json_string(&json, name); lf_json(&json, ":"); lf_json_string(&json, value);
    }
    const char *xmp = ddjvu_anno_get_xmp(annotations);
    if (xmp) { if (!first) lf_json(&json, ","); lf_json(&json, "\"XMP\":"); lf_json_string(&json, xmp); }
    lf_json(&json, "}"); free(keys); ddjvu_miniexp_release(d->doc, annotations);
    return lf_json_finish(&json, error);
}
static unsigned char *render_page(Document *d, int index, int width, const int *region, int *info, char *error) {
    ddjvu_page_t *page = ddjvu_page_create_by_pageno(d->doc, index);
    if (!page) { snprintf(error, 512, "Cannot load DjVu page"); return NULL; }
    while (!ddjvu_page_decoding_done(page)) if (!messages(d, error)) { ddjvu_page_release(page); return NULL; }
    int w = ddjvu_page_get_width(page), h = ddjvu_page_get_height(page);
    if (w <= 0 || h <= 0 || ddjvu_page_decoding_error(page)) { snprintf(error, 512, "Cannot decode DjVu page"); ddjvu_page_release(page); return NULL; }
    if(width<=0 || (!region && width>INT_MAX/3)){ddjvu_page_release(page);snprintf(error,512,"Invalid render width");return NULL;}
    double scaled=(double)h*(double)width/(double)w;if(!(scaled>0)||scaled>INT_MAX){ddjvu_page_release(page);snprintf(error,512,"Invalid page size");return NULL;}
    ddjvu_rect_t full = { 0, 0, (unsigned)width, (unsigned)ceil(scaled) }, tile = full;
    if (region) {
        if (region[0] < 0 || region[1] < 0 || region[2] <= 0 || region[2] > INT_MAX/3 || region[3] <= 0 ||
            region[0] > INT_MAX-region[2] || region[1] > INT_MAX-region[3]) {
            ddjvu_page_release(page); snprintf(error,512,"Invalid render region"); return NULL;
        }
        tile = (ddjvu_rect_t){ region[0], region[1], (unsigned)region[2], (unsigned)region[3] };
    }
    info[0]=(int)tile.w;info[1]=(int)tile.h;info[2]=info[0]*3;info[3]=3;
    if((size_t)info[1]>SIZE_MAX/(size_t)info[2]){ddjvu_page_release(page);snprintf(error,512,"Page bitmap too large");return NULL;}
    unsigned char *out=malloc((size_t)info[2]*(size_t)info[1]);
    ddjvu_format_t *format = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, NULL);
    if (!out || !format) { free(out); if (format) ddjvu_format_release(format); ddjvu_page_release(page); snprintf(error, 512, "Cannot allocate DjVu bitmap"); return NULL; }
    if (region) memset(out, 255, (size_t)info[2]*(size_t)info[1]);
    // Use DjVuLibre's bottom-up rectangle coordinates with top-down output
    // rows. Its top-down coordinate conversion adds full.h to tile.y and
    // can overflow for small regions near the end of a very large canvas.
    tile.y = (int)full.h - (tile.y + (int)tile.h);
    ddjvu_format_set_row_order(format, 1);
    int ok = ddjvu_page_render(page, DDJVU_RENDER_COLOR, &full, &tile, format, info[2], (char *)out);
    ddjvu_format_release(format); ddjvu_page_release(page);
    if (!ok) { free(out); snprintf(error, 512, "Cannot render DjVu page"); return NULL; }
    return out;
}
API unsigned char *lf_render(Document *d, int index, int width, int *info, char *error) { return render_page(d, index, width, NULL, info, error); }
// The same clipped-render ABI as MuPDF; DjVu has one chapter and opaque pages.
API unsigned char *lf_render_tile_at(Document *d, int chapter, int index, int width, const int *region, int alpha, int *info, char *error) {
    (void)chapter; (void)alpha;
    return render_page(d, index, width, region, info, error);
}

typedef struct { FILE *file; int error; } PDFOutput;
static size_t pdf_write(void *info, const void *data, size_t size) {
    PDFOutput *output = info;
    if (output->error) return 0;
    size_t written = fwrite(data, 1, size, output->file);
    if (written != size && !output->error) output->error = errno ? errno : EIO;
    return written;
}
static void pdf_release_pixels(void *info, const void *data, size_t size) {
    (void)info; (void)size; free((void *)data);
}
// Keep the original pixel grid and DPI. DjVuLibre renders each subrectangle
// directly. Target 16 MiB RGB bands, or one full row; Quartz retains them.
API int lf_export_pdf(void *document, const char *path, const int *pages, int page_count, int (*cancelled)(void), char *error) {
    Document *d = document;
    const size_t band_bytes = 16u * 1024u * 1024u;
    int result = 0, page_open = 0;
    FILE *file = NULL;
    CGDataConsumerRef consumer = NULL;
    CGContextRef context = NULL;
    CGColorSpaceRef space = NULL;
    ddjvu_format_t *format = NULL;
    ddjvu_page_t *page = NULL;
    if (cancelled && cancelled()) return -1;
    int count = ddjvu_document_get_pagenum(d->doc);
    if (pages) {
        if (page_count <= 0) { snprintf(error, 512, "Choose at least one page to export"); return 0; }
        for (int i = 0; i < page_count; ++i)
            if (pages[i] < 0 || pages[i] >= count) { snprintf(error, 512, "Page out of range"); return 0; }
    } else page_count = count;
    file = fopen(path, "wb");
    if (!file) { snprintf(error, 512, "Cannot create PDF: %s", strerror(errno)); return 0; }
    PDFOutput output = { file, 0 };
    CGDataConsumerCallbacks callbacks = { pdf_write, NULL };
    consumer = CGDataConsumerCreate(&output, &callbacks);
    if (consumer) context = CGPDFContextCreate(consumer, NULL, NULL);
    space = CGColorSpaceCreateDeviceRGB();
    format = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, NULL);
    if (!context || !space || !format) { snprintf(error, 512, "Cannot create DjVu PDF output"); goto done; }
    ddjvu_format_set_row_order(format, 1); ddjvu_format_set_y_direction(format, 1);
    for (int i = 0; i < page_count; ++i) {
        int index = pages ? pages[i] : i;
        if (cancelled && cancelled()) { result = -1; goto done; }
        page = ddjvu_page_create_by_pageno(d->doc, index);
        if (!page) { snprintf(error, 512, "Cannot load DjVu page"); goto done; }
        while (!ddjvu_page_decoding_done(page)) {
            if (cancelled && cancelled()) { result = -1; goto done; }
            if (!messages(d, error)) goto done;
        }
        int width = ddjvu_page_get_width(page), height = ddjvu_page_get_height(page);
        if (width <= 0 || height <= 0 || ddjvu_page_decoding_error(page)) {
            snprintf(error, 512, "Cannot decode DjVu page"); goto done;
        }
        size_t stride = (size_t)width * 3;
        int rows_per_band = (int)(band_bytes / stride);
        if (!rows_per_band) rows_per_band = 1;
        int dpi = ddjvu_page_get_resolution(page);
        double scale = 72.0 / (dpi > 0 ? dpi : 300);
        CGRect box = CGRectMake(0, 0, width * scale, height * scale);
        CFDataRef box_data = CFDataCreate(NULL, (const UInt8 *)&box, sizeof(box));
        const void *keys[] = { kCGPDFContextMediaBox }, *values[] = { box_data };
        CFDictionaryRef page_info = box_data ? CFDictionaryCreate(NULL, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
        if (box_data) CFRelease(box_data);
        if (!page_info) { snprintf(error, 512, "Cannot allocate PDF page information"); goto done; }
        CGPDFContextBeginPage(context, page_info); CFRelease(page_info); page_open = 1;
        CGContextSetInterpolationQuality(context, kCGInterpolationNone);
        ddjvu_rect_t full = { 0, 0, (unsigned)width, (unsigned)height };
        for (int y = 0; y < height;) {
            if (cancelled && cancelled()) { result = -1; goto done; }
            int rows = height - y < rows_per_band ? height - y : rows_per_band;
            size_t size = stride * (size_t)rows;
            unsigned char *pixels = malloc(size);
            if (!pixels) { snprintf(error, 512, "Cannot allocate DjVu pixel band"); goto done; }
            ddjvu_rect_t band = { 0, y, (unsigned)width, (unsigned)rows };
            if (!ddjvu_page_render(page, DDJVU_RENDER_COLOR, &full, &band, format, stride, (char *)pixels)) {
                free(pixels); snprintf(error, 512, "Cannot render DjVu pixel band"); goto done;
            }
            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, size, pdf_release_pixels);
            if (!provider) { free(pixels); snprintf(error, 512, "Cannot create DjVu pixel provider"); goto done; }
            CGImageRef image = CGImageCreate(width, rows, 8, 24, stride, space, kCGImageAlphaNone,
                provider, NULL, 0, kCGRenderingIntentDefault);
            CGDataProviderRelease(provider);
            if (!image) { snprintf(error, 512, "Cannot create DjVu band image"); goto done; }
            CGContextDrawImage(context, CGRectMake(0, (height-y-rows) * scale, width * scale, rows * scale), image);
            CGImageRelease(image);
            if (output.error) goto done;
            y += rows;
        }
        CGPDFContextEndPage(context); page_open = 0;
        ddjvu_page_release(page); page = NULL;
    }
    result = 1;
done:
    if (page) ddjvu_page_release(page);
    if (format) ddjvu_format_release(format);
    if (space) CGColorSpaceRelease(space);
    if (context) {
        if (page_open) CGPDFContextEndPage(context);
        CGPDFContextClose(context); CGContextRelease(context);
    }
    if (consumer) CGDataConsumerRelease(consumer);
    if (fclose(file) != 0 && !output.error) output.error = errno ? errno : EIO;
    if (output.error && result >= 0) {
        snprintf(error, 512, "Cannot write PDF: %s", strerror(output.error)); result = 0;
    }
    return result;
}


static int page_info(Document *d, int index, ddjvu_pageinfo_t *info, char *error) {
    ddjvu_status_t status;
    while ((status = ddjvu_document_get_pageinfo(d->doc, index, info)) < DDJVU_JOB_OK)
        if (!messages(d, error)) return 0;
    if (status >= DDJVU_JOB_FAILED || info->width <= 0 || info->height <= 0) {
        snprintf(error, 512, "Cannot read DjVu page information"); return 0;
    }
    return 1;
}
API int lf_bounds(Document *d, int index, float *bounds, char *error) {
    ddjvu_pageinfo_t info;
    if (!page_info(d, index, &info, error)) return 0;
    float scale = 72.0f / (info.dpi > 0 ? info.dpi : 300);
    bounds[0] = bounds[1] = 0; bounds[2] = info.width * scale; bounds[3] = info.height * scale;
    return 1;
}
static miniexp_t page_text(Document *d, int index, const char *detail, char *error) {
    miniexp_t expr;
    while ((expr = ddjvu_document_get_pagetext(d->doc, index, detail)) == miniexp_dummy)
        if (!messages(d, error)) return miniexp_dummy;
    if (miniexp_symbolp(expr)) { snprintf(error, 512, "Cannot read DjVu text"); return miniexp_dummy; }
    return expr;
}
API char *lf_text(Document *d, int index, char *error) {
    miniexp_t expr = page_text(d, index, "page", error);
    if (expr == miniexp_dummy) return NULL;
    miniexp_t text = miniexp_nth(5, expr);
    char *out = strdup(miniexp_stringp(text) ? miniexp_to_str(text) : "");
    ddjvu_miniexp_release(d->doc, expr);
    if (!out) snprintf(error, 512, "Cannot allocate DjVu text");
    return out;
}

// Translate the ordered zone traversal used by SumatraPDF's CollectZonesUtf8.
// DjVuLibre exposes the same word tree as an s-expression. Coordinates in
// DjVu files are bottom-up pixels; Sumra uses top-down page points.
static void zone_text(SumraJSON *j, int *first, const char *text, double x, double y, double w, double h) {
    if (!*first) lf_json(j, ","); *first = 0;
    lf_json(j, "{\"text\":"); lf_json_string(j, text); lf_json(j, ",\"rect\":"); lf_json_rect(j, x, y, w, h); lf_json(j, "}");
}
static void words_json(miniexp_t expr, float scale, int height, SumraJSON *j, int *first) {
    if (!miniexp_listp(expr)) return;
    miniexp_t content = miniexp_nth(5, expr);
    if (miniexp_stringp(content)) {
        double x0 = miniexp_to_int(miniexp_nth(1, expr)), y0 = miniexp_to_int(miniexp_nth(2, expr));
        double x1 = miniexp_to_int(miniexp_nth(3, expr)), y1 = miniexp_to_int(miniexp_nth(4, expr));
        zone_text(j, first, miniexp_to_str(content), x0*scale, (height-y1)*scale, (x1-x0)*scale, (y1-y0)*scale);
        return;
    }
    for (miniexp_t children = miniexp_cdr(miniexp_cdr(miniexp_cdr(miniexp_cdr(miniexp_cdr(expr))))); miniexp_consp(children); children = miniexp_cdr(children)) {
        miniexp_t child = miniexp_car(children);
        words_json(child, scale, height, j, first);
        const char *kind = miniexp_to_name(miniexp_nth(0, child));
        if (kind && !strcmp(kind, "word")) {
            double x1 = miniexp_to_int(miniexp_nth(3, child)), y0 = miniexp_to_int(miniexp_nth(2, child)), y1 = miniexp_to_int(miniexp_nth(4, child));
            zone_text(j, first, " ", x1*scale, (height-y1)*scale, 2*scale, (y1-y0)*scale);
        } else if (kind && !strcmp(kind, "line")) zone_text(j, first, "\n", 0, 0, 0, 0);
    }
}
API char *lf_words(Document *d, int index, char *error) {
    ddjvu_pageinfo_t info;
    if (!page_info(d, index, &info, error)) return NULL;
    miniexp_t expr = page_text(d, index, "word", error);
    if (expr == miniexp_dummy) return NULL;
    SumraJSON j = {0}; int first = 1; lf_json(&j, "[");
    words_json(expr, 72.0f/(info.dpi > 0 ? info.dpi : 300), info.height, &j, &first); lf_json(&j, "]");
    ddjvu_miniexp_release(d->doc, expr); return lf_json_finish(&j, error);
}
static void outline_json(miniexp_t list, int depth, SumraJSON *j, int *first) {
    for (; miniexp_consp(list); list = miniexp_cdr(list)) {
        miniexp_t item = miniexp_car(list), title = miniexp_nth(0, item), target = miniexp_nth(1, item);
        if (!miniexp_stringp(title)) continue;
        if (!*first) lf_json(j, ","); *first = 0;
        lf_json(j, "{\"title\":"); lf_json_string(j, miniexp_to_str(title)); lf_json(j, ",\"target\":");
        lf_json_string(j, miniexp_stringp(target) ? miniexp_to_str(target) : ""); lf_json(j, ",\"depth\":"); lf_json_number(j, depth); lf_json(j, "}");
        outline_json(miniexp_cdr(miniexp_cdr(item)), depth+1, j, first);
    }
}
API char *lf_outline(Document *d, char *error) {
    miniexp_t expr;
    while ((expr = ddjvu_document_get_outline(d->doc)) == miniexp_dummy) if (!messages(d, error)) return NULL;
    if (miniexp_symbolp(expr)) { snprintf(error, 512, "Cannot read DjVu contents"); return NULL; }
    SumraJSON j = {0}; int first = 1; lf_json(&j, "["); outline_json(miniexp_cdr(expr), 0, &j, &first); lf_json(&j, "]");
    ddjvu_miniexp_release(d->doc, expr); return lf_json_finish(&j, error);
}
API int lf_resolve(Document *d, const char *uri, float *point, char *error) {
    point[0] = point[1] = NAN;
    const char *name = uri[0] == '#' ? uri+1 : uri;
    while (*name == ' ') ++name;
    char *end; long n = strtol(name, &end, 10);
    if (*name && !*end && n > 0 && n <= ddjvu_document_get_pagenum(d->doc)) return (int)n-1;
    int index = ddjvu_document_search_pageno(d->doc, name);
    if (index < 0) snprintf(error, 512, "Cannot resolve DjVu link");
    return index;
}
API char *lf_links(Document *d, int index, char *error) {
    ddjvu_pageinfo_t info;
    if (!page_info(d, index, &info, error)) return NULL;
    miniexp_t expr;
    while ((expr = ddjvu_document_get_pageanno(d->doc, index)) == miniexp_dummy) if (!messages(d, error)) return NULL;
    if (miniexp_symbolp(expr)) { snprintf(error, 512, "Cannot read DjVu links"); return NULL; }
    miniexp_t *links = ddjvu_anno_get_hyperlinks(expr);
    SumraJSON j = {0}; int first = 1; float scale = 72.0f/(info.dpi > 0 ? info.dpi : 300); lf_json(&j, "[");
    if (links) for (int i = 0; links[i] != miniexp_nil; ++i) {
        miniexp_t item = links[i], uri = miniexp_nth(1, item), area = miniexp_nth(3, item);
        if (miniexp_listp(uri)) uri = miniexp_nth(1, uri);
        const char *shape = miniexp_to_name(miniexp_nth(0, area));
        if (!miniexp_stringp(uri) || !shape) continue;
        double x, y, w, h;
        if (!strcmp(shape, "rect") || !strcmp(shape, "oval") || !strcmp(shape, "text")) {
            x = miniexp_to_int(miniexp_nth(1, area)); y = miniexp_to_int(miniexp_nth(2, area));
            w = miniexp_to_int(miniexp_nth(3, area)); h = miniexp_to_int(miniexp_nth(4, area));
        } else if (!strcmp(shape, "poly") || !strcmp(shape, "line")) {
            // Sumatra exposes the annotation's bounding rectangle for hit
            // testing, including polygons. Preserve every vertex here.
            miniexp_t points = miniexp_cdr(area);
            double x0 = INFINITY, y0 = INFINITY, x1 = -INFINITY, y1 = -INFINITY;
            for (; miniexp_consp(points) && miniexp_consp(miniexp_cdr(points)); points = miniexp_cdr(miniexp_cdr(points))) {
                double px = miniexp_to_int(miniexp_car(points)), py = miniexp_to_int(miniexp_nth(1, points));
                x0 = fmin(x0, px); y0 = fmin(y0, py); x1 = fmax(x1, px); y1 = fmax(y1, py);
            }
            if (!isfinite(x0)) continue;
            x = x0; y = y0; w = x1-x0; h = y1-y0;
        } else continue;
        if (!first) lf_json(&j, ","); first = 0;
        lf_json(&j, "{\"uri\":"); lf_json_string(&j, miniexp_to_str(uri)); lf_json(&j, ",\"rect\":");
        lf_json_rect(&j, x*scale, (info.height-y-h)*scale, w*scale, h*scale); lf_json(&j, "}");
    }
    free(links); lf_json(&j, "]"); ddjvu_miniexp_release(d->doc, expr); return lf_json_finish(&j, error);
}
