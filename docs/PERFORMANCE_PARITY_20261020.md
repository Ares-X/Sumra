# Performance and Sumatra implementation review — 2026-10-20

This round compares Sumra with official SumatraPDF tree
[`a1120ae6de3b84be0c422dc0da7258e6828c2be6`](https://github.com/sumatrapdfreader/sumatrapdf/tree/a1120ae6de3b84be0c422dc0da7258e6828c2be6).
It covers the reading owners below and the complete local 25-book inventory.
It does not assert equal speed on different operating systems or complete
feature parity. Existing upstream adaptation credits in `THIRD_PARTY.md` keep
the revisions from which code was actually translated.

## Direct owner repairs

- **Reading versus previews:** `ReaderPagePreview` submits sidebar/palette
  thumbnails as background work to the existing render queue. Visible reading
  requests can precede queued previews; an already executing decoder is not
  preempted. Identical requests still share pixels and independent cancellation.
- **Fixed-page geometry:** `RasterViewport.Scroll` reuses the existing arithmetic
  layout for equal-size comics and fixed pages, including PDF cover/spread
  scaling, rotation and RTL. It avoids arrays proportional to the book's page
  count. Different measured sizes use their existing explicit placements;
  natural-height chapters keep their existing geometry.
- **Measured size estimates:** `RasterDocument` reuses its calculated common
  page size until measured bounds change. Repainting a cached page no longer
  sorts all visited page locations. Page-order ties, spacer exclusion and the
  existing distinct-size policy remain the same.
- **Contents:** `ReaderState` already decides when an outline's title, target
  or hierarchy changes. `NativeContentsTree` now consumes that revision and the
  expansion revision, avoiding duplicate full-outline comparisons and AppKit
  expansion queries on unrelated scrolling/status updates. Filtering, selection,
  destination resolution and user expansion retain the same nodes.
- **TXT Find:** the existing Unicode matcher reports accepted ranges during its
  single scan. TextKit selects the first eligible match while result counting
  continues, then retains that exact UTF-16 occurrence when complete snippets
  arrive. Clear, replacement queries, reverse/wrapped searches and Find Next
  during counting retain their cancellation and source-position boundaries.
  Completed misses are reused. There is no second whole-document scan or new
  result cap.
- **CHM Contents:** `indexCHM` builds one canonical path-to-page map after its
  existing unique ordered topic list. Resolving every TOC destination no longer
  repeatedly scans that list. Case normalization, duplicate destinations and
  fragments keep their original behavior.

No dependency, original-book write, extracted whole-book cache or persistent
payload cache was introduced. The 0.2.6 independent LZMA2 section index remains
in use.

## Capability and implementation comparison

| Area | Sumra owner and comparison | Remaining boundary |
| --- | --- | --- |
| PDF reading/editing | One MuPDF `NativeFile`/`Pages` document for permissions, actions, forms, annotations, journal and saving; AppKit controls. Compare [EngineMupdf.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/EngineMupdf.cpp). | Wider imported PDF appearances, scripts, signed/encrypted output and physical printing need their own files and acceptance. |
| Render scheduling | Shared in-flight bitmaps, visible-work priority, cancellation, viewport tiles and directional prediction already correspond to [RenderCache.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/RenderCache.cpp). This round fixes preview admission. | Shared PDF image resources still require serialized replay. No unsupported removal of the replay mutex. |
| Lazy geometry | Measured-size estimation corresponds to [DisplayModel.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/DisplayModel.cpp). Sumra now also uses compact arithmetic geometry for eligible fixed collections. | Heterogeneous newly measured pages can still rebuild explicit placements. |
| Comics and archives | ImageIO decodes near requested size, as [EngineImages.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/EngineImages.cpp) does through its decoders. Sumra's forward cursor and independent LZMA2 sections go beyond [Archive.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/base/Archive.cpp), which reopens misses and retains requested full entries. | A first jump still decodes preceding bytes inside the selected section. Completed encoded entries consume session RAM in both implementations; bitmap eviction does not release them. |
| EPUB/MOBI and large text | Native lazy chapters, source anchors and viewport rendering; TextKit viewport layout for TXT. Compare [EngineEbook.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/EngineEbook.cpp) and [TextSearch.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/TextSearch.cpp). | Whole-book EPUB counts can take tens of seconds. Ordinary MOBI can be decoded once by the compatibility inspection and again by native opening; safely unifying that route needs format-fidelity work. Upstream Find itself can require full ebook layout. |
| Search accuracy | Unicode, whole-word, case/diacritic and direction policy uses the existing matcher; this round improves TXT first-result delivery. Browser Find already yields, cancels and reuses the current DOM. | Fixed PDF/DjVu and paged EPUB search remain page-local for phrases crossing page boundaries. Faster TXT delivery does not close that gap. |
| CHM | CHMLib metadata/codepages/resources, authored topic order, HHC hierarchy, WebKit rendering and cross-topic Find. Compare [ChmFile.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/shared/ChmFile.cpp). | Reading `.hhk` as an HTML resource is not a navigable keyword-index feature; that interface remains absent. |
| Windows, Home and tabs | Native AppKit tabs are preferred by default unless the user disables them. Recent catalog and completed covers are reused in memory. Compare [Tabs.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/a1120ae6de3b84be0c422dc0da7258e6828c2be6/src/Tabs.cpp). | macOS tab behavior is a platform counterpart, not a Windows control port. |

The latest upstream [undo-state repair](https://github.com/sumatrapdfreader/sumatrapdf/commit/a1120ae6de3b84be0c422dc0da7258e6828c2be6)
prevents toolbar/menu state from waiting for a rendering lock on the UI thread.
Sumra already obtains PDF information through an awaited actor operation and
renders controls from published `nativePDFInfo`; the corresponding synchronous
UI lock wait was not found. Adding upstream's non-waiting wrapper here would
not repair an observed Sumra failure.

Additional source differences remain in the dated
[capability gap inventory](SUMATRA_GAP_AUDIT_20261010.md): forward SyncTeX GUI
integration, a floating selection toolbar, destination highlighting/zoom policy,
advanced print choices and object-level dark rendering. They are not silently
counted as complete or made requirements for this performance patch. Windows
shell/CLI/silent-print interfaces remain outside the graphical macOS scope.

## Validation and measurement

The baseline at `cce3c0a` passes all 25 hosted book workflows in an 800 × 600
point window, with warm/uncontrolled filesystem caches. It covers first paint,
first/middle/final source positions, outline navigation and complete or capped
Find counting. Private filenames, queries and bodies are absent from this report;
measurements use stable B01–B25 identifiers.

The full source check passes **117 core and 912 app test items**, with four
opt-in corpus/performance items skipped and zero failures, plus **58 packaging
checks** and the three reader-script syntax checks. The final single-column
landscape eligibility refinement passes a separate **93-case** affected
geometry/prediction recheck. The complete corpus run is explicitly enabled separately.

An owner-only rollback to the baseline reproduces the TXT regression (selection
occurs after all 100,000 results, failing the early-delivery assertions). Its
repaired mounted-reader run passes. These warm, single-run measurements share
the same debug configuration and synthetic inputs; they are neither GUI input
percentiles nor first-pixel timings:

| Measured operation | Baseline owner | Repaired owner |
| --- | ---: | ---: |
| TXT first selected match, 100,000 occurrences | 2.678 s | 0.00106 s |
| 200 unchanged Contents updates, 4,000 nodes | 0.49436 s | 0.000436 s |

The Contents check also preserves node identity, selected chapter and collapsed
branches, then verifies an actual expansion still updates the rows. Fixed-page
regressions compare frames/rows against placed geometry across covers, spreads,
RTL and rotation, restore a tail offset and retain heterogeneous page sizes.
The CHM WebKit regression resolves 3,000 topics with repeated and case-varied
TOC destinations. Unicode observer tests retain global non-overlap ranges and
cancellation; reader tests cover Find Next during counting, clearing and stale
query rejection.

Receipts remain under ignored `build/performance-round2-20261020/`. Hosted pixels
are not physical trackpad smoothness; compact storage and reduced operations
are not by themselves a latency measurement. Loaded-app and signed-candidate
observations are recorded separately after acceptance.
