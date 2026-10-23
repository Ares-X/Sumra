# Reader correctness and integration follow-up — 2026-10-23

This is an isolated source batch based on `0c091c6`, alongside the separate
Issue #31 / PR #32 reading-controls release. It does not change versions, release
feeds, installed apps, user books, dependencies or the GUI-only product scope.
The source, local validation and delivery boundaries below are separate.

## Implemented in this batch

| Concern | Change at the existing owner | Evidence / boundary |
| --- | --- | --- |
| Cross-page phrases | MuPDF search retains physical glyph positions in a query-sized continuation window. One owner page counts each logical hit; every touched page supplies highlight geometry. Finite EPUB keeps chapter/source anchors and cheap conservative candidate checks. DjVu uses its existing word-zone geometry and text matcher. | Native harness plus `NativeCrossPageSearchTests`: four pages, both directions, logical count, original UTF-16 offsets, page restrictions, Chinese, printed hyphens, in-word soft hyphens, ligatures/combining marks, EPUB spine boundaries and font/viewport reflow. DjVu geometry remains approximate word-zone geometry; its new cross-page regression uses representative zones, not a new real DjVu book. |
| Forward SyncTeX | `sumra://synctex` uses the macOS document callback, bundled parser, matching native windows and the existing reload/navigation path. Recompiled page geometry is used, including rotation and changed page boxes. Dormant restored tabs are reused. | [Integration and limitations](SYNCTEX.md). Plain/gzip indices, URL decoding/validation, matching/symlinks and PDF replacement are covered locally. Installed-editor → Launch Services → signed-app delivery remains unexercised. Password-protected editor delivery remains unexercised; legacy `.pdfsync` forward search is not implemented. |
| CHM keywords | `.hhk` metadata and original encoding feed a Contents/Index sidebar, keyword filter and all distinct destinations for a term. Existing HHC contents and full-text search remain. | [CHM index scope](CHM_KEYWORD_INDEX.md); metadata, GBK decoding, duplicate/multiple topics and native WebKit navigation fixtures. Index entries need usable local topics; broader authored CHM variants remain a corpus question. |
| Session startup | Restore native tabs and filenames first. Load the saved current tab; defer other documents until native activation. Preserve unopened tabs' locations when saving/closing and allow explicit opening to supersede restoration. | `SessionRestorationTests` uses hosted native windows/tab notifications, tab order, selection, saved positions and deferred-loader behavior. Explicit saved-tab-group opening remains eager. A relaunch of a signed installed app remains separate. |
| Comic entry retention and cancellation | Separate 64 MiB extracted-byte LRU, retaining recently read/traversed entries; check cancellation between 64 KiB decoder reads. Existing reset indexing and cursors remain. | [Actual bytes, latency and tradeoff](ARCHIVE_MEMORY_20261023.md). The B01 workload retains 67,100,296 rather than 260,542,895 bytes; a distant evicted revisit costs decoding again. This is not a whole-document/process memory limit or a universal speed improvement. |
| PDF input I/O | Hash streaming snapshot-copy bytes while writing, avoiding a separate read of that private copy. Keep pre-open digest and mutation checks. Add content-free timing stages for digest, clone/copy and existing native decode/open. | `NativePDFSourceTests` covers immutable-source streaming copy across multiple buffers, mismatching bytes, source changes/restored mtime and private lifetime. APFS clone still performs the two digest scans; first-screen or NAS speedups have not been measured. |
| Shortcut settings | Search commands, record native keys, show parsed equivalent-binding conflicts, reset one command, retain text multi-bindings and global reset. Recording is local to the focused control. | `ShortcutSettingsTests` covers parser semantics, defaults/reset and native letter/arrow/function-key conversion. These are settings/control tests, not acceptance of every physical keyboard layout. Custom toolbar JSON editing is unchanged. |
| Engine maintenance | Ordered patch → behavior → sample/test inventory. | [57-patch map](MUPDF_PATCHES.md), with direct/indirect/missing evidence labelled and upstream status unknown. This adds no new release gate. |

The search normalization uses the existing MuPDF matcher and Sumra word-boundary
policy; [Sumatra 3.6.1 TextSearch.cpp](https://github.com/sumatrapdfreader/sumatrapdf/blob/3.6.1rel/src/TextSearch.cpp)
was consulted for page continuation and cursor behavior. A printed end-of-line
hyphen can join a word; an authored inline hyphen remains significant. An absent
soft-hyphen glyph does not justify joining unrelated authored paragraphs.

## Existing feedback and evidence still open

- **Issue #31:** colors, themes, discoverable installed fonts, repeated arrow
  input and EPUB cover proportions belong to the parallel controls work. This
  batch neither repeats that development nor claims reporter acceptance. The
  reporter's original EPUB and macOS 15.7.5 validation are still distinct from
  representative samples. macOS 13/15 hardware and physical input/VoiceOver
  acceptance are not established by tests on the local macOS 27.0.1 host.
- **Large EPUB performance:** keep first result, complete count, responsive
  paging, cancellation/replacement and closing as distinct measurements. The
  historical B10 observations (first visible result by 1.230 s, complete count
  by 32.806 s) are not new measurements or a claim of a 33-second startup wait.
  This batch fixes search correctness and retains the continuous search path;
  it does not establish a new large-book count latency. B13 MOBI did not
  reproduce a second decode, so its routing/DRM behavior was left alone.
- **Printing:** the app already delegates to the system print panel and carries
  page range, orientation, scale, centering and duplex preferences. An absent
  application-owned odd/even selector does not prove the system/driver lacks
  it. `lpstat -p -d` on this host reports no configured/default printer. Physical
  manual duplex, odd/even handling, mixed paper, driver selection and output
  therefore remain unexercised. Do not add a second print UI before checking
  that actual system/driver. Browser/CHM screen layout uses WebKit while output
  is paginated by MuPDF; complex CSS can differ.
- **PDF interoperability:** list fields currently commit one selection; this
  is not complete AcroForm support. Existing generated annotation/form/signature
  save/reopen tests are useful but do not replace real third-party-reader
  round trips. The real corpus still has only two PDFs. Expand it with a large
  scan, embedded/subset CJK and columns, imported annotations, Chinese forms,
  mixed sizes/rotation and permissions. Record edit → save → close → reopen →
  external-reader content/appearance evidence for each applicable case.
- **Format fidelity:** constructed fixed-layout EPUB/embedded-font/SVG fixtures
  do not establish every real book. Mixed fixed/reflow chapters, complex text
  and full-page artwork remain representative-corpus work.

## Lower-priority product work

These suggestions are retained as follow-up scope, rather than silently claimed
as implemented: Finder move/rename identity and progress migration; optional
page-offset preservation at high zoom; transient destination indication and
zoom policy; a more unified reading-settings entry; a list editor for custom
extra toolbar buttons; a small contextual selection toolbar; Quick Look/Finder
thumbnail extensions; document-size automatic paper selection. OCR and
object-level intelligent dark rendering remain later optional directions.

CLI argument parity, Windows DDE/registry behavior and silent printing are
excluded by the current product decision. The editor URL callback above serves
the concrete SyncTeX need without introducing those interfaces.

## Validation receipts

Local engine wrappers were rebuilt against the existing pinned, patched static
libraries in a separate worktree. The coordinated full run passed **121 Core and
958 application test items**, zero failures, with four opt-in corpus/performance
items skipped. Native C integration fixtures were enabled with isolated copies
of the existing headers/static libraries and the existing DjVu fixture. After
the final change to resolve SyncTeX geometry through the opened MuPDF document,
**31 affected tests** passed, including the new stale-index destination test,
plain/gzip mapping, rotated replacement geometry, inverse synchronization,
legacy PDF position migration, private PDF inputs and lazy restoration.
The compiled native cross-page harness reports zero failures. All Swift source
parsed for the macOS 13 target, all three reader scripts passed syntax checks,
and **58 packaging behavior checks** passed. The final MuPDF-owner change also
passed affected-file macOS 13 parsing. These are local build/test results on
macOS 27.0.1, not physical macOS 13/15 acceptance.

The first integration run exposed an overbroad CJK separator removal, which also
removed authored spaces/paragraph boundaries and disturbed whole-word/snippet
behavior. The final implementation preserves authored HTML separators and only
joins actual visual seams. Existing separator/UTF-16/word-boundary tests were
retained. New CHM navigation tests wait for the existing command queue and assert
canonical topic identity plus the fragment's displayed location; saved reading
anchors intentionally exclude URL fragments. Integration also corrected native
function-key recording and AppKit tab reordering. Failed intermediate receipts
remain available locally rather than being reported as passing evidence.

Local receipts live under ignored `build/reader-gaps-evidence/` and
`build/archive-memory-evidence/`; source books and private queries are not
exported. No installed binary or public release is accepted by these source
tests. This branch does not alter the parallel 0.2.9 publication or its feed.

All child agents completed. Their transient build/probe processes had exited;
21 confirmed idle per-agent tool/helper processes were retired with SIGTERM
(sum of their prior RSS: 978.2 MiB). Attribution and exit receipts remain under
ignored `build/process-cleanup/`. Shared services, the app backend and the other
chat's release work were retained. This is scoped cleanup, not a repair of the
Codex app's global tool-retention policy.
