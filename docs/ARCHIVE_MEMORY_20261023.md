# Archive memory and cancellation follow-up (2026-10-23)

`Archive` now retains up to 64 MiB of completed extracted entry bytes, with
least-recently-used eviction. This is independent of the existing 64 MiB rendered
bitmap cache. Byte accounting uses the actual `Data.count`, rather than a page
count: the local comic inputs range from 397 KiB to 6.7 MiB maximum entry sizes.
The budget reuses the existing reader memory scale while retaining hundreds of
the measured solid comic's recent pages. A requested entry larger than the budget
still returns all its bytes, but does not remain cached or displace the working
set. This bounds cache retention, not the memory required by a current request,
libarchive's decoder, native document objects, or other open documents.

Existing LZMA2 reset indexing and forward cursors remain in use. Recent reverse
reads reuse extracted bytes; returning to an evicted page decodes it again from
the nearest available reset. No original book, persistent cache, compressor,
dependency, or GUI routing changes are involved.

Cancellation is checked between 64 KiB decoder reads, including while consuming
an indexed entry. Completed cached entries remain usable. An indexed decoder can
continue from its partial position for a later target, or restart at the selected
reset when revisiting that partial entry. The ordinary libarchive cursor closes
on an interrupted read and reopens when needed; completed entries survive.

## Local evidence

An optimized isolated core probe read unchanged B01 (2,100 pages, 393,454,197
extracted bytes), then requested one-based pages 382, 1,050 and 2,100 in one owner.
These are single warm-filesystem measurements, not latency distributions or GUI
acceptance. Private receipts are under ignored `build/archive-memory-evidence/`.

| Destination | Prior cached bytes | Bounded cached bytes | Prior read | Bounded read |
| --- | ---: | ---: | ---: | ---: |
| 382 | 69,851,567 | 67,096,244 | 2.316 s | 2.319 s |
| 1,050 | 135,695,530 | 66,959,695 | 2.255 s | 2.288 s |
| 2,100 | 260,542,895 | 67,100,296 | 4.227 s | 4.150 s |

The final retained bytes are 74.2% lower in this workload. Nearby reverse reads
remain below 0.02 ms in the probe. Returning to evicted page 1,050 costs 2.051 s;
its former permanently retained cache hit was below 0.01 ms. This is an explicit
memory/remote-revisit tradeoff, not a claim of universally faster navigation.

The generated 32 MiB synthetic solid-entry cancellation/recovery fixture also ran
against both versions. Cancel-to-return observations were 12.73 ms before and
4.31 ms after; scheduling, allocation and decoder work remain part of these
single observations. The regression verifies cancellation, preserved completed
entries and subsequent forward/backward recovery after renaming the pathname.

The focused optimized core run passed 57 tests covering archive byte eviction,
LRU promotion, oversized requests, cancellation/recovery, independent seeking,
CRC failures, passwords, duplicate names, aliases, ZIP prefixes and existing
LegacyBook behavior. No app was loaded or GUI workflow accepted by this probe.

The local B13 MOBI compatibility path produced 373,065 HTML bytes in approximately
65 ms and returned that HTML for native rendering, so it did not reproduce the
ordinary-MOBI second decode. Its route, DRM checks and format handling remain
unchanged in this measurement. The ordinary-book repeated-decode boundary was
subsequently removed in the [2026-10-24 follow-up](READER_FOLLOWUP_20261024.md);
this older B13 measurement did not establish that change or its performance.

Both isolated probe/build packages and the temporary source test were retired
after preserving logs and probe sources. Their test/build processes had exited;
no shared or original-checkout process was stopped.
