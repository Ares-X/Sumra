# Reading-pipeline parity audit — 2026-10-19

This records the 0.2.5 pipeline batch. The subsequent 0.2.6
[independent-section implementation](COMIC_SEEK_INDEX_20261020.md) supersedes
the archive seek-cost description below for suitable LZMA2 streams: first
access starts at the nearest independent reset, while preceding data within
that section still needs decoding.

This bounded source audit compares the owners below with SumatraPDF tree
`ea7d6b7da899752dcf85bb26297f1a13f0393b1a`. It is not a repository-wide parity
proof. “Implemented” describes the current source batch; loaded-app acceptance,
performance measurements and release validation remain separate evidence owned
by the integrating task. No runtime PASS is inferred from this audit.

## Implemented repairs

| Area | Current Sumra owner and change | Upstream comparison |
| --- | --- | --- |
| Solid archives / CBX | [`Archive.data`](../Sources/SumraCore/Archive.swift) retains encoded entries traversed while advancing a solid 7z stream. Complete entries survive cancellation; duplicate names retain first-index resolution. ZIP keeps partial reads. | [`Archive.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/base/Archive.cpp) retains requested full entries. [`EngineImages.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/EngineImages.cpp) loads CBX images lazily and reads headers for geometry. Retaining traversed entries is Sumra's specific cursor repair, rather than a literal upstream port. |
| Decode admission and duplicate work | [`Pages.swift`](../Sources/Sumra/Pages.swift), `Pages.image` / `ReaderImageRender`, shares identical in-flight pixel requests by location, width, region, transparency, style and layout revision. Subscriber cancellation is independent; the final PDF subscriber cancels the shared native cookie. Archived ordinary images finish extraction on the actor, then decode immutable bytes through a private worker ImageIO source. | [`RenderCache.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/RenderCache.cpp), `RequestRendering`, suppresses identical active/queued requests. Sumra retains its existing actor, native snapshots and render queue; independent worker admission uses platform CPU concurrency. |
| Preview retention and prediction | [`Pages.swift`](../Sources/Sumra/Pages.swift), `RasterDocument.retainImage`, retains whole-page previews by the existing 64 MiB byte budget instead of an additional three-image limit. `RasterViewport.Scroll.predictPages` chains the next viewport's pages in reading order, including spreads, and cancels an obsolete direction/layout chain. Prediction does not mount offscreen reader views. | [`RenderCache.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/RenderCache.cpp), `RequestPredictiveRendering`, chains neighboring work while its origin remains relevant. This is a bounded directional counterpart, not a second document cache or unrestricted predecode. |
| PDF replay and content bounds | [`Native/MuPDF.c`](../Native/MuPDF.c) / [`MuPDFDocument.h`](../Native/MuPDFDocument.h) give a document and its immutable snapshots one reference-counted replay mutex. Shared image decoding, including JBIG2 globals, is serialized across the same document. `lf_content_bounds_at` reuses the cached display list; its bbox device clips painted primitives before union and handles mask/tile construction separately. | [`EngineMupdf.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/EngineMupdf.cpp), `RenderPage`, explicitly serializes display-list replay because shared image decoding can race. `PageContentBox` reuses the View display list. The macOS fix applies those boundaries at its existing native owner. |

Worker admission does **not** imply parallel native replay within one PDF.
Cloned contexts and immutable lists still refer to shared image resources.
Different documents retain separate replay ownership. SVG, JPEG XL, JPEG XR,
folder-image sources and actual ImageIO-failure native decoding retain their
existing owners; Archive and mutable native documents do not cross to thumbnail
workers.

## Already aligned behavior and deliberate macOS counterparts

- **Native PDF and ebook document ownership:**
  [`Document.swift`](../Sources/Sumra/Document.swift),
  [`Native.swift`](../Sources/Sumra/Native.swift) and
  [`Pages.swift`](../Sources/Sumra/Pages.swift) retain the NativeFile/Pages path.
  EPUB, MOBI and related reflow formats use their existing native document or
  legacy-container conversion path. This audit found no reason to introduce a
  parallel PDFKit document or expand an object bridge. Compare
  [`EngineEbook.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/EngineEbook.cpp).
- **TXT and platform controls:**
  [`TextReader.swift`](../Sources/Sumra/TextReader.swift) uses TextKit 2 viewport
  layout, shared text storage for facing pages, UTF-16 reading anchors and
  selection-preserving rendering highlights. Chapter detection and Find scan in
  background tasks. AppKit owns windows, text input, selection and system dialogs;
  replacing these with Windows controls is not a missing port.
  [`DisplayModel.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/DisplayModel.cpp)
  supplies useful navigation/layout semantics, rather than a macOS UI implementation.
- **CHM and browser Find:**
  [`BrowserReader.swift`](../Sources/Sumra/BrowserReader.swift) and
  [`chm.js`](../Sources/Sumra/Resources/Reader/chm.js) already cover system/window
  metadata, codepages, case-insensitive resource paths, HHC hierarchy and topic
  ordering. WebKit owns authored HTML, frames and resource loading. Compare
  [`ChmFile.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/ChmFile.cpp)
  and [`BrowserDocView.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/gui/win/BrowserDocView.cpp).
  [`sumatra-find.js`](../Sources/Sumra/Resources/Reader/sumatra-find.js) and
  [`markdown.js`](../Sources/Sumra/Resources/Reader/markdown.js) retain DOM Range
  matching, selection-independent highlights and cross-topic results, with
  cancellable chunk scanning, current-DOM reuse and explicit sibling-read errors.
  At the comparison tree, shared upstream Find lives in
  [`BrowserViewCommon.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/ea7d6b7da899752dcf85bb26297f1a13f0393b1a/src/shared/BrowserViewCommon.cpp).
- **Command delivery:**
  [`ReaderState.swift`](../Sources/Sumra/ReaderState.swift), `claimCommand`, and
  [`Pages.swift`](../Sources/Sumra/Pages.swift), the `state.$command` subscriber,
  already deliver the emitted snapshot after the Published setter and claim each
  revision once. The historical lost-command/Find `0 / 0` diagnosis is not evidence
  of a current failure. Browser commands preserve their native readiness and
  acknowledgment lifecycle; TextReader handles commands through its representable.

The new corpus sweep also exposed a macOS search handoff defect: reflow restarted
counting an active EPUB query but skipped navigation when the Find panel was
closed. The existing search owner now resumes navigation independently of panel
presentation; clearing the search still ends the session. A generated EPUB
regression covers selection, Find Next and closing the search during reflow.

## Remaining physical cost and evidence boundary

An uncached jump into a distant solid-7z block still has to decompress preceding
entries. Caching prevents repeating completed traversal; it cannot remove the
first traversal's CPU/I/O cost. Encoded-entry memory grows with traversed entries,
including non-image resources. Cancellation can wait for one complete entry.
The earlier isolated archive-stage observation of approximately 2.3 seconds for
a distant cold access remains relevant; it is not a current-batch GUI latency
guarantee. See [the bounded archive investigation](COMIC_SCROLL_PERFORMANCE_20261019.md).

`PDFRenderHandoffTests` reproduced distinct bitmap identities for identical
overlapping requests before the sharing fix. Its cancellation/identity cases,
`ComicDecodeConcurrencyTests`, native replay/content-bound tests and prediction
tests cover distinct code boundaries. Their existence and source inspection do
not establish that the final executable passed them, that every local book was
accepted, or that real scrolling improved. Final integrated test, loaded-binary,
GUI and release receipts must establish those results separately.
