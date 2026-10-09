// MarkdownToc.cpp from SumatraPDF, pinned 012d997f6a3a5c5c97b878e1a340db3bffde8c0e.
// GPL-3.0-or-later. Platform adapter uses the already bundled cmark-gfm parser.
#include "Engine.h"
#include <mupdf/fitz.h>
#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"
#include <errno.h>

// Shared with MuPDF's fixed-page Markdown adapter: registering cmark twice is invalid.
void fz_register_markdown_plugins(fz_context *ctx);

static cmark_node *parse_markdown(fz_context *ctx, const char *path, cmark_parser **parser) {
    FILE *source = NULL;
    cmark_node *document = NULL;
    fz_var(source); fz_var(document);
    fz_try(ctx) {
        source = fopen(path, "rb");
        if (!source) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot open Markdown: %s", strerror(errno));
        fz_register_markdown_plugins(ctx);
        *parser = cmark_parser_new(CMARK_OPT_DEFAULT);
        if (!*parser) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate Markdown parser");
        const char *extensions[] = { "table", "strikethrough", "autolink", "tagfilter", "tasklist" };
        for (size_t i = 0; i < sizeof(extensions) / sizeof(*extensions); ++i) {
            cmark_syntax_extension *extension = cmark_find_syntax_extension(extensions[i]);
            if (extension) cmark_parser_attach_syntax_extension(*parser, extension);
        }
        // cmark's streaming API preserves partial UTF-8 and long lines. Keep
        // the complete source out of memory while the parser builds its tree.
        unsigned char chunk[64 * 1024];
        size_t length;
        while ((length = fread(chunk, 1, sizeof(chunk), source)) != 0)
            cmark_parser_feed(*parser, (const char *)chunk, length);
        if (ferror(source)) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot read Markdown: %s", strerror(errno));
        document = cmark_parser_finish(*parser);
        if (!document) fz_throw(ctx, FZ_ERROR_LIBRARY, "Cannot parse Markdown");
    }
    fz_always(ctx) { if (source) fclose(source); }
    fz_catch(ctx) { fz_rethrow(ctx); }
    return document;
}

static void heading_text(fz_context *ctx, fz_buffer *out, cmark_node *node) {
    cmark_node_type type = cmark_node_get_type(node);
    if (type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE) {
        const char *text = cmark_node_get_literal(node);
        if (text) fz_append_string(ctx, out, text);
        return;
    }
    for (cmark_node *child = cmark_node_first_child(node); child; child = cmark_node_next(child))
        heading_text(ctx, out, child);
}

static int slug_space(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

static void heading_json(fz_context *ctx, SumraJSON *json, const char *title, const char *id, int depth) {
    char *target = id && *id ? fz_asprintf(ctx, "#%s", id) : NULL;
    lf_json(json, "{\"title\":"); lf_json_string(json, title);
    lf_json(json, ",\"target\":"); lf_json_string(json, target);
    lf_json(json, ",\"depth\":"); lf_json_number(json, depth); lf_json(json, "}");
    fz_free(ctx, target);
}

// MarkdownHeadingSlug: keep '_' and each separator; preserve UTF-8 rather than
// cmark's autoheaderid rules, so links authored for GitHub resolve to the same ids.
static void heading_slug(fz_buffer *text) {
    unsigned char *start = text->data, *end = start + text->len, *out = start;
    while (start < end && slug_space(*start)) ++start;
    while (end > start && slug_space(end[-1])) --end;
    while (start < end) {
        unsigned char c = *start++;
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (c >= 0x80 || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') *out++ = c;
        else if (slug_space(c)) *out++ = '-';
    }
    text->len = out - text->data;
}

static cmark_node *anchor_node(fz_context *ctx, cmark_node_type type, const char *id, size_t length) {
    cmark_node *node = cmark_node_new(type);
    if (!node) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate Markdown anchor");
    fz_buffer *html = NULL;
    fz_var(html);
    fz_try(ctx) {
        html = fz_new_buffer(ctx, length + 20);
        fz_append_string(ctx, html, "<a id=\"");
        fz_append_data(ctx, html, id, length);
        fz_append_string(ctx, html, "\"></a>");
        fz_terminate_buffer(ctx, html);
        if (!cmark_node_set_on_enter(node, (const char *)html->data))
            fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot write Markdown anchor");
    }
    fz_always(ctx) { fz_drop_buffer(ctx, html); }
    fz_catch(ctx) { cmark_node_free(node); fz_rethrow(ctx); }
    return node;
}

static int safe_anchor(const char *raw, const char *suffix, const char **id, size_t *length) {
    if (!raw) return 0;
    const char *end = raw + strlen(raw);
    while (raw < end && slug_space(*raw)) ++raw;
    while (end > raw && slug_space(end[-1])) --end;
    size_t prefix_length = 7, suffix_length = strlen(suffix);
    if ((size_t)(end - raw) <= prefix_length + suffix_length || strncmp(raw, "<a id=\"", prefix_length) ||
        memcmp(end - suffix_length, suffix, suffix_length)) return 0;
    *id = raw + prefix_length;
    *length = (size_t)(end - suffix_length - *id);
    for (size_t i = 0; i < *length; ++i) {
        unsigned char c = (*id)[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '-' || c == '_' || c == ':' || c == '.')) return 0;
    }
    return 1;
}

// PreserveSafeEmptyAnchors, without enabling cmark's unsafe HTML renderer.
static void preserve_anchors(fz_context *ctx, cmark_node *parent) {
    for (cmark_node *node = cmark_node_first_child(parent); node;) {
        cmark_node *next = cmark_node_next(node);
        cmark_node_type type = cmark_node_get_type(node);
        if (type == CMARK_NODE_HTML_BLOCK || type == CMARK_NODE_HTML_INLINE) {
            const char *raw = cmark_node_get_literal(node), *id = NULL;
            size_t length = 0;
            cmark_node *close = NULL;
            int safe = safe_anchor(raw, "\"></a>", &id, &length);
            if (!safe && type == CMARK_NODE_HTML_INLINE && next &&
                cmark_node_get_type(next) == CMARK_NODE_HTML_INLINE && safe_anchor(raw, "\">", &id, &length)) {
                const char *literal = cmark_node_get_literal(next);
                if (literal) {
                    while (slug_space(*literal)) ++literal;
                    if (!strncmp(literal, "</a>", 4)) {
                        literal += 4;
                        while (slug_space(*literal)) ++literal;
                        if (!*literal) { safe = 1; close = next; }
                    }
                }
            }
            if (safe) {
                cmark_node *replacement = anchor_node(ctx, type == CMARK_NODE_HTML_BLOCK ? CMARK_NODE_CUSTOM_BLOCK : CMARK_NODE_CUSTOM_INLINE, id, length);
                if (cmark_node_insert_before(node, replacement)) {
                    if (close) { next = cmark_node_next(close); cmark_node_unlink(close); cmark_node_free(close); }
                    cmark_node_unlink(node); cmark_node_free(node);
                } else cmark_node_free(replacement);
            }
        } else preserve_anchors(ctx, node);
        node = next;
    }
}

// ParseMarkdownHeadings and AddHeadingAnchors share this walk. The foreground
// renderer returns the headings from its existing tree instead of reparsing the
// current book after WebKit has built its document.
static char *markdown_headings(fz_context *ctx, cmark_node *document, int anchors) {
    cmark_iter *iter = NULL;
    fz_buffer *title = NULL;
    SumraJSON json = {0};
    fz_var(iter); fz_var(title); fz_var(json);
    fz_try(ctx) {
        title = fz_new_buffer(ctx, 128);
        iter = cmark_iter_new(document);
        if (!iter) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot enumerate Markdown headings");
        lf_json(&json, "[");
        cmark_event_type event;
        int count = 0;
        while ((event = cmark_iter_next(iter)) != CMARK_EVENT_DONE) {
            if (event != CMARK_EVENT_ENTER) continue;
            cmark_node *node = cmark_iter_get_node(iter);
            if (cmark_node_get_type(node) != CMARK_NODE_HEADING) continue;
            title->len = 0;
            heading_text(ctx, title, node);
            if (!title->len) continue;
            fz_terminate_buffer(ctx, title);
            if (count++) lf_json(&json, ",");
            char *label = fz_strdup(ctx, (const char *)title->data);
            fz_try(ctx) {
                heading_slug(title); fz_terminate_buffer(ctx, title);
                heading_json(ctx, &json, label, (const char *)title->data, cmark_node_get_heading_level(node));
                if (anchors) {
                    cmark_node *anchor = anchor_node(ctx, CMARK_NODE_CUSTOM_BLOCK, (const char *)title->data, title->len);
                    if (!cmark_node_insert_before(node, anchor)) cmark_node_free(anchor);
                }
            }
            fz_always(ctx) { fz_free(ctx, label); }
            fz_catch(ctx) { fz_rethrow(ctx); }
        }
        lf_json(&json, "]");
        if (json.failed) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate Markdown headings");
    }
    fz_always(ctx) {
        if (iter) cmark_iter_free(iter);
        fz_drop_buffer(ctx, title);
    }
    fz_catch(ctx) { free(json.data); fz_rethrow(ctx); }
    return json.data;
}

// Both returned buffers use malloc/free, matching the engine's Data boundary.
API char *lf_markdown_render(const char *path, char **outline, char *error) {
    *outline = NULL;
    fz_context *ctx = lf_new_context(0);
    if (!ctx) { snprintf(error, 512, "Cannot create Markdown context"); return NULL; }
    cmark_parser *parser = NULL;
    cmark_node *document = NULL;
    char *body = NULL, *result = NULL, *headings = NULL;
    fz_var(parser); fz_var(document); fz_var(body); fz_var(result); fz_var(headings);
    fz_try(ctx) {
        document = parse_markdown(ctx, path, &parser);
        preserve_anchors(ctx, document);
        headings = markdown_headings(ctx, document, 1);
        // Resources use real file URLs; .md links need no synthetic .html rewrite.
        body = cmark_render_html(document, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(parser));
        if (!body) fz_throw(ctx, FZ_ERROR_LIBRARY, "Cannot render Markdown");
        cmark_node_free(document); document = NULL;
        cmark_parser_free(parser); parser = NULL;
        static const char prefix[] = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><link rel=\"stylesheet\" href=\"leaf://reader/markdown.css\"></head><body>";
        static const char suffix[] = "</body></html>";
        size_t body_length = strlen(body), prefix_length = sizeof(prefix) - 1;
        if (body_length > SIZE_MAX - prefix_length - sizeof(suffix))
            fz_throw(ctx, FZ_ERROR_SYSTEM, "Markdown HTML is too large");
        // cmark_render_html uses the default allocator (stdlib realloc/free;
        // thirdparty/cmark-gfm/src/cmark.c). Extend that allocation in place
        // instead of keeping a second complete HTML buffer for the wrapper.
        result = realloc(body, prefix_length + body_length + sizeof(suffix));
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Cannot allocate Markdown HTML");
        body = NULL;
        memmove(result + prefix_length, result, body_length);
        memcpy(result, prefix, prefix_length);
        memcpy(result + prefix_length + body_length, suffix, sizeof(suffix));
        *outline = headings; headings = NULL;
    }
    fz_always(ctx) {
        cmark_get_default_mem_allocator()->free(body);
        if (document) cmark_node_free(document);
        if (parser) cmark_parser_free(parser);
        free(headings);
    }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(result); result = NULL; }
    fz_drop_context(ctx);
    return result;
}

// ParseMarkdownHeadings: the host runs this off the WebKit/UI thread, publishes
// file entries immediately, then replaces them with the completed outline.
API char *lf_markdown_outline(const char *path, char *error) {
    fz_context *ctx = lf_new_context(0);
    if (!ctx) { snprintf(error, 512, "Cannot create Markdown context"); return NULL; }
    cmark_parser *parser = NULL;
    cmark_node *document = NULL;
    char *result = NULL;
    fz_var(parser); fz_var(document); fz_var(result);
    fz_try(ctx) {
        document = parse_markdown(ctx, path, &parser);
        result = markdown_headings(ctx, document, 0);
    }
    fz_always(ctx) {
        if (document) cmark_node_free(document);
        if (parser) cmark_parser_free(parser);
    }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(result); result = NULL; }
    fz_drop_context(ctx);
    return result;
}

static void html_heading_text(fz_context *ctx, fz_buffer *out, fz_xml *node) {
    for (; node; node = fz_xml_next(node)) {
        const char *text = fz_xml_text(node);
        if (text) fz_append_string(ctx, out, text);
        else html_heading_text(ctx, out, fz_xml_down(node));
    }
}

// ParseHtmlHeadingsData uses an HTML parser, not a layout tree. Gumbo is already
// bundled in MuPDF; this is the same h1...h6/text/id walk as Sumatra's TOC.
API char *lf_html_outline(const char *path, char *error) {
    fz_context *ctx = lf_new_context(0);
    if (!ctx) { snprintf(error, 512, "Cannot create HTML context"); return NULL; }
    fz_buffer *source = NULL, *title = NULL;
    fz_xml *document = NULL;
    SumraJSON json = {0};
    fz_var(source); fz_var(title); fz_var(document); fz_var(json);
    fz_try(ctx) {
        source = fz_read_file(ctx, path);
        document = fz_parse_xml_from_html5(ctx, source);
        title = fz_new_buffer(ctx, 128);
        lf_json(&json, "[");
        int count = 0;
        for (fz_xml *node = fz_xml_root(document); node;) {
            const char *tag = fz_xml_tag(node);
            if (tag && tag[0] == 'h' && tag[1] >= '1' && tag[1] <= '6' && !tag[2]) {
                title->len = 0;
                html_heading_text(ctx, title, fz_xml_down(node));
                while (title->len && slug_space(title->data[title->len - 1])) --title->len;
                fz_terminate_buffer(ctx, title);
                const char *text = (const char *)title->data;
                while (slug_space(*text)) ++text;
                if (*text) {
                    if (count++) lf_json(&json, ",");
                    heading_json(ctx, &json, text, fz_xml_att(node, "id"), tag[1] - '0');
                }
            }
            if (fz_xml_down(node)) node = fz_xml_down(node);
            else {
                while (node && !fz_xml_next(node)) node = fz_xml_up(node);
                if (node) node = fz_xml_next(node);
            }
        }
        lf_json(&json, "]");
    }
    fz_always(ctx) { fz_drop_xml(ctx, document); fz_drop_buffer(ctx, source); fz_drop_buffer(ctx, title); }
    fz_catch(ctx) { snprintf(error, 512, "%s", fz_convert_error(ctx, NULL)); free(json.data); json.data = NULL; json.failed = 0; }
    fz_drop_context(ctx);
    return lf_json_finish(&json, error);
}
