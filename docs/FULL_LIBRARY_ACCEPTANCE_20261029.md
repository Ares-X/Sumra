# Full local-library acceptance, 2026-10-29

Status: final signed candidate local acceptance passed. Publication and the issue
reply still require public-byte and installed Sparkle-update verification.

Accepted application source: `f59ffbf6cbab74c95be59b95b455a827e6723557`,
version 0.2.22 (24), executable SHA-256
`ec7dee198c3d556c9376549bf8ac95dfc4203034ddeb7d4efd85bad5b3be19f2`.

## Inputs and evidence

The active local library contains 25 supported books: 14 EPUB, three CBZ,
two PDF, two Markdown, two TXT, one CHM and one MOBI. The final GUI inventory
also includes the ten original feedback files, four generated boundary fixtures,
four PDF interoperability fixtures and the Markdown demo: 44 distinct file paths,
not 44 different titles. Calibre databases, metadata and hidden Trash
are not active reading inputs. The private file inventory and screenshots stay
local under `build/release-0.2.22/corpus-20261029/`.
The initial 34-file exploration covered the library, eight original format samples
and the demo; the final inventory additionally includes the two C/D EPUB originals
and eight generated/PDF interoperability files. Those files must not be inferred
covered from the initial sweep.

On source `32e089f`, the hosted reader workflow passed all 25 books, including
first/middle/final source positions, Contents and searches. Every page of the
three comics decoded: 2,100 + 829 + 2,013 = 4,942 pages. These are two opted-in
integration tests, not thousands of separate UI tests. All originals retained
their SHA-256, length and nanosecond modification time.

The first GUI sweep used the loaded local executable `fb79308a6dd762c921c2d8545efdd20bf7121ec418c32a56f4d27ca7047954f3`.
All 34 files were opened through the real application, with real footer drags
and desktop-composite captures at the beginning, middle and end. The root agent
inspected all 102 images in per-file sheets and full-size follow-ups. Capture
success alone was not marked visual acceptance. The 34 originals were verified
unchanged again after this sweep.

## Findings and repairs to verify

| Finding | Existing owner and required verification |
| --- | --- |
| Completed search briefly displays `0 / 1` while a hit is selected | Publish the selected native hit with its result projection when lazy pagination renumbers pages. Original-book and generated-book tests reproduce the old mismatch. |
| A 560-point window with a 360-point sidebar squeezes a spread into unreadable columns | Reserve a usable document pane through native split constraints. Preserve the preferred sidebar width when automatic allocation shrinks it; retain divider edits and left/right/AI behavior. |
| A CHM footer drag stays in its first topic | Use the file sequence consistently for multi-topic progress, preview and navigation. Preserve within-file scrolling for single-file HTML. |
| Large page/chapter counts are visibly truncated | Reserve the document's complete localized counter width. Keep small-book dimensions and balanced padding. |
| Background chapter layout changes the track while it is being dragged | Preserve the existing drag's presentation until its navigation completes; keep actual navigation tied to current document state. |
| A large solid archive briefly shows a blank page without feedback | Show a small nonblocking indicator while the requested page has no image. Recheck the real loading-to-paint transition rather than accepting an early blank capture. |
| Portrait fixed pages intersect Medium floating controls | Apply the same Medium/Wide clearance to fixed pages without subtracting nonexistent reflow margins. Preserve Narrow's optional content overlap and hover-stable geometry. |
| Adjacent Markdown headings create an artificial title-only canvas | Repair the chapter producer together with exact migration of shipped passages and bookmarks; preserve text, Contents targets and search source identity. |
| Restoring an old Markdown bookmark navigates correctly, but its stored chapter still uses the old numbering | Normalize the saved bookmark positions through the same native migration before ordering, previous/next navigation and toggle comparison. Preserve bookmark identity and metadata. |

A small cover in one EPUB was checked against its actual source: the publisher
explicitly applies `margin: 50% 30% 0 30%`. That authored layout is separate from
reader-generated spacing. The user's document-style option remains authoritative.

## Final signed local acceptance

The same final executable opened all 44 inputs. First, middle and end desktop
captures (132 images) were actually reviewed, including full-size follow-ups.
The 25 active-library inputs and six additional feedback/performance inputs
also passed first-request cold opening from a fully stopped application; all
31 first paints were visually reviewed. One additional Alice cold open retained
the stationary pointer at the top throughout launch and showed complete,
accessible toolbar buttons without a second file request.

Real ordinary/fullscreen actions covered upper-half toolbar hits, all three
toolbar/progress display modes, View-menu tracking, stationary tab switching,
New Tab cancel/confirm, middle-tab close/reflow, all three file-open policies,
independent Home and Dock reopening from zero windows. Settings icons, live
typography/margins/themes, native Colors selection, custom divider color and
divider hiding were observed in rendered windows. Test preferences were restored
and all 274 functional keys match their original values.

Four-state hover captures had identical reading-body pixels in ordinary and
fullscreen windows. All 130 ordinary and 79 fullscreen progress-capture frames
were viewed. A further 251-frame held-progress capture had 48 distinct pixel
images; all 48 were reviewed with a complete frame-to-pixel correspondence. The
held track/value stayed fixed; precise page-count geometry published after release.
Thirty-nine original C EPUB and 39 Alice MOBI physical-resize frames were reviewed.
Both C spread images retained equal widths throughout live resizing; normal
post-resize repagination remains expected. UI zoom and the production pinch
handler tests passed; this is not a physical-trackpad hardware claim.

Actual AZW3, MOBI and FB2 hover previews allowed a single click through to the
intended destination, dismissed correctly and retained all four image borders
and captions. A large solid comic seek showed nonblocking loading indicators
followed by complete page painting. Original D EPUB Next reached the final
paired spread with 100%. The narrow sidebar preserved its 360-point preference
when expanded, and original-book unique-hit search remained selected/count-correct
while page numbering changed during reflow.

Finder icons and Space previews were viewed for all six original sample formats;
FB2 preview Next also painted readable body text. Loaded preview and thumbnail
processes were verified against the final dist executable paths and MuPDF. Old
OS-owned providers exited normally after temporary registration changed; none
was killed and no global preview cache was purged. The coverless EPUB generic
Finder icon remains a disclosed limitation; its Space preview works.

## Remaining delivery acceptance

- Publish only the accepted immutable candidate assets through the manifest-gated
  existing release workflow and compare anonymous public downloads and feed.
- Exercise the installed 0.2.21 Help-menu Sparkle update, verify all installed
  candidate bytes, reopen an original book on the first cold request, restore
  temporary registration and finish scoped cleanup before replying.

Historical evidence: the pre-bookmark follow-up source gate completed 1,433 tests
with no failures and one manual CUA harness skipped; localization, packaging and JavaScript
checks passed. The later bookmark follow-up passed 20 affected tests. The native
search follow-up passed 29 focused tests with no skips, and preserved all 100,144
oracle records including their source, physical page, range and context start.
These are separate evidence batches, not one summed final-source full-suite run.

Two repeated-prefix scans were removed from whole-word search and normalized
source lookup. On the same book, style and native probe, complete native scanning
changed from 6.557 to 5.757 seconds. The dense single-page 8,192-hit fixture changed
from 816 to 26.48 ms with identical output. The final optimized hosted reader
also completed all 100,144 results in
8.047756 seconds; first partial publication took 75.8 ms and a page painted in
57.4 ms during counting. Main-actor samples had zero intervals above 100 ms.
The real foreground GUI Next action also worked during partial counting.

The final source gate completed 1,439 tests: 1,438 passed, zero failed and one
opt-in manual interaction harness skipped. Its actual hover/Colors workflows
were exercised separately above. Packaging checks (58), shared Quick Look types
(11) and JavaScript syntax checks passed. The 25 hosted-library workflows and
4,942 comic-page decodes also passed on this final source.

A same-layout independent glyph oracle checked the current 317x648 GUI search:
all 100,137 ordered results matched the optimized path, including source anchors,
physical page, UTF-16 range and context. The frozen 779x590 style retained 100,144
identical records on the same shipped engine. Seventeen differing source anchors
were authored compounds containing `-the-`; existing end-of-line hyphen joining
changes whole-word boundaries with wrapping (five current-only and twelve
frozen-only). Different-layout totals were not treated as proof of completeness.
All 44 originals retained SHA-256, length and nanosecond modification time after
GUI acceptance; final application bytes also remained unchanged.

Cold-open stress also reproduced Home-only launches. A live system trace shows
the failing initial document event addressed by PID instead of the hinted Mach
port, before macOS starts the stopped application; the receiver then gets a
synthetic ordinary-launch event. No second request is counted as a cold pass.
Keeping the sending process alive did not prevent a failure. Twenty-five later
cold opens with debug logging succeeded, which does not resolve the earlier
failure. The final community-signed candidate passed the uninstrumented
first-request cold sweep described above. Installed update/cold opening remains the final
delivery gate; no reader fallback, delay or argument parser was added.

Timing from the Debug hosted sweep is not a release performance claim. Likewise,
sampled visual inspection is not a claim that every text page was read or that
every possible file and physical device is error-free.
