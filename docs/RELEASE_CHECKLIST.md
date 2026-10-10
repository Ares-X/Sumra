# Release implementation and validation

## Objective and order

The user reset the working priorities on 2026-10-09: remove overimplementation
and defensive scaffolding, then complete the established GUI functionality with
small binaries, low memory use and fast input/rendering. Reuse existing platform
and MuPDF APIs; each decision belongs to one owner. No new runtime dependency is
approved. Finish coherent functionality batches before their relevant checks;
reuse unchanged evidence and retire unused temporary outputs.

The public product remains a macOS document reader with Sumatra-style reading
and PDF editing. AppKit owns controls and dialogs; `Pages`/`NativeFile` own one
editable MuPDF document. There is no Sumra CLI. The approved compact-font strategy
and automatic native large-Markdown route remain in effect. Browser compatibility
mode and ordinary HTML/CHM retain their HTML/CSS behavior. VoiceOver testing is
user-deferred.

## Current implementation

Candidate **855 completed browser print/export through a live WebKit snapshot
and MuPDF**, including the preview lifecycle repair. Its optimized build took
45.36 seconds; actual GUI Export PDF and Print → Save as PDF passed, and QA
returned to Home. That private app measured 31,353,085 logical bytes (about
29.90 MiB). Final 855 scope and evidence are retained internally.

Candidate **856 completed personal signing and a local archive**, with strict/deep
verification and actual GUI startup/export. Public distribution uses
[GitHub Releases](https://github.com/Ares-X/Sumra/releases/latest).
Candidate **857 completed the native interface refresh**: Home hides reading controls
and the document sidebar, the reader has a single compact toolbar, format covers
are integrated, and Home uses a 120–200-point flexible search field with content
capped at 760 points. Home requires at least 560 × 500 points of content; reading
retains 560 × 400. Actual GUI checks covered Home at minimum and maximized sizes,
light/dark appearance and contents search. Four original-demo screenshots are
included. The optimized build, five affected reader tests and 17 packaging tests
passed. Normal launching uses the macOS single-instance setting; the development
launcher uses ordinary opening. Three obsolete test apps were stopped and removed,
leaving one current preview. Unchanged document-engine evidence is reused.

The preceding854 Find/reflow fix remains integrated. The cleanup batch removes duplicate decisions and
packaging/process checks; its 15 affected behavior and 17 packaging cases pass.
The follow-up fixes a demonstrated Markdown defect: typography changes discarded
the active Find results and highlight. It retains the selected source occurrence,
refreshes its geometry and count, and preserves the reading viewport. Selection
and Find now share one source/style identity decision at the relayout owner.
Twenty affected cases pass across the initial run and the corrected mounted-canvas
observation; three affected cases also pass after consolidating that decision.
The native adapter and final optimized main build pass. At that854 measurement the QA app measured
31,301,508 logical bytes (about29.85 MiB).
Cleanup evidence (internal record retained locally),
Find/reflow evidence (internal record retained locally),
final loaded identity (internal record retained locally).

Candidate 853 has passing evidence for all 853 discovered behavior cases across
the batch and affected rechecks, plus 16 packaging checks, the four native engines
and the optimized main build. This was combined coverage, not one final all-suite
invocation. Its stripped main measures 4,172,632 bytes; raw MuPDF measures
18,434,312 bytes. Neither number is a final signed app/installer size.
[853 changes and evidence](DEFENSE_CLEANUP.md).

Recorded QA854 normally reopens the owned large book and paints its saved 100% ending
without a canvas click. That854 final main and four native engines were loaded
in the private app; the current855 load is recorded separately above. The final shared-decision build also has observed 100% Find
and 150% count/highlight restoration. Canonical review app 845 and the original
book are not refresh targets.

QA 852's missing 600% workflow is now recorded: the true ending paints, the
settled reading median is 404.408 MiB, and normal Home after restoring100% has
an 85.205 MiB one-shot footprint. This resumed process had been open for about
an hour; it is not cold/opening or comparative evidence. Earlier 852 medians of
484.751/506.845 MiB at100/150% retain their original scopes. These do not assert
854's complete performance acceptance. Resumed600% result (internal record retained locally).

## Completed large-Markdown workflow

The integrated Find build completed 100% → 150% → 600% → 100% and normal Home
on the unchanged 20,652,922-byte book. The query remained 1/1 after reflow, with
visible cross-line and cross-page highlights; the true 600% ending painted.
Settled reading medians were 380.548, 368.017 and 399.283 MiB, each below the
existing 512 MiB settled-reading target. Sampled transient maximum was 683.705 MiB;
the target is not a peak ceiling. A settled Home snapshot was 93.392 MiB.
Source-open to first AppKit canvas draw took 2.319 seconds; that is neither a cold
filesystem-cache benchmark nor compositor first-paint timing.

These measurements identify the main before the final equivalent source/style
predicate consolidation. The final build has its separate affected-test and
loaded-GUI evidence; the performance run was not repeated for that consolidation.
Runtime result and scope (internal record retained locally).
Four completed runtime captures were losslessly compressed, saving 1,958,985
logical bytes; no additional full app or source archive was created.
Retirement receipt (internal record retained locally).

## Completed browser printing and export

The user approved native print/export reflow on 2026-10-09. WebKit still owns
browser reading. The new live print snapshot preserves edited form values,
loaded frame documents (including legacy codepages), print media, generated
content/counters/quotes, text transforms, explicit page breaks and image resources.
MuPDF produces the PDF; the existing source-preserving AppKit path keeps its font
and Unicode objects when Export PDF or Print → Save as PDF completes.

The actual two-page saved output distinguishes ordinary `目入文门` from radicals
`⽬⼊⽂⻔` in both MuPDF and PDFKit extraction. It retains the edited main/frame
fields, the GBK-decoded child text and print-only content. Thirty-nine affected
cases and 21 lifecycle cases pass across the combined batch and targeted failure
repairs; native image materialization also passes. This is combined coverage,
not an all-suite run.
855 evidence (internal record retained locally).

Print layout follows MuPDF's HTML/CSS subset; positioning/grid/flex geometry may
reflow. Pictures use their loaded currentSrc; canvas/SVG are image content.
Unreadable printed content reports its actual failure instead of being dropped.
No new dependency, browser fork or WebKit runtime was added.

Release inputs have no demonstrated missing source or notice files in the bounded
audit. One public-identity staging app is prepared from the existing optimized
main and native binaries: version0.2.0/build2, arm64, about29.75 MiB after the855 refresh and removing
Sparkle's unused development headers/modules (151,033 bytes of files). The trimmed
framework loads both updater classes. Batch855 froze and verified the app/source
archives. The user then selected the shared personal `Ares-X Code Signing`
identity; batch 856 signed the same main/native implementation with that certificate
and Hardened Runtime. The community entitlement permits the bundled libraries to
load without an Apple Team ID, after a real dyld failure confirmed that need.
Strict/deep verification, actual GUI startup and a live two-page HTML/form/frame
PDF export pass. This is self-signed community distribution, not Developer ID or
Apple notarization. The canonical reader and private QA remain
separate. Input audit (internal record retained locally),
unsigned staging identity (internal record retained locally),
personal signing evidence (internal record retained locally).

GUI855 export and real Print → Save as PDF now pass after the preview/document
lifecycle repair. Chinese field values, reading position and normal Home are
observed in the refreshed app. Actual Chinese IME composition remains unverified:
the active input method passed through Latin input, and CUA cannot send a
modifier-only Shift toggle. This is an observation limit, not a confirmed Sumra
failure or an added release gate. macOS27.0.1 is the local runtime; macOS13
execution is not verified. VoiceOver remains user-deferred.

## Distribution

The integrated print/export and 857 UI workflows are complete. Unchanged PDF
editing, document engines and large-Markdown evidence are reused; only changed
behavior or a concrete failure calls for another check. Test counts are not a
release policy. macOS 13 is the deployment target and remains unverified at runtime.

The user selected one personal certificate for Linnet, Sumra and future projects.
The signed release uses its exact fingerprint and shared Keychain, with current
app resources/notices and matching corresponding source. Each release supplies
the app ZIP, source archive, provenance and SHA-256 sums. Receipt correspondence
does not claim independent build reproducibility. The installation instructions
describe the self-signed, nonnotarized app. Version 0.2.0 has no update feed;
0.2.1 enables Sparkle delivery as described in [online updates](ONLINE_UPDATES.md).

Source coverage lives in [implementation status](IMPLEMENTATION_STATUS.md),
[UI inventory](SUMATRA_UI_PARITY.md) and [engine inventory](SUMATRA_ENGINE_PARITY.md).
Historical investigations remain in their original `build/validation-*` receipts;
old candidate narratives are not additional unfinished requirements. The compact
before-edit snapshot is retained as an internal local record.
