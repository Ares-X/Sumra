# Sumatra engine, format and PDF feature inventory

Reachable reading/editing routes reuse the pinned upstream engines and existing
native adapters. PDF behavior uses one MuPDF `NativeFile`/`Pages` document; AppKit
owns GUI controls and dialogs. The [current work list](RELEASE_CHECKLIST.md) owns
remaining issues and observed runtime status. Format boundaries below describe
implemented scope, not additional speculative release requirements.

## Format and decoder routes

| Reference behavior | Sumra owner/route | Boundary |
| --- | --- | --- |
| PDF, encrypted PDF, AI containing PDF, signed P7M envelope | `Document.swift`, `NativePDF*.swift`, `Native/MuPDF.c`; Security unwraps the envelope before MuPDF reads it. | Encryption/permission variants and signer trust need broader files; envelope extraction is not trust verification. |
| EPUB, XPS/OXPS, standalone SVG, FB2 and zipped FB2 | MuPDF plus existing archive extraction. | Fixed EPUB and malformed/variant corpus; this route is separate from browser inline-SVG Find. |
| MOBI/PRC/AZW text, HUFF/CDIC, KF8 resources, guide/TOC and AZW4 Print Replica | `LegacyText.swift` and MuPDF MOBI/HTML paths. | DRM, every Kindle container and record variant unsupported; format record representations and output preservation remain part of the decoder. |
| Palm DOC/TealDoc, TCR and LIT | Translated legacy text adapters, native text reader and ConvertLIT. | Ordinary Plucker binary records and LIT DRM5 unsupported. |
| Markdown/HTML and CHM | Automatic native large-Markdown path with cmark/WebKit compatibility mode; Markdown zoom changes typography at physical page scale 1, preserving passage/selection and later scrolling during font loading. HTML/CHM retain whole-page zoom. Sibling headings are parsed on Contents/palette demand. Literal Find yields cooperatively without changing the document DOM or CSS and rejects obsolete scan/restoration results. Find requests immediate match positioning without rewriting authored smooth-scroll CSS or selection. A shared range iterator resolves text endpoints once for range extraction and speech, avoiding repeated distant-boundary comparisons. Speech word highlights use binary lookup over existing UTF-16 offsets; body-only eligibility, layout-rectangle checks and partial-node mapping remain. CHMLib reads book-local topics/resources. Explicit native/browser choices retain separate positions. | Giant documents at extreme sizes, broader authored styles and process relaunch, inline-SVG Find foreground behavior and broader CHM script/resource variants. The 855 form/frame/print-media snapshot passed GUI export and print-to-PDF. Earlier bounded local checks covered ordinary Markdown window reflow/selection; integrated evidence is summarized in the [current work list](RELEASE_CHECKLIST.md). |
| DjVu, image/comic archives, image folders and multi-frame images | DjVuLibre, libarchive, ImageIO and native JPEG XL/JPEG XR paths. Comic Contents uses actual archive folders, preserves nesting and natural image order, and opens each folder's first image; flat archives have no fabricated filename outline. | Solid seek cost, archive-password variants, OS codecs, JXL 8-bit/HDR display and uncommon real files. |
| PostScript/EPS | Optional external Ghostscript conversion. | Availability, converted-container Save a Copy and output inspection. |

Core dispatch and sniffing live in [Sources/SumraCore](../Sources/SumraCore), the GUI reader in [Sources/Sumra](../Sources/Sumra), and native adapters in [Native](../Native). The [format table in the README](../README.md#supported-formats) describes user-visible routes.

Native reflow uses [mupdf-css-user-important.patch](../Native/mupdf-css-user-important.patch)
to rank user `!important` above publisher `!important`, including inline styles,
before comparing selector specificity. Shorthand properties retain that priority.
Publisher layout and images remain enabled; ordinary declarations retain MuPDF's
existing specificity and source-order behavior. Sumra's theme and explicit custom
CSS share the user stylesheet, so specificity and order still decide between their
important declarations. This patch addresses important declarations rather than
implementing every CSS cascade origin or layer.

## PDF document behavior

Native continuous reflow uses an explicit MuPDF layout entry to expose the
existing HTML zero-height natural layout, preserving the public paged API's
default-height contract. The maintained patch also prevents authored viewport
metadata from forcing page dimensions in this mode. Fixed-layout chapters retain
their original geometry. Viewport tiles and clipped rectangle text extraction use
the existing render and selection APIs; continuous chapters do not allocate a
full-height preview or accessibility character snapshot.
The HTML text-region patch reuses upstream draw groups before shaping visible
paragraphs and source glyphs. Finite pages retain upstream page clipping; natural
chapters use font-metric bounds to keep partially visible boundary lines.

The [2026-10-23 follow-up](READER_GAPS_20261023.md) adds physical-page phrase continuation, CHM keyword indexes, forward SyncTeX, lazy session startup and bounded archive entry retention. It distinguishes source validation from installed-app/editor/printer acceptance. The [2026-10-10 gap audit](SUMATRA_GAP_AUDIT_20261010.md) remains a historical snapshot; object-level dark rendering and broader interoperability remain open.

The [large-text performance investigation](LARGE_TEXT_PERFORMANCE_20261010.md)
compares the current upstream page/text cache boundary with natural-height
chapters, records the measured source-restoration allocation reduction and
retains the remaining whole-chapter CPU limitations.

| Function | Existing path | Acceptance boundary |
| --- | --- | --- |
| Reading, labels, outlines, destinations, links/actions, embedded files and images | Live MuPDF document through `NativePDF.swift`, `NativePDFActions.swift` and `Pages.swift`. | Remote/action variants, malformed graphs, attachments and exact corpus rendering. |
| Forms and scripts | AppKit editor commits values into the same MuPDF/MuJS document; calculation, validation, appearance and journal changes share it. List fields currently commit one selection. | Multi-select list fields, broader field types, IME/hardware input, permissions, scripts and saved-reopen matrix. |
| Annotation creation/properties/clipboard/undo | `NativePDFAnnotations.swift`, `NativePDFClipboard.swift` and MuPDF journal cover notes, text marks, shapes, ink, stamps, attachments, redaction marks and supported gestures. | Imported appearances, chosen colors, geometry handles, flags, cross-window and other annotation types need wider current-build GUI checks. |
| Save and copy | Ordinary PDF Save uses live source; converted/extracted containers offer edited PDF or original-container bytes through Save a Copy. | External replacement, encryption, signatures, attachments and output failure matrix. |
| PDF tools | Page extraction/deletion/merge, text/outline/XMP and attachment export, images, compression, baking, encryption, redaction and page-image output reuse MuPDF writers. | Catalog-level preservation and output inspection; compression does not promise target size or image quality. |
| Signatures | MuPDF incremental writer plus macOS Security CMS, Keychain or PKCS#12 identity, unsigned/new field and visible placement. Details expose ByteRange/digest and local trust. | Production identity, malformed/cert variants, online revocation and full PAdES/LTV remain unaccepted or unclaimed. |
| Printing | AppKit print panel; live MuPDF PDF output and native page/image routes. Browser/CHM printing and export capture current form values, loaded frames and print media, then paginate with MuPDF. Actual 855 GUI Export PDF and Print → Save as PDF passed. | MuPDF HTML/CSS can reflow browser geometry; exact browser layout fidelity is not claimed. Physical printers and broader final-app print-error handling remain unverified. |

The PDF feature owners are exercised by [app tests](../Tests/SumraAppTests) and [native tests](../Tests/Native), with detailed implementation scope in [implementation status](IMPLEMENTATION_STATUS.md). A passing output fixture is narrower than a general PDF preservation claim. Windows-only shell, device and certificate dialogs have macOS equivalents; CLI and silent print interfaces are excluded from this graphical product.
