# Reading settings acceptance — 2026-10-24

This follow-up records additional user workflows after 0.2.13. The development
candidate ran on macOS 27.0.1 on Apple Silicon. It used copies of the reporter's
EPUB samples and the multilingual reading fixture. Source checks, this private
application and subsequent signed-release acceptance are separate evidence.

## Reproduced and repaired

| Problem | Observed acceptance in the candidate app |
|---|---|
| A reused Aa panel retained the previous book's advanced drafts. | Leave unapplied CSS and margin 85 in World reading, then replace it with Cover C. The panel names Cover C, collapses advanced settings, shows its margin 32 and has empty CSS/margin drafts. The previous drafts do not apply to Cover C. |
| The basic margin slider disagreed with advanced values and CSS application could restore an older margin. | Apply margin 12, increment the slider to 13, then apply CSS. Both controls show 13. Four unequal margins show Custom, Return applies them, and invalid margin 250 leaves the applied values intact. |
| Saved CSS was present in reader state but the SwiftUI editor displayed an empty field when reopened. | A native plain-text editor displays the saved CSS after close/reopen. Its behavior test also exercises normal text insertion and external replacement with both another draft and an empty draft. |
| Applying an unchanged theme dialog changed System to Light. | Select System in Aa, open Choose Theme and apply unchanged: System remains selected. AppKit regression also preserves the current saved Solarized Dark ID without restoring the retired catalog to the choices. |

The first signed candidate was rejected before publication: a long fractional
margin wrapped its compact label, and an already-open panel remained English
after switching the app to Chinese. The follow-up uses a single-line, compact
margin display while retaining exact advanced values. It observes the selected
interface language and updates the panel title and native input labels without
recreating the editor or discarding its draft. These paths require acceptance in
the replacement signed candidate.

A second signed candidate exposed another actual mouse path: clicking the active
color well again deactivated it while leaving the shared picker visible. A
subsequent color selection then changed the picker without changing the document
color. The color-well owner now preserves its selected target after the native
mouse interaction and supports primary accessibility activation. The accessible
activation regression failed on the previous control and passes on the replacement;
repeated physical clicks still require acceptance in the final signed package.

A third signed candidate failed a real Finder cold launch: the process finished
launching but had no native or accessibility window. The queued-file dispatcher
depended on an action supplied by an existing reader scene. Startup tracing also
showed SwiftUI consuming external events for an empty scene, and an early explicit
book window being covered by the later initial Home.

The command scope now supplies the scene opener independently of reader windows.
External file and SyncTeX requests stay with the AppKit delegate, which drains
them after launch completes and can reuse the initial Home. An isolated native
launch then displayed only Cover C, with no activation or Dock click from the
test observer. The final signed package still requires the Finder cold-launch
and closed-window reopening checks before publication.

The five presets are Light, Light Warm, Dark, Dracula and Gruvbox. System is the
automatic appearance option; user-created themes and the current retired choice
are separate from that preset count. Aa exposes the visual chooser and document
color editor directly.

## Second reporter follow-up

The later comment exposed two gaps in the earlier acceptance: the heading itself
had not been clicked, and the Finder cold-open result came from 0.2.10 rather
than a fresh 0.2.13 run. That earlier result was NOT_REPRODUCED, not proof of a
repair. It must not qualify the next release. The third rejected signed 0.2.14
candidate reproduced the missing-window failure.

Clicking the actual alert heading reproduced the white color at alpha
0.8470588235294118. The native stack showed the text field editor updating the
font/color panel, which then notified the active document color well. The two
palette alerts now supply a native field editor with font-panel synchronization
disabled before it becomes first responder. The regression fails on the old
implementation and passes for headings, RGB fields and the theme-name field.

In the repaired development app, physical heading/RGB/name clicks preserve the
chosen brown and alpha 1 in both dialogs. Switching to Finder and returning by
clicking the heading also preserves it, and a later wheel drag changes only the
selected color. Six physical double-click switches among text/background/link
retain the selected target; Apply closes the panel and reopening retains the
values. These observations still require confirmation in the exact signed app.

Settings now uses the same editable font control as Aa. Installed Supplemental
font metadata contributes families absent from NSFontManager, including Iowan
Old Style. In the actual Settings window, typing Iowan autocompletes the family,
the list offers it, and closing/reopening retains the selected global default.
Global typography, per-format defaults, and a remembered book's settings remain
separate existing scopes; the global defaults are applied first.

All twenty reporter EPUBs pass native cover checks in four layouts each. Second
round A's two small title decorations also center in the actual reading window.
OPF cover-image metadata, guide resources and EPUB3 landmarks identify covers;
an image-only first linear spine item also qualifies without reliable metadata.
Text/caption pages retain their source layout and anchors. Percentage block
widths use the containing width, correcting the offset decorations.

Normalized image-only covers expose an intrinsic-aspect canvas. The development
reader displays a synthetic 2:1 landscape cover across the full viewport with
Cover on Its Own, then resumes ordinary facing pages. This changes neither the
global layout size nor ordinary chapter pagination. Native regressions cover
portrait/landscape, spread/continuous transitions and unchanged ordinary chapter
text, page bounds and anchors. The SVG subarea check now chooses its rectangle
from the actual cover marker rather than the previous fixed paper coordinates;
it retains the same tile-versus-full-image geometry assertions.

## Color-panel state transitions

The signed b402450 candidate exposed another real interaction failure: with the
RGB input focused and the app verified in front, Cmd+A left the insertion point
unchanged. Cut, Copy, Paste and Select All were disabled in the actual Edit menu
during the modal dialog. This was confirmed after the user paused other desktop
input; earlier input with a different app in front remains inconclusive.
The candidate was rejected. A subsequent real keyboard check also confirmed
that modal Undo was disabled by the same closure-based command replacement.
Standard native editing and undo commands now stay in the
responder chain, with reader-only overrides handled by the existing event owner.
The native page canvas responds to Select All and owns PDF undo/redo actions and
their availability. The replaced SwiftUI undo observer has been removed.
Fresh signed acceptance is
required before publication.

Actual native mouse dragging changed the wheel color, RGB field and preview.
Switching to Finder and back retained the color at 100% opacity, and another
wheel drag still changed the intended target. Six successive switches among
text/background/link using the Pencils palette changed only the selected target.
Clicking the labels also retained the chosen color and opacity.

Apply closed the independent panel and retained all three colors on reopening.
Cancel closed it and discarded an unapplied change. Use Theme closed it and
restored the base palette. Invalid RGB disabled Apply; correcting it enabled
Apply again. These were actual app interactions, beyond component assertions.

The initial automation could not enumerate the independent color panel and some
background input attempts did not reach the app. Those attempts are not accepted
results. Native window enumeration and verified foreground interaction supplied
the completed observations. The temporarily launched Orca host was quit.

## Combined reading workflows

On the reporter's Cover C image/caption page, changing to Georgia and switching
between continuous and facing-page reading retained the chapter and visible
caption. Resizing to 600×800 and 1200×760 retained the image aspect ratios,
the single caption beneath its image, and the reading spread. Right reached the
final chapter; another Right stayed there; Left returned to the preceding spread.

These checks supplement the existing A–J native-layout acceptance. They do not
claim every book, every language's linguistic quality, VoiceOver acceptance or
physical testing on the reporter's macOS 15.7.5. Reading-state persistence was
disabled by the existing host preference; close/reopen of the settings panel was
tested, while cross-session book persistence remains covered by the existing
isolated persistence tests.

## Receipts

The ignored `build/ux-depth-20261024/` directory retains the before/after findings,
fixture hashes, native color-panel snapshots, draft-transition states, narrow/wide
screenshots and test logs. Focused appearance/theme checks pass. The complete
Swift, packaging and localization checks are recorded there separately. Shipping
requires checking the exact signed candidate before publication, then verifying
the published bytes/feed and the installed update.
