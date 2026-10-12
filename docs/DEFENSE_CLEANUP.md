# Function-first cleanup

## October 12 careful review

The subsequent careful review found two actual position-restoration failures:
an opening used the departing book's history policy, and a deactivation save
during opening could leak the departing book's in-memory Markdown coordinates.
Initial restoration now reads only that book's persisted state using the
opening request's policy. Same-book mode switches retain their in-memory state;
the premature clearing at load entry is removed. The regression fails before
the fix and after the incomplete policy-only correction, then passes with the
final owner separation.

Unused Markdown fragment offsets are removed from both sides of the native
boundary. Continuous search no longer allocates flattened text and a character
map merely to compute those fields; its existing geometry walk establishes source
presence using upstream flattening rules. The result buffer is reused directly.
Paginated navigation keeps its actual UTF-16 index. Seventy-five relevant checks
and the native rebuild pass. The deep review records the system-wheel control
probe's limits; no product workaround or weakened assertion is introduced.

The signed candidate was then exercised on the original books. Its real Sparkle
upgrade exposed a shipped bookmark consumer: 0.2.1 light-theme records omitted
the generated palette CSS from their user-style identity. The exact legacy
light identity is recognized at NativeFile; current candidate records remain
valid, and changed source/user CSS/document-CSS settings remain invalid. This
is compatibility for observed persistent data, not a speculative fallback.
Action `38269882069` completed the real signed GUI upgrade replay, mode cycle
and fresh-process original-book reopen at the same passage. The test feed was
restored and all its reader/collector/server processes retired.

Home's observed natural-flow 100% error is corrected by recording the actual
viewport fraction at the two existing scroll owners, including hidden bars.
It adds one optional persisted field; fixed-page progress remains page-based,
and renderer changes clear coordinates from the other representation. The
original EPUB restoration assertions exposed a distinct legacy two-part
bookmark failure. Initial layout now treats a later page as finite pagination
even without a saved count; unresolved chapter starts retain direct natural
layout. No fallback chain or weakened source assertion is added. Final signed
GUI progress acceptance is pending; the historical 13.528 s cause remains open.

## October 12 second pass

The second pass removes internal paths with no product consumer: PageRows'
old scaling entry and frame/scale wrapper, raw Palm and test-only decompression
adapters, ChapterDetector's line-only scan branch, two PDF signing adapters,
unread signer metadata, signature-dialog coordinate flags, and unused search
result geometry. Geometry returns CGRect directly, PDF extraction consumes the
already parsed Palm database, and text navigation uses its existing restoration
owner. Synthesized Codable keys replace ReadingPosition's identical key list.

The browser search decoder has one authoritative caller. Its unused independent
fetch/parser branch and Promise chain are replaced by direct sequential scanning;
ordering, bounded results, cancellation and active read failures remain intact.
One-time style initialization and immutable page identity no longer have state
wrappers. Signature and annotation preset validation stay at their actual input
owners; multi-page annotation translation runs once. Native PDF bounds lookup
and reflow loading use MuPDF's existing validation and layout owners.

Related tests now exercise the production APIs; obsolete and tautological
assertions are removed. Source/save permissions and persisted-position migration
still have current consumers. The historical 13.528-second opening incident and
signed-candidate original-book GUI acceptance remain open in the
[release checklist](RELEASE_CHECKLIST.md).

The [October 12 deep upstream review](SUMATRA_DEEP_IMPLEMENTATION_REVIEW_20261012.md)
records removal of the MOBI repacker, file-reopening PDF inspection, unused
browser indexes, repeated source/CSS work and render-cache overhead, with their
actual consumers and retained data boundaries.

## October 11 follow-up

The project-owned Python build, packaging, release-feed and localization tools
are replaced by Swift scripts using existing platform tools. The Python packaging
test harness and Python comic archive fixture writers are removed. The completed
ctypes scan probe is retired; its measured result and native display regressions
remain. No Python runtime is bundled or required by the reader.

The unused `--core` build branch had no caller outside its two implementing
scripts. It is removed, so there is one application with all document engines.
TextReader's forced initial-style bypass is unnecessary for a fresh coordinator
and is removed. Its test-only search forwarding wrapper is replaced by direct
tests of the authoritative `TextSearchOptions` API.

A suspected Contents mouse failure was disproved by actual event-to-scroll
tracing. The unnecessary mouse rewrite, its added test and all temporary trace
code are removed. The demonstrated slow destination passage extraction instead
uses its existing viewport region, avoiding whole-chapter text shaping without
another index or fallback.

Reading and Home now default to the existing light palette, with manual theme
choices retained. Actual original TXT acceptance exposed a color-only style
change losing the distant viewport: TextKit invalidates its estimated layout
when foreground attributes change. The existing style owner now captures and
restores its source position for that change too. A mounted 40,000-line neutral
regression fails before the fix and passes with the 24-case TextLayout group;
no extra position store, delay or fallback is added.
The final normal app also preserves the original 51 MB TXT's entire captured
822-character passage through theme changes and a fresh-process reopen, with
the light painted background verified independently.

The retained checks have current consumers: native patch probing preserves
unknown source edits, archive inventory verifies the artifacts being emitted,
and display/source identity preserves the user's original documents. No new
dependency, arbitrary input cap, retry or protective wrapper is added.

Focused Swift packaging behavior checks and isolated full-app packaging pass;
the full-engine release build also completes with Python commands disabled and
loads successfully in the canonical GUI. Its final Contents navigation and
fresh-process original-book position checks pass. The delivered bundle keeps
the requested arm64/macOS 13 target and its complete decoder set;
the current reader integration and original-book results are recorded in
[the corpus report](BOOK_CORPUS_ACCEPTANCE.md). Completed agents' owned indexing,
analysis and test processes are stopped, with exact ownership receipts retained
locally. Shared services and original books are preserved.

Candidate854 removes unused bookmark/authenticated-open wrappers, duplicate grid
settings coercion, repeated native search truncation, repeated source/app hashing
and test-count/status policy gates in release receipts. Actual archived output
still matches its inventory. The status documents now share one [current work
list](RELEASE_CHECKLIST.md); old narratives are retained once as a compact snapshot.

Release packaging also omits Sparkle's unused development headers and modules.
Both updater classes still load from the trimmed framework, and its signature
verifies. The pinned dependency and full corresponding-source inputs are unchanged.

Fifteen affected behavior tests and17 packaging tests pass. The native adapter
rebuild and optimized main build pass; the current code is loaded in the existing
private QA app and reopens the large book's saved100% ending with automatic paint.
854 evidence (internal record retained locally).

## Completed853 batch

The development rules in [AGENTS.md](../AGENTS.md) now prioritize features,
response time, size and direct implementation. Speculative checks, duplicate
validation, fallback chains, retries, arbitrary input limits and protective
abstractions are prohibited. Complete a coherent batch, then validate it;
unchanged evidence does not need another run.

This batch removes:

- The shared 512 MiB decoded-data policy and its CArchive header, append
  wrappers and custom MuPDF stream/attachment-limit patch.
- The 16,384-pixel render/edit cutoff, 128-megapixel resize cutoff, 1 MiB XMP
  and AI metadata limits, and 64 MiB collective attachment limit.
- Extra PDF/DjVu traversal-depth cutoffs, selection byte-budget plumbing,
  and the unused flow-allocation test-injection wrapper.
- Certificate XML/number-of-list and Google Lens payload cutoffs.
- Rechecking internal reading-position values, silent renderer-selection
  failure fallback, redundant JavaScript configuration defaults and swallowed
  search-bridge/regular-expression failures.
- Historical internal MuPDF patch-prefix compatibility, repeated patch and
  bundle prechecks, and automatically running the entire test suite on every
  app build. `scripts/check-source.sh` owns unified validation.

Passwords, document permissions, format and ABI representation, object cycles,
resource ownership and rendering batches remain actual document behavior.
WebKit requires error descriptions in serialized NSError userInfo; the boundary
now performs one direct conversion rather than conditional reconstruction.

All 853 discovered behavior cases have passing results (94 core, 759 app),
including affected rechecks and completion of previously unexecuted cases.
This is combined coverage, not one final full-suite invocation. Sixteen
packaging checks, JavaScript/shell syntax, all four native engine builds and
the optimized release main build pass. The obsolete multi-terabyte image test
was replaced by integer-representation rejection and a successful 17,000-pixel
wide export; other positive image/format assertions remain.

The current MuPDF sequence contains 41 patches over 28 pinned base files;
base digest is `48581b9f77166c43ce07daec85e490117e5461e7b4f48b5d39db7e56a3210599`.
The old internal tree was migrated once; no retired-patch compatibility layer
was added to product scripts.

Per-case results and logs (internal record retained locally),
native deletion diff (internal record retained locally),
Swift deletion diff (internal record retained locally),
script migration evidence (internal record retained locally).

The existing review app and original book bytes are unchanged. Candidate853 was checked in source/build only while the native automation
connection was unavailable. It recovered during854, which now loads the integrated
source in the existing private QA app. No public signing key was used. D2
large-Markdown runtime acceptance was subsequently completed by the integrated
Find build. D3 browser PDF Unicode is resolved by the approved native print/export
route in855; see the current work list and output evidence. VoiceOver stays user-deferred.
