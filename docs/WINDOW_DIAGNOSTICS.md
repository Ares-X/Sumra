# Window diagnostics

Available from Sumra 0.2.45. This is an optional local trace for window, tab and
fullscreen problems, including the unresolved black Space report in #137/#148.
Recording is off by default and does not upload anything.

## Send a useful report

1. Choose **Help → Window Diagnostics → Record Window Diagnostics**, or enable
   the same switch in **Settings → Diagnostics**.
2. If the problem depends on a fresh app session, quit and reopen Sumra. The
   switch stays enabled and startup/restoration events are recorded too.
3. Repeat the original steps. For #148, preserve whether Duplicate was used
   before New Tab in this app session. Note the time and, if possible, take a
   recording showing the black Space and Mission Control.
4. Choose **Mark Current Window State** when the problem occurs, then **Export
   Window Diagnostics…**. Export still works after recording is switched off.
5. Attach the ZIP and your steps/recording to the issue. Turn recording off when
   finished. Nothing is sent automatically.

Recordings remain in **Show Diagnostics Folder** until you remove them yourself.
They are not rotated, truncated or deleted after export. Each recording is a
separate JSONL file; a restart creates a new one and retains the previous file.
The exported ZIP contains the recordings and a `report.json` describing the
observability and any known logging failure.

## What the trace can establish

The trace correlates requests, payloads and native windows using generated IDs,
monotonic timestamps and a per-recording sequence. It records document loading
and publication, Home classification, tab policy and group removal, placement,
each ready-guard exit, selection and application-owned ordering calls. Native
notifications capture activation, full-screen transitions, visibility, geometry,
sheets and active-Space changes. Chrome changes and the app's own WindowServer
metadata help distinguish a correctly grouped reader from a window that is no
longer visible on the active Space.

No file names, paths, titles, document text, bookmarks, typed keys, screenshots or
other apps' window metadata are written. Errors contain domain/code and a safe
underlying domain/code, not their raw message. AppKit exceptions contain their
kind and return addresses, not a potentially private reason. Include a separate
macOS crash report for a crash; the trace does not replace it.

Public APIs do not expose Space IDs/topology or every internal SwiftUI/AppKit
window-ordering operation. Group values are explicitly cached from application
getters and may be stale. Recording does not proactively read lazy `tabGroup`
or `tabbingIdentifier` properties, use private Space APIs, swizzle AppKit, poll,
or change focus to repair a failure. It still adds observational overhead.
`isOnActiveSpace` and correct group membership do not by themselves prove the
pixels shown to the user; the original reproduction and visual evidence matter.

## Persistence and failures

File encoding and appends run on one background queue. Export captures an
ordered prefix without interrupting recording, preserves raw unfinished tails,
and atomically delivers a completed ZIP. A crash or power loss can lose an
unwritten tail; reports explicitly describe this limit. Normal Quit flushes the
trace and writes an end event.

Recording, encoding and export failures are visible in Diagnostics and the Help
submenu. Previously written files remain available; an incomplete capture must
not be treated as proof that an event never happened. Export failures keep the
source recordings, and a failed export does not replace an existing report.
