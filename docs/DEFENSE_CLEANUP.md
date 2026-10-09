# Function-first cleanup

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
