// SumatraPDF 012d997f: PdfDarkModeImageStats.cpp, EngineMupdf.cpp,
// base/Pixmap.cpp and PdfCad.cpp (GPLv3). Translated to the existing MuPDF C
// boundary; the upstream Win32 render cache and experimental smart device
// are deliberately absent. Live reading reuses its retained display list.
#include "Engine.h"
#include "MuPDFDocument.h"
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>

static float min3(float a, float b, float c) { return fminf(a, fminf(b, c)); }
static float max3(float a, float b, float c) { return fmaxf(a, fmaxf(b, c)); }
static float clamp(float x, float a, float b) { return fminf(b, fmaxf(a, x)); }
static float area(fz_rect r) { return fz_is_empty_rect(r) ? 0 : (r.x1-r.x0)*(r.y1-r.y0); }
static float luminance(const float *rgb) { return .2126f*rgb[0]+.7152f*rgb[1]+.0722f*rgb[2]; }

typedef struct {
    int buckets, valid;
    float variance, saturation, light, border_light, border_uniformity;
} ImageStats;
static void sample_rgb(fz_context *ctx, fz_pixmap *pix, int x, int y, float *rgb) {
    float components[FZ_MAX_COLORS] = {0};
    fz_colorspace *cs = pix->colorspace ? pix->colorspace : fz_device_rgb(ctx);
    unsigned char *p = pix->samples + (size_t)y*pix->stride + (size_t)x*pix->n;
    int count = fz_colorspace_n(ctx, cs);
    for (int i=0; i<count && i<FZ_MAX_COLORS; ++i) components[i] = p[i]/255.f;
    fz_convert_color(ctx, cs, components, fz_device_rgb(ctx), rgb, cs, fz_default_color_params);
}
static ImageStats image_stats(fz_context *ctx, fz_image *image, fz_cookie *cookie) {
    ImageStats stats = {0}; fz_pixmap *pix = NULL;
    fz_var(stats); fz_var(pix);
    fz_try(ctx) {
        if (cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
        float scale = fminf(1, 64.f/fmaxf(1, fmaxf(image->w, image->h)));
        // This MuPDF API takes unit-image-to-device extents, not a scale
        // factor. Passing scale alone requests a zero/one-pixel sample and
        // loses the variance needed to distinguish artwork from flat panels.
        fz_matrix ctm = fz_scale(image->w*scale, image->h*scale);
        pix = fz_get_pixmap_from_image(ctx, image, NULL, image->w>64 || image->h>64 ? &ctm : NULL, NULL, NULL);
        if (cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
        if (!pix || !pix->samples || pix->w<=0 || pix->h<=0) fz_throw(ctx,FZ_ERROR_FORMAT,"Empty PDF image");
        int buckets[4096] = {0}, n=0, saturated=0, light=0;
        float sum=0, squares=0;
        int step_x = pix->w>=32 ? pix->w/32 : 1, step_y = pix->h>=32 ? pix->h/32 : 1;
        for (int y=0; y<pix->h; y+=step_y) for (int x=0; x<pix->w; x+=step_x) {
            float rgb[FZ_MAX_COLORS] = {0}; sample_rgb(ctx,pix,x,y,rgb);
            int r=lroundf(clamp(rgb[0],0,1)*255), g=lroundf(clamp(rgb[1],0,1)*255), b=lroundf(clamp(rgb[2],0,1)*255);
            buckets[((r>>4)<<8)|((g>>4)<<4)|(b>>4)]++;
            float lum=luminance(rgb); sum+=lum; squares+=lum*lum;
            saturated += max3(rgb[0],rgb[1],rgb[2])-min3(rgb[0],rgb[1],rgb[2])>.12f;
            light += lum>.72f; n++;
        }
        for (int i=0; i<4096; ++i) stats.buckets += buckets[i]*100>n;
        stats.variance=squares/n-(sum/n)*(sum/n); stats.saturation=(float)saturated/n; stats.light=(float)light/n;
        float border[128][3] = {{0}}, average[3]={0}; int count=0, border_light=0;
        // Same capped perimeter sampling order as Sumatra.
        for (int edge=0; edge<2; ++edge) {
            int length=edge ? pix->h : pix->w, step=length>=32 ? length/32 : 1;
            for (int p=0; p<length; p+=step) for (int side=0; side<2 && count<128; ++side) {
                float rgb[FZ_MAX_COLORS]={0};
                sample_rgb(ctx,pix,edge ? (side ? pix->w-1 : 0) : p,edge ? p : (side ? pix->h-1 : 0),rgb);
                for (int c=0; c<3; ++c) { border[count][c]=rgb[c]; average[c]+=rgb[c]; }
                border_light+=luminance(rgb)>.72f; count++;
            }
        }
        for (int c=0; c<3; ++c) average[c]/=count;
        float variance=0;
        for (int i=0; i<count; ++i) for (int c=0; c<3; ++c) { float d=border[i][c]-average[c]; variance+=d*d; }
        stats.border_light=(float)border_light/count; stats.border_uniformity=clamp(1-variance/count/.12f,0,1); stats.valid=1;
    }
    fz_always(ctx) { fz_drop_pixmap(ctx,pix); }
    fz_catch(ctx) { fz_rethrow_if(ctx,FZ_ERROR_SYSTEM); fz_rethrow_if(ctx,FZ_ERROR_ABORT); fz_report_error(ctx); stats=(ImageStats){0}; }
    return stats;
}
static int dark_art(ImageStats s, float coverage) {
    return s.valid && coverage>=.035f && s.light<.48f && s.variance>=.004f && (s.buckets>=8 || s.saturation>=.08f);
}
static int preserve_art(ImageStats s, float coverage) {
    if (!s.valid) return 0;
    if ((s.light>.76f && s.variance<.011f && s.buckets<=11 && s.saturation<.17f) ||
        (s.light>.58f && s.variance<.018f) || (s.light>.44f && s.variance<.022f) ||
        (s.light>.50f && s.variance<.038f && s.saturation<.22f && s.buckets<=14) ||
        (s.border_light>=.95f && s.border_uniformity>=.90f)) return 0;
    if (dark_art(s,coverage)) return 1;
    int photo=s.buckets>=16 || s.saturation>=.18f || s.variance>=.014f;
    if ((s.light>.58f && s.saturation<.18f) || (s.buckets<=12 && s.variance<.012f && s.light>.45f) ||
        (s.light>.72f && s.saturation<.18f)) photo=0;
    if (coverage<.14f && s.light>.64f && s.variance<.014f && s.buckets<=12 && s.saturation<.20f) photo=0;
    return photo;
}

typedef struct { fz_rect rect, original; fz_image *image; } PageImage;
typedef struct {
    fz_device super;
    PageImage *images; int count, capacity, collect_images;
    int strokes, fills, text, gray, thin;
    float page_area, image_coverage;
} Analysis;
static void analysis_drop(fz_context *ctx, fz_device *dev) {
    Analysis *d=(Analysis *)dev;
    for (int i=0; i<d->count; ++i) fz_drop_image(ctx,d->images[i].image);
    fz_free(ctx,d->images);
}
static void note_stroke(fz_context *ctx, Analysis *d, const fz_stroke_state *stroke, fz_colorspace *cs, const float *color, fz_color_params params) {
    float rgb[FZ_MAX_COLORS]={0}; fz_convert_color(ctx,cs,color,fz_device_rgb(ctx),rgb,cs,params);
    float lum=luminance(rgb);
    d->strokes++; d->gray += max3(rgb[0],rgb[1],rgb[2])-min3(rgb[0],rgb[1],rgb[2])<=.12f && lum>=.38f && lum<=.88f;
    d->thin += stroke && stroke->linewidth<=.25f;
}
static void analysis_stroke(fz_context *ctx, fz_device *dev, const fz_path *path, const fz_stroke_state *stroke, fz_matrix ctm, fz_colorspace *cs, const float *color, float alpha, fz_color_params params) {
    note_stroke(ctx,(Analysis *)dev,stroke,cs,color,params);
}
static void analysis_fill(fz_context *ctx, fz_device *dev, const fz_path *path, int evenodd, fz_matrix ctm, fz_colorspace *cs, const float *color, float alpha, fz_color_params params) { ((Analysis *)dev)->fills++; }
static void analysis_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm, fz_colorspace *cs, const float *color, float alpha, fz_color_params params) {
    Analysis *d=(Analysis *)dev; d->text++; note_stroke(ctx,d,NULL,cs,color,params);
}
static void analysis_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *text, const fz_stroke_state *stroke, fz_matrix ctm, fz_colorspace *cs, const float *color, float alpha, fz_color_params params) {
    analysis_text(ctx,dev,text,ctm,cs,color,alpha,params);
}
static void analysis_image(fz_context *ctx, fz_device *dev, fz_image *image, fz_matrix ctm, float alpha, fz_color_params params) {
    Analysis *d=(Analysis *)dev; fz_rect rect=fz_transform_rect(fz_unit_rect,ctm);
    if (d->page_area>0) d->image_coverage=fmaxf(d->image_coverage,area(rect)/d->page_area);
    if (!d->collect_images) return;
    // MuPDF already maintains the complete clip/mask/group stack even for an
    // analysis device. Reuse it rather than porting Sumatra's fixed-size stack.
    rect=fz_intersect_rect(rect,fz_device_current_scissor(ctx,dev));
    if(fz_is_empty_rect(rect) || fz_is_infinite_rect(rect)) return;
    for(int i=0;i<d->count;++i) if(area(fz_intersect_rect(rect,d->images[i].rect))>area(d->images[i].rect)*.85f) return;
    if (d->count==d->capacity) { d->images=fz_realloc_array(ctx,d->images,d->capacity+16,PageImage); d->capacity+=16; }
    fz_rect original=rect;
    // Clamp mismatched tall/wide occurrence bounds, as upstream legacy mode does.
    float w=rect.x1-rect.x0,h=rect.y1-rect.y0;
    if (image->w>0 && image->h>0 && w>0 && h>0) {
        float aspect=(float)image->w/image->h;
        if (w/h<aspect/1.4f) rect.y1=rect.y0+fminf(w/aspect,h);
        if (w/h>aspect*1.4f) rect.x1=rect.x0+fminf(h*aspect,w);
    }
    d->images[d->count++]=(PageImage){rect,original,fz_keep_image(ctx,image)};
}
static Analysis *new_analysis(fz_context *ctx, int collect, float page_area) {
    Analysis *d=fz_new_derived_device(ctx,Analysis); d->collect_images=collect; d->page_area=page_area;
    d->super.drop_device=analysis_drop; d->super.stroke_path=analysis_stroke; d->super.fill_path=analysis_fill;
    d->super.fill_text=analysis_text; d->super.stroke_text=analysis_stroke_text; d->super.fill_image=analysis_image;
    return d;
}
static int root(int *parents,int i) { while (parents[i]!=i) { parents[i]=parents[parents[i]]; i=parents[i]; } return i; }
static fz_irect preserve_rect(fz_context *ctx, Analysis *d, fz_rect page, fz_matrix transform, fz_cookie *cookie) {
    int *parents=NULL, *counts=NULL; float *areas=NULL; fz_rect *boxes=NULL; fz_irect best=fz_empty_irect;
    if (!d->count) return best;
    fz_var(parents); fz_var(counts); fz_var(areas); fz_var(boxes); fz_var(best);
    fz_try(ctx) {
        int n=d->count;
        parents=fz_malloc_array(ctx,n,int); counts=fz_calloc(ctx,n,sizeof(int)); areas=fz_calloc(ctx,n,sizeof(float)); boxes=fz_malloc_array(ctx,n,fz_rect);
        for (int i=0;i<n;++i) { parents[i]=i; boxes[i]=fz_empty_rect; }
        float tol=fmaxf(1,fminf(page.x1-page.x0,page.y1-page.y0)*.005f);
        for (int i=0;i<n;++i) {
            if (cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
            fz_rect r=fz_intersect_rect(d->images[i].rect,page);
            if (fz_is_empty_rect(r)) continue;
            r.x0-=tol;r.y0-=tol;r.x1+=tol;r.y1+=tol;
            for (int j=i+1;j<n;++j) if (!fz_is_empty_rect(fz_intersect_rect(r,fz_intersect_rect(d->images[j].rect,page)))) {
                int a=root(parents,i),b=root(parents,j); if (a!=b) parents[a]=b;
            }
        }
        for (int i=0;i<n;++i) {
            if (cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
            fz_rect r=fz_intersect_rect(d->images[i].rect,page); if (fz_is_empty_rect(r)) continue;
            int p=root(parents,i); boxes[p]=fz_union_rect(boxes[p],r); areas[p]+=area(r); counts[p]++;
        }
        for (int i=0;i<n;++i) if (counts[i]<2 || areas[i]<area(boxes[i])*.85f) counts[i]=0;
        int64_t best_area=0;
        for (int i=0;i<n;++i) {
            if (cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
            int p=root(parents,i); fz_rect r=counts[p]>=2 ? boxes[p] : fz_intersect_rect(d->images[i].rect,page);
            float w=r.x1-r.x0,h=r.y1-r.y0, pw=page.x1-page.x0,ph=page.y1-page.y0;
            if (w<=0 || h<=0 || pw<=0 || ph<=0) continue;
            float coverage=area(r)/area(page);
            if (fminf(w,h)/fmaxf(w,h)<.22f || (w/pw<.20f && h/ph>.30f) || (h/ph<.20f && w/pw>.30f)) continue;
            fz_irect own=fz_round_rect(fz_transform_rect(d->images[i].rect,transform));
            if (own.x1-own.x0<72 || own.y1-own.y0<72) continue;
            ImageStats stats=image_stats(ctx,d->images[i].image,cookie);
            if ((coverage>=.75f && !dark_art(stats,coverage)) || !preserve_art(stats,coverage) || (w>pw*.44f && !dark_art(stats,coverage))) continue;
            fz_irect rect=fz_round_rect(fz_transform_rect(r,transform));
            int64_t size=(int64_t)(rect.x1-rect.x0)*(rect.y1-rect.y0);
            if (size>best_area) { best=rect; best_area=size; }
        }
        if(best_area>0) { best.x0-=3;best.y0-=3;best.x1+=3;best.y1+=3; }
    }
    fz_always(ctx) { fz_free(ctx,parents); fz_free(ctx,counts); fz_free(ctx,areas); fz_free(ctx,boxes); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return best;
}

// Engineering algorithms are translated from PdfCad.cpp; the standard MuPDF
// passthrough device replaces the upstream forwarding boilerplate.
static void cad_gray(float *rgb) {
    float lum=luminance(rgb);
    if (max3(rgb[0],rgb[1],rgb[2])-min3(rgb[0],rgb[1],rgb[2])>.14f || lum<.48f || lum>.86f || lum<=.50f) return;
    float target=.15f+fminf((lum-.50f)/.32f,1)*.21f;
    if (target<lum) for (int i=0;i<3;++i) rgb[i]*=target/lum;
}
static float cad_blend(float expansion) { return clamp((.84f-(expansion<.001f ? 1 : expansion))/.60f,0,1); }
static void cad_color(fz_context *ctx,fz_colorspace *cs,const float *color,fz_color_params params,fz_matrix ctm,float *rgb) {
    float old[FZ_MAX_COLORS]={0}; fz_convert_color(ctx,cs,color,fz_device_rgb(ctx),old,cs,params);
    memcpy(rgb,old,3*sizeof(float)); cad_gray(rgb);
    float blend=cad_blend(sqrtf(ctm.a*ctm.a+ctm.b*ctm.b));
    for (int i=0;i<3;++i) rgb[i]=old[i]+(rgb[i]-old[i])*blend;
}
static void cad_stroke(fz_context *ctx,fz_device *dev,const fz_path *path,const fz_stroke_state *stroke,fz_matrix ctm,fz_colorspace *cs,const float *color,float alpha,fz_color_params params) {
    float rgb[FZ_MAX_COLORS]={0};cad_color(ctx,cs,color,params,ctm,rgb);fz_stroke_path(ctx,dev->passthrough,path,stroke,ctm,fz_device_rgb(ctx),rgb,alpha,params);
}
static void cad_fill(fz_context *ctx,fz_device *dev,const fz_path *path,int evenodd,fz_matrix ctm,fz_colorspace *cs,const float *color,float alpha,fz_color_params params) {
    fz_rect r=fz_bound_path(ctx,path,NULL,ctm);
    if (fminf(r.x1-r.x0,r.y1-r.y0)>4) { fz_fill_path(ctx,dev->passthrough,path,evenodd,ctm,cs,color,alpha,params);return; }
    float rgb[FZ_MAX_COLORS]={0};cad_color(ctx,cs,color,params,ctm,rgb);fz_fill_path(ctx,dev->passthrough,path,evenodd,ctm,fz_device_rgb(ctx),rgb,alpha,params);
}
static void cad_text(fz_context *ctx,fz_device *dev,const fz_text *text,fz_matrix ctm,fz_colorspace *cs,const float *color,float alpha,fz_color_params params) {
    float rgb[FZ_MAX_COLORS]={0};cad_color(ctx,cs,color,params,ctm,rgb);fz_fill_text(ctx,dev->passthrough,text,ctm,fz_device_rgb(ctx),rgb,alpha,params);
}
static void cad_stroke_text(fz_context *ctx,fz_device *dev,const fz_text *text,const fz_stroke_state *stroke,fz_matrix ctm,fz_colorspace *cs,const float *color,float alpha,fz_color_params params) {
    float rgb[FZ_MAX_COLORS]={0};cad_color(ctx,cs,color,params,ctm,rgb);fz_stroke_text(ctx,dev->passthrough,text,stroke,ctm,fz_device_rgb(ctx),rgb,alpha,params);
}
static void cad_pixels(fz_pixmap *pix,float zoom,fz_cookie *cookie) {
    float blend=fmaxf(cad_blend(zoom>.01f ? 1/zoom : 1),.55f);
    for (int y=0;y<pix->h && (!cookie || !cookie->abort);++y) for (int x=0;x<pix->w;++x) {
        unsigned char *p=pix->samples+(size_t)y*pix->stride+(size_t)x*4;
        float alpha=p[3]/255.f;if (!p[3]) continue;
        float rgb[3]={p[0]/255.f/alpha,p[1]/255.f/alpha,p[2]/255.f/alpha},old[3];memcpy(old,rgb,sizeof(rgb));
        if (min3(rgb[0],rgb[1],rgb[2])>.96f) continue;
        cad_gray(rgb);for (int i=0;i<3;++i) rgb[i]=old[i]+(rgb[i]-old[i])*blend;
        float lum=luminance(rgb);
        if (lum>.40f && lum<.90f && max3(rgb[0],rgb[1],rgb[2])-min3(rgb[0],rgb[1],rgb[2])<.15f)
            for(int i=0;i<3;++i) rgb[i]*=1-.28f*blend*(lum-.40f)/.50f;
        for(int i=0;i<3;++i) p[i]=lroundf(clamp(rgb[i],0,1)*alpha*255);
    }
}
static int mul255(int a,int b) { int n=a*b+128;n+=n>>8;return n>>8; }
static void image_outlines(fz_pixmap *pix,Analysis *analysis,fz_matrix ctm) {
    // Canvas.cpp DebugOutlinePageElements: image outlines are green, unlike
    // blue links. This is a display overlay and never enters saved PDF bytes.
    for(int i=0;i<analysis->count;++i) {
        fz_irect r=fz_round_rect(fz_transform_rect(analysis->images[i].original,ctm));
        r.x0-=2;r.y0-=2;r.x1+=2;r.y1+=2;
        for(int edge=0;edge<2;++edge) {
            int y=(edge ? r.y1-1 : r.y0)-pix->y;
            if(y>=0 && y<pix->h) for(int x=fmaxf(0,r.x0-pix->x);x<fminf(pix->w,r.x1-pix->x);++x) {
                unsigned char *p=pix->samples+(size_t)y*pix->stride+(size_t)x*4;p[0]=0;p[1]=160;p[2]=0;p[3]=255;
            }
            int x=(edge ? r.x1-1 : r.x0)-pix->x;
            if(x>=0 && x<pix->w) for(int y=fmaxf(0,r.y0-pix->y);y<fminf(pix->h,r.y1-pix->y);++y) {
                unsigned char *p=pix->samples+(size_t)y*pix->stride+(size_t)x*4;p[0]=0;p[1]=160;p[2]=0;p[3]=255;
            }
        }
    }
}
static void recolor(fz_pixmap *pix,uint32_t text,uint32_t background,uint32_t link,fz_irect skip,fz_cookie *cookie) {
    int fg[3]={(text>>16)&255,(text>>8)&255,text&255},bg[3]={(background>>16)&255,(background>>8)&255,background&255},href[3]={(link>>16)&255,(link>>8)&255,link&255};
    for(int y=0;y<pix->h && (!cookie || !cookie->abort);++y) for(int x=0;x<pix->w;++x) {
        if(x+pix->x>=skip.x0 && x+pix->x<skip.x1 && y+pix->y>=skip.y0 && y+pix->y<skip.y1) continue;
        unsigned char *p=pix->samples+(size_t)y*pix->stride+(size_t)x*4;if (!p[3]) continue;
        int rgb[3];for(int i=0;i<3;++i) rgb[i]=p[3]==255 ? p[i] : (p[i]*255+p[3]/2)/p[3];
        int is_link=link && rgb[2]>=fmaxf(rgb[0],rgb[1])+25 && rgb[2]>=72 && (rgb[0]+rgb[1]+rgb[2])/3<=230;
        for(int i=0;i<3;++i) {
            int v=is_link ? href[i]+mul255((rgb[0]+rgb[1])/2,bg[i]-href[i]) : fg[i]+mul255(rgb[i],bg[i]-fg[i]);
            p[i]=(unsigned char)mul255(v,p[3]);
        }
    }
}

// Replay the live page display list; its owner also invalidates cached analysis.
void lf_run_pdf_colors(fz_context *ctx, fz_display_list *list, fz_device **cached_analysis,
        fz_rect box, fz_rect clip, fz_matrix ctm, float zoom, fz_pixmap *pix,
        const int *style, const uint32_t *colors, fz_cookie *cookie) {
    fz_device *dev=NULL; Analysis *analysis=NULL; fz_irect skip=fz_empty_irect;
    fz_var(dev); fz_var(analysis);
    fz_try(ctx) {
        if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
        if((style[0]==1 && style[1]) || style[7]) {
            if (!*cached_analysis) {
                analysis=new_analysis(ctx,1,area(box));
                fz_run_display_list(ctx,list,&analysis->super,fz_identity,box,cookie);
                if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
                fz_close_device(ctx,&analysis->super);
                *cached_analysis=(fz_device *)analysis;analysis=NULL;
            }
            if(style[0]==1 && style[1]) skip=preserve_rect(ctx,(Analysis *)*cached_analysis,box,ctm,cookie);
        }
        // Match upstream replay: output zoom belongs to the draw device;
        // the CAD wrapper sees each original content object's transform.
        dev=fz_new_draw_device(ctx,ctm,pix);
        fz_set_graphics_min_line_width(ctx,0);
        if(style[2]) {
            fz_device *wrapper=fz_new_derived_passthrough_device(ctx,dev,fz_device);fz_drop_device(ctx,dev);dev=wrapper;
            dev->stroke_path=cad_stroke;dev->fill_path=cad_fill;dev->fill_text=cad_text;dev->stroke_text=cad_stroke_text;
            float z=fmaxf(zoom,.20f),minimum=style[4] ? .50f+.55f/z : .14f+.38f/z;
            fz_set_graphics_min_line_width(ctx,clamp(minimum,style[4] ? .50f : .14f,style[4] ? 1.25f : .62f));
        }
        fz_run_display_list(ctx,list,dev,fz_identity,clip,cookie);
        if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
        fz_close_device(ctx,dev);
        if(style[2] && style[3]) cad_pixels(pix,zoom,cookie);
        // Sumatra applies grayscale first, so selected theme colors still apply.
        if(style[6]) for(int y=0;y<pix->h && (!cookie || !cookie->abort);++y) for(int x=0;x<pix->w;++x) {
            unsigned char *p=pix->samples+(size_t)y*pix->stride+(size_t)x*4;
            unsigned char gray=(unsigned char)((54*p[0]+183*p[1]+19*p[2]+128)>>8);p[0]=p[1]=p[2]=gray;
        }
        if(style[0]) recolor(pix,colors[0],colors[1],colors[2],skip,cookie);
        if(style[7]) image_outlines(pix,(Analysis *)*cached_analysis,ctm);
        if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF display cancelled");
    }
    fz_always(ctx) {
        // EngineMupdf::UnhookAbortedDevices: cancelled replay can leave an
        // unbalanced clip stack. Drop it without closing a partial drawing.
        if(cookie && cookie->abort) {
            for(fz_device *d=dev;d;d=d->passthrough) d->close_device=NULL;
            if(analysis) analysis->super.close_device=NULL;
        }
        fz_set_graphics_min_line_width(ctx,0);
        fz_drop_device(ctx,dev);fz_drop_device(ctx,(fz_device *)analysis);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

static int contains(const char *text,const char *needle) { return text && strcasestr(text,needle)!=NULL; }
static int contains_any(const char *text,const char *const *needles,size_t count) {
    for(size_t i=0;i<count;++i) if(contains(text,needles[i])) return 1;return 0;
}
static int metadata_score(const char *value,int *strong) {
    static const char *const blacklist[]={"microsoft word","libreoffice","openoffice","indesign","itext","pdflatex","xelatex","lualatex","latex"," prince","chrome","skia/pdf","mozilla","calibre","epub","powerpoint","excel","onenote","doctotext"};
    static const char *const strong_words[]={"autocad","dwg to pdf","dwg trueview","revit","microstation","solidworks","catia"," creo"," nx ","zwcad","gstarcad","浩辰","中望","bluebeam","pdffactory","tekla","sketchup","archicad","vectorworks","bentley"};
    static const char *const weak[]={"cad","dwg","plot","engineering","layout","draft","mechanical","architect","screenshot","screen capture","snipaste","截图","wps"};
    if(contains_any(value,blacklist,sizeof(blacklist)/sizeof(*blacklist))) return -100;
    if(contains_any(value,strong_words,sizeof(strong_words)/sizeof(*strong_words))) { *strong=1;return 40; }
    return contains_any(value,weak,sizeof(weak)/sizeof(*weak)) ? 15 : 0;
}
// PdfCad detection examines metadata and at most three pages of the same
// document; neither the active render-page cache nor the journal is replaced.
static void detect_engineering(fz_context *ctx,pdf_document *doc,int *result,fz_cookie *cookie) {
    pdf_page *page=NULL;fz_buffer *xmp=NULL;Analysis *analysis=NULL;
    fz_var(page);fz_var(xmp);fz_var(analysis);
    result[0]=result[1]=result[2]=0;
    fz_try(ctx) {
        if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF detection cancelled");
        pdf_obj *trailer=pdf_trailer(ctx,doc),*info=pdf_dict_get(ctx,trailer,PDF_NAME(Info)),*root_obj=pdf_dict_get(ctx,trailer,PDF_NAME(Root));
        pdf_obj *metadata=pdf_dict_get(ctx,root_obj,PDF_NAME(Metadata));
        if(metadata) xmp=pdf_load_stream(ctx,metadata);
        const char *xml=xmp ? fz_string_from_buffer(ctx,xmp) : "";
        if(pdf_is_string(ctx,pdf_dict_gets(ctx,info,"ISO_PDFEVersion")) || strstr(xml,"pdfe:ISO_PDFEVersion") || strstr(xml,"PDF/E-1") || strstr(xml,"PDF/E-2")) result[0]=1;
        else {
            int strong=0,score=0,blacklisted=0;
            const char *fields[]={pdf_to_text_string(ctx,pdf_dict_gets(ctx,info,"Creator")),pdf_to_text_string(ctx,pdf_dict_gets(ctx,info,"Producer")),xml};
            for(int i=0;i<3;++i) { int value=metadata_score(fields[i],&strong);if(value<=-100) blacklisted=1;else score+=value; }
            if(!blacklisted && strong) result[0]=1;
            else if(!blacklisted) {
                int count=pdf_count_pages(ctx,doc),samples=count>3 ? 3 : count;float side=0;
                for(int i=0;i<samples;++i) {
                    if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF detection cancelled");
                    page=pdf_load_page(ctx,doc,i);fz_rect box=pdf_bound_page(ctx,page,FZ_CROP_BOX);
                    side=fmaxf(side,fmaxf(box.x1-box.x0,box.y1-box.y0));fz_drop_page(ctx,(fz_page *)page);page=NULL;
                }
                analysis=new_analysis(ctx,0,side*side);
                for(int i=0;i<count && i<2;++i) {
                    page=pdf_load_page(ctx,doc,i);pdf_run_page_contents(ctx,page,&analysis->super,fz_identity,cookie);
                    if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF detection cancelled");
                    fz_drop_page(ctx,(fz_page *)page);page=NULL;
                }
                fz_close_device(ctx,&analysis->super);
                float stroke_ratio=analysis->strokes+analysis->fills>0 ? (float)analysis->strokes/(analysis->strokes+analysis->fills) : 0;
                float gray_ratio=analysis->strokes ? (float)analysis->gray/analysis->strokes : 0;
                float thin_ratio=analysis->strokes ? (float)analysis->thin/analysis->strokes : 0;
                float text_ratio=analysis->strokes ? (float)analysis->text/analysis->strokes : 0;
                int heuristic=0;
                if(stroke_ratio>.85f) heuristic+=25;if(gray_ratio>.30f) heuristic+=25;if(thin_ratio>.20f) heuristic+=15;
                pdf_obj *layers=pdf_dict_get(ctx,pdf_dict_get(ctx,root_obj,PDF_NAME(OCProperties)),PDF_NAME(OCGs));
                if(pdf_array_len(ctx,layers)>=2) heuristic+=15;if(side>=842) heuristic+=10;if(text_ratio<.15f) heuristic+=10;
                int squares=0;
                for(int i=0;i<samples;++i) {
                    if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF detection cancelled");
                    pdf_obj *annots=pdf_dict_get(ctx,pdf_lookup_page_obj(ctx,doc,i),PDF_NAME(Annots));
                    for(int j=0;j<pdf_array_len(ctx,annots);++j) squares+=pdf_name_eq(ctx,pdf_dict_get(ctx,pdf_array_get(ctx,annots,j),PDF_NAME(Subtype)),PDF_NAME(Square));
                }
                if(squares>20) heuristic+=5;
                if(analysis->text>500 && stroke_ratio<.5f) heuristic-=30;
                if(analysis->image_coverage>=.15f && analysis->text>=40) heuristic-=65;
                if(count>=80 && analysis->image_coverage>=.12f && analysis->text>=25) heuristic-=40;
                int hairline=analysis->image_coverage<.05f && analysis->strokes>=40 && thin_ratio>.25f && stroke_ratio>.55f;
                if(hairline) heuristic+=35;
                int raster=analysis->image_coverage>=.80f && analysis->strokes+analysis->fills<50 && analysis->text<200;
                if(raster) heuristic+=count>30 ? -70 : 55;
                else if(analysis->image_coverage>.5f) heuristic-=40;
                if(count>30) raster=0;
                result[1]=raster;result[2]=hairline;int total=score+heuristic;
                result[0]=(raster && total>=45 && count<=30) || (hairline && total>=45) || (score>0 && total>=45) || total>=60;
            }
        }
        if(cookie && cookie->abort) fz_throw(ctx,FZ_ERROR_ABORT,"PDF detection cancelled");
    }
    fz_always(ctx) { fz_drop_device(ctx,(fz_device *)analysis);fz_drop_page(ctx,(fz_page *)page);fz_drop_buffer(ctx,xmp); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

API int lf_pdf_live_engineering(void *opaque,int *result,void *cancel,char *error) {
    SumraMuPDFDocument *d=opaque;int ok=0;fz_var(ok);
    fz_try(d->ctx) {
        pdf_document *doc=pdf_specifics(d->ctx,d->doc);
        if(!doc) fz_throw(d->ctx,FZ_ERROR_ARGUMENT,"Document is not a PDF");
        detect_engineering(d->ctx,doc,result,cancel);ok=1;
    }
    fz_catch(d->ctx) { snprintf(error,512,"%s",fz_convert_error(d->ctx,NULL)); }
    return ok;
}

