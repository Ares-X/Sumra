# EPUB layout regressions: fourth-round investigation

## Communication and release status

Fourth-round work is in the repair and verification stage. No completion reply
or public release has been made for it. Issue 31 remains open.

## What the reporter found

The eight original reduced EPUBs expose small cover-following illustrations,
scale changing incorrectly as the window grows, misplaced interior artwork and
first-page padding affected by an unused metadata cover resource. Originals and
the downloaded ZIP are hash-inventoried under `build/issue31-fourth-round/`.

The signed 0.2.16 app reproduces the small A illustration in both windowed and
full-screen reading. A separate native observation records actual page bounds
before and after repeated layouts, without assuming a nominal initial viewport.
The retained 0.2.15 native library provides a comparison; no old app was installed
or registered for that comparison.

## Why the previous acceptance missed this

- Removing the reader's global automatic-height override exposed a native CSS
  parser defect: unsupported `98vh` became a fixed length of 98. Tests covered
  pixel, em and percentage heights but omitted viewport-relative dimensions.
- Refining cover resource identity correctly kept a publisher logo small, but
  stopped treating some interior image pages as covers. The replacement art
  fitting rule covered several images in one chapter and omitted a single image
  in a separate chapter immediately after a cover.
- Most native sweep assertions checked occurrence count, aspect and containment.
  A tiny image inside its page can pass all three. Only selected cases checked
  centering or a size lower bound. Source-position tests likewise did not prove
  that the restored image occupied its intended area.
- Cover fixtures included a visible cover in the spine. They did not compare the
  same first visible page with and without an unrelated metadata-only cover.

The earlier green checks remain historical results for their stated assertions;
they did not establish the broader absence of EPUB layout regressions. Publishing
and replying with more confidence than that evidence supported was a mistake.

## Verification of the failure class

The repair must preserve these distinct behaviors together:

| Boundary | Required behavior |
| --- | --- |
| Viewport lengths | `vh`, `vw`, `vmin` and `vmax` resolve against the current reading canvas; width-only and height-only changes invalidate the appropriate layout |
| Relative height chains | Definite pixel/em/viewport ancestors supply the percentage reference; an auto-height ancestor keeps the percentage indefinite; zero is distinct from an absent reference |
| Art pages | A single independent auto-sized illustration and an image sequence fit paged reading; small explicit dimensions, constrained logos and mixed prose keep their authored sizing |
| Authored maxima | Positive and zero maxima constrain images in paged and continuous reading; percentage maximum height uses its own actual containing-height reference |
| Responsive containers | A viewport-sized image-only frame and its image reserve the same available page budget, without creating an empty trailing page from outer insets |
| Cover identity | An unused metadata resource cannot change first visible geometry, trigger whole-spine parsing or prevent opening a valid first chapter because a later chapter is unreadable; a later declared cover must not promote an earlier small logo |
| State transitions | Fresh open, narrow/wide and portrait/landscape sizes, return to the same size, single/facing/continuous changes and full screen preserve source identity, complete painting and intended scale |
| Earlier repairs | All four rounds of reporter examples, small logo/heading controls, image occurrence boundaries, captions and anchors remain checked |

The native repair's first internal iteration was withheld: independent review and
new tests caught zero/continuous maximum-size failures, a wrong percentage
maximum-height reference, eager spine loading and empty pages after responsive
image frames. These failures are retained as evidence; this iteration is not an
accepted release.

Source assertions, native geometry, painted output, actual signed-app interaction
and delivery verification remain separate. No finite test set establishes that
every document or system version has no defect. Missing observations remain
unverified, and test counts are not a replacement for those observations.

## Additional acceptance corrections

The hosted reader check now measures the painted illustration’s actual pixel
extent against its native rectangle transformed into the displayed canvas. It
checks the first, middle and last illustration through repeated reading-mode
changes and height-only/width-only window changes, rather than accepting a few
colored pixels as proof of a correctly sized picture.

A full source run also exposed a test initialization race in the outline test.
It compared an outline prepared at the default 420×595 canvas with a destination
resolved while the mounted reader was switching to its actual viewport. A
focused rerun alone was not accepted as a correction. The test now waits for an
outline publication belonging to the committed reader revision and retains both
exact destination comparisons. No product behavior was changed for this race.
The in-progress source run with the incomplete wait was stopped, retaining its
log, before starting verification of the corrected test.
