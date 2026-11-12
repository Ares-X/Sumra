# Issue 137 and related reader follow-up

Baseline: main `88ab0b8b7898fa867215b46d381eb1288094c39b`, installed
0.2.37 (39), arm64 macOS 27.0.1. The reporter of
[#137](https://github.com/Ares-X/Sumra/issues/137) uses macOS 15.7.5.
These are different runtime environments. No reporter comments are part of
this task.

## Original-report checklist

| Reported behavior | Investigation and acceptance boundary |
| --- | --- |
| Floating traffic-light hover glyphs stick or fail to appear | Original recording inspected. The existing tracking-area tests manually call event handlers; they do not establish WindowServer delivery during the green-button system popover. No verified fix yet. |
| A rectangular surface briefly covers the floating toolbar during fullscreen entry | Original recording inspected, including its larger multi-tab case. Stable screenshots after fullscreen entry do not establish transition-frame correctness. No verified fix yet. |
| Normal fullscreen toolbar is blank after Always Hide → Auto Hide while hovering | Replayed the mode change on the installed version. The companion background was restored to opaque while its content remained hidden. The candidate now hides both together; a native-window ownership test fails against the old code. Pure-hover acceptance remains separate because CUA has no pointer-move-only action. |
| Floating tab close hover fills the whole tab and breaks the shared hover surface | Candidate keeps the 28-point target, uses an 18-point visible close background, and makes the tab own hover across its close target. Physical visual acceptance pending. |
| Closing a normal tab leaves a gap until the pointer leaves | Replayed three native tabs → two on the installed version and retained a screenshot with the pointer at the closed tab. This does not establish the reporter's macOS 15.7.5 behavior. No verified fix yet. |
| Adding or duplicating fullscreen tabs leaves black Spaces | Two installed-version duplicate actions joined the existing group and displayed their documents. Lifecycle logs confirm group counts two and three. CUA could not inspect Dock/Mission Control, so extra-Space absence is not established. |
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
  recovery already exists. The remaining candidate makes the clicked preview
  image take keyboard focus; Finder's unfocused arrows still belong to file
  navigation. Acceptance must exercise the signed extension in Finder.

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
