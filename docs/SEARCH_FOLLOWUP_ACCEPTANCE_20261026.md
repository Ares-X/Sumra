# Search follow-up acceptance — 2026-10-26

The later [October 27 interaction/performance round](INTERACTION_POLISH_20261027.md)
adds completed-zero-result reuse and a final cancellation boundary. Its focused
checks and negative-query measurements are separate from this historical gate
and dense-query measurements.

Status: the final integrated source gate passed 1,262 tests with no failures or
skips, superseding the earlier 1,242-test search checkpoint. It includes the
later title-page, global-theme, ordinary-open, pinch-anchor and native-tab
corrections. Local search GUI evidence remains as recorded below; the final
bundle's later interaction changes are recorded in the
[October 27 reader acceptance](READER_ACCEPTANCE_20261027.md). Signed 0.2.20
acceptance and publication are pending. Search timings below were not rerun
for the later footer and generated-PDF reload changes.

The first search source check failed one Markdown selected-passage paint wait;
the individual test and its 58-test suite passed on recheck. No product cause
has been established for that intermittent failure. The subsequent 1,242-test
search gate passed and remains historical evidence below.

## Correctness finding and correction

The 0.2.19 stress check covered one rendering history. Comparing fresh searches
with searches after drawing different pages exposed a further problem: the
same 6,591 occurrences and source anchors could acquire different local page
numbers, UTF-16 offsets and highlight rectangles. Full bitmap replay left a
FreeType transform on a shared font face; HTML shaping reset its character
size but did not clear that transform.

`mupdf-html-font-transform-reset.patch` clears the transform under the existing
HarfBuzz/FreeType lock. It adds no font cache, parser or dependency. The native
regression injects a raster transform into the actual fallback face before
laying out authored Han text at two page sizes. It fails against the old
archive and passes against the corrected archive.

The complete 1,471-chapter private stress corpus returned 6,591 matches with
identical ordered JSON, including geometry and source locations, in these
histories: no prior render, first page rendered, middle page rendered, and two
workers with different prior renders. The corrected hash is
`6a540c17f7cec1b306b8cb65a0cc6dac0262684076f14a2b6d646feedebd230b`.
Additional 100-chapter checks used 600/1,200-pixel render widths and an Iowan
Old Style font choice, preserving geometry within each style.

All 73 local MuPDF patches replayed from the pinned clean source in an isolated
tree. Evidence: `build/perf-followup-20261026/native/ft-transform-receipt.json`.
The native experiment's elapsed times and RSS describe a separate probe
process, not the graphical reader.

## Counting work and GUI measurements

The reader and one temporary, independent MuPDF document claim chapter offsets
from the same queue. The reader starts with the visible chapter. Results keep
explicit chapter/page locations, source identities and cross-chapter fragments;
the reader merges only measured chapter counts from the same source and layout
revision before projecting final flat page numbers. Cancellation reaches the
worker, and a worker error cannot publish a successful partial count.

The initial fixed-half split completed a normal GUI count in 9.35 and 10.71
seconds, but a resize during counting took 25.43 seconds. Sampling showed that
one task finished its half while the reader continued alone. Dynamic chapter
assignment addressed that observed imbalance.

| Local release-configuration workflow | Complete count | Input to final count | Peak process RSS |
|---|---:|---:|---:|
| Dynamic assignment, normal count | 6,591 | 9.44 s | 841 MB |
| Dynamic assignment, resize after first result | 6,591 | 13.33 s | 899 MB |

The actual resize started 0.219 seconds after query input, changed the window
from 1,280 × 800 to 1,400 × 899 on the physical main display, and restarted the
count for the new layout. The 13.33-second value includes that restart. It is
not a claim that every workflow is below 12 seconds. Measurements use cached
AX status polling at 100 ms and process RSS sampling at 200 ms; they are not
application frame-rate measurements or promises for other machines/books.

Receipts are `gui-dynamic-reflow-summary.json` (classified as normal count:
its attempted resize was rejected before mutation) and
`gui-dynamic-reflow-main-summary.json` under the follow-up build directory.
The local dynamic candidate reused the already built native libraries and
rebuilt its Swift executable with release/Osize settings; it was ad-hoc signed.
Its identity is retained in `gui-dynamic-candidate-identity.json`.

## Interaction and test coverage

- Full count navigation wrapped 1 → 6,591 → 1 correctly.
- Escape canceled an active high-frequency search and removed its status.
- Replacing an active query with an absent token completed with no matches;
  the earlier results did not return.
- The focused EPUB suite passed five tests, including two concurrent claimants
  covering 1,471 offsets exactly once, source/geometry parity, a worker-owned
  cross-spine match and rejection of an obsolete layout result.
- Independent code reviews of the initial worker and dynamic queue found no
  actionable correctness issue. Those reviews are static evidence, separate
  from the GUI observations and executed tests.
- The earlier search-only frozen source gate passed 1,242 tests with zero failures/skips, plus
  packaging, localization, parsing and reader JavaScript syntax checks. It
  exercised 25 books and all 4,942 comic pages. All 415 source inputs and the
  native engine stayed unchanged during the run. The manual interaction
  harness was excluded; its GUI checks are separate. Receipt:
  `build/perf-followup-20261026/source-gate-final/source-gate.json`. This gate
  predates implementation of the three newly reported requests.

The original issue acceptance remains in
[the issue follow-up report](ISSUE42_FOLLOWUP_ACCEPTANCE_20261026.md).
Issue #42 now has nine comments. The reply at 11:46 UTC adds first-image
sizing/centering, global theme selection and new-window file opening. The
12:34 UTC reply adds native tabs staying visible over the book while the toolbar
is hidden. A direct user observation adds trackpad-pinch image movement. These
corrections are included in the final integrated source gate; final-bundle GUI
acceptance remains separate from that automated evidence. The optional coverless EPUB Finder-thumbnail routing suggestion
remains unresolved on the tested OS; the reporter describes it as an edge case
they can address by adding a cover.

## Final integrated source checkpoint

`build/perf-followup-20261026/source-gate-complete/source-gate.json` passed
1,262 tests, zero failures and zero skips, with 419 source inputs unchanged.
The corpus covered 25 books and 4,942 comic pages. Localization and packaging
checks also passed; the manual interaction harness was excluded. Swift tests
took 640.284 seconds, and the complete gate took 648.851 seconds. Native engine
SHA256 stayed `203171083c375425d457bd476534c27fc995f3daff5c34f79a89b8463dee2e4a`.
This gate includes the final pinch correction, native-tab shared ownership and
borderless-window fix. It supersedes the 1,242-test checkpoint for the current
source scope without changing the provenance of earlier GUI measurements.

Intermediate integrated attempts first found stale localization coverage, then
two obsolete exact-HTML expectations and a borderless AppKit titlebar-accessory
`NSException`. Those causes were corrected before the passing frozen run; the
failures remain part of the validation history. Focused pinch tests passed 6/6
across 13 hosted paths with 0.0-point drift in constrained painted samples.
Twenty toolbar tests and 25 Core legacy-book tests also passed; the corrected
shared-companion fixture fails four assertions against the old implementation.
These are hosted/code checks, not physical trackpad acceptance. Further detail
is in [the issue follow-up report](ISSUE42_FOLLOWUP_ACCEPTANCE_20261026.md).

## Update delivery and cleanup

After the user restored Clash, the actual installed 0.2.18 application downloaded,
installed and relaunched 0.2.19 through Sparkle. All 140 installed files, five
symlinks, 91 directories, modes and signatures match published provenance.
Both Quick Look extensions registered at the official path; the updated app
opened the original Alice FB2. The agent did not change proxy settings. See
`official-update-recovered.json`; the earlier failed TLS attempt is retained.

Completed agents stopped their owned Serena/SourceKit and test/build workers.
Private native variants and the isolated Swift scratch build were removed after
retaining receipts. Shared builds and unrelated processes were preserved.

## Final local visual refinement

After the 1,262-test integrated gate, a physical-display narrow-window check
found the native toolbar overflow chevron remained visible. A toolbar-only
correction now hides/fades its native owner while retaining installed layout;
the full 21-test toolbar suite passed, then three affected regressions passed
after excluding document-content traversal from native-toolbar lookup. This
refinement does not change search or native engine code. Personal user
acceptance now precedes any issue reply or 0.2.20 publication.
