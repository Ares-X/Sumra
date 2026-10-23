# Language support audit — 2026-10-23

Follow-up: the Hebrew, variable-font and marked-input defects were addressed
for 0.2.10. See [current support and limits](LANGUAGE_SUPPORT.md). The findings
below are the historical 0.2.9 audit, not the current feature status.

The 0.2.9 release did not receive comprehensive world-language acceptance.
Its passing suite included 18 representative font glyphs, Hebrew source-order
copy, Thai shaping/export, CJK PDF appearances, Unicode search, supplementary
characters and language-preference fallback. These checks did not establish
correct reading, typography or complete UI translations for every language.

## Findings

- **Confirmed defect in public 0.2.9:** default serif Hebrew renders missing-glyph
  boxes. Text extraction and search still succeed, so those checks alone miss
  the defect. The old glyph test used system Helvetica, which already contains
  Hebrew and therefore bypassed the broken serif fallback.
- **Local fix, not released:** preserve the script face returned by
  `CTFontCreateForStringWithLanguage`. Asking for its style a second time can
  replace Times New Roman with `.TimesFB`, whose absent file URL prevents the
  existing FreeType loader from reading it. The base font was already styled
  before the script lookup. Regular, bold, italic and bold-italic Hebrew glyph
  regressions now pass; reading and PDF export use a real installed Hebrew face.
- **Open font limitation:** macOS 27's Kefa III Bold is a variable instance of
  `KefaIII.ttf`. CoreText reports `KefaIII-Bold`; the current slim FreeType build
  disables `TT_CONFIG_OPTION_GX_VAR_SUPPORT` and exposes the default regular
  face. The PostScript-name matcher cannot load the bold instance. Regular
  Ethiopic text passes; this audit does not claim its variable styles work.
- **Partial UI translations:** there are 73 locale catalogs, including regional
  variants. Most contain 251 entries; Japanese has 259, Traditional Chinese 263,
  and Simplified Chinese 782. Missing keys fall back to the English source.
  The English catalog intentionally contains only 12 explicit overrides.
  Catalog counts are neither language counts nor proof of translation quality.
  For example, most locales lack the new Customize/Delete Theme instructions.

## Additional checks

Host: Apple Silicon, macOS 27.0.1. Public checks load the engine directly from
the signed `dist/Sumra.app` 0.2.9 bundle; local checks load `build/engines`.
The signed public app was not replaced or modified.

The fixture has 39 groups: Latin and accents, Greek, Cyrillic, Armenian,
Georgian, Simplified/Traditional Chinese, Japanese, Korean, Arabic, Hebrew,
Persian, Urdu, ten Indic scripts, Thai, Lao, Tibetan, Burmese, Khmer,
Ethiopic, Cherokee, Canadian syllabics, Cyrillic Mongolian and a mixed-direction
sample with combining marks and emoji. These are sample strings, not a complete
language corpus or native-speaker assessment.

| Check | Result | Boundary |
| --- | --- | --- |
| HTML reflow and PDF export, 39 groups | Character sequences preserved | Compared after NFC normalization and whitespace removal |
| EPUB, 39 groups at 600/320-point widths | 78/78 text checks pass; original search count invalid | The original probe counted JSON envelope fields instead of actual matches; it cannot establish search success |
| Exported PDF word queries | Original search count withdrawn pending corrected verification | Query receipts must count the actual matches array; copy can still contain inferred intra-word whitespace |
| Regular glyphs with default Charis SIL and system Helvetica | 34 representative scalars pass | Not exhaustive script coverage |
| Hebrew default font, all four styles | Pass after local fix | Baseline regression failed before the fix |
| Affected font, width-cache, RTL-copy, Thai/CJK-export and localization tests | 11 pass, zero failures | Focused suite; not a new full release acceptance |
| UI key presence | 73 catalogs parsed | No linguistic quality claim |

The UI scan found 427 direct literal `L(...)` keys. Simplified Chinese contains
413, Traditional Chinese 124, Japanese 122, and most other locales 114. Dynamic
menu/command labels are outside that scan, so these are mechanical subset
counts, not overall completion percentages.

Correction on October 24: fresh exports and actual-match queries against the
verified official 0.2.9 bundle found 159/179 exported-PDF words. The 0.2.10 local
engine/output had the same 20 misses, involving inferred intra-word spaces.
The former 179/179 claim is withdrawn. Corrected EPUB queries pass 78/78 in the
local follow-up. Receipts are in `build/language-fix/`; this is not full-script
linguistic acceptance.

Raster review caught the Hebrew defect. Reading/export rasters were also
compared; exact equality is not universal, including for English. This audit
does not treat different antialiasing or raster phases as glyph corruption.
Non-Latin typography still requires language-specific acceptance.

## Evidence and limits

Reproduction scripts, fixture EPUB, before/after Hebrew images, normalized
results, catalog scan and test logs are retained locally under
`build/language-acceptance/`. `acceptance.json` records the scope and open gaps.

Not exercised: native-speaker translation review, systematic RTL UI layout,
vertical writing/ruby/traditional Mongolian, IME composition, screen-reader or
speech language behavior, all Unicode characters, and macOS 13/15 runtime.
Installed system fonts affect coverage. No claim of complete world-language
support, new release, or issue closure follows from this audit.

API reference: [Apple — CTFontCreateForStringWithLanguage](https://developer.apple.com/documentation/coretext/ctfontcreateforstringwithlanguage(_:_:_:_:)).
