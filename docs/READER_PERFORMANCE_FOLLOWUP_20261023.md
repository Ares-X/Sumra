# PDF capture and search cancellation follow-up (2026-10-23)

This source follow-up removes the redundant pre-capture PDF hash and connects
search task cancellation to the existing MuPDF drawing cookie. It adds no
runtime dependency, extracted-book cache, search index, decoder owner or arbitrary
work limit. [Archive memory](ARCHIVE_MEMORY_20261023.md) has its separate byte
budget and observations. Earlier [performance parity observations](PERFORMANCE_PARITY_20261020.md)
remain historical workloads, not universal latency guarantees.

## PDF capture ownership

`NativeFile.PDFSource` captures the source before computing its checkpoint.
It opens one descriptor, records its complete device/inode/size/mtime/ctime
version and verifies the pathname names that same version. An APFS clone owns
immutable bytes when cloning returns; a streaming copy must retain that complete
source version through its last write. Descriptor and pathname versions are
checked at that capture boundary. Source changes after capture cannot change the
private input or cause the later snapshot hash to read different source bytes.

The original-save checkpoint now combines the captured source version with the
captured bytes' digest. The private-input checkpoint combines the private file's
version with that same digest. APFS hashes the private input once; non-cloning
volumes hash during the existing streaming copy. Source-save validation still
checks the original checkpoint, including digest comparison when only ctime
changed. An unchanged complete version returns without another hash. A later
replacement, in-place write, truncation or equal-length write restoring mtime
cannot become an owned original Save. Save a Copy and print continue to consume
the immutable private input, independently of the original pathname.

A read-only warm-filesystem probe on actual B08 (44,364,471 bytes, 174 pages)
observed:

| Stage | Time |
| --- | ---: |
| Original hash removed from opening | 21.01 ms |
| APFS clone | 0.19 ms |
| Private-input hash retained | 21.44 ms |
| Streaming copy and simultaneous hash | 25.79 ms |
| Native opening of captured PDF | 11.30 ms |
| Native page count | 0.05 ms |
| First page bounds | 1.09 ms |

These measure the owning filesystem/native operations, not a timed Swift app
launch or first painted frame. The original stat was unchanged. Source tests
cover snapshot lifetime, private permissions, locked-file capture, metadata,
current captured bytes, and original-save rejection after replacement or restored
mtime writes. Existing PDF output tests retain unread-page, concurrent writer,
copy, print, original-save and journal boundaries.

## Search work and cancellation

`Pages.matches` now installs a task cancellation handler around its serialized
native request. The existing request-specific `NativeRenderCancellation` cookie
passes through `lf_search_pages_at`, structured-text extraction, HTML/EPUB's
`run_page` callback and `fz_draw_html` to the existing flow drawing loop. The
previous HTML callbacks discarded that cookie. A canceled extraction throws and
does not publish or cache its partial glyph page; a new request has its own
cookie. Finite-page phrase windows and the matching/normalization policy remain
in their existing owners.

Actual native continuous-mode probes used one decoder at a time and unchanged
private books. They used a 600-point width and 14-point text; filesystem caches
were warm. These are individual observations, not percentile measurements.

| Input / workload | First hit | Count / limit | Longest synchronous call |
| --- | ---: | ---: | ---: |
| B10, 1,471 chapters, natural CJK phrase | 28.60 ms | 54 hits / 29.70 s | 570.00 ms |
| B22, 1,052 chapters, frequent character name | 40.73 ms | 1,000th hit / 184.92 ms | 17.99 ms |

The B22 observation reaches the existing 999+ display threshold; it is not a
complete count of every occurrence. B10 demonstrates a full-count long tail.
A parsed ordered-CJK candidate experiment retained the same 54 hits and rejected
more chapters but took 33.10 s. That experiment was reverted; its failed receipt
is retained instead of presenting it as an optimization.

The largest B10 source chapter has 2,330,929 XHTML bytes. A request searching that
chapter was canceled after a 10 ms timer:

| Operation | Earlier path | Connected drawing cookie |
| --- | ---: | ---: |
| Cancel to native return | 350.63 ms | 1.55 ms |
| Returned stale result pointer | No | No |
| Subsequent query, one verified hit | 88.62 ms | 393.31 ms |
| Subsequent first-chapter bounds | 9.48 ms | 9.58 ms |
| Closing native document | 16.00 ms | 9.95 ms |

The subsequent query must redo cold extraction after cancellation; the earlier
path had finished and cached the obsolete request's whole glyph page. These
native calls establish prompt interruption and decoder reuse. They do not prove
live app query-replacement, close or page-turn UI latency. During an uncanceled
count, a large continuous chapter can still occupy the actor for about 570 ms;
existing batching yields between page requests. The change does not eliminate
that full-count work or promise immediate ordinary paging during it.

## Focused validation and evidence

The changed native library passed `CrossPageSearch.c` (multi-page spans, CJK,
ligatures, marks, soft/line hyphens and allowed-page boundaries) and
`EPUBSearchNaturalPhrase.c` (26 fixtures × 8 options/directions plus chunk
boundaries). Swift regressions additionally cover request-cookie cancellation
and subsequent query recovery. Full coordinated app validation is recorded by
the enclosing integration task; these probes themselves do not load the app.

Private receipts and probe sources are under ignored
`build/performance-followup/`. They retain the failed candidate attempt as well
as the final cancellation result. Temporary comparison dylibs, standalone test
executables and unused object outputs were removed after retaining the receipts.
All owned probe/build/test processes exited; active integration engines and
other tasks' processes remain owned by their existing callers.
