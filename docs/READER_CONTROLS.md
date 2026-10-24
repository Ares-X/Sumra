# Reading controls and macOS integration

The **Aa** toolbar item opens a nonmodal Reading Settings panel. Changes apply to
the visible document while the panel stays open. Typography includes installed
font families and an editable name for supplemental fonts, size, line spacing,
and margins. The existing native passage anchor keeps reflowable text at its
reading location. Theme and layout controls share the reader's existing settings;
Choose Theme and Custom Document Colors are available directly in the panel.
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

For fixed pages, **Keep scroll position when turning pages** preserves the visible
origin as fractions of the displayed page dimensions, including rotated pages.
It is off by default. **Keep current zoom when following links** is also optional. Link
jumps briefly mark their destination; Back restores the recorded reading viewport.

Settings → Keyboard Shortcuts supports command search, recording an actual key
combination, conflict feedback, and resetting one command. Custom Toolbar Buttons
supports a command list, reorder and symbol selection, retaining Advanced JSON.
Add the custom button group through macOS **Customize Toolbar** if it is hidden.
Selecting reader text shows nearby existing Copy, Read, Translate and available
Highlight actions without taking keyboard focus from the reader.

Saved native tabs, including named tab groups, open their documents only when
activated. A moved file retains its macOS identity where the filesystem supports
it. Progress, bookmarks and saved tabs migrate to its new path. **File → Relocate File…** lets you choose a replacement when the original is unavailable.
Explicitly selecting an existing file opens that selected pathname. Renaming a
live PDF preserves native annotations and pending form input; saving refreshes
bookmarks after the atomic file replacement.

EPUB, CBZ, CBR, CBT and CB7 register read-only Quick Look thumbnail and preview
extensions with the bundled app. Select a file in Finder and press Space; use the
preview's arrows to navigate. The operating system manages extension enablement
and which provider handles a file. These extensions do not register PDF or plain
ZIP/RAR/7z files and do not create reader history. Reading and preview use the
same bundled decoder libraries; a bare `swift run` does not install extensions.

For printing, use the macOS print panel's Range, Paper Size, Orientation, Scaling
and Paper Handling → Sheets to Print → Odd Only / Even Only controls. Actual
duplex availability and paper handling depend on the selected printer/driver.
The [acceptance record](READER_ACCEPTANCE_20261023.md) separates observed controls
from physical printer output.
