# Issue 42: links, immersive reading and Quick Look

Release-cycle status update (2026-10-26): use [Issue 42 Release
Acceptance](ISSUE42_RELEASE_ACCEPTANCE_20261026.md) for the accepted 0.2.18
candidate and release delivery state. That record supersedes the current or
final labels below for this release cycle; dated evidence remains historical.

Latest original-feedback recheck: [ORIGINAL_FEEDBACK_RECHECK_20261025.md](ORIGINAL_FEEDBACK_RECHECK_20261025.md). Current host is `7BD95D07-CE05-3822-9AE2-F7D5C6DFDCC4`; it fixes short-screen hover-preview containment. The 33-original / 175 third-round / 48 fourth-round layout matrix has now been replayed against current build inputs and the current packaged engine, with 81 focused checks and actual Virtual-display link acceptance. E316 and older observations below retain their historical attribution.

## Current follow-up (supersedes earlier final-candidate/input-boundary labels)

Earlier optimized GUI/Finder observations are the historical 4397-engine pass,
distinct from the later R5 manual/watchdog attempt. Current unsigned native
candidate SHA-256 is
`baf8d6a7fc64c8651c57fa93952e7ac52fb2eca9d2b71ff80d582c464add4a72`; its
MuPDF engine UUID is `E002E933-FFBC-3EFA-9511-CA1BF15C4409`, not the app host
UUID. Current final Release app host UUID is `E31645C1-9D48-37D1-AEEE-D0194363E220`;
packaged engine SHA-256 remains
`a31614b885aad81d31013cd075e48a5ce458929dbd216d4601784b20853f58d7`.
Release build and refined-motion overlay passed; 7CEA is the accepted prior
pre-polish snapshot, and `96420814…` is older. Current binding, 409-input
build, 17 focused motion/toolbar tests, 100k hosted search, Light fullscreen
4:1→5:1, final Book/source binding and cleanup passed. Final acceptance is
`refined-motion-final-acceptance.json`; cleanup is `refined-motion-cleanup.json`.
Detailed current metrics and receipts
are in [feedback traceability](FEEDBACK_TRACEABILITY_20261025.md#current-follow-up-supersedes-the-earlier-final-labels-below). This hosted workflow
is separate from the 25-hit native B10 timing below. Third-pass performance/parity evidence
is in `build/issue42/third-pass-performance/README.md` and
`final-uncapped-parity.json`: 19/19 full ordered JSON and geometry parity.
Five-book comparisons: B10 12.062→6.010 s (warm 6.025; 25 hits), B03
6.772→1.320 s (387), B22 1.755→1.215 s (1). Large Markdown bulk is 3.717 s;
first precise result 11.901 ms, real no-hit 3.814 s, maximum step 18.732 ms,
cancellation 1.375 μs. No stronger Han-LTR total-count gain is established.
The older 12.062 s figure remains a historical candidate measurement.

R6 physical-input acceptance now closes the earlier hover/cursor and system
Colors observation gaps at its recorded boundary. See
`build/issue42/feedback-harness-host/RUN6_ACCEPTANCE.md`,
`run6-acceptance.json` and `interaction-run6-final.json`: real reader/production
dialog, actual CGEvent pointer entry and hand cursor, preview-visible down,
exact one down/up, destination painted, preview closed and no rejected events;
all three NSColorPanel wells were independently exercised by wheel, RGB sliders
and opacity, with correct routing and synchronized values. Apply yielded Text
009062, Background FFFF34, Link CB20A0. Host exit 0 and manual test passed in
54.383 s. The tooltip-owner lifetime defect found in this run is fixed; run-4
crash/run-5 watchdog failure remain historical. Current toolbar and Finder
status are summarized in feedback traceability: the overlay update now passes
Virtual 16:9 window/fullscreen/presentation viewport and pixel checks; the old
C3 AX/CG-click “pass” remains withdrawn because those pixels showed an
invisible toolbar. Restored-registration Finder smoke passed. Native window
controls pass at the documented AX boundary; direct green-button exit is not
claimed.

The historical broad source gate ran 1,214 tests, one manual skip, and two old
Markdown reflow-cancellation assertions. Both original scenarios later passed
the focused cancellation/reflow repair; this does not rewrite the broad-gate
receipt. Corrected queued-query regression, packaging and 17 focused
motion/toolbar tests passed separately. Native Close/open, FullScreen entry and minimize/restore AX
actions also passed within their recorded boundaries; direct green-button exit
remains untested. See
`search-final-source-gate.json` and `reflow-repair-checks.json`.

Source baseline: `32cffde`. Work remains local until explicitly delivered. This
record separates source tests, native/hosted rendering, packaged application
interaction and Finder extension activation.

## Scope and causes

- Link hover previews used a transient popover which intercepted the first
  pointer click. The preview now uses a passive, nonactivating child panel;
  ebook link navigation omits the destination marker. PDF destination indicators
  retain their existing behavior.
- KF8/AZW3 skeletons and insertion fragments were previously read as a flat
  stream, followed by their CSS flows. The decoder reconstructs the HTML,
  separates CSS/SVG resources and translates fragment/offset links before
  resource URI expansion changes byte lengths. Multi-part KF8 is materialized
  as a deterministic EPUB using the already-linked system libarchive so each
  authored document retains its own head, body and CSS context. Joining heads
  was rejected after visible acceptance exposed later `li` styles removing
  earlier TOC numbers. MOBI6 and single-part KF8 retain their HTML adapter.
  App and Quick Look share the Core materializer. SVG flows retain `.svg`
  names and the existing MOBI image indexes. Structured KF8 does not use the
  MOBI6 image-only heuristic: embeds inside SVG must not replace authored text
  with bare images. Empty skeleton tables are rejected with `ReadError` at the
  reconstruction boundary instead of indexing an empty result. No second
  renderer or runtime dependency is added.
- Hidden toolbars now give the unused titlebar area to the document and use its
  palette. Settings → Toolbar has an optional top-edge hover reveal. AppKit owns
  toolbar/chrome visibility in one transaction and preserves the window frame;
  native controls and page-field editing remain available while revealed.
- Quick Look uses the existing book inspection/native adapter for MOBI, AZW3
  and FB2. Host and extensions share book/comic content-type declarations.
  CBR/CBT/CB7 explicitly conform to `public.data`: macOS `public.archive` alone
  does not establish physical-file conformance. Thumbnail drawing uses AppKit
  point coordinates at both 1× and 2× scales.
- Divergent testing found document-specific passage/scroll/pan coordinates in
  per-format defaults. Defaults now retain layout choices and strip document
  coordinates at the owning boundary, including existing contaminated records.
- Visible dark-mode acceptance found white ebook page margins. Palette CSS now
  paints the upstream `@page` background, including margins, rather than only
  the body. Color-only palette changes retain source-passage identity. The
  default dark link color also increased from #6B7280 to #9CA3AF (contrast
  against black from 4.34 to 8.27); this is not a full accessibility audit.
- Generated image links exposed a shared MuPDF target defect across MOBI,
  FB2 and EPUB: the image parser inserts a soft-break before the image, but
  target lookup skipped only anchors. It therefore used the soft-break's
  baseline near the image bottom. The existing native target owner now skips
  that synthetic soft-break before calculating the first actual content top.
  No Swift coordinate compensation is used.

## Inputs

The original `formatsampler.zip` from the issue has SHA-256
`ee9c5d33b919918afae0212eac4d37633357507c2e00c91a139e08451a6ca92b`.
Its six documents and original sizes, mtimes and hashes are inventoried in
`build/issue42/originals-before.json`. The electronic-book samples contain no
body illustrations. AZW3's EXTH-designated cover is a raster picture of a TOC
and remains a cover; its pictured entries are not interactive links. The next
live text TOC contains the clickable links. The user requested generated image-bearing documents for this
acceptance. Synthetic FB2/MOBI HTML fixtures therefore cover oversized art,
small natural logos, authored sizing, page boundaries and actual painted extents.

## Verification status

The broad input matrix and its limits are in
[FULL_ACCEPTANCE_20261025.md](FULL_ACCEPTANCE_20261025.md). Earlier failed tests
and investigation logs remain under `build/issue42/` and are not passing evidence.

The first coherent source gate passed **128 Core, 1,064 app and five Quick Look
tests, zero failures and zero skips**, plus 58 packaging behavior checks and
shared declarations for 11 content types (`source-checks-complete.log`). It
includes original six-format hosted workflows, every original comic page,
generated image-link fixtures, cold comic checks and four published PDF
interoperability samples. Native parse, localization audit and reader JavaScript
syntax checks also passed. The exact local inputs and candidate identity are
recorded in `final-source-before.json`, `final-checks.json` and
`gui-candidate/first-pass-final-identity.json`.

Dedicated native/hosted image tests cover paged, facing, continuous and resized
surfaces, image occurrence counts, painted edge bounds, natural/authored small
images, prose/caption boundaries, real MOBI and FB2 adapters, and immutable
inputs. The valid KF8 fixture additionally exercises real PNGs embedded through
separate SVG flows and per-spine stylesheet isolation.

First-pass isolated-app workflows observed (C1, before the second-pass modal fix and search optimization):

- Final original AZW3 live TOC single click navigates to Chapter 8; Back returns
  to the TOC. The first TOC retains numbers while the final TOC retains its
  authored unnumbered style. No duplicated plain chapter title appears.
- Hidden toolbar in light/dark and full-screen transitions reclaims its space
  and preserves the window frame. Top-edge hover and passive link-panel input
  are additionally covered by hosted AppKit tests; physical hover was not
  independently observed through the available pointer API.
- Final generated FB2 single/facing pages show all four colored image borders
  and caption, with dark page margins. Continuous search locates following
  text in the earlier candidate; hosted final tests cover the same flow.
- Final generated MOBI opens in continuous mode; one click lands at the first
  image's red top edge with all four borders and caption visible. Back returns
  to the opening text. Final hidden-toolbar/full-screen transitions pass.
- Generated PDF opens with complete image borders. System print preview shows
  one full page, cancellation returns to reading and preview can reopen. Save
  as PDF produces a readable output copy; a note can be placed, undone, redone,
  saved and read after closing/reopening. Output and screenshots stay under
  `build/issue42/gui-output/` and `gui-observed/`. No physical print was sent.
  The final candidate independently reopens that saved copy and shows the
  exact note text in its annotation popover.

The first-pass GUI code UUID was `ABEABF7A-1875-32E5-9DB0-D247524F74F0`, matching that
local Release. The packaged MuPDF hash is
`6b130bed0bf5ed66afa46bc0a73199360fb4604cac6fc7c59fb52c1c531ecfb8`, identical
in the isolated clone and source candidate. GUI application identity is
recorded in `gui-candidate/first-pass-final-identity.json`. It was
an ad-hoc local Release clone with a unique preferences domain, no document
associations or extensions, and update checks disabled. It does not establish
behavior of an installed release or Finder-selected provider.

## Actual Finder and installed-release acceptance

The user authorized installing the latest official release and temporarily
registering the candidate. Official 0.2.17 was downloaded from the repository's
release asset, verified against its SHA-256, installed at `/Applications/Sumra.app`
and launched. Its cold Finder Open With opens the EPUB window without a Dock
click. `build/issue42/official-install/receipt.json` records the asset, installation
and signature checks. Static Gatekeeper rejects the project's self-signed
certificate; no security policy or quarantine state was changed.

Actual Finder reproduced the official stubby CBZ thumbnail and missing CBR
preview. The rebuilt candidate was then selected with both extension paths
verified: launchd had reused the official extension during an earlier ambiguous
attempt, so that attempt is not accepted. The dedicated candidate Finder pass
observed full centered CBR/CBZ cover thumbnails, MOBI/FB2/AZW3 first-page
thumbnails, and nonblank Space previews/navigation for all six original suffixes.
The no-cover EPUB retains the generic Books icon on this machine; its Space
preview works. No sample was renamed to EPUB.

`finder-acceptance/actual-finder-pass.json`, `diagnosis/findings.md` and
`evidence/candidate-*.png` retain the actual provider paths and observations.
This pass used host UUID `B934E3D1-3033-398E-96B6-3BB2DF20603A` and preoptimization
MuPDF `6b130bed…ecfb8`. It is not relabeled as an optimized-engine Finder pass.
Temporary candidate registrations were removed and the official application's
registrations restored; the official app remains installed.

## Second pass and search performance

A second exploratory pass found another real ownership defect: a Custom Document
Colors dialog could apply its result to a replacement document. The owning action
now checks the original document identity after closing the color panel. Nineteen
focused tests pass, including Apply/Use Theme/Cancel, replacement, rapid FB2
navigation and reflow; `second-pass-workflows/README.md` retains the failure and
repair evidence.

Native search now filters supported multi-Han text candidates before expensive
glyph shaping, then uses the existing authoritative glyph search for hits. It
retains physical-page/chapter continuations, normalization, RTL fallback and
cancellation. Other queries retain their existing search owner. The five-book
independent oracle preserves full ordered results, sampled pixels, font reflow,
navigation and post-cancel usability. Large EPUB full counting improves from
81.399 s official / 79.606 s preoptimization to 12.062 s optimized, with the same
25 matches. This is native full counting, not foreground UI latency. Details and
memory measurement limits are in `second-pass-performance/OPTIMIZED_ACCEPTANCE.md`.

Final packaged MuPDF SHA-256 is
`4397fb642fd670cc601c20503cbc7e73304177395f6394d743a9ffc4b3fc874d`.
Its UUID and every `__TEXT` section match the measured optimized oracle. The
packaged engine repeats 33 original EPUB entries, 175 third-round geometry checks
and 48 fourth-round paged layouts without a failure. The second full source gate
and final optimized GUI observations are recorded below; the
first-pass GUI evidence above remains attributed to its actual binary.

## Historical 4397-engine optimized acceptance

`optimized-final-checks.json` records **128 Core + 1,067 app + five Quick Look =
1,200 tests**, zero failures and zero skips; 58 packaging checks, 11 shared types,
679 localization keys, parsing and reader-script syntax also pass. The second
full gate repeats 25 retained-book workflows and every one of 4,942 comic pages.
All 396 source/build/test inputs stayed unchanged during build/checks; all 67
retained originals and four primary PDFs retain SHA-256, size and nanosecond mtime.

The loaded historical isolated clone used main UUID
`B934E3D1-3033-398E-96B6-3BB2DF20603A` and packaged MuPDF `4397fb64…b3fc874d`.
`optimized-gui-acceptance.json` and `gui-observed/optimized-*` record final AZW3
Chapter-8 first-click/final TOC, rapid eight-forward/three-backward paging to the
expected chapter, complete FB2/MOBI image borders/captions, Light/Dark hidden
chrome in window/fullscreen/presentation, typed and reopened per-book/global
Iowan selection, color Apply/Cancel/Use Theme and dialog heading/app-switch RGB
binding, and reopening the exact saved PDF note.

The historical GUI large-book search visibly publishes a match while counting, then
completes with 25 hits. A different search was closed while visibly counting;
the next physical arrow changed pages and later process CPU was idle. These are
coarse interaction observations, not a measured 12-second GUI benchmark.

Final actual Finder repeated all six original suffixes with nonblank Space
previews and the corrected thumbnails; CBR next-page navigation reaches 2/11.
Cold Finder Open With reveals the EPUB window without a Dock click or activation
helper after the action. `finder-acceptance/optimized-actual-finder-pass.json`
binds final host/engine and actual selected extension processes. The previous
preoptimization Finder pass remains historical. Candidate registrations have
been removed; both selected extension paths point to `/Applications/Sumra.app`.

The historical 4397-engine pass did not independently observe pointer entry,
hand cursor or system Colors wheel/sliders. R6 now closes the link-preview and
Colors-panel gaps at the real-reader host boundary: actual pointer entry and
hand cursor, 6.36984 s preview dwell, preview-visible click, exactly one down/up,
destination paint, closed preview and zero rejected events. All three
NSColorPanel wells were independently changed by wheel, RGB sliders and opacity;
routing and synchronized values were correct. Apply yielded Text `009062`,
Background `FFFF34`, Link `CB20A0`. Host exited 0 and manual test passed in
54.383 s. Current toolbar and Finder status is summarized above and in
feedback traceability. The former fullscreen/presentation C3 AX/CG-click result
is withdrawn because retained pixels show an invisible toolbar. The new overlay
passes 13 `ReaderToolbarTests` plus four `PanelMotion` tests and Virtual 16:9 window/fullscreen/presentation
viewport/pixel UAT. Native Close/open, FullScreen entry and minimize/restore AX
actions passed within the documented boundary; direct green-button exit and
main notched display after the move remain untested.
No physical print, earlier macOS/Intel or full VoiceOver acceptance is claimed.

The historical 4397-engine candidate remained ad-hoc signed and unpublished.
Current Release build, native `__TEXT` binding, 17 focused motion/toolbar tests,
Light fullscreen, bounded native window-control actions, Release-hosted 100k
search and QA cleanup passed as recorded above. Direct green-button exit and
main notched-display validation remain untested. Official
0.2.17 is installed separately; no issue reply/closure, PR, push or release was
performed. Two owned superseded bundles were retired after preserving identities
and checking for active use; unrelated prior build/source work remains intact.
