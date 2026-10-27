<p align="center">
  <img src="docs/images/sumra-brand.png" alt="Sumra — a lightweight, open-source reader for macOS" width="720">
</p>

# Sumra — A Lightweight macOS Reader

**Ebooks, comics, PDFs, images and Markdown. One native Mac app, focused on reading.**

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

**macOS 13+ · Apple Silicon · Free and open source**

[**Download for Mac**](https://github.com/Ares-X/Sumra/releases/latest) · [Release notes](https://github.com/Ares-X/Sumra/releases) · [Supported formats](#supported-formats) · [Build from source](#build-from-source) · [Report an issue](https://github.com/Ares-X/Sumra/issues)

Open an EPUB novel, a comic archive, a folder of images, Markdown notes or a PDF from Finder. Read in native Mac windows and tabs, choose your layout, and use contents, search and bookmarks to find your place.

![Sumra displaying Markdown reading notes and contents in light mode](docs/images/reader-light.png)

<details>
<summary>More screenshots: two-page reading, recent files and dark mode</summary>

![Two-page reading with the contents sidebar](docs/images/reader-two-pages.png)

![Recent documents on the Home screen](docs/images/home-light.png)

![Reading in dark mode](docs/images/reader-dark.png)

All screenshots use the repository's [original demo document](docs/demos/Reading-Notes.md).

</details>

## Install and start reading

1. Download the app ZIP from the [latest release](https://github.com/Ares-X/Sumra/releases/latest) and unzip it.
2. Move **Sumra.app** to **Applications**, then open it.
3. Press **⌘O** or drag a file into the window. Press **⌘F** to search its text.

Public builds use the maintainer's **Ares-X Code Signing** self-signed certificate, rather than an Apple Developer ID certificate, and are not notarized. If macOS blocks the first launch and you trust the download, follow [Apple's instructions](https://support.apple.com/en-us/102445): open **System Settings → Privacy & Security → Open Anyway**, then confirm.

**Updates:** choose **Help → Check for Updates**, or enable automatic checks in Settings. Sparkle verifies the update and installs it after your confirmation. Each release also includes corresponding source and SHA-256 checksums.

<details>
<summary>Compatibility and older installations</summary>

The release targets **Apple Silicon (arm64)** and **macOS 13 or later**. Bundled executables and libraries are checked for arm64 support, deployment targets and runtime dependencies. GUI acceptance has been performed on macOS 27.0.1; a physical macOS 13 machine has not yet been verified.

Version 0.2.0 has no update feed. Install a newer release manually once; 0.2.1 and later support in-app updates. PostScript and EPS require a separate Ghostscript installation.

</details>

## Made for reading

- **Native windows and tabs.** Open from Finder, drag files into Sumra, or continue from Home. Enable **Use window tabs** in Settings to keep multiple books together.
- **A layout that suits the document.** Single-page, continuous scrolling and two-page spreads, with themes and typography controls. Reflowable books adapt to the window; fixed pages keep their original geometry.
- **Find your place.** Contents, chapter-title search, full-text search, thumbnails, bookmarks and optional reading-position history. TXT and MOBI can detect standalone chapter titles when an authored table of contents is absent.
- **Navigate comic collections.** Archive folders become Contents entries with their names and nesting preserved. Suitable solid LZMA2 archives support distant jumps through an in-memory section index, without modifying the original or writing an extracted book cache.
- **Work with PDFs.** Fill forms, edit annotations, undo and redo, extract or merge pages, and save your changes. PDF editing is locked until you choose **Enable Editing**. **Save a Copy** retains editable forms and annotations; **Export PDF** makes a static reading copy.
- **Listen, print and export.** Read text or a selection aloud with system speech, print through the macOS print panel, or export a PDF. Available operations depend on the format and document permissions.

Use the sidebar for Contents, thumbnails and bookmarks, the **View** menu for layout and theme, and Settings for typography, history and tabs. **Help → Keyboard Shortcuts** lists commands; shortcuts can be customized in Settings.

Choose from five built-in reading themes, or save your own text, background and link colors. **View → Document Colors → Choose Theme…** previews the selection; **Customize…** creates a named palette or edits the selected custom theme. Previously saved theme settings remain readable:

![Preview of Sumra's five built-in reading themes](docs/images/themes.png)

Choose installed fonts from the reading **Font** menu or Settings. The **Aa** reading-settings button applies typography, colors and layout live; **Typography and CSS…** also accepts a family name, such as `Iowan Old Style`, including supplemental fonts macOS omits from its available-font list. Install your own font files with macOS Font Book first. **Light** uses pure white paper. For per-document text, background and link colors, open **View → Document Colors → Custom Document Colors…**. Color wells, RGB fields and an instant preview help you choose; **Use Theme** restores the theme palette.

CHM files expose a separate **Index** tab when they contain a keyword index. EPUB and comic files also support paged Quick Look previews and first-page thumbnails through Sumra's bundled extensions. For EPUB thumbnails, Finder may select Apple Books instead, leaving coverless books with a generic icon. [Editor SyncTeX integration](docs/SYNCTEX.md) and [reading controls](docs/READER_CONTROLS.md) describe the available GUI workflows.

## Supported formats

| Type | Formats |
| --- | --- |
| PDF and fixed pages | PDF, XPS / OXPS, SVG, DjVu |
| Ebooks | EPUB, MOBI, AZW, PRC, FB2 / compressed FB2 |
| Comics and images | CBZ, CBR, CB7, CBT, image folders; common image formats including GIF, TIFF and JPEG XL |
| Text and web | Markdown, HTML / XHTML, CHM, TXT and related plain text, TCR |
| Other compatible formats | PDF-compatible AI, P7M envelopes, LIT |
| Requires additional software | PostScript / EPS: install Ghostscript separately |

Support varies by file variant. Sumra does not provide OCR or DRM removal; scanned pages need an existing text layer for text search.

<details>
<summary>Rendering notes and format limitations</summary>

- Markdown uses MuPDF, with an optional WebKit compatibility mode. HTML and CHM use WebKit for reading; their printing and PDF export use MuPDF layout and may look different from the reading view.
- Reflowable ebooks and native Markdown compact redundant blank prose rows and empty paragraphs, while preserving preformatted text, tables, image blocks and explicit page breaks. Recognized CHM prose also uses compact paragraph spacing; changing its font, size or line spacing overrides publisher styles.
- Neutral text scans in PDFs gain contrast automatically. Turn **Enhance Scanned Pages** off under **View → Document Colors** to see the original appearance. The source file stays unchanged.
- Section indexing skips earlier independent sections in suitable comic archives. A first jump still needs to decode preceding data within the target section; it does not make every unseen jump instantaneous.

See [format and engine coverage](docs/SUMATRA_ENGINE_PARITY.md), [Markdown rendering](docs/MARKDOWN_RENDERER_DECISION.md) and [comic section seeking](docs/COMIC_SEEK_INDEX_20261020.md) for details.

</details>

## Build from source

You need macOS, the Apple Swift toolchain and macOS SDK, and CMake. The first build needs internet access to fetch pinned native dependencies and Sparkle. Project build and packaging scripts use Swift and system tools; Python is not required.

```sh
git clone https://github.com/Ares-X/Sumra.git
cd Sumra
./scripts/build-app.sh --release
open dist/Sumra.app
```

If needed, install CMake with your package manager, for example `brew install cmake`. For a development build and launch, use `./scripts/run-dev.sh`. Local builds are ad-hoc signed by default.

Sumra is a graphical application; opening files, document tools and printing use its interface. For development, see the [implementation notes](docs/IMPLEMENTATION_STATUS.md), [local checks](scripts/check-source.sh) and [release procedure](docs/RELEASE_ACTIONS.md).

## Contribute and translate

Choose among 25 common interface language/region options in Settings. The managed UI labels are translated; native-speaker review is still welcome. Document font coverage is separate and depends on embedded, bundled and installed fonts. See [language support and validation](docs/LANGUAGE_SUPPORT.md) for the list, tested scripts and layout limits.

[Bug reports, feature requests](https://github.com/Ares-X/Sumra/issues) and pull requests are welcome. Include the macOS and Sumra versions, file format, reproduction steps and a shareable sample when possible.

The README is available in English, Simplified Chinese, Traditional Chinese and Japanese. Use [README.md](README.md) as the content reference, keep the same section order, and update the other versions when shared information changes. All versions reuse the same screenshots and link to the technical documentation.

<!-- community-contributors:start -->
## Community contributors

Thanks to everyone improving Sumra through issue reports, code, and reviews. This list is automatically generated from eligible GitHub issues and merged pull requests.

| Contributor | Contributions |
| --- | --- |
| <a href="https://github.com/HomeStarRunnerTron"><img src="https://github.com/HomeStarRunnerTron.png?size=80" alt="@HomeStarRunnerTron" width="40"></a> [@HomeStarRunnerTron](https://github.com/HomeStarRunnerTron) | 📝 [Issue #31](https://github.com/Ares-X/Sumra/issues/31) [Issue #42](https://github.com/Ares-X/Sumra/issues/42) |
| <a href="https://github.com/2924661311"><img src="https://github.com/2924661311.png?size=80" alt="@2924661311" width="40"></a> [@2924661311](https://github.com/2924661311) | 📝 [Issue #48](https://github.com/Ares-X/Sumra/issues/48) |

<!-- community-contributors:end -->

## License and acknowledgments

New Sumra code is licensed under **[AGPL-3.0-or-later](LICENSE)**. Upstream and ported components retain their own licenses and copyright notices; see [THIRD_PARTY.md](THIRD_PARTY.md) for sources, versions and licenses.

Inspired by [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf), Sumra reuses MuPDF and parts of SumatraPDF's document handling with a SwiftUI and AppKit interface. Thanks to [MuPDF](https://mupdf.com/) and the other upstream projects. Sumra is independently developed; the [reference notes](docs/SUMATRA_PARITY.md) describe feature coverage and remaining differences.
