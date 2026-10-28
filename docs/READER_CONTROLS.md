# Reading controls and macOS integration

The **Aa** toolbar item opens a nonmodal Reading Settings panel. Changes apply to
the visible document while the panel stays open. Typography includes installed
font families and an editable name for supplemental fonts, size, line spacing,
and margins. The existing native passage anchor keeps reflowable text at its
reading location. Theme and layout controls share the reader's existing settings;
Choose Theme and Custom Document Colors are available directly in the panel.
Clicking the selected color well again keeps the system picker connected to it;
choosing another well changes the active target. Apply and Cancel close the picker.
Following the system appearance remains selected when a theme dialog is applied
unchanged. A document's previously saved retired palette is shown only while it
is selected; the built-in presets remain limited to five.

Advanced Typography and CSS uses drafts until **Apply Margins and CSS** (or Return
in the margins field). The panel names the current document and refreshes its
drafts when another document replaces it. The basic margin slider follows the
applied advanced margins; unequal edges are labelled **Custom**. Moving that
slider sets equal edges and updates the advanced draft, so applying CSS does not
restore an older margin value. Closing the panel discards unapplied drafts and
retains changes already applied to the document.
The plain-text CSS editor loads the saved draft when reopened and replaces its
visible contents when the current document changes, including an empty draft.
An open panel follows interface-language changes without discarding its drafts.
Its compact margin label rounds for display; the advanced values retain their
full precision.

Main **Settings** changes reading appearance and layout in every open reader
immediately, including while Settings owns keyboard focus. Only the edited
options change, and reflow retains the visible passage. Newly opened books read
the latest defaults. A saved book or format snapshot predating an explicit global
change cannot restore the older value of that option; unrelated book settings
and positions remain intact. Later per-book changes from **Aa** can still be
remembered. **Use Changes as Defaults** publishes Aa typography to all readers.
Reading-toolbar layout and zoom actions remain local to the book rather than
silently replacing the global defaults during restoration. Opening policies and
startup choices take effect at their named action. Advanced Apply and Import use
the same live update path. The per-setting restore markers are internal,
persist across app updates and stay out of public settings exports.

The compact theme preview shows both pages, including the selected divider
color; disabling the divider leaves uninterrupted paper. Text and links on each
side use the same palette as the reading canvas.

The six Settings categories use system symbols alongside their translated labels.

**Page Margins** offers Narrow (8 pt), Medium (16 pt) and Wide (24 pt)
presets for reflowable books, plain text and browser documents. Presets set all
four edges; the advanced controls still support unequal margins. An unset
override is labelled Custom and keeps the document's original margins. New
profiles start with explicit Medium margins; upgrades retain existing implicit,
custom and per-book settings. Preference migration is versioned and runs before
reader windows open. Export/import includes the margins and reading-control
preferences, while the migration version remains internal.

Semantic FB2 title pages and generated legacy covers fit their title, artwork and
author together. Reader-selected margins frame that intrinsic group instead of
retaining unused full-page paper; Fit Page keeps those margins in display points
as the window grows. Explicit publisher spacing and later user CSS keep their
authored canvas. This changes the fitted title canvas without changing chapter
pagination, image coordinates or search locations.

For fixed pages, **Keep scroll position when turning pages** preserves the visible
origin as fractions of the displayed page dimensions, including rotated pages.
It is off by default. **Keep current zoom when following links** is also optional. PDF link
jumps briefly mark their destination; ebook links navigate without that marker.
Back restores the recorded reading viewport. Hover previews remain passive,
so the first click follows the source link. Previews fit the available space
above or below that link, scaling down on short or narrow displays while keeping
the source link visible.
In continuous reflowable books, previews draw only their visible area; internal
link previews begin at the destination within the chapter. Opening Page
Thumbnails reveals the current page, and navigation keeps that thumbnail in view.
Fixed pages retain their complete preview and viewer rotation.

The bottom progress control follows the renderer's position. Native continuous
books use the actual scroll position within the current canvas, including long
single chapters. Unread chapters still have estimated heights, so their progress
keeps the approximate `≈` marker. Dragging previews the percentage and target label and commits
one seek on release; browser-file and continuous labels keep their current
file/page semantics until the seek completes. Keyboard and accessibility increments also scroll within the
canvas. Returning to paged reading restores physical page or approximate chapter
progress. Saved passages and Back retain their source position through reflow.
Mouse-up retains the chosen slider preview until the reader has applied the
seek, instead of briefly painting the old position. Continuous reflow confirms
the seek after its measured viewport records the new fraction. A newer drag or
keyboard adjustment keeps its preview when an earlier seek finishes, including
when returning to the page that was visible before the pending seek.
Approximate paged chapter progress gives each known page a distinct position;
chapter endings do not alias the next chapter's beginning. Clicking the current
position preserves navigation history, and a one-page final chapter reaches
100%. Unread chapter counts remain unresolved until that chapter is needed.
Two-page progress follows visible spreads, including a separate cover and a
one-page final spread, so the last visible spread reaches 100%. **Progress Bar**
in the View menu and Settings supports Always Show, Auto Hide and Always Hide.
The bottom 56 points reveal Auto Hide without requiring the pointer to reach
the Dock. Dragging and keyboard adjustment keep the control visible.

TXT bookmarks use their existing UTF-16 character anchors to order positions
within a wrapped source line. Previous/Next Bookmark visits each position and
wraps in reading order; older line-only bookmarks remain supported.

In the compatible browser reader, a new Find starts at the reading viewport in
the requested direction. Paged and right-to-left layouts use the same source
order and wrap at the beginning or end of the document.

Settings → Keyboard Shortcuts supports command search, recording an actual key
combination, conflict feedback, and resetting one command. Custom Toolbar Buttons
supports a command list, reorder and symbol selection, retaining Advanced JSON.
Add the custom button group through macOS **Customize Toolbar** if it is hidden.
Settings → Toolbar → **Toolbar Display** is a single persisted choice shared by
all reader windows and the View menu: **Always Show** (default), **Auto Hide**,
or **Always Hide**. Auto Hide reveals controls within the top 48 points and
keeps them available while the pointer remains within the top 96 points or edits
the page field. Always Hide does not reveal controls on hover. Temporary controls
overlay the book without changing its viewport or pagination, including in full
screen. Presentation hides the reading toolbar, and leaving presentation
restores the chosen mode. The earlier local
hover preference migrates to Auto Hide when enabled, otherwise Always Show.
Advanced settings export/import uses `toolbarDisplayMode` (`shown`, `auto`,
`hidden`). Existing configured `toolbar` commands keep their show/hide semantics
and change this same setting; they do not maintain a separate window override.
In full screen, the active reader synchronizes the native toolbar presentation
policy with this same visibility state, so the menu-bar hover area does not
impose a second reveal threshold or leave hidden chrome covering the first line.
Window close/full-screen controls remain owned by macOS; minimizing is unavailable
while the native full-screen window is active.
**Floating Reading Controls** is an optional setting, off by default. Welcome and
initial loading pages keep the native toolbar without changing this setting. It replaces
the native strip with separate compact navigation, tab and reading-tool groups;
the existing visibility choice still controls their reveal. Tabs continue to use
the native window group, retain their colors and reveal the selected tab. The
three groups combine into one compact strip in narrow windows. Long filenames
truncate in the middle, keeping both their beginning and extension; one open
document shows its filename only once. Window buttons and reading controls
retain their click areas.
The floating progress bar is 26 points tall and 6 points from the bottom edge.
Its capsule is at most 472 points wide, with equal 12-point inner padding and
16-point window gutters in narrow windows. The percentage and page label align
to the outer ends in stable slots; the slider fills the remaining middle width
without shifting when the digits change during navigation or drag previews.
Medium margins reserve a small gap around the floating controls; Narrow allows
the controls to cover reading content; Wide keeps additional clearance. This
reservation includes the book's own margin instead of adding a second full
margin: the top content inset is 48 points for Medium and 56 for Wide, including
the 36-point toolbar and its 10-point top inset. The bottom inset is 34/40 points
respectively. All toolbar groups stay in one row, including multiple tabs.
The reservation does not change when controls appear or disappear. The floating
hover area retains access to the full control group in narrow windows.
Opening or replacing a book while the pointer stays in that area reveals Auto
Hide controls when the book becomes ready, without requiring another mouse move.
During window resizing, paged reflowable books fit their existing pages to the
changing viewport. Pagination and raster generation wait until the drag ends,
then refresh at the final size while retaining the reading passage. Both halves
of a spread adopt the new page dimensions together.
**New Tab** is available in the toolbar, Tabs menu and with Command-T, including
the empty welcome window. **Open Documents** chooses New Window (the existing
default), New Tab or Replace Current; replacing a modified document still uses
the normal save/discard/cancel decision.
Reader chrome uses a short 180 ms eased reveal. A hidden toolbar waits 140 ms
after pointer exit, then fades for 120 ms; returning reverses the fade without
remounting controls. Temporary toolbar chrome omits the native title/background
flash. Reading Settings and the selection toolbar share the same quiet opacity
transitions. Sidebars and inline search fade into their settled layout; buttons
use a light hover/press wash and active tools retain a restrained accent.
Animations do not resize or animate the document. Reduce Motion skips the fades
and toolbar exit delay; dismissing selection controls immediately stop intercepting
input and preserve the reader's selection and keyboard focus.
Selecting reader text shows nearby existing Copy, Read, Translate and available
Highlight actions without taking keyboard focus from the reader.

Saved native tabs, including named tab groups, open their documents only when
activated. A moved file retains its macOS identity where the filesystem supports
it. Progress, bookmarks and saved tabs migrate to its new path. **File → Relocate File…** lets you choose a replacement when the original is unavailable.
Explicitly selecting an existing file opens that selected pathname. Renaming a
live PDF preserves native annotations and pending form input; saving refreshes
bookmarks after the atomic file replacement.

EPUB, MOBI/PRC, Kindle AZW/AZW3, FB2, CBZ, CBR, CBT and CB7 register
read-only Quick Look thumbnail and preview extensions with the bundled app.
Select a file in Finder and press Space; use the preview's arrows to navigate. The operating system manages extension enablement
and which provider handles a file. These extensions do not register PDF or plain
ZIP/RAR/7z files and do not create reader history. Reading and preview use the
same bundled decoder libraries; a bare `swift run` does not install extensions.

For printing, use the macOS print panel's Range, Paper Size, Orientation, Scaling
and Paper Handling → Sheets to Print → Odd Only / Even Only controls. Actual
duplex availability and paper handling depend on the selected printer/driver.
The [acceptance record](READER_ACCEPTANCE_20261023.md) separates observed controls
from physical printer output.
