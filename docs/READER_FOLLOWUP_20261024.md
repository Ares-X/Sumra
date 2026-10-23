# Remaining reader follow-up — 2026-10-24

This batch continues the [previous acceptance record](READER_ACCEPTANCE_20261023.md)
on `fix/reader-gaps-20261023`, in its isolated worktree. The active original
checkout, installed application, release feed and dependencies were preserved.

## Ordinary MOBI decoding

Supported ordinary MOBI now returns the HTML and resources already produced by
`LegacyText.mobiContent`, using the existing `.mobihtml` adapter and the same
MuPDF MOBI HTML flavor. Previously that inspection could discard its decoded
output and ask MuPDF to decode the Palm records again. Unsupported short MOBI
headers and Print Replica keep their existing native/extraction routes. The
now-unused recovery/navigation flags were removed from private return tuples.

`NativeMobiDecodingTests` compares the original native path and adapted path for
four ordinary-book variants (uncompressed/PalmDOC × Windows-1252/UTF-8), with
multiple records, image resources and finite pagination: all page text, page
counts and first/last page bitmap bytes agree. Core coverage retains DRM, HUFF,
trailer, image-index, recovery, navigation and declared-header boundaries. Source
containers remain unchanged. This is representative parity, not an assertion
that every real MOBI has identical layout.

An isolated 771,957-byte generated ordinary MOBI (189 text records) confirms the
old route returned no adapter and the new route retained 770,113 decoded HTML
bytes. Inspection observations were 217.89 ms before and 161.13 ms after. Native
open/first-bounds observations were 1.09/40.44 ms for the original container and
0.69/39.88 ms for its adapter. These are single warm-process stage observations;
regex initialization and caching can affect them. They do not establish an app
first-frame improvement or a causal 56 ms saving. The verified improvement is
removal of the redundant text decode.

## PDF choice calculations

The existing MuPDF choice-array setter now schedules its normal dependent
calculation owner, so changing a multi-select list updates calculated fields in
the same live undo transaction. `Field.value` reads an inherited PDF `/V` array
as a JavaScript array of strings, preserving an export such as `001`. Scalar
conversion is unchanged (the existing scalar `001` behavior is numeric `1`).
MuJS allocations occur outside Fitz exception scopes.

The generated `/CO` fixture checks multiple exports, clear, scalar selection,
numeric strings, dependent calculated values, undo/redo, save, close, reopen and
unchanged original bytes. The new ordered patch is number 59 in the
[patch map](MUPDF_PATCHES.md); the expanded pinned-base manifest was independently
verified against the pinned upstream file.

Array keystroke/validation events, script assignment of arrays and the full
`currentValueIndices`/`changeEx` APIs remain outside this implementation. Complete
AcroForm compatibility is not claimed. The existing four public PDF save/reopen
samples were included in the full regression run.

## Actual editor delivery and authenticated reload

VS Code was opened in a dedicated fixture workspace. Its process task invoked
macOS `/usr/bin/open -a <exact private app> <sumra URL>` using `${lineNumber}`.
No Sumra command-line parser was added. The PDF filename contained spaces.

| Editor action | Observed private reader |
|---|---|
| Source cursor at line 42, run forward task | Cold-launched PDF at page 1/2 |
| Source cursor at line 84, run task again | Same `reader-AppWindow-1`, page 2/2 |
| Run editor fixture rebuild task (atomic PDF/index replacement) | Same window automatically updated to page 2/3 |
| Run forward task again at line 84 | Same window, page 3/3, new page text visible |

The private bundle used its own preferences and had no registered default
`sumra` URL scheme. The explicit `open -a` delivery therefore did not replace the
installed app's URL handler. The reader and owned editor window were closed
without quitting other existing VS Code windows. The fixture used a constructed
valid SyncTeX index; no LaTeX compiler was installed, so a real compiler/editor
extension/shipping-installation workflow is not accepted by this observation.
An example process task is documented in [SyncTeX integration](SYNCTEX.md).

A separate native test opens a truly encrypted PDF with its reader password,
reloads through forward SyncTeX, uses the replacement document geometry and
retains the password while still rejecting unauthorized editing. This corrects
the earlier blanket statement that authenticated forward geometry was
unsupported. First-time password entry through the complete editor workflow
remains unexercised.

## Search experiment rejected

A candidate-only identity fast path for U+3400–U+9FFF passed all 27,648 scalar
reference checks in exact/folded modes, native candidate parity and natural
phrase fixtures. It did not improve the actual B10 workload and was removed.
The final source and engine retain the previous search implementation.

| Unchanged B10 query | Existing | Experiment |
|---|---:|---:|
| First native hit | 23.659 ms | 22.922 ms |
| Full count, 1,471 chapters | 30.159 s | 30.436 s |
| Logical results | 54 | 54 |
| Exact result JSON SHA-256 (offsets/source/highlight fragments included) | `75258b35c8f24bde0eec19028ead4052ae60dd2c4a736c3be8b3312e3e3b64b9` | same |

These single sequential runs are sufficient to reject this proposed gain, not
to estimate a timing distribution. Full EPUB count latency remains a documented
limit. The earlier request-specific cancellation fix and its evidence remain
valid; this batch adds no claim about visible first-result latency or paging
during the longest native actor call.

## Validation and cleanup

The full suite completed **121 Core + 982 application + 3 Quick Look cases,
zero failures, four opt-in corpus/performance skips**. All four public PDF
interoperability samples were enabled. After removing the unused private return
flags, the 25 LegacyBook and two native MOBI cases were rebuilt and passed again.
The 58 packaging behavior checks and 59-patch pinned-source gate passed.

The final 48 MiB ad-hoc development app includes both Quick Look extensions and
passes strict deep signature verification. Its main binary UUID is
`0E9EB78A-6EFB-3593-A507-42BC32CA150B`; MuPDF is
`3FACC529-8A67-3143-98A3-55DF17A17B9E`. The deployment target is macOS 13;
that metadata is not physical older-system acceptance.

Receipts and probe sources are retained under ignored
`build/remaining-20261024/`: `all-tests.log`, `final-mobi-tests.log`,
`packaging-tests.log`, `patch-gate.log`, `editor-uat-receipt.json`,
`final-receipt.json` and `cleanup.json`. The final app is `final/Sumra.app`.
No publication, notarization, installation, physical-printer output,
older-macOS acceptance or full VoiceOver workflow is inferred from these checks.

One bounded source agent was reused; it finished without starting background
build/index/probe processes. A fresh lifecycle/tool-start/process attribution
audit found no confirmed surviving tool servers owned by that agent. Shared
services and the original checkout's active work were preserved. Temporary
native probe executables and the isolated UAT app/preferences were retired after
retaining their evidence; the final development bundle remains available.
