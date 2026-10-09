#include <mupdf/fitz.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef union { max_align_t alignment; size_t size; } allocation;
typedef struct { size_t count, bytes, calls; size_t fail_at; int refusals; } tracking;
static void *alloc(void *state, size_t size)
{
	tracking *t = state;
	if (++t->calls >= t->fail_at && t->fail_at) { ++t->refusals; return NULL; }
	allocation *a = malloc(sizeof(*a) + size);
	if (!a) return NULL;
	a->size = size; ++t->count; t->bytes += size; return a + 1;
}
static void release(void *state, void *ptr)
{
	if (!ptr) return;
	tracking *t = state; allocation *a = (allocation *)ptr - 1;
	--t->count; t->bytes -= a->size; free(a);
}
static void *resize(void *state, void *ptr, size_t size)
{
	if (!ptr) return alloc(state, size);
	if (!size) { release(state, ptr); return NULL; }
	tracking *t = state;
	if (++t->calls >= t->fail_at && t->fail_at) { ++t->refusals; return NULL; }
	allocation *a = (allocation *)ptr - 1; size_t old = a->size;
	a = realloc(a, sizeof(*a) + size); if (!a) return NULL;
	a->size = size; t->bytes = t->bytes - old + size; return a + 1;
}
static void require(fz_context *ctx, int yes, const char *why)
{
	if (!yes) fz_throw(ctx, FZ_ERROR_GENERIC, "%s", why);
}
int main(void)
{
	tracking t = {0}; fz_alloc_context allocator = {&t, alloc, resize, release};
	fz_context *ctx = fz_new_context(&allocator, NULL, FZ_STORE_DEFAULT);
	if (!ctx) return 1;
	size_t before_count = t.count, before_bytes = t.bytes;
	fz_pool *pools[3] = {0}; int failed = 0;
	fz_var(pools); fz_var(failed); fz_var(t);
	fz_try(ctx)
	{
		for (int k = 0; k < 3; ++k) pools[k] = fz_new_pool(ctx);
		unsigned char *saved[256]; size_t sizes[256];
		for (int i = 0; i < 256; ++i)
		{
			size_t n = i == 0 ? 0 : (i == 255 ? 100003 : (size_t)(i * 19 % 997 + 1));
			saved[i] = fz_pool_alloc(ctx, pools[i % 3], n); sizes[i] = n;
			require(ctx, (uintptr_t)saved[i] % FZ_POINTER_ALIGN_MOD == 0, "pool pointer alignment");
			for (size_t j = 0; j < n; ++j) require(ctx, saved[i][j] == 0, "pool allocation not zeroed");
			memset(saved[i], i, n);
		}
		char *whole = fz_pool_strdup(ctx, pools[0], "retained string");
		char *part = fz_pool_strndup(ctx, pools[1], "truncated string", 9);
		fz_pool_array *arr = fz_new_pool_array_imp(ctx, pools[2], sizeof(size_t), 3);
		size_t *elements[257];
		for (size_t i = 0; i < 257; ++i)
		{
			size_t index = SIZE_MAX; elements[i] = fz_pool_array_append(ctx, arr, &index);
			require(ctx, index == i && *elements[i] == 0, "pool array append contract"); *elements[i] = i * 13 + 7;
		}
		require(ctx, fz_pool_array_len(ctx, arr) == 257, "pool array length");
		for (size_t i = 0; i < 257; ++i) require(ctx, *elements[i] == i * 13 + 7, "pool array data after growth");
		for (int i = 0; i < 256; ++i)
			for (size_t j = 0; j < sizes[i]; ++j) require(ctx, saved[i][j] == (unsigned char)i, "data after pool growth");
		require(ctx, !strcmp(whole, "retained string") && !strcmp(part, "truncated"), "pool strings");
		for (int k = 1; k >= 0; --k) { fz_drop_pool(ctx, pools[k]); pools[k] = NULL; }
		require(ctx, *elements[256] == 256 * 13 + 7, "independent pool lifetime");
		fz_drop_pool(ctx, pools[2]); pools[2] = NULL;
		require(ctx, t.count == before_count && t.bytes == before_bytes, "pool cleanup baseline");
		for (int pass = 0; pass < 4; ++pass)
		{
			int caught = 0; char *value = NULL;
			fz_var(caught); fz_var(value);
			if (pass >= 2) { pools[0] = fz_new_pool(ctx); value = fz_pool_strdup(ctx, pools[0], "survives failed growth"); }
			t.fail_at = t.calls + (pass == 1 ? 2 : 1); int refusals = t.refusals;
			fz_try(ctx)
			{
				if (pass < 2) pools[0] = fz_new_pool(ctx);
				else if (pass == 2) fz_pool_alloc(ctx, pools[0], 100003);
				else for (int i = 0; i < 10000; ++i) fz_pool_alloc(ctx, pools[0], 127);
			}
			fz_catch(ctx)
			{
				caught = fz_caught(ctx) == FZ_ERROR_SYSTEM;
				printf("OOM pass=%d code=%d cause=%s\n", pass, fz_caught(ctx), fz_caught_message(ctx));
				fz_report_error(ctx);
			}
			t.fail_at = 0;
			require(ctx, caught && t.refusals > refusals, "pool OOM cause not propagated");
			if (value) require(ctx, !strcmp(value, "survives failed growth"), "failed growth damaged existing data");
			fz_drop_pool(ctx, pools[0]); pools[0] = NULL;
			require(ctx, t.count == before_count && t.bytes == before_bytes, "failed pool operation leaked allocation");
		}
	}
	fz_catch(ctx) { fprintf(stderr, "FAIL: %s\n", fz_caught_message(ctx)); fz_report_error(ctx); failed = 1; }
	for (int k = 0; k < 3; ++k) fz_drop_pool(ctx, pools[k]);
	fz_drop_context(ctx);
	if (t.count || t.bytes) failed = 1;
	if (!failed) puts("pool zero/small/oversize/alignment/strings/array growth/multiple lifetimes/OOM cleanup PASS");
	return failed;
}
