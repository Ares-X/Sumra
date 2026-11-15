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

- `tests-fulltext-before`:3 real WKWebView cases failed with5 assertions before the first text fix.
- `tests-unvisited-before`: the unvisited-srcdoc case exposed3 further failures. `tests-unvisited-inherited-url` recorded DOMParser inheriting the live page URL and WebKit accepting uppercase `ALLOW-SAME-ORIGIN` without normalizing DOMTokenList.contains.
- `tests-unvisited-final`: all10 relevant WebKit cases pass after the complete text fix, including cancellation, a late body, independent next request, live/inert nested frames, opaque sandbox, CHM deduplication, current selection, HTML encodings and SVG text eligibility.
- `tests-content-final`:53 earlier passes cover the AI runner/composer, thumbnails and existing extraction paths; its one failed unvisited-srcdoc case was subsequently fixed and rerun above. The optional thumbnail benchmark is skipped. This failed run is retained, not presented as an all-green run.
- `tests-chrome-before` and `tests-native-minimum-before` preserve failing appearance/minimum-height regressions. `tests-layout-final` exercises native layout/tab regressions. Its new exact32pt assertion exposed a view-installation ordering failure: AppKit applied its standard height before the resize policy was changed. The final policy is set before installing the view. `tests-layout-policy-order` checks the actual32pt row across native resizes, caption hit areas and native minimum-height restoration; earlier failed attempts are retained.
- `packaging.log`: package metadata, Quick Look declarations and nonvisible language registration passed after the version bump.

## Signed app, publication and limitations

Final signed candidate and GUI acceptance are pending. Local probe binaries are diagnostic comparisons; they are not the released bytes. The reporter's macOS 15.7.5 has not been exercised: only the existing macOS 26.6.2 VM is authorized. #158 remains open until its full reported rendering behavior is confirmed.

#96's original damaged-page cursor/button recovery is already released. Its remaining Finder arrow routing must be checked against the actual loaded signed extension. Synthetic panel events do not establish Finder acceptance; no global keyboard monitor or private host takeover is introduced.
