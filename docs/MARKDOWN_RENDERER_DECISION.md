# Approved Markdown rendering strategy

The user approved reuse of the existing MuPDF path for large Markdown on
2026-10-07, retaining explicit WebKit compatibility mode and ordinary HTML/CHM
browser behavior. This adds no dependency or separate rendering engine.

`ReadingDocument → Pages → NativeFile` owns paged Markdown. Automatic chooses
this path for files at least 8 MiB, dense sources with at least 100,000 nonempty
runs separated by blank lines, or a source version that reached the browser layout
limit. These are renderer-selection heuristics, not input rejection limits.
The per-file menu retains Paged Markdown and Compatibility Mode; each mode saves
its own position. Native zoom changes font size at raster scale 1, with source-flow
anchors preserving passages and selections across font-only reflow. Source or
stylesheet changes invalidate those anchors.

The native route has different CSS support. Compatibility mode preserves the
existing WebKit reading contract. Ordinary HTML/CHM remain on WebKit for reading.
For printing and export, the approved 855 route captures current form values,
loaded frames and print-media content, then uses MuPDF pagination and the AppKit
print panel. Actual GUI Export PDF and Print → Save as PDF passed, including
Unicode extraction. MuPDF's HTML/CSS subset can reflow browser layout; exact browser
layout fidelity is not claimed. No WebKit source fork or new runtime is required.
The completed large-Markdown runtime measurements and scoped print/export evidence
are summarized in the [current work list](RELEASE_CHECKLIST.md).

Native conversion releases its completed AST/parser and adopts the generated
HTML allocation without retaining another whole-source copy. Contents headings
load on demand. Compact 26-font packaging, source-flow handles and platform-sized
flow chunks are integrated. Rejected pool-zone, segmentation, marker and layout
experiments remain outside product source; do not repeat them without a new
concrete reason.

See the [source owner](../Sources/Sumra/Document.swift) and
[behavior tests](../Tests/SumraAppTests/MarkupReaderTests.swift).
The 855 print/export investigation is an internal record retained locally.
