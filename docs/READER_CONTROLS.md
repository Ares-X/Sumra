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
screen. Presentation hides the persistent toolbar; Auto Hide still permits hover
access, and leaving presentation restores the chosen mode. The earlier local
hover preference migrates to Auto Hide when enabled, otherwise Always Show.
Advanced settings export/import uses `toolbarDisplayMode` (`shown`, `auto`,
`hidden`). Existing configured `toolbar` commands keep their show/hide semantics
and change this same setting; they do not maintain a separate window override.
In full screen, the active reader synchronizes the native toolbar presentation
policy with this same visibility state, so the menu-bar hover area does not
impose a second reveal threshold or leave hidden chrome covering the first line.
Window close/full-screen controls remain owned by macOS; minimizing is unavailable
while the native full-screen window is active.
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
