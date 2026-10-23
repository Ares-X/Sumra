# Reader batch acceptance status — 2026-10-23

The [goal completion follow-up](READER_GOAL_20261024.md) supersedes the search,
choice-field event/index, first authentication and accessibility limitations
recorded below; earlier measurements remain historical observations.

This record distinguishes source implementation, observed behavior, and scenarios
that remain unavailable or unexercised. It describes the isolated reader branch,
not publication or acceptance of every possible document variant.
The [2026-10-24 follow-up](READER_FOLLOWUP_20261024.md) supersedes the MOBI,
SyncTeX delivery/authentication, form-calculation and patch-count rows below.

| Area | Implemented and checked | Remaining boundary |
|---|---|---|
| Cross-page search | PDF/finite EPUB/DjVu phrase continuation, logical result count, direction/cursor behavior and per-page highlight fragments. Native and Swift fixtures cover CJK, printed/soft hyphens, UTF-16, ligatures, marks and EPUB repagination/source anchors. | DjVu uses representative word-zone fixtures; the user's exact original documents remain separate acceptance inputs. |
| Forward SyncTeX | Local URL request parsing, plain/gzip index lookup, matching/symlink/dormant window reuse and reload using replacement MuPDF geometry. | Configured editor → Launch Services → installed shipping app is unexercised. Legacy pdfsync forward search is unsupported. Authenticated-password reload and local editor delivery were subsequently verified; see the follow-up. |
| CHM Index | HHK keyword sidebar/filter, multiple destinations and source encoding. | CHM variants beyond the maintained fixture set remain format-specific. |
| PDF capture | Capture first; one private-input hash on APFS, hash during streaming copy elsewhere. Opening/save mutation and retained-source tests pass. | B08 warm-filesystem stages were measured; GB-scale NAS/SMB and external-disk first-frame latency were not. |
| PDF editing and saved interoperability | Native multi-select lists, shared field ownership, undo/clear/save/reopen, permissions; four public samples saved/closed/reopened with PDFKit/CoreGraphics and MuPDF. Chinese form value and independent-reader appearance verified. | MuPDF's array setter bypasses scalar form events; complete AcroForm is not claimed. Real complex encrypted, scan, mixed-paper and third-party-reader coverage remains limited; generated fixtures exercise these native boundaries. See [sample protocol](PDF_INTEROPERABILITY.md). |
| Large EPUB | Request-specific cancellation reaches HTML drawing. B10 first native hit 28.60 ms, 54-hit full count 29.70 s; cancel-to-native-return 350.63 → 1.55 ms. | These native timing boundaries differ from visible app latency. A largest uncanceled chapter can occupy the actor for about 570 ms; full counting still has a long tail. |
| Solid comics | Separate 64 MiB extracted-byte LRU; cancellation between decoder reads. B01 retained extracted bytes 260,542,895 → 67,100,296; evicted revisit 2.051 s. | This is not a process-wide memory limit. Cold distant seeks still need preceding solid-block decode. See [archive measurements](ARCHIVE_MEMORY_20261023.md). |
| MOBI | Existing B13 compatibility path measured about 65 ms and returns HTML directly for rendering. | Ordinary MOBI returning nil can still incur compatibility inspection plus native decode. It was not reproduced by that sample; no general optimization is claimed. |
| Finder identity | Original follows rename even when its old name is reused; associations migrate; missing-file progress and Relocate; explicit existing-file opens stay with the selected pathname. Clean pending form input survives PDF rename. Atomic PDF Save refreshes saved bookmark/tab identities. | Cross-volume identity cannot follow an unavailable original automatically; Relocate remains the explicit association step. |
| Tabs and navigation | Startup and named tab groups load native background tabs on activation. Optional normalized page offsets, keep-zoom links, destination ring and Back viewport covered. | Defaults retain prior navigation behavior; physical older-system workflows remain unexercised. |
| Reading settings | Nonmodal Aa panel, installed/editable fonts, typography, themes, margins, layout and CSS. Real private-app checks changed font to Iowan Old Style, theme to Light Warm and link-zoom toggle, then closed the panel on the same reading page. | Physical macOS 15.7.5 color/keyboard behavior and the reporter's original EPUB are unavailable. Existing #31/theme/cover changes are inherited from the separate 0.2.9 work, not redeveloped here. |
| Shortcut/custom toolbar/selection | Recorder/search/conflicts/per-command reset, button list/reordering/symbols, advanced JSON, nonactivating selection tools; focused AppKit tests pass. | Full manual VoiceOver continuous reading/focus/form and every custom toolbar interaction are unexercised. |
| Quick Look | Native EPUB/comic thumbnail and preview extensions use shared decoders. Three tests cover comic order, EPUB SVG/navigation and Retina layout. Real Finder comic preview moved 1/2 → 2/2; EPUB preview displayed its full portrait cover without cropping. | macOS chooses providers; signed/notarized shipping extension delivery and other system versions remain separate. |
| System printing | Actual system panel exposed range, paper, orientation, scaling, and Paper Handling → All/Odd Only/Even Only; Even Only applied, then canceled. | No configured physical printer: manual duplex/output/other papers and drivers unexercised. Automatic mixed-paper selection remains deferred until actual driver need. |
| Patch maintenance | Ordered 58-patch behavior/evidence map with indirect coverage and unknown upstream status labeled. | Map is a maintenance aid; no upstream submission is claimed. |

## Validation receipt

Final coordinated full-suite receipt: **121 Core + 979 application + 3 Quick Look
cases, zero failures**. Four opt-in corpus/performance cases were skipped; the
four public-PDF interoperability samples were enabled. Receipt:
`build/reader-gaps-evidence/final-all-tests-2.log` (application cases: 236.57 s).
Focused identity and real-PDF interoperability checks also passed 11/11. Native phrase
harnesses passed, JavaScript syntax checks passed for chm/markdown/sumatra-find,
and 58 packaging behavior checks passed. The local 48 MiB application includes
both extensions, passes strict deep signature verification and dependency/
macOS 13 deployment checks. It is an ad-hoc development bundle, not notarized.

Host: macOS 27.0.1, Apple Silicon. No physical macOS 13/15, printer, installed
editor integration, or full VoiceOver workflow is accepted by this record.
The existing installed Sumra and update feed were not changed.

## Isolation and cleanup

All seven child agents completed. Their owned probes/builds/indexers were
retired; a final attribution check found no remaining confirmed child-agent tool
servers. Earlier scoped cleanup retired 21 confirmed processes (978.2 MiB of
observed summed RSS, not an OS memory-pressure delta). Shared services and the
other active Sumra checkout were preserved. Temporary UAT app/extension
registrations, preferences, clients and redundant local bundles were removed;
the final development bundle and reproducible receipts remain under ignored
`build/`. No remote publication occurred.

OCR and object-level intelligent dark rendering remain optional directions.
CLI interfaces, Windows DDE/registry behavior and silent printing are outside
Sumra's GUI-only product scope. See [reader controls](READER_CONTROLS.md).
