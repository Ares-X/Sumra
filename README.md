![Sumra — a lightweight, open-source reader for macOS](docs/images/sumra-brand.png)

# Sumra — A Lightweight macOS Reader

**Ebooks, comics, images, Markdown and PDF. One native app, focused on reading.**

English · [简体中文](README.zh-CN.md)

[Download for Mac](https://github.com/Ares-X/Sumra/releases/latest) · [Reading features](#reading-and-document-tools) · [Supported formats](#supported-formats) · [Get started](#get-started) · [Build from source](#build-from-source)

Sumra is a free, open-source document reader for **macOS 13 and later on Apple Silicon**. Open an EPUB novel, a CBZ comic, a folder of images, Markdown notes or a PDF from Finder, and read them in a familiar Mac interface. Contents, search, bookmarks and reading positions help you find your place.

Inspired by [SumatraPDF](https://www.sumatrapdfreader.org/), Sumra keeps the reading experience simple. It reuses MuPDF and parts of SumatraPDF's document handling, with a native SwiftUI and AppKit interface for windows, tabs, menus and system dialogs.

![Sumra for macOS displaying Markdown reading notes and contents in light mode](docs/images/reader-light.png)

<details>
<summary>More screenshots: two-page reading, recent files and dark mode</summary>

![Sumra showing the original Markdown demo in a two-page spread with the contents sidebar](docs/images/reader-two-pages.png)

![Sumra home in light mode, with recently read documents](docs/images/home-light.png)

![Sumra macOS document reader in dark mode](docs/images/reader-dark.png)

</details>

Screenshots use the repository's [original demo document](docs/demos/Reading-Notes.md). They contain no private books or user data.

## Download and install

Download the app ZIP from the [latest release page](https://github.com/Ares-X/Sumra/releases/latest). It contains the complete **Sumra.app**, including its document engines, ready to move into Applications. The same release provides corresponding source and SHA-256 checksums. PostScript and EPS require the separately installed Ghostscript noted below.

The current distribution target is **Apple Silicon (arm64)**, with a minimum system target of **macOS 13**. Packaging checks every bundled executable and library for ARM support, the system target and resolved runtime dependencies. The GUI has been exercised on macOS 27.0.1; compatibility on a physical Mac running macOS 13 has not yet been verified.

Installation:

1. Download and unzip the app ZIP.
2. Drag **Sumra.app** into **Applications**.
3. Open Sumra. If macOS blocks it, go to **System Settings → Privacy & Security**, choose **Open Anyway** for Sumra, and follow the confirmation prompt.

Public builds use the maintainer's personal self-signed identity, **Ares-X Code Signing**. This is not an Apple Developer ID signature, and the app is not notarized by Apple, so the first launch may require that confirmation. See [Apple's installation guidance](https://support.apple.com/en-us/102445) for details.

**Online updates**: starting with 0.2.1, use **Help → Check for Updates** to download and install new releases, or enable automatic checks in Settings. Version 0.2.0 has no update feed and requires one manual installation of 0.2.1 or later. Updates install after your confirmation.

## Reading and document tools

- **Open files directly**: use Finder, drag files into a window, or continue from the home screen and recent files. Multiple windows and macOS tabs are supported.
- **Navigate long documents**: contents and chapter-title search, full-text search, thumbnails, bookmarks and remembered reading positions. TXT and MOBI without an authored table of contents can detect standalone chapter titles.
- **Choose a comfortable layout**: single-page reading, continuous vertical scrolling, two-page spreads and left/right page turns are available across document formats. Continuous reflowable ebooks, text and web documents use a natural text stream without screen-sized paper gaps, wrap to the reading window and use the selected text and paper theme. Fixed pages retain their authored geometry. Ebooks and text offer font and typography settings.
- **Listen to the text**: use system speech to read document text or a selection aloud.
- **Work with PDFs**: fill forms, add and edit annotations, undo and redo, save or save a copy. Document tools include page extraction and merging.
- **Read scanned PDFs**: neutral text scans gain contrast automatically. Turn **Enhance Scanned Pages** off in **View → Document Colors** to see the original appearance; the source file stays unchanged.
- **Print and export**: use the macOS print panel or export a PDF. Available operations depend on the document's format and permissions.

PDF editing is locked by default for reading. Choose **Enable Editing** before making changes, then save or save a copy to preserve the original. Saving a copy retains editable forms and annotations; exporting a PDF produces a static reading copy.

## Supported formats

| Type | Formats |
| --- | --- |
| PDF and fixed-page documents | PDF, XPS / OXPS, SVG, DjVu |
| Ebooks | EPUB, MOBI, AZW, PRC, FB2 / compressed FB2 |
| Comics and images | CBZ, CBR, CB7, CBT, image folders; common image formats including GIF, TIFF and JPEG XL |
| Text and web documents | Markdown, HTML / XHTML, CHM, TXT and related plain text, TCR |
| Other compatible formats | PDF-compatible AI, P7M envelopes, LIT |
| Requires additional software | PostScript / EPS: install Ghostscript separately |

Large Markdown documents use MuPDF and support single-page, continuous and two-page reading; WebKit compatibility mode is selectable. HTML and CHM use WebKit for reading. CHM prose fits the reading viewport, and plain-text topics use the reader's typography; repeated fixed-column Chinese prose flows across source line breaks while retaining the source text. Changing the reader font, size or line spacing overrides CHM publisher styles. Printing and PDF export for HTML, CHM and Markdown compatibility mode use MuPDF layout, so the output may differ from the reading view.

Reflowable ebooks and native Markdown compact redundant blank prose rows and empty paragraphs. Preformatted text, tables, image blocks and explicit page breaks keep their layout. Recognized CHM prose uses compact paragraph gaps while retaining its original text.

Format support does not cover every file variant. Sumra does not provide OCR or DRM removal; searching scanned pages requires an existing text layer. See the [format and engine notes](docs/SUMATRA_ENGINE_PARITY.md) for detailed coverage.

Comic archives use their folders as Contents. Folder names and nesting are retained, and each entry opens the folder's first image in the existing reading order.

## Get started

1. Press **⌘O** to open a file, or drag it into Sumra.
2. Open the sidebar for contents, thumbnails or bookmarks. The contents search field finds chapter titles.
3. Press **⌘F** to search document text.
4. The default reading and Home background is light. Use the **View** menu to adjust layout and theme; ebooks and text offer additional typography settings.
5. Return through the home screen or recent files to continue from your last reading position.

Find more commands under **Help → Keyboard Shortcuts**. You can customize shortcuts in Settings.

## Build from source

You need macOS, the Apple Swift toolchain and macOS SDK, and CMake. Build scripts fetch pinned native dependencies, so the first build requires internet access. Swift Package Manager fetches a pinned version of Sparkle. Project build, packaging and checking scripts use Swift and system tools; Python is not required.

```sh
git clone https://github.com/Ares-X/Sumra.git
cd Sumra
./scripts/build-app.sh
open dist/Sumra.app
```

If CMake is missing, install it with your existing package manager; with Homebrew, use `brew install cmake`. Use `./scripts/build-app.sh --release` for an optimized build, or `./scripts/run-dev.sh` to build and launch a development instance. Local builds are ad-hoc signed by default and do not publish a release.

Sumra is a graphical application: file opening, document tools and printing are operated through its interface. See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency sources, versions and licenses, and the [development notes](docs/IMPLEMENTATION_STATUS.md) for implementation progress. [Report a bug or request a feature](https://github.com/Ares-X/Sumra/issues) on GitHub.

## License and acknowledgments

New Sumra code is licensed under **[AGPL-3.0-or-later](LICENSE)**. Upstream and translated components retain their own licenses and copyright notices; see [THIRD_PARTY.md](THIRD_PARTY.md).

Thank you to [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf), [MuPDF](https://mupdf.com/) and the other upstream projects. Sumra is independently developed and is not an official SumatraPDF release. Feature coverage and remaining differences are recorded in the [SumatraPDF reference notes](docs/SUMATRA_PARITY.md).
