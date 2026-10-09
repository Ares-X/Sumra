/* Printable LTR and guarded fallback behavior at the existing Bidi owner. */
#include "mupdf/fitz.h"
#include "mupdf/ucdn.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#ifdef SUMRA_BIDI_REFERENCE
void sumra_reference_bidi(fz_context *, const uint32_t *, size_t,
    fz_bidi_direction *, fz_bidi_fragment_fn *, void *, int);
#endif

typedef struct { size_t offset, length; int level, script; } fragment;
typedef struct { const uint32_t *text; size_t count; fragment pieces[128]; } result;

static void capture(const uint32_t *text, size_t length, int level, int script, void *opaque)
{
    result *value = opaque;
    assert(value->count < 128);
    value->pieces[value->count++] = (fragment){ text - value->text, length, level, script };
}

static void check(fz_context *ctx, const uint32_t *text, size_t length,
    fz_bidi_direction direction, int flags, int printable_ltr)
{
    result actual = { .text = text };
    fz_bidi_direction final = direction;
    fz_bidi_fragment_text(ctx, text, length, &final, capture, &actual, flags);
    if (printable_ltr)
    {
        assert(final == FZ_BIDI_LTR && actual.count == 1);
        assert(actual.pieces[0].offset == 0 && actual.pieces[0].length == length);
        assert(actual.pieces[0].level == 0 && actual.pieces[0].script == UCDN_SCRIPT_LATIN);
    }
#ifdef SUMRA_BIDI_REFERENCE
    result expected = { .text = text };
    fz_bidi_direction old_final = direction;
    sumra_reference_bidi(ctx, text, length, &old_final, capture, &expected, flags);
    assert(final == old_final && actual.count == expected.count);
    for (size_t i = 0; i < actual.count; ++i)
    {
        fragment a = actual.pieces[i], b = expected.pieces[i];
        assert(a.offset == b.offset && a.length == b.length && a.level == b.level && a.script == b.script);
    }
#endif
}

int main(void)
{
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    assert(ctx);
    uint32_t text[128], random = 19;
    for (size_t i = 0; i < 95; ++i) text[i] = 0x20 + i;
    check(ctx, text, 95, FZ_BIDI_LTR, 0, 1);
    for (size_t i = 0; i < 95; ++i) check(ctx, text + i, 1, FZ_BIDI_LTR, 0, 1);
    for (int run = 0; run < 1024; ++run)
    {
        for (size_t i = 0; i < 64; ++i)
        {
            random = random * 1664525u + 1013904223u;
            text[i] = 0x20 + random % 95;
        }
        check(ctx, text, 64, FZ_BIDI_LTR, 0, 1);
        check(ctx, text, 64, FZ_BIDI_RTL, 0, 0);
        check(ctx, text, 64, FZ_BIDI_NEUTRAL, 0, 0);
        check(ctx, text, 64, FZ_BIDI_LTR, FZ_BIDI_CLASSIFY_WHITE_SPACE, 0);
    }
    const uint32_t mixed[] = { 'a', '1', ' ', 0x05e9, 0x05dc, '2', ' ', 0x0627, 0x0644, 0x4e16, 0x0301, 'Z' };
    const uint32_t controls[] = { 'a', '\t', '1', '\n', 0x202e, '2', 0x202c, 0x2067, '3', 0x2069, 'Z' };
    for (int direction = FZ_BIDI_LTR; direction <= FZ_BIDI_UNSET; ++direction)
        for (int flags = 0; flags < 4; ++flags)
        {
            check(ctx, mixed, sizeof(mixed)/sizeof(*mixed), direction, flags, 0);
            check(ctx, controls, sizeof(controls)/sizeof(*controls), direction, flags, 0);
        }
    fz_drop_context(ctx);
    puts("Printable LTR fragments and guarded mixed/RTL/control cases pass.");
    return 0;
}
