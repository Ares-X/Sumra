# Solid comic scrolling (2026-10-19)

This records the 0.2.5 implementation and measurements. The subsequent
[0.2.6 section index](COMIC_SEEK_INDEX_20261020.md) uses independent LZMA2
reset points within a 7z folder, so a distant first access need not traverse
every preceding section. The first-region and within-section costs below remain.

## Unread scrolling is the acceptance case

The reported stall occurs when entering unread pages. Returning to visited pages
is a separate regression case and does not establish that the report is fixed.

In a fresh GUI process, eight-screen advances from page 1 through page 34 were
followed by a 200-screen advance and two more eight-screen advances, ending at
page 336. The old public app took 3.143 seconds from its final visible request
to the first canvas draw. The integrated new rendering pipeline took 0.466
seconds. Both used an 885 × 702 point viewport on this Mac. These are bounded
local observations, not a SumatraPDF runtime benchmark or a universal guarantee.
The intermediate archive-only repair took 0.630 seconds at a slightly shorter
885 × 674 viewport; it is retained as a separate observation.

Subsequent one-screen advances into previously unread pages drew in 40–65 ms in
the new app. Eight-screen advances took 113–130 ms; those jump beyond the next
viewport and still need extraction and decoding. Recorded debug events use
`render-request` and `canvas-first-draw`, not thumbnail or page-number readiness.

## Observed causes and changes

Archive extraction and ordinary comic image decoding previously occupied the
same serial actor. ImageIO now decodes immutable entry bytes on a worker with its
own image source while the actor can extract the next entry. Identical visible
and predictive requests share pixels and independent cancellation subscriptions.
The directional prediction chain starts after visible hosts enqueue their work,
covers the next viewport (including short pages and spreads), and does not wait
for the first paint. The existing 64 MiB bitmap budget replaces the additional
three-preview count restriction. Offscreen views remain unmounted.

A local 2100-page comic named `.cbz` is actually a 365 MiB 7z archive with
one solid LZMA2 block. JPEG decoding is about 25–36 ms. An uncached backward
request near page 382 instead spent about 2.2 seconds replaying solid decompression.

`Archive.data` previously discarded entries passed while reaching a requested
page. It now retains their original file bytes in its existing entry cache.
Returning to those pages does not reopen the archive or move the forward cursor.
Duplicate names still resolve to the first indexed entry. ZIP keeps partial reads
and skips unrelated entries.

Cancellation is observed between complete 7z entries. The current entry finishes
and enters the cache before cancellation returns, keeping the solid stream usable.
Other formats reset a partially consumed cursor on cancellation. Both preserve
completed cache entries; actual read failures still invalidate the reader/cache.

This retains encoded files, not full-resolution page bitmaps. Memory grows with
the uncompressed entries traversed, including non-image entries. First access to
an unseen distant page still pays sequential decompression. Cancellation can wait
for one complete entry, which matters for unusually large individual files.

## Upstream comparison

Inspected SumatraPDF tree `ea7d6b7da899752dcf85bb26297f1a13f0393b1a`:

- [Archive.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/base/Archive.cpp):
  full requested entries stay in `FileInfo`; uncached reads reopen libarchive and
  skip preceding entries. A cached full entry also serves header requests.
- [EngineImages.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/EngineImages.cpp):
  CBX opens lazily, reads headers for page bounds and reuses encoded image data.
- [RenderCache.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/RenderCache.cpp):
  predictive rendering chains neighboring requests while their origin stays visible.
- [DisplayModel.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/DisplayModel.cpp):
  visible pages and their predictive neighbors enter the rendering chain together.
  `EngineImages` also performs image loading and decoding outside its cache lock.

The change uses the existing system libarchive owner. Retaining traversed solid
entries is a specific repair to Sumra's cursor, not a literal upstream port.

## Measured archive and decoder behavior

Same source-built optimized harness, same file, request order 382, 383, 381, 384:

| Operation | Before | After |
| --- | ---: | ---: |
| First page 382 data/header | 2220 ms | 2282 ms |
| Forward page 383 data/header | 7.9 ms | 8.3 ms |
| Backward page 381 data/header | 2190 ms | 0.002 ms |
| Next page 384 data/header | 18.7 ms | 5.1 ms |
| Page 381 ImageIO thumbnail decode | 33 ms | 26 ms |

These are local stage measurements, not a SumatraPDF A/B or screen-paint latency.
Evidence is under ignored `build/cbz-scroll-20261019/`.

Regression coverage includes traversed-entry reverse reading after the archive
pathname moves, continued forward reading through the same descriptor, first-name
resolution for duplicate solid entries, existing ZIP/ZIP64/password behavior and
pre-cancelled reads. Mid-entry cancellation has no deterministic test barrier in
the synchronous file interface; the pre-cancelled test is a separate boundary.

## Validation and evidence layers

- The new optimized Swift archive, request-sharing and prediction tests pass.
  Tests include three visible pages warming the next viewport, shared bitmap
  identity, independent cancellation and solid-entry cursor preservation.
- The full native library was rebuilt from the existing pinned corresponding
  sources. PDF content-bounds, snapshot replay and display checks cover the
  additional owner repairs described in the [source audit](SUMATRA_PARITY_AUDIT_20261019.md).
- The actual GUI measurements above use a separate app and preference domain.
  The original reader process was preserved during that comparison. Stage measurements and automated
  hosted views are recorded separately from actual canvas drawing.
- Original Books inputs are read-only. Private inventory, stage measurements,
  GUI debug events and corpus reports live under ignored
  `build/corpus-20261019/`; earlier archive measurements are under
  `build/cbz-scroll-20261019/`. Private names and contents are not release assets.

Final full-corpus and exact-candidate release acceptance are recorded in
[the book-corpus report](BOOK_CORPUS_ACCEPTANCE.md).

## Exact signed candidate (2026-10-20)

The CI candidate from `e81c567151edcbaab612c605f02a6dd131ed9542` loaded
executable UUID `96EDC528-635F-31DA-A118-91CCF536565F`. Its fresh-process
GUI sweep used a larger 1269 × 904 point viewport: eight-screen advances reached
pages 11, 21 and 31, followed by a 200-screen jump and two eight-screen advances
to page 303. The final request painted in 193 ms. The intervening advance to
page 293 took 897 ms while solid decompression caught up. Subsequent one-screen
advances painted new neighboring pages in 46–83 ms. The larger geometry makes
this a separate candidate observation, not the matched-window comparison above.

All three original comics passed actual candidate page movement, continuous
scrolling and Contents controls. Raw event receipts are in ignored
`ci-unread-paints.json` and `gui.ndjson`.

The public 0.2.4 → 0.2.5 Sparkle upgrade subsequently loaded the same accepted
candidate into canonical `dist/Sumra.app`. A cold jump to page 382 painted in
2.283 seconds, followed by new neighboring page 384 in 65 ms. The cold seek
remains a solid-format traversal cost; the final app was left at page 382.
