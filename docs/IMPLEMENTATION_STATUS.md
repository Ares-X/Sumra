# Implementation status against SumatraPDF

[Current work and remaining issues](RELEASE_CHECKLIST.md) is the single status
owner. Feature inventories describe existing routes; they do not add speculative
release requirements or duplicate the history of every intermediate build.

## Owners and scope

Sumra is a graphical macOS reader. AppKit owns windows, controls and dialogs.
PDF reading/editing share MuPDF's `NativeFile`/`Pages` document: passwords,
permissions, actions, forms, annotations, journal undo and output use that owner.
Markdown automatically uses MuPDF for large/dense sources and retains explicit
paged/browser compatibility choices. Ordinary HTML/CHM use WebKit. Build/test
scripts and optional external integrations are distinct from a product CLI.

## Implemented functions

| Area | Existing owner and behavior |
| --- | --- |
| Opening and lifecycle | `Document.swift` and `SumraApp.swift`: format dispatch, passwords, Finder/Open/drop, windows/tabs, replacement cancellation, reload and document-owned temporary inputs. |
| Navigation and layout | `ReaderState.swift`, `ReaderView.swift`, `Pages.swift` and core layout: pages/chapters, history, bookmarks, searchable Contents, thumbnails, zoom/fit and saved positions. All reader routes offer single-page, continuous vertical and two-page reading with left/right turns. Continuous native reflow uses natural chapter height and viewport rendering without paper gaps; text and browser routes retain their natural stream. Reflowable content wraps to the window; fixed pages retain their geometry, cover and rotation options. |
| Search, selection and speech | Native and browser text search, result navigation, exact text/image copy and reading aloud. Browser scans yield and cancel obsolete work; sibling scans respect the existing result budget. Shared range extraction avoids repeated distant-node traversal. |
| PDF editing and saving | `NativePDF*.swift`: AppKit field controls, MuPDF/MuJS actions, annotation creation/properties/clipboard, one journal, Undo/Redo, Save and Save a Copy. |
| Print/export and tools | System print panel, live MuPDF and WebKit output, page/area selection, image/text/outline/attachment export, page operations, compression, encryption, baking, redaction and signing. |
| Markdown/HTML/CHM | Native Markdown plus WebKit compatibility; both offer single-page, continuous and two-page reading. Typography zoom preserves reading passage/selection. CHM prose adapts to viewport width; plain-text topics use reader typography and detected fixed-column Chinese prose wraps naturally without changing source text. Font/size/line changes override CHM publisher styles. Form and table geometry remains authored. Contents loads sibling headings on demand; CHM topics use CHMLib and the existing encoding decoder. |
| Images and comics | ImageIO/native codecs, archive/folder pages, multi-frame GIF/TIFF/JPEG XL and original-resolution output. Archived comic images decode immutable entry bytes outside the archive actor. Suitable LZMA2 archives seek from lazily indexed independent sections without modifying the source or creating a persistent payload cache. Completed encoded entries and forward progress survive cancellation; per-entry CRC checks cover indexed reads. Comic Contents uses actual archive folders, preserves nesting and existing natural image order, and opens each folder's first image. |
| Detected chapters | TXT and MOBI without an authored TOC reuse `ChapterDetector`; MOBI destinations retain original decompressed byte offsets through native HTML anchors. Authored MOBI navigation takes precedence. KF8/AZW3 reconstructs skeleton/fragment content, separates CSS/SVG flows and translates fragment-position links through the same native HTML reader; [issue 42 verification](ISSUE42_ACCEPTANCE_20261025.md). |
| Native reading performance | `Pages.swift`: visible pixels precede chapter counting; finite pages enqueue a directional next-viewport prediction chain and share identical in-flight bitmaps using the existing preview byte budget and natural chapters use viewport tiles, including during mode handoff. Reading modes reuse parsed HTML/CSS and measured font metrics; initial layout uses the actual target viewport. Live reflow resize retains its painted layout until the final width. Generated Markdown without raw HTML uses the XML parser; raw HTML keeps HTML5 parsing. |
| External/platform | SyncTeX/PDFSync, user-triggered optional Ghostscript and AI providers, Sparkle surface, localization, settings, commands and toolbar. |

The [UI inventory](SUMATRA_UI_PARITY.md) and [engine inventory](SUMATRA_ENGINE_PARITY.md)
retain the format and command details. Behavior coverage is in [app tests](../Tests/SumraAppTests),
[core tests](../Tests/SumraCoreTests) and [native fixtures](../Tests/Native).
[Corpus results](BOOK_CORPUS_ACCEPTANCE.md) describe the sampled books.

## Product limits

DRM removal, arbitrary Palm/Kindle variants, OCR, a library database, cloud sync
and telemetry are outside scope. Ghostscript and AI providers require separately
installed software. Online revocation and full PAdES/LTV validation are not
claimed. Compression exposes upstream options rather than promising a target
size. Converted PDFs may lose interactive catalog features. User-facing behavior
and these limits are in [README](../README.md).
