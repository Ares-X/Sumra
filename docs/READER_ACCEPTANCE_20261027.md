# Reader acceptance — 2026-10-27

The subsequent [0.2.20 release acceptance](RELEASE_0_2_20_ACCEPTANCE_20261027.md)
records completed publication, official installation and issue replies.

For the subsequent interaction/performance round, see
[the follow-up record](INTERACTION_POLISH_20261027.md). The executable and visual
receipts below identify this earlier checkpoint specifically.

Local 0.2.20 candidate; personal acceptance, signed-candidate acceptance and
publication remain pending. No issue reply has been sent for this candidate.
This record supersedes earlier local title-spacing screenshots, not the
historical signed 0.2.19 acceptance in [the issue 42 report](ISSUE42_FOLLOWUP_ACCEPTANCE_20261026.md).

## Reading space and controls

The maintainer rejected both excessive title-page margins and the subsequent
overly tight fit. Eligible FB2/MOBI first-title canvases now use cached content
bounds while preserving explicit publisher margins, padding, borders and
ordinary body pagination. The reader reserves native toolbar/tab space in all
modes, independently of hover. Fullscreen additionally reserves the native
system-menu height. A real top-edge check found that omitting this extra height
covered the title even though ordinary toolbar hover passed; that boundary was
fixed and retested on the physical M27Q display.

The native menu's fullscreen companion remains available for Close/Zoom, while
Always Hide and presentation suppress reader tools and tabs. The prior
implementation incorrectly revealed them when the system menu appeared.
Regression tests fail against that prior behavior. System fullscreen Minimize
remains unavailable according to AppKit's normal policy.

A 30-point footer provides restrained bottom space in ordinary reading,
including fullscreen. Hover or keyboard focus reveals percentage, position and
a native slider. Its height is unchanged when hidden. Dragging previews the
destination and commits one navigation on release. Keyboard and accessibility
increments use the renderer's position step. A document replacement cancels the
old drag's navigation.

The final GUI check caught a horizontal slider shift when the percentage or
page label changed width. Fixed-width label columns now keep the native slider
stationary; a hosted test covers 560/1,000-point windows and forward/reverse
previews. The final loaded app also passed a real first → last → first drag.

PDF/comics use physical pages, text uses source lines, and browser content uses
scroll progress within the current file. Incomplete native pagination is
explicitly approximate and reports chapter/local-page positions without a
fabricated total. Seeking resolves only the target chapter, including its
actual final page at 100%, without paginating unrelated chapters.

## Generated PDF refresh — issue 48

[Issue 48](https://github.com/Ares-X/Sumra/issues/48) describes a source PDF being
replaced during snapshot capture by a Typst/LaTeX build. An actual atomic
replacement during the streaming-copy path reproduced the exact reported
failure before the fix. A typed source-change error now retains the displayed
document and opening position/history, renews observation and schedules a retry
using the existing 250 ms debounce. Generation/cancellation and edit revision
checks prevent a stale retry from replacing a newly opened or edited document.
Malformed PDFs, passwords, missing files and permission failures retain their
normal error handling; the retry is specific to a detected source change.

Seven new tests use real file replacement, not a production test hook. They
cover repeated replacements, initial opening intent, old-document retention,
close/new-file cancellation, deletion, unsaved edits and distinct open errors.
Seven existing PDF-source tests and four existing lifecycle checks also pass.

## Integrated validation

The current affected suite covers 130 unique tests: toolbar/fullscreen/native
tabs, footer, browser reading modes and asynchronous lifecycle, PDF capture and
reload, reader lifecycle, native viewport, title fitting, pinch anchors, search
reflow handoff and Quick Look book rendering. The first run passed 126 with four
original-fixture tests skipped due to omitted fixture environment variables;
those exact four then passed with the original reporter files configured.
There are no remaining skipped cases in that selected scope. This is not a
rerun of the earlier 1,262-test gate.

After the label-column correction, all nine footer tests passed, including one
new frame-stability regression. Thus 131 unique cases are covered across these
runs; the 130-case integrated run preceded that final presentation-only change.

The toolbar viewport test spans paged/continuous × one/two native tabs ×
Shown/Auto/Hidden/presentation, including normal → simulated fullscreen →
normal and native-menu reveal. Actual fullscreen behavior is checked separately
through the GUI. Pinch tests exercise the production gesture handler; they do
not establish physical trackpad acceptance. All 25 localization catalogs pass
syntax/placeholder/coverage audit; the five footer strings are translated in
all 24 non-English catalogs.

Evidence: `build/fb2-whitespace-20261027/` contains the title/native and earlier
fullscreen boundary evidence. `build/reader-footer-issue48-20261027/` contains
`integrated-tests.log`, `original-fixture-followup.log`, the fail-before PDF log,
localization audit and final app build. Final loaded-app receipts and visual
handoff are recorded alongside those logs.

## Loaded candidate and visual acceptance

The final local release-configuration app at `dist/Sumra.app` is version
0.2.20 (22), ad-hoc signed, with executable SHA256
`2f71de8c7f48f17e4ea375deb12b231f4ab691ad2f11962d00b632f3b048ce9c`.
Its bundled MuPDF SHA256 is
`3d4050f05b88ea835d05b62a8c1f6545cdfc5ceaced79914176db463fef27282`.
Deep/strict code-signature verification passed. This does not establish
Developer ID signing, notarization or Sparkle delivery.

On the physical M27Q display, the final app opened the original Alice FB2 in a
1,000 × 800-point normal window. Actual pointer input revealed the bottom
control; dragging reached page 8/8 at 100%, then returned to page 1/8 at 0%.
The returned title page is pixel-identical to its initial rendering. Toolbar
and footer shown/hidden comparisons are pixel-identical across the book area
(x 0–1,000, y 40–770). In actual fullscreen, the native menu and toolbar leave
the title visible, and pixels below y=84 remain identical through reveal. The
native menu shadow changes some pixels above that boundary without moving the
book. Fullscreen footer reveal was also visually inspected.

The immediately preceding local executable
`5cacb47250e454ceb362386b6448f6fb19796c05e5fdf2447e35109e7eb77e84`
passed actual normal/fullscreen two-tab reveal checks and generated-PDF
refresh: seven atomic replacements at 150 ms intervals ended at BUILD 8,
page 7/12, with no error and no loss of reading position. Those PDF/tab paths
are unchanged in the final executable; only footer label widths changed.
`pdf-footer-back.png` records the pre-fix reverse-drag attempt and is not a
passing acceptance screenshot. Final forward/reverse evidence is in
`final-fb2-end.png` and `final-fb2-back.png`.

The final normal-window FB2 remains open for the maintainer. Functional reading
preferences match the pre-test snapshot; only the last Settings tab selection
and Go-to-Page dialog geometry differ. No analysis/build/test worker remains.
The live reader is intentionally retained for personal acceptance.

## Remaining delivery boundaries

Personal visual acceptance precedes release and replies. Official signed
0.2.20 installation/update/provider acceptance has not occurred; the installed
official app remains 0.2.19. Physical trackpad input, the optional coverless EPUB
Finder-thumbnail route and the broader dense-search latency goal remain
distinct from the fixes above. The earlier 9.44 s normal / 13.33 s resized
6,591-match search measurements are unchanged historical evidence, not new
measurements of this footer build.
