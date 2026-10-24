# Language support

Document rendering and interface translation have separate coverage. Sumra
does not claim that every world language, Unicode character or writing system
has received linguistic acceptance.

## Reading and input

PDF, EPUB and native Markdown use MuPDF's shaping and rendering with embedded
fonts, the compact bundled font set and installed macOS script fonts. Text
uses the macOS text system; browser-layout HTML/Markdown use WebKit. Installing
a font in Font Book makes it available to the reading-font controls.

The 0.2.10 changes fix default-serif Hebrew fallback and selected system
variable-font instances. The existing HarfBuzz library pins the selected axes
into static outlines before FreeType loads them. The same bytes are embedded
in exported PDFs, retaining the requested weight without another font engine.
The [HarfBuzz instancing API](https://harfbuzz.github.io/harfbuzz-hb-subset.html#hb-subset-input-pin-axis-location) is part of the existing dependency.

Representative checks cover Latin accents, Greek, Cyrillic, Armenian,
Georgian, Simplified/Traditional Chinese, Japanese, Korean, Arabic, Hebrew,
Persian, Urdu, Indic scripts, Thai, Lao, Tibetan, Burmese, Khmer, Ethiopic,
Cherokee, Canadian syllabics, Cyrillic Mongolian, combining marks and emoji.
The glyph test exercises regular, bold, italic and bold-italic fallback from
the actual default Charis SIL faces. Separate tests verify variable weight in
reading, PDF reopening and independent CoreGraphics rendering.

Viewport copy and assistive text retain zero-width combining marks and ligature
continuations; a geometric selection must not discard their Unicode characters.
Regression samples cover Arabic, Hindi and decomposed Latin text at three widths.
HTML source word boundaries also prevent geometric spacing from breaking words
and their search queries. New PDF exports retain those boundaries as standard
ActualText word scopes, including visual continuation outlines. Reopened copy
and search respect the authored word; visible outlines also contribute to the
highlight when a text-bearing glyph has zero width.

Find and Contents retain marked input across interface updates; candidate
confirmation/cancellation stays with the input method. Theme names preserve
literal Unicode, including combining marks and emoji. Automated tests use
the native `NSTextInputClient` composition/commit APIs. This is distinct from
physically choosing an input method and its candidates.

The 0.2.13 integration also makes Japanese phrases searchable across physical
line wraps in exported PDFs, retaining highlights on each line. Cross-page
PDF/DjVu/finite-EPUB searches retain their per-page fragments and navigation.

The 0.2.12 PDF-export correction addresses the audit's 20 missed queries:
new exports find all 179 sampled words across the 39 representative groups.
Regressions also cover exact copy, adjacent-word phrases, real wrapping,
inline font/color changes and the painted bounds of an Urdu word. A separate
correction maps the installed Oriya MN font's AAT deleted-glyph marker to a
no-glyph source character, preserving the Odia text and preventing its PDF
outline from shifting by a font advance. Ordinary
PDFs without authored metadata retain geometric space inference. Older exports
and third-party PDFs can still contain ambiguous geometry or missing text;
this change does not recover their absent word boundaries. The host PDFKit
extractor also returns visual/reversed order for the Urdu sample in both old
and new output; standard ActualText and Sumra's logical copy do not establish
correct extraction in every external reader. EPUB sample
searches use the actual matches array and pass at both tested widths.

Reflowable EPUB CSS vertical writing and ruby are not currently implemented
by the native reflow engine. The representative Mongolian sample is Cyrillic,
not traditional vertical Mongolian. An installed font alone does not provide
these layout features. Screen-reader pronunciation and speech voices also
depend on macOS and have not received a full language-by-language review.

## Interface translations

Settings offers 25 common language/region options: English, Simplified and
Traditional Chinese, Arabic, Bengali, Dutch, French, German, Hebrew, Hindi,
Indonesian, Italian, Japanese, Korean, Malay, Persian, Polish, Brazilian and
European Portuguese, Russian, Spanish, Thai, Turkish, Ukrainian and Vietnamese.
All retained catalogs cover the 676 inventoried translatable UI keys. English
uses source text. The other 48 interface catalogs were removed; saved choices
and old exported settings resolve to System. Document reading remains independent
of the interface language list.

This is source-key coverage, not proof of translation or typography quality.
Native-speaker review remains welcome. [The October 24 follow-up](LOCALIZATION_UX_20261024.md)
describes settings compatibility, translation provenance and actual checks.
Exact source keys and coverage are reported by:

```sh
python3 scripts/audit-localizations.py --check --json build/localization-audit.json
```

The audit checks catalog syntax, duplicate/empty entries, format placeholders
and the bundled coverage data. Its inventory includes literal `L(...)` calls
and the explicit dynamic menu, fit, theme, icon and choice-list owners. English
uses its source strings and does not require duplicated translation entries;
invariant product/theme names and format acronyms are not counted as missing
translations. It does not infer completion from catalog sizes.

After adding UI keys or translations, refresh derived coverage with
`python3 scripts/audit-localizations.py --write-coverage`, then rerun the audit.

## Acceptance evidence

The initial [October 23 audit](LANGUAGE_ACCEPTANCE_20261023.md) records the
original defects. Follow-up receipts and before/after fixtures are retained
locally in `build/language-fix/` and `build/language-acceptance/`. Test scope,
actual GUI observations and the host OS must be recorded separately from the
release source and published artifact identity. Other macOS versions and
language-specific typography remain unverified unless explicitly exercised.
