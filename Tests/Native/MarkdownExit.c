// Exercise the engine's real exit callbacks in a child process, without timers.
// A FIFO holds a live parser between input chunks while exit begins. The earlier
// finalizer then finishes its input and checks that the borrowed extensions lived
// until both the parser and its AST were freed.
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static pthread_t worker;
static int writer;
static const char *source;
static char *(*render)(const char *, char **, char *);
static char *(*outline)(const char *, char *);

static void *convert(void *unused) {
    char error[512] = {0}, *headings = NULL;
    char *result = render ? render(source, &headings, error) : outline(source, error);
    int ok = result && strstr(result, "Heading");
    if (!ok) fprintf(stderr, "conversion failed: %s\n", error);
    free(result); free(headings);
    return (void *)(long)!ok;
}

static void finish_input(void) {
    close(writer);
    void *failure;
    if (pthread_join(worker, &failure) || failure) _Exit(1);
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    alarm(10); // A broken handshake fails the test instead of hanging XCTest.
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    if (!strcmp(argv[2], "render")) render = dlsym(library, "lf_markdown_render");
    else outline = dlsym(library, "lf_markdown_outline");
    if (!render && !outline) return 2;
    source = argv[3];
    if (mkfifo(source, 0600) || atexit(finish_input)) return 2;
    if (pthread_create(&worker, NULL, convert, NULL)) _Exit(2);
    writer = open(source, O_WRONLY);
    if (writer < 0) _Exit(2);
    // More than the pipe capacity: completion proves the parser has registered
    // and borrowed its extensions and has started reading, before process exit.
    char chunk[64 * 1024];
    memset(chunk, 'x', sizeof(chunk));
    memcpy(chunk, "# Heading\n\n~~deleted~~\n\n", 23); chunk[sizeof(chunk)-1] = '\n';
    for (int i = 0; i < 4; ++i) {
        size_t offset = 0;
        while (offset < sizeof(chunk)) {
            ssize_t count = write(writer, chunk + offset, sizeof(chunk) - offset);
            if (count <= 0) _Exit(2);
            offset += count;
        }
    }
    return 0;
}
