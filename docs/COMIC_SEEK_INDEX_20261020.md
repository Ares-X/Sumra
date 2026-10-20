# Solid comic section seeking (2026-10-20)

## Scope

0.2.6 adds in-memory section indexing to the existing Archive owner. Original
books remain read-only. It creates no extracted book, persistent image cache or
on-disk index. Existing completed-entry memory caching and the rendering
pipeline from 0.2.5 remain in use.

The original 2,100-page B01 comic has one 7z folder, but its LZMA2 stream has
dictionary resets at unpacked offsets 0, 128 MiB and 256 MiB. A 7z folder is not
necessarily one indivisible LZMA2 decoding region. Earlier documentation that
described every first access as requiring traversal from the book's beginning
was too broad.

## Reading ownership

System libarchive still owns archive detection, filenames, passwords, file
metadata and decompression. `SevenZipIndex` reads the additional 7z stream map:
packed ranges, coder properties, substream offsets and CRC32 values. It handles
plain and LZMA1/LZMA2-encoded headers. Suitable single-coder LZMA2 folders use
section seeking; other coder/filter combinations retain ordinary archive reads.

Reset offsets are discovered lazily by scanning chunk headers up to a requested
entry. This skips compressed payload bytes rather than decoding them. The first
page does not wait for an index of the entire book. A seek starts at the nearest
independent reset before the file's beginning, or continues an already closer
decoder. Files crossing a reset remain complete because decoding can continue
through subsequent sections in the same folder.

The existing libarchive decoder reads the selected range through a small virtual
XZ envelope supplied by callbacks. Encoded LZMA1 headers use a virtual `.lzma`
header. These envelopes are in-memory metadata, not recompressed books. Explicit
filter selection is necessary: libarchive's LZMA autodetection can reject a
valid 192 KiB dictionary and otherwise expose compressed bytes as raw input.

The descriptor belongs to the opened book and callbacks use `pread`, preserving
its position. Renaming the pathname does not detach the stream from its index.
Requested entries and complete entries traversed within that section retain
their original encoded image bytes in the existing session cache. The page's
CRC32 is checked before returning either full data or a prefix. A canceled
request preserves completed entries and decoder progress; read errors reset the
decoder and invalidate completed data through the existing Archive error path.

Sources for the format behavior are the official
[LZMA2 decoder](https://github.com/ip7z/7zip/blob/main/C/Lzma2Dec.c),
[XZ format specification](https://tukaani.org/xz/xz-file-format.txt) and
[libarchive 7z owner](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_7zip.c).
No package, native decoding library or dependency strategy was added.

## Evidence boundaries

The initial read-only raw-stream probe matched the decoded bytes at pages 382,
1,050 and 2,100. Section starts reduced extraction at page 1,050 from 6.27 to
2.11 seconds and page 2,100 from 12.36 to 3.94 seconds on this Mac with warm
filesystem caches. These are independent raw-stream observations, not GUI or
release acceptance. Page 382 is in the first region and stayed near 2.2 seconds.

Regression fixtures cover independent reads beyond a corrupt earlier compressed
region, per-entry CRC failures including prefix reads, entries spanning resets,
multiple folders, directory/empty-file maps, duplicate names, renamed paths,
empty archives and encoded headers with a non-power-of-two LZMA1 dictionary.
The fixtures have no runtime compressor dependency.

Integrated source, Books corpus, optimized GUI and exact signed-candidate
observations are recorded separately in the
[corpus acceptance report](BOOK_CORPUS_ACCEPTANCE.md). Private inputs, queries,
measurements and logs remain under ignored `build/solid-seek-20261020/`.

A section can still contain up to 128 MiB of preceding decoded data in B01.
Indexing removes traversal of earlier independent sections; it does not make
every cold jump instantaneous or reduce the cost within its selected section.
