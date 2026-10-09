#include "Engine.h"
#include <chm_lib.h>

typedef struct { struct chmFile *file; struct chmUnitInfo *items; int count; } Document;
static int collect(struct chmFile *f, struct chmUnitInfo *item, void *context) {
    Document *d = context; (void)f;
    size_t n = strlen(item->path);
    if (!n || item->path[n-1] == '/') return CHM_ENUMERATOR_CONTINUE;
    if (!(item->flags & CHM_ENUMERATE_NORMAL) && strcasecmp(item->path, "/#SYSTEM") &&
        strcasecmp(item->path, "/#WINDOWS") && strcasecmp(item->path, "/#STRINGS")) return CHM_ENUMERATOR_CONTINUE;
    if (d->count > INT_MAX - 64) return CHM_ENUMERATOR_FAILURE;
    if (d->count % 64 == 0) {
        void *p = realloc(d->items, (d->count + 64) * sizeof(*d->items));
        if (!p) return CHM_ENUMERATOR_FAILURE;
        d->items = p;
    }
    d->items[d->count++] = *item;
    return CHM_ENUMERATOR_CONTINUE;
}
API void lf_close(Document *d) { if (d) { if (d->file) chm_close(d->file); free(d->items); free(d); } }
API Document *lf_open(const char *path, char *error) {
    Document *d = calloc(1, sizeof(*d)); if (!d) return NULL;
    d->file = chm_open(path);
    if (!d->file || !chm_enumerate(d->file, CHM_ENUMERATE_NORMAL | CHM_ENUMERATE_META | CHM_ENUMERATE_SPECIAL | CHM_ENUMERATE_FILES, collect, d)) {
        snprintf(error, 512, "Cannot read CHM directory"); lf_close(d); return NULL;
    }
    return d;
}
API int lf_count(Document *d) { return d->count; }
API const char *lf_path(Document *d, int i) { return i >= 0 && i < d->count ? d->items[i].path : NULL; }
API unsigned char *lf_read(Document *d, int i, size_t *size) {
    if (i < 0 || i >= d->count) return NULL;
    struct chmUnitInfo *item = &d->items[i];
    if ((uint64_t)item->length > INT64_MAX) return NULL;
    *size=(size_t)item->length;
    unsigned char *out=malloc(*size ? *size:1);
    if(!out)return NULL;
    if (chm_retrieve_object(d->file, item, out, 0, *size) != (LONGINT64)*size) { free(out); return NULL; }
    return out;
}
