# Issue 138: ordered rapid navigation

Baseline: `531c7eb`, installed 0.2.36 (38), arm64 macOS 27.0.1. The scope is the rapid-navigation command ordering in [#138](https://github.com/Ares-X/Sumra/issues/138), also reported in the navigation portion of [#137](https://github.com/Ares-X/Sumra/issues/137). Other issues in that external report remain open.

The reporter's original 14.133-second recording was inspected, including a 10 fps progress-strip contact sheet. It shows forward progress reversing through values such as 18 → 17 and 20 → 18. On the baseline, an actual macOS `NSHostingView(RasterReader)` published zero-based pages `[1, 2, 3, 4, 1, 2, 3, 4]` during four forward inputs. Backward, alternating, menu and RTL facing-page bursts reproduced equivalent replays. The installed GUI also opened the eight-image CBZ and reached the fifth image after four right arrows. Its end-state screenshot does not establish which intermediate values the compositor painted.

Relative turns now resolve inside their input command. A scroll's derived turn retains the same command revision and completes when the destination viewport consumes its request. The next input therefore uses the new geometry. Fixed-page row calculation is shared with the close-time snapshot of explicit pending page destinations. Unknown scroll/decoder destinations are not guessed during close. Navigation history records each jump's origin when the command begins. A failed current render releases its pending viewport request, including requests received after that failure, while keeping the error visible.

Local acceptance comprises 63 distinct passing tests across two final focused runs, using private preferences/pasteboards and the unchanged installed native engine. Coverage includes:

- Complete page publication sequences for forward, backward, alternating, menu, mixed first/last and RTL facing-page navigation, plus returning through history.
- A small page followed by a larger page at actual size: the next queued right arrow pans inside the destination instead of skipping it.
- Different-sized large pages with page-local position preservation enabled, including queued forward and backward turns.
- A real corrupt middle image in CBZ: error reporting, a later request for the same failed page, and navigation to a valid next page.
- Closing before explicit page commands are applied, both before and after the reader claims the command, retains the requested page without stale chapter coordinates.
- Existing Page Up bottom anchoring, wheel phase/momentum routing, continuous scrolling, focus, chapter/facing-page transitions, GIF frame navigation, FB2 rapid navigation followed by layout changes, and PDF close validation.

The localization audit and `git diff --check` pass. Native engines and dependencies are unchanged. The first added corrupt-image fixture failed during its eager bounds scan; the corrected fixture leaves bounds/rendering to the real reader and exercises the intended visible failure. Two old model-only history tests now acknowledge simulated command consumption, while their existing history limit, branch and anchor assertions remain.

Signed candidate, public publication and installed update acceptance are pending. Physical macOS 15.7.5, the reporter's exact comic, and frame-by-frame compositor timing are not established by the local tests.
