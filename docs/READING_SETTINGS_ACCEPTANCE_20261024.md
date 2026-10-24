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

The five presets are Light, Light Warm, Dark, Dracula and Gruvbox. System is the
automatic appearance option; user-created themes and the current retired choice
are separate from that preset count. Aa exposes the visual chooser and document
color editor directly.

## Color-panel state transitions

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
