# Issue 118 verification

Report: [v0.2.31 issues](https://github.com/Ares-X/Sumra/issues/118).
Baseline app: 0.2.31 (33), source `a8a07ec640d9307f70dc30fd89183bef7df1154f`.
Desktop environment: arm64 Mac, macOS 27.0.1. This does not establish runtime
acceptance on the macOS 13 deployment target or the reporter's display setup.
The corrected signed 0.2.32 candidate, adaptive floating-tab follow-up 0.2.33
and window drag/resize/fullscreen-spacing follow-up 0.2.34 are accepted within
the boundaries below and published. The installed 0.2.31 → 0.2.32,
0.2.32 → 0.2.33 and 0.2.33 → 0.2.34 Sparkle upgrades passed.

The earlier acceptance missed particular action sequences and made broader claims
than its observations supported. The regressions below exercise the actual owner
of each demonstrated failure. Simulated AppKit state, direct button actions and
offscreen rendering are recorded separately from real desktop interactions.

## Complete report review (2026-11-05, in progress)

The 15 items below were re-read against the original text and all attached
videos/screenshots. Previous passing observations remain valid for their stated
sequence; they do not establish that the entire issue is fixed. In particular,
T4 now reproduces in installed 0.2.34. No 0.2.35 release is accepted yet.

| Item | Original sequence that must be preserved | Current conclusion / next check |
| --- | --- | --- |
| W1 | Home hover in/out → green enters fullscreen → pointer leaves without clicking → reveal → green exits → pointer leaves | Home button bodies remain visible in installed 0.2.34 fullscreen. Mounted regressions reject the old behavior. Signed 0.2.35 hides the entire header after fullscreen entry/body focus and restores it on exit. Pointer-only human replay is pending. |
| W2 | Floating single document → hover green until system move/resize menu appears → leave/re-enter → green fullscreen → pointer-only leave | Prior page clicks do not substitute for the pointer-only tracking path. Replay after the Home/native-window changes. |
| T1 | Two original EPUB tabs → click the unselected tab's top/middle/bottom → actual fullscreen → repeat after horizontal scrolling | Final preview passes 12 physical clicks at both original tabs' top/middle/bottom, windowed and fullscreen after horizontal gestures. The offscreen click fixture could not dispatch selection and was retired. No remaining failure reproduced; the original failure is not fully explained. |
| T2 | Four mixed-format floating tabs → select left/middle/right (scrolling if needed) → red closes the whole group; tab x closes one | Owner regression covers all selection positions. Final preview repeats four mixed tabs with the third selected: physical red closes all four; the Window menu contains no remaining document. Prior individual tab-x behavior remains covered. |
| T3 | Four normal tabs, third selected → close third → keep pointer in bar and select surviving left/middle/right → only then leave bar | Final preview repeats four-to-three with the third selected. Immediate close and middle selection fill the bar without the pointer leaving. Left/right clicks select correctly, but those captures omit native chrome, so their paint is unverified. No separate root cause established. |
| T4 | Normal fullscreen → one Open operation selects six mixed formats → inspect Spaces → exit fullscreen → activate every new tab; separately floating duplicate | **REPRODUCED in installed 0.2.34 and corrected:** new MOBI/FB2/AZW3/CBZ retained stale zero native-button opacity. Exact signed 0.2.35 repeats the one-operation six-format open and exit; all seven tabs expose close/minimize/enabled fullscreen. Human button paint and Space inspection are pending. |
| C1 | Floating fullscreen on each current display, including menu-excluded window frame | Signed 0.2.34 and human follow-up establish the corrected 16pt window inset. Reuse this evidence unless touched. |
| C2 | Another app active → first click normal reader top → switch to another Sumra window by its top; Show/Auto/Hide | Prior Calculator→Auto pass covers only one mode/window transition. Complete the sequence with both windows. |
| C3 | Normal Always Hide window → top-left reveal → fullscreen → New Tab/open file → reveal again; only window controls, no tab shadow | Exact signed 0.2.35 repeats Always Hide → top-left click → native green fullscreen → open original I. Windowed reveal exposes only the three controls; the fullscreen new document has no toolbar/tab shadow. Pure hover remains separate from the AX button/click evidence. |
| C4 | CBZ/CBR, normal progress Auto, normal toolbar Auto then Hide → reveal footer | Generated owner regression and actual comic footer pass exist. Preserve the reserved row and page position while checking adjacent scrollbar behavior. |
| L1 | Original second-round C, two pages/cover off → resize larger and through extreme shapes | Pixel regression and user's installed-version resize pass are valid. They do not establish continuous first-frame timing; no need to erase that bounded acceptance. |
| L2 | First file open, paged Actual/zoom, Auto toolbar/progress, no resize → reveal both controls and drag both axes → fullscreen → Always Show without/with tabs | Both excess-clearance defects have failing-before regressions. Exact signed 0.2.35 passes Actual/200%, Auto → fullscreen, both physical scrollbar drags to AX 1.0, exit → Always Show, and native tabs → separate single window, with adjacent tracks and no resize. Uses the captioned C substitute. The unavailable Carpenters book and rare half-obscured case remain unverified. |
| L3 | A three pictured shapes; captioned original C four pictured shapes; I minimum-width/max-height Actual; second-round C narrow/tall Actual, all cover off/two pages | Prior A/second-round C observations remain valid. Final preview adds the historical captioned C candidate in tall and wide Actual/Fit Page and I in tall Actual. CUA did not achieve the actual minimum width; do not treat half-screen width as that boundary. Exact captioned-file identity remains unknown. |
| P1 | Palette Home/Open/Browse Files and thumbnail Page2/Page3 single clicks; separate real double-click/Return execution | Final preview physical single clicks on Home/Open/Browse Files select and keep the palette open. Thumbnail single click → Down → Return opens page 3; physical double-click opens page 2. Exact first-highlight latency remains unmeasured; AX row activation is not a mouse-click substitute. |
| P2 | Focus search → click action row → immediately Up/Down → Return, also after scrolling | Stable responder regression and baseline comparison pass. Final preview repeats physical search focus → Home row click → Down → Return and opens the real Open dialog. Thumbnail keyboard execution also passes. |

Follow-ups from this chat are part of the same acceptance scope: adaptive floating
tab width and wheel reachability (0.2.33), corner resize versus drag, native blank
titlebar dragging and floating fullscreen gap (0.2.34), and Home fullscreen
control visibility (pending). They must not be confused with the similarly named
native Always Hide reader controls in C3.

The remaining work is grouped into coherent journeys rather than separate
releases: Home/floating hover; normal fullscreen batch-open and tab closing;
external activation and Always Hide; first-open paged scrollbars/comic footer;
exact EPUB examples; palette/thumbnail selection and execution. Fix demonstrated
failures at their owners, run affected regressions, then replay the changed
journeys in one final signed package before promotion. Missing physical hover,
continuous frames or Mission Control observations stay explicitly unverified.

Original-media review and current installed reproduction receipts are retained
under `build/issue118/full-review-20261105` in the primary checkout. The six-format
replay uses the existing reporter format sampler. Its MOBI is named
`sample_illustrated.mobi`; the original video shows `sample_illustrated2.mobi`,
so byte identity of that one file is not established. The captioned C candidate
is the earlier reporter `misalignedepubC.epub` (SHA-256
`08401f026d2ee35a89d982abd30a44699c6fea9ef106dd7ecc9817c483bcea9d`),
whose vertical image and `IMAGE SUBTITLE` match the pictured structure; exact
identity with the issue's `repeat-misalignedepubC.epub` is not established.

## Behavior and evidence

| Report | Change and regression evidence | Real desktop evidence / remaining work |
| --- | --- | --- |
| W1/W2: traffic-light hover after zoom | Re-sample the pointer when AppKit replaces the tracking area. A raster regression fails on the old implementation and passes on the candidate. | Baseline glyphs remained after a green-button transition and an outside click. Candidate welcome and floating physical green-button fullscreen transitions followed by outside clicks clear the glyphs. Option-zoom and pointer-only hover sweeps are unverified. |
| T1: floating tab lower half/fullscreen input | No speculative change. The isolated scroll-host hypothesis did not reproduce the report. | Baseline lower-half clicks switched TXT and original EPUB tabs. Candidate lower-half clicks also switched both original-EPUB fullscreen tabs. Reported failure remains unexplained. |
| T2: floating red button closes only the selected tab | Multi-tab red control uses the existing ordered close/approval chain. Real native button actions reproduce the old selected-tab-only behavior. Candidate covers all three selection positions, cancellation in the middle, and restoration of the single-window native action. | Candidate physical red click with the right tab selected left no app windows. Tab x retains individual-close behavior. |
| T3: native tab gap until pointer leaves | No separate root cause established. | Candidate physical middle-tab x click immediately redistributed the two remaining native tabs while the pointer remained in the bar. Exact baseline comparison is unavailable. |
| T4: new/duplicate fullscreen tabs and black Spaces | Closed SwiftUI hosts no longer reconfigure themselves as Home or remove themselves from the native group. Mounted-host regression reproduces that separate lifecycle defect. | Candidate floating duplicate, normal duplicate and normal new-file fullscreen tabs displayed in their groups; exit retained native buttons. Floating-to-normal, exit fullscreen, first physical Next also passed. Black-Space count remains unverified. |
| C1: fullscreen toolbar too low | Menu clearance subtracts the strip already outside the fullscreen window. A real screen/window geometry fixture fails on the old duplicate 33pt reserve. Full-height-menu and Find-clearance cases remain covered. | Baseline fullscreen bar starts at y98px; candidate stable fullscreen starts at y32px, matching the windowed inset. |
| C2: native titlebar cannot activate from another app | Activate the app as well as making the window key; an already-key window is not reordered. | After raising and physically clicking Calculator, the first physical click in Sumra's normal Auto Hide titlebar revealed the toolbar and focused the reader. |
| C3: Always Hide buttons and tab shadow | The reading overlay yields the native button region to AppKit; normal Always Hide leaves toolbar visibility with its AppKit owner. Regression assertions cover button ancestors and canonical root hit targets. Always Hide collapses the public native accessory controller and restores only the state it took over; tests cover native single-tab Hide Tab Bar, selected-tab ownership, detach and fullscreen restoration. Windowed document proxies remain hidden while the reader toolbar is hidden. | Three native tabs + Always Hide still revealed the document proxy icon in candidate 3. Candidate 4 passed the same three-tab physical header-click replay: no document proxy, toolbar or tab strip remained. Always Hide/Show preserved actual fullscreen; exit restored tabs and the first physical Next worked. The first signed candidate failed actual pointer-only hover and was rejected. After the focused follow-up, the same SDK-policy runtime probe reveals all three controls; the user confirmed physical pointer-only hover, and native green/fullscreen/exit/red-close actions passed. The corrected signed candidate passes the same native-control/header replay below. |
| C4: normal comic progress Auto Hide lacks footer room | Normal progress retains its 26pt row independently of native toolbar Auto/Hidden. Generated comic host test is red on old code and green on the candidate. | Real Numbered comic GUI passed toolbar Auto/Hidden + progress Auto: the revealed slider stays below the page without changing its position. |
| L1: one-frame EPUB resize stretch | Pending outgoing bitmaps retain their aspect while replacement page geometry is already published. A real circle raster turns into an ellipse on the old implementation and retains its aspect on the candidate. | An original-book wide/short transition sample retained aspect before new geometry settled. Continuous resize capture remains unverified; sampled screenshots cannot exclude a transient frame. |
| L2: initial/ fullscreen scrollbar clearance | Scroll-owner publication and actual viewport frame changes update the clearance owner; its observer follows the current viewport and is removed/restored on detach. Late mount, same-owner attachment, final frame and Find-close cases pass. | Continuous comic tracks follow the viewport in normal Always Hide/Show and actual fullscreen normal/floating modes. A fresh duplicate comic reader in Continuous/Fit Width with Always Show Scrollbars also placed its track below the revealed Auto Hide toolbar without a user resize. This is a fresh mount, not continuous first-frame or cold-file timing evidence. |
| L3: EPUB facing cover at extreme sizes/Actual | The cover uses its facing paper in both Fit Page and Actual Size. Authored peer content is preserved. Four original-book hosted regressions reproduce the old placement failure; all eight originals retain contained native art at three viewport shapes. | With cover off, fifth-round A passes narrow/tall Fit Page, wide/short Fit Page and Actual, and fullscreen Actual. Second-round C passes narrow/tall Fit Page and Actual, wide/short Actual and fullscreen Actual. I passes tall Actual with aligned facing images. F, G, H, fourth-round C and third-round D also passed Fit Page and Actual Size. F and fourth-round C passed wide/short Actual; F retained its wide image/caption, G its small native logo, H its text, and D its separately paginated second image/dedication. Not every mode and shape was replayed for every book. |
| P1: palette/thumbnail mouse feedback | Native mouse-down selects immediately; mouse-up with click count two activates. Candidate input-owner raster tests check visible changed selection and double-click behavior. | Physical single-click selection and double-click execution passed. One palette click plus capture completed in 0.5704s, an observation upper bound rather than frame timing. Thumbnail click, Down and Return also passed; precise thumbnail latency is unmeasured. |
| P2: palette arrows after clicking a row | Clicking hands focus to a stable list responder outside recycled rows. Candidate test covers arrows, Return and scrolling the original row away. | Baseline physical row click then Down left search focused and Open selected. Candidate exact replay moved selection to the next row and removed the search focus ring. |

## Local checks

### Post-release manual follow-up and adaptive floating tabs

The user tested installed 0.2.32 after the Sparkle upgrade. Lower-half floating
tab clicks switched documents in the requested windowed/fullscreen replay, and
the subsequent fullscreen/new-tab Mission Control inspection showed no extra
black desktop. Resizing second-round C showed no visible transient stretch.
These are human observations for those sequences, not exhaustive frame or Space
lifecycle coverage.

The same replay exposed a top-right resize cursor that still initiates window
dragging, excessive fullscreen top clearance, a fixed-width floating tab group,
and mouse-wheel overflow that cannot reach the other documents. The corner and
fullscreen-clearance findings are addressed in the 0.2.34 follow-up below. Screenshots and
the user's observations are retained in `build/issue118/manual-followup-20261105`
in the primary checkout.

The adaptive tab design keeps the existing three floating surfaces. The center
group requests enough room for its document count and readable titles, while its
actual width is limited by the measured navigation and tool groups. It stays
centered where possible and shifts only to avoid either neighbor. Narrow windows
retain the existing merged surface. Tabs share the available width, retain their
120-point minimum and independent close targets, and overflow horizontally only
when they cannot fit. Adding/closing tabs and resizing recompute the layout;
mounting or activating a selected tab brings it into view without undoing manual
scrolling. The plus button remains outside the scrolling viewport.

The tab viewport owns ordinary vertical-wheel translation while preserving
native horizontal gestures. It interprets precise versus discrete deltas using
the [AppKit scrolling delta contract](https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay).
The original native tab group remains the document/selection owner.

Previous sizing coverage mounted the inner tab strip on its own, bypassing the
outer 360-point cap, and asserted only that overflow geometry existed. Follow-up
coverage mounts the complete floating toolbar and exercises wheel input rather
than equating a scroll view with reachable documents. These local checks remain
separate from the signed release acceptance recorded below.

The first real preview exposed another missing fixture condition: native
full-size-content windows passed a 48-point titlebar safe area into the nested
hosting view, moving its labels below the 28-point viewport. The new containment
case failed before the correction. The tab content host now owns zero safe-area
insets because its parent has already positioned this window chrome. The input
fixture also mounts the actual ReaderView and locates its tab viewport by the
document surface, rather than accidentally sending wheel events to the reader.

Five adaptive-tab cases and three adjacent native-tab cases have passing final
evidence across focused runs: count/width/side-control layout, membership and zoom
label changes, vertical/horizontal wheel reachability, selection reveal including
RTL, full-size native target containment, existing two-tab targets, long-title
selection and native color markers. This combines seven passes in `tests-accepted`
with the corrected wheel fixture's pass in `tests-reader-viewport`; it is not a
claim that the earlier eight-case invocation was entirely green. Baseline runs
reject the original fixed cap and unreachable vertical-wheel overflow. The main
debug build and the independent preview's deep strict signature check also pass.

Real CUA input in the corrected preview opened all eight original EPUBs in one
group. At 900 points the center surface used about 488 points, and vertical wheel
input reached both ends without changing the document. Clicking the lower half
of the revealed last tab selected F. Fullscreen and Window > Fill both expanded
the strip to show all eight tabs between the side controls. Leaving fullscreen
restored the narrower viewport with F still visible. These observations cover
the local ad-hoc preview on macOS 27.0.1.

### Signed 0.2.33 and installed update

Adaptive floating tabs [PR #124](https://github.com/Ares-X/Sumra/pull/124) merged as
`14e13be4756bd624ec80deda12bfd85d2f310f54`. The
[candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/41973045480)
built that revision. The 0.2.33 (35) package passed all asset checksums, frozen
source/build correspondence, the original signing certificate, deep strict code
signature, all 140 app-file hashes and public-key-only Sparkle verification.
It is arm64, minimum macOS 13, compiled with Swift 6.1.2 and SDK 15.5.
The accepted manifest digest is
`6c2b1d3e625aef49e3425f462df03da5a264e6edc8af8e04649383ac4d42c9cc`.

Real CUA input in that exact signed app repeated the original-book tab sequence.
The centered surface grew from one to two to eight documents, and all eight fit
between the side groups in a wide window. Native Window > Move & Resize > Left
narrowed the window while retaining the selected last tab. Vertical wheel input
reached both ends without changing documents; physical lower-half clicks selected
the revealed A and D tabs. Actual native fullscreen expanded all eight tabs.
Closing six selected tabs shrank the surface back to two; exiting fullscreen
restored the half-width window with F selected. Labels and close targets remained
vertically contained.

Finder Quick Look using the exact signed preview extension advanced original I
from chapter 1 to 2 and the numbered comic from page 1 to 2. Finder icon view
rendered both thumbnails using the exact signed thumbnail extension. Runtime
paths were verified for the app and both extensions. The temporary Finder window,
Quick Look and candidate app were closed; candidate registrations were removed
and installed extension registrations restored. All eight original hashes were
unchanged. Detailed receipts are under
`build/issue118/manual-followup-20261105/release` in the primary checkout.

The [publication workflow](https://github.com/Ares-X/Sumra/actions/runs/41974781161)
published [0.2.33](https://github.com/Ares-X/Sumra/releases/tag/v0.2.33) without
rebuilding: all six asset IDs, sizes and digests match the accepted draft.
Anonymous downloads of the public app ZIP and default-branch appcast match the
accepted files. The installed 0.2.32 app then completed Help > Check for Updates >
Install Update > Install and Relaunch. About shows 0.2.33 (35), the running process
is `/Applications/Sumra.app/Contents/MacOS/Sumra`, all 140 installed file hashes
match the accepted provenance, and its deep strict signature passes.

The corner resize/drag mismatch and reported fullscreen top clearance were
still pending at 0.2.33. Hardware trackpad momentum, physical macOS 13 and exhaustive Space
transitions were not exercised. Disposable preview/candidate app copies, Finder
fixture copies and duplicate release archives were retired after checking for
active consumers; recipes, logs, manifests and verification receipts are retained.

### Window-edge and fullscreen-spacing follow-up

The corner mismatch comes from the reader's local mouse-down monitor: it treated
draggable titlebar hits as window moves and consumed the original event before
AppKit could handle native resizing. The monitor now performs activation only
and preserves the original event. The reading overlay starts a move only when
AppKit dispatches a mouse-down to that view. Native titlebar, toolbar, accessory
and tab input remains with AppKit; no guessed edge width or custom resize logic
is introduced.

The extra floating fullscreen gap was a permanent reservation for the transient
system menu. Floating controls now retain the same 16-point inset inside the
window in both modes, with native menu reveal left to AppKit's overlay. Native
nonfloating chrome retains its existing menu clearance. Reading margins, Find
and scrollbar clearance continue to follow the actual controls.

The old source fails the new native-dispatch regression in Auto Hide and Always
Hide and places the rendered fullscreen floating group 49 points below the top
instead of the windowed 16 points. The fixture now verifies original event
delivery at all sampled top/right/corner points; native extreme-edge hits need
not report themselves draggable. The rendered ReaderView fixture checks exact
position, both full-height and menu-excluded window frames, menu reveal, reading
position and Find/scrollbar restoration. These are isolated native fixtures,
not physical Window Server resize or fullscreen transition evidence.

Fifteen focused final cases pass across the input, native-control, fullscreen
and adaptive-tab runs. This combines the corrected five-case input rerun with
the other ten passing cases, rather than calling the earlier fixture-precondition
failure a green run. The main debug build also passes.

Actual fullscreen transitions with original A were measured in the local GUI
preview on both displays. On the external display the floating navigation group
starts 16 points inside the fullscreen window. On the built-in display macOS
excludes its 33-point notch strip from the window; the group remains 16 points
inside that window, with no additional application menu reservation. Temporary
geometry instrumentation is removed from production source. CUA corner drags
did not produce a verified frame change because of inconsistent dual-display
input targeting. Physical resize acceptance is recorded separately below.

Evidence is under `build/issue118/window-chrome-20261105` in the primary checkout.
The first signed 0.2.34 candidate from `ab54a3af95baa17fa64ba7dbec2e4fb17d92d0b6`
passed file, original-certificate, frozen-source and update-signature verification,
but failed human desktop acceptance: the blank native titlebar area between the
filename and first toolbar control could no longer drag the window. Its rejected
manifest is `ffde82f41b7a90d41e89654654cf78cd4cc360cae39c8dcebb166c79d0c325ed`;
these bytes must not be published.

The dispatch test stopped at a spy NSWindow and never exercised the visible
native hit's mouseDown. The correction mounts a drag receiver in the actual
native titlebar. It yields controls, accessories, Command clicks and double-clicks
to their existing owners and starts a move only after AppKit dispatches to it.
The monitor still preserves edge events. The receiver is removed when its
chrome, selected tab or host no longer owns that titlebar.

The new regression measures the filename-to-first-control gap, obtains its
actual root hit and verifies that hit starts a drag with the original event.
The rejected source fails at the absent receiver before entering Window Server
tracking. Native gesture checks dequeue their events before hit testing rather
than assuming direct sendEvent sets currentEvent. Eight affected final cases pass across the corrected native drag case and the
adjacent input, late-control, reading-overlay and fullscreen cases. The event
queue may return a new NSEvent instance: the test verifies its fields and uses
that dequeued event as the identity boundary. Its first stricter identity
assumption failed and was corrected; the subsequent focused rerun passes.
The local GUI preview uses the new source and the signed app's SDK 15.5 runtime
policy stamp, but remains an ad-hoc build from the local compiler. The user
confirmed that both native blank-titlebar dragging and top-right resizing work
in that corrected preview.

### Signed 0.2.34 acceptance

The [corrected candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/41993469200)
built source `f4f709fff36ad57b3e0a5bc4019b26b1e4d4ea86`. The exact 0.2.34 (36)
package passes all asset checksums, including corresponding source, all 140
app-file hashes, the original signing certificate, deep strict signature,
frozen source/build correspondence and public-key Sparkle verification. Its
manifest digest is
`7639c047597ca599bb8ba6d4b3fa427fe3a994654398970f567ef9bf2634c985`.

In that signed package, original A retains the 16-point floating inset during
real fullscreen; exiting restores native controls, and the first native Next
advances to chapter 2. The user independently repeated the native blank-titlebar
drag and top-right resize in this final signed package and confirmed both work.
The local preview confirmation is not substituted for this signed-package check.

Finder shows original I and comic PAGE 1 thumbnails. Quick Look advances I from
chapter 1 to 2, rendering its yellow page, and the comic from PAGE 1 to PAGE 2.
The app and both extension process paths point to the corrected signed bundle.
The temporary Finder window and Quick Look were closed, the candidate exited,
installed extension registrations were restored, and scoped test preferences
were restored without replacing the user's whole preference domain.

[PR #126](https://github.com/Ares-X/Sumra/pull/126) merged as
`c80ee48e60c662bce77eeb11bc3dbf1dea774572`. The
[publication workflow](https://github.com/Ares-X/Sumra/actions/runs/42002203498)
published [0.2.34](https://github.com/Ares-X/Sumra/releases/tag/v0.2.34) from those
accepted bytes. All six public asset IDs, sizes and digests match the candidate;
the anonymous ZIP SHA-256 is
`047a24dc15f18df8590e2689ab457cf871978e5cc73ca0cdb04901cb8c3aa5e9`.
The anonymous default-branch appcast matches the accepted feed, and its public-key
Sparkle signature verification passes.

Installed 0.2.33 detected the public update and completed Help > Check for
Updates > Install Update > Install and Relaunch. About shows 0.2.34 (36).
The new process runs from `/Applications/Sumra.app`; all 140 installed file
hashes match accepted provenance and deep strict signature verification passes.
The installed 0.2.34 preview/thumbnail registrations point only to that app.

Evidence is retained under `build/issue118/window-chrome-20261105/release-corrected`
in the primary checkout. Temporary previews, candidate bundles, Finder fixture
copies, build scratch and duplicate release archives were removed after checking
active consumers. The rejected private 0.2.34 draft is removed; one exact rejected
ZIP, source hashes and failure evidence remain locally until reporter confirmation.
The installed 0.2.34 app remains open for the user. Physical macOS 13, hardware
trackpad momentum and exhaustive Spaces transitions were not exercised.

### Home fullscreen follow-up after 0.2.34

The user reported the welcome window's traffic lights remaining visible in
fullscreen. This is a custom Home header, not the reader's progress/status bar.
The installed 0.2.34 reproduces it: after native fullscreen entry, clicking the
central search field leaves the red and green controls visibly painted while
minimize is disabled. This sequence was not included in the earlier signed
reader acceptance. The Home regression only mounted its header at two windowed
widths, without the window chrome observer or a fullscreen transition.

Home's header was unconditional and the existing pointer owner explicitly
required a document. The correction lets fullscreen Home use that same pointer
owner independently of reading-toolbar preferences. Its header observes native
fullscreen state, hiding paint, hit targets and accessibility together while
retaining its layout space. Windowed Home keeps its controls visible.

This follow-up requires its own regression, signed-package and installed-update
evidence. It does not establish that every sequence in the original report is
resolved.

### Combined fullscreen and scrollbar correction

Replaying normal fullscreen followed by one six-format Open operation reproduced
the missing native controls in installed 0.2.34. The chrome owner captured zero
button opacity while those new windows were fullscreen, then restored that stale
value after AppKit returned them to windowed mode. Native button opacity now
remains with AppKit throughout attachment, updates and teardown. The new owner
regression fails against the old implementation. In the preview, all seven tabs
retain close, minimize and fullscreen accessibility controls after exit; some
shared-window captures omit the separate native titlebar, so this alone is not
complete painted-control acceptance.

The first-open paged replay also found both parts of the reported scrollbar gap.
Changing `scrollerInsets` deferred actual track layout until another native layout
event. The old tests themselves called `tile()` before checking the track. The
owner now tiles when its inset changes, and the test observes actual tracks
immediately across nonzero, changed and zero clearance in both scroller styles.

In Always Show, SwiftUI's scroll view can still extend under the native titlebar
while its `contentInsets` already reserve that area. Real geometry logging showed
a 38pt overlap, 45.5pt content inset (native area plus content padding), and a
second 38pt scroller inset. With a tab bar, the overlap grew to 66pt. A request
for zero overlay clearance now leaves that existing native reserve alone; Auto
Hide retains the explicit overlay clearance. A separate native geometry test
reproduces the duplicate reserve and checks the actual track without moving the
viewport or changing the system-owned content inset. Both new scrollbar cases
fail before their respective corrections.

The linked-SDK 15.5 diagnostic run uses the local compiler and a changed test-host
SDK policy stamp, not the release compiler. Its existing Always Hide offscreen
hit-test case fails identically against both the shipped and candidate owners;
the three native controls paint and the overlay yields, but the root hit target
differs in that isolated host. This is retained as a diagnostic limitation rather
than deleting the assertion or treating the invocation as green. Actual signed
Always Hide acceptance remains necessary.

The final source has passing evidence for 15 affected cases across the focused
SDK-policy and normal-host runs. This combines 14 passes in the diagnostic batch
with the unchanged Always Hide case's normal-host pass; it is not a claim that
the diagnostic invocation was wholly green. Source inputs stayed frozen and
isolated preference/pasteboard suites were cleaned after every run.

The final ad-hoc preview repeats first-open paged Actual Size, Auto to Always
Show, Show Tab Bar, Hide Tab Bar, fullscreen at 200%, both scrollbar drags near
their far ends (AX values above 0.998), exit fullscreen and Always Show. Tracks now remain adjacent to the current
native controls without a resize, with no accumulated top gap. The historical
captioned C is used explicitly as a substitute for the unavailable Carpenters
book. This preview uses a local compiler with the SDK-policy stamp; the exact
signed-package observations follow below, and the installed update remains pending.

### Exact signed 0.2.35 candidate

[PR #128](https://github.com/Ares-X/Sumra/pull/128) groups the Home fullscreen,
native-button lifecycle and scrollbar corrections. The
[candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/42014573419)
built source `ef1fb5fdf451f6acf9e7f02cb537db62a918bb4d` as 0.2.35 (37), using
Swift 6.1.2 and SDK 15.5. All asset hashes, frozen source correspondence,
140 signed app-file hashes, original certificate, deep strict code signature and
public-key-only Sparkle verification pass. Candidate manifest SHA-256:
`1527e3bef5537cae0a5b97e90d8f55ebcef372642ad6963b2c08f86a12a87ef0`.

On macOS 27.0.1, this exact package passes Home fullscreen/body-focus header
hiding and exit restoration, the normal fullscreen six-format batch-open/exit
with seven complete native control sets, and the signed scrollbar journey in L2
above. Both actual fullscreen scrollbar drags reach AX 1.0. The Always Hide
new-file chain exposes only window controls in the windowed reveal and no
residual toolbar/tab strip in the captured fullscreen document.

Finder icon view renders fresh original-I and numbered-comic thumbnails.
Quick Look advances original I from chapter 1 to 2 and the comic from page 1 to
2. Both extension process paths point to the exact candidate. The temporary
Finder and Quick Look windows are closed. Candidate extension registrations and
the scoped preference backup remain until final acceptance/installed update;
they must be restored before retiring the candidate bundle.

Pure pointer-only Home/floating hover, native button paint obscured by the macOS
sharing indicator, and Mission Control are pending a single grouped human replay.
The candidate is not yet accepted for publication. No claim is made for physical
macOS 13, continuous first-frame timing, actual minimum-width C/I geometry,
all three C2 modes across two windows, or missing reporter sample bytes.
Receipts and viewed contact sheets are under
`build/issue118/full-review-20261105/release` in the primary checkout.

### Original 0.2.32 checks

The initial isolated full run recorded 1,575 passes, five failures and 40 skips.
The five failures were investigated individually: titlebar activation unnecessarily
reordered an already-key test window; the fullscreen fixture did not span the
screen's menu region; the normal-footer test still expected overlay geometry;
the margin snapshot omitted preference revisions; and the input-only Find fixture
did not consume the initial search command. Product and fixture corrections each
have focused passing reruns. The last batch passed 12/12; Margin passed separately.
A Quick Look supplement also passed one formerly skipped case using the installed
engine. This is combined evidence, not a claim that a second full run was green.

Swift parsing, localization audit, packaging tests and reader JavaScript syntax
checks passed. The final C3 follow-up passed its new real native-host case, the
corrected menu-reveal fixture and eight adjacent input/restore cases. Its actual
desktop replay passed in local debug candidate 4.

That proxy leak illustrates a missing precondition in isolated acceptance: the
native proxy was already hidden in the offscreen host, so its hidden-state
assertions did not reproduce the GUI defect. The public accessory controller has
an independent failing-before regression; the proxy requires the actual desktop
header-click replay. A native Hide Tab Bar action is checked in a single-tab
group where AppKit permits it, and temporary reveal checks retain their native
control ownership when layout changes.

## Original files and traceability

The reporter's eight-file archive is unchanged:
`misalignedepubsfifthround.zip`, SHA-256
`b14e2c572074641a229d5522953fbc867ffa46370cee3854e660a969346d93ab`.
Local evidence is retained under `build/issue118` in the primary checkout,
including individual fixture hashes, baseline app metadata, source/build
receipts, isolated test logs and `gui-observations.md`.

Local GUI packages are ad-hoc debug builds using the installed release's unchanged
engine/resources. They are not the signed release candidate. Publication must
follow [the release workflow](RELEASE_ACTIONS.md), including exact signed-byte
original-book and Finder-extension acceptance, then the public update path.

## Signed candidate status

PR [#119](https://github.com/Ares-X/Sumra/pull/119) merged as
`5814f0f59fceacb2fb9aae413a1cb08d3730049f`. The
[candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/41868875434)
succeeded. The first, later-rejected 0.2.32 (34) draft passed all asset checksums, the original signing
certificate, deep strict code-signature verification, 140 app-file hashes against
provenance, arm64/macOS 13 deployment metadata, frozen source/build correspondence,
and public-key-only Sparkle Ed25519 verification. The rejected candidate manifest
digest is `dfa7d0e3f06f625d0527c2ec936e4adb38ba1c04aeeab486fb3280208cc20ca3`;
it must not be used to publish this rejected candidate.

That first draft's signed GUI checks confirmed A's cover-off Fit Page and wide/short Actual
alignment, three-tab native accessory/proxy hiding, I's fullscreen Hide/Show
restoration, and the first physical Next after fullscreen exit. The user confirmed
that C3 pointer-only button reveal failed even after clicking the page to activate
Sumra. That first draft was rejected for publication. Finder extension acceptance and the installed update
path were deferred to the corrected candidate. Local observations are in
`build/issue118/release/signed-gui-observations.md`.

A temporary cold ReaderWindow probe drove the actual application event monitor
and SwiftUI update path. It passed locally but did not reproduce the signed
failure, so it was removed after retaining the diagnostic evidence. Both real local WindowGroup Debug and Release/Osize builds also reveal
the native buttons. Their main binary SDK stamp is 13.0; the signed candidate
uses SDK 15.5 and Swift 6.1.2. Changing only the local Release main binary's SDK
stamp to 15.5 reproduces the failure on the same Mac and original file. This is
a controlled runtime-policy probe, not a true SDK 15.5 compilation or release
acceptance. The separate CI diagnostic job was cancelled before it acquired a runner; GitHub
reported macOS arm64 capacity constraints. It produced no build or release.

The failing probe receives the mouse event and completes the hover update.
All three captured/current native controls match, with `isHidden == false` and
alpha 1, but their titlebar view has alpha 0 and its parent container is hidden;
their visible rectangles are empty. Checking the button alone and using a local
app with a different main-executable SDK policy therefore missed the defect.
The follow-up leaves normal Always Hide's native toolbar visibility with AppKit
and stops requesting SwiftUI to hide the whole native window toolbar. The
reading overlay also yields the native button region instead of returning a view
outside its subtree. Its new input assertion failed on all three controls before
the change and passed after it, while the root still hit the canonical buttons.
The existing C3 regression now also checks every NSView ancestor's alpha and
visible rectangle. Temporary logging and the cold-mount probe are removed.

The corrected runtime probe repeats the same original-A cold-open and top-edge
sequence. All three native AX controls now appear, and the previously hidden
ancestors have alpha 1, are not hidden and have nonempty visible rectangles.
The toolbar, native tab strip and proxy remain absent. The user independently
confirmed that physical pointer-only hover now reveals all three buttons. CUA
native-button activation enters fullscreen; Always Show/Hide retain fullscreen;
exit restores the original window and controls; native close returns to Home.
Follow-up [PR #120](https://github.com/Ares-X/Sumra/pull/120) merged as
`57889dc4cae0363856549a86ccd18d8004ad473a`. After diagnostic removal, the final
C3 case passed again against unchanged Sources/Tests hashes; its isolated host,
preferences and pasteboards were cleaned. The
[corrected candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/41894989640)
built that exact merged revision successfully. The corrected signed package passes
all asset checksums, the original certificate, deep strict signature, all 140
app-file hashes, frozen source/build correspondence and public-key-only Sparkle
verification. It is 0.2.32 (34), arm64, with macOS 13 minimum and SDK 15.5,
compiled by Swift 6.1.2. Its manifest digest is
`fe9b3b9514ece0d1cf833c497bb7d261dbc1ec4f50ddcbb2e215a784f3fa3123`.
After the user unlocked the Mac, the exact signed app passed original-A cold
Always Hide/page-to-header reveal, native green-button fullscreen, fullscreen
Always Show/Hide, native exit and first Next. A three-tab native group hides its
accessory/proxy while retaining the native controls; native red closes the
selected tab without a crash. A and I retain their cover-off Actual Size art and
alignment. The comic keeps the same page position between Auto and shown
progress, with the shown slider below its art. CUA footer clicks did not reliably
reveal Auto progress, so the earlier local Auto-hover evidence remains separate.
The sharing indicator still obscures native button paint in CUA captures; the
user's pointer-only paint confirmation belongs to the corrected local probe.

Actual Finder Quick Look rendered original I and advanced from chapter 1 to 2,
and rendered comic PAGE1 then PAGE2. Both fresh portrait thumbnails displayed.
The preview and thumbnail process paths point to the exact signed candidate.
Finder initially picked the installed 0.2.31 preview; that observation was not
counted. Only its registration was temporarily removed, then restored after
acceptance. The task-created Finder window was closed; candidate extension
registrations were removed. No global cache purge or process kill was used.

[Publication](https://github.com/Ares-X/Sumra/actions/runs/41957911778) succeeded
using the accepted manifest above. [v0.2.32](https://github.com/Ares-X/Sumra/releases/tag/v0.2.32)
is public; an anonymous download matches accepted ZIP SHA-256
`94b793d226ec99725c6ae2486163e35addbe75e33f4f336cc151247130c8200b`
(17,096,729 bytes). The public feed equals the accepted appcast, and public-key
Sparkle verification passes. The workflow publishes those existing bytes without
rebuilding or recompressing them. Installed 0.2.31 detected 0.2.32 and completed
Sparkle download → Install and Relaunch → Home. About shows 0.2.32 (34);
the new installed process replaces the old PID, all 140 installed app-file hashes
match the accepted candidate, and deep strict signature verification passes.

Six task-modified preference keys were restored individually; all other values,
including Sparkle's new last-check time, are unchanged. The private backup was
removed after verification. Task-created Finder windows, application processes,
local test hosts and temporary extension registrations are closed or released.
Local build scratch, disposable app bundles and duplicate source/app archives are
retired; the rejected private draft and failed diagnostic branch are removed.
Compact logs, fixtures, receipts and one exact rejected signed ZIP remain for
reproducing the SDK-policy failure until reporter confirmation.

## Acceptance boundaries

All agent-operated desktop interaction uses Codex CUA. Native AX actions and physical coordinate
clicks are distinguished. The current CUA native API has no documented continuous
frame recording or desktop/Spaces overview; multi-display/Space transitions also
produced inconsistent screenshot/click targeting. Failed targeting is not recorded
as a product defect. Missing evidence remains pending.

The human report stays open for reporter confirmation. Do not use an automatic
closing keyword or describe the whole report as fixed while rows remain pending.
