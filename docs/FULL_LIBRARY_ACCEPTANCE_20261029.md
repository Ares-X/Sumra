# Full local-library acceptance, 2026-10-29

Status: in progress. Publication and the issue reply wait for the repaired
candidate's visual, interaction, installation and update acceptance.

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

## Remaining acceptance

- Load the coherent repaired build and recheck each finding with actual pixels
  and physical interactions. Recheck all library and feedback files on the final
  signed candidate, including narrow/ordinary/full-screen and mixed-format tabs.
- Trace first-request cold opening by actual receiving PID and window. Earlier
  Home-only observations remain unlocalized; a second Open is not a cold pass.
- Verify source tests, original preservation, preference retention, targeted
  release performance, exact signed/public bytes, and the installed updater
  relaunch before replying to the reporter.

The coherent pre-bookmark follow-up source gate completed 1,433 tests with no
failures and one manual CUA harness skipped; localization, packaging and JavaScript
checks passed. The later bookmark follow-up passed 20 affected tests. The native
search follow-up passed 29 focused tests with no skips, and preserved all 100,144
oracle records including their source, physical page, range and context start.
These are separate evidence batches, not one summed final-source full-suite run.

Two repeated-prefix scans were removed from whole-word search and normalized
source lookup. On the same book, style and native probe, complete native scanning
changed from 6.557 to 5.757 seconds. The dense single-page 8,192-hit fixture changed
from 816 to 26.48 ms with identical output. This does not replace the pending
hosted release-build timing and interaction check.

Cold-open stress also reproduced Home-only launches. A live system trace shows
the failing initial document event addressed by PID instead of the hinted Mach
port, before macOS starts the stopped application; the receiver then gets a
synthetic ordinary-launch event. No second request is counted as a cold pass.
Keeping the sending process alive did not prevent a failure. Twenty-five later
cold opens with debug logging succeeded, which does not resolve the earlier
failure. The final community-signed candidate and installed-app boundary still
need comparison; no reader fallback, delay or argument parser was added.

Timing from the Debug hosted sweep is not a release performance claim. Likewise,
sampled visual inspection is not a claim that every text page was read or that
every possible file and physical device is error-free.
