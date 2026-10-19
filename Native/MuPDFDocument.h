#pragma once
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>

// One actor-owned document supplies reading, editing and its undo journal.
// Native editing invalidates cached pages/display lists, not this owner.
typedef struct SumraMuPDFReplayLock SumraMuPDFReplayLock;
typedef struct SumraMuPDFDocument {
    fz_context *ctx;
    fz_document *doc;
    fz_page *render_page;
    fz_display_list *display_list;
    fz_store_drop_fn *display_list_drop;
    fz_stext_page *text_page;
    fz_device *color_analysis;
    SumraMuPDFReplayLock *replay_lock;
    int render_chapter, render_index;
    int saved_journal_position, journal_nesting, journal_start_position;
    int authentication; // MuPDF: 1 = unencrypted, 2 = user, 4 = owner.
    int editing_enabled;
    int hide_annotations;
} SumraMuPDFDocument;

void lf_drop_render_page(SumraMuPDFDocument *document);
void lf_prepare_pdf_colors(fz_context *ctx, fz_display_list *list, fz_device **analysis,
    fz_rect box, const int *style, fz_cookie *cookie);
void lf_run_pdf_colors(fz_context *ctx, fz_display_list *list, fz_device **analysis,
    fz_rect box, fz_rect clip, fz_matrix ctm, float zoom, fz_pixmap *pix,
    const int *style, const uint32_t *colors, fz_cookie *cookie);
