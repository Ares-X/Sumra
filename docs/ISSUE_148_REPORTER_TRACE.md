# Black Space: reporter diagnostics from 0.2.45

[Reporter comment 6891499640](https://github.com/Ares-X/Sumra/issues/137#issuecomment-6891499640)
provides a short recording and a Window Diagnostics ZIP with a problem marker.
The reporter confirms macOS 15.7.5 and says Duplicate in New Tab remains
intermittent. The normal/floating tab redesign is reported as working.

The original ZIP SHA-256 is
`f7a836d423b55d8a4a84a698a43c804bd0c2d277552e9bfcf318bf1e8cd3d6ac`.
Both captures identify 0.2.45(47), arm64, macOS 15.7.5 (24G624).
One has five records ending in normal termination; the other has 293 continuous,
complete JSONL records through export. `loggingIncomplete` is false and the last
successful/enqueued sequences both equal 293. The ZIP contains **one Duplicate
operation**, not a successful/failed pair. The separate macOS 26 VM trace is a
cross-system comparison, not another attempt on the reporter's system.

## Recorded failing operation

Times below are relative to `command.duplicate`, request `005A3478-4D50-4022-8578-4FEA0F5EAC13`.
The original reader is w5 / native window 5679; the new reader is w11 / 5723.
The recorded reader uses normal controls, `toolbarMode=shown`, and internal page
142 of a 144-page CBR visible in the video.

| Sequence | Time | Observation |
| --- | ---: | --- |
| 105–108 | 0–0.4 ms | Duplicate has a loaded document at internal page 142; scene opening begins. |
| 113 | 92 ms | SwiftUI's new window becomes key before the app's Host attaches. |
| 117–124 | 178–179 ms | Host attaches, finds parent 5679, and calls native add synchronously inside the scene opener. |
| 126 / 132 | 223 / 247 ms | New window receives its first fullscreen entry pair. |
| 134 | 250 ms | Native add returns. |
| 140 / 143 | 322 / 328 ms | The same new window receives a second fullscreen entry pair. |
| 145 | 375 ms | SwiftUI's scene opener returns. |
| 148–149 | 420–433 ms | Natural application getters observe g1 containing both readers, selected w11. |
| 155–160 | 525–526 ms | Ready selects w11 and makeKeyAndOrderFront returns; w11 is key/main, visible, fullscreen and on the active Space. |
| 171–172 | 668–669 ms | w11 loses active-Space membership and visible occlusion. Both readers are off the active Space; this process's on-screen WindowServer list is empty. |
| 182–185 | 799–815 ms | The document publishes and finishes loading while off the active Space. |
| 193 | 4.582 s | Another Space change brings the readers back; WindowServer again lists window 5723 and its toolbar. |
| 225 / 264 | 6.962 / later | Problem marker and export occur after return to the reader. |

The recording shows entry into fullscreen, Duplicate in New Tab, and then a black
screen at about four seconds into the clip. It supports the observed disappearance;
it does not establish whether a new Space was created or an existing Space became
empty. Cached group values are not live Space ownership. This instance did not
hit a ready guard exit or Home-removal path. The evidence locates the failure
**after successful grouping and selection**, not in document loading.

In the accepted 0.2.45 macOS 26 VM comparison, manual add also nested inside the
scene opener, but the duplicated window received only one fullscreen entry pair
and no later active-Space loss was observed. That difference motivates removing
the nested insertion; it does not by itself identify every internal AppKit action.

## Rejected first candidate

The first attempted change deferred the explicit insertion to scene readiness.
Its mounted native ordering/interruption checks passed 68 cases with one platform
skip, using isolated preferences and clipboard. Those tests did not exercise
SwiftUI's first display or WindowServer/Spaces.

A fresh 0.2.45 VM control matched Always Show normal controls, a 144-page stored
RAR5 CBR, two-page layout and page 143, with Duplicate before New Tab. It showed
one fullscreen-entry pair, stayed visible, and Mission Control showed only a
Desktop and one populated Sumra Space. The filename/content differ from the
reporter's book, and macOS remains 26.6.2; this is still a non-reproduction.

The signed 0.2.46 candidate at `0dd59ff7063e5e11df278e91948d2289290fdd5c`
failed this real-VM acceptance. SwiftUI entered fullscreen before its opener
returned; the later native insertion caused another fullscreen entry and the
selected child temporarily left the active Space. Continuous native captures
showed a Space slide and an empty loading view before the reader returned.
The candidate was withheld from merge/publication and PR 156 returned to draft.
This falsifies deferral alone as the repair; passing native unit tests did not
make that presentation boundary safe.

## Creation-owner experiments

All experiments below used ignored source overlays, the existing macOS 26.6.2
VM, the same stored-RAR5 CBR and normal Always Show controls. They are not
additional attempts on macOS 15.7.5 and were not published.

- Calling the existing SwiftUI window controller's public `newWindowForTab`
  consumed the intended payload once, synchronously, but created an independent
  fullscreen reader. With application insertion disabled, readiness correctly
  exited with `parentMissing`. Direct `NSWindow` did not respond to that action.
- Temporarily using `[.primary, .fullScreenAuxiliary]` for the synchronous join
  produced one fullscreen-entry pair, as the 0.2.45 control already did. SwiftUI
  restored the primary mask during native entry. This did not establish a repair
  and was not adopted.
- A narrow AppKit-created child hosting the existing `ReaderWindow` joined the
  parent before its first order. The scene opener was not involved in that
  creation. Capture `A5F3ADBC-96BA-4F5E-991B-A6341921C33F` records one entry pair;
  the visible duplicate retained page 143, native toolbar and menu navigation to
  page 144. Mission Control showed Desktop and one populated Sumra Space.
  Its first automated Duplicate attempt was not dispatched (zero commands in
  the trace); those initial continuous frames are not acceptance evidence. The
  later confirmed command, trace and settled pixels establish the observations
  above, not an absence of every transient frame.

## AppKit owner and session restoration

The replacement creates explicit document tabs with AppKit, hosts the same
SwiftUI reader, and inserts the native window before its first display. Other
reader and auxiliary requests retain their scene owners. Native window numbers
exist before insertion, including unselected batch tabs; closing releases the
controller and its hosting graph. The original close-command implementation is
unchanged: a suspected routing failure was not reproduced when the trace
confirmed that the command had actually been dispatched.

Local VM playback of Duplicate before New Tab retained page 143, showed one
fullscreen-entry pair and one populated Sumra Space. A separate seven-tab
session exposed a restoration regression before release: a native CBR scene
temporarily received the active copy's UUID, then its late decoded value
replaced that UUID with the original CBR's identity. A second original-CBR scene
had already been created, leaving only six unique ready identities for seven
saved rows. The recovery barrier therefore kept the readers blank. Raw capture
`9206F221-6F22-411D-A4A9-50EB058D087B` preserves this failure.

The application session now saves a restorable native window's public identifier
alongside its canonical payload UUID. During the synchronous native-restoration
call, a matching default payload keeps that UUID, including repeated default
evaluation; a nested unmatched request does not inherit the outer identity.
Application-owned child controllers have no native decoding contract and use
`isRestorable=false`; the application session still saves their document rows.
Older session payloads remain readable. Native restoration's asynchronous
completion does not extend the synchronous identity scope; actual restart
playback must verify the framework uses it before publication.

The replacement source passed 101 focused tests with two host-platform skips,
using isolated preferences and clipboard. Those skips do not establish GUI
acceptance. In the existing macOS 26.6.2 VM, a fresh private application identity
replayed fullscreen Home → three-file batch → first CBR → page 143 → four
Duplicates → normal Quit → restart. Capture
`4020F494-07E5-4CC0-8D46-560BB19DE6ED` preserves the four confirmed commands;
`54699B11-24D2-466B-A9C8-9B39DEB4AB0E` records one native restoration request,
the original CBR identity matched inside the synchronous scope, six missing
scenes, and seven unique ready UUIDs matching all seven saved rows. The selected
copy loaded page 143 with its toolbar. Mission Control showed Desktop and one
populated Sumra Space. This is local-source acceptance; the replacement signed
candidate still requires its own acceptance before publication.

The reporter's macOS 15 behavior remains
unverified for the replacement. Issues 137, 148 and 96 remain open; none of these
observations is a confirmed resolution of the reporter's black-Space outcome.
Local original attachments, frame observations, focused failure receipts and
independent analyses are retained under `build/issue148-reporter45/`.
