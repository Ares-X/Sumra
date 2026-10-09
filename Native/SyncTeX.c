// SyncTeX queries follow SumatraPDF 012d997f src/PdfSync.cpp (GPLv3).
// The parser itself is the original MIT-licensed ext/synctex implementation.
#include "Engine.h"
#include <synctex_parser.h>

// Each query has its own scanner and diagnostic buffer, including concurrent
// inverse requests from different reader windows.
_Thread_local char *lf_synctex_error_buffer;

static synctex_scanner_p sync_open(const char *pdf, char *error) {
    error[0] = 0;
    lf_synctex_error_buffer = error;
    return synctex_scanner_new_with_output_file(pdf, NULL, 1);
}

static void sync_close(synctex_scanner_p scanner, char *error, int ok, const char *fallback) {
    synctex_scanner_free(scanner);
    lf_synctex_error_buffer = NULL;
    if (!ok && !error[0]) snprintf(error, 512, "%s", fallback);
}

// The returned filename is copied before releasing the scanner; the caller frees it.
API char *lf_synctex_inverse(const char *pdf, int page, double x, double y, int *location, char *error) {
    synctex_scanner_p scanner = sync_open(pdf, error);
    char *result = NULL;
    if (scanner && isfinite((float)x) && isfinite((float)y)
        && synctex_edit_query(scanner, page, (float)x, (float)y) > 0) {
        synctex_node_p node = synctex_scanner_next_result(scanner);
        if (node) {
            const char *name = synctex_scanner_get_name(scanner, synctex_node_tag(node));
            int line = synctex_node_line(node), column = synctex_node_column(node);
            if (name && *name && line > 0) {
                result = strdup(name);
                if (!result) snprintf(error, 512, "Cannot allocate SyncTeX source path");
                location[0] = line; location[1] = column < 0 ? 0 : column;
            }
        }
    }
    sync_close(scanner, error, result != NULL, scanner ? "No SyncTeX source near this PDF location" : "No readable .synctex or .synctex.gz index beside the PDF");
    return result;
}
