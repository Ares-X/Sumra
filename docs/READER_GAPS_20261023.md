# Reader correctness and integration follow-up — 2026-10-23

This isolated source batch builds on the earlier reader-correctness work and the
separate reading-controls release. It does not change versions, release feeds,
installed apps, dependencies, or the GUI-only product scope. Source changes,
local test evidence, and external workflow acceptance remain separate; see the
[acceptance matrix](READER_ACCEPTANCE_20261023.md). The
[2026-10-24 goal follow-up](READER_GOAL_20261024.md) records the current search,
form, authentication, accessibility and 61-patch results; measurements below
remain the observations from the earlier batch.

## Implemented in source

| Area | Current behavior | Closest evidence / boundary |
|---|---|---|
| Cross-page search | MuPDF keeps physical glyph positions in a query-sized continuation window; one owner page counts each logical hit while touched pages provide highlight geometry. Finite EPUB retains chapter/source anchors and candidate checks; DjVu uses existing word-zone geometry. | Native cross-page harness and `NativeCrossPageSearchTests` cover direction, counts, UTF-16 offsets, page limits, Chinese, printed and soft hyphens, ligatures, combining marks, and EPUB/reflow boundaries. DjVu fixtures use representative word zones. |
| Forward SyncTeX and startup | `sumra://synctex` uses macOS document callbacks and the bundled parser. Startup restores filenames/tabs first, loads the selected tab, and defers other documents until activation. | [SyncTeX details](SYNCTEX.md). Local parser, matching, replacement geometry, and lazy restoration coverage do not establish installed-editor delivery or physical macOS 13/15 behavior. |
| CHM and archives | CHM `.hhk` metadata and source encoding drive Contents/Index navigation; comic extraction has a separate 64 MiB byte LRU and cancellation between decoder reads. | [CHM index scope](CHM_KEYWORD_INDEX.md), plus the earlier archive-memory evidence referenced by the original batch. Cache retention trades repeat-decode time for memory; it is not a process-wide memory cap. |
| PDF input and live editing | Capture-first PDF opening hashes bytes during the single private copy, then opens that immutable snapshot for reading/editing. Save a Copy leaves source bytes unchanged; ordinary Save checks the captured source before replacement. | `NativePDFSourceTests` covers source mutation and private snapshot lifetime. Four public sample PDFs have save/reopen evidence in PDFKit and MuPDF, including annotations and a Chinese form value; source-byte equality is asserted. This is a small corpus, not complete AcroForm or third-party-reader acceptance. |
| File identity and Finder moves | A file bookmark tracks a moved/renamed original, migrates reading associations, reports unavailable files with progress, and supports Relocate. | `FileIdentityTests` includes reused-old-path, migration, and in-place edited-PDF cases. Focused identity regressions cover explicit selected-file opening, old-path reuse, missing-original resolution, clean pending form input during rename, and saved bookmark identities after atomic PDF Save. |
| Navigation and reading controls | Named tab groups restore lazily; page-turn offset preservation, keep-zoom-on-links, and destination hints are implemented. Reading settings expose installed fonts and editable CSS. | `NavigationPositionTests`, `ReaderUsabilityTests`, and the existing lifecycle/appearance suites. Local test receipts are summarized in the acceptance matrix; hosted and physical-device use remains separate. |
| Toolbar and selection | Custom extra-button list/icon editing and a contextual selection toolstrip are implemented. | `ReaderUsabilityTests` covers selection actions, placement, and panel behavior. Custom-editor and end-to-end interaction acceptance are subject to the current test receipt, not inferred from source presence. |
| Quick Look | Two Quick Look app extensions use shared reader core and bundled MuPDF for EPUB and comic previews. | `QuickLookBookTests` exercises comic navigation and a constructed SVG EPUB using the bundled engine. Real Finder verification passed for comic navigation from 1/2 through 2/2; Finder EPUB preview also passed after prelinking the shared engine for the extension sandbox and fixing Retina bitmap fitting; the complete portrait cover was visually inspected. |
| MuPDF patch tracking | The earlier inventory contained 59 patches; the current map contains 61. | [Patch-to-behavior map](MUPDF_PATCHES.md) records closest evidence, indirect coverage, missing fixtures, and unknown upstream status. It is a maintenance aid, not a release gate. |

The search implementation keeps printed end-of-line hyphens distinct from
soft-hyphen and authored inline-hyphen semantics. Do not join unrelated authored
paragraphs merely because a soft-hyphen glyph is absent. The patch inventory
likewise separates patch purpose from what a test exercises.

## Known boundaries

- The final coordinated suite passed 121 Core, 979 application and 3 Quick Look
  cases with zero failures and four opt-in corpus/performance cases skipped.
  Four public PDFs were enabled for independent-reader save/reopen checks.
  Strict bundle/signature checks and 58 packaging behavior checks passed.
- Large EPUB cancellation is measurable but not instantaneous: B10 complete
  count remains 29.70 seconds; cancel-to-native-return improved from 350.63 ms
  to 1.55 ms, while an uncanceled call took about 570 ms. These timings do not
  establish instant live UI cancellation or paging during the largest chapter.
- The actual system print panel showed range, paper, orientation, and scaling,
  with Paper Handling offering All, Odd Only, and Even Only. Even Only was
  applied. There was no configured printer in the earlier host inspection;
  physical printer output, mixed-paper automation, and other drivers remain
  unexercised. Automatic mixed-paper selection is deferred pending actual driver
  requirements.
- PDF list fields currently use MuPDF's array setter, which bypasses scalar
  keystroke/validation events. Dependent calculation and array-valued script reads
  were completed in the [2026-10-24 follow-up](READER_FOLLOWUP_20261024.md).
  Do not claim complete multi-select AcroForm behavior. The
  four-sample save/reopen corpus does not cover all external readers, permissions,
  mixed page sizes, or form scripts.
- Physical macOS 13/15, printer, reporter's original EPUB, and installed-app
  editor-to-shipping-Sumra delivery remain unavailable or unexercised. Local
  VS Code delivery to the private development bundle was verified in the follow-up. OCR and
  object-level intelligent dark rendering remain optional future directions.

Sumra remains a graphical macOS reader. CLI argument parity, Windows DDE/registry
behavior, and silent printing are out of scope. GUI-driven integrations and
build/test scripts remain in scope.

[Reading controls](READER_CONTROLS.md) and [public PDF samples](PDF_INTEROPERABILITY.md) provide reproducible user and test entry points.
