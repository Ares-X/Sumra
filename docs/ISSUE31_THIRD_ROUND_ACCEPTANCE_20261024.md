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

## Broader product acceptance

The first signed candidate, source `2b9809e8cc12b15e29de953d14dc67a1e6b556c8`,
was withheld after two additional user workflows exposed defects outside the
reported image alignment cases:

- In the reporter's image-only chapter, Single Page at `2:3`, Continuous,
  Single Page returned at `2:4`. The native passage owner only captured text.
  Image viewports now use the existing stable HTML image source identity;
  visible prose and captions retain priority. Native and real Reader tests
  cover repeated resources and the first, middle and last illustration.
  That complete Reader test also caught a chapter-start boundary: a saved blank
  margin could resolve above the first image after reflow, putting the actual
  viewport in the preceding chapter. The existing scroll destination owner now
  keeps source restoration at or below its target chapter start, without
  restricting normal scrolling or chapter-end positioning.
- A small Markdown document's link to a later heading stayed in the first
  column. Generated Markdown places an empty anchor before the heading, whose
  empty content range had no geometry. The existing paged fragment owner now
  aligns the adjacent heading. WebKit tests cover generated anchors and normal
  content IDs in paged and continuous reading.

An unreadable PDF also exposed an unhelpful error without its file name. The
opening error now includes the requested file and original cause; the previous
document is preserved. The short context message is translated in all shipped
non-English catalogs.

Actual GUI exercises on that withheld candidate included:

| Workflow | Observed result |
| --- | --- |
| PDF form draft, cancel Save a Copy, place note, save new copy, undo/redo, cancel document replacement, discard disposable draft and reopen output | Form value and note preserved in the saved output; undo/redo works; both input PDF hashes unchanged |
| CHM topic link, find, cancel Open, failed PDF Open, then successful PDF replacement | Topic and search survive cancel/failure; successful replacement clears old search |
| CBZ cover alone, facing-page order, RTL forward movement, last-page boundary, sidebar arrow focus | Correct numbered pictures and direction; sidebar focus does not turn the reader page |
| TXT search, continuous/paged transition, font change and multilingual text | Search remains usable at its passage; English, Chinese, Arabic and Hebrew glyphs render |
| MOBI accented-character search and reading-mode transition | Accented text and Chinese render; matches remain available after reflow |
| Real 170-chapter Chinese EPUB, directory filtering, chapter destination, whole-book search and mode round trip | Directory and search destinations reach the intended chapter and text |
| Real 44 MB, 174-page technical PDF, out-of-range page entry, distant page, Fit Width and repeated paging | Page entry clamps to last page; distant content renders; Fit Width persists while paging |

These observations are preliminary runtime evidence for that exact candidate,
not acceptance of a later build. The replacement signed candidate must pass
both newly discovered workflows and the affected image/opening regressions.
No issue closure or success reply has been made for this round.

The image identity check uses the four fixture colors to distinguish painted
illustrations, not to assert display color accuracy. A first attempt compared
exact device RGB values and failed on AppKit's calibrated-color conversion;
that invalid acceptance condition was replaced by saturated-color identity.
Source and logical-position assertions remain unchanged.
