# Feedback traceability — 2026-10-25

Latest original-feedback recheck: [ORIGINAL_FEEDBACK_RECHECK_20261025.md](ORIGINAL_FEEDBACK_RECHECK_20261025.md). Current host is `7BD95D07-CE05-3822-9AE2-F7D5C6DFDCC4`; it fixes short-screen hover-preview containment. The 33-original / 175 third-round / 48 fourth-round layout matrix has now been replayed against current build inputs and the current packaged engine, with 81 focused checks and actual Virtual-display link acceptance. E316 and older observations below retain their historical attribution.

## Current follow-up (supersedes the earlier “final” labels below)

The earlier optimized GUI/Finder pass is a historical 4397-engine pass, not
the later R5 manual/watchdog attempt. Current unsigned native candidate SHA is
`baf8d6a7fc64c8651c57fa93952e7ac52fb2eca9d2b71ff80d582c464add4a72`; its
MuPDF engine UUID is `E002E933-FFBC-3EFA-9511-CA1BF15C4409` (not the app host
UUID). The current final local Release host UUID is
`E31645C1-9D48-37D1-AEEE-D0194363E220`; packaged engine SHA-256 remains
`a31614b885aad81d31013cd075e48a5ce458929dbd216d4601784b20853f58d7`.
The E316 Release build passed in 56.935 s; deep/strict codesign passed and 409
input hashes stayed stable (`refined-motion-clean-release-build.json`).
`toolbar-overlay-final-engine-binding.json` confirms the current engine's
`baf8` section hash and every `__TEXT` section match. The 7CEA host is the
previous accepted pre-polish snapshot; the older 96420814 host predates it.
Final original preservation is 71/71. The earlier cleanup attempt stopped at
an unregistered path before moving anything; the later definitive cleanup
receipt below supersedes that attempt. The corrected queued-query regression passed in
23.86 s (`search-repair-final-test.json`); the 27 focused passes were reused,
and packaging's 58 checks plus 11 declarations passed in 4.30 s. Release-hosted
100k search on the E316 Release passed: 100,144/100,144 results in 15.45364 s,
complete at 15.89674 s, Main pulse max 59.688 ms (one over 50 ms, none over
100 ms); last target 100,144/100,144 painted on page 10,224. Cancellation,
reading during count and replacement passed. Receipts:
`refined-release-high-volume-search.json` and
`third-pass-publication/refined-release-publication.json`. The prior 7CEA
16.31163 s result is a no-regression baseline, not evidence of a universal gain.
This hosted result is separate from the 25-hit native B10 timing below. The current candidate's
independent third-pass receipt
(`build/issue42/third-pass-performance/README.md` and
`final-uncapped-parity.json`) reports 19/19 full ordered JSON and geometry
parity. Five-book current comparisons: B10 12.062→6.010 s (warm 6.025; 25
matches), B03 6.772→1.320 s (387), B22 1.755→1.215 s (1). Large Markdown
bulk remains 3.717 s; first precise result 11.901 ms, real no-hit 3.814 s,
maximum step 18.732 ms, cancellation 1.375 μs. There is no stronger Han-LTR
total-count gain. The earlier 81.399→12.062 s and its 4397 package binding are
retained as historical measurements, not current-candidate claims.

The 7CEA overlay is the accepted pre-polish snapshot. Current E316 motion is
shared through `ReaderMotion.swift`: 180 ms cubic `(0.16,1,0.3,1)` reveal, 140 ms
hover-exit grace, then 120 ms outro; reentry reverses current opacity without
remounting. Root geometry remains stable. Persistent `toolbarOverlaysContent`
spans full-size/titlebar/root and RasterReaderGeometryReader safe area without
reflow. Public macOS 15 `.toolbar(removing: .title)` plus hidden toolbar
background on transient overlays removes the one-frame filename/gray flash in
retained 4D8 (`retained-refined-toolbar-motion.mov`, peak gray 48.419); E316 peak
is 6.617 with no filename or backplate. The zone remains 48/96 pt in stable
parent-window coordinates, no `contentLayoutRect` feedback. Thirteen
`ReaderToolbarTests` and four `PanelMotion` tests pass (17 unique focused tests):
`refined-motion-clean-tests.log` and `refined-motion-reduced-tests.log` plus
`toolbar-overlay-viewport-tests.json/.log`. Reset/detach publishing warning is
fixed; the latest run is warning-free.

On Virtual 16:9 display 8, window/fullscreen/presentation reveal inside 40 pt,
retain at 60/90 pt, advance 1:1→2:1→3:1→4:1, then hide; exact window and
scroll-area frames are preserved. Receipts:
`gui-observed/refined-clean-inside40-{window,fullscreen,presentation}-acceptance.json`
and `refined-clean-toolbar-viewport-frames.json`. The focused motion video and
analysis (`refined-clean-toolbar-motion.mov`) have 543 frames/9.983 s, body
registration 0, 21 partial-contrast frames, two visible cycles including quick
return/fade interruption, and 60 native frame bounds unchanged. Capture median
16.667 ms/max 183.333 ms is not an app 60 fps claim. Older 7CEA motion evidence
remains accepted at its boundary; `motion60` and nonfocused videos remain
incomplete. The prior C3 AX/CG-click pass stays withdrawn because its pixels
showed an invisible toolbar; raw evidence and failures remain historical.

PanelSettings and selection use native 180/120 ms alpha animation with
cancellation revision. Selection is nonactivating, ignores mouse while fading,
uses light press/hover wash, and keeps root sidebar/inline-find content in
settled layout while changing opacity only. Reduce Motion true-path is covered
without changing global settings. Settings close/reopen was 70.8 ms, same native
window 184311, alpha 1 and frame unchanged (162 alpha samples/13 partial;
`refined-clean-settings-motion.json`). Selection drag required background
activation as expected for native first mouse; real hover/press, outside cancel,
unchanged clipboard and panel persistence pass (`refined-clean-selection-motion.json`
and alpha samples).

The 7CEA native Close/open, FullScreen entry and minimize/restore AX actions
remain accepted at their prior boundary. E316 also observed all three macOS-owned
native buttons windowed; no additional action result is inferred. Direct
green-button exit is untested. Fullscreen control availability remains macOS
owned. The purple `WindowSharingSessionButton` was capture UI at the old
selection, not a new-window control. No custom button/private API was added.
macOS 13 source compilation passes, but `.visible` requires macOS 15; older
runtime and the main notched display after moving to Virtual 16:9 remain
untested.

Finder smoke after correct HOST registration and fresh file typing passed:
actual AZW3 preview nonblank; CBR Quick Look advanced 1/11→2/11
(`finder-acceptance/search-final-smoke/actual-smoke-restored.json`). Official
host and both app extensions are restored only under `/Applications`; task
staging baseline and candidate registrations are unregistered
(`restore-official.json`). The official installation was not replaced by the
local candidate. The earlier cleanup attempt stopped at an unregistered path
before moving anything; the later `refined-motion-cleanup.json` receipt below
confirms completed recoverable cleanup. All GUI checks used Virtual display 8
and left other user windows untouched. Amicro skill source is pinned at
`dc2a183…`; Skills CLI and shadcn CLI are independently versioned.
The unrelated `@subhanhq/amicro@1.0.1` has no executable and was not installed;
Sumra dependencies are unchanged.

## Final closure receipts

`build/issue42/refined-motion-final-acceptance.json` passes. Current engine
binding passes at `build/issue42/third-pass-performance/refined-final-engine-binding.json`;
409 source-input hashes were unchanged after build. Fullscreen Light passed
physical 4:1→5:1 in `gui-observed/refined-clean-light-fullscreen-acceptance.json`.
Focused light and dark motion videos are `refined-clean-light-toolbar-motion.mov`
and `refined-clean-toolbar-motion.mov`; each analysis has 543 frames/9.983 s,
body registration [0,0] at 1 pt, 21 partial-contrast frames, and 61/60 unchanged
native frame bounds, respectively. Light gray baseline was 254, minimum 246.639;
neither video contains a filename/gray flash. Capture maxima are 233.334 ms light
and 183.333 ms dark; app FPS was not measured. The 6 s H.264 demo
`gui-observed/refined-motion-demo.mp4` is cropped/resized from the actual dark
recording (88 KB); no FPS claim.

CUA acceptance: Light sidebar open/close preserved Value On/Off and Chapter 3;
Cmd+F, paste Lorem, Enter produced 24 exact matches, current 8/24, and closing
Find restored reader focus. The transcript is the evidence; no separate PNG is
claimed. Selection press/cancel evidence is in `refined-clean-selection-motion.json`.

Cleanup passed (`refined-motion-cleanup.json`): QA process 89803 normal-quit
terminated; no task-local commands remain. Nine old bundles (305,285,659 bytes)
were moved recoverably to `/Users/aresx/.Trash/Sumra-motion-intermediates-20261025-215832`;
compiled native helpers went there too, while source, receipts and videos remain.
Current `dist/Sumra.app` and `gui-candidate/SumraQA.app` are kept for review and
are not installed as the official app. QA registration exited 0; only
`/Applications/Sumra.app/Contents/PlugIns/{SumraPreview,SumraThumbnail}.appex`
are registered. Both current apps passed deep/strict signature verification
after GUI. Other Orca windows, ports and user windows were untouched. The earlier
cleanup failure moved nothing; this later receipt is definitive.

All current GUI ran on Virtual 16:9 display 8. No hidden-startup guarantee is
claimed: the first-hit flow did not require an unhide when the app was already
visible, and startup behavior is not established. The initial main-screen
relocation was corrected; no rerun was made on the notched display after moving
to Virtual. The direct green-button fullscreen exit and runtime on macOS before
15 remain untested. No remote operations were performed; official 0.2.17 was
not replaced. The final Git diff check passed.

Physical input is now accepted at the R6 boundary: `build/issue42/feedback-harness-host/RUN6_ACCEPTANCE.md`,
`run6-acceptance.json` and `interaction-run6-final.json` document real-reader
`NSApp`, production Colors dialog, actual `CGEvent` pointer entry/hand cursor,
6.36984 s dwell, preview-visible down, key Canvas, exactly one down/up,
destination painted and preview closed with zero rejected events. Independent
`NSColorPanel` wheel and RGB-slider changes were observed for all three wells;
opacity also changed, routing/synchronized values were correct, and Apply
produced text `009062`, background `FFFF34`, link `CB20A0`. Host exit was 0,
manual test passed (54.383 s). The tooltip-owner lifetime defect found in this
run is fixed; the earlier run-4 crash and run-5 watchdog timeout remain failed
historical runs. Current toolbar and Finder state is summarized above and
tracked in rows 42-T1/T2 below.

The historical broad source-gate receipt is `build/issue42/search-final-source-gate.json`;
it ran 1,214 tests (128 Core, 1,081 app, five Quick Look) with one manual skip
and two old Markdown reflow-cancellation assertions failing. Both original
cases now pass after canceling the old find/count before reflow and resuming its
intent after committed layout (`reflow-repair-checks.json`). The 28-test
closure log includes one impossible timing assertion; the corrected test now
checks the real reader-state command-queue contract. Do not label the 1,214
gate clean. Both original Markdown scenarios were repaired and pass the later
focused checks; this does not rewrite the historical broad-gate receipt. The
corrected queued-query regression and packaging receipts are listed above.
Release-hosted 100k search and virtual-display toolbar viewport
acceptance passed; direct green-button exit and main notched-display rerun
remain untested.

Read directly through the GitHub connector: [issue 42](https://github.com/Ares-X/Sumra/issues/42), its one comment, [issue 31](https://github.com/Ares-X/Sumra/issues/31), and all ten comments. No issue/comment was changed by this audit.

Issue 31 is **closed / completed**. The [reporter's final comment](https://github.com/Ares-X/Sumra/issues/31#issuecomment-6393056920) accepts 0.2.17's EPUB results and moves the remaining findings to issue 42. Older acceptance records saying issue 31 remains open describe their historical snapshot. Issue 42 remains open; its existing reply addresses video permission/tips, not technical completion.

## Final evidence and its boundaries

- **Historical optimized GUI/Finder candidate:** host UUID `B934E3D1-3033-398E-96B6-3BB2DF20603A`, packaged MuPDF SHA-256 `4397fb642fd670cc601c20503cbc7e73304177395f6394d743a9ffc4b3fc874d`. Its isolated QA clone and actual Finder pass are bound to that snapshot. It is not the later R5 manual/watchdog attempt, nor the current Release candidate.
- **S — final source gate:** `build/issue42/optimized-final-checks.json`, `optimized-source-checks.log`: **1,200 Swift tests = 128 Core + 1,067 app + five Quick Look, zero failures/skips**; 58 packaging checks and 11 shared content types. All optional corpus, comic-page, original issue-42, generated-image, cold-comic and four primary PDF-interoperability inputs were enabled. The 396 checked source inputs did not change during build/checks. Deep/strict signing verification passed after GUI/Finder work.
- **G — final actual GUI:** `build/issue42/optimized-gui-acceptance.json`; captures under `build/issue42/gui-observed/optimized-*`. The visible workflows below are attributed to this receipt. Actual input and observed output are distinct from component assertions.
- **F — final actual Finder:** `build/issue42/finder-acceptance/optimized-actual-finder-pass.json`, `optimized-preview-AX.json`, `evidence/optimized-*`. Original six suffixes retained. Actual preview/thumbnail processes were observed at `dist/Sumra.app/Contents/PlugIns/`. After acceptance, both registered extension paths were verified restored to `/Applications/Sumra.app/Contents/PlugIns/`; the official 0.2.17 installation remains separate from this local candidate.
- **N — final packaged native layout/performance:** `build/issue42/second-pass-performance/final-packaged-engine-binding.json`, `OPTIMIZED_ACCEPTANCE.md`, `build/issue42/optimized-final-epub-replay.log` and `optimized-final-*` geometry receipts. Measured optimized native code matches every named packaged `__TEXT` section. All 33 retained EPUB entries, 175 third-round geometry checks, eight fourth-round books / 48 paged layouts and preservation of all 67 inventoried inputs pass.
- **Historical C1:** prior isolated UUID `ABEABF7A-1875-32E5-9DB0-D247524F74F0`, engine `6b130bed0bf5ed66afa46bc0a73199360fb4604cac6fc7c59fb52c1c531ecfb8`. Its earlier `gui-observed/final-*` screenshots and first 1,197-test source gate remain historical evidence. The newer modal document-owner repair and optimized search are validated by S/G/N, not retroactively attributed to C1.

R6 supersedes the earlier physical-hover and independent Colors-panel gaps for the stated reader-host boundary. The current overlay update passes the Virtual 16:9 window/fullscreen/presentation pixel and viewport checks; prior C3 AX/CG-click “pass” remains withdrawn because its retained pixels showed the toolbar invisible. Native Close/open, FullScreen entry, and minimize/restore actions now pass at the documented AX boundary; direct green-button exit is untested. Earlier optimized GUI/Finder observations remain the historical 4397-engine pass; the distinct R5 manual/watchdog attempt did not pass.

Paths below are repository-relative. See [FULL_ACCEPTANCE_20261025.md](FULL_ACCEPTANCE_20261025.md) for the full corpus/performance matrix. Failed/interrupted logs remain evidence of their own runs, not passing receipts.

## Issue 42 — every technical finding

| ID / feedback | Actual owner and focused behavior evidence | Final observed result / honest limit |
| --- | --- | --- |
| 42-L1 Hover preview must allow the first click to follow a link | `Pages.swift`, `RasterCanvas.Canvas.mouseEntered/closePreview/followLink`: passive nonactivating child panel. `NativeLinkInteractionTests.testHoverImagePreservesReaderFocusAndFirstClickFollowsEbookLinkWithoutMarker` sends native down/up with preview open. | R6 physical run observed pointer entry, 6.36984 s preview dwell, preview-visible click down, exactly one down/up, destination paint and preview closure with zero rejected events. The 4397 GUI's AZW3 Chapter 8 click remains historical additional evidence. |
| 42-L2 Hover must preserve cursor/link focus | Same owner/test asserts reader first responder, unchanged key window, mouse-event passthrough and non-key preview; `resetCursorRects` owns link cursor. | R6 observed the displayed hand cursor and key Canvas during the actual pointer-entry/preview interaction. It records the same physical input sequence and no rejected events. |
| 42-L3 Remove ebook blue destination circle | `Pages.swift` calls `showLinkDestination` only for PDF; link test requires nil ebook hint. | G's Chapter-8 destination has no ebook blue ring. PDF's existing destination indicator intentionally retains its behavior. |
| 42-L4 AZW3 links do nothing | `LegacyText.swift` KF8 reconstruction/navigation and shared `MobiMaterialization.swift` EPUB spine. Original-sample test checks all 16 live TOC links, destinations and hosted mode/resize source retention. | G: first numbered TOC single-clicks to Chapter 8; final unnumbered TOC observed (`optimized-azw3-first-toc.png`, `optimized-azw3-chapter8.png`, `optimized-azw3-final-toc.png`). The initial raster TOC cover is not a live text TOC. Back command occurred; final intermediate return was not captured. |
| 42-L5 Stray AZW3 CSS on last page | `LegacyText.swift` separates flows; materializer preserves per-part head/body/CSS. Original test checks every page's text; `NativeKF8FlowTests` protects style isolation and SVG resources. | G final TOC has no stray CSS and retains its unnumbered style while the first TOC retains numbers. |
| 42-L6 Clipped/repeated next-page art outside EPUB/PDF | Existing MuPDF HTML image-layout owner and `Pages.swift`; `NativeEbookImageLayoutTests` covers real MOBI/FB2, prose/caption boundaries, logo sizing, occurrence/containment and painted edges; native image-link tests protect top destinations. | G generated MOBI continuous link lands at red top with all borders/caption; FB2 paged art retains all borders/caption (`optimized-mobi-image-link.png`, `optimized-fb2-image.png`). Reporter samples have no body art; these generated inputs remain distinguished. |
| 42-T1 Optional top-area toolbar hover | SwiftUI is the visibility owner; `.windowToolbarFullScreenVisibility(.visible)` removes the second native hover gate. Thirteen `ReaderToolbarTests` plus four `PanelMotion` tests pass. | E316 Virtual 16:9 window/fullscreen/presentation pixel and viewport UAT passes; C3 AX/CG-click receipt remains withdrawn. Native controls are macOS-owned; direct green-button exit and the post-move notched display remain untested. |
| 42-T2 Reclaim hidden-toolbar space, then make room on reveal | Persistent `toolbarOverlaysContent`, full-size/titlebar/root and RasterReaderGeometryReader safe area preserve layout; zones 48/96 pt in stable parent coordinates, no `contentLayoutRect` feedback. Reveal/outro timing is 180/120 ms with a 140 ms hover grace; reentry reverses opacity without remount. | E316 display 8 preserves exact window/scroll-area frames in window/fullscreen/presentation. Focused video has 543 frames/9.983 s, two visible cycles and unchanged native frame bounds; capture max 183.333 ms does not establish 60 fps. |
| 42-T3 Windowed Light/Dark grey stripe | Same chrome owner and theme palette; toolbar preset geometry and native page/tile-margin tests. | G: both `optimized-light-hidden-window.png` and `optimized-dark-hidden-window.png` show themed reclaimed space. |
| 42-T4 Full-screen Light/Dark grey stripe | Same owner; full-screen notifications reset transient reveal state. | G: both `optimized-light-hidden-fullscreen.png` and `optimized-dark-hidden-fullscreen.png`, then window return. |
| 42-T5 Presentation stripe | `ReaderState.toolbarShown`, chrome bridge and `ReaderView` share hidden layout; presentation visibility test. | G: `optimized-light-presentation.png`, `optimized-dark-presentation.png`, and return to window. This is actual presentation evidence, separately from full screen. |
| 42-F1 Stubby lower-left CBZ thumbnail | `ThumbnailProvider.draw` uses AppKit points; `PreviewLayoutTests.testThumbnailDrawingFillsPointBoundsAtBothDisplayScales` checks 1×/2× drawing, aspect preserved. | F actual Retina Finder shows full centered CBZ cover, compared with official stubby baseline. Separate 1×/2× source tests do not claim two physical display-scale observations. CBZ Space preview is also nonblank. |
| 42-F2 CBR thumbnail missing | Shared `scripts/bundle.swift` registrations and `QuickLookBook` archive decoder; original six-format test without renaming and packaging checks. | F actual original `.cbr` shows full centered cover. |
| 42-F3 CBR Quick Look missing | Same owners plus `PreviewViewController`. | F actual `.cbr` Space preview is nonblank and Next reaches **2/11**, retained in `optimized-preview-AX.json`. Official missing-preview baseline remains under `evidence/official-cbr-no-preview.png`. |
| 42-F4 MOBI thumbnail/Quick Look missing | `QuickLookDocument` and shared Core materializer; original six-format rendering/navigation and registration tests. | F actual `.mobi` generated thumbnail and nonblank Space preview/navigation controls, without rename. |
| 42-F5 FB2 thumbnail/Quick Look missing | Native FB2 route in `QuickLookDocument`; same original-file tests/registrations. | F actual `.fb2` generated thumbnail and nonblank Space preview/navigation controls, without rename. |
| 42-F6 AZW3 thumbnail exists but preview is absent/blank | Shared KF8 materializer/native EPUB spine; original-file test requires nonempty paint and next/back. | F actual `.azw3` generated thumbnail and nonblank Space preview/navigation controls, original suffix retained. |
| 42-F7 Preserve working no-cover EPUB behavior | Existing EPUB route; supplied no-cover original, SVG/spine and Retina tests. | F original EPUB Space preview is nonblank with controls. Its Finder icon remains **Books' generic icon**, as expected for this no-cover input on this machine; it is not falsely described as a generated cover thumbnail. |

The [issue-42 reply](https://github.com/Ares-X/Sumra/issues/42#issuecomment-6393716089) already grants video permission and discusses a possible tip mechanism. This patch adds no payment feature.

## Issue 31 — body and every later feedback round

Reporter confirmations remain attributed to their versions. Historical signed/release GUI, final packaged native checks and current final GUI are distinguished below.

| ID / feedback and provenance | Actual owner and focused behavior evidence | Release / final observation and limits |
| --- | --- | --- |
| 31-A1 Pure-white Light theme | `ReaderTheme.builtins`, palette CSS; theme and native-background tests. | Reporter confirms in [6374880582](https://github.com/Ares-X/Sumra/issues/31#issuecomment-6374880582); G observes final Light/Dark window/full-screen/presentation palette. |
| 31-A2 Theme/Custom Colors dialogs must open and respond | `ReaderAids.chooseTheme/configureDocumentColors`, `ReaderThemeAlert`/editor; clickable-theme and native-color-well tests. | Reporter confirms dialogs, then picker in [6383242166](https://github.com/Ares-X/Sumra/issues/31#issuecomment-6383242166). G's dialog observations are historical additional evidence. R6 independently manipulated the production system panel's wheel and RGB sliders and opacity for all three wells; Apply routed Text `009062`, Background `FFFF34`, Link `CB20A0`. |
| 31-A3 Choose installed Iowan Old Style | `ReaderReadingSettings` / `ReaderFontNamePicker`, installed/Supplemental inventory and native font owner; live font-picker and native Iowan reflow/vector-export tests. | G physically pastes/commits per-book Iowan and observes it after panel reopen (`optimized-iowan-committed.png`, `optimized-iowan-reading-settings.png`). Reporter previously confirmed the picker in 6374880582. |
| 31-A4 Global Default Typography accepts typing and reflects saved global font | Shared settings font picker; `testDefaultTypographyReflectsSavedFontAndOffersInstalledSupplementalFamilies`; global → format → per-book precedence remains authoritative. | Requested in [6380926771](https://github.com/Ares-X/Sumra/issues/31#issuecomment-6380926771), explained in [6381979829](https://github.com/Ares-X/Sumra/issues/31#issuecomment-6381979829), confirmed in 6383242166. G physically pastes/commits global Iowan and observes persisted reopened value (`optimized-global-iowan-reopened.png`). |
| 31-N1 Rapid bare arrows halt/beep | Reader local event/navigation owner; repeated-arrow/focus-replacement and editable-control routing tests. Second-pass FB2 queues eight forward/three backward turns then reflows the selected source. | G actual eight Right plus three Left from home reaches expected **Chapter 4** (`optimized-rapid-arrows.png`). Reporter had also confirmed responsive arrows in 6374880582. |
| 31-C1 Cross-app color focus resets to white/85% | `ReaderThemeAlert`, `ReaderThemeColorWell`, exclusive panel target; dialog-focus and exclusive-well tests. | G app-switch RGB/alpha observation is historical. R6 independently exercised the real panel's wheel, RGB sliders and opacity for all three wells and confirmed routed/synchronized values, including Text `009062`, Background `FFFF34`, Link `CB20A0`. Prior physical official evidence remains additional history. |
| 31-C2 Literal headings select white/85% | Same owner; real alert-heading/RGB/name behavior covered by appearance tests. | G both custom-color and custom-theme heading focus preserves RGB/alpha 1 (`optimized-custom-colors-app-switch.png`, `optimized-custom-theme-heading.png`). |
| 31-C3 Picker disconnects or switches wrong target | Same exclusive-well owner and `testColorPanelSwitchesExclusiveWellsWithoutChangingOtherInputs`. | Reporter confirms no disconnect in 6380926771; historical physical six-target switches remain additional evidence. R6 independently exercised all three panel wells with correct routing and synchronized values. |
| 31-C4 Apply closes picker; Cancel/Use Theme preserve semantics | `configureDocumentColors` and `closeColorPanel`; appearance and `SecondPassReaderWorkflowTests` check normal owner Apply/Cancel/Use Theme and closure. | G's Link **AABBCC** Apply/reopen and Cancel/Use Theme results are historical. R6 Apply on the production panel closed/applied with Text `009062`, Background `FFFF34`, Link `CB20A0`; its independent wheel/sliders/opacity interaction is recorded in the R6 receipts. |
| 31-C5 Custom Colors needs link color and preview parity | Shared three-color editor/RGB/live preview; persistence, preview and validation tests. | Delivered in [6375733582](https://github.com/Ares-X/Sumra/issues/31#issuecomment-6375733582). G final Link edit/reopen works; historical physical preview and S retain their own evidence. |
| 31-C6 New modal replacement-owner failure | `configureDocumentColors` captures document ID before modal loop and checks it after closing the panel; replacement-owner test preserves replacement colors/queue. | S includes the repair and passing replacement tests. G is bound to that code and verifies normal color workflows. **Replacement during the modal loop remains a source-test assertion**, not a claimed physical workflow. |
| 31-G1 Initial stretched single/facing cover | Native SVG aspect/EPUB cover layout; `EPUBCoverAspectTests` full-page SVG and declared-cover wrapper tests. | Shipping 0.2.17 accepted by reporter; N repeats all 33 original entries using final packaged engine. |
| 31-G2 Round 1 A/B/C/J blank/repeated edges, caption separation; D stretch; E–J tiny/padded/nonresponsive covers | Existing native cover/image owner; caption keep-together, author dimensions, occurrence and painted-bound tests. | Ten originals retained; N final native sweep passes. Historical signed/installed GUI remains attributed to [fourth-round record](ISSUE31_FOURTH_ROUND_ACCEPTANCE_20261024.md), rather than claiming all ten were physically re-viewed now. |
| 31-G3 Round 2 title-overlay alignment and full-width Cover on Its Own before two-page text | Native layout and cover identity; actual reader CSS composition/cover/facing controls tests. | Ten originals retained; N passes, historical signed full-screen/mode receipts in [third](ISSUE31_THIRD_ROUND_ACCEPTANCE_20261024.md)/fourth records. Current pass does not claim a new physical own-cover on/off matrix. |
| 31-G4 Round 3 A/B ornament/title alignment; C tiny publisher logo | Native block/inline centering and cover identity; authored-logo/dimension controls. | N passes **175 third-round geometry checks**. Historical signed GUI separately observes centered decoration and small logo; final release author confirmation retained. |
| 31-G5 Round 3 D repeated lower art; repeated round-2 C art growth/centering | Native pagination/independent-art fit; source-placement and painted-image regressions. | N retains third/fourth repeated controls; historical signed full-screen/mode GUI remains its own evidence. |
| 31-G6 Round 4 A–E small art after cover, growth then shrink; repeat placement | Native viewport/percentage/maxima/responsive-frame owner; authored-art growth/return and maxima tests. | N **eight books / 48 paged layouts** plus retained continuous/return checks. Actual signed/installed 0.2.17 observations and reporter acceptance remain attributed to that release. |
| 31-G7 Round 4 F unused metadata cover changes visible padding | Native EPUB cover identity; unused-cover margin and lazy later-chapter tests. | N repeats original F; historical signed first-process GUI showed correct first-page padding. Metadata-only covers are not promoted to visible pages. |
| 31-G8 Keep image/caption/source through mode/font/resize changes | `NativeEPUBPositionTests`, caption glyph-priority, hosted art/cover tests and native passage owner. | Historical signed C single → continuous → single remains 2:4 with exact whole-art pixel comparison. G final MOBI/FB2 borders/captions intact. Final pass does not claim a new physical four-round mode/resize matrix. |
| 31-F1 Fully quit Finder Open With must reveal document without Dock click | `SumraApp` delegate/startup/window owner; lifecycle first-window and closed-window reuse tests. | F final candidate cold Open With produces the actual file window via an already-bound read-only observation, **no Dock/launch/activate helper after Finder action**; `evidence/optimized-cold-open-with.txt`. Official baseline and historical installed 0.2.17 Finder evidence remain separate; reporter confirms in 6383242166. |

## Final acceptance status

The prior full-gate/package/Finder/GUI completion statement applies only to its identified historical 4397-engine pass. R6 closes physical link-preview/cursor and independent Colors-panel input at the documented boundary. Current E316 Release binding/build, final Book/source binding, 17 unique focused motion/toolbar tests, Light fullscreen, refined Light and Dark fullscreen motion, Virtual 16:9 window/fullscreen/presentation acceptance, Finder smoke and QA cleanup passed at their recorded boundaries. The 7CEA native control-action proof remains accepted; E316 observed three macOS-owned controls windowed. Direct green-button exit, older runtime, and main notched-display rerun remain untested. Current app bundles remain in place for review; no remote operations occurred.

Earlier G records saved PDF note reopening and visible large-EPUB progress; they remain attributed to their snapshot. Current native timings and exact ordered parity are summarized in the follow-up above. Historical paired memory measurements remain uncertain and do not establish app RSS or a leak.

This documentation follow-up updates only the three assigned acceptance records. It starts no build, test, GUI, registration or indexing process and owns no persistent process requiring cleanup.
