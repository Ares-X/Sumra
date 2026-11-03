# Reading controls and macOS integration

The normal and floating toolbars show **Aa** in every interface language. It
opens the nonmodal Reading Settings panel. Changes apply to the visible
document while the panel stays open. Typography includes installed
font families and an editable name for supplemental fonts, size, line spacing,
and margins. The existing native passage anchor keeps reflowable text at its
reading location. Theme and layout controls share the reader's existing settings;
Choose Theme and Custom Document Colors are available directly in the panel.
Clicking the selected color well again keeps the system picker connected to it;
choosing another well changes the active target. Apply and Cancel close the picker.
Following the system appearance remains selected when a theme dialog is applied
unchanged. A document's previously saved retired palette is shown only while it
is selected; the built-in presets remain limited to five.

Font size, line height and all four margins have editable numeric fields beside
their sliders in Reading Settings and Default Typography. Typing commits on
Return or focus loss. Select **Custom** to edit margins; it stays Custom even if
the entered values equal a preset. The shorthand margins draft commits with
**Apply Margins** or Return; an empty draft restores document margins. CSS has
its own **Apply CSS** action. The panel names the current document and refreshes
its drafts when another document replaces it. Closing the panel discards
unapplied drafts and retains changes already applied to the document.
The plain-text CSS editor loads the saved draft when reopened and replaces its
visible contents when the current document changes, including an empty draft.
An open panel follows interface-language changes without discarding its drafts.
Numeric fields retain entered precision. An accepted value remains displayed while
the settings binding publishes its update, so moving focus cannot resubmit a stale value.
Consecutive edits to different margin sides retain every accepted value. A numeric
draft belongs to the document in which editing began; replacing that document
starts a fresh native editor for the incoming document's settings.

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
In the compatible HTML/CHM reader, changing the default page spread or reading
direction updates the visible layout immediately. Default-fit changes synchronize
the rendered zoom with the current setting, including a combined settings import.

The compact theme preview shows both pages, including the selected divider
color; disabling the divider leaves uninterrupted paper. Text and links on each
side use the same palette as the reading canvas.

The six Settings categories use system symbols alongside their translated labels.
Native sidebar dividers retain their dragged widths across PDF save/reload,
including an adjacent AI pane. Explicit sidebar-width changes in Advanced
Settings update the mounted reader immediately; transient layout measurements
do not replace the saved width.
The document pane keeps at least 360 pt beside either sidebar. Narrow windows
temporarily compress the sidebar; widening restores its saved width without
changing the selected page layout.
Every split pane reclaims the native top safe area before applying its own
toolbar clearance. Contents and AI must reserve this space once, including
empty contents, either sidebar edge and normal/floating toolbar round trips.
The welcome page's recent-file menu offers Open and Open in New Window;
Open in New Tab is reserved for the file browser in an occupied reader.
Page-grid configuration rows use their controls' natural fitting heights, so
numeric values and the Style picker remain fully visible in the native alert.
Native contents and search-result lists have transparent backgrounds; the
containing sidebar owns their theme surface. AppKit keeps native row selection
and keyboard focus feedback, without adding a separate gray block below search.

Close and Command-W use the document window's close capability, including in
fullscreen when AppKit hides or disables its traffic-light button. An attached
sheet blocks the document close command. Closing still follows the existing
unsaved-changes confirmation and native delegate approval.
AppKit completes ordinary tab closes synchronously and keeps the surviving
document windows in their existing group. Native
titlebar accessories retain their own clicks; the window-drag region excludes
their actual view hierarchy. On macOS 15 and later SwiftUI also owns removal of
the native title item when the reading toolbar hides.

Floating window controls keep AppKit's standard buttons and actions. Their
public tracking area draws a small theme-aware ring around the hovered available
button, without substituting a pressed state or reproducing system button
symbols. Moving away clears it; native click and modifier behavior remains with
the button.

**Page Margins** is also available for PDF, comics and other fixed pages. Narrow,
Medium and Wide use 8, 16 and 24 pt on each fixed-page edge. Reflowed text uses
those vertical margins and twice that amount horizontally, restoring the
comfortable 16/32 pt Medium proportions. Custom values apply exactly on all
four edges. An unset
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
It is off by default.
When **Trim Empty Margins** removes a saved point above the page's cropped
content, restoring that point starts at the cropped page rather than entering
the preceding page. Points within retained content keep their source location.
**Keep current zoom when following links** is also optional. PDF link
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
Paged Markdown keeps consecutive headings with their first body text. Existing
reading positions and bookmarks migrate through their original source locations
and saved typography before the current chapter layout is used. Bookmark titles,
identities, file access and reading preferences remain intact; different source
positions on a merged page remain separate bookmarks.

In the compatible browser reader, a new Find starts at the reading viewport in
the requested direction. Paged and right-to-left layouts use the same source
order and wrap at the beginning or end of the document.

The Find magnifier in either toolbar toggles the complete Find controls and
results. Docked Find groups its field, buttons and match count at the leading
edge of the reader. Documents with page-range search show that filter below.
Command-F opens or refocuses Find. Close Find and Escape return focus
to the reader, cancel delayed and active search, and remove its controls,
results and highlights. Escape also ends a Command-G search while Find is
closed; the retained query remains available for the next Command-G. Text
input keeps native Escape handling, including input-method composition. Reopening
Find searches the retained query and page range again.

Ask Document clears the submitted question when it enters the conversation.
You can draft your next question while the selected CLI responds. If the
selected passage has no readable text, the draft stays in the editor. Cancel
ends the request and keeps any text already received. Codex can reconnect an
interrupted stream within the same turn.

The command palette, bookmark browser and annotations list show a message
when their filtered list is empty. PDF annotations are checked after the
current document revision finishes loading.

Settings → Keyboard Shortcuts supports command search, recording an actual key
combination, conflict feedback, and resetting one command. Custom Toolbar Buttons
supports a command list, reorder and symbol selection, retaining Advanced JSON.
Add the custom button group through macOS **Customize Toolbar** if it is hidden.
Settings → Toolbar → **Toolbar Display** is a single persisted choice shared by
all reader windows and the View menu: **Always Show** (default), **Auto Hide**,
or **Always Hide**. Auto Hide reveals controls across the full measured native
toolbar and tab-bar height, with a minimum entry depth of 48 points. The retention
region is at least 96 points and never shorter than the entry region, so closing
a tab under a stationary pointer keeps the surviving controls reachable. Editing
the page field also keeps controls available. Auto Hide keeps the normal toolbar
installed; Always Hide removes it and reveals only the window buttons on hover. Temporary controls
overlay the book without changing its viewport or pagination, including in full
screen. Presentation hides the reading toolbar, and leaving presentation
restores the chosen mode. The earlier local
hover preference migrates to Auto Hide when enabled, otherwise Always Show.
Native reading, including fixed PDFs and reflowed text, uses the space beneath
temporary chrome, retaining the selected page margin without an additional
titlebar-sized blank band. PDF fitting and scrolling use that same unobscured
viewport. Native scrollbar tracks end clear of overlaid reading controls while
the document can still use the space underneath. Always Show reserves the native controls once. In paged and two-page
TXT reading, the scroll thumb follows the visible range in the source text as
TextKit lays out more lines. Vertical line commands align to complete TextKit lines; the facing
page continues immediately after the last complete line on the leading page.
Advanced settings export/import uses `toolbarDisplayMode` (`shown`, `auto`,
`hidden`). Existing configured `toolbar` commands keep their show/hide semantics
and change this same setting; they do not maintain a separate window override.
In full screen, the active reader synchronizes the native toolbar presentation
policy with this same visibility state, so the menu-bar hover area does not
impose a second reveal threshold or leave hidden chrome covering the first line.
With floating controls, moving the pointer to the very top reveals the macOS
menu bar. The book remains visible below it when switching or creating tabs.
Window close/full-screen controls remain owned by macOS; minimizing is unavailable
while the native full-screen window is active.
In native full screen, AppKit also owns those buttons' opacity and the document
icon's visibility. The reader must not restore their windowed appearance over
the full-screen title. Toolbar mode changes still release the button hiding
owned by the reader, including when returning from Always Hide to Always Show.
In a windowed native reader, Auto Hide and Always Hide retain an arrow cursor
and window dragging over the native titlebar's empty area. The chrome host
receives that band above the reading view, using the real native window-button
container's bounds even when hidden toolbar layout expands into the document.
Native controls installed after the reading view attaches join the same hiding
and dragging behavior as soon as AppKit supplies them.
Native controls keep their own input; the document below still supports text
selection. This does not reserve extra page space or take over full-screen
system controls.
When the native toolbar appears above the document overlay, its filename and
empty space also keep the arrow cursor and window dragging. The reader passes
the original single mouse-down to AppKit for these areas; toolbar buttons and
page inputs retain their own events. Double-click and Command-click remain
native operations, including the document-title path menu.
On macOS 15 and later, SwiftUI removes and restores the native title item with
the reading tools. AppKit does not also change title visibility there: a later
`navigationTitle` update could otherwise restore the title while the window
buttons are hidden and leave it beneath those buttons on the next reveal.
**Floating Reading Controls** is an optional setting, off by default. Home and
initial loading pages use a draggable header with native window buttons and
16-point horizontal gutters. Home keeps its title and Open action in the main
welcome content without duplicating them in that header. Home is an
independent launch window; it has no document tabs or floating reading tools and
does not change the reading setting. Floating reading controls replace
the native strip with separate compact navigation, tab and reading-tool groups;
the existing visibility choice still controls their reveal. Tabs continue to use
the native window group, retain their colors and reveal the selected tab. The
three groups combine into one compact strip in narrow windows. Long filenames
truncate in the middle, keeping both their beginning and extension; one open
document shows its filename only once. Window buttons and reading controls
retain their click areas. Adding a floating tab keeps one visible set of window
buttons; returning to the native toolbar restores its original controls.
Show/Hide Tab Bar stays disabled while floating controls own the tabs, including
when AppKit inserts or rebuilds the native menu item. Native toolbar mode keeps
the command available.
One document uses the available title width; fitting
multiple tabs share the strip, and crowded tabs scroll horizontally while
keeping their selection and close targets usable.
The native full-screen toolbar follows automatic visibility while custom chrome
is active. Its detached companion stays hidden, including during system-menu
tracking and tab changes, so it cannot paint over or intercept custom buttons.
Always Hide suppresses reading tools and document tabs. Moving to the top edge
still reveals the three macOS window buttons, without changing the book viewport
or restoring a native toolbar over them. Presentation hides those buttons too.
Tab switching, batch closing, sessions and named groups read the complete native
group even when its system tab bar is not shown.
With a normal toolbar, Always Show reserves a row below the document for the
progress bar even when the top toolbar hides. The percentage, slider and page
label are centered together; the slider stays still as page numbers change.
The floating progress bar is 26 points tall and 16 points from the bottom edge,
matching the top control inset.
Small-book capsules are 472 points wide, with equal 12-point inner padding and
16-point window gutters in narrow windows. The percentage and page label align
to the outer ends in stable slots; the slider fills the remaining middle width
without shifting when the digits change during navigation or drag previews.
Long page and chapter counters reserve their complete localized label width;
the capsule grows by that difference when the window permits it. A held drag
keeps its counter width and track geometry when background chapter pagination
finishes. Multi-topic CHM progress navigates the whole file sequence. HTML
progress reports and seeks within the current file, including when its folder
contains other HTML files; entering another file starts its local page count.
**Content margins** and **Control clearance** are independent groups in Aa and
Settings → Reading. The four content margins and Narrow/Medium/Wide presets
change page geometry; they no longer choose floating-control clearance.
Top and bottom clearance accept 0–200 pt independently, measured from the window
edge. Defaults are 54 pt above and 44 pt below, retaining the former Medium
layout. A value of 0 allows floating controls to overlap reading content.
With floating controls in full screen, positive top clearance starts below the native menu-bar band;
0 still reserves no control clearance, and hovering never changes the reservation.
Each end uses the larger of its content margin and control clearance rather
than adding both. A hidden toolbar or progress bar reserves no clearance at that
end; Auto Hide retains the chosen area while the controls fade. Native toolbars
continue to use their existing system layout. Find/edit/speech rows and sidebar
buttons still clear the actual interactive controls even with clearance set to 0.
When a docked Find, editing or speech row already clears the floating toolbar,
Contents, search results and AI start below that row without adding the same
top clearance again. Always Hide removes the configured extra sidebar clearance;
the sidebar's interactive heading still clears the visible window buttons.
Window buttons stay below the system's window-sharing indicator band. All
toolbar groups stay in one row, including multiple tabs.
The two values are remembered with the book and format settings. Use Changes as
Defaults also saves them as defaults; explicit Settings edits update open readers
and future documents without replacing content margins. Settings export/import
includes `controlTopMargin` and `controlBottomMargin`; old exports that omit
these fields leave the current clearance unchanged.
The reservation does not change when controls appear or disappear. The floating
hover area retains access to the full control group in narrow windows.
Opening or replacing a book while the pointer stays in that area reveals Auto
Hide controls when the book becomes ready, without requiring another mouse move.
During window resizing, paged reflowable books fit their existing pages to the
changing viewport. Pagination and raster generation wait until the drag ends,
then refresh at the final size while retaining the reading passage. While a
facing spread is in **Fit Page**, both existing pages scale together until the
new layout is ready. This keeps neighboring artwork aligned throughout the drag.
In a paged, facing layout, **Fit Page** fits each page into its own half of the
spread and centers the two vertically. When a normalized EPUB cover faces an
image-only page, the cover fits the facing artwork's frame, including its book
or reader margins. Both pictures retain their aspect ratio. This presentation
applies to the paired **Fit Page** view; solo covers, prose, author-sized
illustrations and other zoom modes retain their document geometry.
**Cover on Its Own** gives the separate cover the full viewport for fitting.

PDF pages remain fixed-layout pages: **Fit Page** scales the paper, not its text
flow. **Fit Width in Continuous View** selects single-page continuous reading
and width fitting; **Trim Empty Margins** can additionally crop empty object
bounds. Neither action rewraps PDF text or recognizes text in scanned images.
An image covering the whole page keeps its internal scanned whitespace.
**Use Document Layout** follows the file's preferred layout metadata; it does
not select one or two pages in response to window width. A manually selected
two-page layout stays selected when the window narrows.
**New Tab** is available in the toolbar, Tabs menu and with Command-T. It selects
files first and opens them as document tabs, independently of the default open
policy; canceling creates nothing. After selection, the new tab displays Opening
until the file is ready. Welcome is reserved for windows opened without a file.
The system tab-bar New Tab action uses the
same command. **Home** opens or activates a separate launch window and retains
all open books. Closing Home does not close their windows. Reopening the running
app from the Dock restores an existing reader or creates Home when none remain,
even if an auxiliary system window is still visible.
**Move Tab Left/Right** moves the active book one position while retaining that
book's window, reading position and selection. Native tab captions and their
click targets follow the new order; moving beyond either end leaves it unchanged.
**Open Documents** chooses New Window (the existing
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

Saved groups follow the current New Window / New Tab / Replace Current opening
policy. Restored tabs keep saved order after existing siblings. Empty groups
cannot be restored; saving an existing name offers Replace, Rename or Cancel.
Saved native tabs, including named tab groups, open their documents only when
activated. A moved file retains its macOS identity where the filesystem supports
it. Progress, bookmarks and saved tabs migrate to its new path. **File → Relocate File…** lets you choose a replacement when the original is unavailable.
Explicitly selecting an existing file opens that selected pathname. Renaming a
live PDF preserves native annotations and pending form input; saving refreshes
bookmarks after the atomic file replacement.

**Choose Page by Thumbnail** shows sequential pages around the current page,
without the command palette's search and category controls or history sorting.
The thumbnail chooser accepts Up/Down to change selection, Return to navigate,
and Escape to close without changing the page. Single-click anywhere on a row to select it in either chooser; double-click or
press Return to open it. A separate *Current Page* subtitle marks the page being read. Custom Document Colors includes
the page divider color and visibility; these overrides persist with the book,
and **Use Theme** restores the theme's divider.

**Send by Email** uses the macOS compose-email sharing service with the current
document attached. Unavailable or failed sharing displays the system error;
when a default email application is configured, the failure message names it
and explains that attachment sharing support is required. The app does not
change the system default email application.

EPUB, MOBI/PRC, Kindle AZW/AZW3, FB2, CBZ, CBR, CBT and CB7 register
read-only Quick Look thumbnail and preview extensions with the bundled app.
Select a file in Finder and press Space. Use the arrows below the preview to
turn pages. If a page fails to render, the error appears below the last readable
page. Its buttons still work, so you can retry or return to another readable page.
Finder uses the keyboard arrows to browse files.
The operating system manages extension enablement
and which provider handles a file. These extensions do not register PDF or plain
ZIP/RAR/7z files and do not create reader history. Reading and preview use the
same bundled decoder libraries; a bare `swift run` does not install extensions.

For printing, use the macOS print panel's Range, Paper Size, Orientation, Scaling
and Paper Handling → Sheets to Print → Odd Only / Even Only controls. Actual
duplex availability and paper handling depend on the selected printer/driver.
The [acceptance record](READER_ACCEPTANCE_20261023.md) separates observed controls
from physical printer output.

Mouse-moved events can carry either document/owned-child coordinates or, when AppKit supplies no associated window, screen coordinates. The existing toolbar owner converts the latter before its key-window and top-region hover decision.


Browser-to-native Markdown links retain their explicit encoded heading fragment
when switching renderers. That destination takes precedence over the target's
saved reading position; ordinary browser sibling and same-file links keep their
existing navigation path.

Browser Read Aloud keeps true paragraph/block boundaries in its speech text,
while text inside inline elements remains continuous. Speech highlighting maps
its UTF-16 offsets back to the original text nodes, including gaps introduced
for paragraph pauses. Find, Copy and the publication's DOM remain literal.
Natural completion clears the last highlighted word in both the native and
browser reader paths.

The document file-browser sheet completes its native close notification before
opening the selected document, including explicit new-window and new-tab actions.
This lets AppKit give the destination its normal front-window and keyboard focus.

Text thumbnails read only the initial 8,000 complete Swift Characters, with the
following character needed to settle a chunk boundary. Full TXT opening still
loads the document normally; sidecar covers remain preferred. Preview encoding
detection uses the existing UTF-8-first/Foundation policy on the consumed prefix,
so unseen later bytes cannot influence that heuristic.

Overlay progress controls reserve their actual interaction height in Contents and
AI sidebars, including the floating footer's hover area. Existing root padding
and the status row count toward that clearance once. The reading canvas keeps its
existing page margins and full-bleed behavior. Selecting the footer's Hidden
display mode releases the sidebar space; Auto Hide keeps the hover area clear.

Command palette rows retain command availability: unavailable actions are disabled for pointer and accessibility input, while enabled rows keep single-click selection and double-click/Return activation.
