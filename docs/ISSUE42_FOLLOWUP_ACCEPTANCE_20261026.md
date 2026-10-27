# Issue 42 follow-up acceptance — 2026-10-26

Current local follow-up: [October 27 reader acceptance](READER_ACCEPTANCE_20261027.md),
including final title/native safe areas, bottom progress and issue 48 PDF reload.
The subsequent [interaction/performance round](INTERACTION_POLISH_20261027.md)
records progress feedback refinements and repeated negative-query optimization.

**Status: the signed 0.2.19 candidate passed the previously reported bug-fix acceptance;
0.2.19 is published and installed. Public download verification passed;
the complete 0.2.18 → 0.2.19 updater workflow passed after the user restored
the proxy connection. Later feedback added title-page sizing, global themes,
file-opening behavior, and native tabs remaining visible over the book. Local
0.2.20 corrections passed a 1,262-test integrated source checkpoint. Subsequent
toolbar and FB2 title-spacing refinements passed their affected checks. The
October 27 revision and its remaining acceptance boundaries are recorded below;
the earlier gates do not validate later source changes. Personal acceptance,
signed acceptance and publication remain pending. The earlier TLS failure is
retained below.**
[PR #46](https://github.com/Ares-X/Sumra/pull/46) was merged as
`e39f2f03c7716aab85c1cf64505404307c03ce44`. The accepted app was built from
`44c8c19ea81d1489a3f74f57592e5df13a63eb5d` by the
[signed candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/40293832740).
Its host UUID is `E7EB07E9-FD52-3447-B5E0-797617506CCB`, engine SHA256
`4caa65929fcccd0a9b3da64dea91ee8ca0830e7642af08c5736442372994ceb3`, and engine
UUID `4A19310F-C4A8-3C08-85E4-F697C1A30D44`. Signature, bundle manifest and
corresponding-source checks passed. All 413 inputs in the final 1,238-test
source gate match the committed candidate source. The installed official app is 0.2.19 (21), and the original Alice FB2 was
opened from that installed executable on the physical display.

The exact signed app was exercised on the physical main display, then quit.
Temporary candidate registration was removed, official registration and saved
application preferences restored, and owned candidate providers stopped or
observed exited. Evidence is under `build/release-0.2.19/`, headed by
`signed-acceptance.json`, `candidate-downloads.json`, `candidate-identity.json`,
`correspondence-check.json`, and `validation-source-binding.json`.
The optional coverless EPUB thumbnail and dense-search performance goal remain
unresolved; neither is included in the bug-fix pass.

A later search-optimization experiment exposed an additional limitation in
0.2.19: prior bitmap rendering can leave a transform on a shared font face and
change later HTML pagination. The 6,591 logical occurrences and source anchors
remain the same, but their page assignments and rectangles can differ between
rendering histories. The recorded position checks below did not cover that
comparison. A follow-up native correction now produces identical full-book
search geometry with no prior rendering, with the first or middle page rendered,
and with differently primed search workers. That correction is not part of the
published 0.2.19 bytes; application integration and acceptance remain separate.

## Latest feedback cross-check

The issue still had nine comments at the 21:35 local-time cross-check. The [earlier reporter reply](https://github.com/Ares-X/Sumra/issues/42#issuecomment-6415229740)
was created at `2026-10-26T11:46:52Z` and edited at `11:47:33Z`. It confirms
that the clipping, empty page, stuck previews, resize outline, toolbar overlay,
native fullscreen controls and thumbnail proportions are fixed, and adds the
three follow-up items below. A [further reply at 12:34 UTC](https://github.com/Ares-X/Sumra/issues/42#issuecomment-6416106998)
shows native tabs remaining visible above a hidden toolbar and asks for unified
visibility with opaque reveal. The maintainer also reproduced image movement
during a trackpad pinch on Alice MOBI. Both are in the current scope.
The earlier three-comment snapshot remains in
`build/release-0.2.19/issue-latest.json` and `issue-comments-latest.json` as
historical evidence.

| Reported behavior | Local evidence and remaining acceptance |
| --- | --- |
| Preview intercepts first click; blue destination circles | Reporter confirms 0.2.18 fixed both. Signed-candidate physical single-click regression passed. |
| AZW3 dead links and visible CSS | Reporter confirms both fixed. Signed original sample: all 8 live TOC links navigate; final page has no CSS. The image-only first page is not an interactive TOC. |
| FB2/MOBI image peeking, normal and fullscreen | Signed original Alice books: FB2 7 normal + 5 fullscreen pages; MOBI 9 normal + 7 fullscreen pages visually checked. All illustrations intact, no empty first/last page. |
| Link preview remains open; two previews in a spread | Six lifecycle tests plus signed-candidate 10/10 physical pointer steps pass, including repeated URI targets, departure during delay, and cross-page handoff. |
| Blank cover/comic click then enlarge leaves blue outline | Signed cover on/off and comic blank-area click/enlarge cases pass. Cover-on and comic keyboard navigation also pass. |
| Revealed toolbar has no background, especially in dark mode | Signed themed windowed/fullscreen dark captures pass; presentation has no grey stripe and Escape restores the reader. |
| Fullscreen hidden toolbar leaves gap/shadow; hover causes movement | Signed dark fullscreen 330 frames and light windowed 345 frames have zero registered body movement and unchanged window geometry. This measures spatial stability, not application FPS. |
| Always Hide removes native window buttons | Actual top-edge reveal exposes native Close/Zoom without reader tools; Zoom exits fullscreen. Minimize remains disabled by native fullscreen behavior. |
| CBZ thumbnail placement; new thumbnails too wide | Natural-page canvas proportions replace the fixed landscape canvas; original landscape comic art retains its shape. Signed Finder recheck passed. |
| CBR/MOBI/FB2/AZW3 extension recognition and Quick Look | Reporter confirms format compatibility improved; all six original extensions passed actual Space preview, including CBR page 2. Signed extension loading confirmed for both providers; all six Space previews and CBR page 2 pass. |
| Generate a thumbnail for the coverless EPUB too | Unresolved optional enhancement. Normal installation, default-app selection, and explicit extension election still route it to Books. Space preview works. |
| First FB2/MOBI image remains small and off-center as the canvas grows | Local 0.2.20 title-page correction; original-book normal/fullscreen screenshots visually checked, including narrow/short layouts and MOBI spreads. Personal review then rejected excess FB2 whitespace. The further spacing correction and final loaded-app screenshots are recorded below; personal and signed acceptance remain pending. |
| Theme changes should apply to every window and not be restored per book | Global owner replaces per-book theme restore; focused tests pass. Actual open MOBI and FB2 tabs both adopted a dark theme change. Signed acceptance pending. |
| File → Open should reuse an empty welcome window or open a new window | Shared ordinary-open routing corrected; 40 lifecycle tests pass. GUI opening reused the welcome window, then retained FB2 and created a second native-tab reader for MOBI. Signed acceptance pending. |
| Native tabs remain visible and transparent when toolbar is hidden | Local correction links native accessory visibility to toolbar mode and paints an opaque theme background. 21 toolbar tests pass, including native overflow, shared-companion ownership and borderless-window cases. Both bars responded to real hover on the physical M27Q display. User acceptance is required before replying to the reporter. |
| Trackpad pinch moves images around the page | Final shared raster-reader anchor correction is included in the frozen gate. Six focused tests pass across 13 hosted paths, including original Alice FB2/MOBI and representative PDF/comic/reflow layouts, with 0.0-point drift in constrained painted samples. Physical trackpad acceptance remains pending. |

The reporter accepted the earlier overlay behavior, but the maintainer's later
personal review rejected controls covering the title. The current policy keeps
stable native toolbar/tab space in every mode, plus system-menu space in
fullscreen. Reveal changes visibility without repaginating or moving the book.
Dense full-count search remains a separate unmet
performance goal: 0.2.19 took 16.921 seconds for 6,591 matches; local 0.2.20
search work completed in 9.44 seconds normally and 13.33 seconds including a resize restart.
See the [search follow-up report](SEARCH_FOLLOWUP_ACCEPTANCE_20261026.md).
Neither that goal nor the optional coverless EPUB thumbnail is marked solved.

## Local 0.2.20 integrated checkpoint

The integrated frozen gate at
`build/perf-followup-20261026/source-gate-complete/source-gate.json` passed
1,262 tests with zero failures/skips. All 419 inputs and native engine SHA256
`203171083c375425d457bd476534c27fc995f3daff5c34f79a89b8463dee2e4a`
stayed unchanged. The 25-book and 4,942-comic-page corpus, localization audit
and packaging checks passed. Swift tests took 640.284 seconds; the complete
gate took 648.851 seconds. The manual interaction harness was excluded.
This includes the final pinch anchor, native-tab shared ownership and borderless
accessory correction, and supersedes the earlier 1,242-test search checkpoint
for current source coverage.

Earlier integrated attempts found stale localization coverage, then two obsolete
exact-HTML assertions and a borderless AppKit titlebar-accessory `NSException`.
Those failures were corrected before the final frozen pass; they are retained
as validation history. Focused toolbar and Core legacy-book checks passed
20 and 25 tests respectively in
`build/perf-followup-20261026/native-tabs-and-legacy-books-final-20261026.log`.
The exact old shared-companion implementation fails four assertions with the
corrected fixture in `native-tabs-shared-companion-before-fix-final-fixture-20261026.log`
in that directory. Focused pinch evidence is `pinch-final-tests.log`: 6/6 tests,
13 hosted paths, 0.0-point drift in constrained painted samples. Hosted input
does not establish a physical trackpad workflow.

The local bundle is 0.2.20 (22), about 33 MB, and ad-hoc signed.
Original Alice FB2/MOBI images were visually checked in normal, fullscreen,
narrow, short and double-page layouts. Main-display obstruction was resolved
with the user's help; subsequent interaction used the physical M27Q display.
The final pre-overflow build's real fullscreen recording contains 358 decoded
frames, visible toolbar/tab transitions, unchanged window bounds and a single
body-registration shift of (0, 0). This is spatial continuity evidence, not an
app-FPS measurement. The windowed recording had no visible chrome transition
and is not counted as hover acceptance.

A subsequent 560×720 visual check found AppKit's native overflow chevron still
visible while the toolbar was hidden. The correction fades/hides the complete
native toolbar view, found through its public accessibility role, while retaining
the installed toolbar and viewport. Lookup skips the document-content subtree.
The new regression failed nine assertions before the fix (including the hidden
overflow intercepting hits). All 21 toolbar tests then passed; after bounding the
lookup, the three affected overflow/book-viewport/shared-companion tests passed
again. Logs are `overflow-before.log`, `overflow-after.log` and
`overflow-bounded-lookup.log` under `build/perf-followup-20261026/`.
The 1,262-test gate precedes this final toolbar-only refinement; it must not be
represented as a rerun against that refinement.

The original MOBI rabbit image explicitly specifies `align="baseline"`,
`width="320"` and `height="480"` in a paragraph containing prose. Narrow-window
screenshots therefore retain words next to the bottom of the illustration.
This authored inline layout is recorded for the user's visual review and is
not described as image drift or silently rewritten as a standalone figure.

The earlier local user-acceptance build SHA256 was
`fc0ca29bada6a8c4b450786dfc3d8a5db77ff3a6ca6206ddf1f9d0d0b082fe38`.
Strict local signature verification passed. Its final fullscreen capture has
367 frames, visible tab/toolbar transitions, unchanged window bounds and
(0, 0) body-registration shifts. Final narrow-window captures confirm the
native overflow control disappears and returns with the toolbar. Actual normal,
narrow and short FB2 and normal/narrow MOBI images are retained in
`visual-0.2.20/accept-*.png`; `user-acceptance-handoff.json` binds them to this
loaded build. The screenshot report is `visual-0.2.20/USER_ACCEPTANCE.md`.
The book is left open for personal acceptance. These are local, not distributed
signed-candidate, results.

The user requested personal acceptance and screenshots before any reply to the
issue reporter. No 0.2.20 publication or reporter reply has occurred. Signed
candidate acceptance and physical trackpad input remain distinct from the
local build, visual captures and hosted gesture-handler tests.

## FB2 whitespace revision after personal review

The user rejected the remaining FB2 title-page whitespace. The title measurement
had retained normal paragraph indentation/alignment and redundant default root,
paragraph and picture margins. It could also reserve a following chapter's
collapsed margin. The corrected measurement uses final title alignment, measures
caption space without the original image height, and reclaims only default-origin
title spacing. Explicit publisher/user margins remain authoritative, including
overrides with values equal to the default. The paginated title boundary keeps
authored paragraph margins separate; ordinary body layout and continuous flow
are unchanged. One inward float rounding step keeps an exact-fit author line
on the same page.

Native 17-point rendering of the original Alice FB2 at 560×720 increases image
height from 488.8 to 577.2 points (39.4% more area); at 1000×800 it increases from
589.2 to 657.2 points (24.4% more area). These are renderer measurements, not
window-screenshot pixel measurements. The title, author and complete artwork
remain together with the source aspect ratio. Width-limited title groups remain
centered. All 59 ordinary body pages across six viewports have identical text,
image bounds, Alice search results and search rectangles before and after.
The four original illustrations each occur once.

The final focused title suite passed 6/6 tests, including exact available-space
fitting, overflowing captions, explicit margins and default-equivalent overrides.
After the release-configuration app rebuild, the combined title, ebook image,
authored EPUB, viewport reflow, pinch and toolbar suites passed **57 tests with
zero failures in 40.91 seconds**. All 74 native patches replay cleanly across
44 touched source files and match the applied source. The earlier 1,262-test
gate was not rerun against this subsequent revision.

The rebuilt local 0.2.20 app was quit/relaunched and loaded the new engine from
`dist/Sumra.app` (PID 71443); strict deep signature verification passed. Executable
SHA256 is `83c9dc73901c8404486f85256c1327c62c5a8f0a0a17bf7647622334e0c5d4ba`,
bundled engine SHA256 is
`0c26235b9421a8d7c1529c6294b794d143342eaca824519fe02aa4e6cb0490b8`, and the
pre-bundle engine SHA256 is
`25d3fc0ca9b75458b11b7e7452888f3bce112886ff7e8e389d816a0c7d538e4d`.
Actual original-book screenshots were visually inspected at normal 1000×800,
narrow 560×720, short 1200×466 and fullscreen 2560×1440 sizes on the physical
M27Q display. Title, complete art and author fit in each. A physical-screen
hover comparison shows a changed toolbar region and identical pixels below
the top 64 pixels; this is an endpoint stability check, not animation-FPS proof.

Evidence is under `build/fb2-whitespace-20261026/`: `receipt.json`,
`affected-suite.log`, `patch-replay.log`, `gui-fb2-*.png`,
`screen-hover-comparison.json` and `USER_ACCEPTANCE.md`. These FB2 screenshots
supersede the earlier FB2 handoff images. The corrected FB2 is left open for
personal acceptance. No 0.2.20 release or reporter reply has been made.

## Candidate and source gate

The earlier `perf/reader-interaction-20261026` candidate at source revision
`30ceefe8` used host UUID
`EA687099-462B-32CD-9BED-9776B500B688`; the native engine UUID is
`BA514843-B483-30A2-A637-1D2FC21A0241`. Source native SHA256 is
`fc490aeef537c70cfdcad2c39d2eaebe2a0c51833fa78d500cc4c216d3373e65`. Packaging
changes the dylib signature/install name; UUID and packaging receipts bind the
source engine to the app. This is an ad-hoc local build, not a notarized
release. At that earlier checkpoint `/Applications/Sumra.app` was the official
0.2.18; the current installed version is recorded above.

The earlier composed CB6 source gate at
`build/perf-interaction-20261026/source-gate-final/source-gate.json` passed:
1,229 tests, 0 failures, 0 skips. That includes 5 Quick Look, 128 Core, and
1,096 app tests, plus packaging, localization, source parsing, and reader
JavaScript syntax checks. The explicitly manual
`FeedbackInteractionHarnessTests` suite was excluded and is not counted as
automated coverage. All 410 source inputs remained unchanged during the gate;
the receipt records its owned processes exited. This gate predates the current
toolbar and Find changes, so it does not validate those edits. The earlier
1,228 log-regex count missed one test line with a native prefix; the XCTest
suite totals establish the corrected count of 1,229. A later broad run at
`build/perf-interaction-20261026/source-gate-current/source-gate.json` attempted
1,232 tests and reported 1,231 passed, 1 failed. The failure was
`HighVolumeSearchTests.testHostedFullResultsPublicationAndReplacementRemainInteractive`:
the failing attempt used a 650-point fixture height. The source comparison
confirms that all 411 inputs match except this test fixture, and production
source is identical to restored CB6. The fixture was corrected to 672 points,
the intended height in current source, preserving the 779×590 search body.
Five focused tests then passed against reverted CB6; the
hosted high-volume check matched the established 100,144-result oracle with
search geometry unchanged before and after, completing in 24.98 s. These older
attempts are superseded by the passing combined gate below.

A later noncanonical source-gate attempt was interrupted after 132 passes and
one Quick Look assertion failed. The test required more than 100 sampled-ink
pixels, but the source-authored FB2 title page contains only 44 while visibly
rendering its title; the next page contains Chapter 1 and body text. The
assertion is now based on nonzero visible ink, with page, navigation, byte
preservation, and other oracles retained. This was not an alpha-channel or
product-rendering failure. Do not count the interrupted run as a pass.

## Native image and layout acceptance

The final engine passed 187 authored-break layouts, 666 inline-image layouts,
144 six-alignment public API cases, 16 actual generated-EPUB spread cases, 14
Alice-specific checks, and all 72 patch replays. The earlier reporter-book
results remain evidence for their named fixtures and layouts.

Evidence: `build/perf-interaction-20261026/native-images/ALIGNMENT-ACCEPTANCE.md`,
`aligned-summary.json`, and baseline/final geometry receipts.

Expanded fixtures found a pre-existing authored `break-before` defect: both
the prior candidate and installed engine ignored authored `div` breaks. The
canonical engine includes the direct two-line cursor fix. A separate leading-
margin defect was also exposed by an empty first page in a compressed FB2; the
fix distinguishes margin-only blocks from content, height, padding, or border.
The formerly failing input now has visible page-zero text. Evidence:
`build/perf-interaction-20261026/authored-breaks/README.md`, `receipt.json`, and
`leading-receipt.json`. These are distinct from the originally reported FB2/MOBI
illustration clipping.

Focused Swift checks passed (39 reader lifecycle and 3 Quick Look tests). The
final release source gate passed 1,238 tests with 0 failures and 0 skips; all
413 source inputs were unchanged, and engine SHA256
`e6b9d81c0cd6c98510c6080605627f2b38b131426cd8fa00ee22166e0bf7074f` matched
before and after. The manual interaction harness was excluded. The 25-book,
4,942-comic-page corpus passed. Evidence:
`build/perf-interaction-20261026/source-gate-release-final/source-gate.json`.
Earlier `source-gate-canonical` and `source-gate-final-combined` runs, including
the compressed-FB2 empty-page failure later fixed, remain historical.

## B10 native search comparison

On the 50 MB B10 EPUB, the native-library probe returned the same 25 ordered
matches before and after, with pixel parity for initial, enlarged-font, and
restored-font samples. Fresh-document search measured 5.265 s before and
5.240 s after. Warm same-document search measured 5.295 s before and 5.299 s
after. Cancellation returned the expected cancellation error, and the
post-cancel render remained usable. This is a small fresh-search change with
warm performance effectively unchanged, not a general search speedup. The
book's recorded hash did not change. Evidence:
`build/perf-interaction-20261026/final-B10-comparison.json` and
`final-B10.json`.

The dense-query native benchmark completed all 6,591 `女主` matches. Its
complete ordered match hash equals a forced glyph-search oracle; an independent
recovered-body count also found 6,591 exact occurrences. Native cancellation
and recovery were checked. See
`build/perf-interaction-20261026/native-benchmark/README.md` and
`summary.json`. The 133.5 s forced-glyph run validates the oracle; it is not the
normal candidate-path timing.

The accepted window-reuse optimization passed all three native suites and the
strong 6,591-result glyph oracle. Two paired runs reduced extraction calls from
4,904 to 4,052. On final engine e6b, the fast path completed in 11.960 s and
matched the full forced-glyph result order and geometry from the original 24c
oracle, including positions hash
`a6dc747a8f5f1a395326e7a1f75e35d0a13d3130bab96cc67f8505d8317244f2`; B10
bytes, hash, and mtime were unchanged. Cancellation preserved its
error cause, post-cancel rendering passed, and the worker exited. This native
timing is not mounted-reader GUI latency. Evidence:
`build/perf-interaction-20261026/window-search-reuse/combined-final-parity.json`
and `combined-final-fast.json`.

## Hosted search observations

On the CB6 host, sparse B10 GUI search returned all 25 results in 6.380 s,
with the first in 0.256 s. Dense `女主` returned all 6,591 results in 17.346 s,
with the first in 0.346 s. During the dense count, View menu access at 4,202
matches returned before 5,860 matches, about 1,204 ms for the combined tool
and AX round trip; this is not pure click latency. Search used font 17,
line-height 1.6, margin 32, and a 979×722 AX reader viewport. The earlier
native probe used 736×536 and line-height 1.4, so those timings are not directly
comparable. Native-owner profiling is ongoing; performance work is not complete.

Cancel/replacement passed: replacing `主` while it showed three searching
matches completed the new sparse query at 1/25. In that sparse 25-result
search, wrap navigation showed 25/25 at chapter 1465:1, then 1/25 at 1:1; this
was not the dense 6,591-result search. Evidence: `gui-sharedcookie-sparse*.json`,
`gui-sharedcookie-dense*.json`, `gui-sharedcookie-replace*.json`, and
`gui-sharedcookie-wrap-last*.json`; input timestamps and the menu round trip
are in `gui-sharedcookie-sparse-input.json`,
`gui-sharedcookie-dense-input.json`, and `gui-sharedcookie-dense-menu.json`.

Separately, the shared-cookie production probe reduced isolated full-count
Debug time from 19.390 s to 14.741 s (24%), with all 6,591 ordered matches
identical. This is not GUI wall time. Four regression tests passed. Five
focused Find regressions cover open/closed status geometry and queued reflow;
the footer stays stable across open/close and F3 search-session state. Evidence:
`shared-cookie-production.json`, `find-session-summary.json`, and
`find-status-summary.json`. The latest 0.2.19 Release host is built and loaded
with the final engine; its release source gate passed. Signed-release GUI validation is recorded in the final acceptance section.

A separate quiet dense-query measurement completed 6,591 results in 16.7045 s;
the 4 ms yield variant took 16.2341 s. The experiment was rejected because it
did not provide a meaningful, consistent full-query improvement. No 4 ms code
is retained. A native scalar experiment changed the count by only 0.8% and was
also rejected. No safe parallel cloned-EPUB path was found within upstream
ownership constraints. Dense-query optimization remains open; these
measurements do not support a universal latency promise.

The quiet GUI baseline on host 5ABD returned all 6,591 results in 17.701987 s
from input to final state (15.969 s from the first `Searching… 0` status).
The final-engine quiet GUI run took 16.921259 s from input to final state and
15.230922 s from `Searching… 0` to completion. This is one 4.4% input-to-final
improvement pair, not a universal performance claim. Dense-query wrap reached
6591/6591 at chapter 1470:67, then 1/6591 at 1:1. Replacing `主` during a count
with `女主天地合集` completed the new query at 1/25. Evidence:
`hover-acceptance/final-dense-baseline.json`,
`hover-acceptance/combined-dense-quiet.json`, `combined-dense-wrap*-ax.txt`, and
`combined-replace-before-ax.txt` / `combined-replace-after-ax.txt`. Native
window reuse is accepted for the tested oracle and suites; it does not establish
that all hosted search latency is solved.

## Alice visual review

On loaded QA host 5ABD with engine 24c, the supplied FB2 Alice book showed all
illustrations intact across seven normal pages and five fullscreen pages. After
loading final engine e6b, MOBI showed all four illustrations intact across nine
normal and seven fullscreen pages, with no empty trailing page. The contact
sheets were visually reviewed. The final native 14-case Alice checks cover both
formats, but do not relabel the earlier FB2 GUI captures as final-engine captures.
Evidence is under `build/perf-interaction-20261026/hover-acceptance/`
(`combined-alice-mobi-pages.json`,
`combined-alice-mobi-full-pages.json`, `final-alice-fb2-pages.json`,
`final-alice-fb2-full-pages.json`, and the corresponding contact sheets).

## Quick Look and Finder

The five Quick Look unit tests passed in the earlier source gate; they do not
establish Finder's thumbnail-provider selection.

Finder Space preview succeeded for all six tested formats through
`SumraPreview`; CBR advanced to page 2 of 11. The coverless EPUB's Space preview
shows its first page, but its Finder icon remains generic. A 0.2.19 candidate
temporarily installed at the exact `/Applications/Sumra.app` URL still routed
the coverless thumbnail request to `BooksThumbnail` and returned no thumbnail;
the covered control returned 340×512 through Books. A second combined test with
Sumra explicitly selected for all EPUB roles and its unique thumbnail extension
elected also routed requests to Books. Reload and historical discovery checks
retained this result. Provider selection remains unresolved, not a conditional
pass.

Both probes restored the official 0.2.18 app byte-for-byte, including symlinks;
only its official preview and thumbnail extensions remain registered, and
extension election is back to default. The current run restored all EPUB roles
to Books and removed its own persistent override. An earlier experiment began
with editor/shell roles unset, and their exact runtime restoration was not
established; do not claim that original nil state was restored. Evidence:
`build/perf-interaction-20261026/normal-install-probe/RESULT.json`,
`normal-install-elected-probe/COMBINED-RESULT.md`,
`normal-install-elected-probe/ROLE-CLEANUP-RESULT.md`, and the Finder images
under `normal-install-probe/`.

## Fullscreen and native window controls

The CB6 host passed physical-main-display fullscreen toolbar cold-hide, reveal,
retention, reversal, and native exit-action checks in Light. Dark motion also
passed: 341 decoded frames, 51 constant window-frame samples, and zero
body-position delta. The contact sheet shows an opaque black toolbar and no
residual bar when hidden. These receipts establish spatial continuity and
visible transitions, not app FPS. The purple macOS screen-sharing indicator
covers traffic-light pixels, so the evidence uses AX state and actual native
actions; it is not RGB proof of the button. Evidence:
`candidate-identity-sharedcookie.json`, `sharedcookie-dark-full-motion.mov` and
its JSON/analysis, and `sharedcookie-dark-full-contact.png`.

Always Hide showed no bar at the y=73 pointer position; Always Show kept the
bar while the body was visible; Escape from Presentation returned to normal
with the bar. Native toolbar customization removed Navigation and retained
reveal/hide behavior, then restored Open/Contents/Navigation ordering. Native
AX Minimize produced `minimized=true` and an empty onscreen-window list;
restore returned it to `false`. An initial CUA minimize attempt did nothing,
so the validated action used a native helper's explicit AXPress. Closing
removed the document window; Cmd-O opened another book. The sharing overlay
remains the limit on pixel-level traffic-light claims. Evidence includes
`sharedcookie-alwayshide-top.png`, `sharedcookie-alwaysshow-body.png`,
`sharedcookie-presentation.png`, `customized-no-navigation.json`,
`customized-restored.json`, `native-minimize-controls.json`,
`native-minimized-actual.json`, and `final-native-close-reopen.json`.

On loaded host 5ABD, Always Hide plus a top-edge hover exposed native Close and
Zoom while reader tools stayed absent. AX reported fullscreen, Close and Zoom
enabled, and Minimize present but disabled, as expected in fullscreen. A real
Zoom click exited fullscreen; Always Show was then restored. The screen-sharing
overlay obscures button pixels, so AX state and the actual action are the
evidence, not pixel proof. Receipts: `final-alwayshide-top-ax.txt` and
`final-alwayshide-controls.json`.

## Link-preview hover lifecycle

The latest reporter update describes a preview remaining open after pointer
departure and, in a two-page spread, two previews remaining open at once. The
reported stale blue-outline trigger is also specific: with Cover on Its Own
enabled, click blank space next to the cover; with it disabled, click blank
space in the same screen half as the cover. Blank comic space also triggers it.
After enlarging the window, the outline remains until the image itself is
clicked.

`sharedRasterSelections` now has one weak owner for the visible canvas; preview
dismissal follows actual pointer and key-window lifecycle. Six
`NativeLinkHoverLifecycleTests` and 10 existing related tests pass. Preliminary
ten-step pointer evidence on host `7693773E` used the earlier engine and remains
historical. On loaded host 5ABD with engine 24c, `physical-hover-final.json`
passed all 10 steps. The Swift host is the same as the final local host, but
this receipt is not a final-engine or signed-candidate observation. While a
preview was visible, a single click navigated from
1:1 to 3:1 without an extra click. Evidence:
`build/perf-interaction-20261026/hover-acceptance/`
(`lifecycle-final.log`, `physical-hover-final.json`, and
`final-link-click-ax.txt`).

On the main physical display, cover-on blank-click/enlarge plus keyboard Right
to 2:1 and Left to 1:1 passed. Cover-off was also tested by clicking the actual
left blank region (x=20, bitmap y=800), enlarging from 1200×840 to 1400×900, and
checking keyboard navigation. Comic blank-click/enlarge and keyboard navigation
2/11 to 1/11 also passed. The contact sheets were reviewed and show no residual
outline. Evidence includes `final-cover-on-blank.png`,
`final-cover-off-physical-blank.png`, `final-cover-off-physical-enlarged.png`,
`final-comic-blank.png`, and `final-comic-enlarged.png`. Earlier off-mode input
before moving the window is superseded by this physical-display run.

## Coverage boundaries

- Inline-image evidence includes the reported FB2/MOBI Alice books and layout
  cases; it does not stand for every real-world ebook or image.
- The reporter's cover-adjacent and comic blank-space resize trigger is
  recorded above, alongside captures of the originally affected pages.
- Toolbar checks cover physical cold entry, actual rendered transitions,
  window/body geometry, the common toolbar modes, and customization. The
  sharing indicator blocks direct pixel proof of traffic-light buttons, and
  recordings do not measure app frame rate.
- Quick Look unit tests and bitmap generation cannot establish Finder's
  provider choice. The normal-install, default-app, and extension-election
  probes all show Books retaining EPUB thumbnails despite working SumraPreview.
- Earlier native search probes used different viewport and styling settings
  from the mounted reader. The latest native oracle and hosted run used matching
  979×722 reader geometry. Exact native matching is an oracle; it does not
  replace GUI responsiveness checks.

Native image checks, Alice pages, six-format Finder previews, fullscreen and
window-control checks, physical cover/comic blank-area checks, final link-hover
actions, and the passing 1,238-test release gate are complete at their stated
boundaries. An earlier broad gate failed on a high-volume fixture mismatch; a
later gate found the compressed-FB2 empty-first-page case that is now fixed.
The signed release-candidate GUI pass is complete for the issue bug-fix scope. One tested dense GUI run
improved 4.4% over its baseline; this does not establish a broad performance
gain, and timings remain about 15–17 seconds for 6,591 results on this machine.
EPUB thumbnail-provider selection and exact restoration of the earlier unset
editor/shell roles remain unresolved. Publication and reporter reply are recorded separately below.

## Signed candidate acceptance

The exact app and extension checks use host/engine identities in the opening
status. Original sample image sequences, live AZW3 links, focus resizing,
physical hover handoffs, toolbar motion and Finder previews were re-exercised.
The `signed-search-lorem-ax.txt` smoke check counts all 24 matches and the
previous-result action moves to the prior chapter. Full dense-result and
replacement-query coverage retains the earlier source-matched evidence above.

The initial AZW3 suspicion was falsified: its first page is a raster image that
looks like a TOC; the actual live TOC is on the following page. Baseline 0.2.18
and the candidate agree across four viewports. `signed-azw3-live-links.json`
records all eight genuine links; the superseded false-positive receipt is
retained rather than counted as a failure or hidden.

Finder initially displayed only CBR metadata while temporary registration was
incomplete. After normal Launch Services and extension registration, the exact
candidate preview process loaded and rendered all six original file extensions.
The accepted evidence is `signed-finder-contact.png` and
`signed-finder-providers.txt`; the registration transition is not counted as
successful preview evidence. Native fullscreen Close/Zoom are available on
top-edge reveal; macOS disables Minimize there, and clicking Zoom exited.

Runtime acceptance is on macOS 27.0.1 arm64. No application FPS claim is made
from screen-capture frame rate. The screen-sharing badge can cover the native
traffic-light pixels; their accessibility state and actual action were tested.

## Publication and installation

[Publication workflow](https://github.com/Ares-X/Sumra/actions/runs/40301775455)
succeeded and published the accepted bytes as
[0.2.19](https://github.com/Ares-X/Sumra/releases/tag/v0.2.19), retaining draft
release ID 424019797 and all six asset IDs. Accepted manifest SHA256:
`7784e21cb02dc059db7f38f70481925b5a2f8960ae5ca9b6421f3716e50d239e`.
The workflow updated the feed without rebuilding the application.

The real installed 0.2.18 updater was invoked and showed a retrieval error.
Unified logs identify a TLS error. The initial claim that port 8089 had no
listener was wrong: unprivileged `lsof` had no result, but TCP connected,
HTTP CONNECT returned 200, and netstat attributed the listener to Clash's
`verge-mihomo` PID 2289. Both HTTP and SOCKS proxy feed requests reproduced a
TLS close; direct IPv4 returned HTTP 200 with bytes identical to the accepted
appcast. A subsequent Clash log identified the Github group's upstream
connection timeout for the update host. No proxy setting was changed by the
test. This initial automatic-update attempt failed.

The exact published application was installed manually at `/Applications/Sumra.app`.
All 140 files, five symlinks, modes, certificate and extension signatures match
accepted provenance. Installed version 0.2.19 (21) was launched from that path
and opened the original Alice FB2 on the physical display. The previous app is
preserved locally. `manual-install.json`, `staged-official-identity.json`,
`official-update-acceptance.json`, and `network-route-check.json` retain the
installation and failed-updater evidence separately.

After the user reported that Clash had recovered, the installed 0.2.19
successfully checked the feed and reported that it was current. The preserved
official 0.2.18 was then temporarily installed at `/Applications/Sumra.app` for
the complete upgrade test. Its Help → Check for Updates action offered 0.2.19;
Install Update downloaded the archive, and Install and Relaunch installed and
launched 0.2.19 (21) from the same path. All 140 files, five symlinks, 91
directories and recorded modes match the published provenance; deep, strict
signature verification passed. Both Quick Look extensions registered the new
version at the official app path, and the relaunched app opened the original
Alice FB2. No proxy configuration was changed. Evidence:
`build/perf-followup-20261026/official-update-recovered.json`,
`restored-proxy-feed.json`, `updater-offer-ax.txt`, and
`updater-download-progress-ax.txt`. This successful retry supplements the
retained failed attempt; it is an observed Sparkle installation, not a manual
copy counted as an update.

Anonymous public verification completed for all six assets, including the full
application and corresponding-source archive. IDs, sizes and SHA256 hashes
match the accepted candidate; raw-main appcast bytes match, and the Ed25519
update signature verifies. Initial transport failures and recovered ranges
remain documented separately; the final receipt is
`build/release-0.2.19/public-verification-direct/public-ranges-check.json`.

The [reporter reply](https://github.com/Ares-X/Sumra/issues/42#issuecomment-6413187666)
was posted after publication, installed-app loading and public verification.
It describes the fixes and overlay behavior, explicitly leaves coverless EPUB
thumbnail selection and dense-search speed unresolved, and asks for everyday
book testing and remaining rough edges. Issue #42 remains open.
