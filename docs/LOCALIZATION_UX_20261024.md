# Interface languages, settings transfer and lookup performance

## Interface scope

The interface offers 25 common language/region options: English, Simplified
and Traditional Chinese, Arabic, Bengali, Dutch, French, German, Hebrew, Hindi,
Indonesian, Italian, Japanese, Korean, Malay, Persian, Polish, Brazilian and
European Portuguese, Russian, Spanish, Thai, Turkish, Ukrainian and Vietnamese.
The other 48 interface catalogs were removed at the user's request. Existing
saved selections fall back to System; Settings displays that effective choice,
and older configuration exports remain importable. Book-script and document-font
support are separate from interface languages.

All retained catalogs cover the 676 translatable keys in the managed interface
inventory. English uses source labels. The inventory includes literal `L` calls
and named dynamic menu/choice owners; runtime engine/provider error text is
outside it. Catalog coverage is not native-speaker linguistic acceptance.

The importer now uses the complete audit inventory, exact upstream matches and
explicit whole-label aliases. `--csv path` accepts a saved upstream snapshot.
Existing entries are preserved except documented clear mistranslations. New
locale-specific messages retain formatting arguments, literal percent escapes,
command templates and irreversible-action semantics. These tokens are checked
centrally. Native-speaker review remains unperformed.

## Settings transfer

Aa and Settings share a 0–200 point margin range. Advanced Settings previously
rejected valid defaults above 96 and omitted encoded per-side margins from export.

Public JSON now contains `pageMargins` as one, two or four numeric point values
in a string. `"10 20 30 40"` means top, right, bottom, left; `""` clears the saved
override. The existing `PageMargins` parser owns validation and encoded
persistence. Import validates the entire configuration before changing settings.
Older exports that omit this key leave it unchanged. Current documents retain
their individual reading settings.

Behavior regressions cover margin 120, transfer of four distinct margins into a
new reader, atomic rejection, blank clearing, old exports and retired-language
configuration compatibility. An initial test-host run lacked AppKit initialization
and crashed before acceptance; it was corrected and the behavior tests rerun.

## Performance evidence

Following the system language previously repeated Foundation's language
negotiation for every localized label. The system fallback is now resolved once
per application session. Explicit in-app language changes remain live, including
returning to System. Changes to macOS preferred UI languages apply next session.

Five standalone optimized trials compiled the actual localization owner against
the same signed 0.2.14 resources. At 10,000 warm text lookups per trial, the median
fell from 287.20 ms to 13.90 ms with identical output checksums. This is the
localization operation, not whole-window latency or a general app speedup.
Reproduction and source identity: `build/maintenance-20261024/localization-performance.json`.

A current B10 full-count probe retained 25 historical-query hits in 10.145 s:
5.523 s candidate parsing/walking, 3.309 s typography, 1.207 s exact search.
This is a single warm native full-count observation, distinct from first-hit
latency and the later 54-hit query. No unproven parser/cache path was adopted.
Receipts: `build/maintenance-20261024/perf/`.

## Acceptance boundaries

The full regression run exposed a partial-spread boundary defect in the browser
reader: restoring the topic end at offset 35,997 was rounded back to 35,700,
preventing the next-chapter command. The shared snapping owner now preserves
the physical end, with explicit asymmetric margins and both reading directions
in the regression. Two other failing fixtures inherited per-side defaults from
an earlier crashed test process, while prelaying out with no override. They now
declare the same style inputs as their manual layout; their original passage,
painted-state and prediction assertions remain intact. Failed-run and diagnostic
receipts are retained rather than clearing preferences to obtain a passing run.

Source, resource integrity, glyph screening and actual UI results are recorded
separately in `build/maintenance-20261024/`. Native-speaker review and macOS 13/15
runtime are not established by this macOS 27.0.1 arm64 validation.
