/* Word metadata must remain within its allocation when shaping splits text.
 * This is an internal memory-boundary regression, not a product interface. */
#include "html-imp.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static fz_html_flow *word(const char *text, uint32_t offset, int lang, size_t *size)
{
	*size = fz_html_flow_word_size(strlen(text), offset, lang);
	fz_html_flow *flow = calloc(1, *size + 16);
	assert(flow);
	memset((unsigned char *)flow + *size, 0xa5, 16);
	flow->type = FLOW_WORD;
	flow->source_node = 0xf0123456;
	strcpy(fz_html_flow_text(flow), text);
	fz_html_flow_set_word_metadata(flow, offset, lang);
	return flow;
}

static void verify(fz_html_flow *flow, size_t size, const char *text, uint32_t offset, int lang)
{
	assert(strcmp(fz_html_flow_text_const(flow), text) == 0);
	assert(flow->source_node == 0xf0123456);
	assert(fz_html_flow_source_offset(flow) == offset);
	assert(fz_html_flow_markup_lang(flow) == lang);
	for (size_t i = 0; i < 16; ++i)
		assert(((unsigned char *)flow)[size + i] == 0xa5);
}

static void shorten(fz_html_flow *flow, size_t step)
{
	uint32_t offset = fz_html_flow_source_offset(flow);
	int lang = fz_html_flow_markup_lang(flow);
	size_t length = strlen(fz_html_flow_text_const(flow));
	assert(step < length);
	memmove(fz_html_flow_text(flow), fz_html_flow_text_const(flow) + step, length - step + 1);
	fz_html_flow_set_word_metadata(flow, offset + step, lang);
}

int main(void)
{
	const char *text = "abcdefghijklmnop";
	const uint32_t offsets[] = {0, 1, 2, 3, 4, 0xfffffff0};
	const int languages[] = {FZ_LANG_UNSET, FZ_LANG_zh_Hans, FZ_LANG_TAG3('e', 'n', 'g')};
	for (size_t l = 0; l < sizeof(languages) / sizeof(languages[0]); ++l)
		for (size_t o = 0; o < sizeof(offsets) / sizeof(offsets[0]); ++o)
			for (size_t step = 1; step <= 4; ++step)
			{
				size_t size;
				fz_html_flow *flow = word(text, offsets[o], languages[l], &size);
				verify(flow, size, text, offsets[o], languages[l]);
				shorten(flow, step);
				verify(flow, size, text + step, offsets[o] + step, languages[l]);
				shorten(flow, 1);
				verify(flow, size, text + step + 1, offsets[o] + step + 1, languages[l]);
				free(flow);
			}
	puts("word mutation preserves source identity, language and allocation boundaries");
	return 0;
}
