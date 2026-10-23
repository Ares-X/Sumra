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

Find and Contents retain marked input across interface updates; candidate
confirmation/cancellation stays with the input method. Theme names preserve
literal Unicode, including combining marks and emoji. Automated tests use
the native `NSTextInputClient` composition/commit APIs. This is distinct from
physically choosing an input method and its candidates.

Reflowable EPUB CSS vertical writing and ruby are not currently implemented
by the native reflow engine. The representative Mongolian sample is Cyrillic,
not traditional vertical Mongolian. An installed font alone does not provide
these layout features. Screen-reader pronunciation and speech voices also
depend on macOS and have not received a full language-by-language review.

## Interface translations

There are 73 locale catalogs, including regional/script variants. Settings
marks incomplete translations; missing labels use the original English.
Simplified Chinese covers the current inventoried translatable UI keys. This
is key coverage, not proof of translation or typography quality.

The October 24 update adds interface entries using explicit reviewed upstream
equivalences and new Sumra-specific translations for core theme/font/status
flows in 21 locales. New prose has not been reviewed by native speakers.
The remaining untranslated key sets are reported precisely by:

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
