# Native GUI acceptance

Use `python3 scripts/test-gui.py` for the managed entry point,
including bounded recording, candidate identity, result extraction, and cleanup.
See [the current release acceptance](../../docs/RELEASE_0_2_23_ACCEPTANCE_20261101.md).
The commands below are low-level build/debug commands; their caller owns cleanup.

This standalone XCUITest project attaches to the already-running candidate at
`SUMRA_GUI_APP_PATH`. It does not build Sumra, launch/relaunch it, terminate it,
or open private documents. Targeted journeys may temporarily change reading-control
settings and restore their declared baseline. Use a disposable macOS login
for a clean acceptance run when available. Xcode must have UI testing permission.

The first journey uses File > New Sumra Window to create its own Home window,
then its Open Document button and a real Open panel (Go to Folder) to read unique temporary copies of
`docs/demos/Reading-Notes.md`. It exercises real pointer hover over New Tab,
canceling a tab's Open panel, adding and closing a native tab, and opening the
contents sidebar. It checks the original document/window count survives cancel
and close, and verifies a chapter is present in the sidebar's accessibility tree.
Screenshots support human visual review; these assertions do not prove appearance.
Two further journeys exercise fullscreen tab cancel/add/close and fullscreen exit,
and native corner resize plus dragging the document titlebar. Each checks the actual
window frame before claiming the action occurred, restores the normal frame,
and saves named phase screenshots for review. Phase diagnostics print epoch and
uptime timestamps so the native video can be inspected around each transition.
Run one method per acceptance run; all methods inherit the 120-second test limit.
Runtime results are recorded separately from compilation. Fullscreen starts
from a normal window and verifies keyboard entry materially expands both frame
dimensions, then verifies exit restores the original geometry. Native video and
independent host observation supply visual/native-state review. It does not
compare window bounds with the full physical display. Teardown tracks only its
own fullscreen request and exits an expanded owned window before closing it.
Resize first widens the existing window, then restores its original narrow size.
It needs at least 80 points of available growth on the current display. A constrained or ineffective
drag fails its frame assertion; it does not count as exercised. Cursor shape,
page clipping, and transition jitter still require reviewing native video/images.
Manual tab dragging, printing, and real user files are not exercised.

`NativeFixedPDFChromeAcceptanceTests/testOpenPDFChromeHoverAndFullscreenRoundTrip`
attaches to an already-open public PDF named by `SUMRA_GUI_WINDOW_TITLE`. It
verifies actual native toolbar hover and a native View-menu full-screen round trip, then leaves
Auto Hide selected without closing the document. Set `SUMRA_GUI_START_FULLSCREEN=1`
only when the prepared window is already full-screen. Select this class directly
with `xcodebuild -only-testing`; the managed script selects the Journey class.
The test checks that the prepared reader is active, focuses its page field
without changing the page, and uses the enabled native View > Toggle Full Screen
command. It reactivates Sumra after a full-screen transition before sending
pointer input, so another application's existing window is left untouched.
This fixed-PDF journey currently uses Chinese reading-control/full-screen labels;
prepare that language rather than assuming it is language-independent.

For signed 0.2.23 (25), the cover-page keyboard round trip passed on macOS 27.0.1.
Scrolled-text keyboard attempts failed during XCTest event synthesis, without
evidence that the app's shortcut handler ran. After focus checks, the native
View-menu round trip passed; its four phase captures and a later stable body
capture were reviewed. The menu pass does not validate keyboard injection in
that scrolled-text state. The exact-bundle macOS 26.6.2 guest separately covers
hover reveal/body dismissal, not a guest full-screen round trip. See the linked
release acceptance for candidate identity, receipt paths and publication limits.

`testNativeTabAndOverviewEntries` and
`testFullscreenNativeTabAndOverviewEntries` additionally exercise the native tab
bar's lowercase `new tab` button and the native All Tabs overview's `New Tab`
button. Each entry is cancelled once and used to open a real public fixture;
closing its unique added document must return to the original. These use the
observed AppKit View command identifiers and native accessibility labels, distinct
from Sumra's localized toolbar control. The native tab bar is changed only in the
test-owned document window.

`testAIAndPaletteLayout` uses the native divider and window border to verify AI
input/button geometry at a measured minimum sidebar width and a narrower window,
then closes and reopens the sidebar. It does not enter a question or send an AI
request. It reveals the actual progress footer and checks that both AI action
buttons remain above its interaction row; window containment alone is insufficient.
The same journey clicks the command palette row's verified right blank
region and requires the native Page input alert before cancelling it. `ai-*` and
`palette-*` phase screenshots support visual review. See the acceptance receipt
for each candidate's actual result. Activating a command uses the app's normal
palette-MRU update, even when the subsequent Page dialog is cancelled.

`testEPUBSpreadResize` accepts an EPUB through the runner's `--fixture` option.
Temporary fixtures preserve the source extension. The journey explicitly selects
Single Page followed by Two Pages, records the initial native Cover menu,
toggles Cover once for the resize phase, selects Fit Page and the first page,
then drags the native window border wider/taller and back. It preserves before/wide/restored PNGs and native
menu-state screenshots, then toggles Cover again and captures the separate cover.
AppKit does not expose its menu checkmark through XCTest value/isSelected here.
Visual review must confirm initial Cover ON, Cover OFF with two blue pages during
resize, and Cover ON again; these Boolean states are not automatically asserted.
Window-frame assertions establish actual resizing; page aspect ratios and common
scaling also require inspecting the retained images/video. This method is intended
for the anonymous blue-page `latest-C.epub` acceptance fixture.

Existing user windows are retained. An existing Home window blocks the test
because Open would reuse it; only set `SUMRA_GUI_OWNS_INITIAL_HOME=1` when that Home
was created for this run and may be closed. The test closes its unique document
tabs, removes its unique Recent items through their native Forget actions, closes
its Home window, then deletes its temporary fixture directory. If an owned window
or history cleanup fails, it retains the fixtures and reports the path. It never
quits the app or clears other recent documents.

The 2026-11-01 floating follow-up exposed XCTest's implicit interruption handler:
it answered eleven pre-existing CoreServicesUIAgent dialogs during a test action.
The run is rejected and its exact actions are retained in `interruption-audit.json`;
dialog titles and effects could not be recovered from that XCTest log.
Setup now checks that system agent's existing dialogs before activating Sumra.
An unexpected runtime interruption records a failure, with `continueAfterFailure`
disabled, instead of clicking any answer; teardown also avoids UI after that
failure. These entry changes require independent runtime verification before
claiming the interruption boundary is validated. No system permission or
authentication configuration is changed by this code.

From the repository root:

```sh
xcodebuild build-for-testing \
  -project tools/GUIAcceptance.xcodeproj -scheme GUIAcceptance \
  -destination 'platform=macOS' \
  -derivedDataPath build/gui-acceptance-20261101/xcode

TEST_RUNNER_SUMRA_GUI_APP_PATH="$PWD/dist/Sumra.app" \
TEST_RUNNER_SUMRA_GUI_FIXTURE_PATH="$PWD/docs/demos/Reading-Notes.md" \
TEST_RUNNER_SUMRA_GUI_LANGUAGE="$(defaults read dev.aresx.leaf language)" \
xcodebuild test-without-building \
  -project tools/GUIAcceptance.xcodeproj -scheme GUIAcceptance \
  -destination 'platform=macOS' \
  -derivedDataPath build/gui-acceptance-20261101/xcode \
  -resultBundlePath build/gui-acceptance-20261101/native-journey.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:SumraUITests/NativeReaderJourneyTests/testOpenCancelAddCloseAndContentsHover
```

Xcode forwards environment variables prefixed `TEST_RUNNER_` into the runner,
removing that prefix. `SUMRA_GUI_APP_PATH` and `SUMRA_GUI_FIXTURE_PATH` are read by
the test runner, not Sumra. Forward the candidate's actual `language` preference
as `SUMRA_GUI_LANGUAGE`: XCTest isolates runner preferences, so its domain lookup
may differ from the host. There is deliberately no Target Application setting:
`XCUIApplication(url:)` selects the external candidate. Before execution, verify
its version/hash separately and start that exact app yourself. The test itself uses only XCUITest interaction and window geometry; it requests
no additional Accessibility grant or permission bridge.

The default `GUIAcceptance` test plan records native XCTest video and retains it
for successful and failed runs so the caller can inspect it. Its legacy-named
`uiTestingScreenshotsLifetime: keepAlways` setting generates the documented
`SystemAttachmentLifetime: keepAlways` setting in `.xctestrun`, together with
`PreferredScreenCaptureFormat: screenRecording`. The plan enables a 120-second
per-test execution allowance and maximum. Xcode 27 build-for-testing validated
these generated values. No additional screen recorder is needed.

Keep the result bundle and native video only through review and evidence export;
then remove raw media and the task-owned derived-data directory. The explicit
named phase screenshot attachments use `keepAlways`. Apple describes keeping
passing-run video in [WWDC25's UI automation session](https://developer.apple.com/videos/play/wwdc2025/344/),
18:55–19:26; `man xcodebuild.xctestrun` documents `SystemAttachmentLifetime`.
No generated artifacts belong in Git.
