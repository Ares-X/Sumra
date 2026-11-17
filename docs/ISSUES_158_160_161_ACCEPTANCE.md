# Remaining reader issues after 0.2.47

Baseline: `3dbf1bda50ab15bac5e954618a30c6f8dd06768a`. Only the existing macOS 26.6.2 VM is authorized. This is an in-progress acceptance record: no new release or issue closure is claimed.

## #160: frame speech source

Browser speech callbacks now retain the exact document Realm that produced the text. Moving focus to the parent or another frame no longer changes the highlight target. A new reading source clears the previous source; source navigation and frame removal clear its highlight and release the reference. Zero-length callbacks clear visible geometry while retaining the current UTF-16 map, as required by the existing speech-follow toggle and native speech startup. Visible reading needs only its starting caret before extending to the body end; it no longer requires a second caret at the viewport bottom.

Three new real WKWebView cases reproduce the focus/cleanup failures before the fix, then pass with seven existing speech regressions. They cover selection/cursor/visible reading, UTF-16 offsets, parent/sibling focus changes, replacement, navigation, detached frames and the real native overlay path when CSS highlights are unavailable. Actual system-speech playback in the signed VM remains pending.

## #161: annotation refresh work and rows

The existing Pages mutation owner records affected annotation pages. Ordinary annotation edits, creation, deletion, erase and cut/paste publish their actual pages; undo and form operations retain full invalidation because their effects can extend beyond the initiating page. Link-only changes do not invalidate annotation rows. Each sidebar instance can collect coalesced mutations since its last completed refresh, including changes while hidden.

The sidebar keeps its same-document rows until the replacement data is ready. Changed pages replace only their own rows, retaining document/page ordering and filters. Unknown mutations or a different page count rebuild; a replacement document hides the old rows immediately, and a late old task cannot publish into it.

Real native-PDF reads before the fix confirmed that a one-page edit queried all 1,000, 5,000 and 10,000 pages. The first attempt's accessibility waits timed out, so its timing values are not performance evidence. Its receipt also records a test-helper edit during the protected run; that failed run is retained and is not an all-green gate.

After the fix, actual NSHosting sidebar rendering and query-count checks pass:

| PDF pages | Initial annotation queries | Queries after one-page edit | Initial load plus repaint | Edit plus repaint |
| --- | ---: | ---: | ---: | ---: |
| 1,000 | 1,000 | 1 | 0.059 s | 0.030 s |
| 5,000 | 5,000 | 1 | 0.182 s | 0.030 s |
| 10,000 | 10,000 | 1 | 0.305 s | 0.030 s |

These are local macOS test-host observations, not signed-VM timings or CPU/RSS measurements. A blocked page-read test verifies pixel-identical existing rows during refresh and discards old work after replacement. Coalesced edits preserve page order; undo rebuilds. Test-only read/completion observers are excluded from release builds.

## #158: latest reporter sequence

The [latest reply](https://github.com/Ares-X/Sumra/issues/158#issuecomment-6904858425) adds a specific step: Normal Auto Hide → New Tab or Duplicate in New Tab → hover the new native filename until its document proxy thumbnail appears. The recorded gap is local to the filename while the remaining toolbar and captions stay opaque. Hiding the toolbar also leaves a thin separator between the native toolbar and caption row. This differs from the previously fixed fullscreen companion band.

The original video and screenshot were inspected. A fresh VM reproduction, native title/proxy ownership trace, fix and signed acceptance are still pending. Do not treat the previous add-tab check as coverage of this new hover trigger. `NSToolbar.showsBaselineSeparator` is marked “No longer supported” in the installed SDK; a deprecated setter is not a demonstrated fix.

## #96 and delivery boundary

The original broken-page recovery has existing signed Finder acceptance. Ordinary and fullscreen arrow routing failed in 0.2.47. Public QLPreviewingController does not expose an extension keyboard negotiation API, and prior actual-host text-field/button experiments already failed. No global keyboard monitor or private host takeover is added. #96 remains open.

Current evidence: `build/issues-remaining48/tests-content-final/receipt.json` records 15 cases: 14 passed; the existing accessibility-driven annotation filter test failed with an empty accessibility tree while the Mac was locked. New speech, native query-count, bitmap retention, coalesced edit, undo and document replacement checks pass. Source/engine hashes are unchanged during this run and private test hosts/preferences/clipboard were cleaned. The old filter interaction must be rerun unlocked; it has not been removed or weakened.

The Mac was confirmed locked, VM resume returned canceled, and desktop tools could not connect. No guest files, preferences or registrations have been changed in this attempt; the existing VM remains suspended. Signed-package GUI acceptance, merge, publication and confirmed issue closure await the remaining work above.
