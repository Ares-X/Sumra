# SumatraPDF feature reference

Sumra targets Sumatra-style document reading with native macOS windows, dialogs
and input. Functional coverage lives in the [implementation inventory](IMPLEMENTATION_STATUS.md),
[UI inventory](SUMATRA_UI_PARITY.md) and [engine/format inventory](SUMATRA_ENGINE_PARITY.md).
The [current work list](RELEASE_CHECKLIST.md) is the single owner of unfinished
work and release status.

Reuse upstream MuPDF behavior for PDF reading/editing, and existing platform
features for macOS integration. Lightweight, fast and minimal remain product
priorities. Invented fallback layers, repeated validation and test-count gates
are not parity features. Windows shell registration, DDE and silent-printing/CLI
interfaces remain outside this graphical macOS product.

Measured performance and sampled real books are recorded in their existing
runtime receipts and [corpus report](BOOK_CORPUS_ACCEPTANCE.md). Historical
measurements describe their actual build and workload; they are not a reason
to rerun unchanged workflows or create additional release requirements.

The [October 20 performance and implementation comparison](PERFORMANCE_PARITY_20261020.md)
pins a fresh upstream tree and distinguishes aligned owners, measured repairs
and remaining capability gaps.

The [solid-seek and EPUB-count follow-up](SEEK_SEARCH_PERFORMANCE_20261020.md)
compares archive replay, retained ebook instructions and native page search,
with separate extraction, count, hosted and signed-app measurements.
