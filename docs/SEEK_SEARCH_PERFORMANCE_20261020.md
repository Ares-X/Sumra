# Solid-archive seeks and large EPUB counting — 2026-10-20

This round targets the remaining first seek and complete-count costs from
[0.2.7](PERFORMANCE_PARITY_20261020.md). It compares official SumatraPDF tree
[`a1120ae6de3b84be0c422dc0da7258e6828c2be6`](https://github.com/sumatrapdfreader/sumatrapdf/tree/a1120ae6de3b84be0c422dc0da7258e6828c2be6),
freshly verified as upstream master. Private book names, queries and content
remain in ignored local receipts. The originals must retain their hashes,
sizes and modification times; no whole-book persistent payload cache is used.

## Solid archive: measured work and direct repair

B01 has three independent LZMA2 dictionary resets and 393,454,197 unpacked
bytes. Its 7,786 chunks include 6,345 compressed continuation chunks, 1,438
uncompressed copy chunks and three dictionary-reset chunks. Only 70,379,030
bytes are copy payload. Both measured distant targets intersect compressed
continuations, so directly reading uncompressed spans cannot satisfy them.

The existing index already selects the nearest independent reset; an `0x80`
continuation requires the dictionary and probability state produced by the
preceding stream. System libarchive and Apple Compression were compared in an
isolated experiment; changing to Apple Compression did not offer a reliable
tail improvement and was not adopted. No decoder state is copied through an
opaque API, and no replacement codec or new dependency was added.

The existing archive owner now uses ARM64 CRC instructions, preserving the
portable table implementation on other targets. Indexed entries decode straight
into their known final allocation, avoiding scratch-buffer copies and repeated
Data growth. Full-entry CRC checks and completed traversal entries are retained.
The 64 MiB CRC-only comparison falls from about 159 ms to 7 ms; this is not an
end-to-end jump measurement.

Three alternating optimized baseline/candidate pairs open a fresh index for
each target and retain the same traversed bytes as `Archive`. Filesystem caching
is warm/uncontrolled. The target hashes, sizes, retained entry counts and total
retained bytes match in every pair:

| Destination | Baseline median | Repaired median | Reduction |
| --- | ---: | ---: | ---: |
| B01 page 1,050 | 2.212 s | 2.056 s | 7.05% |
| B01 page 2,100 | 4.168 s | 3.882 s | 6.86% |

These isolate archive extraction, excluding image decoding, GUI scheduling and
canvas drawing. A separate 0.2.7 real-window baseline draws previously unread
pages 1,050 and 2,097 in 2.390 / 4.279 s at an 853 × 665 point viewport. The
large section replay remains a material latency limit; the CRC and allocation
repair does not make a first distant jump instantaneous.

The focused 29-test Core run passes, including 88 independent CRC vectors at
unaligned addresses and word/buffer boundaries, damaged CRC rejection, duplicate
names and moved open descriptors. The cancellation regression is precancelled;
it does not prove a deterministic mid-entry interruption. ARM64 runtime and
ARM64/x86_64 C syntax are exercised; x86_64 runtime is not.

Sumatra's [Archive.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/base/Archive.cpp)
reopens and walks the archive on an uncached request, then keeps requested entry
bytes. It does not provide decoder checkpoints inside these LZMA2 continuations.
Sumra's existing reset index and forward cursor avoid earlier independent
sections. Both implementations retain encoded entry bytes in session memory;
this round does not introduce disk payload caching or change that policy.

## EPUB: owner attribution

The same saved queries on fresh native documents separate candidate walking,
typography and page search. These isolated owner timings use 736 × 536 point
geometry and 17 point text; they are not the hosted 800 × 600 workflow timings.

| Book | Chapters | Exact hits | Baseline total | Main measured cost |
| --- | ---: | ---: | ---: | --- |
| B10 | 1,471 | 25 | 65.012 s | 56.026 s in per-page search |
| B22 | 1,052 | 1 | 11.655 s | 11.594 s in chapter candidate preparation |

B10 includes exceptionally long flow paragraphs spanning hundreds of pages.
Finite-page candidates now restrict the existing necessary-character check to
the renderer's inclusive page-baseline bounds. Compact groups of 64 flow nodes
reuse the renderer's min/max extent approach, so a page does not rescan the
entire paragraph. Candidate rejection avoids glyph extraction; a possible hit
still uses the unchanged exact MuPDF matcher, word boundaries, Unicode options,
source anchors and geometry. Fixed-layout EPUB keeps its existing matching path.

The group capacity is reserved before HTML enters the bounded Fitz store. Its
parsed UTF-8 byte count bounds later flow splits during wrapping/bidi layout.
Reflow fills new bounds in the same charged allocation; dropping HTML frees it.
This changes neither the result cap nor document navigation.

B22 stack attribution found repeated `load_html_image` / ZIP inflate, not Unicode
normalization, dominating its chapter preparation. Repeated raster resources now
reuse the existing bounded Fitz memory store, keyed by full resolved path and a
retained archive identity. The store uses full-key comparison and a dedicated
resource value type. SVG retains its existing decode path because its nested
resources depend on the caller's base URI. Store cost includes images and keys;
there is no extracted-book cache or disk write.

The final isolated native run uses the same saved queries, options and geometry:

| Book | Baseline total | Repaired total | Exact hit count |
| --- | ---: | ---: | --- |
| B10 | 65.012 s | 10.426 s | 25 → 25 |
| B22 | 11.655 s | 1.347 s | 1 → 1 |

B10's per-page/glyph phase drops from 56.026 s to 1.439 s. Remaining work includes
parsing/candidate preparation and typography in possible chapters. These are
single native owner runs with warm/uncontrolled filesystem caching, rather than
GUI input percentiles or complete-count latency from the hosted workflow.

Native regressions compare exact search JSON across Unicode options/directions,
finite 180/360-point and natural-height layouts, a grouped long paragraph and
repeated reflow. Image fixtures cover canonical aliases, separate archives,
concrete colliding 32-bit path hashes, distinct pixels, two layouts and archive
close/store eviction/reopen. Independent review corrections for image identity,
SVG base URI and pre-layout store accounting are included in the final source.
The natural-height suite additionally compares 26 fixtures across eight
options/directions and a real chunk-boundary match. Explicit glyph-reference
counts cover query characters in hidden, transparent, zero-font, display-none,
clipped and overprinted text, rather than accepting two empty results as proof.

The supplemental continuous-reading check exposed a separate cost: without page
bounds, B10 still extracted whole-chapter glyphs and took 21.489 s, essentially
unchanged from the 21.220 s baseline. Natural-height HTML now projects painted,
laid-out flow onto the query's characters and uses Fitz's existing matcher as a
necessary-order check before glyph extraction. This additional check applies to
pure CJK queries of at least two characters. Unsupported queries and uncertain
bidi flow retain the existing search path. Adjacent overprint duplicates and
matches spanning projection chunks remain eligible. The exact glyph search
still decides every reported hit, anchor and rectangle.

With the same natural-height B10 query, the native total falls from 21.489 s to
12.171 s with 25 hits preserved; the glyph/search phase falls from 12.308 s to
1.371 s. Parsing and typography remain substantial. B22's natural-height baseline
falls from 13.285 s to 1.419 s with the raster-resource repair; its later 1.878 s
run illustrates preparation-time variation. These are individual native runs,
not GUI latency percentiles.

The application counting loop also scans consecutive no-match pages inside the
existing `Pages` actor, yielding between pages for reading and cancellation.
It returns matches, the next cursor and the authoritative chapter-layout
snapshot together. This avoids a UI actor round trip and viewport capture for
each empty page. Match publication, the 999+ result cap and source identities
are preserved; regressions compare batched results with per-page search and
exercise cancellation, limits and layout stability.

Signed-app investigation also exposed repeated chapter publications. Natural
chapters often advance only `laidOut`, without changing page numbers. The
`ReaderState` owner now accepts that metadata without capturing/restoring the
viewport, remapping search results or issuing a scroll request. Duplicate and
stale snapshots likewise cannot capture the viewport. Actual pagination changes
still capture the live position before remapping. Counting applies layout when
returning hits and at completion; independent decoder notifications continue
to deliver real pagination changes. Anchor, stale-snapshot and queued-reflow
regressions cover this distinction.

Sumatra's [TextSearch.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/TextSearch.cpp)
ensures complete ebook layout before traversing pages; its
[EngineEbook.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/EngineEbook.cpp)
extracts search text from retained page drawing instructions. Sumra's native
MuPDF HTML owner remains authoritative for layout, text, normalization, source
anchors and match geometry; adding a second EPUB text parser is unnecessary.

## Acceptance state

The first integrated build passes **118 Core and 912 application tests**, four
opt-in items skipped, **58 packaging checks** and three reader-script syntax
checks. All **25 Books workflows** pass; the **4,942 comic pages** decode
successfully. All 22 searchable books retain their prior same-query counts and
caps. At 800 × 600 in paged mode, B10's complete count falls from the prior
72.028 s to 32.041 s, and B22 from 20.959 s to 2.938 s. These measurements precede
the natural-height and application batching follow-ups above.

The final official engine rebuild and all three native suites pass. The full
source recheck passes **118 Core and 913 application tests**, four opt-in items
skipped, **58 packaging checks** and three script syntax checks. Its preceding
run retained one hosted queued-zoom timeout. The test required two render
revisions although adjacent absolute zooms may coalesce. An unchanged isolated
run and the complete recheck pass. The test now verifies independent target
page bounds, the current painted canvas and ordered command completion, while
retaining selection, source text and offscreen Copy assertions; both affected
selection tests pass after this refinement. No production zoom behavior changed.

The final hosted sweep passes **25/25**, including Contents opening/closing and
first/middle/final source positions. All **22 searchable books** retain the same
saved-query counts and cap status as the preceding sweep, which also matches
0.2.7. With final application batching, B10 completes in **23.804 s** (25 hits),
and B22 in **2.468 s** (one hit), versus 0.2.7's 72.028 / 20.959 s. First selected
results arrive at 0.193 / 0.858 s. These are debug hosted-reader measurements in
paged mode, not signed-app input latency. The 4,942-page comic decode evidence
is reused because the subsequent changes affect HTML search and counting only.

All **14 EPUBs** also pass a paired native comparison against the public 0.2.7
library: 13 reflowable books use natural-height layout and the fixed EPUB keeps
its fixed layout. Saved queries/options are unchanged. The ordered match JSON,
including source positions and geometry, has identical hashes; counts and the
1,000-hit cap sentinel agree. B10 takes **20.380 → 10.182 s** with 25 hits, and
B22 **11.743 → 1.338 s** with one hit. These are single baseline-then-candidate
passes with warm/uncontrolled filesystem caching, not a percentile study.

## Final signed acceptance and delivery — 2026-10-21

The final accepted source is `5b557d1a61d1b6b12b9eda03dcda2191dafad16f`.
[Candidate Action 39458013232](https://github.com/Ares-X/Sumra/actions/runs/39458013232)
builds 0.2.8 (10), UUID `A5FFDF34-7033-3AB8-A385-84A6FFCBDB53`.
Its 181 files, five symlinks and 130 directories match provenance, including
file modes. All nine Mach-O binaries have ARM64 support and a macOS 13 minimum;
the application executable is ARM64-only. The existing certificate and Sparkle
Ed25519 signature verify. Corresponding source verifies 13,457 files, 17 links
and all 434 included Git project files. Root `AGENTS.md` and `appcast.xml` are
the package's two intentional Git exclusions.

After the chapter-publication repair, the full source gate again passes 118
Core and 913 application tests (four opt-in skips), 58 packaging checks and three
script syntax checks. The live-position callback regression also passes after
strengthening its captured-coordinate assertion. All 25 hosted workflows and
22 saved-query counts/caps pass again. This latest B10/B22 complete count is
**33.039 / 5.170 s**, versus the earlier 23.804 / 2.468 s and 0.2.7's
72.028 / 20.959 s. First selected results arrive at 0.233 / 1.655 s. These
individual hosted timings vary substantially; the faster preceding values
remain historical evidence, and the latest run is not proof of an isolated
speedup from the metadata-only repair.

The exact signed app passes **25/25 actual GUI workflows**: opening, sampled
navigation, Contents opening/closing, and **22/22 saved-query complete/capped
counter observations**. Six native tabs are observed in one process. Twenty-four
page/chapter indicators advance and 24 exposed scrollbars change. Single-chapter
MOBI scrolls without changing its chapter indicator; CHM has no exposed scrollbar
in this pass but advances topic navigation and completes its expected search.
CHM's transient initial `0 / 0` is retained; a subsequent observation reaches the
expected two results. Fixed EPUB's zero-result query also agrees with its exact
native comparison. This is sampled GUI coverage, not every-page/text fidelity.

The signed library independently passes all **14 EPUBs** against the public
0.2.7 baseline with identical ordered match JSON hashes, source positions,
geometry, counts and cap sentinels. At 736-point natural width with 17-point
text and line height 1.4, signed B10 takes **15.138 s** and B22 **2.552 s**;
the earlier local-library run was 10.182 / 1.338 s. These use the same queries
and parameters but different build/run boundaries and are not GUI timings.

A fresh signed-app B10 pass at the user's continuous-reading defaults and a
single filled window continuously observes the counter 187 times: still
searching at **32.713 s**, complete with 25 results by **32.806 s**. The first
visible result is observed by 1.230 s. This includes accessibility observation
overhead. The preceding multi-tab pass only bounds completion between 31.198
and 61.683 s because the observations have a gap; 61.683 s is not an exact count
latency. Find Next advances `2 / 25` to `3 / 25` and changes the reading location.
Signed B22 is observed complete with one result by **6.055 s**. Large EPUB
counting still takes material time; parsing and typography are not eliminated.

### Signed solid-seek observations and variation

The first intermediate signed candidate draws pages 1,050/2,097 in
2.568 / 4.917 s at 853 × 665 points, slower than the initial 0.2.7
2.390 / 4.279 s observation. The hardware CRC instructions are present in that
binary. A later aligned intermediate pair at 2545 × 1372 points measures
2.464 / 4.529 s for 0.2.7 and 2.138 / 3.976 s for the candidate. Neither pair
is a percentile study, and the initial variation's exact cause is unproven.

The final signed binary's six-tab pass measures **2.750 / 5.099 s** at
2545 × 1344 points. A final contemporaneous single-tab pair uses fresh old/new
processes, 2545 × 1372 points, and page 382 drawn before each unread destination:

| Destination | Public 0.2.7 | Accepted 0.2.8 | Reduction in this pair |
| --- | ---: | ---: | ---: |
| B01 page 1,050 | 3.093 s | 2.587 s | 16.34% |
| B01 page 2,097 | 5.638 s | 5.061 s | 10.23% |

Both requests belong to fresh archive owners; neither target was visited in its
process. Times run from visible render request to first native canvas draw,
excluding UI command delivery. Filesystem caching is warm/uncontrolled. The
six-tab viewport differs from the paired viewport and is not a controlled tab
overhead comparison. The final pair supports reduced first-seek work, while
the earlier passes show why these values cannot be presented as stable latency
percentiles. First distant seeks still take seconds.

### Publication and installed runtime

[0.2.8](https://github.com/Ares-X/Sumra/releases/tag/v0.2.8) is public through
[publish Action 39461683308](https://github.com/Ares-X/Sumra/actions/runs/39461683308),
which promotes the accepted candidate without rebuilding it. The accepted
`SHA256SUMS` digest is
`2eea62b08eff5e9f6ae69d63d3225b474af73bc1014f18a66570a61d7296e1d6`.
Anonymous public verification confirms the same six asset IDs, names and sizes,
and downloads every asset to compare exact accepted bytes and API digests.
The public corresponding source, manifest, raw main feed and Ed25519 signature
all pass. The app archive SHA-256 is
`5664bd8b6a5177cf61fb01807f85ffcb213de45bfd04be2a32bcaef7e5e90acd`;
the corresponding-source archive SHA-256 is
`f71d2c3df59c1715e55cbb2920de6bde2b0b242bd26a906d11649d5f91eafd13`.
The real 0.2.7 → 0.2.8 Sparkle download, installation and relaunch completes.
Every installed file, directory, link and mode matches accepted provenance;
signature/certificate checks pass, and About displays **0.2.8 (10)**. B01 is
restored to page 382 with native first drawing observed in the updated app.

All 25 originals retain SHA-256, size and nanosecond mtime, including the corpus
inventory set. No original-file write, dependency change or persistent whole-book
payload cache is introduced. Private receipts live under
`build/seek-search-20261020/` and `build/release-0.2.8-final-candidate/` and are
excluded from the public source. Unused probes and superseded app extractions
are retired after retaining receipts. The installed reader remains running.
Physical macOS 13 and real trackpad frame-rate acceptance are not exercised.
