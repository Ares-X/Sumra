# Issue 118 verification

Report: [v0.2.31 issues](https://github.com/Ares-X/Sumra/issues/118).
Baseline app: 0.2.31 (33), source `a8a07ec640d9307f70dc30fd89183bef7df1154f`.
Desktop environment: arm64 Mac, macOS 27.0.1. This does not establish runtime
acceptance on the macOS 13 deployment target or the reporter's display setup.
The corrected signed 0.2.32 candidate is accepted within the boundaries below and
published. The installed 0.2.31 → 0.2.32 Sparkle upgrade passed.

The earlier acceptance missed particular action sequences and made broader claims
than its observations supported. The regressions below exercise the actual owner
of each demonstrated failure. Simulated AppKit state, direct button actions and
offscreen rendering are recorded separately from real desktop interactions.

## Behavior and evidence

| Report | Change and regression evidence | Real desktop evidence / remaining work |
| --- | --- | --- |
| W1/W2: traffic-light hover after zoom | Re-sample the pointer when AppKit replaces the tracking area. A raster regression fails on the old implementation and passes on the candidate. | Baseline glyphs remained after a green-button transition and an outside click. Candidate welcome and floating physical green-button fullscreen transitions followed by outside clicks clear the glyphs. Option-zoom and pointer-only hover sweeps are unverified. |
| T1: floating tab lower half/fullscreen input | No speculative change. The isolated scroll-host hypothesis did not reproduce the report. | Baseline lower-half clicks switched TXT and original EPUB tabs. Candidate lower-half clicks also switched both original-EPUB fullscreen tabs. Reported failure remains unexplained. |
| T2: floating red button closes only the selected tab | Multi-tab red control uses the existing ordered close/approval chain. Real native button actions reproduce the old selected-tab-only behavior. Candidate covers all three selection positions, cancellation in the middle, and restoration of the single-window native action. | Candidate physical red click with the right tab selected left no app windows. Tab x retains individual-close behavior. |
| T3: native tab gap until pointer leaves | No separate root cause established. | Candidate physical middle-tab x click immediately redistributed the two remaining native tabs while the pointer remained in the bar. Exact baseline comparison is unavailable. |
| T4: new/duplicate fullscreen tabs and black Spaces | Closed SwiftUI hosts no longer reconfigure themselves as Home or remove themselves from the native group. Mounted-host regression reproduces that separate lifecycle defect. | Candidate floating duplicate, normal duplicate and normal new-file fullscreen tabs displayed in their groups; exit retained native buttons. Floating-to-normal, exit fullscreen, first physical Next also passed. Black-Space count remains unverified. |
| C1: fullscreen toolbar too low | Menu clearance subtracts the strip already outside the fullscreen window. A real screen/window geometry fixture fails on the old duplicate 33pt reserve. Full-height-menu and Find-clearance cases remain covered. | Baseline fullscreen bar starts at y98px; candidate stable fullscreen starts at y32px, matching the windowed inset. |
| C2: native titlebar cannot activate from another app | Activate the app as well as making the window key; an already-key window is not reordered. | After raising and physically clicking Calculator, the first physical click in Sumra's normal Auto Hide titlebar revealed the toolbar and focused the reader. |
| C3: Always Hide buttons and tab shadow | The reading overlay yields the native button region to AppKit; normal Always Hide leaves toolbar visibility with its AppKit owner. Regression assertions cover button ancestors and canonical root hit targets. Always Hide collapses the public native accessory controller and restores only the state it took over; tests cover native single-tab Hide Tab Bar, selected-tab ownership, detach and fullscreen restoration. Windowed document proxies remain hidden while the reader toolbar is hidden. | Three native tabs + Always Hide still revealed the document proxy icon in candidate 3. Candidate 4 passed the same three-tab physical header-click replay: no document proxy, toolbar or tab strip remained. Always Hide/Show preserved actual fullscreen; exit restored tabs and the first physical Next worked. The first signed candidate failed actual pointer-only hover and was rejected. After the focused follow-up, the same SDK-policy runtime probe reveals all three controls; the user confirmed physical pointer-only hover, and native green/fullscreen/exit/red-close actions passed. The corrected signed candidate passes the same native-control/header replay below. |
| C4: normal comic progress Auto Hide lacks footer room | Normal progress retains its 26pt row independently of native toolbar Auto/Hidden. Generated comic host test is red on old code and green on the candidate. | Real Numbered comic GUI passed toolbar Auto/Hidden + progress Auto: the revealed slider stays below the page without changing its position. |
| L1: one-frame EPUB resize stretch | Pending outgoing bitmaps retain their aspect while replacement page geometry is already published. A real circle raster turns into an ellipse on the old implementation and retains its aspect on the candidate. | An original-book wide/short transition sample retained aspect before new geometry settled. Continuous resize capture remains unverified; sampled screenshots cannot exclude a transient frame. |
| L2: initial/ fullscreen scrollbar clearance | Scroll-owner publication and actual viewport frame changes update the clearance owner; its observer follows the current viewport and is removed/restored on detach. Late mount, same-owner attachment, final frame and Find-close cases pass. | Continuous comic tracks follow the viewport in normal Always Hide/Show and actual fullscreen normal/floating modes. A fresh duplicate comic reader in Continuous/Fit Width with Always Show Scrollbars also placed its track below the revealed Auto Hide toolbar without a user resize. This is a fresh mount, not continuous first-frame or cold-file timing evidence. |
| L3: EPUB facing cover at extreme sizes/Actual | The cover uses its facing paper in both Fit Page and Actual Size. Authored peer content is preserved. Four original-book hosted regressions reproduce the old placement failure; all eight originals retain contained native art at three viewport shapes. | With cover off, fifth-round A passes narrow/tall Fit Page, wide/short Fit Page and Actual, and fullscreen Actual. Second-round C passes narrow/tall Fit Page and Actual, wide/short Actual and fullscreen Actual. I passes tall Actual with aligned facing images. F, G, H, fourth-round C and third-round D also passed Fit Page and Actual Size. F and fourth-round C passed wide/short Actual; F retained its wide image/caption, G its small native logo, H its text, and D its separately paginated second image/dedication. Not every mode and shape was replayed for every book. |
| P1: palette/thumbnail mouse feedback | Native mouse-down selects immediately; mouse-up with click count two activates. Candidate input-owner raster tests check visible changed selection and double-click behavior. | Physical single-click selection and double-click execution passed. One palette click plus capture completed in 0.5704s, an observation upper bound rather than frame timing. Thumbnail click, Down and Return also passed; precise thumbnail latency is unmeasured. |
| P2: palette arrows after clicking a row | Clicking hands focus to a stable list responder outside recycled rows. Candidate test covers arrows, Return and scrolling the original row away. | Baseline physical row click then Down left search focused and Open selected. Candidate exact replay moved selection to the next row and removed the search focus ring. |

## Local checks

The initial isolated full run recorded 1,575 passes, five failures and 40 skips.
The five failures were investigated individually: titlebar activation unnecessarily
reordered an already-key test window; the fullscreen fixture did not span the
screen's menu region; the normal-footer test still expected overlay geometry;
the margin snapshot omitted preference revisions; and the input-only Find fixture
did not consume the initial search command. Product and fixture corrections each
have focused passing reruns. The last batch passed 12/12; Margin passed separately.
A Quick Look supplement also passed one formerly skipped case using the installed
engine. This is combined evidence, not a claim that a second full run was green.

Swift parsing, localization audit, packaging tests and reader JavaScript syntax
checks passed. The final C3 follow-up passed its new real native-host case, the
corrected menu-reveal fixture and eight adjacent input/restore cases. Its actual
desktop replay passed in local debug candidate 4.

That proxy leak illustrates a missing precondition in isolated acceptance: the
native proxy was already hidden in the offscreen host, so its hidden-state
assertions did not reproduce the GUI defect. The public accessory controller has
an independent failing-before regression; the proxy requires the actual desktop
header-click replay. A native Hide Tab Bar action is checked in a single-tab
group where AppKit permits it, and temporary reveal checks retain their native
control ownership when layout changes.

## Original files and traceability

The reporter's eight-file archive is unchanged:
`misalignedepubsfifthround.zip`, SHA-256
`b14e2c572074641a229d5522953fbc867ffa46370cee3854e660a969346d93ab`.
Local evidence is retained under `build/issue118` in the primary checkout,
including individual fixture hashes, baseline app metadata, source/build
receipts, isolated test logs and `gui-observations.md`.

Local GUI packages are ad-hoc debug builds using the installed release's unchanged
engine/resources. They are not the signed release candidate. Publication must
follow [the release workflow](RELEASE_ACTIONS.md), including exact signed-byte
original-book and Finder-extension acceptance, then the public update path.

## Signed candidate status

PR [#119](https://github.com/Ares-X/Sumra/pull/119) merged as
`5814f0f59fceacb2fb9aae413a1cb08d3730049f`. The
[candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/41868875434)
succeeded. The first, later-rejected 0.2.32 (34) draft passed all asset checksums, the original signing
certificate, deep strict code-signature verification, 140 app-file hashes against
provenance, arm64/macOS 13 deployment metadata, frozen source/build correspondence,
and public-key-only Sparkle Ed25519 verification. The rejected candidate manifest
digest is `dfa7d0e3f06f625d0527c2ec936e4adb38ba1c04aeeab486fb3280208cc20ca3`;
it must not be used to publish this rejected candidate.

That first draft's signed GUI checks confirmed A's cover-off Fit Page and wide/short Actual
alignment, three-tab native accessory/proxy hiding, I's fullscreen Hide/Show
restoration, and the first physical Next after fullscreen exit. The user confirmed
that C3 pointer-only button reveal failed even after clicking the page to activate
Sumra. That first draft was rejected for publication. Finder extension acceptance and the installed update
path were deferred to the corrected candidate. Local observations are in
`build/issue118/release/signed-gui-observations.md`.

A temporary cold ReaderWindow probe drove the actual application event monitor
and SwiftUI update path. It passed locally but did not reproduce the signed
failure, so it was removed after retaining the diagnostic evidence. Both real local WindowGroup Debug and Release/Osize builds also reveal
the native buttons. Their main binary SDK stamp is 13.0; the signed candidate
uses SDK 15.5 and Swift 6.1.2. Changing only the local Release main binary's SDK
stamp to 15.5 reproduces the failure on the same Mac and original file. This is
a controlled runtime-policy probe, not a true SDK 15.5 compilation or release
acceptance. The separate CI diagnostic job was cancelled before it acquired a runner; GitHub
reported macOS arm64 capacity constraints. It produced no build or release.

The failing probe receives the mouse event and completes the hover update.
All three captured/current native controls match, with `isHidden == false` and
alpha 1, but their titlebar view has alpha 0 and its parent container is hidden;
their visible rectangles are empty. Checking the button alone and using a local
app with a different main-executable SDK policy therefore missed the defect.
The follow-up leaves normal Always Hide's native toolbar visibility with AppKit
and stops requesting SwiftUI to hide the whole native window toolbar. The
reading overlay also yields the native button region instead of returning a view
outside its subtree. Its new input assertion failed on all three controls before
the change and passed after it, while the root still hit the canonical buttons.
The existing C3 regression now also checks every NSView ancestor's alpha and
visible rectangle. Temporary logging and the cold-mount probe are removed.

The corrected runtime probe repeats the same original-A cold-open and top-edge
sequence. All three native AX controls now appear, and the previously hidden
ancestors have alpha 1, are not hidden and have nonempty visible rectangles.
The toolbar, native tab strip and proxy remain absent. The user independently
confirmed that physical pointer-only hover now reveals all three buttons. CUA
native-button activation enters fullscreen; Always Show/Hide retain fullscreen;
exit restores the original window and controls; native close returns to Home.
Follow-up [PR #120](https://github.com/Ares-X/Sumra/pull/120) merged as
`57889dc4cae0363856549a86ccd18d8004ad473a`. After diagnostic removal, the final
C3 case passed again against unchanged Sources/Tests hashes; its isolated host,
preferences and pasteboards were cleaned. The
[corrected candidate workflow](https://github.com/Ares-X/Sumra/actions/runs/41894989640)
built that exact merged revision successfully. The corrected signed package passes
all asset checksums, the original certificate, deep strict signature, all 140
app-file hashes, frozen source/build correspondence and public-key-only Sparkle
verification. It is 0.2.32 (34), arm64, with macOS 13 minimum and SDK 15.5,
compiled by Swift 6.1.2. Its manifest digest is
`fe9b3b9514ece0d1cf833c497bb7d261dbc1ec4f50ddcbb2e215a784f3fa3123`.
After the user unlocked the Mac, the exact signed app passed original-A cold
Always Hide/page-to-header reveal, native green-button fullscreen, fullscreen
Always Show/Hide, native exit and first Next. A three-tab native group hides its
accessory/proxy while retaining the native controls; native red closes the
selected tab without a crash. A and I retain their cover-off Actual Size art and
alignment. The comic keeps the same page position between Auto and shown
progress, with the shown slider below its art. CUA footer clicks did not reliably
reveal Auto progress, so the earlier local Auto-hover evidence remains separate.
The sharing indicator still obscures native button paint in CUA captures; the
user's pointer-only paint confirmation belongs to the corrected local probe.

Actual Finder Quick Look rendered original I and advanced from chapter 1 to 2,
and rendered comic PAGE1 then PAGE2. Both fresh portrait thumbnails displayed.
The preview and thumbnail process paths point to the exact signed candidate.
Finder initially picked the installed 0.2.31 preview; that observation was not
counted. Only its registration was temporarily removed, then restored after
acceptance. The task-created Finder window was closed; candidate extension
registrations were removed. No global cache purge or process kill was used.

[Publication](https://github.com/Ares-X/Sumra/actions/runs/41957911778) succeeded
using the accepted manifest above. [v0.2.32](https://github.com/Ares-X/Sumra/releases/tag/v0.2.32)
is public; an anonymous download matches accepted ZIP SHA-256
`94b793d226ec99725c6ae2486163e35addbe75e33f4f336cc151247130c8200b`
(17,096,729 bytes). The public feed equals the accepted appcast, and public-key
Sparkle verification passes. The workflow publishes those existing bytes without
rebuilding or recompressing them. Installed 0.2.31 detected 0.2.32 and completed
Sparkle download → Install and Relaunch → Home. About shows 0.2.32 (34);
the new installed process replaces the old PID, all 140 installed app-file hashes
match the accepted candidate, and deep strict signature verification passes.

Six task-modified preference keys were restored individually; all other values,
including Sparkle's new last-check time, are unchanged. The private backup was
removed after verification. Task-created Finder windows, application processes,
local test hosts and temporary extension registrations are closed or released.
Local build scratch, disposable app bundles and duplicate source/app archives are
retired; the rejected private draft and failed diagnostic branch are removed.
Compact logs, fixtures, receipts and one exact rejected signed ZIP remain for
reproducing the SDK-policy failure until reporter confirmation.

## Acceptance boundaries

All agent-operated desktop interaction uses Codex CUA. Native AX actions and physical coordinate
clicks are distinguished. The current CUA native API has no documented continuous
frame recording or desktop/Spaces overview; multi-display/Space transitions also
produced inconsistent screenshot/click targeting. Failed targeting is not recorded
as a product defect. Missing evidence remains pending.

The human report stays open for reporter confirmation. Do not use an automatic
closing keyword or describe the whole report as fixed while rows remain pending.
