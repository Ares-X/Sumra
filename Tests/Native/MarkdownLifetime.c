// Isolated converter ownership regression; no production instrumentation.
// Include md.c to exercise its static converter, replacing only the copy and
// extension lookup boundaries. Export renames allow linking the normal archive.
// This single-threaded process temporarily tracks the default cmark allocator;
// persistent extension registration is warmed before tracking and retained.
#include <mupdf/fitz.h>
#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"
#include "registry.h"
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
static void check(int ok, const char *why)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", why); ++failures; }
}

typedef struct tracked { void *ptr; size_t size; struct tracked *next; } tracked;
static tracked *live;
static size_t live_count, allocations;
static cmark_mem original_cmark;

static tracked **find_allocation(void *ptr)
{
    tracked **entry = &live;
    while (*entry && (*entry)->ptr != ptr) entry = &(*entry)->next;
    return entry;
}
static void remember(void *ptr, size_t size)
{
    tracked *entry = malloc(sizeof(*entry));
    if (!entry || !ptr) abort();
    *entry = (tracked){ptr, size, live}; live = entry;
    ++live_count; ++allocations;
}
static void *tracked_calloc(size_t count, size_t size)
{
    if (size && count > SIZE_MAX / size) abort();
    void *ptr = original_cmark.calloc(count, size);
    remember(ptr, count * size);
    return ptr;
}
static void *tracked_realloc(void *ptr, size_t size)
{
    if (!ptr) {
        void *result = original_cmark.realloc(NULL, size);
        remember(result, size); return result;
    }
    tracked *entry = *find_allocation(ptr);
    // Reallocating the pre-existing extension registry would invalidate the
    // baseline and means this isolated test's tracking assumptions are wrong.
    if (!entry || !size) abort();
    void *result = original_cmark.realloc(ptr, size);
    if (!result) abort();
    entry->ptr = result; entry->size = size;
    return result;
}
static void tracked_free(void *ptr)
{
    if (!ptr) return;
    tracked **slot = find_allocation(ptr), *entry = *slot;
    if (!entry) {
        check(0, "conversion freed a retained baseline cmark allocation");
    } else {
        // Make a borrowed output detectably wrong even without a sanitizer.
        memset(ptr, 0xA5, entry->size);
        *slot = entry->next; free(entry); --live_count;
    }
    original_cmark.free(ptr);
}

// Fitz tracks all of its own allocations, including context/input baselines.
// Refuse the rendered payload size persistently so scavenging cannot mask OOM.
typedef union { max_align_t alignment; size_t size; } allocation;
static struct { size_t count, bytes, fail_size, refusals; } fitz;
static void *fitz_malloc(void *unused, size_t size)
{
    (void)unused;
    if (fitz.fail_size && size == fitz.fail_size) { ++fitz.refusals; return NULL; }
    allocation *a = malloc(sizeof(*a) + size);
    if (!a) return NULL;
    a->size = size; ++fitz.count; fitz.bytes += size; return a + 1;
}
static void fitz_free(void *unused, void *ptr)
{
    (void)unused;
    if (!ptr) return;
    allocation *a = (allocation *)ptr - 1;
    --fitz.count; fitz.bytes -= a->size; free(a);
}
static void *fitz_realloc(void *unused, void *ptr, size_t size)
{
    if (!ptr) return fitz_malloc(unused, size);
    if (!size) { fitz_free(unused, ptr); return NULL; }
    if (fitz.fail_size && size == fitz.fail_size) { ++fitz.refusals; return NULL; }
    allocation *a = (allocation *)ptr - 1;
    size_t old = a->size;
    a = realloc(a, sizeof(*a) + size);
    if (!a) return NULL;
    a->size = size; fitz.bytes = fitz.bytes - old + size; return a + 1;
}

static const char mixed[] =
    "# 标题 café\n\n"
    "| Key | Value |\n| --- | --- |\n| 中文 | ~~deleted~~ |\n\n"
    "- [x] completed\n- [ ] pending\n\n"
    "https://example.com\n\nFootnote[^note].\n\n"
    "[^note]: Footnote body.\n\n"
    "<div>Raw HTML 中文</div>\n\n<script>filtered</script>\n";
static int inject_copy_failure, inject_missing_extension, copy_calls;
static unsigned char *boundary_copy;
static size_t boundary_size;

static fz_buffer *copy_boundary(fz_context *ctx, const unsigned char *data, size_t size)
{
    ++copy_calls;
    tracked *output = *find_allocation((void *)data);
    check(live_count == 1 && output && output->size >= size,
        "copy boundary must own only detached HTML, with no live parser/AST allocations");
    check(size && data[size - 1] == 0 && strlen((const char *)data) + 1 == size,
        "copy includes exactly the rendered HTML and its terminator");
    free(boundary_copy);
    boundary_copy = malloc(size);
    if (!boundary_copy) abort();
    memcpy(boundary_copy, data, size); boundary_size = size;
    if (inject_copy_failure) fitz.fail_size = size > 1 ? size : 16;
    // Call the real Fitz function with the real test-owned allocator; the
    // resulting exception passes through md.c's actual fz_always/fz_catch.
    return fz_new_buffer_from_copied_data(ctx, data, size);
}
static cmark_syntax_extension *find_extension(const char *name)
{
    if (inject_missing_extension && !strcmp(name, "table")) return NULL;
    return cmark_find_syntax_extension(name);
}

#define fz_new_buffer_from_copied_data copy_boundary
#define cmark_find_syntax_extension find_extension
#define fz_register_markdown_plugins lifetime_register_markdown_plugins
#define md_document_handler lifetime_md_document_handler
#define fz_md_document_handler lifetime_fz_md_document_handler
#ifndef SUMRA_MARKDOWN_SOURCE
#define SUMRA_MARKDOWN_SOURCE "../../build/deps/mupdf/source/html/md.c"
#endif
#include SUMRA_MARKDOWN_SOURCE
#undef fz_new_buffer_from_copied_data
#undef cmark_find_syntax_extension
#undef fz_register_markdown_plugins
#undef md_document_handler
#undef fz_md_document_handler

typedef struct { int code, error_number; char message[256]; } cause;
static void capture(fz_context *ctx, cause *error)
{
    error->code = fz_caught(ctx);
    error->error_number = error->code == FZ_ERROR_SYSTEM ? fz_caught_errno(ctx) : 0;
    snprintf(error->message, sizeof(error->message), "%s", fz_caught_message(ctx));
}
static cause convert(fz_context *ctx, fz_buffer *input)
{
    fz_buffer *result = NULL;
    cause error = {0};
    size_t count = fitz.count, bytes = fitz.bytes, before_allocations = allocations;
    fz_var(result); fz_var(error);
    copy_calls = 0;
    fz_try(ctx)
    {
        result = fz_md_to_html(ctx, NULL, input, NULL, NULL);
        check(result && result->len == boundary_size &&
            !memcmp(result->data, boundary_copy, boundary_size),
            "Fitz output retains every byte after all cmark storage is released");
    }
    fz_always(ctx)
    {
        fitz.fail_size = 0;
        fz_drop_buffer(ctx, result);
    }
    fz_catch(ctx) capture(ctx, &error);
    check(allocations > before_allocations, "conversion exercised tracked cmark allocations");
    check(live_count == 0 && live == NULL, "conversion success/exception releases all cmark allocations");
    check(fitz.count == count && fitz.bytes == bytes, "conversion releases all incremental Fitz allocations");
    return error;
}
static void check_mixed_html(void)
{
    const char *html = (const char *)boundary_copy;
    const char *tokens[] = {"标题 café", "<h1 id=", "<table>", "中文", "<del>deleted</del>",
        "type=\"checkbox\" checked=", "type=\"checkbox\" disabled=", "completed", "pending",
        "href=\"https://example.com\"", "class=\"footnotes\"",
        "Footnote body.", "<div>Raw HTML 中文</div>", "&lt;script>", NULL};
    for (int i = 0; tokens[i]; ++i) check(strstr(html, tokens[i]) != NULL, tokens[i]);
}
int main(void)
{
    fz_alloc_context allocator = {NULL, fitz_malloc, fitz_realloc, fitz_free};
    fz_context *ctx = fz_new_context(&allocator, NULL, FZ_STORE_UNLIMITED);
    if (!ctx) return 2;
    fz_buffer *input = NULL, *empty = NULL;
    int fatal = 0;
    cmark_mem *mem = cmark_get_default_mem_allocator();
    original_cmark = *mem;
    fz_var(input); fz_var(empty); fz_var(fatal);
    fz_try(ctx)
    {
        lifetime_register_markdown_plugins(ctx);
        const char *names[] = {"table", "strikethrough", "autolink", "tagfilter", "tasklist", "autoheaderid"};
        cmark_syntax_extension *baseline[6];
        for (int i = 0; i < 6; ++i) {
            baseline[i] = cmark_find_syntax_extension(names[i]);
            check(baseline[i] != NULL, "expected registered extension baseline");
        }
        input = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)mixed, strlen(mixed));
        empty = fz_new_buffer(ctx, 16);
        fz_terminate_buffer(ctx, input); fz_terminate_buffer(ctx, empty);
        *mem = (cmark_mem){tracked_calloc, tracked_realloc, tracked_free};

        cause success = convert(ctx, input);
        check(!success.code && copy_calls == 1, "mixed conversion succeeds through copy boundary");
        if (success.code || copy_calls != 1)
            fz_throw(ctx, FZ_ERROR_GENERIC, "mixed fixture conversion failed: %s", success.message);
        check_mixed_html();

        // Establish the original exception using the SAME real Fitz function,
        // data length and allocator, then compare after converter cleanup.
        cause original = {0};
        size_t count = fitz.count, bytes = fitz.bytes;
        fz_var(original);
        fitz.fail_size = boundary_size;
        fz_try(ctx) {
            fz_buffer *unexpected = fz_new_buffer_from_copied_data(ctx, boundary_copy, boundary_size);
            fz_drop_buffer(ctx, unexpected);
        }
        fz_always(ctx) fitz.fail_size = 0;
        fz_catch(ctx) capture(ctx, &original);
        check(original.code == FZ_ERROR_SYSTEM && original.error_number == ENOMEM,
            "reference failure comes from the real Fitz allocation");
        check(fitz.count == count && fitz.bytes == bytes, "reference OOM releases partial Fitz buffer");

        size_t refusals = fitz.refusals;
        inject_copy_failure = 1;
        cause failed = convert(ctx, input);
        inject_copy_failure = 0;
        check(copy_calls == 1 && fitz.refusals > refusals, "copy failure exercised Fitz allocator refusal");
        check(failed.code == original.code && failed.error_number == original.error_number &&
            !strcmp(failed.message, original.message), "copy OOM retains its original code/errno/message");
        check_mixed_html();

        inject_missing_extension = 1;
        failed = convert(ctx, input);
        inject_missing_extension = 0;
        check(!copy_calls && failed.code == FZ_ERROR_LIBRARY &&
            !strcmp(failed.message, "cmark table extension not found"),
            "pre-render extension exception retains its original cause without entering copy");

        success = convert(ctx, empty);
        check(!success.code && copy_calls == 1 && boundary_size == 1 && boundary_copy[0] == 0,
            "empty conversion owns and copies an independent terminated output");
        success = convert(ctx, input);
        check(!success.code && copy_calls == 1, "conversion recovers after exceptions and empty input");
        if (!success.code) check_mixed_html();
        for (int i = 0; i < 6; ++i)
            check(cmark_find_syntax_extension(names[i]) == baseline[i], "retained extension registry survives every conversion");
    }
    fz_always(ctx)
    {
        *mem = original_cmark;
        fitz.fail_size = 0;
        fz_drop_buffer(ctx, input); fz_drop_buffer(ctx, empty);
        free(boundary_copy);
    }
    fz_catch(ctx) { fprintf(stderr, "Unexpected exception: %s\n", fz_caught_message(ctx)); fatal = 1; }
    fz_drop_context(ctx);
    check(fitz.count == 0 && fitz.bytes == 0, "context teardown releases its complete Fitz baseline");
    printf("{\"failures\":%d,\"fatal\":%d,\"cmarkAllocations\":%zu,\"cmarkLive\":%zu,"
        "\"fitzLive\":%zu,\"fitzRefusals\":%zu}\n", failures, fatal, allocations, live_count, fitz.count, fitz.refusals);
    return failures || fatal ? 1 : 0;
}
