# Five-round reader polish — 2026-10-27

The maintainer requested five rounds of interaction and performance work before
publication. The starting public and installed version was 0.2.20. Unrelated
AGENTS.md, Serena metadata and the Sumatra comparison document are preserved.

| Round | Missed workflow and repair | Validation |
| --- | --- | --- |
| 1 | Continuous-chapter thumbnails and link hover previews rasterized the entire chapter; previews now draw a bounded region, with links starting at their destination. Opening thumbnails at PDF page 12 showed pages 1–5; the sidebar now reveals the reading page. Browser Find ignored the initial backward direction and paged viewport origin; it now captures the source origin. | 48 affected cases passed; one existing opt-in large-book case skipped. Another 43 browser Find and 9 CHM cases passed. Real local app verified PDF page 12 → sidebar pages 8–12, then Home → pages 1–5; natural-chapter previews display. |
| 2 | Mixed-size PDF facing pages used independent fit scales after switching to continuous reading. Layout, measurement and rendering now share the existing facing-page calculation. | Fail-before measured both pages at 300×600. All 25 selected tests passed, including page/width, RTL, mode cycles, uniform sizing, content/visible and prediction. |
| 3 | Bulk tab closing inspected state before asynchronous close approval finished and stopped after the first loaded tab. Closing now waits for each actual result and stops on cancellation or failure. Floating Find results also failed to route PDF Undo to their parent reader; text editing keeps native Undo. | Five native-tab tests passed, including native refusal, Cancel, Save, Discard and a real save failure. Two real NSPanel focus tests passed PDF Undo/Redo, document isolation and native text Undo/Redo; the original mapping fails the established-focus regression. |
| 4 | The separate bookmarks window discarded file identity and could open a replacement at an old path. Its request now uses the sidebar's existing identity-aware opening. Entering a filtered folder carried the parent's query into the child; directory changes clear query and selection, including the active search editor. | Full ReaderWindow request integration passed for normal, moved and deleted originals with reused paths; active-search Return enters the folder and opens its child. The combined identity/browser/close/lifetime run passed 22 cases with no skips. |
| 5 | Native continuous reading counted natural chapters as pages, ignoring scrolling within a chapter and disabling the slider for one long chapter. The footer now observes the existing canvas scroll fraction separately, and the existing geometry owner performs seeks. | Single-chapter and 20-chapter hosts pass drag to 0/0.5/1, accessibility and Home/End, lazy chapters, source-position restoration and return to paged mode. Chapter-internal scrolling publishes zero ReaderState changes. The affected run passed 83 cases; its two original-file pinch cases subsequently passed with the original Alice and format-sampler directories configured. |

For round 1, a 300-paragraph HTML/Markdown fixture produced an unrotated
128×10,881 image, 4,178,304 bytes. The bounded preview is 128×160, 61,440 bytes;
rotated previews remain at most 81,920 bytes. A separate link fixture changed
from 640×43,789, 84,074,880 bytes, to 640×880, 1,689,600 bytes. These are decoded
bitmap allocations, not whole-process footprint or universal latency claims.
Finite pages retain their complete preview and rotation.

The preview regression first failed against the whole-chapter path. Its link
destination assertion was corrected to use reader CSS for the colored oracle
and compare color channels, since the active theme overrides publisher colors
and the display profile affects exact RGB values. The destination text was
already visible in the diagnostic image; the final test checks the actual red
destination rather than an unrelated white part of the chapter.

The Undo host initially had no running AppKit event loop and no key window;
those setup failures do not establish a product defect. With a short real
AppKit event loop, the original mapping still failed to undo the parent PDF.
The repaired mapping passed both tests and restored the prior activation policy
and foreground app. Continuous-progress host setup corrections and the
distinction between pixel scrolling and legitimate lazy-chapter publications
are retained in `round5-harness-observations.md`.

Release preparation also normalizes the contributor test to the existing
`Tests` directory and updates its workflow/documented command. On the Mac's
case-insensitive filesystem, separate `Tests` and `tests` paths referred to one
directory and the source packager could emit a different spelling than Git.
The Python tests pass at the canonical path. The final corresponding-source
archive must be checked against the committed file spelling.

Evidence is retained under `build/reader-polish-20261027/`: baseline and final
test logs, bitmap sizes, native mixed-page results and local-app screenshots.
Across the recorded final affected runs, 213 distinct app behavior tests passed;
this is combined coverage rather than a new full-suite run. The existing opt-in
100,144-match original-book stress case was not rerun. Its search owner is
unchanged. Six contributor tests, 58 packaging checks, Quick Look registration
and all 25 localization catalogs also passed. The final release build and
signed-candidate validation remain pending at this local source checkpoint.

The local source-inventory attempt encountered the already-exported MuPDF
checkout without Git metadata. Its parent-repository revision is not a native
source attestation. The existing clean Action build remains the release owner;
its frozen receipts and downloaded source archive require their normal
correspondence verification. No native source checkout was reset or replaced.
No 0.2.21 publication has occurred at this checkpoint.

Physical trackpad behavior, the full-book first-search latency goal and
coverless EPUB Finder-thumbnail provider selection retain their existing
limitations. New findings outside these five batches are not claimed fixed.
