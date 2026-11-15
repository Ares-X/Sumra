# 0.2.45 window diagnostics acceptance

The optional diagnostic facility passed signed-package acceptance in the existing
macOS 26.6.2 (25G83) VM. This is not confirmation that #137/#148 black Space or
#96 Quick Look keyboard routing is fixed; all three issues remain open.

- Source: `120a92fca58e31ae0725160305cf99454e95b9f7`; candidate workflow
  [43682567585](https://github.com/Ares-X/Sumra/actions/runs/43682567585).
- Accepted manifest: `b3a9adc62138cd70e225caf4943a2f1021489853f8f62898101e4df21fb60d6a`.
- Main executable: `71640d0181b63bc7727c569034de0e98d0554ef87847bb5b1e64259ad349eade`.
- All six asset digests, frozen source/app inventories, original signing
  certificate, three arm64/macOS 13 bundles, deep strict signatures, and Sparkle
  Ed25519 passed. The loaded VM candidate matched the accepted executable.
- Focused isolated tests: 71 distinct cases passed, one expected platform skip.
  Preferences and clipboard were isolated; source and installed engine hashes
  stayed unchanged. The current host requires an SDK 15.5 compatibility stamp
  on its temporary XCTest launcher; production candidate bytes were unmodified.

## Actual GUI observations

Settings initially showed recording off and zero files; no diagnostic directory
existed. The switch was enabled through Settings. A PDF at 180/180 entered
fullscreen and used **Duplicate in New Tab before New Tab** in this process,
then New Tab opened an EPUB through the file panel. The repeated-page PDF has
identical PAGE 1 artwork; its live toolbar confirmed 180/180. Pointer-only
movement showed and hid the fullscreen controls. Mission Control showed one
desktop and one populated Sumra Space, with no extra empty Space in this replay.

A Help-menu problem marker and Save-panel export produced a ZIP containing 429
continuous events, including duplicate/payload/placement/ready/selection,
load/publication and later Space events. Normal Quit flushed its end event.
Relaunch retained the opt-in and created a second capture with startup and
restoration notifications. Recording was disabled through Help; a subsequent
fullscreen transition left both log files byte-identical.

A third launch with recording off created no new capture. The Chinese Settings
page exported both earlier captures: 525 events from two processes, ending in
normal termination and capture disabled respectively. Sequences were continuous,
known recording failure was false, and fixture names/paths were absent. English
and Simplified Chinese settings were visually checked, including all seven tabs;
Show Diagnostics Folder opened the two recordings in Finder.

The reporter's macOS 15.7.5, an actual black Space failure, crash-tail durability,
and public Gatekeeper trust remain unexercised. Only the existing VM was used.

Public release and real 0.2.44-to-0.2.45 Sparkle acceptance are pending.
Local receipts and actual exported ZIPs: `build/issue148-diagnostics45/`.
