# Sumra 0.2.23 release acceptance

The user accepted the locally installed reader on November 1 after the persistent
PDF top-strip repair. The accepted development executable was
`9acfd6b232562a90174ccc84b107c3a5cf0bd72adf98fed5883e84245bc1da4e`, with MuPDF
`da1d019bf5c1194f13580bed8391b5179757a609ad72fde7391810055f70919c`.

## Verified development behavior

- A real MuPDF document in an AppKit/SwiftUI host reproduced a 40-point top gap
  before the fix. The repaired owner uses the existing toolbar-overlay policy;
  the original pixel and layout assertions pass.
- Paged, facing-page Fit Width checks preserve the raw reading origin and page
  when changing Hidden to Auto Hide or Shown to Auto Hide. The latter increases
  the viewport from 606 to 672 points while preserving origin 441 and page 2.
- A real native UI test on macOS 27.0.1 verifies top-hover reveal, body-hover
  dismissal and a full-screen round trip. Four native screenshots were reviewed.
  A macOS 26.6.2 guest independently verifies the same PDF and mouse interaction;
  its Auto Hide and dismissed screenshots match exactly.
- Related layout checks report 37 passed and 2 conditionally skipped. Fixed-page
  and appearance checks report 79 passed and 2 conditionally skipped. These are
  scoped runs, not an exhaustive final-product or all-issue guarantee.
- Earlier focused regressions and original-document GUI checks cover native
  tabs, saved groups, reading settings, two-page keyboard input, browser/native
  links, annotation dirty-state ordering, text previews and delayed PDF hashing.
  The reported PDF decodes all 454 pages and 101 bookmarks.

The complete local receipts are retained with the task's acceptance evidence.
Intermediate recordings, result bundles, duplicate images and owned guest
snapshots were removed after review. The VM and shared automation tools remain
available; the activity-specific automation mode is disabled.

## Release source checks

The complete local check run found one failing localization case: its 22
assertions identified five missing new clearance labels in the non-Chinese
catalogs. Those translations were completed without changing reader behavior.
All 25 catalogs now cover the managed inventory, the five localization tests
pass, packaging tests and Quick Look UTI registration checks pass, and all three
reader JavaScript syntax checks pass. The other cases from the complete run
retain their results; 25 app tests were conditionally skipped. The failed run
and focused repair checks are retained separately rather than relabeling the
original run as a clean pass.

## Formal release boundary

The official signed candidate is 0.2.23 (25), built from
`4876792a802043101d78630268bc9c1234f1f0b7` through
[successful candidate run 41293263420](https://github.com/Ares-X/Sumra/actions/runs/41293263420)
of [the existing release workflow](RELEASE_ACTIONS.md). Its executable SHA-256 is
`3e7bef5973e8934375553e2a09edf6782e4a275fb651e4d92dbeb8d00544e0af`;
the accepted manifest SHA-256 is
`2d57da93a9b4a4a887dad61d3952eb58885479dc693ae6cf833ebaea92064ca1`.
This is separate from the development executable above.

Formal receipts are under `build/release-0.2.23-20261101/`:

- `candidate-bundle-check.json` verifies the arm64 signed bundle (140 files,
  five symlinks) against the frozen build. `candidate/correspondence-check.json`
  passes source correspondence, including 581 Git source files. The source
  archive's owner allowlist excludes `AGENTS.md`, `appcast.xml`, `design-qa.md`
  and the three `tools/GUIAcceptance.xcodeproj` files. App/build source
  correspondence is verified; a standalone GUI acceptance environment from that
  archive is not established.
- On macOS 27.0.1, the cover-page keyboard full-screen round trip passed
  (`native-ui-summary.json`). Subsequent scrolled-text keyboard attempts timed
  out during XCTest event synthesis, before there was evidence the app's handler
  ran. They remain failed attempts, not a passed keyboard check or an established
  product defect.
- The focused reader then passed the scrolled-text full-screen round trip through
  the native View menu (`native-ui-menu-summary.json` and
  `native-ui-menu-roundtrip.log`). Four named captures were reviewed: normal
  body, top hover, full-screen body and returned body. A later stable body capture
  also showed no persistent top strip. The harness now checks active-reader
  focus and uses that native menu route; this pass does not replace the failed
  keyboard-injection evidence.
- The macOS 26.6.2 guest loaded the exact signed bundle at PID 6647
  (`guest-loaded.json`) and opened the same `original.pdf`. Hover reveal and
  body dismissal were captured and reviewed (`guest-formal-initial.json`,
  `guest-hover-observed.json`, `guest-body-observed.json`). This guest evidence
  covers those interactions, not an independent full-screen round trip.
- Further guest checks observed Restore Tab Group disabled in the actual native
  menu with an empty saved-group inventory. Thumbnail image (page 181), text
  (182), middle blank area (183) and row end (184) each selected their target
  with one click, closed the picker and retained that selection on reopening;
  page order remained intact (`thumbnail-row-zones-result.json`).
- Command-palette text, middle and row-end clicks each opened exactly one Go to
  Page dialog; cancelling preserved the page (`command-palette-row-zones-result.json`).
  Reviewed Finder captures show CBZ/TXT thumbnails and CBZ Space preview moving
  from 1/4 to 2/4. Loaded-library receipts identify the candidate's Thumbnail
  (PID 7665) and Preview (PID 7704) extensions and bundled MuPDF; each extension
  has one current 0.2.23 registration, with no registration changes. TXT Quick
  Look also displayed a readable prefix beginning with the complete `Section 1`;
  its provider may be selected by macOS, so candidate-provider ownership is
  established for the CBZ preview and CBZ/TXT thumbnails only.
- Reviewed guest Home captures show a hover ring on each window button. A real
  minimize click moved owned Home window 1053 offscreen; after restoration, a
  real close click removed it while original PDF window 1017 remained open.
- Reviewed RGB-field captures show readable full selection in light/dark themes
  and the last three characters selected under Graphite in light theme. Values
  remained `#000000` in light and `#F9FAFB` in dark. Every color dialog was
  cancelled without Apply. The temporary Graphite choice was restored to
  Automatic; before/after HighlightColor and Accent preferences match (both
  absent). The reader returned to Light and the task-started Settings process
  quit gracefully. These observed states do not establish every reporter's
  color-selection environment.
- Formal HTML checks show two visible pages without a horizontal scrollbar.
  Down advanced progress to 0.0589468 and Up returned to zero; arrows in the
  input preserved editing (`Xabc`) without navigating. Dragging to 100% reached
  page 18/18 and the next file, `02.html`, opened at zero progress
  (`html-formal-result.json`); three captures were reviewed.
- Reviewed native images of public `sample_illustrated.epub` are pixel-identical
  between 0.2.19 default margins and this candidate's Custom blank margin 32
  with explicit `pageMargins` absent (`old-new-blank-comparison.json`). Both
  used the same file (SHA-256
  `672d0f8c8c95557b86086ea92e0211428ae2db2519e49054e3aa34e92ea9d6f1`),
  system font 17, line height 1.6, Two Pages, Cover off and native Auto Hide at
  full-screen 1129×730. This was a public fixture, not the reporter's original
  book. The candidate's Medium preset separately shows margins 16/32/16/32
  (top/right/bottom/left); its reviewed body has readable typography and margins,
  without a claim that Medium matches the old default.
- Physical mouse clicks/drags on the full-screen floating Auto Hide progress
  slider reached 0, 0.5 and 1. All three reviewed full-display captures show no
  Dock. The slider bounds were y=691, height=20, with 16-point outer clearance
  (`dock-progress-interaction-result.json`). This covers the observed viewport
  and interaction route.
- `native-ui-result-cleanup.json` records removal of nine completed result
  bundles after exporting summaries, logs and selected screenshots. Those
  receipts and required review evidence remain retained.
- The owned Xcode DerivedData directory was removed after checking for active
  consumers. The native UI evidence directory decreased from 248,440 to 43,416
  KiB. Guest comparison preferences were restored exactly for 26 keys, followed
  by the earlier 22-key test baseline. The old comparison app, temporary Quick
  Look links, unused candidate ZIP, captured-image copies and owned snapshots
  were removed after use (104 guest paths). The signed guest candidate remains
  available for handoff and system-managed extension consumers; the VM and
  shared automation tools were preserved.
- Brave compatibility was not exercised and the default browser was not changed.
  The unused task-owned 214,756,164-byte partial download was removed, recorded
  in `brave-preparation-cleanup.json`.

## Public release and installed acceptance

[PR #75](https://github.com/Ares-X/Sumra/pull/75) merged as
`b0e41de807c4a9609a9f8bf77ca29a3d0330cca9`.
[Publish run 41327222591](https://github.com/Ares-X/Sumra/actions/runs/41327222591)
successfully promoted the same accepted bytes to
[0.2.23](https://github.com/Ares-X/Sumra/releases/tag/v0.2.23). Release ID
430481451 and all six asset IDs, sizes and digests stayed unchanged. The public
ZIP was anonymously downloaded and matched SHA-256
`da2b5ab1e922590acb749250df126caebcd11755d5971dd26dcbfacd3f6769ca`.
The live feed matches the candidate feed and the public ZIP's Sparkle Ed25519
signature verifies with the existing public update key.

The actual installed 0.2.22 (24) found 0.2.23 through Help > Check for Updates;
Install Update and Install and Relaunch completed on November 2 local time.
The installed `/Applications/Sumra.app` is 0.2.23 (25): all 140 file hashes,
91 directories and their modes, five symlink targets, and the deep strict code
signature match the accepted bundle. A separate cold application launch opened
the unchanged original PDF through the native Open dialog, identified 454 pages
and followed its third-chapter bookmark to label 73 (physical page 87). The final
Auto Hide body was visually reviewed. Receipts are `installed-bundle-check.json`,
`installed-cold-original-check.json` and `public/` under the evidence directory.

Product source remains `4876792a802043101d78630268bc9c1234f1f0b7`;
the later harness/documentation commits do not rebuild or replace accepted bytes.

## Issue scope

After those checks, #59, #60 and #65–#74 received scoped replies and were closed
as completed, including the two original reporter threads #68 and #69.
`issue-replies-posted.json` retains the comment links. Issue #55 received the
batch update and remains the continuous review index.
Acceptance is bounded by the recorded fixtures and environments; unobserved
environments remain unknown rather than adding an unlimited release gate.
Brave itself was not exercised. Representative performance measurements do not
establish cold-cache or external-volume behavior. User-deferred listening and
physical-input judgments are not recorded as passed.
