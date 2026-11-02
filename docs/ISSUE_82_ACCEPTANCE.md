# Issue 82: reader interactions and book layout

[Issue #82](https://github.com/Ares-X/Sumra/issues/82) reports behavior on public
0.2.24 (26). The reporter's list of features that already work is not a list of
regressions. The results below distinguish local AppKit/engine checks from
the actual application. Internal verification does not replace reporter confirmation.

| Report | Check and result |
| --- | --- |
| Restored tabs change titles/order, then Close and Quit fail | AppKit restoration opens the selected document, then loads dormant documents on activation. The regression selects each window, checks its URL, represented URL and native group order, closes the selected document, and checks the remaining saved session during quit. |
| Floating strip intercepts clicks/scroll incorrectly; middle or left native tab close disturbs survivors | Floating buttons cover the full tab row and wheel routing checks the topmost scroll owner. Closing a clean native tab completes in the original AppKit close event without removing/reinserting neighboring windows. Tests exercise hit routing, group identity/order, and close of multiple native tabs. Physical trackpad feel requires a device. |
| Normal-toolbar click activation, hidden toolbar rectangle, settings flicker and floating controls | Native titlebar clicks activate the owner without stealing tab or button actions. The native toolbar visibility and separate settings panel are exercised across visibility modes. The settings panel opens immediately, and listing installed fonts waits for interaction with the font picker. Actual hover pixel comparisons cover the floating close/minimize/fullscreen buttons. |
| PDF page field blank after Enter | A real PDF can declare a label range without a prefix or numbering style. MuPDF returns an empty string for that range; the reader now displays the physical number and preserves nonempty Roman labels. The public 0.2.24 app reproduced the blank field on a three-page PDF with legal empty labels while the page body and total remained visible. The reporter's 164-page PDF was not attached. Midnight PDF alone did not reproduce a blank field in 0.2.24. |
| Normal progress control looks right aligned; hiding the toolbar takes space from comics | The screenshot shows a centered *track*, with a longer label on its right. The rendered bounds of the percentage, track and page label together are now centered. Both original CBR and CBZ kept a separate bottom row with the progress bar always visible, in all three top-toolbar modes. |
| FB2 margins differ from other formats | The original formatsampler FB2 has no author stylesheet. Its FictionBook root received an additional default 1em margin. Native glyph-position tests now measure the requested margins in paged and continuous layout; publisher defaults, authored indentation and user CSS remain available. |
| EPUB cover versus facing image and unequal top/bottom margins; mixed-size PDF pages | Rendered the original C/E EPUBs and seven-page Midnight PDF. In C the two image tops differed by less than 0.5 pt at both tested widths. In E a 400×800 layout with 24 pt vertical margins measured 24 pt above and below the art. At 1512×945 both facing Midnight PDF pages filled the available height. Mixed crop boxes, RTL, solo cover, actual-size mode, and live-resize coverage also exercised the shared geometry. |
| Palette and thumbnail selection; Open panel disappears | Reproduced the vanishing Open panel in the public app. In a macOS VM the development app kept the chooser open on the first click, and its Open panel remained visible after double-clicking the selected row. Both choosers separate selecting a row from committing it. Commands that open another window are handed off at the native end-of-sheet notification. A separate Current Page label remains when selection moves. |
| Light dialog selection is hard to see | The field editor uses the system's selected-content background and corresponding foreground. AppKit tested selection across two fields under Aqua and Dark Aqua. |
| Long TXT scrollbar reverses on first traversal | The native thumb now tracks the source range visible in TextKit's viewport. A standalone AppKit comparison used 80 forward steps: three runs each produced nine reverse thumb movements on 3,500 lines and 25 on 51.61 MB; the new mapping produced zero on both. Native dragging reached 0/1 and the three intermediate targets within 0.00054. The reader still uses lazy layout. Application tests exercise line/page traversal, revisits and knob dragging across continuous, single and facing layouts. |
| Scrollbar ends hidden behind reading controls | Native scroller insets account for the part of the track actually under the controls. Legacy/overlay scroller and hosted reader checks verify the track clears them without shrinking the document viewport. |

On macOS 26.6.2 the public app restored a group saved as PDF, EPUB, TXT
in the order PDF, TXT, EPUB, and the selected EPUB subsequently separated.
An early development build also left the three documents in separate windows.
The reused Home window was allowed to accept tabs but had no native tab group
yet. Attaching the first document to the neighboring window created the
group (native counts 2, then 3); the next replay showed PDF, EPUB, TXT in
one native tab strip, with the middle EPUB selected. In a fresh launch of the
uninstrumented development app, mouse clicks switched from EPUB to TXT, PDF
and back to EPUB. Each window displayed the correct body and title. Closing
the middle EPUB, keeping the pointer in the tab strip and clicking the
surviving PDF also worked. AppKit held the old tab widths temporarily under
the pointer. An earlier replay recorded ignored clicks; it did not recur in
this clean run. Cmd-W closed the selected PDF without disturbing the others.

Direct New Tab, fullscreen Duplicate Tab, and opening another file in a
fullscreen tab rendered their documents during development acceptance. The
subsequent fullscreen check caught a separate regression: the native View
menu no longer offered Show All Tabs after automatic tabbing was disabled
globally. Switching tabs by keyboard or accessibility did not exercise this
missing command. The application now leaves native tabbing enabled when the
reader preference allows tabs; each requested window still controls its own
placement. On macOS 26.6.2 (25G83), the replacement build restored both
View commands and all four Window tab commands. In fullscreen, Duplicate Tab
added a second rendered Midnight PDF. The real View > Show All Tabs overview
showed both PDF covers, E's blue page and the TXT body. Cmd-N from that
overview created a separate Home window; both Home and the original reader
were accessible through the Window menu. Leaving fullscreen returned E to
its original 900 × 622 window with its body, controls and all four tabs visible.
These observations were taken after each Space transition settled.

With floating controls in a 560 pt window, a mouse click at y=75 in a tab
spanning y=50–78 selected TXT and showed its first section. Sending a
continuous horizontal wheel gesture over the four-tab strip scrolled the
visible titles from EPUB/TXT to the two PDFs; the same TXT section stayed
on screen. The gesture was injected in the VM; physical trackpad feel was
not measured.

Clean tabs now allow native Close and Quit to finish synchronously. Pending
edits still go through the existing save/cancel confirmation.

## Distribution

[PR #83](https://github.com/Ares-X/Sumra/pull/83) merged as
`bba387ce5714495372c6d7e4ba1254955cca09ac`.
[Candidate build](https://github.com/Ares-X/Sumra/actions/runs/41474896231)
produced 0.2.25 (27), a 17,036,049-byte arm64 ZIP with SHA-256
`c6086ff355e979549c30a0bf78849a11b474e2a6397e7f6c4fa47c5d427ed980`.
The existing community certificate, deep/strict code signature, both Quick Look
extension bundles and the Sparkle Ed25519 update signature verified. The
downloaded app matched the build inventory (140 files and five symlinks).

Three original-sample tests were repeated with the signed bundle's MuPDF
loaded (SHA-256 `b7ad389e2a5292e7ae9e9f233cac629fb59033a43991e66368f2a7b4a6994946`).
At 1512 × 945, C/E and Midnight had facing heights within 2 pt and centered
art within 0.5 pt. In the original FB2, first-paragraph x was within 1 pt of
each requested 8/16/24 pt margin in both paged and continuous layouts. The
original CBR and CBZ retained their always-visible footer under all three
normal top-toolbar modes.
