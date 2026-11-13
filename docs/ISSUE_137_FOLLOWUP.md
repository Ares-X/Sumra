# Issue 137 and related reader follow-up

## November 13 reporter reply (0.2.40 candidate)

The [latest reporter reply](https://github.com/Ares-X/Sumra/issues/137#issuecomment-6839217736)
confirms responsive floating window controls, retained Home folders after errors,
and the fullscreen toolbar-mode correction in 0.2.39. Four reports remain:
zoom/scroll inertia, transient toolbar cutoff during fullscreen entry, ordinary
native tab widths after closing, and black Spaces when adding/duplicating tabs.
They have not all been resolved and #137 remains open.

The new change disables horizontal and vertical rubber-banding on finite raster
surfaces at their existing mounted-scroll owner. In-page native inertia and the
existing gesture/page-turn policy remain; continuous readers retain automatic
elastic scrolling. The previous wheel-handler correction could recognize an
elastic position, but could not stop an already-running AppKit rebound.

The mounted native-view regression covers mixed-axis pan ownership, a fresh
outward edge gesture, one turn through momentum, and continuous/presentation
remounts. It passes with the change and fails four assertions against the old
owner. The affected raster, pinch and viewport suite passed 79 cases and skipped
eight original-sample cases; no failures. Receipts retain preference/clipboard
isolation and unchanged source/engine checks.

On the existing macOS 26.6.2 Parallels guest, a local diagnostic candidate opened
the original `misalignedepubC.epub` at 200%. CUA drove actual reading-area wheel
input: page 2/4 panned vertically, stopped at the bottom, and the next downward
input advanced to 3/4. Right-arrow input also panned horizontally while retaining
page 2/4. Peekaboo's wheel dispatches initially produced no viewport changes;
those attempts are not acceptance. This virtual-wheel result does not reproduce
a physical trackpad's phased, mixed-axis strong inertia. Formal signed-candidate
acceptance remains pending.

Further investigation of the other three reports:

- Released 0.2.39 on the guest opened a fullscreen CBZ, duplicated from the first
  tab twice, and opened a CBR through the native new-tab file panel. All four
  documents stayed visible in one fullscreen group. Mission Control showed
  Desktop plus one Sumra Space. This does not establish reporter macOS 15.7.5.
- Original 60 FPS recordings show that selecting the reused first CBR already
  causes a black transition before Duplicate. The second clip uses the native
  right-end plus and Show All Tabs overview plus; both use ordinary controls.
  Those paths are recorded separately from the simpler loaded-document replay.
- The standalone AppKit comparison closes five native tabs to four. Their
  widths stayed 177/177/169/161 points through public accessory/frame-view layout
  and `window.update()`. Pointer exit changed them to 219/219/204/203. No private
  native-tab override was added, and the report remains open.
- A behavior-neutral fullscreen trace found no companion at willEnter; AppKit
  reparented controls afterwards. At didEnter the discovered companion was
  transparent with content alpha zero. Adding an earlier notification therefore
  has no demonstrated fix on this guest. Its capture tool did not produce an
  authorized high-rate movie, so brief transition clipping remains unverified.

Evidence and diagnostic overlays are under `build/issue137-latest`. Temporary
trace overlays are excluded from product source and release builds. #96's
separate Finder arrow-key limitation is unchanged; no reporter reply is sent.


## Remaining interaction pass after 0.2.38 (0.2.39 candidate)

The maintainer rejected the first native-policy candidate on macOS 27.0.1:
Hidden → Auto did not hide, and Mission Control showed an extra black blank
Space after fullscreen Home opened six formats and the first CBR tab was
selected and duplicated. A correct seven-window native group did not prove
that its Spaces were correct. The failed candidate, pointer logs and screenshot
are recorded separately under `build/issue137-remaining`.

The failed candidate kept reader content at full opacity and delegated hiding
to SwiftUI's `onHover` policy. That change has been removed. The replacement
resamples the stationary pointer after a toolbar-mode change, which clears the
old hover state without necessarily producing another mouse event. Floating
traffic-light glyphs also resample their actual visible pointer region after
tracking-area replacement and observed window updates. Native companion
ownership follows the captured button when AppKit reparents it; custom chrome
collapses the unused native accessory controller as well as hiding its pixels.

The first child was attached while the reused fullscreen Home was already busy
but still had native tabbing disabled; only afterwards did SwiftUI promote that
parent. Tab placement now synchronizes the parent's existing policy before the
native attachment, and the Host and live preferences share that policy owner.
The isolated regression fails against the old owner. This establishes the
ordering correction; the exact seven-tab guest replay below also checks Mission
Control. It does not establish behavior on every macOS release.

The minimal replacement passed 29 isolated pointer/mode, first-tab, native Home,
native tab-host/close and live-preference cases. The same stationary-pointer and
first-tab cases fail against their previous owners.

The broader window regression exposed a real hover-boundary error in that
replacement: on non-clipping AppKit views, `visibleRect` can extend beyond the
54-by-20 button group. A large-window fixture then considered an outside pointer
inside. Hover now uses the intersection of `bounds` and `visibleRect`; both the
original stationary-pointer zoom test and a non-clipping ancestor regression
pass. This is distinct from proving the system green-button popover.

The reporter's November 12 follow-up confirms the released rapid navigation,
mixed-axis pan ownership, Home labels/history and floating tab-close treatment.
It adds loss of the browsed directory after a failed Read Images as Pages action,
and delayed edge turns during strong scroll inertia. Home's loading view had
unmounted the browser and discarded its local directory, search and selection;
the candidate retains that browser under the existing loading indicator until
a document successfully replaces it. Its native search/grid responders now
honor the disabled state so repeated Return cannot open another hidden target
during loading. The mounted Home regression passes with query, folder, history,
loading-time keyboard input and subsequent successful opening checked.

The wheel handler had compared a constrained probe with an unconstrained elastic
position. It now probes from the constrained baseline. The mounted native-scroll
regression passes for the candidate and fails four assertions against the old
owner. A test-only clip places one out-of-range position, then uses AppKit's real
constraint method; this is not a physical trackpad/inertia acceptance claim.

### Independent VM interaction, November 12

At the maintainer's request, hover acceptance moved to the existing Parallels
macOS 26.6.2 guest, using its already-authorized Peekaboo bridge and local pointer
movement. Actual WindowServer delivery is evidenced by both rendered changes
and the candidate's mouse-coordinate logs. This avoids asking the maintainer
to perform every hover. It does not establish behavior on the reporter's
macOS 15.7.5 or the host's macOS 27.0.1.

The exact local diagnostic archive has SHA-256
`b00ee3084ab9d4b5c5b6ba6b942a2f865de8d6bae8b1436127c8495c9db1ea9d`.
The guest opened six original formats through the real fullscreen Home file
panel, selected the first CBR, and duplicated it into a seventh native tab.
Always Hide → Auto Hide with the pointer at the screen top revealed the complete
toolbar and seven tabs; moving only the pointer into the document hid them.
Mission Control then showed Desktop and one Sumra fullscreen Space, without
an extra black Space. Evidence is under `build/issue137-remaining/vm`:
`six-selected-final.png`, `seven-auto-top.png`, `seven-auto-body.png`,
`mission-seven-open.png`, and `seven-hover-tabs.log`.

Floating tab-close hover retained the parent tab highlight and displayed an
inset close-button background (`floating-close-hover.png`). A seven-tab
floating-toolbar fullscreen-entry capture did not show the reported rectangle
in its 32 captured frames. The effective capture rate was about 5 FPS, so this
does not exclude a shorter flash; the original frames and MP4 are retained in
`floating-entry` and `floating-entry.mp4`.

Normal-tab closing was reproduced: after seven tabs became six, their old width
remained until the pointer left the tab bar (`native-gap-six.png`). A separate
pure AppKit app with no Sumra code, SwiftUI, toolbar or delegate proxy reproduced
the same five-to-four behavior and expanded on pointer exit
(`native-control-four-stationary.png`, `native-control-four-leave.png`). This
locates the observation at the native tab bar; it does not prove Apple's intent
or justify a private-API layout override.

The floating factory green button did not show the system tiling popover in the
initial candidate, while Home and normal native titlebar controls did. A
standalone AppKit control excluded target-assignment timing, repeated updates
and hidden originals. The real document's whole-surface SwiftUI shadow wrapped
the native buttons in an extra graphics effect view. Root hit testing still
reached the actual green button, so click-routing unit tests did not detect it.

Removing only that shadow restored the popover. Reinstating it with the corrected
hover bounds reproduced the failure (`green-bounds-only-dwell.png`). Moving the
same shadow to the rounded background restored both the visual shadow and the
native system menu (`green-background-dwell.png`, `green-background.log`). The
menu also opened after fullscreen entry. After dismissing it, moving the pointer
between the screen top and reading area revealed and hid the floating controls;
see `background-top-center.png` and `background-hidden-from-center.png`.
The final affected local regression run passed 109 cases and skipped one
SDK-dependent native title test, with source, preferences and clipboard isolation
verified (`tests-release-window/receipt.json`). Formal signed acceptance is recorded below.

The guest initially showed file information instead of loading the candidate
preview. After moving the candidate into `~/Applications` and opening it through
Finder, the candidate extension ran from that exact path (PID 61232 and the
`loadView` log). It rendered Recovery.cbz, advanced to 2/3, retained that page
and enabled controls after corrupt 03.png failed, then returned to 1/3 through
Previous. Evidence: `preview-corrupt-next.png`, `preview-recovered.png` and
`preview-routing.log`.

After a physical click, the preview page was its key window's first responder.
Neither the Peekaboo Left key nor Parallels' virtual keyboard Left reached any
observed extension keyboard handler or navigated. Parallels Down changed the
Finder selection and preview to the neighboring CBR, establishing host keyboard
delivery. Adding arrow key equivalents to the buttons did not fix this route;
the experiment and temporary routing logs have been removed from product code.
The existing failed-page recovery is unchanged; Finder keyboard routing remains
unresolved. No global event interception or private panel takeover was added.

Finder loaded the exact local routing diagnostic. A physical click focused the
preview page, but the maintainer's physical Left key did not navigate and did
not reach page/root keyDown, key-equivalent or command handlers. Button recovery
from 0.2.38 remains separate from this unresolved keyboard path. Neither issue
is closed, and no reporter replies are part of this task. The retained diagnostic is separate from release source.

Baseline: main `88ab0b8b7898fa867215b46d381eb1288094c39b`, installed
0.2.37 (39), arm64 macOS 27.0.1. The reporter of
[#137](https://github.com/Ares-X/Sumra/issues/137) uses macOS 15.7.5.
These are different runtime environments. No reporter comments are part of
this task.

## Signed 0.2.39 acceptance, November 12

The accepted app is build 41 from source
`c928c9a875f8a46b9c1ed49ddd9e906f27b340e6`, built by
[release run 43236590415](https://github.com/Ares-X/Sumra/actions/runs/43236590415).
Its ZIP SHA-256 is
`b20d5b01c76acc2ce679cd304573f225d5d045fe47eac374e9aa029b339ea051`;
the accepted SHA256SUMS digest is
`fbe23267a8acadefcb12f0877766fd2cdc429eda24a14441fc01d7db012737f2`.
All asset checksums, 140 app files, five app symlinks, 632 allowlisted tracked
source files, the existing certificate, deep strict code signature and Sparkle
Ed25519 signature passed. Repository metadata outside the existing source-export
allowlist is recorded separately, not represented as compiled source.

The exact ZIP was transferred into the macOS 26.6.2 guest and its checksum and
signature rechecked. Actual pointer movement, GUI file panels and native menus
established the following on that guest:

- Fullscreen Home opened CBR, CBZ, AZW3, EPUB, FB2 and MOBI together. Selecting
  the first CBR and duplicating it produced seven tabs. Always Hide → Auto Hide
  with a stationary top pointer displayed the complete controls and tabs;
  moving only the pointer into the page hid them. Mission Control showed Desktop
  and one Sumra fullscreen Space, with no extra black Space.
- Floating green-button system menus appeared both windowed and fullscreen.
  After dismissing the menu, moving to the neighboring folder button cleared
  the traffic-light symbols. Clicking the green button entered fullscreen;
  moving into the page hid the floating controls. The keyboard shortcut exited
  fullscreen. System-menu dismissal by pointer alone is not claimed.
- Read Images as Pages on the books-only fixture directory produced the explicit
  supported-image error, retained the folder after dismissal, and allowed its
  CBZ to open directly from the retained browser.
- Finder loaded the signed preview from the task app path (PID 62832). Recovery.cbz
  advanced from 1/3 to 2/3, retained 2/3 with an explicit error for corrupt 03.png,
  and returned to 1/3 using Previous. This does not establish arrow-key routing.

Evidence is retained under `build/issue137-remaining`: release
`signed-verification.json`, `tests-release-window/receipt.json`, and the VM
`signed-*` action receipts and screenshots. The source commit remains unchanged;
this later documentation update records acceptance of those already-built bytes.
Reporter macOS 15.7.5, physical trackpad inertia, sub-frame transition clipping,
native tab width behavior and Quick Look arrow-key routing retain the limits
above. Both #137 and #96 remain open.

## Original-report checklist

| Reported behavior | Investigation and acceptance boundary |
| --- | --- |
| Floating traffic-light hover glyphs stick or fail to appear | Actual pointer resampling covers tracking and window changes, bounded to the controls' visible intersection. The whole-surface shadow also prevented the system green-button menu; moving the shadow to the background passed the guest native-menu comparison. Tests and guest evidence remain separate from reporter macOS 15.7.5 acceptance. |
| A rectangular surface briefly covers the floating toolbar during fullscreen entry | Original recording inspected, including its larger multi-tab case. Stable screenshots after fullscreen entry do not establish transition-frame correctness. No verified fix yet. |
| Normal fullscreen toolbar is blank after Always Hide → Auto Hide while hovering | Replayed the mode change on the installed version. The companion background was restored to opaque while its content remained hidden. The candidate now hides both together; a native-window ownership test fails against the old code. The replacement passed the seven-tab stationary-pointer mode change, reveal and hide on the macOS 26.6.2 guest; host/reporter OS behavior remains separate. |
| Floating tab close hover fills the whole tab and breaks the shared hover surface | Candidate keeps the 28-point target, uses an 18-point visible close background, and makes the tab own hover across its close target. The guest visual hover check passed; see `floating-close-hover.png`. |
| Closing a normal tab leaves a gap until the pointer leaves | Reproduced in Sumra and a standalone AppKit tab group on the guest. No private native-tab layout override was added; reporter macOS 15.7.5 behavior remains unverified. |
| Adding or duplicating fullscreen tabs leaves black Spaces | Two installed-version duplicate actions joined the existing group and displayed their documents. Lifecycle logs confirm group counts two and three. The replacement exact seven-tab guest replay showed only one Sumra fullscreen Space; this does not establish reporter macOS 15.7.5 behavior. |
| Zoomed image EPUB panning unexpectedly turns pages | Candidate checks both scroll components and retains pan ownership through one phased gesture. The mixed-axis native-host regression passes with the fix and fails against the old wheel handler. The signed app pans within the original EPUB page at 200%; physical mixed-axis trackpad delivery remains unexercised. |
| Home buttons do not clearly distinguish browsing from reading images | Candidate distinguishes Browse Folder, Recent Documents and Read Images as Pages; all 25 localization catalogs updated. Local layout and signed-app browsing, Recents reopening and supported-format errors passed. |
| Browsed folders do not immediately appear in Recents | Candidate records successful browsing with its destination intent, preserving image-reader intent for previously read folders. Recent menus and context actions must honor the same intent. |
| Empty image-folder error does not explain supported formats | Candidate derives the list from the existing image-format owner. English/Chinese error and history-policy tests passed in the first focused run. |
| Rapid image-folder/CBZ navigation reverses progress | Released in 0.2.37; reuse the scoped evidence in [Issue 138 acceptance](ISSUE_138_ACCEPTANCE.md). |

## Related issues

- [#135](https://github.com/Ares-X/Sumra/issues/135): same-topic CHM and
  same-page PDF bookmark identity and order. Include real CHM/WKWebView
  scrolling, RTL offsets, and the existing PDF coordinate migration boundary.
- [#136](https://github.com/Ares-X/Sumra/issues/136): preserve a CHM default
  homepage fragment on the actual first-open path. The test must mount
  `BrowserReader` through SwiftUI; passing `nil` directly to its coordinator
  misses the production path's nonoptional current position.
- [#96](https://github.com/Ares-X/Sumra/issues/96): failed-page state/button
  recovery already exists. The shipped clicked-page focus change does not make Finder forward the
  arrow keys. Signed-host and guest diagnostic checks confirm this remaining
  boundary. Do not count button recovery as keyboard acceptance.

## Evidence

Original attachments, desktop snapshots, preference recovery data and local
test receipts are task-owned under `build/issue137`. The focused Home, zoom routing, PDF/CHM bookmark, CHM homepage and existing
PDF-coordinate/reading-position regressions passed. Old-owner overlays fail
for mixed-axis page routing, PDF/CHM same-page bookmark identity/order and
first-open CHM anchors. Initial test-fixture failures are retained separately;
they are not product acceptance evidence.

The first Quick Look focus test failed; declaring a focusable page alone was
insufficient. The clicked page now explicitly takes focus in its mouse handler,
including the first click into an inactive preview. The test sends the click to
the hit-tested view and then keys through the native window. It does not prove
Finder's remote-view routing; the signed-extension GUI result is recorded below.

During baseline testing, file selection in a fullscreen `NSOpenPanel` left its
Open button disabled. A separate minimal AppKit app reproduced the same
windowed/fullscreen difference using the same file and panel configuration.
This is not established as a Sumra-specific defect and no workaround was added.
The probe was quit after the comparison.


## Local desktop follow-up

The local 0.2.38 development bundle uses the installed 0.2.37 native engines.
Home browsing, immediate Recents, reopening a browsed folder, and the explicit
supported-image-types error were exercised through the UI. The CHM homepage
anchor is visible on first open in paged/spread mode. With a fixed continuous
viewport, same-topic bookmarks restore distinct scroll positions; toggling the
current one removes it without removing the others.

PDF same-page bookmarks restored distinct vertical positions, but this GUI
check found a further failure: a saved X coordinate of `157.20000000000002`
returned as `157.20000000000005`. Exact equality then opened Add Bookmark
instead of removing the existing bookmark. The first private candidate run
was cancelled before publication. The follow-up compares PDF positions through
the current page transform at device-pixel precision and preserves exact sort
order. Its native-host test explicitly models the observed one-ULP storage
representation difference after a real viewport restore; it does not claim that
the fixture naturally produces that difference.

Small single-axis scrolling on the original `misalignedepubC.epub` at 200%
moved within the page without changing its page number. A real mixed-axis
trackpad gesture remains unexercised: the maintainer was unavailable to perform
it, and CUA only exposes single-axis scrolling. The maintainer also reported
that the earlier fullscreen auto-hide check did not hide automatically; the
new backing fix is not sufficient evidence that this interaction is resolved.


The follow-up local bundle passed the original PDF failure path: reopening the
saved position and toggling removed its bookmark without an Add dialog, while
the other same-page bookmark remained. Previous and Next moved between the two
positions on page 1/8 (native vertical scrollbar values approximately 0.152 and
0.760 after restoration). All three focused PDF bookmark tests passed, including
legacy migration and pixel-precision toggle/previous/next coverage.

## Signed candidate

The replacement candidate is 0.2.38 (40), built from
`42e8dedfdd1e833abbf49f6dc291321ecf84a2ab` by
[release run 43182378300](https://github.com/Ares-X/Sumra/actions/runs/43182378300).
All release-file checksums, the existing signing certificate, deep code signature,
140 bundle files, five symlinks and 625 tracked source files were verified.
The archive's length and Ed25519 signature match the 0.2.38 appcast entry and
the existing public update key. The manifest SHA-256 is
`e6101495f7f9cd65f7984db1ea9dd7970791e76a5e936c01dd89c0aac608f865`.

The latest results across the relevant local test runs contain 68 distinct
passing cases, no failures, and two skips: an old native-title test that does
not apply on this macOS version and an unavailable historical format sample.
These skips are not acceptance evidence. Desktop interaction resumed after the
maintainer confirmed the desktop was available.

The exact signed app passed folder/Recents reopening and supported-format
errors, first-open CHM homepage-anchor visibility, same-topic CHM bookmark
restoration and removal, and same-page PDF previous/next/toggle. PDF scrollbar
positions were approximately 0.154 and 0.771 on page 1/8; toggling removed only
the current bookmark and did not open an Add dialog. CHM restored approximately
0.215 and 0.289 within the same topic, then removed only the current bookmark.
The original image EPUB at 200% stayed on page 1/4 while its scrollbar moved
from 0.839 to 0.912. The signed normal-fullscreen Hidden → Auto transition
showed the document without a companion toolbar backing; this stationary-pointer
screenshot does not establish pure-hover reveal/hide or transition animation.

Finder initially loaded the installed 0.2.37 extension. After switching its
registration, the running executable was verified under the exact candidate
bundle. Next displayed page 2/3; attempting corrupt page 3 showed an explicit
error while retaining the last successful page. Previous recovered to page 1/3.
However, clicking the page and pressing either arrow did not navigate.

A separate temporary local diagnostic showed that the page received mouseDown,
its window was key, and makeFirstResponder succeeded with that page as the
actual responder. No direction-key event reached either the page or root
keyDown handler. Declaring needsPanelToBecomeKey on the root did not improve
this. The temporary change and logging were reverted exactly; they are absent
from the candidate. This locates the remaining observation at the Finder-to-
remote-view input boundary without claiming a proven platform defect.

The candidate is accepted for the bounded fixes above. Issues #135 and #136
may close after publication and installed-update acceptance. #137 and #96
remain open; release notes explicitly retain their unresolved paths. No issue
reply is part of this delivery.
