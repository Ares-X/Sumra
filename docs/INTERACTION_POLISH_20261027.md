# Interaction and performance follow-up — 2026-10-27

This follows the [reader acceptance checkpoint](READER_ACCEPTANCE_20261027.md).
The user authorized publication and issue replies on 2026-10-27 after this
local acceptance checkpoint. Signed-candidate and delivery evidence is recorded
separately; the observations below retain their original pre-publication scope.

## Changes

- A completed, unfiltered ebook search with zero matches now reuses that result
  for the same query and options. It uses the existing search lifecycle state,
  without a new document cache or native search strategy. Reflow, changed
  options/page restrictions and clearing search retire the result. Selection or
  cursor misses do not establish a reusable whole-document zero. Editable PDFs
  retain their previous behavior.
- Chapter search checks cancellation, document identity and generation after
  its final asynchronous yield, before publishing a found or empty result.
- Moving the progress slider within its current destination page no longer
  queues navigation or adds a history entry. Unresolved chapter page counts
  cannot establish that a seek is unchanged.
- Progress preview percentage agrees with the actual target page, avoiding a
  percentage change on release. Browser scroll progress remains continuous;
  unknown chapter pagination remains explicitly approximate.
- Removed the redundant tooltip attached to the entire bottom strip, which
  could cover the author text. The native slider retains accessibility help.

## Measured scope

An unchanged toolbar update costs 29–43 microseconds, and a body-pointer event
1.3–2.3 microseconds, in release probes with standalone and SwiftUI ReaderView
hosts. Across 10,000 calls per mode, no unchanged ReaderState publications
occurred. No toolbar caching or animation architecture change was justified.
Evidence and reproduction: `build/chrome-hotpath-20261027/`.

The real-book negative-search benchmark uses the literal
`SUMRA_ABSENT_QUERY_20261027`, a roughly 50 MB / 1,471-chapter book, and a hidden
release NSHostingView running RasterReader. It includes 5 ms polling and bitmap
painting; it does not measure foreground GUI event delivery.

| Same negative-query workflow | Before | After |
| --- | ---: | ---: |
| First scan | 54.519 s | 50.918 s |
| Repeated unchanged query | 45.627 s | 0.01215 s |
| Repeat starts another scan | 1 | 0 |
| Matches | 0 | 0 |

Only the repeated-query improvement is attributable to this change. The initial
scan is unchanged algorithmically. Underscores in this particular query make
the existing conservative native candidate check fall back to its first-rune
test; 856 chapters containing 36,834 pages remain candidates. These times must
not be generalized to all absent queries or confused with the earlier
6,591-match dense-query measurements. The complete first-query latency goal
remains open.

## Validation

The prior implementation failed the new no-rescan assertions in single HTML
and multi-chapter EPUB hosts. A separate initial harness setup timeout was
corrected by performing the same explicit layout as the existing tests; it is
not product failure evidence. A later selection assertion incorrectly assumed
that Select All plus Find excludes all selected matches. The established
wrapped-search contract returns those matches, so that assertion was corrected
and a distinct selected absent-query case added to exercise the nonmemoized
selection path.

Final focused test results, loaded app identity and visible-window checks are
recorded in `build/interaction-polish-20261027/receipt.json` and
`USER_ACCEPTANCE.md`. Earlier issue #48 and native title/tab evidence remains
valid for unchanged code; those checks are not represented as fresh reruns.

The final release-configuration suite passed 19/19 tests, zero failures/skips:
seven search handoff/lifecycle tests and twelve footer tests. The temporary
large-book benchmark was removed after retaining its source and receipts at
`build/perf-followup-20261026/native/negative-summary-20261027.json`.

The final loaded 0.2.20 (22) ad-hoc candidate has executable SHA256
`5ec0b617c96e2a5e03b1d28c997196fb5e475ede38f44025ec08a9f5d76155bb`;
MuPDF remains unchanged at
`3d4050f05b88ea835d05b62a8c1f6545cdfc5ceaced79914176db463fef27282`.
Build and deep/strict signature integrity verification passed. On the physical
M27Q display, the original Alice FB2 completed negative find, repeated forward
and backward negative find, then a replacement `Alice` query with 29 results.
This foreground check establishes behavior, not the hidden-host timing above.

Actual pointer dragging at 1,000 × 800 verified that the preview and committed
destination both read page 5/8 at 57%; same-page input retained the page;
forward-to-end and return-to-start worked. Moving directly into the body hid
the footer. Normal and fullscreen dwell no longer produced a tooltip over the
author. The unchanged-page/title regions (x 0–1,000, y 40–770) are pixel-identical
before/after the same-page drag and footer reveal, including comparison to the
previous 2f71 candidate. The book remains open in a normal window for personal
acceptance. Applications still contains official 0.2.19; no release or reply
has been made.

GitHub #42 and #48 were refreshed during this round: #42 still had nine comments
and updated-at 2026-10-26T12:51:08Z; #48 had no comments and updated-at
2026-10-26T17:47:43Z. No new issue changes or reply were made.
