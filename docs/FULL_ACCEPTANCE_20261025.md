# Broad reader acceptance — 2026-10-25

Latest original-feedback recheck: [ORIGINAL_FEEDBACK_RECHECK_20261025.md](ORIGINAL_FEEDBACK_RECHECK_20261025.md). Current host is `7BD95D07-CE05-3822-9AE2-F7D5C6DFDCC4`; it fixes short-screen hover-preview containment. The 33-original / 175 third-round / 48 fourth-round layout matrix has now been replayed against current build inputs and the current packaged engine, with 81 focused checks and actual Virtual-display link acceptance. E316 and older observations below retain their historical attribution.

## Current-candidate follow-up (supersedes historical “final” labels below)

Earlier optimized GUI/Finder observations are the historical 4397-engine pass;
they are not the later R5 manual/watchdog attempt. Current unsigned native
candidate SHA-256 is
`baf8d6a7fc64c8651c57fa93952e7ac52fb2eca9d2b71ff80d582c464add4a72`, and
`E002E933-FFBC-3EFA-9511-CA1BF15C4409` is its MuPDF engine UUID, not app host
UUID. Current final Release app host UUID is `E31645C1-9D48-37D1-AEEE-D0194363E220`;
packaged engine SHA-256 remains
`a31614b885aad81d31013cd075e48a5ce458929dbd216d4601784b20853f58d7`. Release
build passed in 56.935 s; deep/strict codesign passed and 409 input hashes were
stable (`refined-motion-clean-release-build.json`).
`toolbar-overlay-final-engine-binding.json` bound the pre-polish 7CEA snapshot;
the current E316 binding is `third-pass-performance/refined-final-engine-binding.json`,
with every `__TEXT` section matching. The 7CEA host is the accepted pre-polish
snapshot; 96420814… is older still. Original preservation is 71/71. Final
acceptance passed (`refined-motion-final-acceptance.json`) and cleanup passed
(`refined-motion-cleanup.json`); the earlier cleanup script failure moved
nothing and is superseded.
The corrected queued-query regression passed in 23.86 s
(`search-repair-final-test.json`); 27 focused passes were reused, and packaging
passed 58 checks plus 11 declarations in 4.30 s. The 7CEA 100k result
(16.31163 s) remains the no-regression baseline. Current E316 hosted 100k search
passed with 100,144 results in 15.45364 s (15.89674 s complete), Main pulse
max 59.688 ms (one over 50 ms, none over 100 ms), and final target
100,144/100,144 painted on page 10,224; cancellation, reading during count and
replacement passed. See `refined-release-high-volume-search.json` and
`third-pass-publication/refined-release-publication.json`. This hosted workflow
is separate from the unchanged 25-hit native B10 timing below.
The independent third-pass performance
receipt and `final-uncapped-parity.json` report 19/19 full ordered JSON and
geometry parity. Five-book comparisons: B10 12.062→6.010 s (warm 6.025; 25
matches), B03 6.772→1.320 s (387), B22 1.755→1.215 s (1). Large Markdown
bulk remains 3.717 s; first precise result 11.901 ms, real no-hit 3.814 s,
maximum step 18.732 ms, cancellation 1.375 μs. No stronger Han-LTR total-count
gain is claimed. Thus the former 12.062 s large-EPUB result is historical; the
current comparison is 6.010 s with the same 25 hits.

R6 physical-input acceptance is complete for link preview/cursor and Colors:
`build/issue42/feedback-harness-host/RUN6_ACCEPTANCE.md` and its JSON receipts
record real `NSApp`/production dialogs, actual pointer entry and hand cursor,
6.36984 s dwell, preview-visible click down, reader Canvas key state, one exact
down/up, painted destination, closed preview and zero rejected events. The
independent system panel changed wheel/RGB sliders and opacity across all three
wells, with correct routing and synchronized values; Apply yielded text
`009062`, background `FFFF34`, link `CB20A0`. Host exit 0; manual test passed
in 54.383 s. The run's tooltip-owner lifetime defect is fixed. The earlier
run-4 crash/run-5 watchdog timeout remain historical failures. Current refined
toolbar, Finder and prior C3 pixel-withdrawal status is summarized in
[feedback traceability](FEEDBACK_TRACEABILITY_20261025.md#current-follow-up-supersedes-the-earlier-final-labels-below).

The historical broad source gate (`build/issue42/search-final-source-gate.json`)
ran 1,214 tests with one manual skip and two old Markdown reflow-cancellation
assertions failing. Both original scenarios later passed the focused repair
checks in `reflow-repair-checks.json`; this does not rewrite the historical
broad receipt. A 28-test closure log had one invalid timing assertion; its
corrected contract check and Release/package binding passed. Thirteen current
ReaderToolbar tests plus four PanelMotion tests are recorded separately. Do not present either historical broad
gate as the final Release gate.

This matrix extends issue #42 acceptance across the retained local book corpus,
original format samples, earlier EPUB reports and reader/PDF behavior. A hosted
reader test opens real `ReaderState`/`ReaderView` owners and records painted
snapshots; it does not constitute physical input, every-page visual inspection
or acceptance of a different installed binary. Each result below retains that
boundary. The historical matrix below is a local source/candidate record, not
a published release. Those checks ran on macOS 27.0.1 (26A434), arm64.

The historical optimized source gate passed **1,200 Swift tests** (128 Core,
1,067 app and five Quick Look), **zero failures and zero skips**, plus 58
packaging checks and 11 shared content-type registrations. The source receipt
checks all 396 build/test inputs unchanged. Final optimized GUI and actual
Finder workflows are recorded separately in `optimized-gui-acceptance.json`
and `finder-acceptance/optimized-actual-finder-pass.json`. The earlier 1,197-test
preoptimization run remains historical evidence in `final-checks.json`.

## Inputs and preservation

The local-only inventory is `build/issue42/corpus-exploration/inventory-before.json`.
It records SHA-256, size and nanosecond modification time before testing for:

| Group | Inputs | Content/workflow boundary |
| --- | ---: | --- |
| Retained library | 25 | 14 EPUB, two PDF, three CBZ, two Markdown, two TXT, one CHM, one MOBI. Includes fixed EPUB, large reflow books, long text/Markdown, GBK CHM and solid archives. |
| Issue #42 originals | 6 | CBR, CBZ, AZW3, EPUB, FB2, MOBI, all supplied originals. |
| Generated image boundaries | 3 | FB2, MOBI and PDF with observable image edge markers. |
| Earlier EPUB round 1 | 10 | Original misaligned EPUB reports. |
| Earlier EPUB round 2 | 10 | Original second-round reports. |
| Earlier EPUB round 3 | 5 | Four third-round reports and one repeated second-round report. |
| Earlier EPUB round 4 | 8 | Six fourth-round reports and two repeated second-round reports. |

All 25 retained-library inputs match the fourth-round inventory by SHA-256, size
and nanosecond mtime. Earlier EPUB round inputs include reports labeled as repeats. All 33 retained
file entries have different SHA-256 values; that is not evidence of 33 distinct
authored books. The corpus and raw titles remain
local and are not shipped as public fixtures. The post-run `inventory-after.json` and `preservation.json` confirm all **67/67**
entries retained exactly the same SHA-256, size and nanosecond mtime. No original
was written or replaced.

## Acceptance matrix

| Layer / formats | Workflow and assertion | Current result | Evidence / limits |
| --- | --- | --- | --- |
| Source checks | Native parsing, 679-key localization audit, Core/app/Quick Look tests, packaging and script syntax | **128 Core + 1,067 app + five Quick Look = 1,200; zero failures / skips**, plus 58 packaging checks and 11 shared content types | `build/issue42/optimized-source-checks.log`, `optimized-final-checks.json`; retained library, all comic pages, original samples, generated fixtures, cold-comic and four primary PDF interop enabled. |
| Retained library: 25 books | Open/first paint; first/middle/final positions; painted bitmap; Contents navigation; extraction; complete search and selected result | **25/25 passed again**, 106.697 s total hosted workflows; largest 33.881 s | `corpus-exploration/optimized-final-known25-workflows.json`; same maintained harness/layout/watchdog. These are hosted workflow durations, distinct from paired native benchmarks. Earlier 183.588 s run remains retained. |
| Retained comics: three CBZ | Decode every page at width 800 with nonzero dimensions | **4,942/4,942 passed again**, 82.275 s | `corpus-exploration/optimized-final-known25-workflows.comics.json`; does not establish foreground visual inspection of every page. |
| Issue #42 originals: six formats | Same hosted full-document workflows, including AZW3/FB2 through the existing ebook owner | **6/6 passed**, repeated in final gate after KF8 spine changes; every original comic page also decoded | `issue42-workflows.json` and final `issue42-final-workflows.json` / `.comics.json`; harness extension allowlist expanded to include AZW3 and FB2. Other parameters and assertions unchanged. |
| Generated FB2/MOBI/PDF | Same hosted open/navigation/Contents/search workflow | **3/3 passed**, 2.200 s | `generated-workflows.json` / `.log`; dedicated image boundary assertions and visible GUI checks retain their separate evidence in the issue #42 record. |
| Earlier EPUB originals | Layout/image boundaries and authored geometry | **33/33 retained entries passed again** with the optimized packaged engine; third-round **175 checks** and fourth-round **eight books / 48 paged layouts** passed | `optimized-final-prior-epub-native-sweep.log/json`, `optimized-final-packaged-third-round-layout.log/json`, `optimized-final-packaged-fourth-round-layout.log/json` and `-assertions.json`; summary `optimized-final-epub-replay.log`. Signed packaged engine SHA-256: `4397fb642fd670cc601c20503cbc7e73304177395f6394d743a9ffc4b3fc874d`. Earlier `final-*` reports remain historical evidence. |
| Reader defaults/restoration | Cross-book layout defaults versus document-specific position, rotation and history; overlapping opens and search | **11 related tests passed**; two demonstrated default-coordinate failures fixed at owner | `broad-reader-final.log`; [reader workflow record](BROAD_READER_WORKFLOW_ACCEPTANCE_20261025.md). Explicit saved-document positions retain their own behavior. |
| PDF editing / forms / links | Encrypted forms/annotations/undo/save/restrict; rotated/cropped snapshots and duplicate/reordered subset/print; cancelled copy after external source replacement | **Three chained exploratory cases passed**, alongside the full app suite | `pdf-exploration/README.md`, logs and retained PDF/PNG hashes; transparent pixel comparison preserves exact source pixels. Visible print/note workflows are separate below. |
| Themes / page margins | Normal-size body/link contrast of offered themes; full-page/tile corners, finite/facing/continuous, authored image pixels and passage identity | Default dark link contrast fixed; **27 related contrast checks and 15 page-margin/browser checks passed** | `theme-contrast-final.log`, `reflow-background-final.log`, `reflow-background-browser.log`; custom themes remain user choices. No full WCAG/VoiceOver claim. |
| Isolated candidate GUI | AZW3 first-click Chapter 8/final TOC; rapid arrows; Light/Dark hidden toolbar/window/fullscreen/presentation; MOBI/FB2 image borders; per-book/global Iowan; color Apply/Cancel/Use Theme/heading/app switch; large-book search/cancel/next page; saved PDF note | Historical 4397-engine pass; large-book full result 25; another in-progress search closed then next page worked | `optimized-gui-acceptance.json`, `gui-observed/optimized-*`, `gui-candidate/identity.json`. R6 completes physical preview/cursor and production Colors-panel interaction. Current E316 overlay passes 13 ReaderToolbar + four PanelMotion tests and Virtual 16:9 window/fullscreen/presentation UAT; physical Light fullscreen 4:1→5:1 passed. The 7CEA native control-action evidence remains valid; E316 observed three macOS-owned controls windowed. Direct green-button exit, older OS runtime, and main notched display after the move remain untested. Cleanup and final engine/source binding passed; Book/source binding and light-theme review are closed per the final receipt. See feedback traceability for exact boundaries. |
| Actual Finder: six issue #42 formats | Original suffixes; thumbnails and Space Quick Look; cold Open With | Historical 4397-engine pass: all six nonblank previews, CBR next2/11; centered CBR/CBZ covers and MOBI/FB2/AZW3 thumbnails; no-cover EPUB generic Books icon retained. Cold Open With reveals EPUB without Dock click | `finder-acceptance/optimized-actual-finder-pass.json`, `optimized-preview-AX.json`, `evidence/optimized-*`; historical host B934… / engine4397…; selected provider paths/processes were verified in that pass. Official registration restored. Retina Finder is separate from 1×/2× source drawing tests. |
| Native search correctness/performance | Official 0.2.17 → preoptimization → optimized engines, same five real books/parameters; complete ordered results, pixels, source preservation and cancellation recovery | **Five cases pass the independent result oracle**. Large EPUB full counting **81.399 → 12.062 s**, same **25 ordered hits**; second CJK EPUB **2.556 → 1.755 s**, same one hit | `second-pass-performance/OPTIMIZED_ACCEPTANCE.md`, `optimized-replay.json`; `final-packaged-engine-binding.json` binds the measured optimized native code to the signed packaged engine. Native API timing is not foreground app latency; Markdown memory findings remain qualified below. |

Both complete source gates opted into the maintained PDF interoperability tests with
four newly downloaded primary-source originals (arXiv paper, PBC report, PDF
Association UTF-8 example and a blank IRS W-9). Their hashes match the retained
[PDF interoperability inventory](PDF_INTEROPERABILITY.md); the current
download URLs, hashes, sizes and mtimes are in `pdf-interop-before.json`. Only
artificial annotation/form values are used. PDFKit/Quartz reopening is an
independent API check, not a physical Acrobat/Preview application workflow.

The baseline library harness sets paged/page-fit, zoom 1, no spread/cover, light
theme, system font 17, line height 1.4 and margin 32. It leaves the existing
120-second per-stage stall watchdog unchanged. It samples actual middle/final
source chapters for lazy books instead of treating an incomplete global page
count as complete pagination. The retained library completes **21 positive text searches**, plus one
fixed-layout EPUB no-match check and three comics with text search inapplicable.
The six issue #42 inputs add four positive searches and two comics; the three
generated documents all complete positive searches. Counts and selected targets
are retained per file in JSON. A no-text result is accepted only through the
existing fixed EPUB/PDF/no-text-capability rules; it is not represented as a
successful positive text-search check.

Source diagnostics for malformed publisher CSS, missing local font faces and
XHTML repaired by the existing HTML5 parser remain in the logs. They did not
produce a failed workflow and are not hidden or treated as fidelity approval.
`summary.json` aggregates the four reports. All three owned Swift test sessions
exited with status 0; no background analysis, indexing or build process was
started or left running by this corpus task. Shared app/engine processes remain
under their owning tasks.

## Historical optimized native search and packaged regression evidence

The demonstrated hotspot was glyph extraction/shaping on finite HTML pages
whose first query rune was common. `Native/MuPDF.c` now supplies the complete
Fitz-normalized pure-basic-Han query to the existing laid-out candidate. The
ordered prefix matcher in `mupdf-html-paginated-search-candidate.patch` uses
memory proportional to the query. Non-Han omission and adjacent-duplicate
collapse broaden candidates; unrelated Han remain barriers. A finite page's
nonempty trailing query-prefix suffix proceeds to the original glyph-window
search, retaining physical-page/spine continuations. RTL/fixed-layout content
and other queries keep their existing authoritative search paths. Matching
options, ordered results, source positions and rectangles remain glyph-owned.

The native build and focused tests pass independently of the running Swift
gate: finite Han cases across eight option/direction combinations, natural-page
paint/order/Unicode cases, repeated prefixes, canonical/compatibility forms,
duplicate glyphs, real physical seams, and in-traversal cancellation with a
fresh-request recovery. Receipts and reproduction commands are in
`build/issue42/search-performance/README.md`, `CrossPageSearch.log`,
`EPUBSearchNaturalPhrase.log`, `EPUBSearchCandidate.log` and `finite-cancel.log`.
These native tests retain their boundary alongside the completed final GUI pass; they do not prove physical pointer-hover behavior.

The independent five-book native oracle retains the official and
preoptimization baselines rather than overwriting them:

| Real-book case | Official full count | Preoptimization full count | Optimized full count | Optimized warm | Ordered hits |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary EPUB | 6.8390 s | 6.8436 s | 6.7718 s | 5.5360 s | 387 |
| Large Markdown | 3.7581 s | 3.7410 s | 3.8205 s | 3.7654 s | 1 |
| PDF | 0.1989 s | 0.1971 s | 0.2022 s | 0.0934 s | 14 |
| Large EPUB | 81.3991 s | 79.6062 s | 12.0622 s | 12.2867 s | 25 |
| Second CJK EPUB | 2.5556 s | 2.5659 s | 1.7551 s | 1.7365 s | 1 |

Each case preserves complete ordered match JSON, warm results, first/middle/
final rendered pixel hashes, font-change/restoration pixels, five-position
navigation pixels and source SHA-256/size/nanosecond mtime. The large EPUB's
page-search stage drops from 75.508 s official / 73.660 s preoptimization to
2.186 s; optimized candidate scanning takes 5.189 s and chapter layout 4.582 s.
This measures full counting. Native first-result and cancellation checkpoints
retain their own boundary; cancellation recovery is not a timed GUI Cancel
click. Fresh engine/file workers share uncleared OS caches, and CPU counters
are retained alongside wall time. No speed threshold was added.

The Markdown memory follow-up does **not** establish an app-memory regression
or prove equal memory use. Three order-alternated official/optimized pairs have
reading-stage peaks of 339.59–352.28 MiB / 340.16–359.53 MiB, with paired
differences +7.250, +0.562 and +15.219 MiB. Whole-worker peaks also include
post-close Python hashing; in two pairs the reading difference already appears
before search. The small sample, overlapping ranges, native layout and allocator
effects leave the cause unresolved. All result hashes agree; these values are
not Sumra foreground-app RSS or evidence of a leak. See
`second-pass-performance/b06-memory-repeat/summary.json`,
`phase-RSS-analysis.json` and `reading-peak-analysis.json`.

The final packaged engine at `dist/Sumra.app/Contents/Frameworks/MuPDF.dylib`
has signed SHA-256
`4397fb642fd670cc601c20503cbc7e73304177395f6394d743a9ffc4b3fc874d`
and Mach-O UUID `4B421508-AF20-3752-B8AB-0B2EA052C89D`. Its UUID and every
named `__TEXT` section match the measured unsigned optimized snapshot
(`916ae033c7be82a7684a03c2b125bf64fd612d515527522131f6a5be1d23e148`);
aggregate section hash is
`679e0c753098ba7d161814f4718ebcdf7a9c518b6b32636b8dcf25d4c2adb707`.
`second-pass-performance/final-packaged-engine-binding.json` records no section
mismatches. This explains the differing signed/unsigned file hashes without
equating them. The packaged-native EPUB replay independently passes all
33 retained entries, 175 third-round geometry checks and eight fourth-round
books / 48 paged layouts. `optimized-final-epub-inputs-before.json` and
`optimized-final-epub-inputs-after.json` preserve all 67 inventoried inputs.

Historical actual Finder acceptance was repeated against the 4397 optimized candidate,
including six nonblank previews and cold Open With. The shipping official
0.2.17 remains installed at `/Applications/Sumra.app`; candidate registrations
were removed and both selected extension paths point back to that official app.
The installed official release does not contain these local fixes or this search
optimization. Final GUI observations and remaining input-tool boundaries are in
`optimized-gui-acceptance.json`; all 67 retained inputs and four primary PDF
originals preserve SHA-256, size and nanosecond mtime in
`optimized-original-preservation.json`.

## Reproduction

Run from the repository root after the shared Swift build slot is available.
`SUMRA_BOOK_CORPUS_FILE` remains unset for complete inventories. Each command is
separate to preserve the failing receipt and avoid overlapping shared builds.

```sh
python3 build/issue42/corpus-exploration/inventory.py before
env -u SUMRA_BOOK_CORPUS_FILE SUMRA_BOOK_CORPUS_DIR=/Users/aresx/Documents/Books SUMRA_BOOK_CORPUS_ALL_COMIC_PAGES=1 SUMRA_BOOK_CORPUS_REPORT="$PWD/build/issue42/corpus-exploration/known25-workflows.json" swift test --filter BookCorpusAcceptanceTests
env -u SUMRA_BOOK_CORPUS_FILE -u SUMRA_BOOK_CORPUS_ALL_COMIC_PAGES SUMRA_BOOK_CORPUS_DIR="$PWD/build/issue42/fixtures/formatsampler" SUMRA_BOOK_CORPUS_REPORT="$PWD/build/issue42/corpus-exploration/issue42-workflows.json" swift test --filter BookCorpusAcceptanceTests.testAllDocumentWorkflows
env -u SUMRA_BOOK_CORPUS_FILE -u SUMRA_BOOK_CORPUS_ALL_COMIC_PAGES SUMRA_BOOK_CORPUS_DIR="$PWD/build/issue42/gui-fixtures" SUMRA_BOOK_CORPUS_REPORT="$PWD/build/issue42/corpus-exploration/generated-workflows.json" swift test --filter BookCorpusAcceptanceTests.testAllDocumentWorkflows
python3 build/issue42/corpus-exploration/inventory.py after
```

## Not exercised / unresolved

Until its row receives a receipt, it remains pending. The original-file matrix
covers ten extensions: EPUB, PDF, CBZ, Markdown, TXT, CHM, MOBI, CBR, AZW3 and FB2.
XPS/OXPS, standalone SVG/DjVu, compressed FB2, other AZW/PRC variants, TCR, LIT,
P7M, PDF-compatible AI, image folders, multi-frame images and JXL do not acquire
real-original corpus acceptance from this sweep. Existing generated source-test
coverage for some of those routes keeps its narrower boundary. Even completed corpus
workflows do not establish every EPUB/PDF page, every feature combination,
physical printing, full VoiceOver interaction, compatibility on earlier macOS or
Intel, DRM ebooks or unrepresented encryption variants, cloud/network locations, every CBR compression
variant, or every format listed by the product. Existing unsupported paths and
known performance limits are not relabeled as successes.

## Historical local packaging boundary

The final standard local Release build passed (`optimized-release-build.log`).
Deep/strict ad-hoc signature verification passed again after GUI/Finder checks.
The optimized packaged engine binding, second full source gate and actual GUI
receipts are recorded above. The optional release provenance attempt
failed before Swift compilation: `scripts/package-release.swift` requires the
MuPDF directory to be an independent Git checkout at the pinned revision;
this retained local dependency tree has an exported source-revision marker and
no `.git`, so Git resolves the parent project's revision. The rejection remains
in `release-build-provenance-attempt.log`; no marker or repository metadata was
fabricated and the release check was not weakened. The ordinary local build
uses the supported source-marker path. This candidate is not a notarized,
published release and has no complete release provenance attestation.
