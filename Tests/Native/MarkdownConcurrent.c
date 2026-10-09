// Concurrent native Markdown regression. Invoke with MuPDF.dylib and a test-owned
// fixture containing Heading, ~~deleted~~, https://example.com, a task-list item
// and a GFM table. Both render and outline use real engine APIs; no parser hooks.
// A shared start gate exercises first registration and concurrent inline finish.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#define THREADS 8
#define ROUNDS 128

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int arrived, go;
static const char *library_path, *source;

typedef struct { int id, failures, renders, outlines; } job;

static void *convert(void *opaque) {
    job *j = opaque;
    pthread_mutex_lock(&mutex);
    arrived++;
    pthread_cond_broadcast(&condition);
    while (!go) pthread_cond_wait(&condition, &mutex);
    pthread_mutex_unlock(&mutex);

    for (int round = 0; round < ROUNDS; round++) {
        void *library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
        if (!library) {
            if (j->failures++ == 0) fprintf(stderr, "dlopen: %s\n", dlerror());
            continue;
        }
        char *(*render)(const char *, char **, char *) = dlsym(library, "lf_markdown_render");
        char *(*outline)(const char *, char *) = dlsym(library, "lf_markdown_outline");
        if (!render || !outline) {
            if (j->failures++ == 0) fprintf(stderr, "Missing native Markdown API\n");
            dlclose(library);
            continue;
        }
        char error[512] = {0}, *headings = NULL;
        int body = (round + j->id) % 2 == 0;
        char *result = body ? render(source, &headings, error) : outline(source, error);
        int ok = result && strstr(result, "Heading");
        if (body) {
            j->renders++;
            ok = ok && headings && strstr(headings, "Heading") &&
                strstr(result, "<del>deleted</del>") && strstr(result, "<table>") &&
                strstr(result, "type=\"checkbox\"") && strstr(result, "href=\"https://example.com\"");
        } else j->outlines++;
        // Keep the first exact cause/output per thread; logs remain bounded even
        // if a broken build fails every conversion or the fixture is invalid.
        if (!ok && j->failures++ == 0)
            fprintf(stderr, "conversion %d/%d/%s failed: %s\nHTML=%.4096s\nOUTLINE=%.4096s\n",
                j->id, round, body ? "render" : "outline", error,
                result ? result : "NULL", headings ? headings : "NULL");
        free(result);
        free(headings);
        dlclose(library);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: markdown-concurrent MuPDF.dylib fixture.md\n");
        return 2;
    }
    alarm(20);
    library_path = argv[1];
    source = argv[2];
    pthread_t threads[THREADS];
    job jobs[THREADS] = {0};
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    if (pthread_attr_setstacksize(&attr, 256 * 1024)) return 2;
    for (int i = 0; i < THREADS; i++) {
        jobs[i].id = i;
        if (pthread_create(&threads[i], &attr, convert, &jobs[i])) return 2;
    }
    pthread_attr_destroy(&attr);
    pthread_mutex_lock(&mutex);
    while (arrived < THREADS) pthread_cond_wait(&condition, &mutex);
    go = 1;
    pthread_cond_broadcast(&condition);
    pthread_mutex_unlock(&mutex);

    int failures = 0, renders = 0, outlines = 0;
    for (int i = 0; i < THREADS; i++) {
        pthread_join(threads[i], NULL);
        failures += jobs[i].failures;
        renders += jobs[i].renders;
        outlines += jobs[i].outlines;
    }
    int resident = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "MuPDF.dylib")) resident++;
    }
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    printf("{\"threads\":%d,\"rounds\":%d,\"renders\":%d,\"outlines\":%d,\"failures\":%d,"
        "\"residentAfterAllDlclose\":%d,\"peakResidentBytes\":%ld}\n",
        THREADS, ROUNDS, renders, outlines, failures, resident, usage.ru_maxrss);
    return failures ? 1 : 0;
}
