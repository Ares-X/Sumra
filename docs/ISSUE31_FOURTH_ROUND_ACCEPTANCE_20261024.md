# EPUB layout regressions: fourth-round investigation

## Communication and release status

The repaired runtime is bound to source revision
`7c6f190ac4e6696ba4fc28d2477712538e7031c5`. No completion reply has been
posted for this round. Issue 31 remains open. Delivery status is recorded below.

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

## Automated verification of the repaired batch

Source revision: `7c6f190ac4e6696ba4fc28d2477712538e7031c5`.
Native patch SHA-256: `dadd1cd2eb4a23d62fc76dc0a87ccf3ad3c5da06e22c3b2853a71256a98de355`.

- All 67 ordered native patches reverse to the unchanged pinned-source digest
  and reapply; a complete engine build succeeds.
- All 33 original files across four rounds pass the native cover/layout sweep.
  The fourth round additionally checks each affected interior illustration through
  six paged layouts and continuous reading: one occurrence, containment, growth
  with a larger window and identical placement on returning to the same size.
  The old signed 0.2.16 engine fails the growth assertion for A.
- Nine authored CSS/image regressions cover exact dimensions, viewport units,
  percentage references, maximum-size constraints, responsive container insets,
  small-logo controls, metadata-only covers and lazy first-chapter opening.
- The hosted reader verifies actual painted extents and source identity through
  reading-mode cycles and width-only/height-only window changes. The corrected
  outline test observes the committed outline publication; exact destination
  assertions remain intact.
- `scripts/check-source.sh`: PASS — 121 core tests, 1,036 app tests (six opt-in
  skips), three Quick Look tests, 58 packaging checks, parser checks and all 25
  retained translation catalogs with 677 inventoried keys present.
- The separate opt-in hosted corpus run passes all 25 files (14 EPUB, two PDF,
  three CBZ, two Markdown, two text, one CHM and one MOBI), in 182.36 seconds.
  A large EPUB’s whole workflow takes 102.56 seconds, close to the previous
  101.52-second result; these are workflow totals, not cold-open measurements.
  Original sizes, modification timestamps and SHA-256 hashes are unchanged.

Evidence: `build/issue31-fourth-round/source-checks-final.log`,
`final-focused.log`, `four-round-native-regression.log`,
`revision-layout-assertions.json`, `corpus-workflows.json` and
`corpus-preservation.json`. Earlier failed/interrupted runs are retained and are
not counted as successful acceptance. Signed candidate interaction remains the
next independent verification layer.

## Signed candidate acceptance

The unmodified CI candidate 0.2.17 (19) passes complete bundle/provenance,
corresponding-source and signing checks. Its executable UUID is
`B58D2397-0C35-373F-9A52-476B74BF138A`; ZIP SHA-256 is
`ed6d01aa38d9f415c9f6d8708ccf83673fddbd3f40cf4fcec1174c5bf46f4779`.
The observed running process loaded that candidate’s exact bundle path.
Its packaged MuPDF library independently passes the eight original fourth-round
geometry checks, including continuous reading and returning to prior sizes.

Actual application interaction on macOS 27.0.1 arm64:

| Case | Observed result |
| --- | --- |
| Fourth-round F, first process/open | First visible art fills its intrinsic canvas without the unused-cover padding |
| A, restarted process | Cover and following art both render at appropriate scale; the art remains on its own single chapter page |
| A/B, full-screen/window return | Art grows with the reading window and returns to its prior placement |
| A, system Window → Zoom and restore | Page/source remain stable and artwork remains complete |
| A, Single Page / Continuous / Two Pages | Same illustration retained; finite modes fit the page and continuous mode uses natural reading height |
| B–E and repeated second-round D/F | Each affected interior image is visibly large, proportional and in its authored chapter; neighboring text remains present |
| Third-round A/B/C controls | Heading decoration and inline title art stay centered; publisher logo remains small |
| Repeated second-round C, last image | Single Page → Continuous → Single Page returns to 2:4 with the complete blue illustration |

A coordinate drag attempt did not change the actual window bounds and is excluded
from resize acceptance. Width-only/height-only/narrow-window changes are covered
by the hosted painted-reader test and packaged native geometry; real GUI size
changes above use full screen and the system Window menu.

The inline tool preview appeared to clip the last illustration after a mode
change. Publication was held while both agents checked original PNG pixels.
The saved 2400×1520 images have identical artwork bounds before/after:
`[671,120,1729,1476]`; a background row below the image confirms its lower edge
is present. This was a preview-display artifact, not a demonstrated product bug.
No product workaround was added. The hosted test was strengthened to require
the entire transformed image inside the visible canvas in Fit Page mode; its
focused run also passes. Evidence is retained in
`signed-ui/last-artwork-pixel-comparison.json` and
`whole-artwork-before-fix.log` (the filename preserves the initial hypothesis).

Candidate UI captures and AX states are under
`build/issue31-fourth-round/signed-ui/`; identity and corresponding-source
receipts are under `build/release-0.2.17-candidate/`.

## Delivery

The runtime and acceptance changes merged through [PR 40](https://github.com/Ares-X/Sumra/pull/40).
[0.2.17 (19)](https://github.com/Ares-X/Sumra/releases/tag/v0.2.17) is public.
Its runtime source remains `7c6f190ac4e6696ba4fc28d2477712538e7031c5`;
subsequent commits change only tests, documentation and the update feed.

Anonymous downloads of all six published assets match the accepted candidate's
asset IDs, sizes and SHA-256 hashes. The public main-branch update feed matches
the accepted feed, and the Sparkle Ed25519 signature verifies. The accepted
`SHA256SUMS` digest is
`b7119136e042c85a37aa208bcf8dce9574899cba123ed896ad760b852c326ec1`.
The public-verification receipt is retained; redundant downloaded asset copies
were removed after comparison with the retained accepted assets.

The existing formal installation completed a real Sparkle **0.2.16 → 0.2.17**
download, install and relaunch. All 140 installed files, five symlinks and
91 directories match the accepted provenance; signing identity, executable UUID
and embedded binaries also pass. An initial automation action selected Skip
instead of Install after accessibility indices changed; it is recorded as an
unsuccessful attempt, then corrected using the refreshed control identifier.
The final preferences contain no skipped-update entry.

After quitting the installed app and confirming no Sumra executable was running,
Finder's actual Open With menu contained exactly one Sumra entry. Selecting it
opened the original A EPUB in the formal installed app. Before any app-selection
or activation helper was used, a passive process/window observation confirmed
that Sumra was active and its document window was on screen. Cover and following
illustration were then checked in the actual installed reader. Receipts and
captures are in `signed-ui/finder-*` and `signed-ui/installed-finder-*`.

Final preservation checks confirm all 33 original four-round books and all
18 downloaded input/sidecar entries remain unchanged. Earlier corpus checks
also preserve all 25 local books. Application preferences match the pre-test
snapshot except the updater's legitimate last-check timestamp. The test app and
owned Finder window are closed, the Cua kernel is reset, completed agents retain
no owned background work, and redundant public downloads released 184,222,109
bytes. Prior cleanup is separately recorded in `cleanup-partial.json`; the final
receipt is `final-cleanup-preservation.json`. Shared processes and unrelated
working-tree changes were preserved.

No issue reply or closure was performed for this round. Acceptance establishes
the documented cases on macOS 27.0.1 arm64, not a guarantee for every EPUB or
macOS version.
