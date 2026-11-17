# Vira Reader 0.2.48 acceptance

The signed build 51 from source `47fdb598293cdae7838cbc53fe4065572140191d` passed the following pre-publication checks in the existing macOS 26.6.2 (25G83) VM. This does not claim macOS 15.7.5, physical trackpad input or quarantined Gatekeeper first-launch acceptance.

- The maintainer supplied the exact light PNG used by the build; it appears on Home and in the Dock. All six assets, 140 application files, five symlinks, the corresponding-source inventory, three new bundle IDs, existing certificate and Ed25519 signature passed verification. The installed application's 140 hashes match the candidate.
- Fresh installation migrated controlled language, font size, the automatic-update choice and history bytes. Sumra's preference domain remained unchanged. Native saved-window state, default associations and new Keychain authorization are outside this migration acceptance.
- #158: windowed Normal Auto Hide retained an opaque filename-proxy hover after Duplicate and after completing New Tab's native Open panel. Moving into the document hid the native separator. Fullscreen tabs revealed and hid correctly in Auto Hide; Always Show retained a stable caption band without the reported extra dark padding. The reporter's original macOS 15.7.5 confirmation remains outstanding.
- #160: actual system speech started in srcdoc. Physical clicks on the parent and sibling buttons, resolved from fresh exact-window accessibility bounds, left word highlighting in the source frame. Prior heading paint was cleared and Stop removed all paint. The same source also passed the existing 13-case real-WK/native-message/snapshot suite.
- #161: a native 1,000-page PDF kept the annotation row visible, changed its contents, restored the original on Undo, reapplied the change on Redo and saved. Existing unchanged native tests cover retained rows, replacement isolation and one-page reads in 1,000/5,000/10,000-page documents. No signed-VM CPU/RSS or timing claim is made.
- #96: Finder loaded `dev.aresx.vira-reader.preview` from this exact application. Actual mouse navigation passed 1/3 → 2/3 → damaged third page preserves 2/3 with an error → Previous returns 1/3 → Next returns 2/3. Finder direction-key routing remains separately unresolved; this issue stays open.

Local packaging checks passed (58 cases plus registration/language probes). Reader, extension and test sources are unchanged from the prior accepted identity candidate, so valid existing chrome/annotation/speech/migration regressions were reused rather than duplicated. Recent closed reporter feedback was reviewed: #137's reporter explicitly confirmed fullscreen tab/black Space recovery and closed the issue; subsequent appearance feedback is tracked in #158.

Main SHA-256: `141e4ee07f0b79b3566ed52f0686848a815321fcb9fb6cc4ced515e1db5e044e`.
Archive SHA-256: `d0c197af5dbd155473df66e182b38000838021b9ced273f34ff02ca70f6d3e33`.
Accepted SHA256SUMS: `0f1e579cc0b5d158f3e7ac53f310c2de09484dcb65aa406bcaf69cf6a77943e1`.

Detailed private receipts and original native screenshots are retained under `build/issues-release48/`. Earlier failed automation attempts and early transition captures remain recorded and are not counted as successful workflows. Publication must use these already accepted bytes through the existing release workflow; public-asset and real-update checks are recorded separately after publication. The first transition from Sumra requires manual installation, while subsequent Vira updates use the independent Vira feed.
