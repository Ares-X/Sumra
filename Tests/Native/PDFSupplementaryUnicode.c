// Public font/PDF APIs exercise UTF-16 ToUnicode through real saved documents.
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <mupdf/ucdn.h>
#include <CoreText/CoreText.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern fz_context *lf_new_context(size_t);
extern void lf_install_system_fonts(fz_context *);
static int failures;
static void check(int ok, const char *what) { if (!ok) { fprintf(stderr,"FAIL %s\n",what); ++failures; } }
static unsigned u16(const unsigned char *p) { return p[0]*256u+p[1]; }
static unsigned u32(const unsigned char *p) { return u16(p)*65536u+u16(p+2); }
static void put16(unsigned char *p,unsigned n) { p[0]=n>>8; p[1]=n; }
static void put32(unsigned char *p,unsigned n) { put16(p,n>>16); put16(p+2,n); }
// Keep bundled, real glyph outlines and replace only their Unicode assignments.
// Adjacent glyph IDs force bfranges across BMP and low-surrogate boundaries.
static const unsigned scalars[]={0x41,0x42,0xfffe,0xffff,0x10000,0x10001,0x103fe,0x103ff,0x10400,0x10401,0x10402,0x1f600};
static fz_font *boundary_font(fz_context *ctx)
{
    int len,index; const unsigned char *original=fz_lookup_cjk_font(ctx,FZ_ADOBE_GB,&len,&index);
    if(!original || index!=0 || !memcmp(original,"ttcf",4)) fz_throw(ctx,FZ_ERROR_FORMAT,"boundary fixture requires standalone bundled TTF");
    unsigned cmap_len=12+16+12*(sizeof(scalars)/sizeof(*scalars));
    unsigned char *bytes=fz_malloc(ctx,len+cmap_len); memcpy(bytes,original,len); memset(bytes+len,0,cmap_len);
    unsigned char *cmap=bytes+len; put16(cmap+2,1); put16(cmap+4,3); put16(cmap+6,10); put32(cmap+8,12);
    unsigned char *sub=cmap+12; put16(sub,12); put32(sub+4,cmap_len-12); put32(sub+12,sizeof(scalars)/sizeof(*scalars));
    for (unsigned i=0;i<sizeof(scalars)/sizeof(*scalars);++i) {
        put32(sub+16+12*i,scalars[i]); put32(sub+20+12*i,scalars[i]);
        // U+10401/U+10402 deliberately share one glyph; existing reverse cmap selects the last scalar.
        put32(sub+24+12*i,20+(i==10?9:i));
    }
    for(unsigned i=0;i<u16(bytes+4);++i) {
        unsigned char *table=bytes+12+i*16;
        if(!memcmp(table,"cmap",4)) { put32(table+8,len); put32(table+12,cmap_len); }
    }
    fz_buffer *buf=fz_new_buffer_from_data(ctx,bytes,len+cmap_len);
    fz_font *font=fz_new_font_from_buffer(ctx,"SupplementaryBoundary",buf,0,0);
    fz_drop_buffer(ctx,buf); return font;
}
static const char *expected="AB\xef\xbf\xbe\xef\xbf\xbf\xf0\x90\x80\x80\xf0\x90\x80\x81\xf0\x90\x8f\xbe\xf0\x90\x8f\xbf\xf0\x90\x90\x80\xf0\x90\x90\x82\xf0\x9f\x98\x80";
static pdf_document *make_boundary(fz_context *ctx)
{
    pdf_document *doc=pdf_create_document(ctx); fz_font *font=boundary_font(ctx);
    pdf_obj *fonts=pdf_new_dict(ctx,doc,1),*resources=pdf_new_dict(ctx,doc,1),*page;
    pdf_dict_puts_drop(ctx,fonts,"F0",pdf_add_cid_font(ctx,doc,font));
    pdf_dict_put(ctx,resources,PDF_NAME(Font),fonts);
    fz_buffer *contents=fz_new_buffer(ctx,100);
    fz_append_string(ctx,contents,"BT /F0 16 Tf 20 80 Td <");
    for(unsigned i=0;i<sizeof(scalars)/sizeof(*scalars);++i) if(i!=10)
        fz_append_printf(ctx,contents,"%04x",fz_encode_character(ctx,font,scalars[i]));
    fz_append_string(ctx,contents,"> Tj ET");
    page=pdf_add_page(ctx,doc,fz_make_rect(0,0,500,150),0,resources,contents); pdf_insert_page(ctx,doc,0,page);
    pdf_drop_obj(ctx,page); pdf_drop_obj(ctx,fonts); pdf_drop_obj(ctx,resources); fz_drop_buffer(ctx,contents); fz_drop_font(ctx,font);
    return doc;
}
static pdf_document *make_rich(fz_context *ctx,const char *text)
{
    pdf_document *doc=pdf_create_document(ctx);
    pdf_obj *obj=pdf_add_page(ctx,doc,fz_make_rect(0,0,500,150),0,NULL,NULL); pdf_insert_page(ctx,doc,0,obj); pdf_drop_obj(ctx,obj);
    pdf_page *page=pdf_load_page(ctx,doc,0); pdf_annot *annot=pdf_create_annot(ctx,page,PDF_ANNOT_FREE_TEXT);
    pdf_set_annot_rect(ctx,annot,fz_make_rect(20,40,480,100)); pdf_set_annot_border_width(ctx,annot,0);
    float black[3]={0,0,0}; pdf_set_annot_default_appearance(ctx,annot,"Helv",16,3,black);
    pdf_set_annot_contents(ctx,annot,text); pdf_set_annot_rich_defaults(ctx,annot,"font-family:Helvetica;font-size:16pt;color:#000000;text-align:left;");
    pdf_update_annot(ctx,annot);
    // A second page runs exactly the annotation appearance as page content for
    // the independent platform extractor, whose page API omits annotations.
    pdf_obj *ap=pdf_dict_getp(ctx,pdf_annot_obj(ctx,annot),"AP/N");
    pdf_obj *resources=pdf_new_dict(ctx,doc,1),*x=pdf_dict_put_dict(ctx,resources,PDF_NAME(XObject),1);
    pdf_dict_puts(ctx,x,"A",ap); fz_buffer *contents=fz_new_buffer(ctx,30); fz_append_string(ctx,contents,"q /A Do Q");
    obj=pdf_add_page(ctx,doc,fz_make_rect(0,0,500,150),0,resources,contents); pdf_insert_page(ctx,doc,1,obj);
    pdf_drop_obj(ctx,obj); pdf_drop_obj(ctx,resources); fz_drop_buffer(ctx,contents); pdf_drop_annot(ctx,annot); fz_drop_page(ctx,(fz_page*)page);
    return doc;
}
static int inspect(fz_context *ctx,pdf_document *doc,int number,const char *text,int require)
{
    pdf_page *page=pdf_load_page(ctx,doc,number);
    pdf_obj *resources=pdf_page_resources(ctx,page);
    if(pdf_first_annot(ctx,page)) resources=pdf_dict_getp(ctx,pdf_annot_obj(ctx,pdf_first_annot(ctx,page)),"AP/N/Resources");
    pdf_obj *fonts=pdf_dict_get(ctx,resources,PDF_NAME(Font));
    // The platform page references its original appearance as an XObject.
    if(!fonts) resources=pdf_dict_getp(ctx,resources,"XObject/A/Resources"), fonts=pdf_dict_get(ctx,resources,PDF_NAME(Font));
    int embedded=0; size_t bytes=0;
    for(int i=0;i<pdf_dict_len(ctx,fonts);++i) {
        pdf_obj *font=pdf_dict_get_val(ctx,fonts,i),*children=pdf_dict_get(ctx,font,PDF_NAME(DescendantFonts));
        if(pdf_array_len(ctx,children)) font=pdf_array_get(ctx,children,0);
        pdf_obj *desc=pdf_dict_get(ctx,font,PDF_NAME(FontDescriptor));
        pdf_obj *stream=pdf_dict_get(ctx,desc,PDF_NAME(FontFile2));
        if(!stream) stream=pdf_dict_get(ctx,desc,PDF_NAME(FontFile3));
        if(stream) { fz_buffer *buf=pdf_load_stream(ctx,stream); ++embedded; bytes+=fz_buffer_storage(ctx,buf,NULL); fz_drop_buffer(ctx,buf); }
    }
    if(require) check(embedded>0,"real font bytes remain embedded");
    printf("page=%d embedded=%d font-bytes=%zu\n",number,embedded,bytes);
    fz_stext_page *st=fz_new_stext_page(ctx,fz_make_rect(0,0,500,150));
    fz_device *dev=fz_new_stext_device(ctx,st,NULL); fz_run_page(ctx,(fz_page*)page,dev,fz_identity,NULL); fz_close_device(ctx,dev);
    char *copy=fz_copy_rectangle(ctx,st,fz_make_rect(0,0,500,150),0); int ok=strstr(copy,text)!=NULL;
    printf("page=%d expected=[%s] actual=[%s] extraction=%s\n",number,text,copy,ok?"PASS":require?"FAIL":"OPEN");
    if(require) check(ok,"every expected scalar extracts exactly");
    fz_pixmap *pix=fz_new_pixmap_from_page(ctx,(fz_page*)page,fz_identity,fz_device_rgb(ctx),0);
    int ink=0; for(int y=0;y<fz_pixmap_height(ctx,pix);++y) { unsigned char *p=fz_pixmap_samples(ctx,pix)+y*fz_pixmap_stride(ctx,pix); for(int x=0;x<fz_pixmap_width(ctx,pix);++x) if(p[x*3]<128 && p[x*3+1]<128 && p[x*3+2]<128) ++ink; }
    if(require) check(ink>10,"real glyph pixels render"); printf("page=%d ink=%d\n",number,ink);
    fz_drop_pixmap(ctx,pix); fz_free(ctx,copy); fz_drop_device(ctx,dev); fz_drop_stext_page(ctx,st); fz_drop_page(ctx,(fz_page*)page); return ok;
}
static void save_case(fz_context *ctx,const char *dir,const char *name,pdf_document *doc,const char *text,int required)
{
    size_t full_bytes=0;
    for(int subset=0;subset<2;++subset) {
        char path[4096]; snprintf(path,sizeof(path),"%s/%s-%s.pdf",dir,name,subset?"subset":"full");
        if(subset) pdf_subset_fonts(ctx,doc,0,NULL);
        pdf_write_options options=pdf_default_write_options; options.do_compress=1;
        pdf_save_document(ctx,doc,path,&options); pdf_document *reopened=pdf_open_document(ctx,path);
        for(int p=0;p<pdf_count_pages(ctx,reopened);++p) inspect(ctx,reopened,p,text,required);
        pdf_drop_document(ctx,reopened);
        fz_buffer *saved=fz_read_file(ctx,path); size_t size=fz_buffer_storage(ctx,saved,NULL); fz_drop_buffer(ctx,saved);
        if(subset && required) check(size<full_bytes,"font subsetting reduces saved embedded bytes");
        if(!subset) full_bytes=size;
    }
}
static void diagnose_han(fz_context *ctx)
{
    fz_font *bundle=fz_load_fallback_font(ctx,UCDN_SCRIPT_HAN,FZ_LANG_UNSET,0,0,0);
    printf("U20000 bundled=%s glyph=%d\n",fz_font_name(ctx,bundle),fz_encode_character(ctx,bundle,0x20000));
    UniChar chars[]={0xd840,0xdc00}; CFStringRef sample=CFStringCreateWithCharacters(NULL,chars,2);
    CTFontRef base=CTFontCreateWithNameAndOptions(CFSTR("Helvetica"),12,NULL,kCTFontOptionsPreventAutoActivation|kCTFontOptionsPreventAutoDownload);
    CTFontRef font=CTFontCreateForStringWithLanguage(base,sample,CFRangeMake(0,2),NULL);
    CFStringRef ps=CTFontCopyPostScriptName(font); CFURLRef url=CTFontCopyAttribute(font,kCTFontURLAttribute);
    char name[512]={0},path[4096]={0}; CFStringGetCString(ps,name,sizeof(name),kCFStringEncodingUTF8);
    int present=url && CFURLGetFileSystemRepresentation(url,true,(UInt8*)path,sizeof(path));
    printf("U20000 CoreText selected=%s file=%s\n",name,present?path:"none");
    if(present) {
        fz_buffer *data=fz_read_file(ctx,path); int faces=1,found=0;
        for(int i=0;i<faces;++i) {
            fz_font *ft=fz_new_font_from_buffer(ctx,NULL,data,i,0); FT_Face face=fz_font_ft_face(ctx,ft);
            fz_ft_lock(ctx); faces=face->num_faces; const char *actual=FT_Get_Postscript_Name(face); int match=actual && !strcmp(actual,name); fz_ft_unlock(ctx);
            if(match) { printf("U20000 selected FreeType face=%d glyph=%d bytes=%zu accepted=%s\n",i,fz_encode_character(ctx,ft,0x20000),fz_buffer_storage(ctx,data,NULL),!strcmp(name,"LastResort")?"NO (LastResort missing-script box)":"glyph required"); found=1; }
            fz_drop_font(ctx,ft); if(found) break;
        }
        check(found,"CoreText-selected file resolves to its actual FreeType face"); fz_drop_buffer(ctx,data);
    }
    if(url) CFRelease(url); CFRelease(ps); CFRelease(font); CFRelease(base); CFRelease(sample);
}
int main(int argc,char **argv)
{
    if(argc!=2) return 2; fz_context *ctx=lf_new_context(64<<20); if(!ctx)return 2; lf_install_system_fonts(ctx);
    fz_try(ctx) {
        pdf_document *doc=make_boundary(ctx); inspect(ctx,doc,0,expected,1); save_case(ctx,argv[1],"boundary",doc,expected,1); pdf_drop_document(ctx,doc);
        doc=make_rich(ctx,"Latin 😀"); inspect(ctx,doc,0,"Latin 😀",1); save_case(ctx,argv[1],"emoji",doc,"Latin 😀",1); pdf_drop_document(ctx,doc);
        // A failed glyph remains an explicit OPEN observation; it cannot make a support claim.
        diagnose_han(ctx); doc=make_rich(ctx,"Latin 𠀀"); inspect(ctx,doc,0,"Latin 𠀀",0); save_case(ctx,argv[1],"rare-han-open",doc,"Latin 𠀀",0); pdf_drop_document(ctx,doc);
    } fz_catch(ctx) { fprintf(stderr,"FAIL exception: %s\n",fz_caught_message(ctx)); ++failures; }
    fz_drop_context(ctx); printf("failures=%d rare-han-glyph=OPEN\n",failures); return failures?1:0;
}
