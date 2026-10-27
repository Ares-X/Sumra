# Sumra 0.2.21 release acceptance — 2026-10-27

The requested five rounds and the follow-up fixes for issues 52–54 are shipped
in [0.2.21](https://github.com/Ares-X/Sumra/releases/tag/v0.2.21), build 23.
Implementation is recorded in [PR 56](https://github.com/Ares-X/Sumra/pull/56)
and [PR 57](https://github.com/Ares-X/Sumra/pull/57). The source revision is
`6a5209cb46bd003e765575633970408d63a94ba9`.

The [five-round report](FIVE_ROUND_READER_POLISH_20261027.md) explains each
repair and its fail-before evidence. The [issue follow-up](ISSUES_52_54_ACCEPTANCE_20261027.md)
records the TXT anchor and reversible chapter-progress fixes. Those reports
are source checkpoints; this report completes their release delivery.

## Code and behavior checks

The combined affected runs passed **284 distinct behavior tests**. The final
joint issue run passed 7 Core and 124 app tests with no failures or skips.
Other checks passed: 58 packaging checks, Quick Look registration, six
contributor tests and all 25 localization catalogs. This is affected coverage,
not a new full-suite run. The unchanged opt-in 100,144-match stress case was
not rerun; the two original-file pinch cases passed with their original inputs.

The preview fixtures reduced decoded image allocation from 4,178,304 to
61,440 bytes for a thumbnail, and from 84,074,880 to 1,689,600 bytes for a link
preview. These measurements concern those bitmaps, not total process memory
or a general first-open latency improvement.

## Exact candidate and publication

[Candidate Action 40477022475](https://github.com/Ares-X/Sumra/actions/runs/40477022475)
built and signed once from the source revision above. The earlier Action
40472906352 was canceled before staging a candidate when the maintainer added
the new issues. It did not publish a release or update the feed.

The accepted `SHA256SUMS` digest is
`600e761e9aa10e6860a7f9c9ca2b5aa4571281dc3d1a136d8ee77d4094083a36`.
All five manifest entries passed. The extracted app matched all 140 files,
file/directory modes and five symbolic links in provenance and the frozen
build receipt. Its executable SHA-256 is
`241e1d55025c47ab2db03ab10539cebc68e5c162cbac066a6085e51e59a68243`.
Strict/deep code verification and the Sparkle Ed25519 signature passed.
The existing community certificate SHA-1 is
`066AF413DC67F84BD8C2EA06B5CF0BAA14E5CAFD`; this is not a notarization claim.

The corresponding-source archive matched 13,550 files and 17 symbolic links
in provenance. All 527 included Git files matched the committed bytes and
spelling, including `Tests/test_community_contributors.py`. The existing
source allowlist excludes root `AGENTS.md` and `appcast.xml`. The clean Action
receipts resolved the local exported-MuPDF inventory limitation without
replacing or resetting that checkout.

[Publish Action 40479494369](https://github.com/Ares-X/Sumra/actions/runs/40479494369)
published the accepted assets and then updated the feed, with no rebuild.
Anonymous verification of all six public assets, unchanged asset IDs and the
public feed is recorded in `build/release-0.2.21/public-verification.json`.

## Loaded signed app and installed update

The signed candidate was loaded from the verified extracted bundle on this
arm64 Mac running macOS 27.0.1. Observed GUI workflows were:

- A single wrapped TXT line containing Chinese and non-BMP text: create
  bookmarks B/C/A, observe A/B/C order, navigate forward B/C/A and back to C.
  All three self-created bookmarks were then deleted.
- Open the final one-page native Markdown chapter and switch to continuous
  reading while retaining the ending.
- Open PDF page 12, show thumbnails and observe the sidebar at the end with
  the current page included. Mixed-size facing PDF pages 2/3 render together;
  the continuous-mode transition also loads.
- Search the original Alice FB2: 29 results, visible result navigation,
  close Find and turn the page.
- Merge five loaded document windows into native tabs, invoke Close All Tabs
  once and observe Home after the whole group closes.
- Filter the Home folder list by `Novels`, press Return to enter the child,
  observe an empty search editor and `Book.txt`, then open it with Return.

The installed `/Applications/Sumra.app` started at 0.2.20 (22). Sparkle offered
0.2.21, downloaded it, and Install and Relaunch started a new installed process.
The installed bundle matched the candidate's full inventory and certificate.
A subsequent check reported 0.2.21 as the newest version. After quitting and
verifying that no Sumra process remained, a fresh installed-app launch opened
and rendered the original Alice FB2.

## Preservation and limits

The two original Alice inputs and the 12-page PDF retained their hash, size
and modification time. Functional defaults and the bookmark store match the
pre-QA snapshot. The two fixture-only Markdown renderer overrides were restored.
Only the last open-panel directory, two window/dialog geometry entries and
Sparkle's last-check timestamp changed. Unrelated `AGENTS.md`, `.serena/` and
the Sumatra comparison document remain untouched.

Two superseded local 0.2.21 app backups and the two verified duplicate public
archive downloads were retired (247,298,692 bytes). The existing 0.2.20 backup,
current local bundle, installed release, accepted assets and receipts remain.

Physical trackpad behavior, full-book initial-search latency and coverless
EPUB Finder-thumbnail provider selection retain their documented limits.
Standalone signed-app pointer dragging of the hidden footer was not confirmed
through the available automation; hosted native AppKit drag, keyboard and
accessibility tests passed. Issue 55's PDF-digest, clipboard and Find-strategy
leads remain unconfirmed. The issues were not closed or publicly replied to.

Machine-readable receipts, test logs and GUI evidence remain under
`build/release-0.2.21/` and `build/reader-polish-20261027/`.
