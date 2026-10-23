# Performance and Sumatra implementation review — 2026-10-20

The [2026-10-23 follow-up](READER_PERFORMANCE_FOLLOWUP_20261023.md) records
capture-first PDF checkpoints, interruptible search extraction and measured
large-EPUB count limits.

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
are not by themselves a latency measurement. The signed-candidate and installed-app
observations below retain their separate coverage.

## Complete inventory measurements

The corrected **25/25** hosted sweep includes Contents opening, three
source positions and search selection/counting. First confirmed ready is
0.071–2.027 s; TXT readiness includes outline indexing. Contents opening is
0.064–0.244 s. Polling and drawing overhead are included; these are not native
first-frame clocks. The baseline's corresponding first-ready range is
0.068–2.038 s, so this round does not claim a general opening-speed increase.

| Remaining workload | First selection or middle jump | Completed count or final jump |
| --- | ---: | ---: |
| B01 solid comic, new middle/final destinations | 2.634 s | 4.629 s |
| B10 large EPUB Find | 0.181 s | 72.028 s |
| B22 EPUB Find | 5.868 s | 20.959 s |
| B25 51 MB TXT Find | 0.081 s | 0.543 s |

The comic archive owner did not change in this round; its baseline middle/final
jumps are 2.589/4.641 s. These observations retain the section-decoding limit,
not a claimed comic extraction speedup. Full-count times are separate from
first selection and may reach the existing native result cap.

The first extended sweep recorded 24 passes and a CHM timeout. A new early-hit
wait returned before its realm probe while no hit existed, unlike the old
complete-count wait. The hidden hosted WebKit scan then stopped progressing;
its idle-thread sample is retained. An intermediate harness condition also
incorrectly treated the last command action as a pending-command flag and was
stopped. The final harness checks the browser coordinator's actual activation,
validates the destination realm and observes that realm while waiting for the
first hit. CHM then passes at 5.556/5.584 s for first selection/full count.
These probes can wake an occluded WebKit process; browser timings are not
unobserved background performance. The discarded source candidate build was
cancelled, and the signed candidate uses corrected source `af1c4202`.

## Signed candidate, public release and installed app

The accepted source is `af1c4202be127230381ce8bfcf521b031f954c5f`, built in
[candidate run 39425079696](https://github.com/Ares-X/Sumra/actions/runs/39425079696).
The signed 0.2.7 (9) executable UUID is
`FECE7EEA-2D38-3FFB-8DE4-96273FA4DD49`. All 181 files, five links, 130
directories and permission modes match provenance. Code signing, the existing
certificate, nine Mach-O images with arm64 support and macOS 13 deployment
minimums pass. The corresponding source matches all 13,451 files and 17 links,
including 428 exported Git project files. These identity checks do not establish
physical macOS 13 behavior; this round ran on macOS 27.0.1.

The unmodified signed candidate passes **25/25 real-window book workflows**:
opening, scrolling, navigation and Contents open/close. There are at most six
native tabs in the same process. Twenty-three books advance a page/chapter
indicator. The single-chapter MOBI scrolls from 0 to 0.004607 with Next disabled;
CHM keeps topic 1 while its scroll indicator advances from 0 to 1. Lazy canvas
growth can reduce normalized scroll fractions, so those fractions alone are not
an input-to-paint clock. These are sampled workflows, not every-page fidelity
or trackpad frame-rate acceptance.

The actual 51 MB TXT first selects line 10,287 while counting is still active,
then reports 1 / 74 results. Find Next reports 2 / 74, and closing Find succeeds.
This adds real-control delivery evidence to the hosted and synthetic checks.
Four Home list/grid transitions complete using the initial catalog for that
Home owner; new window owners still construct their own catalogs. Background
Home drawing markers do not measure the completion of every cover.

In a retained fresh comic document owner, previously unread destinations 1,050
and 2,097 first draw in **2.600 / 4.560 s**, measured from render request to native
canvas first draw at an 853 × 665 point viewport with warm filesystem caches.
This round does not change archive extraction or erase that section-decoding
cost. Earlier 0.2.6 all-4,942-comic-page decode evidence applies to the unchanged
archive/decoder path; it was not rerun as a new every-page check.

All 25 original SHA-256 values, sizes and nanosecond modification times match
the original inventory after GUI acceptance. User preferences were restored
and verified before the public update. Receipts remain under ignored
`build/performance-round2-20261020/`, particularly `candidate-gui-acceptance.json`,
`candidate-unread-jumps.json`, `originals-after-gui.json` and
`sparkle-installed-identity.json`.

[Publish run 39428869231](https://github.com/Ares-X/Sumra/actions/runs/39428869231)
released the exact accepted candidate as
[0.2.7](https://github.com/Ares-X/Sumra/releases/tag/v0.2.7). All six anonymously
downloaded public assets match the accepted bytes and asset IDs; all manifest
entries, the raw main appcast and the Sparkle Ed25519 signature pass. The public
manifest SHA-256 is
`cff70c545bfb026049135ea2490a59fd41db90e2fbd11c5d5d60c7ffcb365338`.
The app ZIP is 15,777,219 bytes. Signing remains the existing self-signed,
non-notarized distribution; no new trust claim is made.

An actual public **0.2.6 (8) → 0.2.7 (9)** Check for Updates / Install Update /
Install and Relaunch succeeds. The installed app matches all accepted files,
links, directories and modes; its loaded process UUID and About version match
the candidate. The canonical app remains open at B01 page 382, with native
canvas drawing observed and the original file's hash/size/mtime unchanged.
Owned QA apps and log/sample processes were stopped; release archives and
receipts retain recovery and reproduction evidence.
