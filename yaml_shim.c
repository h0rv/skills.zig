/* Narrow libyaml adapter. No upstream source is copied into this file. */
#include <yaml.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int kind; const unsigned char *data; size_t len; int id; } sy_node;
typedef struct { size_t line, column; } sy_issue;
typedef struct { yaml_document_t document; } sy_document;

/* YAML 1.2 core scalar resolution. libyaml parses syntax but does not resolve
   implicit scalar tags. Quoted, block, and !!str or ! tagged values stay strings. */
static int eq(const unsigned char *s, size_t n, const char *v) {
    return n == strlen(v) && memcmp(s, v, n) == 0;
}
static int digit(unsigned char c) { return c >= '0' && c <= '9'; }
static int numeric(const unsigned char *s, size_t n) {
    size_t i = 0, before = 0, after = 0;
    if (i < n && (s[i] == '+' || s[i] == '-')) i++;
    if (eq(s+i, n-i, ".inf") || eq(s+i, n-i, ".Inf") || eq(s+i, n-i, ".INF")) return 1;
    if (eq(s, n, ".nan") || eq(s, n, ".NaN") || eq(s, n, ".NAN")) return 1;
    if (i == 0 && n > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'o')) {
        int hex = s[1] == 'x';
        for (i = 2; i < n; i++) {
            unsigned char c = s[i];
            if (!(hex ? (digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) : (c >= '0' && c <= '7'))) return 0;
        }
        return 1;
    }
    while (i < n && digit(s[i])) { before++; i++; }
    if (i < n && s[i] == '.') {
        i++;
        while (i < n && digit(s[i])) { after++; i++; }
    }
    if (before + after == 0) return 0;
    if (i < n && (s[i] == 'e' || s[i] == 'E')) {
        size_t exponent = 0;
        i++;
        if (i < n && (s[i] == '+' || s[i] == '-')) i++;
        while (i < n && digit(s[i])) { exponent++; i++; }
        if (!exponent) return 0;
    }
    return i == n;
}
static int string_scalar(const yaml_event_t *e) {
    const unsigned char *s = e->data.scalar.value;
    size_t n = e->data.scalar.length;
    if (e->data.scalar.tag)
        return strcmp((const char *)e->data.scalar.tag, YAML_STR_TAG) == 0 ||
               strcmp((const char *)e->data.scalar.tag, "!") == 0;
    if (e->data.scalar.style != YAML_PLAIN_SCALAR_STYLE) return 1;
    if (!n || eq(s,n,"~") || eq(s,n,"null") || eq(s,n,"Null") || eq(s,n,"NULL") ||
        eq(s,n,"true") || eq(s,n,"True") || eq(s,n,"TRUE") ||
        eq(s,n,"false") || eq(s,n,"False") || eq(s,n,"FALSE")) return 0;
    return !numeric(s, n);
}

/* Status: 0 success, 1 syntax, 2 unsupported type, 3 budget, 4 OOM,
   5 multiple documents. Event preflight bounds parser work before document load. */
int sy_parse(const unsigned char *text, size_t len, size_t max_nodes,
             size_t max_depth, sy_document **out, sy_issue *issue) {
    yaml_parser_t parser;
    yaml_event_t event;
    size_t nodes = 0, depth = 0, documents = 0;
    int status = 0, done = 0;
    *out = NULL;
    issue->line = issue->column = 0;
    if (!yaml_parser_initialize(&parser)) return 4;
    yaml_parser_set_input_string(&parser, text, len);
    while (!done) {
        if (!yaml_parser_parse(&parser, &event)) {
            issue->line = parser.problem_mark.line + 1;
            issue->column = parser.problem_mark.column + 1;
            status = parser.error == YAML_MEMORY_ERROR ? 4 : 1;
            break;
        }
        switch (event.type) {
        case YAML_DOCUMENT_START_EVENT: if (++documents > 1) status = 5; break;
        case YAML_MAPPING_START_EVENT:
        case YAML_SEQUENCE_START_EVENT:
            depth++;
            if (++nodes > max_nodes || depth > max_depth) status = 3;
            if (event.type == YAML_MAPPING_START_EVENT && event.data.mapping_start.tag &&
                strcmp((const char *)event.data.mapping_start.tag, YAML_MAP_TAG) != 0 &&
                strcmp((const char *)event.data.mapping_start.tag, "!") != 0) status = 2;
            break;
        case YAML_MAPPING_END_EVENT:
        case YAML_SEQUENCE_END_EVENT: depth--; break;
        case YAML_SCALAR_EVENT:
            if (++nodes > max_nodes) status = 3;
            else if (!string_scalar(&event)) status = 2;
            break;
        case YAML_ALIAS_EVENT:
            /* Aliases are supported by libyaml without recursive expansion. */
            if (++nodes > max_nodes) status = 3;
            break;
        case YAML_STREAM_END_EVENT: done = 1; break;
        default: break;
        }
        if (status) {
            issue->line = event.start_mark.line + 1;
            issue->column = event.start_mark.column + 1;
        }
        yaml_event_delete(&event);
        if (status) break;
    }
    yaml_parser_delete(&parser);
    if (status) return status;
    sy_document *doc = malloc(sizeof(*doc));
    if (!doc) return 4;
    if (!yaml_parser_initialize(&parser)) { free(doc); return 4; }
    yaml_parser_set_input_string(&parser, text, len);
    if (!yaml_parser_load(&parser, &doc->document)) {
        issue->line = parser.problem_mark.line + 1;
        issue->column = parser.problem_mark.column + 1;
        status = parser.error == YAML_MEMORY_ERROR ? 4 : 1;
        yaml_parser_delete(&parser);
        free(doc);
        return status;
    }
    yaml_parser_delete(&parser);
    *out = doc;
    return 0;
}
void sy_free(sy_document *doc) {
    yaml_document_delete(&doc->document);
    free(doc);
}
static sy_node node_view(sy_document *doc, int id) {
    yaml_node_t *n = yaml_document_get_node(&doc->document, id);
    sy_node v = { 0, NULL, 0, id };
    if (!n) return v;
    v.kind = n->type;
    if (n->type == YAML_SCALAR_NODE) { v.data = n->data.scalar.value; v.len = n->data.scalar.length; }
    if (n->type == YAML_MAPPING_NODE) v.len = (size_t)(n->data.mapping.pairs.top - n->data.mapping.pairs.start);
    return v;
}
sy_node sy_root(sy_document *doc) {
    yaml_node_t *n = yaml_document_get_root_node(&doc->document);
    return node_view(doc, n ? (int)(n - doc->document.nodes.start) + 1 : 0);
}
void sy_pair(sy_document *doc, int id, size_t index, sy_node *key, sy_node *value) {
    yaml_node_t *n = yaml_document_get_node(&doc->document, id);
    yaml_node_pair_t pair = n->data.mapping.pairs.start[index];
    *key = node_view(doc, pair.key);
    *value = node_view(doc, pair.value);
}
