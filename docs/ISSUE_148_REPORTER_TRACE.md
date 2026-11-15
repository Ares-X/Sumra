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

## Targeted change and validation

Explicit tab requests now prepare native policy and identity while mounting, and
perform their one manual insertion at the existing scene-ready main-queue boundary.
This separates the application insertion from SwiftUI's synchronous first ordering.
The callback belongs to its original window and close guard. Closing the parent or
child, detaching/rebinding the host, or moving the child to another group prevents
that old request from attaching or taking selection. Native restoration and cold
batch paths retain their existing ownership.

The new opener-order and interrupted-placement tests fail on 0.2.45. A follow-up
host reattachment case also rejected the initial deferred callback until its window
and delegate identities were fixed. These mounted native tests protect the creation
boundary; they do not reproduce or prove WindowServer/Space behavior.

Final affected checks passed 68 cases with one expected platform skip, using isolated
preferences and clipboard; source and installed native engines remained unchanged.
Signed existing-VM acceptance is pending. The reporter's
macOS 15 behavior remains unverified after this change. Issues 137, 148 and 96 remain
open; this change must not be described as a confirmed black-Space resolution.
Local original attachments, frame observations, focused failure receipts and
independent analyses are retained under `build/issue148-reporter45/`.
