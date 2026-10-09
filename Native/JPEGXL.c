#include "Engine.h"
#include <errno.h>
#include <jxl/decode.h>

typedef struct {
    unsigned char *source, *pixels;
    size_t source_size, pixel_size;
    JxlDecoder *decoder;
    int width, height, count, cached_page;
} Document;

static const JxlPixelFormat format = {4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};

API void lf_close(Document *d) {
    if (!d) return;
    if (d->decoder) JxlDecoderDestroy(d->decoder);
    free(d->source); free(d->pixels); free(d);
}

API int lf_count(Document *d) { return d ? d->count : 0; }

API unsigned char *lf_color_profile(Document *d, size_t *size, char *error) {
    *size = 0; error[0] = 0;
    size_t n;
    JxlDecoderStatus status = JxlDecoderGetICCProfileSize(d->decoder, JXL_COLOR_PROFILE_TARGET_DATA, &n);
    // ERROR here is libjxl's documented "no ICC available or generatable".
    if (status == JXL_DEC_ERROR || (status == JXL_DEC_SUCCESS && !n)) return NULL;
    if (status != JXL_DEC_SUCCESS) { snprintf(error, 512, "JPEG XL color profile is incomplete"); return NULL; }
    unsigned char *profile = malloc(n);
    if (!profile) { snprintf(error, 512, "Cannot allocate JPEG XL color profile"); return NULL; }
    if (JxlDecoderGetColorAsICCProfile(d->decoder, JXL_COLOR_PROFILE_TARGET_DATA, profile, n) != JXL_DEC_SUCCESS) {
        snprintf(error, 512, "Cannot read JPEG XL color profile"); free(profile); return NULL;
    }
    *size = n; return profile;
}

static int page_exists(Document *d, int page, char *error) {
    if (page >= 0 && page < d->count) return 1;
    snprintf(error, 512, "JPEG XL page is out of range"); return 0;
}

static int decode_page(Document *d, int page, char *error) {
    if (page == d->cached_page) return 1;
    d->cached_page = -1;
    JxlDecoderRewind(d->decoder);
    if (JxlDecoderSetInput(d->decoder, d->source, d->source_size) != JXL_DEC_SUCCESS) {
        snprintf(error, 512, "Cannot read JPEG XL input"); return 0;
    }
    JxlDecoderCloseInput(d->decoder);
    // libjxl owns reference-frame decoding, blending and random-access skips.
    JxlDecoderSkipFrames(d->decoder, (size_t)page);
    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(d->decoder);
        if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            if (!d->pixels) d->pixels = malloc(d->pixel_size);
            if (!d->pixels) { snprintf(error, 512, "Cannot allocate JPEG XL pixels"); return 0; }
            if (JxlDecoderSetImageOutBuffer(d->decoder, &format, d->pixels, d->pixel_size) != JXL_DEC_SUCCESS) {
                snprintf(error, 512, "Cannot set JPEG XL pixel buffer"); return 0;
            }
        } else if (status == JXL_DEC_FULL_IMAGE) {
            d->cached_page = page; return 1;
        } else if (status == JXL_DEC_NEED_MORE_INPUT) {
            snprintf(error, 512, "JPEG XL page %d is truncated", page + 1); return 0;
        } else if (status == JXL_DEC_ERROR || status == JXL_DEC_SUCCESS) {
            snprintf(error, 512, "Cannot decode JPEG XL page %d", page + 1); return 0;
        }
    }
}

API Document *lf_open(const char *path, char *error) {
    FILE *f = fopen(path, "rb");
    if (!f) { snprintf(error, 512, "Cannot open JPEG XL: %s", strerror(errno)); return NULL; }
    if (fseek(f, 0, SEEK_END) != 0) {
        snprintf(error, 512, "Cannot seek JPEG XL: %s", strerror(errno)); fclose(f); return NULL;
    }
    long size = ftell(f);
    if (size < 0 || fseek(f, 0, SEEK_SET) != 0) {
        snprintf(error, 512, "Cannot read JPEG XL size: %s", strerror(errno)); fclose(f); return NULL;
    }
    if (!size) { snprintf(error, 512, "JPEG XL file is empty"); fclose(f); return NULL; }
    Document *d = calloc(1, sizeof(*d));
    if (!d) { snprintf(error, 512, "Cannot allocate JPEG XL document"); fclose(f); return NULL; }
    d->source_size = (size_t)size; d->cached_page = -1;
    d->source = malloc(d->source_size);
    if (!d->source) {
        snprintf(error, 512, "Cannot allocate JPEG XL input"); fclose(f); lf_close(d); return NULL;
    }
    if (fread(d->source, 1, d->source_size, f) != d->source_size) {
        snprintf(error, 512, "Cannot read JPEG XL: %s", ferror(f) ? strerror(errno) : "file changed or truncated");
        fclose(f); lf_close(d); return NULL;
    }
    fclose(f);
    d->decoder = JxlDecoderCreate(NULL);
    if (!d->decoder) { snprintf(error, 512, "Cannot allocate JPEG XL decoder"); lf_close(d); return NULL; }
    // The native CGImage contract expects straight RGBA; the decoder otherwise
    // preserves associated alpha. Default coalescing supplies full-canvas pages.
    if (JxlDecoderSetUnpremultiplyAlpha(d->decoder, JXL_TRUE) != JXL_DEC_SUCCESS ||
        JxlDecoderSubscribeEvents(d->decoder, JXL_DEC_BASIC_INFO | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS ||
        JxlDecoderSetInput(d->decoder, d->source, d->source_size) != JXL_DEC_SUCCESS) {
        snprintf(error, 512, "Cannot initialize JPEG XL decoder"); lf_close(d); return NULL;
    }
    JxlDecoderCloseInput(d->decoder);
    int ok = 0;
    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(d->decoder);
        if (status == JXL_DEC_BASIC_INFO) {
            JxlBasicInfo info;
            if (JxlDecoderGetBasicInfo(d->decoder, &info) != JXL_DEC_SUCCESS ||
                !info.xsize || !info.ysize || info.xsize > INT_MAX / 4 || info.ysize > INT_MAX) {
                snprintf(error, 512, "JPEG XL dimensions are too large"); break;
            }
            // libjxl's default orientation handling also swaps these dimensions.
            d->width = (int)info.xsize; d->height = (int)info.ysize;
            if (JxlDecoderImageOutBufferSize(d->decoder, &format, &d->pixel_size) != JXL_DEC_SUCCESS ||
                d->pixel_size != (size_t)d->width * (size_t)d->height * 4) {
                snprintf(error, 512, "Invalid JPEG XL pixel geometry"); break;
            }
        } else if (status == JXL_DEC_FRAME) {
            if (d->count == INT_MAX) { snprintf(error, 512, "JPEG XL has too many pages"); break; }
            ++d->count;
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            // Count displayed frames without allocating an output image for each.
            if (JxlDecoderSkipCurrentFrame(d->decoder) != JXL_DEC_SUCCESS) {
                snprintf(error, 512, "Cannot index JPEG XL frames"); break;
            }
        } else if (status == JXL_DEC_SUCCESS) {
            ok = d->count > 0 && d->width > 0 && d->height > 0;
            if (!ok) snprintf(error, 512, "JPEG XL has no readable frames");
            break;
        } else if (status == JXL_DEC_NEED_MORE_INPUT) {
            snprintf(error, 512, "JPEG XL file is truncated"); break;
        } else if (status == JXL_DEC_ERROR) {
            snprintf(error, 512, "Cannot read JPEG XL frames"); break;
        }
    }
    if (!ok || !decode_page(d, 0, error)) { lf_close(d); return NULL; }
    return d;
}

API unsigned char *lf_render(Document *d, int page, int width, int *info, char *error) {
    if (!page_exists(d, page, error) || !decode_page(d, page, error)) return NULL;
    int ow = d->width, oh = d->height;
    if (width > 0 && width < ow) {
        // Round up so even a very wide, single-row image remains at least 1 px.
        oh = (int)(((int64_t)oh * width + ow - 1) / ow); ow = width;
    }
    info[0] = ow; info[1] = oh; info[2] = ow * 4; info[3] = 4;
    size_t n = (size_t)info[2] * (size_t)oh;
    unsigned char *out = malloc(n);
    if (!out) { snprintf(error, 512, "Cannot allocate JPEG XL rendered page"); return NULL; }
    if (ow == d->width) { memcpy(out, d->pixels, n); return out; }
    for (int y = 0; y < oh; ++y) {
        int sy = (int)((int64_t)y * d->height / oh);
        for (int x = 0; x < ow; ++x) {
            int sx = (int)((int64_t)x * d->width / ow);
            memcpy(out + ((size_t)y * ow + x) * 4, d->pixels + ((size_t)sy * d->width + sx) * 4, 4);
        }
    }
    return out;
}

API int lf_bounds(Document *d, int index, float *bounds, char *error) {
    if (!page_exists(d, index, error)) return 0;
    bounds[0] = bounds[1] = 0; bounds[2] = d->width; bounds[3] = d->height; return 1;
}
