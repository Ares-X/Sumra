# Issue 118 verification

Report: [v0.2.31 issues](https://github.com/Ares-X/Sumra/issues/118).
Baseline app: 0.2.31 (33), source `a8a07ec640d9307f70dc30fd89183bef7df1154f`.
Desktop environment: arm64 Mac, macOS 27.0.1. This does not establish runtime
acceptance on the macOS 13 deployment target or the reporter's display setup.
This is an in-progress record; no signed candidate or public release is accepted yet.

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
| C3: Always Hide buttons and tab shadow | The overlay returns the actual native traffic-light hit target. Always Hide collapses the public native accessory controller and restores only the state it took over; tests cover native single-tab Hide Tab Bar, selected-tab ownership, detach and fullscreen restoration. Windowed document proxies remain hidden while the reader toolbar is hidden. | Three native tabs + Always Hide still revealed the document proxy icon in candidate 3. Candidate 4 passed the same three-tab physical header-click replay: no document proxy, toolbar or tab strip remained. Always Hide/Show preserved actual fullscreen; exit restored tabs and the first physical Next worked. The sharing indicator still limits direct traffic-light painting/input observations. |
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

## Acceptance boundaries

All desktop interaction uses Codex CUA. Native AX actions and physical coordinate
clicks are distinguished. The current CUA native API has no documented continuous
frame recording or desktop/Spaces overview; multi-display/Space transitions also
produced inconsistent screenshot/click targeting. Failed targeting is not recorded
as a product defect. Missing evidence remains pending.

The human report stays open for reporter confirmation. Do not use an automatic
closing keyword or describe the whole report as fixed while rows remain pending.
