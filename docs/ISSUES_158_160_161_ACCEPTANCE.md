# Remaining reader issues after 0.2.47

The later Vira Reader build 51 acceptance is recorded in [the 0.2.48 release acceptance](RELEASE_0_2_48_ACCEPTANCE.md). The checkpoints below preserve the original investigation and pre-rename candidate history.

Baseline: `3dbf1bda50ab15bac5e954618a30c6f8dd06768a`. Only the existing macOS 26.6.2 VM is authorized. The signed 0.2.48 (50) draft candidate passed the scoped existing-VM workflows below. The maintainer then requested Vira Reader branding before publication; no new public release or issue closure is claimed.

## #160: frame speech source

Browser speech callbacks now retain the exact document Realm that produced the text. Moving focus to the parent or another frame no longer changes the highlight target. A new reading source clears the previous source; source navigation and frame removal clear its highlight and release the reference. Zero-length callbacks clear visible geometry while retaining the current UTF-16 map, as required by the existing speech-follow toggle and native speech startup. Visible reading needs only its starting caret before extending to the body end; it no longer requires a second caret at the viewport bottom.

Real WKWebView cases reproduce the focus/cleanup failures before the fix. They cover selection/cursor/visible reading, UTF-16 offsets, parent/sibling focus changes, replacement, navigation, detached frames and the real native overlay path when CSS highlights are unavailable. Actual VM acceptance then exposed two srcdoc boundaries: URL alias normalization threw before startup, and srcdoc messages have an about:srcdoc URL that the native book-origin guard discards. Path normalization now uses the already-parsed pathname; speech uses the same-origin top document's relay, retaining the native trust guard. Twelve focused cases pass, including the actual trusted main-frame native message.

Local VM system speech starts and keeps highlighting its original frame after parent/sibling focus moves. Visible inspection also exposed old heading paint after speech advanced into the paragraph. This matches [WebKit 306396](https://github.com/WebKit/WebKit/commit/15176166d70f4095b6c4d7b8d97e25f7810d6753): deleting a registry entry did not repaint its ranges. Speech now clears the existing Highlight's ranges before deletion, for movement, Stop and source replacement. A rendered WK snapshot regression and final signed VM repaint checks are being completed.

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

The original video and screenshot were inspected and both symptoms were reproduced in the existing VM using the exact signed 0.2.47 package. A temporary native-view trace established that proxy hover masks the toolbar's backing and that AppKit's caption separator sits beside, rather than inside, its hosting view. Making the titlebar nontransparent alone still produced a tinted gap; that failed probe is retained.

The fix paints and fades the windowed native titlebar owner once. Toolbar/caption descendants retain their own opacity beneath that owner, and the caption's native presentation container fades its separator too. Fullscreen retains the companion owner. Always Hide releases the windowed owner so its separate traffic-light hover remains visible; effective ancestor visibility is tested. The local VM probe shows an opaque proxy-hover title and no residual hidden line. Temporary full-view tracing is removed from product source. Signed-package checks remain pending.

The new native ownership test fails four assertions against the previous source. Existing leaf-alpha assertions were moved to effective ancestor opacity because the shared titlebar now owns the fade. The expanded suite verifies native caption collapse, backing/restoration, Always Hide control ancestry, titlebar input, tab closing/selection and fullscreen lifecycle without adding fixed insets or private class selectors. `NSToolbar.showsBaselineSeparator` is marked “No longer supported” in the installed SDK and is not used.

## #96 and delivery boundary

The original broken-page recovery has existing signed Finder acceptance. Ordinary and fullscreen arrow routing failed in 0.2.47. Public QLPreviewingController does not expose an extension keyboard negotiation API, and prior actual-host text-field/button experiments already failed. No global keyboard monitor or private host takeover is added. #96 remains open.

The locked-host run initially had an empty accessibility tree in the existing annotation filter interaction. After unlocking, that unchanged test passed in `tests-filter-unlocked`. `tests-accepted` then ran 88 cases with 87 passed, one expected legacy-platform skip and no failures. It includes the native chrome, input, tab lifecycle, annotation and speech cases. Source/engine hashes remained frozen and private test hosts/preferences/clipboard were cleaned. The later srcdoc-to-native speech relay needs its own focused regression run.

The existing VM is now running with a backed-up 23-key preference domain and task-owned app/fixtures. Local GUI acceptance of the 1,000-page PDF covers native annotation editing, immediate sidebar update and Undo/Redo. Earlier release-mode product compilation passed (87.98 s), excluding the private test-isolation library; the final signed build remains a separate gate. Signed-package GUI acceptance, merge, publication, restoration/cleanup and confirmed issue closure await the remaining work above.

## Signed draft acceptance before the rename

Source `2014282527f4d5d654ba5a92c824573315f92dd0`, main SHA-256 `52583c075a5dcd8db46a8f0765050d07a141249dd92b8a98740a9445b654a934`, manifest `444e67b918a5eb653c2e50d4eb91f88c4421e58efcc8889e0c596b8222b7d0ae`. All six assets, 140 application files, signatures, pinned Sparkle verification and corresponding-source inventory passed. The installed VM application matched all 140 files.

The signed package passed Duplicate and New Tab proxy hover, residual-line hiding, Always Hide traffic-light hover, fullscreen Auto Hide and Always Show, title-blank dragging and right-edge resizing. Actual system speech in srcdoc followed its original source after parent/sibling button clicks and cleared all word paint on Stop. The 1,000-page native PDF sidebar updated after editing a note, reverted on Undo, restored on Redo and saved. Exact upper-corner cursor transitions and reporter macOS 15.7.5 were not independently accepted.

The final focused speech run passed all 13 cases, including actual native-message delivery and rendered heading/body/Stop/replacement snapshots. Earlier snapshot experiments retained their failures; suspended hidden-view animation waits were removed in favor of a bounded initial snapshot followed by the actual paint assertions. No failed run is counted as green.

Receipts and original images: `build/issues-remaining48/release/signed-verification.json`, `vm/signed48-installed.json`, `vm/signed48-acceptance.json` and `tests-speech-release/`. This Sumra-named candidate remains a draft. Rebranded installation/update acceptance is separate, and #96/#158/#160/#161 remain open pending the next public delivery.
