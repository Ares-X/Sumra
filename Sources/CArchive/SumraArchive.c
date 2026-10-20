#include "SumraArchive.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if !__has_include(<archive.h>)
typedef ssize_t archive_read_callback(struct archive *, void *, const void **);
typedef int archive_open_callback(struct archive *, void *);
typedef int archive_close_callback(struct archive *, void *);
int archive_read_append_filter(struct archive *, int);
#define ARCHIVE_FILTER_LZMA 5
#define ARCHIVE_FILTER_XZ 6
int archive_read_support_format_raw(struct archive *);
int archive_read_open(struct archive *, void *, archive_open_callback *,
    archive_read_callback *, archive_close_callback *);
int archive_read_close(struct archive *);
int archive_errno(struct archive *);
void archive_set_error(struct archive *, int, const char *, ...);
#define ARCHIVE_FATAL (-30)
#endif

static uint32_t crc_table[256];
static pthread_once_t crc_once = PTHREAD_ONCE_INIT;

static void initialize_crc_table(void)
{
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t value = i;
        for (unsigned bit = 0; bit < 8; ++bit)
            value = (value >> 1) ^ ((value & 1) ? 0xedb88320U : 0);
        crc_table[i] = value;
    }
}

uint32_t sumra_archive_crc32(const void *bytes, size_t size)
{
    pthread_once(&crc_once, initialize_crc_table);
    const uint8_t *p = bytes;
    uint32_t crc = UINT32_MAX;
    for (size_t i = 0; i < size; ++i)
        crc = crc_table[(crc ^ p[i]) & 255] ^ (crc >> 8);
    return ~crc;
}

static void store_u32(uint8_t *p, uint32_t value)
{
    for (unsigned i = 0; i < 4; ++i) p[i] = value >> (8 * i);
}

static size_t store_vli(uint8_t *p, uint64_t value)
{
    size_t size = 0;
    do {
        p[size++] = (value & 127) | (value >= 128 ? 128 : 0);
        value >>= 7;
    } while (value);
    return size;
}

struct stream_source {
    int fd;
    int64_t offset;
    int64_t remaining;
    uint8_t prefix[24];
    size_t prefix_size;
    uint8_t suffix[64];
    size_t suffix_size;
    unsigned phase;
    // During open, libarchive may invoke close before returning an error.
    int *closed_during_open;
    uint8_t buffer[64 * 1024];
};

static ssize_t read_stream(struct archive *archive, void *opaque, const void **out)
{
    struct stream_source *source = opaque;
    if (source->phase == 0) {
        source->phase = 1;
        *out = source->prefix;
        return source->prefix_size;
    }
    if (source->remaining) {
        size_t count = source->remaining < (int64_t)sizeof(source->buffer)
            ? (size_t)source->remaining : sizeof(source->buffer);
        ssize_t actual = pread(source->fd, source->buffer, count, source->offset);
        if (actual <= 0) {
            if (actual < 0)
                archive_set_error(archive, errno, "Cannot read 7z compressed stream: %s", strerror(errno));
            else
                archive_set_error(archive, EIO, "Truncated 7z compressed stream");
            return -1;
        }
        source->offset += actual;
        source->remaining -= actual;
        *out = source->buffer;
        return actual;
    }
    if (source->phase == 1) {
        source->phase = 2;
        *out = source->suffix;
        return source->suffix_size;
    }
    return 0;
}

static int close_stream(struct archive *archive, void *opaque)
{
    (void)archive;
    struct stream_source *source = opaque;
    if (source->closed_during_open) *source->closed_during_open = 1;
    free(source);
    return ARCHIVE_OK;
}

int sumra_archive_open_7z_stream(struct archive *archive, int fd, int64_t offset,
    int64_t packed_size, int64_t unpacked_size, uint64_t codec,
    const uint8_t *properties, size_t properties_size)
{
    if (offset < 0 || packed_size < 0 || unpacked_size < 0 ||
        offset > INT64_MAX - packed_size || !properties ||
        (codec == 0x21 ? properties_size != 1 || properties[0] > 40 :
         codec == 0x030101 ? properties_size != 5 : 1)) {
        archive_set_error(archive, EINVAL, "Unsupported 7z compressed stream properties");
        return ARCHIVE_FATAL;
    }
    // The 7z coder already identifies the filter. LZMA signature bidding rejects
    // valid 7z dictionary sizes such as 192KiB and would expose compressed bytes
    // as raw output, so select the known decoder explicitly.
    int status = archive_read_append_filter(archive,
        codec == 0x21 ? ARCHIVE_FILTER_XZ : ARCHIVE_FILTER_LZMA);
    if (status != ARCHIVE_OK) return status;
    status = archive_read_support_format_raw(archive);
    if (status != ARCHIVE_OK) return status;
    struct stream_source *source = calloc(1, sizeof(*source));
    if (!source) {
        archive_set_error(archive, ENOMEM, "Cannot allocate 7z stream reader");
        return ARCHIVE_FATAL;
    }
    source->fd = fd;
    source->offset = offset;
    source->remaining = packed_size;
    if (codec == 0x21) {
        // XZ Stream Header, Check=None, and a single LZMA2 Block Header.
        static const uint8_t stream_header[] = {
            0xfd, '7', 'z', 'X', 'Z', 0, 0, 0, 0xff, 0x12, 0xd9, 0x41
        };
        memcpy(source->prefix, stream_header, sizeof(stream_header));
        uint8_t *block = source->prefix + sizeof(stream_header);
        block[0] = 2;
        block[2] = 0x21;
        block[3] = 1;
        block[4] = properties[0];
        store_u32(block + 8, sumra_archive_crc32(block, 8));
        source->prefix_size = 24;
        uint64_t payload_size = (uint64_t)packed_size + 1;
        // End marker plus Block Padding, followed by the single-record Index.
        size_t size = 1 + ((4 - (payload_size & 3)) & 3);
        size_t index_start = size;
        source->suffix[size++] = 0;
        source->suffix[size++] = 1;
        size += store_vli(source->suffix + size, 12 + payload_size);
        size += store_vli(source->suffix + size, (uint64_t)unpacked_size);
        while ((size - index_start) & 3) source->suffix[size++] = 0;
        store_u32(source->suffix + size,
            sumra_archive_crc32(source->suffix + index_start, size - index_start));
        size += 4;
        size_t footer_start = size;
        store_u32(source->suffix + size + 4, (uint32_t)((size - index_start) / 4 - 1));
        store_u32(source->suffix + size,
            sumra_archive_crc32(source->suffix + size + 4, 6));
        source->suffix[footer_start + 10] = 'Y';
        source->suffix[footer_start + 11] = 'Z';
        source->suffix_size = footer_start + 12;
    } else {
        // The .lzma header carries the 7z coder properties and known output size.
        memcpy(source->prefix, properties, 5);
        for (unsigned i = 0; i < 8; ++i)
            source->prefix[5 + i] = (uint64_t)unpacked_size >> (8 * i);
        source->prefix_size = 13;
    }
    int closed = 0;
    source->closed_during_open = &closed;
    status = archive_read_open(archive, source, NULL, read_stream, close_stream);
    if (status != ARCHIVE_OK) {
        // Closing covers errors after a source filter was installed. A failure
        // before that point leaves ownership here. Preserve the decoder error.
        int error_number = archive_errno(archive);
        const char *message = archive_error_string(archive);
        char *error_message = message ? strdup(message) : NULL;
        archive_read_close(archive);
        if (!closed) free(source);
        archive_set_error(archive, error_number, "%s",
            error_message ? error_message : "Cannot open 7z compressed stream");
        free(error_message);
    } else {
        source->closed_during_open = NULL;
    }
    return status;
}
