# Reader issue batch: 0.2.47 (49)

This batch addresses #145, #146, #153 and the three normal-toolbar reports in #158. The remaining Finder keyboard interaction in #96 is a separate acceptance boundary. No reporter reply is posted and no issue is closed by the PR description.

## Changes and failures reproduced

- #145: Swift cancellation now reaches the independent WebKit full-text request through its AbortController. Later responses are discarded before parsing and cannot return old text; the next request remains independent. Existing AI preparation UI owns cancelling its task on Cancel, sidebar close and document replacement.
- #146: entire-document extraction includes accessible inline and nested frame text, including srcdoc in an unvisited HTML chapter. Live documents retain WebKit's same-origin boundary. Inert srcdoc is included independently of its inherited DOMParser URL, honors opaque sandbox boundaries and treats sandbox tokens case-insensitively. Listed CHM/HTML chapters remain in their original order without duplication. Export Text and Ask Document continue to use the same extraction owner.
- #153: text thumbnails retain their 8000-character target but stop after 128 KiB of source bytes. A single legal grapheme cannot force repeated decoding of an entire book. Full reading and original files are unchanged.
- #158: revealed normal toolbars paint their own opaque palette surface after tabs are added. The fullscreen companion no longer paints a backing, shadow or titlebar separator outside the real controls. The replaced native caption accessory releases its fullscreen minimum height while hidden and restores it with its prior visibility when ownership ends. The custom 32pt caption row opts out of AppKit's automatic standard-size compression.

Signed 0.2.46 in the existing macOS 26.6.2 VM reproduced windowed toolbar transparency. Instrumented local traces then established that the hidden native row retained a 28pt fullscreen minimum while AppKit compressed the custom row to 28pt despite its 32pt minimum. This is the observed layout failure; no fixed document inset was added.

## Local validation

Evidence remains under `build/issues-remaining47/`:

- `tests-fulltext-before`: 3 real WKWebView cases failed with 5 assertions before the first text fix.
- `tests-unvisited-before`: the unvisited-srcdoc case exposed 3 further failures. `tests-unvisited-inherited-url` recorded DOMParser inheriting the live page URL and WebKit accepting uppercase `ALLOW-SAME-ORIGIN` without normalizing DOMTokenList.contains.
- `tests-unvisited-final`: all 10 relevant WebKit cases pass after the complete text fix, including cancellation, a late body, independent next request, live/inert nested frames, opaque sandbox, CHM deduplication, current selection, HTML encodings and SVG text eligibility.
- `tests-content-final`: 53 earlier passes cover the AI runner/composer, thumbnails and existing extraction paths; its one failed unvisited-srcdoc case was subsequently fixed and rerun above. The optional thumbnail benchmark is skipped. This failed run is retained, not presented as an all-green run.
- `tests-chrome-before` and `tests-native-minimum-before` preserve failing appearance/minimum-height regressions. `tests-layout-final` exercises native layout/tab regressions. Its new exact 32pt assertion exposed a view-installation ordering failure: AppKit applied its standard height before the resize policy was changed. The final policy is set before installing the view. `tests-layout-policy-order` checks the actual 32pt row across native resizes, caption hit areas and native minimum-height restoration; earlier failed attempts are retained.
- `packaging.log`: package metadata, Quick Look declarations and nonvisible language registration passed after the version bump.

## Signed app, publication and limitations

The exact signed candidate from [workflow 43721152589](https://github.com/Ares-X/Sumra/actions/runs/43721152589) has passed full package identity verification: source revision `a9b1b5b250e17c15ab6eb68989dbcc709f2c17e0`, version 0.2.47 (49), main SHA256 `b2bf9d617a8ca48d051b01a7a31d6ebbb739cb7b3746dec3b2c9a2f48270aff8`, accepted manifest SHA256 `5ec405ce698c40b736ecaaf38d14c8ae008ab85746375af62f310bbd6308b1be`. The installed VM main has the same digest and loaded its bundled MuPDF. All six asset digests/sizes, frozen-source correspondence, 140 app hashes and three bundle signatures/certificates/arm64/macOS 13 targets pass. The source download used a verified 206 Range continuation after its bounded first transfer timed out; full-file hash matches.

`tests-release-source` ran the exact committed source: 122 cases, 120 passed, 2 expected platform/optional benchmark skips, 0 failures, unchanged source/engine hashes and cleaned private preferences/clipboard/test hosts. This supersedes earlier partial/failed runs.

Signed macOS 26.6.2 VM acceptance:

- Windowed Auto Hide after Duplicate and New Tab stays opaque. Fullscreen Auto Hide reveals/hides without moving the underlying page horizontally; Always Show has no off-hover dark band. Live trace shows native accessory minimum 0 and custom frame/minimum 32/32. Native fullscreen entry/exit followed by actual Mission Control leaves only the original Desktop, with no extra blank Space.
- Actual Extract Text and its native save panel exported the visible inline frame and an unvisited chapter's inline frame exactly once.
- The 301-topic sample completed too quickly for a cancelled-phase GUI observation; that attempt is not marked as a cancel. A 3001-topic fixture (additional topics are hard links) then visibly showed disabled provider/context and Cancel. Cancelling restored Send and preserved the unsent question. A replacement question completed preparation independently and alone reached the expected CLI-not-installed boundary. No external AI provider request was sent. Controlled WebKit tests independently verify abort, no subsequent fetch, rejection of a late body and independent replacement requests. GUI CPU/RSS peaks were not measured.
- Home → Browse Folder → Thumbnails generated one and then three separate cards for the 5,000,001-byte long-combining-sequence fixture, alongside an equal-byte ASCII reference. Filtering and switching list/grid views remained responsive. Original SHA256, byte count and modification time are unchanged. Unit tests verify the 128 KiB source budget and ordinary encodings; screenshots establish the real Home consumer, not a Finder thumbnail or full-document reader benchmark.
- The actual signed Quick Look extension loaded its bundled MuPDF and `Good-Bad.cbz`. Advancing from good page 2 to broken page 3 retains page 2, its 2/3 label and a visible decode error. Previous returns to good page 1 and Next returns to page 2.

The initial candidate was staged outside the Applications directory, where default PlugInKit matching still selected the old 0.2.45 extension despite the new registration. After quitting, checking consumers and moving the identical signed bundle to the task-owned `~/Applications/Sumra-Candidate47.app`, default matching selected both 0.2.47 extensions. Finder nevertheless retained its old preview provider until the task-created old preview process exited and the exact old preview registration was temporarily removed. PID 97842 then loaded the candidate extension with SHA256 `66582df3947edcf3068f4c8b4d6f966114d70b0a4b7b83b203ca96b340b3c134`. That registration is leased for restoration after acceptance; original app bundles and preexisting thumbnail processes are preserved. No global thumbnail cache was purged. Local probes are diagnostic comparisons, not the released bytes.

The reporter's macOS 15.7.5 has not been exercised: only the existing macOS 26.6.2 VM is authorized. One windowed CBR mode-switch capture also put the native title under the window controls; subsequent stable PDF new-tab and hide/reveal captures were aligned. That transition is not claimed resolved. #158 remains open for these rendering boundaries.

#96's original damaged-page cursor/button recovery is already released and passed the actual signed Finder check above. Keyboard acceptance still fails: clicking the page image and pressing Left in ordinary Quick Look selects `00 Neighbor.cbz` in Finder instead of flipping the current preview; in fullscreen Quick Look the same key leaves page 2/3 unchanged. #96 remains open. Synthetic panel events do not establish Finder acceptance; no global keyboard monitor or private host takeover is introduced.

Publication and 0.2.46 → 0.2.47 Sparkle acceptance are recorded after the merge, using this same accepted manifest and candidate assets.
