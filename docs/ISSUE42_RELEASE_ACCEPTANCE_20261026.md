# Issue 42 Release Acceptance — 2026-10-26

**Status: final candidate accepted; publication and installed-update checks pending.** Source commit
`dc2736990265a4761b6b56a0b8edab8acb2b0936` is pushed; its release candidate
Action `40216514470`, final source gate and exact signed-app GUI acceptance pass.
This record separates signed-candidate evidence from current source and pending
release checks. It supersedes earlier documents' current/final labels for this
release cycle; their dated observations remain historical. See the [Issue 42
acceptance record](ISSUE42_ACCEPTANCE_20261025.md), [broad acceptance
matrix](FULL_ACCEPTANCE_20261025.md), [feedback traceability](FEEDBACK_TRACEABILITY_20261025.md),
and [original-feedback recheck](ORIGINAL_FEEDBACK_RECHECK_20261025.md).

## Accepted signed candidate

The accepted app is version **0.2.18 (20)**, host UUID
`BEDE118F-792B-3AE8-A028-F148A3DB323C`, native engine SHA256
`c918c9b0c19c2c4f472bdb12dd0aa1894eb82ffd2e877af184071f0f9a5d57f7`.
Manifest SHA256:
`67cfbab4a332bbc007c92111f1a05cc8088af0fff62e4034c2778a75d29efe0a`.
All runtime checks below used this downloaded app on macOS 27.0.1 arm64,
primarily on BetterDisplay's Virtual 16:9 display. They do not establish
coverage of every macOS release, machine or ebook.

- Correspondence: 13,518 source files, 17 symlinks and 495 Git source files
  match the recorded revision. Original layout replay passes 175 third-round
  checks and eight fourth-round books across 48 paged layouts.
- Five real books pass all 45 equivalence assertions: ordered full/warm
  matches, layout parameters, original preservation and initial, reflowed,
  restored, navigated and post-cancellation pixels. B10 native full search is
  12.062 → 5.095 seconds; warm search is 12.287 → 5.131 seconds, with 25 matches.
- Original AZW3: a physical click while its Chapter 8 hover preview was visible
  navigated immediately; the passive preview closed and no blue destination
  circle appeared. Resizing also removed the preview. Automated original-file
  assertions cover CSS and destination mapping.
- Generated FB2 and MOBI: all four colored image borders and the caption remain
  visible together. The FB2 preceding page contains text without an image
  fragment. Native layout checks also cover the original and generated files.
- Toolbar: 40-point physical hover reveals controls onscreen; Always Hide
  remains hidden, and Always Show in View is reflected in Settings. Selecting
  Auto Hide in Settings updates the open reader. Presentation also reveals the
  controls. Hidden first lines and theme backgrounds are complete.
- Light and Dark fullscreen recordings retain every measured body coordinate
  at one logical-point resolution; window frames do not change. The recorded
  sequence includes grace-period reentry, fade reversal and retention below
  the entry region. This proves spatial stability, not a direct app FPS
  measurement. An initial light recording started late; it is retained, while
  the accepted repeat waits for actual captured frames before input.
- Native window controls: physical green entry/exit, yellow minimize, restore,
  red close and reopening passed before CUA screen sharing attached. macOS
  can replace those controls with a sharing indicator during capture; that
  indicator is not Sumra's normal traffic-light layout.
- Finder: the final candidate's own Thumbnail and Preview processes rendered
  all six unchanged original extensions. CBR advanced 1/11 → 2/11. CBR/CBZ
  covers have correct proportions; AZW3/FB2/MOBI show their first page.
  The coverless EPUB retains its normal Books icon and has a working preview.

Signed-app search was measured separately from the native benchmark. With one
cached AX status element read every 100 ms, cold B10 search completed 25 matches
in **7.873 seconds from Return**, with the first positive result observed
**0.628 seconds from field entry**. A narrow query returned all 54 matches in
9.272 seconds from Return; after widening, the 25-match query took **7.587
seconds**. Input-to-completion bounds, including CUA field editing, were 7.949,
10.559 and 8.795 seconds respectively. The last result reached chapter 1465
with the expected title highlighted. Frequent-query counting could be closed
while active; its 1.218-second click-and-observation time includes CUA overhead,
so it is not claimed as pure application latency. Markdown counted all 1,507
occurrences and navigated to the final one.

The earlier final-app measurement with 61 complete AX-tree observations took
13.556 seconds and remains recorded. Those reads materially load the main
thread; it must not be compared directly with minimal-observer/native timings.
A one-second sample during the cold minimal-observer run found 74/80 main-thread
samples waiting for events and background work in `lf_search_chapter_candidate`.
This is bounded responsiveness evidence, not a claim that every action on every
large file is instantaneous. The final source-level paired probe additionally
proves resumed full pagination, remapping all 25 targets and exact first/last
source geometry after reflow.

Evidence under `build/release-0.2.18/`: `final-signed-gui-acceptance.json`,
`final-search-*-minimal.json`, `final-search-last-ax.txt`,
`final-markdown-last-ax.txt`, `final-dark-motion-analysis.json`,
`final-light-ready-motion-analysis.json`, `final-finder-status.json`,
`final-finder-processes.txt`, `correspondence-check.json`,
`original-layouts.json` and `final-known-five-comparison.json`.
Temporary candidate registration was removed, its owned provider processes
stopped and the original application preferences restored after acceptance.

## Historical signed candidate 9f6134 — passed evidence within its boundary

- Native layout replay: `build/release-0.2.18/attempt3-signed-9f/original-layouts.json`
  records 175 checks across eight books and 48 layouts.
- Five-book search comparison: `attempt3-signed-9f/final-known-five-comparison.json` records B10
  full count 12.062→5.945 s and warm 12.287→5.988 s, with the same 25 ordered
  matches. This is the paired native benchmark for the named query and books.
- Source correspondence: `build/release-0.2.18/attempt3-signed-9f/correspondence-final.log`
  records 13,518 source files, 17 symlinks and 495 checked Git source files.
- Actual Finder acceptance: six original formats passed with the candidate's
  own provider paths selected; CBR Quick Look advanced to the next page.
  Evidence: `finder-signed-9f-acceptance.json`.
- In Native QA, physical traffic lights were revealed; green fullscreen entry
  and minimize passed. The macOS CUA screen-sharing overlay can replace those
  controls. This is historical QA evidence; final signed control acceptance is
  recorded above.

## Source and working-tree status

Signed candidate 9f6134 and its results below are historical, not the current
source state. The 9f full source gate reported 1,223 passed and 3 failed, 1,226
executed; the three failures came from synthetic global fullscreen-notification
pollution. A corrected test passed in an isolated combined 48/48 run. Neither
result substitutes for the final source gate below.

The final source gate at `dc2736990265a4761b6b56a0b8edab8acb2b0936`
passed 1,227 automated tests with no failures or skips, plus all-source parsing,
localization, reader JavaScript syntax and packaging checks. The explicitly
manual `FeedbackInteractionHarnessTests` remains outside that automated run;
its physical-input evidence is recorded separately. All 409 checked source
inputs and native engine SHA256
`6b9b5f58a9d7b9cdcdf94da52c1f30f60f1468386aa41d16272c7d9b44009552`
remained unchanged. Evidence: `build/release-0.2.18/source-gate.json`.

Action `40216514470` built the final signed candidate, host UUID
`BEDE118F-792B-3AE8-A028-F148A3DB323C`. Its six downloaded assets match the
manifest; app and extension signatures, existing certificate, entitlements,
11 Mach-O architectures/deployment targets and Sparkle Ed25519 signature pass.
This is package validation, separate from the following runtime acceptance.

Commit `c0cc394` replaces the static SwiftUI fullscreen policy with the active
fullscreen reader's native `autoHideToolbar` presentation policy. The two-file
change passed real QA: controls appeared at the 40-point entry position; the
hidden first line remained complete; Light and Dark motion recordings retained
all body coordinates at one logical-point resolution; native fullscreen exit,
minimize and restore worked. The single Settings picker also updated the open
reader immediately. This QA host is `84787422-DFFC-3FCC-A745-C643E58594CD`, with
the unchanged signed 9f native engine. It is not the final signed release host.
Evidence: `build/release-0.2.18/fullscreen-chrome/native-policy-acceptance.json`.

The earlier conditional SwiftUI `.onHover` / `.visible` experiment was rejected:
its AX toolbar existed at y=-54 while the actual controls remained offscreen.
That failed experiment is not part of `c0cc394`.

Commit `062d94d` adds per-segment bidi proof, and `dc27369` adds
search-prioritized warm pagination and cached-image first paint. Performance
evidence for the current source is in `build/release-0.2.18/search-scheduling/`
and `build/issue42/native-candidate-20261026/experiment/`. The native
measurement is 5.243 s. The hosted-reader run completed the full query in
6.184 s, first result in 0.183 s, wide query in 6.699 s, and resumed pagination
in 10.447 s; all 25 expected matches were remapped. These are distinct native
and hosted boundaries. The older 9f GUI timing below remains a rejected
candidate result, not the current-source performance result.

Actual 9f GUI search checked 1,507 Markdown occurrences and navigation to the
last match. The 50 MB B10 EPUB returned all 25 expected title matches and reached
the last result; a frequent-query search could be closed while still counting.
However, a query submitted just after resizing the window took 12.633 s from
Return to observed completion. The later scheduling and paint-lifecycle fixes
address the measured contention; the historical native 5.945 s benchmark alone
does not establish hosted-reader latency. See
`build/release-0.2.18/search-gui-9f.json`.

Earlier candidates retain their outcomes: 7bc was rejected for initial viewport
behavior; 446 was rejected for stale hover state; signed 9f was rejected for
clipping the first line against hidden fullscreen chrome. The 7bc viewport
issue and 9f first-line clipping may be related, but their candidate-specific
receipts remain separate historical evidence, not current passes.

## Delivery state

- Publication, update acceptance, and the Issue 42 reply. None is claimed by
  this pre-publication record.
