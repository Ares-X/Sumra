# Sumra 0.2.20 release acceptance — 2026-10-27

[0.2.20 is published](https://github.com/Ares-X/Sumra/releases/tag/v0.2.20).
The user authorized publication and issue replies after the local interaction
checkpoint. [PR #49](https://github.com/Ares-X/Sumra/pull/49) integrated the
changes; the compiled source is `9a81f7a4cac90b784f9dcf4667a0ddb1fb5d3487`.

## Artifact and delivery

- Candidate Action: [40431973821](https://github.com/Ares-X/Sumra/actions/runs/40431973821).
- Publication Action: [40434678825](https://github.com/Ares-X/Sumra/actions/runs/40434678825).
- Accepted SHA256SUMS digest: `0b6a51aa68541cfa411ea66afdce4e1ac0b6fa4f823ec3aa3c4b7d47f2aba92f`.
- Main executable SHA256: `7c4e6b517db791f008c6aeaa37629b1f5234399ea714c23e22237f087c63dabf`.
- MuPDF SHA256: `2b15d9ca1acd4655559b55c7623bb4cf8cd128748e15ddf9c2873270407f39f3`.

The exact Action-built app passed deep/strict signature verification with the
existing Ares-X certificate `066AF413DC67F84BD8C2EA06B5CF0BAA14E5CAFD`.
Distribution remains community-signed and nonnotarized. ARM64, macOS 13 minimum,
version 0.2.20 (22), update URL and public key match the existing contracts.
All 140 app files and five symlinks match provenance; the corresponding-source
archive verifies 13,538 files, 17 symlinks and 515 committed source files.
Frozen source/build receipt correspondence and the Sparkle Ed25519 signature pass.

Publication preserved all six asset IDs and bytes. Anonymous downloads of all
assets match the accepted candidate; the public update feed is identical to the
accepted appcast. Actual Help → Check for Updates in `/Applications/Sumra.app`
offered 0.2.20 to 0.2.19, downloaded it, then installed and relaunched successfully.
All installed files match the accepted signed app. A second check reports that
0.2.20 is current. After a separate quit and cold launch, the original Alice FB2
opens at its title page. The final reader remains open at 1,000 × 800 on M27Q.
The updater initially relaunched to Home; this is not evidence of automatic
restoration of the previously open window.

## Exact signed-app observations

- Original Alice FB2 title/artwork/author and body images display correctly.
  Real slider input previews page 5/8 at 57%, commits that same destination,
  reaches 8/8, then returns to 1/8. The returned title pixels are unchanged.
- Original Alice MOBI cover, authored separate title page and illustrated body
  render in normal and actual fullscreen windows. File → Open preserves the
  existing FB2 reader. Dark/light changes affect both open readers.
- Two native MOBI tabs follow Auto Hide in normal and fullscreen windows, with
  an opaque theme background. Normal content below y=40 and fullscreen content
  below y=120 are pixel-identical through toolbar reveal. Always Hide exposes
  native Close/Zoom when the system menu appears while keeping tools/tabs hidden.
- Completed negative search, repeated forward/backward negative search and a
  replacement `Alice` query work; the replacement returns 29 matches.
- Seven atomic PDF replacements at 150 ms intervals finish at BUILD 8, page 7/12,
  without an error or loss of the selected page.
- Finder space preview renders original CBR, CBZ, FB2, MOBI, AZW3 and EPUB
  extensions; CBR advances to page 2/11. Thumbnail and preview processes load
  from the exact candidate. Generated comic/book thumbnails retain proportions.
  The coverless EPUB still has the generic Books icon; its Sumra preview works.

Earlier behavior evidence remains scoped to its recorded binaries: 131 affected
cases across the preceding runs, then 19/19 final search/footer tests. Release
preparation additionally passed 58 packaging checks, Quick Look registration
checks and all 25 localization catalogs. A bounded independent source review
found no blocker. These are not a new exhaustive all-suite run.

## Handoff and preservation

Replies were posted and read back in [#42](https://github.com/Ares-X/Sumra/issues/42#issuecomment-6431816798)
and [#48](https://github.com/Ares-X/Sumra/issues/48#issuecomment-6431820050), asking
the reporters to update, verify their usual workflows and describe remaining
rough edges. Both issues remain open.

Temporary candidate registration was removed and its two owned preview workers
stopped. Both selected extensions now resolve to official 0.2.20 in Applications.
Eight original book files retain their hashes, sizes and mtimes. App preferences
match the starting snapshot except `SULastCheckTime`; proxy settings were not
changed. Unrelated AGENTS.md, .serena and comparison-document work was preserved.
The redundant public source-archive download was removed only after verifying
it equals the retained accepted archive. No owned build/test/download worker remains.

Evidence is retained under `build/release-0.2.20/`: `signed-acceptance.json`,
`correspondence-check.json`, `bundle-verification.json`, `public-verification.json`,
`installed-update-verification.json`, screenshots, provider paths and cleanup receipt.
Physical trackpad input remains unexercised, first full-book search is not
universally fast, and coverless EPUB thumbnail provider selection is unresolved.
See [interaction measurements](INTERACTION_POLISH_20261027.md) for the precise
performance boundaries.
