# Issue 31: third-round image layout acceptance

The reporter confirms cold file opening, color picking and font selection now
work. This round concerns authored image sizing/alignment, image pagination and
full-page interior illustrations. The baseline is the installed signed 0.2.15
app; the final release candidate and installed update are verified separately.

## Required behavior

- Keep small logos and heading ornaments at their authored size and position.
  Respect centered block margins and sized inline image containers.
- Keep real cover recognition separate from a later logo or illustration.
- At every tested page boundary, draw each source illustration once, fully and
  proportionally. Do not trade duplicated images for cropped or missing images.
- Fit an image-only sequence intended as full pages to the reading area while
  retaining explicitly sized images, mixed text, captions and links.
- Preserve ordinary text layout, chapter destinations and reading position as
  users change presentation or return from navigation.

## Coverage and evidence

Original input hashes are retained in `build/issue31-third-round/input-manifest.json`.
The five new reporter files remain unmodified. Earlier reporter samples and
purpose-built behavior fixtures cover different authoring patterns.

| Area | Cases and state changes | Evidence required |
| --- | --- | --- |
| Image roles | Declared cover, later small logo, heading ornament, title illustration, image-only sequence, normal text with images/captions | Source identity, image size/aspect/location and visible result; explicit small images stay small |
| Author sizing | Auto, fixed, relative/percentage wrappers, centered margins, SVG/raster and wide/tall aspect ratios | Author dimensions respected; no clipping, stretch, duplicate or missing image |
| Page boundaries | D's failing size and a range of neighboring widths/heights; LTR/RTL | Total image occurrences and source identities conserved across pages; full extents retained |
| Window transitions | Small/large window, enter/leave full screen, resize and return | Pictures adapt, page content remains reachable, logical position stays in the same passage/chapter |
| Reading modes | Single/facing pages, Cover on Its Own on/off, paged/continuous | Cover and interior layout remain distinct; correct sequence and forward/backward movement |
| Reading controls | Font/size, margins including distinct per-side values, authored styles on/off, custom CSS, zoom | Layout updates coherently; resets restore expected settings; no stale image or incorrect page count |
| Navigation | Next/previous, rapid arrows, chapter/outline jump, find and return | No repeated/stuck/skipped content; destinations and active passage remain usable after reflow |
| Regression | Earlier 20 reporter EPUBs, ordinary EPUB/Markdown and affected source tests | Previous cover/text/caption/anchor behavior retained; failures classified before acceptance |
| Delivery | Exact signed candidate, public archive/feed/signature, real 0.2.15 update and relaunch | Installed bytes match the accepted candidate; actual version and window verified |
| Preservation | Original books, existing preferences/history, unrelated working changes | Hash and state checks; only owned temporary bundles/processes retired; one Open With entry |

A passing source test, native geometry result and actual GUI observation are
separate evidence. The acceptance record states which were exercised; missing
observations remain untested. Runtime checks on this machine do not establish
macOS 15 behavior or a native-speaker language review.

## Baseline observations

In 0.2.15, A's chapter ornament and B's title image are visibly offset from their
centered text. C's small publisher mark is expanded to fill a page. The repeated
second-round C interior artwork retains its physical size when entering a larger
full-screen window. These have actual screenshots and page controls recorded
under `build/issue31-third-round/`.

D's repeated image is reproduced by the native renderer at specific page sizes;
its source image appears in both adjacent page placements. Baseline geometry and
size-sweep receipts are retained in the `native/` evidence directory.

## Integration findings caught before release

The actual reader bridge injected `img{height:auto!important;max-width:100%!important}`.
The newly recognized maximum-width property made this reader rule look like an
author constraint, so direct native layout tests passed while real reader calls
still failed to fit the image sequence. The global override was removed; normal
image layout now resolves percentage height from its actual containing block.
Real NativeFile regressions cover author width-only/height-only constraints,
maximum-size classification, auto versus definite percentage references, paged
and continuous reading, and zero-height containers with following text.

Independent review exposed the zero-percent case: a valid zero-height result was
mistaken for a missing height reference. A public-bridge probe confirmed that
`0%` incorrectly restored a natural-size image while `0px` did not. The owner
now distinguishes the existence of a reference from its computed result.

A partial manual native relink initially reused an object compiled against an
older private CSS-property enum and failed an existing PDF underline test. The
unchanged complete engine build rebuilt all native consumers, and the focused
PDF test and full source check then passed. The final height fix is rebuilt and
validated separately; stale partial-build results are not release evidence.

Signed candidate and final runtime acceptance are in progress. No issue closure
or success reply has been made for this round.
