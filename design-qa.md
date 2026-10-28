# Issue 42 floating controls and live resize — 2026-10-27

final result: ready for user acceptance

The selected design is the second displayed concept (three separate groups):
`/Users/aresx/.codex/generated_images/01a17171-d5b9-7192-9956-e4cccff8afd7/exec-02d0b241-e987-455f-b28c-5f5fe8afc3c3.png`.
The user's later instructions supersede it below 680 points: combine controls in
one row, truncate long filenames and avoid repeated titles. Default reserved
margins remain; floating controls are optional.

## Evidence and normalization

The source image is 1487 × 1058 pixels. Native captures are at 2× display density;
the before sequence spans 560–900 point windows and 500–650 point heights.
The reference depicts an interior spread while the captured original Alice FB2
is its separate title page; book text and image composition are therefore not a
pixel-for-pixel fidelity target. The app-owned toolbar regions were viewed in the
same comparison input. Genuine original book art must remain intact and keep its
aspect ratio, regardless of this content difference.

Candidate before the live-resize repair:
`c74c88e6af3d6380dd08e228690ba7ea17d864aba6b90337c41594172ea91108`.
Evidence lives in `build/issue42-followup-20261027/`.

## Review history

1. User screenshot: P1 controls stacked into two large rows, duplicate filename,
   absent window buttons, leaked proxy icon, and book title obscured. The new
   responsive toolbar removes the stacked group and repeated compact title;
   split-view safe-area correction restores the intended reading region.
2. Actual candidate and continuous mouse drag: P1 native window buttons still
   disappear after settling; P1 native title and proxy icon reappear during
   resize; P1 Fit Page retains its old display size during the drag, causing
   clipping, scrollbars and major horizontal displacement. These are visible in
   `live-resize-before/r0-drag-10.png`, `r1-drag-06.png`, and `r2-drag-10.png`.
   The mouse-up captures recover, so a static settled screenshot alone is not
   acceptance. Thirty drag frames and nine settled frames plus native render
   diagnostics were captured.
3. Candidate `69b54ff74d16ab78d819be43e0a53bbb9870fa60fb48ec544a869dd0c942ba55`
   fits existing pages during real dragging and defers pagination and raster
   generation until mouse-up. `final-small-window.png` shows the complete original
   Alice artwork with the single compact toolbar and no duplicated native title.
   Thirty-nine native captures of the reporter's C EPUB show equal image widths
   and vertical centers in both pages (0 pixel difference in every frame), with
   no visible clipping. Each drag separately remains compatible with fixed image
   proportions and independent one-pixel rounding per axis. Cross-mouse-up bitmap
   comparisons include re-pagination and raster sampling; they do not establish
   pixel-exact invariant artwork bounds. See `final-c-spread-geometry.json`.
4. The same candidate was dragged without a CUA window-sharing attachment. Three
   native input sequences reached their final window size about 1, 55 and 1 ms
   after mouse-up. Window-sharing capture adds AppKit synchronization stalls in
   both Sumra and an empty native baseline window; capture timings are not normal
   runtime timings. See `final-unshared-live-resize-profile.txt` and the paired
   samples. Native diagnostics show no intermediate drag bitmap requests.
5. Actual native full-screen entry exposes a remaining blocker: floating window
   buttons lose their window association after SwiftUI dismantles/reuses the
   view. Actual tab-close acceptance also fails while floating controls are on;
   turning them off immediately permits the native middle tab to close. Both
   must pass on a newly built candidate before this report can pass.
6. The failed native command test established that setting a standard window
   button's own alpha to zero disables AppKit's Close validation. Hiding its
   native parent container preserves that command, including the existing close
   confirmation/delegate veto. The repaired full-reader test passes at 560, 800
   and 560 points, and lifecycle reuse resolves the current mounted window.
   `focused-native-container-chrome.log` passes 45 tests with no failures.
   Actual full-screen, tab close, hover and final candidate screenshots still
   need confirmation before the result changes from blocked.
7. Candidate 5 restores ordinary Close capability but real full-screen entry
   still hides the floating group. The bounded real-Space probe establishes why:
   AppKit registers the factory copies as the window's standard buttons, and
   chrome discovery then hides their parent inside reader content. Excluding
   reader content fixes the real-Space probe; the seven native integration tests
   pass in `focused-fullscreen-content-owner.log`. Final app validation remains.
8. The user's later spacing feedback reduces Wide from 32 to 24 points and its
   extra floating clearance from 82/40 to 66/32 points (top/bottom). Legacy custom
   values retain their values and clearance. The visible Alice had retained a
   legacy Custom 32-point value rather than an explicit Medium preset. Native,
   browser and hover margin tests pass; migration's historical 32-point implicit
   value is independent of the current preset. The focused migration rerun passes
   eleven tests in `refined-wide-margin-migration-tests.log`.
9. Candidate 6 (`b73d026d371ce431133120958e32ef9e8a07d494c36954ae66d6a60450d6a3da`)
   passes actual full-screen entry/exit with a single visible set of working
   window buttons. Minimize produces AXMinimized=1; middle MOBI tab close and
   closing the welcome tab through the red button both work immediately.
   Four real hover captures retain identical book pixels (1120 x 868 region)
   and identical window bounds; see `candidate6-hover/geometry.json`. Two real
   resizing rounds completed; the third was safely aborted before input when
   the target corner belonged to another app. This is not a three-round pass.
10. The user found a missing mode boundary: the floating reading controls also
    appeared on the welcome page. `usesFloatingChrome` now requires an open
    document. The hosted welcome/loading/document/close-to-home regression and
    related controls/native-toolbar checks pass (39 tests), while preserving
    the user's floating preference. See `focused-reading-only-floating.log`.
11. The subsequent screenshot disproved the spacing acceptance: the outer
    toolbar clearance still stacked on top of page margins, and the fixed
    toolbar band reserved a second row even for one document. All groups now
    stay 36 points high, including multiple tabs. Preset clearances deduct the
    explicit book margin: total top 48/56 and bottom 34/40 points for Medium/Wide.
    Unset native publisher margins are unknown and are not inferred from the
    legacy scalar. The current profile disables saved reading positions; the
    additional window opened during acceptance had Custom 32 rather than the
    Wide choice made in the original window. Final visual proof must explicitly
    inspect the active book's selected preset.
12. New geometry assertions exposed another real error: the native split-view
    child reclaimed top padding smaller than its 52-point safe area. The reader
    clearance now lives inside the ignored-safe-area subtree. The retained
    red geometry log and independent hidden SwiftUI probe reproduce the error.
    The final gate (`focused-clearance-final.log`) passes 23 tests, including
    TXT/HTML/FB2 total clearances, unchanged window bounds across presets, no
    extra native inset, fixed book geometry during hover, welcome transitions,
    and reachable Find controls even in Narrow. Source fingerprints are retained
    in `clearance-source.sha256`; final app validation is still required.
13. Candidate 7 (`97efc8304df02ac7f65728153b23e58cbe6829cf3032183c4acdc4a660ebc474`)
    is built, signature-verified and loaded. Real Cmd-T shows the native welcome
    toolbar/tab bar with no floating groups; selecting the book restores the
    floating groups and closing the temporary welcome tab works. Real full-screen
    entry/exit retains one working button set. The active book was explicitly
    set to Wide 24. Three unshared 60-event resize gestures reached their final
    sizes in about 1.64/1.09/0.92 ms after input ended; these are catch-up times,
    not per-frame timings. A separate 39-image native drag capture includes
    compact/three-group transitions and complete art at all selected frames.
    Four hover states have identical book-region pixels and 900 x 650 window
    bounds (`candidate7-hover/geometry.json`). The original Always Show setting
    is restored. The capture-bound process was closed, then the same signed
    candidate cold-launched without a CUA capture attachment; Wide was selected
    explicitly again because this profile disables saved reading positions.
    `wide-after.png` is the clean, unedited final 900 x 650 preview left open for
    the user. Old task-owned candidate backups are removed; receipts remain in
    `scoped-cleanup.json`.

## Fidelity surfaces

- Typography: system toolbar fonts and middle-truncated filenames are intentional;
  the extra native title is removed in the latest loaded candidate.
- Spacing: compact controls form one 36-point row. The reserved outer region is
  constant across responsive modes. Medium/Narrow TXT and HTML integration tests
  now confirm narrow starts at the window top instead of retaining 52 points.
- Colors: opaque theme backgrounds and restrained strokes/shadows follow the
  chosen design. Native buttons remain visible and functional across full-screen
  entry/exit; minimizing is appropriately unavailable while full-screen.
- Images: original Alice artwork is used without replacement. The failing drag
  sequence is retained; the repaired candidate displays the complete image and
  keeps both halves of the reporter's spread synchronized during resize.
- Content: a single document is named once. Compact multiple tabs omit the
  repeated heading; selected long tabs remain reachable in the automated test.

The issue-wide recheck passed 258 distinct related tests with no remaining
skips after the original EPUB/AZW3 pinch fixture was supplied. Actual follow-up
checks cover native/floating middle tab close, stationary tab activation, View
menu tracking, Settings/Home appearance, original D final spread progress,
progress visibility modes, full-screen landscape centering/Dock avoidance,
original comic blank click plus resize, and Finder Quick Look for six original
extensions. System Quick Look ran the registered official extensions, not the
candidate extension bytes; the coverless EPUB Finder icon remains the accepted
Apple Books routing edge case.

A final unshared cold launch with floating controls and Auto Hide persisted
reveals a new blocker: the top controls do not appear on the first real hover,
while bottom progress does. Switching Always Show then Auto Hide restores top
hover. Two independent cold processes reproduce this with no CUA binding;
`recheck-cold-hover/` and `recheck-cold2-hover/` retain the failures, and
`recheck-after-mode-toggle/` retains the successful control. Candidate 7 is not
ready for user handoff until this is repaired and reverified. Publication and
the reporter reply remain pending the user's requested personal acceptance.

The subsequent diagnostic has not established the product cause. The full
hidden ReaderWindow/WindowTabs asynchronous-open test passes with one Host and
mouse acceptance true, but is not a real WindowGroup Scene. A temporary
environment-gated logging build records one Host with mouse acceptance true
and a non-key window before input. Its actual-pointer probe aborts safely when
the hit owner belongs to another app. SecurityAgent owns the foreground after
the signing attempt; CUA explicitly disallows that protected app. The owned
codesign process is stopped, no credentials or security settings are changed,
and the user is asked to cancel only that codesign prompt. No speculative
input patch is applied. The diagnostic app is stopped, all source tracing is
removed, and exact signed candidate 7 is restored to dist. One local diagnostic
bundle and its logs remain for resuming this investigation after the prompt is
closed. User acceptance has not started.

Candidate 8 supersedes that blocked state. A confirmed regression was reproduced
with a foreground, unchanged Home window and a pointer fixed at (1158,120):
asynchronous book opening left the floating controls hidden. The exact hosted
regression also failed before the repair. The existing Host now resamples its
current pointer on document-identity changes, deferred past SwiftUI's update.
The complete related rerun passes 260 distinct tests with no failures or skips.

Candidate 8 is a locally ad-hoc signed release-configuration build, executable
SHA-256 `2ff819a6937cce14632bc267452d09a4feeb5322c351ad6a8266b8c2710731cb`.
Its real Home-to-book stationary test and direct cold launch show controls
without further input. Ordinary and real full-screen four-state hover tests
check both the actual pointer and foreground app; window bounds and book pixels
stay identical. Failed attempts with pointer/focus interference were aborted
and are not counted. Evidence is in `candidate8-geometry.json` and the matching
capture logs. Alice is left open at 900 x 650 with explicit Wide 24, Light and
Auto Hide, without CUA window sharing. Unused diagnostic and previous candidate
bundles were removed after runtime/consumer and hash checks; current app and
acceptance evidence remain. Personal acceptance is pending every checklist
item. No release or issue reply has been made for this batch.


Candidate 9 follows the maintainer's failed first acceptance item: Wide had about
107.5 pt above the title and 94 pt below the author at 871 x 795, and taller
windows expanded the unused paper. This is a title-canvas failure; the selected
preset remained Wide 24 rather than changing during resize.

The native title owner now recognizes margins from a marked reader stylesheet
separately from actual publisher/user declarations. Reader margins frame the
intrinsic semantic FB2/legacy cover group, normalized against Fit Page's scale,
while genuine authored spacing retains its paper. Pagination, image coordinates,
following-chapter text/search rectangles and source bytes remain unchanged.
The initial raw-padding implementation exposed three tall-window failures; it
was corrected rather than loosening their visual-gap assertions.

The new complete related run passes 271 distinct tests (266 App, 5 Quick Look),
0 failures and 0 skips, in `title-margin-full-recheck.log`. Its 18-case original
Alice FB2/MOBI matrix spans all three presets and 900 x 650, 871 x 795 and
871 x 900 windows. Wide's top geometry is 56 pt throughout; FB2 bottom ranges
41.77-42.36 pt and MOBI is 40 pt. These are native geometry measurements, not
physical ink-edge measurements or personal acceptance. Candidate 9 is built,
ad-hoc signature verified and loaded, executable SHA-256
`8fc46c8ad547d10d8543632af8771c85e69aaf26bd0879243d56b3c342ff0536`.
Real pointer-driven captures were interrupted by foreground/pointer changes and
are not acceptance evidence. The user has been asked for one quiet interval to
complete the actual resize, preset and hover comparisons. Item 1 remains failed
until its repaired candidate is visually checked, then awaits the maintainer's
retest. No issue reply, release, settings migration change or official install
has been performed. The unused candidate 8 bundle was removed only after exact
hash, prior PID termination and open-consumer checks; source/fixture/evidence
files remain for acceptance.


Candidate 9 actual verification is now complete for this spacing repair. The
three presets were selected and values read in Reading Settings. Real snapshots
show Wide ink-edge gaps changing only from 65/46 pt at 871 x 795 to 66.5/46.5 pt
at 871 x 900 (font-ink bounds, distinct from the fixed 56/40 layout budget).
Three native drag rounds produced 39 valid PNGs; requested endpoints differ
from AppKit's observed sizes, which are preserved in the log. This is visual
geometry evidence, not a new frame-time benchmark. Ordinary and real fullscreen
four-state captures guard foreground, actual pointer and window bounds; all
reading-region pixel differences are empty in `candidate9-geometry.json`.

The first capture helper did not create its output directory, and screencapture
returned zero despite missing files. It was corrected to create the directory
and verify actual PNG existence, then the whole hover sequence was repeated.
Only the verified logs and PNGs count. A blocked fullscreen attempt was aborted
and repeated successfully. An early exit-fullscreen probe ran before the Space
transition ended; the final ordinary-frame receipt confirms the settled exit.
No such probe failure is counted as a product pass or a product crash.

The candidate is left in Alice FB2, Two Pages, Cover on Its Own, Light, Wide24,
Auto Hide, 871 x 795. Initial relaunch used implicit Custom32 because reading
position memory is disabled; that initial image is not the Wide comparison.
The visible selected Wide state was explicitly restored for handoff. All mouse
operations stopped before evidence analysis. Personal item 1 awaits maintainer
retest; no other personal box was checked and no issue reply/release was made.


Candidate 10 addresses the maintainer's next feedback after accepting Wide
margins: the percentage sat inward in a wide empty left slot, while the page
label was near the right edge. The maintainer chose a wider track and fixed
outer padding. Only the existing floating footer layout changes: capsule width
472 pt, inner padding 12 pt at both ends, stable 42/84 pt text slots aligned
outward, slider filling the middle, and 16 pt external gutters in narrow windows.
Height 26 and bottom inset 6 remain unchanged; native nonfloating footer layout
and all progress/navigation calculations are unchanged.

35 related tests pass with no failures or skips in
`progress-spacing-final-verified-tests.log`. The new rendered test checks both
ink edges, an expanded middle track, small/large windows, page-digit changes and
0/50/100% drag previews without movement or premature navigation. Initial harness
attempts used a SwiftUI accessibility tree unavailable in an unobserved hosted
window; this was replaced by actual rendered-pixel inspection. A mistaken edit
to a similar pre-existing test loop was reverted, and the complete related batch
was then rerun successfully. These harness failures are retained and are not
reported as product passes.

The built/ad-hoc-verified candidate is loaded, executable SHA-256
`3fb81733e91229cd0c2b6447914d28a27dc6e3325a1ffc57b3f5acdb5a720706`.
Actual ordinary-window AX frames confirm a 298 pt slider (previously 172), left
text 12 pt from the capsule's edge and right text 12 pt from the other edge.
`candidate10-normal-footer.png` is a direct screen-region capture. Book geometry
matches the accepted 871 x 795 scene; raw comparison has 708 pixels differing by
at most 2/255 in a 2,396,992-pixel reading region, and is not claimed bit-identical
across candidates. The initial drag probes found a hidden footer, then a reading
position changed to Page 2, and finally actual pointer interference; none counts
as a completed drag. A single 30-second quiet interval is pending for the real
drag, narrow/fullscreen checks and final handoff. The unused candidate 9 bundle
was removed after hash, terminated-PID and open-consumer verification; current
candidate and acceptance evidence remain. No issue reply or release occurred.


Candidate 10 final real verification completed after the maintainer supplied a
quiet interval. The native control was dragged from its current 8% to 0%, then
54% (Page 8/14, the correct nearest whole-page result for a middle drag), 100%
(Page 14/14), and back to the cover at 0%. All four control frames remain exactly
(565.5, 836, 298, 20). Pointer and foreground guards passed. An initial narrow
capture detected a pointer change and was discarded; it was repeated successfully.
The ordinary 871 x 795, narrow 560 x 500 and real fullscreen 1728 x 1084 captures
all show a 298 pt slider and exactly 12 pt text padding at both outer edges.
Fullscreen exited successfully. Final receipts and direct region screenshots are
in `candidate10-final-acceptance.json` and matching scene files. The reader is
left on Alice's cover, Wide24, Auto Hide, 871 x 795. All mouse operations stopped
before analysis; the current candidate remains for personal footer acceptance.
No additional source changes or test repeats were needed. No issue reply/release.


Candidate 11 fixes live main Settings rather than only the per-book Aa panel.
Explicit global edits publish only changed reading fields to every registered
reader; restoration no longer writes book layout back into global defaults.
Field revisions preserve unedited legacy overrides while rejecting stale fields
after a global edit. Later per-book Aa settings remain restorable. Native PDF
form drafts finish their existing commit boundary before layout and revision
acknowledgment. Opening policies retain their operation-time semantics.

Final related release test run: 307 App and 5 Quick Look tests pass, zero failures
or skips (`settings-live-final-recheck.log`). It includes multiwindow live edits,
field independence, old/inflight restore snapshots, Remember on/off opening and
a new pending-form global-layout test. A flaky simulated-fullscreen test now
uses a fixed attached-menu height rather than sampling a changing system value;
its strict viewport and passage assertions remain. Earlier failed fixture runs
are retained and are not counted as passing evidence. Localization audit passes
all 25 catalogs with 701 inventoried keys and no missing keys.

Actual candidate UI: main Settings stays open while FB2/TXT/HTML update for
margins, size, line height, font and flow. New MOBI reads the edited defaults
(system, 20 pt, 1.8 line height, Medium16, continuous), confirmed in its Aa panel.
AX-only font value replacement did not send an editing event and is excluded;
real text input confirmed both Georgia persistence and changed rendered glyphs.
All six category icons render with Chinese labels; Advanced explains immediate
appearance/layout and opening-time options. Original preferences and private
revision markers were restored, then the same bundle cold-launched again.

Current executable SHA-256: `fc49a3b7f8016a15f39df88ff011c20deb4bf6d730ef4b5e44e7c3e7bc0b82fb`.
Final PID 3526, Alice FB2 and Reading Settings remain for personal acceptance.
Current Medium16, system17, line1.6, paged/spread/cover, Auto Hide.
Test fixture windows and files are retired; owned previous candidate 10 removed
after exact hash and open-consumer checks. An accidental default-app file open
started Koodo; its Alice window and that exact newly started process were closed
gracefully. No file association change, issue reply, publication or personal
acceptance claim. Screenshots and scope receipts remain until acceptance.


Candidate 12 addresses the newly reported progress-slider flicker. Real capture
proved mouse-up briefly restored the old progress before the renderer committed
the target: blue-rail endpoints 1031→884→985 and 587→985→581. The former endpoint
acceptance missed these intermediate frames. The footer now retains a pending
seek preview until its own queued command completes, and a newer seek is not
cleared by the earlier completion. Returning to the still-visible old page while
a seek is pending also queues the new intent. The existing RasterReader request
owner now acknowledges continuous progress only on consume/cancel/replacement,
including mutations before a SwiftUI redraw. No timers/retries were introduced.

Valid current test evidence: 220 distinct App tests across the first 121 passing
cases, 98 nonoverlapping reader regressions and 3 final new tests (2 overlap).
The first batch's one failed native event fixture assumed local NSEvent delivery
could move the real pointer; its replacement tests the actual native tracking
callback lifecycle only. Strict seek completion and second-seek assertions stay.
Real pointer displacement and painting are separately exercised through CGEvent
and ScreenCaptureKit. Continuous tests check measured fraction at completion and
immediate cancellation without hanging the command queue.

Main-screen ordinary slow/fast/endpoint drags, real fullscreen, and continuous
slow/fast drags completed. Final ordinary and continuous captures retain all
complete frames at requested 60 Hz: 128 and 140 frames. Presentation timestamps
are used for phase alignment; frame delivery time is not painting time. Final
checks have stable control frames, no AX reversal, no painted return to the old
position, and matching actual continuous scrollbar/slider fractions. Earlier
4ms input-delivery assumptions and one previous-point cursor lag were rejected
probe runs and are not counted. Earlier occasional old AX reads had no captured
paint reversal and are not claimed monotonic.

Executable SHA-256 `cabd50401e58b420d702098e21f6ffd6894b965ee5e158ac56130610221c6232`, loaded PID 44066, normal
871x795 at (70,90), Alice Page8/13. Global preferences match the pre-test snapshot
exactly. Owned candidate11 retired after hash/PID/lsof checks. Current preview
and necessary frame evidence remain until personal acceptance; no issue reply
or release. A separate unlocalized first-open-at-launch observation is retained
in the acceptance notes, not claimed fixed by the footer work.


Candidate 14 completes the latest issue-content audit. Body and all 15 comments
were read and compared twice, most recently 2026-10-28 13:10 UTC; no changes or
new comments were found. The reported page-divider controls already applied to
the reader, but the compact theme preview omitted the divider. The production
preview now draws both pages and the chosen divider, retaining text/link colors.
The same live editor redraws red → green → hidden immediately in the actual
dialog; cancellation preserves the original custom-theme list and selection.

102 distinct related App tests have final passing evidence: 101 in the batch
plus the new pixel test after its color-space fixture correction. The failed
cache/calibrated-color attempts remain in logs, excluded from passing evidence.
The final test draws in explicit sRGB and reads original samples, preserving
exact red/green/hidden and both text/link assertions. Localization audit passes
25 catalogs, 701 inventoried keys, zero missing. Presentation documentation now
matches the existing strict hidden-toolbar behavior; no product mode changed.

Actual final candidate checks include Settings/Home live dark/light, a newly
opened MOBI adopting dark, and existing FB2/MOBI adopting light. Home uses its
native toolbar and tabs, with no reading overlay. Real CGEvent tab switching
MOBI → Home → FB2 retains usable controls with no further pointer movement.
Closing the visible selected middle MOBI from three tabs reflows the remaining
two immediately: 120 ms and 720 ms AX positions match. Pointer/focus guards pass.
An earlier close probe targeted an offscreen clipped button and is excluded;
the repeated probe first brought the target into view. Accessibility activation
alone did not move the physical pointer and is not counted as real hover proof.

Diagnostic candidate 13 observed successful first requests for cold, immediate
reopen and windowless-process file opening (3.05/2.35/2.60 s). The earlier isolated
Home-only observation did not reproduce. No startup delay/retry/behavior patch
was added; content-free temporary event logs were removed and candidate 14 was
rebuilt. Its first explicit file open also displayed Alice successfully.

Final executable SHA-256:
`91f260c6ad3a4445d2e16162746b570cc8eaface9511ade79738575f7f66ba52`.
PID 20092, main-screen Alice8/13 at (70,90), 871x795; Reading Settings at
(1000,150), 500x620. Medium16, Light, system17, line1.6, paged/spread/cover,
floating and Auto Hide match the pre-test preferences. The toolbar, footer and
Pages owners match candidate12; no new performance measurement is claimed.
Old task-owned candidate12/13 bundles were removed after hash and lsof checks;
unrelated previous bundle remains. Build/test/log-stream/probe processes ended.
Only current preview and required evidence/fixtures remain for personal
acceptance. No issue reply, release or automatic personal acceptance marking.
