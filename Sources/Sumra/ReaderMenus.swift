#if os(macOS)
import SwiftUI

@MainActor
func chooseDocuments(_ receive: @escaping ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.begin { if $0 == .OK { receive(panel.urls) } }
}

// One command catalog serves the menu bar, command palette and shortcut editor.
enum ReaderMenuCommand: String, Codable, CaseIterable, Identifiable {
    case open, save, saveCopy, exportPDF, reload, properties, copyPath, close
    case files, openNoHistory, discard, rename, trash, trashAndNext, home
    case duplicateTab, duplicateWindow, nextTab, previousTab, nextTabSmart, previousTabSmart, moveTabLeft, moveTabRight, closeOtherTabs, closeLeftTabs, closeRightTabs, closeAllTabs, saveTabGroup, restoreTabGroup, tabColor, reopenClosed, shareEmail, openWith
    case contents, contentsSearch, thumbnails, bookmarks, fullscreen, presentation, palette, ai
    case find, previous, next, goToPage, back, forward, previousFile, nextFile
    case findNext, findPrevious, findSelectionNext, findSelectionPrevious, matchCase, wholeWord, firstPage, lastPage, scrollUp, scrollDown, scrollLeft, scrollRight, pageUp, pageDown, halfPageUp, halfPageDown
    case zoomIn, zoomOut, actual, fitPage, fitWidth, fitHeight, fitOrientation, shrinkToFit, fitContent, fitVisible, customZoom, zoomToSelection, paged, continuous, twoPages, coverOnItsOwn, rightToLeft, bookmark
    case rotateLeft, rotateRight, copy, copyImage, selectAll, speak, pauseSpeaking, continueSpeaking, stopSpeaking
    case pdfExtract, pdfDelete, pdfMerge, pdfEncrypt, pdfDecrypt, pdfFlatten, pdfCompress, pdfDecompress, pdfBake, pdfRedact, pdfSign, pdfSignatures, pdfText, pdfOutline, pdfXMP, pdfAttachments, pdfImages
    case pdfEditing, highlight, underline, strike, note, freeText, ink, line, square, circle, link, editAnnotation, deleteAnnotation

    case selectCurrentPage, copySelectionImage, saveSelection, printSelection, selectRectangle, tocExpand, tocCollapse, tocLevel2, tocLevel3, tocCurrent, tocSiblings, bookmarkToggle, bookmarkNext, bookmarkPrevious, bookmarkSort, copyLocation, fitPageSingle, fitWidthContinuous, cycleZoom, uniformWidth, trimMargins, freePan, showLinks, disableLinks, hoverPreview, keyboardLinks, keyboardSelection, autoScroll, scrollFaster, scrollSlower, readingBar, readingBarInvert, readingBarLarger, readingBarSmaller, laserPointer, blankBlack, blankWhite, toolbar, pageInfo, cursorPosition, annotations

    case searchGoogle, searchBing, searchWikipedia, searchScholar, translateGoogle, translateDeepL

    case squiggly, caret, stamp, insertImage, pasteImageAnnotation, polygon, polyline, attachment, replaceAttachment, redactMark, inkEraser, highlightBrush, editAnnotations, copyAnnotation, cutAnnotation, pasteAnnotation
    case embeddedFiles, generatedHTML, annotationsVisible, highlightFormFields, pageBoxes
    case saveFormatDefaults, clearFormatDefaults
    case saveImage, cropImage, resizeImage, pasteImage, screenshot, lensPage, lensSelection
    case screenshotHotkey
    case closeAndQuit, pdfInfo, scrollbarsSmart, scrollbarsShown, scrollbarsHidden
    case print
    case setTheme
    case autoContents
    case autoLayout
    case inverseSearch, toggleInverseSearch
    case invertColors, grayscale, toggleLightDark
    case pageGrid, configurePageGrid, transparencyGrid
    case imageBounds, fitContentArea
    case cycleFocus, navigateThumbnail
    case speakFromTop, speakFromCursor, speakSelection
    case bookmarksWindow, showLog, showErrors
    case documentColorsOff, documentColorsSmart, documentColorsLegacy, customDocumentColors, preserveImages, engineeringOff, engineeringAuto, engineeringOn

    var id: String { rawValue }
    var title: String { L(englishTitle) }
    private var englishTitle: String {
        switch self {
        case .pdfEditing: return "Enable PDF Editing"
        case .setTheme: return "Choose Theme…"
        case .print: return "Print…"
        case .closeAndQuit: return "Close Document and Quit If Last"
        case .pdfInfo: return "PDF Resource Information…"
        case .scrollbarsSmart: return "Automatic Scrollbars"
        case .scrollbarsShown: return "Always Show Scrollbars"
        case .scrollbarsHidden: return "Hide Scrollbars"
        case .screenshotHotkey: return "Global Screenshot Shortcut…"
        case .imageBounds: return "Show Embedded Image Boundaries"
        case .fitContentArea: return "Show Fit Content Area"
        case .bookmarksWindow: return "Bookmarks Window"
        case .showLog: return "Application Log"
        case .showErrors: return "Errors in This Session"
        case .speakFromTop: return "Read from Visible Page"
        case .speakFromCursor: return "Read from Cursor"
        case .speakSelection: return "Read Selection"
        case .cycleFocus: return "Move Focus to Next Pane"
        case .navigateThumbnail: return "Choose Page by Thumbnail…"
        case .documentColorsOff: return "Original Document Colors"
        case .documentColorsSmart: return "Theme Colors (Smart)"
        case .documentColorsLegacy: return "Theme Colors (Legacy)"
        case .customDocumentColors: return "Custom Document Colors…"
        case .preserveImages: return "Preserve PDF Image Colors"
        case .engineeringOff: return "Engineering Enhancement Off"
        case .engineeringAuto: return "Engineering Enhancement Automatic"
        case .engineeringOn: return "Engineering Enhancement On"
        case .pageGrid: return "Show Page Grid"
        case .configurePageGrid: return "Configure Page Grid…"
        case .transparencyGrid: return "Show Transparency Grid"
        case .invertColors: return "Invert Document Colors"
        case .grayscale: return "Grayscale"
        case .toggleLightDark: return "Toggle Light and Dark Theme"
        case .inverseSearch: return "Open Source at Reading Position"
        case .toggleInverseSearch: return "Enable Inverse Search"
        case .autoLayout: return "Use Document Layout"
        case .autoContents: return "Generate Contents from Headings"
        case .saveImage: return "Save Image…"
        case .cropImage: return "Crop Image…"
        case .resizeImage: return "Resize Image…"
        case .pasteImage: return "Open Clipboard Image"
        case .screenshot: return "Capture Screen Area…"
        case .lensPage: return "Search Page with Google Lens"
        case .lensSelection: return "Search Selection with Google Lens"
        case .saveFormatDefaults: return "Use Current Settings for This Format"
        case .clearFormatDefaults: return "Clear Defaults for This Format"
        case .embeddedFiles: return "Embedded Files…"
        case .generatedHTML: return "Show Generated HTML…"
        case .annotationsVisible: return "Show Annotations"
        case .highlightFormFields: return "Highlight Form Fields"
        case .pageBoxes: return "Show PDF Page Boxes"
        case .selectCurrentPage: return "Select Current Page"
        case .copySelectionImage: return "Copy Selection as Image"
        case .saveSelection: return "Save Selection as Image…"
        case .printSelection: return "Print Selection…"
        case .selectRectangle: return "Rectangular Selection"
        case .tocExpand: return "Expand All Contents"
        case .tocCollapse: return "Collapse All Contents"
        case .tocLevel2: return "Expand Contents to Level 2"
        case .tocLevel3: return "Expand Contents to Level 3"
        case .tocCurrent: return "Reveal Current Chapter"
        case .tocSiblings: return "Collapse Sibling Chapters"
        case .bookmarkToggle: return "Toggle Bookmark at Position"
        case .bookmarkNext: return "Next Bookmark"
        case .bookmarkPrevious: return "Previous Bookmark"
        case .bookmarkSort: return "Sort Bookmarks by Name"
        case .copyLocation: return "Copy Reading Location"
        case .fitPageSingle: return "Fit Page in Single Page View"
        case .fitWidthContinuous: return "Fit Width in Continuous View"
        case .cycleZoom: return "Cycle Zoom Mode"
        case .uniformWidth: return "Uniform Page Width"
        case .trimMargins: return "Trim Empty Margins"
        case .freePan: return "Free Pan"
        case .showLinks: return "Show Link Boundaries"
        case .disableLinks: return "Disable Links"
        case .hoverPreview: return "Link Hover Preview"
        case .keyboardLinks: return "Follow Links with Keyboard"
        case .keyboardSelection: return "Select Text with Keyboard"
        case .autoScroll: return "Automatic Scrolling"
        case .scrollFaster: return "Scroll Faster"
        case .scrollSlower: return "Scroll Slower"
        case .readingBar: return "Reading Bar"
        case .readingBarInvert: return "Invert Reading Bar"
        case .readingBarLarger: return "Larger Reading Bar"
        case .readingBarSmaller: return "Smaller Reading Bar"
        case .laserPointer: return "Laser Pointer"
        case .blankBlack: return "Presentation Black Screen"
        case .blankWhite: return "Presentation White Screen"
        case .toolbar: return "Toggle Toolbar"
        case .pageInfo: return "Page Information Overlay"
        case .cursorPosition: return "Cursor Position"
        case .annotations: return "Annotation List"
        case .searchGoogle: return "Search Selection with Google"
        case .searchBing: return "Search Selection with Bing"
        case .searchWikipedia: return "Search Selection in Wikipedia"
        case .searchScholar: return "Search Selection in Google Scholar"
        case .translateGoogle: return "Translate Selection with Google"
        case .translateDeepL: return "Translate Selection with DeepL"
        case .squiggly: return "Squiggly Underline Selection"
        case .caret: return "Add Caret"
        case .stamp: return "Add Stamp"
        case .insertImage: return "Insert Image…"
        case .pasteImageAnnotation: return "Paste Image as Annotation"
        case .polygon: return "Add Polygon"
        case .polyline: return "Add Polyline"
        case .attachment: return "Add File Attachment…"
        case .replaceAttachment: return "Replace Attachment File…"
        case .redactMark: return "Mark for Redaction"
        case .inkEraser: return "Erase Ink"
        case .highlightBrush: return "Highlight Brush"
        case .editAnnotations: return "Move and Resize Annotations"
        case .copyAnnotation: return "Copy Annotation"
        case .cutAnnotation: return "Cut Annotation"
        case .pasteAnnotation: return "Paste Annotation"
        case .open: return "Open…"
        case .files: return "Browse Files…"
        case .openNoHistory: return "Open without History…"
        case .discard: return "Discard Changes"
        case .rename: return "Rename File…"
        case .trash: return "Move File to Trash…"
        case .trashAndNext: return "Trash File and Open Next…"
        case .home: return "Home"
        case .save: return "Save"
        case .saveCopy: return "Save a Copy…"
        case .exportPDF: return "Export PDF…"
        case .reload: return "Reload"
        case .properties: return "Document Properties…"
        case .copyPath: return "Copy File Path"
        case .close: return "Close Document"
        case .duplicateTab: return "Duplicate in New Tab"
        case .duplicateWindow: return "Duplicate in New Window"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .nextTabSmart: return "Next Tab by Recent Use"
        case .previousTabSmart: return "Previous Tab by Recent Use"
        case .moveTabLeft: return "Move Tab Left"
        case .moveTabRight: return "Move Tab Right"
        case .closeOtherTabs: return "Close Other Tabs"
        case .closeLeftTabs: return "Close Tabs to the Left"
        case .closeRightTabs: return "Close Tabs to the Right"
        case .closeAllTabs: return "Close All Tabs"
        case .saveTabGroup: return "Save Tab Group…"
        case .restoreTabGroup: return "Restore Tab Group…"
        case .tabColor: return "Tab Color…"
        case .reopenClosed: return "Reopen Closed Document"
        case .shareEmail: return "Send by Email…"
        case .openWith: return "Open With…"
        case .contents: return "Contents"
        case .contentsSearch: return "Search Contents"
        case .thumbnails: return "Page Thumbnails"
        case .bookmarks: return "Bookmarks"
        case .fullscreen: return "Toggle Full Screen"
        case .presentation: return "Presentation"
        case .palette: return "Command Palette…"
        case .ai: return "Ask AI…"
        case .find: return "Find…"
        case .goToPage: return "Go to Page…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .findSelectionNext: return "Find Next Selection"
        case .findSelectionPrevious: return "Find Previous Selection"
        case .matchCase: return "Match Case"
        case .wholeWord: return "Match Whole Word"
        case .firstPage: return "First Page"
        case .lastPage: return "Last Page"
        case .scrollUp: return "Scroll Up"
        case .scrollDown: return "Scroll Down"
        case .scrollLeft: return "Scroll Left"
        case .scrollRight: return "Scroll Right"
        case .pageUp: return "Scroll Up a Page"
        case .pageDown: return "Scroll Down a Page"
        case .halfPageUp: return "Scroll Up Half a Page"
        case .halfPageDown: return "Scroll Down Half a Page"
        case .previous: return "Previous Page"
        case .next: return "Next Page"
        case .back: return "Go Back"
        case .forward: return "Go Forward"
        case .previousFile: return "Previous File"
        case .nextFile: return "Next File"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actual: return "Actual Size"
        case .fitPage: return "Fit Page"
        case .fitWidth: return "Fit Width"
        case .fitHeight: return "Fit Height"
        case .fitOrientation: return "Fit by Orientation"
        case .shrinkToFit: return "Shrink to Fit"
        case .fitContent: return "Fit Content"
        case .fitVisible: return "Fit Visible Content"
        case .customZoom: return "Custom Zoom…"
        case .zoomToSelection: return "Zoom to Selection"
        case .paged: return "Paged"
        case .continuous: return "Continuous"
        case .twoPages: return "Two Pages"
        case .coverOnItsOwn: return "Cover on Its Own"
        case .rightToLeft: return "Right to Left"
        case .bookmark: return "Bookmark This Position…"
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .copy: return "Copy"
        case .copyImage: return "Copy Page Image"
        case .selectAll: return "Select All"
        case .speak: return "Read Aloud"
        case .pauseSpeaking: return "Pause Reading"
        case .continueSpeaking: return "Continue Reading"
        case .stopSpeaking: return "Stop Reading"
        case .pdfExtract: return "Extract Pages…"
        case .pdfDelete: return "Delete Pages…"
        case .pdfMerge: return "Merge PDFs…"
        case .pdfEncrypt: return "Encrypt PDF…"
        case .pdfDecrypt: return "Decrypt PDF…"
        case .pdfFlatten: return "Flatten Annotations…"
        case .pdfCompress: return "Compress PDF…"
        case .pdfDecompress: return "Decompress PDF…"
        case .pdfRedact: return "Apply Redactions…"
        case .pdfBake: return "Bake Annotations and Forms…"
        case .pdfSign: return "Digitally Sign PDF…"
        case .pdfSignatures: return "Digital Signature Details…"
        case .pdfText: return "Extract Text…"
        case .pdfOutline: return "Export Outline…"
        case .pdfXMP: return "Export XMP Metadata…"
        case .pdfAttachments: return "Extract Embedded Files…"
        case .pdfImages: return "Export Pages as Images…"
        case .highlight: return "Highlight Selection"
        case .underline: return "Underline Selection"
        case .strike: return "Strike Out Selection"
        case .note: return "Add Note…"
        case .freeText: return "Add Text…"
        case .ink: return "Draw on PDF"
        case .line: return "Add Line"
        case .square: return "Add Rectangle"
        case .circle: return "Add Ellipse"
        case .link: return "Add Link…"
        case .editAnnotation: return "Edit Annotation…"
        case .deleteAnnotation: return "Delete Annotation"
        }
    }

    var defaultShortcut: String {
        switch self {
        case .print: return "cmd+p"
        case .cycleFocus: return "f6"
        case .open: return "cmd+o"
        case .close: return "cmd+w"
        case .save: return "cmd+s"
        case .saveCopy: return "cmd+shift+s"
        case .reload: return "cmd+r"
        case .contents: return "cmd+alt+t"
        case .fullscreen: return "cmd+ctrl+f"
        case .nextTab: return "cmd+shift+]"
        case .previousTab: return "cmd+shift+["
        case .nextTabSmart: return "ctrl+tab"
        case .previousTabSmart: return "ctrl+shift+tab"
        case .reopenClosed: return "cmd+shift+t"
        case .presentation: return "cmd+shift+f"
        case .palette: return "cmd+shift+p"
        case .find: return "cmd+f"
        case .goToPage: return "cmd+l;g"
        case .findNext: return "cmd+g"
        case .findPrevious: return "cmd+shift+g"
        case .findSelectionNext: return "cmd+alt+g"
        case .findSelectionPrevious: return "cmd+alt+shift+g"
        case .firstPage: return "cmd+home"
        case .lastPage: return "cmd+end"
        case .previous: return "cmd+["
        case .next: return "cmd+]"
        case .back: return "cmd+left"
        case .forward: return "cmd+right"
        case .previousFile: return "cmd+alt+up"
        case .nextFile: return "cmd+alt+down"
        case .zoomIn: return "cmd+="
        case .zoomOut: return "cmd+-"
        case .actual: return "cmd+1"
        case .fitPage: return "cmd+0"
        case .fitWidth: return "cmd+2"
        case .bookmark: return "cmd+d"
        case .copy: return "cmd+c"
        case .selectAll: return "cmd+a"
        default: return ""
        }
    }

    @MainActor
    func checked(_ state: ReaderState?) -> Bool? {
        guard let state else { return nil }
        switch self {
        case .pdfEditing: return state.pdfEditingEnabled
        case .fullscreen: return state.window?.styleMask.contains(.fullScreen) == true
        case .scrollbarsSmart: return state.scrollbarMode == "smart"
        case .scrollbarsShown: return state.scrollbarMode == "shown"
        case .scrollbarsHidden: return state.scrollbarMode == "hidden"
        case .imageBounds: return state.showImageBounds
        case .fitContentArea: return state.showFitContentArea
        case .documentColorsOff: return state.documentColors == "off"
        case .documentColorsSmart: return state.documentColors == "smart"
        case .documentColorsLegacy: return state.documentColors == "legacy"
        case .preserveImages: return state.preservePDFImages
        case .engineeringOff: return state.engineeringEnhance == "off"
        case .engineeringAuto: return state.engineeringEnhance == "auto"
        case .engineeringOn: return state.engineeringEnhance == "on"
        case .pageGrid: return state.showPageGrid
        case .transparencyGrid: return state.showTransparencyGrid
        case .invertColors: return state.invertColors
        case .grayscale: return state.grayscale
        case .toggleInverseSearch: return state.inverseSearchEnabled
        case .autoLayout: return state.automaticLayout
        case .twoPages: return state.spread
        case .coverOnItsOwn: return state.cover
        case .rightToLeft: return state.rtl
        case .fitPageSingle: return state.fitPresetSelected(continuous: false)
        case .fitWidthContinuous: return state.fitPresetSelected(continuous: true)
        case .annotationsVisible: return state.annotationsVisible
        case .highlightFormFields: return state.highlightFormFields
        case .highlightBrush: return state.nativePDFAnnotationTool?.kind == "highlightBrush"
        case .ink: return state.nativePDFAnnotationTool?.kind == "ink"
        case .inkEraser: return state.nativePDFAnnotationTool?.kind == "eraser"
        case .editAnnotations: return state.nativePDFAnnotationTool?.kind == "editMode"
        case .pageBoxes: return state.showPageBoxes
        case .contents: return state.showContents
        case .thumbnails: return state.showThumbnails
        case .bookmarks: return state.showBookmarks
        case .annotations: return state.showAnnotations
        case .toolbar: return state.toolbarVisible
        case .presentation: return state.presentation
        case .matchCase: return state.searchCaseSensitive
        case .wholeWord: return state.searchWholeWord
        case .uniformWidth: return state.uniformPageWidth
        case .trimMargins: return state.trimEmptyMargins
        case .freePan: return state.freePan
        case .showLinks: return state.showLinks
        case .disableLinks: return state.disableLinks
        case .hoverPreview: return state.hoverPreview
        case .keyboardLinks: return state.keyboardLinkFollowing
        case .keyboardSelection: return state.keyboardTextSelection
        case .selectRectangle: return state.rectangularSelection
        case .autoScroll: return state.autoScroll
        case .readingBar: return state.readingBar
        case .readingBarInvert: return state.readingBarInvert
        case .laserPointer: return state.laserPointer
        case .pageInfo: return state.showPageInfo
        case .cursorPosition: return state.cursorPositionUnit != nil
        case .bookmarkSort: return state.bookmarksByName
        default: return nil
        }
    }

    private var requiresPDFEditing: Bool {
        switch self {
        case .highlight, .underline, .strike, .note, .freeText, .ink, .line, .square, .circle, .link,
             .editAnnotation, .deleteAnnotation, .squiggly, .caret, .stamp, .insertImage, .pasteImageAnnotation,
             .polygon, .polyline, .attachment, .replaceAttachment, .redactMark, .inkEraser, .highlightBrush,
             .editAnnotations, .cutAnnotation, .pasteAnnotation: return true
        default: return false
        }
    }

    @MainActor
    func enabled(_ state: ReaderState?) -> Bool {
        if let state, state.nativePDF != nil {
            switch self {
            case .copyAnnotation: return NativePDFClipboard.canCopy(state)
            case .cutAnnotation: return NativePDFClipboard.canCopy(state, cut: true)
            case .pasteAnnotation: return NativePDFClipboard.canPaste(state)
            case .editAnnotation, .deleteAnnotation:
                return state.canEditPDF && state.nativePDFInfo?.permissions.annotate == true && state.nativePDFSelection?.editable == true
            default: break
            }
        }
        if requiresPDFEditing {
            guard let state, state.isPDF, state.canEditPDF else { return false }
            return state.nativePDFInfo?.permissions.annotate == true
        }
        switch self {
        case .print:
            return state?.hasDocument == true &&
                (state?.nativePDF == nil || state?.nativePDFInfo?.permissions.print == true)
        case .contentsSearch: return state?.hasDocument == true && state?.presentation == false
        case .exportPDF:
            return state?.hasDocument == true &&
                (state?.nativePDF == nil || state?.nativePDFInfo?.permissions.copy == true)
        case .pdfEditing: return state?.isPDF == true && (state?.busy == false || state?.pdfEditingEnabled == true)
        case .pdfInfo: return state?.isPDF == true
        case .showLog, .showErrors: return true
        case .bookmarksWindow: return state?.openAuxiliaryWindow != nil
        case .pageGrid, .configurePageGrid, .transparencyGrid, .navigateThumbnail, .imageBounds, .fitContentArea: return state?.isFixed == true
        case .documentColorsOff, .documentColorsSmart, .documentColorsLegacy, .preserveImages, .engineeringOff, .engineeringAuto, .engineeringOn: return state?.isPDF == true
        case .pdfText: return state?.supportsSearch == true
        case .pdfOutline: return state?.isPDF == true || state?.outline.isEmpty == false
        case .inverseSearch: return state?.isPDF == true && state?.inverseSearchEnabled == true
        case .toggleInverseSearch: return state?.isPDF == true
        case .autoLayout, .twoPages, .coverOnItsOwn, .rightToLeft: return state?.isFixed == true
        case .autoContents: return state?.isPDF == true && state?.outlineBusy == false
        case .screenshot, .screenshotHotkey: return state != nil
        case .pasteImage: return state != nil && NSImage.canInit(with: NSPasteboard.general)
        case .saveImage, .cropImage, .resizeImage, .lensPage: return state?.isFixed == true
        case .lensSelection: return state?.isFixed == true && state?.hasSelection == true
        case .embeddedFiles, .annotationsVisible, .highlightFormFields, .pageBoxes: return state?.isPDF == true
        case .generatedHTML: return state?.document.map { ["md", "markdown", "html", "htm", "xhtml"].contains($0.url.pathExtension.lowercased()) } ?? false
        case .searchGoogle, .searchBing, .searchWikipedia, .searchScholar, .translateGoogle, .translateDeepL: return state?.hasTextSelection == true
        case .copySelectionImage, .saveSelection: return state?.isFixed == true && state?.hasSelection == true
        case .printSelection:
            return state?.isFixed == true && state?.hasSelection == true && ReaderMenuCommand.print.enabled(state)
        case .selectRectangle, .uniformWidth, .trimMargins, .freePan, .fitPageSingle, .fitWidthContinuous, .cycleZoom: return state?.isFixed == true
        case .annotations, .squiggly, .caret, .stamp, .insertImage, .pasteImageAnnotation, .polygon, .polyline, .attachment, .replaceAttachment, .redactMark, .inkEraser, .highlightBrush, .editAnnotations, .copyAnnotation, .cutAnnotation, .pasteAnnotation: return state?.isPDF == true
        case .blankBlack, .blankWhite: return state?.presentation == true
        case .toolbar, .setTheme: return state != nil
        case .selectCurrentPage: return state?.supportsSearch == true
        case .open, .fullscreen, .palette: return true
        case .files, .openNoHistory, .home: return state != nil
        case .discard: return state?.modified == true && state?.busy == false
        case .rename, .trash, .trashAndNext: return state?.document?.url.hasDirectoryPath == false && state?.busy == false
        case .restoreTabGroup, .reopenClosed: return state?.createWindow != nil
        case .close, .nextTab, .previousTab, .nextTabSmart, .previousTabSmart, .moveTabLeft, .moveTabRight, .closeOtherTabs, .closeLeftTabs, .closeRightTabs, .closeAllTabs, .saveTabGroup, .tabColor: return state?.window != nil
        case .save: return state?.canSave == true
        case .saveCopy: return state?.canSaveCopy == true
        case .reload: return state?.hasDocument == true && state?.busy == false
        case .find: return state?.supportsSearch == true
        case .goToPage: return state?.hasDocument == true && (state?.count ?? 0) > 0
        case .findNext, .findPrevious, .matchCase, .wholeWord: return state?.supportsSearch == true
        case .findSelectionNext, .findSelectionPrevious: return state?.supportsSearch == true && state?.hasTextSelection == true
        case .firstPage, .lastPage, .scrollUp, .scrollDown, .scrollLeft, .scrollRight, .pageUp, .pageDown, .halfPageUp, .halfPageDown:
            return state?.hasDocument == true && (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable != true
        case .previous: return state?.canGoBackward == true
        case .next: return state?.canGoForward == true
        case .back: return state?.canNavigateBack == true
        case .forward: return state?.canNavigateForward == true
        case .paged, .continuous: return state?.supportsPagination == true
        case .zoomToSelection: return state?.canZoomToSelection == true
        case .actual, .fitPage, .fitWidth, .fitHeight, .fitOrientation, .shrinkToFit, .fitContent, .fitVisible, .rotateLeft, .rotateRight, .thumbnails, .presentation:
            return state?.isFixed == true
        case .highlight, .underline, .strike, .note, .freeText, .ink, .line, .square, .circle, .link, .editAnnotation, .deleteAnnotation,
             .pdfExtract, .pdfDelete, .pdfMerge, .pdfEncrypt, .pdfDecrypt, .pdfFlatten, .pdfCompress, .pdfDecompress, .pdfBake, .pdfRedact, .pdfSign, .pdfSignatures, .pdfXMP, .pdfAttachments, .pdfImages: return state?.isPDF == true
        case .copyImage: return state?.isFixed == true
        case .copy:
            return state?.isFixed == true || state?.supportsSearch == true || (NSApp.keyWindow?.firstResponder is NSTextView)
        case .selectAll:
            return state?.supportsSearch == true || (NSApp.keyWindow?.firstResponder is NSTextView)
        case .speak, .speakFromTop, .speakFromCursor: return state?.supportsSearch == true
        case .speakSelection: return state?.supportsSearch == true && state?.hasTextSelection == true
        case .pauseSpeaking: return state?.speechRequested == true && state?.speechPaused == false
        case .continueSpeaking: return state?.speechRequested == true && state?.speechPaused == true
        case .stopSpeaking: return state?.speechRequested == true
        default: return state?.hasDocument == true
        }
    }

    @MainActor
    func run(_ state: ReaderState) {
        guard enabled(state) else { return }
        switch self {
        case .pdfEditing: state.setPDFEditingEnabled(!state.pdfEditingEnabled)
        case .setTheme:
            let alert = NSAlert(); alert.messageText = L("Choose Theme…")
            let picker = NSPopUpButton(); picker.addItems(withTitles: ReaderTheme.all.map { L($0.name) })
            picker.selectItem(at: ReaderTheme.all.firstIndex { $0.id == state.theme } ?? 0)
            alert.accessoryView = picker; alert.addButton(withTitle: L("Apply")); alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { state.setTheme(ReaderTheme.all[picker.indexOfSelectedItem].id) }
        case .print: state.printDocument()
        case .screenshotHotkey: ScreenshotHotkey.configure(state)
        case .imageBounds: state.showImageBounds.toggle()
        case .fitContentArea: state.showFitContentArea.toggle()
        case .showLog: ReaderHelp.showLog()
        case .showErrors: ReaderHelp.showErrors()
        case .bookmarksWindow: state.openAuxiliaryWindow?("bookmarks")
        case .speakFromTop: state.send(.readAloudFromTop)
        case .speakFromCursor: state.send(.readAloudFromCursor)
        case .speakSelection: state.send(.readAloudSelection)
        case .cycleFocus: state.focusCycle &+= 1
        case .navigateThumbnail: state.paletteMode = "& "; state.showPalette = true
        case .documentColorsOff: state.documentColors = "off"
        case .documentColorsSmart: state.documentColors = "smart"
        case .documentColorsLegacy: state.documentColors = "legacy"
        case .customDocumentColors: state.configureDocumentColors()
        case .preserveImages: state.preservePDFImages.toggle()
        case .engineeringOff: state.engineeringEnhance = "off"
        case .engineeringAuto: state.engineeringEnhance = "auto"
        case .engineeringOn: state.engineeringEnhance = "on"
        case .pageGrid: state.showPageGrid.toggle()
        case .configurePageGrid: state.configurePageGrid()
        case .transparencyGrid: state.showTransparencyGrid.toggle()
        case .invertColors: state.invertColors.toggle()
        case .grayscale: state.grayscale.toggle()
        case .toggleLightDark: state.toggleLightDarkTheme()
        case .inverseSearch: state.inverseSearchAtCurrentPosition()
        case .toggleInverseSearch: state.inverseSearchEnabled.toggle()
        case .autoLayout: state.toggleAutomaticLayout()
        case .autoContents: state.generateContents()
        case .saveImage: ReaderImages.edit(state, mode: .save)
        case .cropImage: ReaderImages.edit(state, mode: .crop)
        case .resizeImage: ReaderImages.edit(state, mode: .resize)
        case .pasteImage: ReaderImages.openClipboard(state)
        case .screenshot: ReaderImages.capture(state)
        case .lensPage: ReaderImages.searchPageWithLens(state)
        case .lensSelection: state.send(.searchSelectionWithLens)
        case .saveFormatDefaults: state.saveFormatDefaults()
        case .clearFormatDefaults: state.saveFormatDefaults(clear: true)
        case .embeddedFiles: state.showAttachments()
        case .generatedHTML: state.showGeneratedHTML()
        case .annotationsVisible: state.annotationsVisible.toggle()
        case .highlightFormFields: state.highlightFormFields.toggle()
        case .pageBoxes: state.showPageBoxes.toggle()
        case .selectCurrentPage: state.send(.selectCurrentPage)
        case .copySelectionImage: state.send(.copySelectionImage)
        case .saveSelection: state.send(.saveSelection)
        case .printSelection: state.send(.printSelection)
        case .selectRectangle: state.rectangularSelection.toggle()
        case .tocExpand: state.expandContents(to: .max)
        case .tocCollapse: state.expandContents(to: 1)
        case .tocLevel2: state.expandContents(to: 2)
        case .tocLevel3: state.expandContents(to: 3)
        case .tocCurrent: state.revealCurrentContents()
        case .tocSiblings: state.collapseContentsSiblings()
        case .bookmarkToggle: state.toggleBookmark()
        case .bookmarkNext: state.moveBookmark(1)
        case .bookmarkPrevious: state.moveBookmark(-1)
        case .bookmarkSort: state.bookmarksByName.toggle()
        case .copyLocation: state.copyLocation()
        case .fitPageSingle: state.toggleFitPreset(continuous: false)
        case .fitWidthContinuous: state.toggleFitPreset(continuous: true)
        case .cycleZoom: state.cycleZoom()
        case .uniformWidth: state.uniformPageWidth.toggle()
        case .trimMargins: state.trimEmptyMargins.toggle()
        case .freePan: state.freePan.toggle()
        case .showLinks: state.showLinks.toggle()
        case .disableLinks: state.disableLinks.toggle()
        case .hoverPreview: state.hoverPreview.toggle()
        case .keyboardLinks: state.keyboardLinkFollowing.toggle()
        case .keyboardSelection: state.keyboardTextSelection.toggle()
        case .autoScroll: state.setAutoScroll(!state.autoScroll)
        case .scrollFaster: state.changeAutoScrollSpeed(1.5)
        case .scrollSlower: state.changeAutoScrollSpeed(1 / 1.5)
        case .readingBar: state.readingBar.toggle()
        case .readingBarInvert: state.readingBarInvert.toggle(); state.readingBar = true
        case .readingBarLarger: state.readingBarHeight = min(300, state.readingBarHeight + 12); state.readingBar = true
        case .readingBarSmaller: state.readingBarHeight = max(12, state.readingBarHeight - 12); state.readingBar = true
        case .laserPointer: state.laserPointer.toggle()
        case .blankBlack: state.presentationBlank = state.presentationBlank == "black" ? nil : "black"
        case .blankWhite: state.presentationBlank = state.presentationBlank == "white" ? nil : "white"
        case .toolbar: state.toolbarVisible.toggle()
        case .pageInfo: state.showPageInfo.toggle()
        case .cursorPosition: state.toggleCursorPosition()
        case .annotations: state.showAnnotations.toggle()
        case .searchGoogle: state.searchSelection("google")
        case .searchBing: state.searchSelection("bing")
        case .searchWikipedia: state.searchSelection("wikipedia")
        case .searchScholar: state.searchSelection("scholar")
        case .translateGoogle: state.translateSelection("google")
        case .translateDeepL: state.translateSelection("deepl")
        case .squiggly: state.send(.annotate("squiggly"))
        case .caret: state.send(.annotate("caret"))
        case .stamp: state.send(.annotate("stamp"))
        case .insertImage: state.send(.annotate("image"))
        case .pasteImageAnnotation: state.send(.annotate("pasteImage"))
        case .polygon: state.send(.annotate("polygon"))
        case .polyline: state.send(.annotate("polyline"))
        case .attachment: state.send(.annotate("attachment"))
        case .replaceAttachment: state.send(.annotate("replaceAttachment"))
        case .redactMark: state.send(.annotate("redact"))
        case .inkEraser: state.send(.annotate("eraser"))
        case .highlightBrush: state.send(.annotate("highlightBrush"))
        case .editAnnotations: state.send(.annotate("editMode"))
        case .copyAnnotation: state.send(.annotate("copy"))
        case .cutAnnotation: state.send(.annotate("cut"))
        case .pasteAnnotation: state.send(.annotate("paste"))
        case .open: break // Window creation belongs to the SwiftUI scene.
        case .files: state.showFiles.toggle()
        case .openNoHistory:
            chooseDocuments { urls in
                ReaderWindows.open(Array(urls.prefix(1)), in: state, recordsHistory: false) { state.createWindow?($0) }
            }
        case .discard: state.discardChanges()
        case .rename: state.renameFile()
        case .trash: state.trashFile(openNext: false)
        case .trashAndNext: state.trashFile(openNext: true)
        case .home: state.close()
        case .save: state.savePDF()
        case .saveCopy: state.saveCopy()
        case .exportPDF: state.send(.exportPDF)
        case .reload: state.reload()
        case .properties: state.showProperties()
        case .pdfInfo: state.showPDFResourceInformation()
        case .closeAndQuit:
            guard let window = state.window else { return }
            if ReaderWindows.states.filter({ $0.window != nil }).count == 1 { NSApp.terminate(nil) }
            else { window.performClose(nil) }
        case .scrollbarsSmart: state.scrollbarMode = "smart"; if state.isBrowser { state.send(.style) }
        case .scrollbarsShown: state.scrollbarMode = "shown"; if state.isBrowser { state.send(.style) }
        case .scrollbarsHidden: state.scrollbarMode = "hidden"; if state.isBrowser { state.send(.style) }
        case .copyPath: state.copyPath()
        case .close: state.window?.performClose(nil)
        case .duplicateTab: state.duplicate(inTab: true)
        case .duplicateWindow: state.duplicate(inTab: false)
        case .nextTab: state.selectTab(1)
        case .previousTab: state.selectTab(-1)
        case .nextTabSmart: state.selectTab(1, smart: true)
        case .previousTabSmart: state.selectTab(-1, smart: true)
        case .moveTabLeft: state.moveTab(-1)
        case .moveTabRight: state.moveTab(1)
        case .closeOtherTabs: state.closeTabs("other")
        case .closeLeftTabs: state.closeTabs("left")
        case .closeRightTabs: state.closeTabs("right")
        case .closeAllTabs: state.closeTabs("all")
        case .saveTabGroup: state.saveTabGroup()
        case .restoreTabGroup: state.restoreTabGroup()
        case .tabColor: state.setTabColor()
        case .reopenClosed: state.reopenClosed()
        case .shareEmail: state.shareByEmail()
        case .openWith: state.openWithApplication()
        case .contents: state.showContents.toggle()
        case .contentsSearch: state.showContentsSearch()
        case .thumbnails: state.showThumbnails.toggle()
        case .bookmarks: state.showBookmarks.toggle()
        case .fullscreen: state.window?.toggleFullScreen(nil)
        case .presentation:
            if state.deferForNativePDFForm({ [weak state] in if let state { self.run(state) } }) { return }
            state.presentation.toggle()
            if let window = state.window, window.styleMask.contains(.fullScreen) != state.presentation { window.toggleFullScreen(nil) }
        case .palette: state.paletteMode = "> "; state.showPalette.toggle()
        case .ai: state.showAI.toggle()
        case .find: state.showFindPanel()
        case .goToPage: state.requestPageInput()
        case .findNext: state.findNext()
        case .findPrevious: state.findNext(backwards: true)
        case .findSelectionNext: state.findNext(fromSelection: true)
        case .findSelectionPrevious: state.findNext(backwards: true, fromSelection: true)
        case .matchCase: state.searchCaseSensitive.toggle()
        case .wholeWord: state.searchWholeWord.toggle()
        case .firstPage: state.firstPage()
        case .lastPage: state.lastPage()
        case .scrollUp: state.scroll(.up)
        case .scrollDown: state.scroll(.down)
        case .scrollLeft: state.scroll(.left)
        case .scrollRight: state.scroll(.right)
        case .pageUp: state.scroll(.up, amount: .page)
        case .pageDown: state.scroll(.down, amount: .page)
        case .halfPageUp: state.scroll(.up, amount: .halfPage)
        case .halfPageDown: state.scroll(.down, amount: .halfPage)
        case .previous: state.turn(-1)
        case .next: state.turn(1)
        case .back: state.navigateHistory(-1)
        case .forward: state.navigateHistory(1)
        case .previousFile: state.sibling(-1)
        case .nextFile: state.sibling(1)
        case .zoomIn: state.zoomStep(1)
        case .zoomOut: state.zoomStep(-1)
        case .actual: state.setActualSize()
        case .fitPage: state.setFit("page")
        case .fitWidth: state.setFit("width")
        case .fitHeight: state.setFit("height")
        case .fitOrientation: state.setFit("orientation")
        case .shrinkToFit: state.setFit("shrink")
        case .fitContent: state.setFit("content")
        case .fitVisible: state.setFit("visible")
        case .customZoom: state.customZoom()
        case .zoomToSelection: state.zoomToSelection()
        case .paged: state.setFlow("paged")
        case .continuous: state.setFlow("continuous")
        case .twoPages, .coverOnItsOwn, .rightToLeft:
            if state.deferForNativePDFForm({ [weak state] in if let state { self.run(state) } }) { return }
            state.automaticLayout = false
            if self == .twoPages { state.spread.toggle() }
            else if self == .coverOnItsOwn { state.cover.toggle() }
            else { state.rtl.toggle() }
        case .bookmark: state.bookmark()
        case .rotateLeft: state.rotate(-90)
        case .rotateRight: state.rotate(90)
        case .copy:
            if !NSApp.sendAction(Selector("copy:"), to: nil, from: nil) { state.send(.copy) }
        case .copyImage: state.send(.copyImage)
        case .selectAll:
            if !NSApp.sendAction(Selector("selectAll:"), to: nil, from: nil) { state.send(.selectAll) }
        case .speak: state.send(.readAloud)
        case .pauseSpeaking: state.pauseReading()
        case .continueSpeaking: state.continueReading()
        case .stopSpeaking: state.stopReading()
        case .pdfExtract: state.performPDFTool(.extract)
        case .pdfDelete: state.performPDFTool(.delete)
        case .pdfMerge: state.performPDFTool(.merge)
        case .pdfEncrypt: state.performPDFTool(.encrypt)
        case .pdfDecrypt: state.performPDFTool(.decrypt)
        case .pdfFlatten: state.performPDFTool(.flatten)
        case .pdfCompress: state.performPDFTool(.compress)
        case .pdfDecompress: state.performPDFTool(.decompress)
        case .pdfRedact: state.performPDFTool(.redact)
        case .pdfBake: state.performPDFTool(.bake)
        case .pdfSign: state.performPDFTool(.sign)
        case .pdfSignatures: state.showSignatures()
        case .pdfText: state.exportDocumentText()
        case .pdfOutline: state.exportDocumentOutline()
        case .pdfXMP: state.performPDFTool(.xmp)
        case .pdfAttachments: state.performPDFTool(.attachments)
        case .pdfImages: state.performPDFTool(.render)
        case .highlight, .underline, .strike, .note, .freeText, .ink, .line, .square, .circle, .link: state.send(.annotate(rawValue))
        case .editAnnotation: state.send(.annotate("edit"))
        case .deleteAnnotation: state.send(.deleteAnnotation)
        }
    }
}

func readerShortcutBindings(_ string: String) -> [String] {
    guard !string.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    return string.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
}

func readerShortcut(_ string: String) -> KeyboardShortcut? {
    let parts = string.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard let last = parts.last, !last.isEmpty else { return nil }
    var modifiers: EventModifiers = []
    for part in parts.dropLast() {
        switch part {
        case "cmd": modifiers.insert(.command)
        case "shift": modifiers.insert(.shift)
        case "alt": modifiers.insert(.option)
        case "ctrl": modifiers.insert(.control)
        default: return nil
        }
    }
    let key: KeyEquivalent
    switch last {
    case "left": key = .leftArrow
    case "right": key = .rightArrow
    case "up": key = .upArrow
    case "down": key = .downArrow
    case "space": key = .space
    case "return": key = .return
    case "escape": key = .escape
    case "tab": key = .tab
    case "home": key = .home
    case "end": key = .end
    case "pageup": key = .pageUp
    case "pagedown": key = .pageDown
    case "delete": key = .delete
    case "forwarddelete": key = .deleteForward
    default:
        if last.hasPrefix("f"), let number = Int(last.dropFirst()), (1...24).contains(number), let scalar = UnicodeScalar(0xF704 + number - 1) {
            key = KeyEquivalent(Character(scalar))
            return KeyboardShortcut(key, modifiers: modifiers)
        }
        guard last.count == 1, let character = last.first else { return nil }
        key = KeyEquivalent(character)
    }
    return KeyboardShortcut(key, modifiers: modifiers)
}

struct ReaderCommandButton: View {
    let command: ReaderMenuCommand
    @FocusedObject private var state: ReaderState?
    var open: () -> Void = {}
    @AppStorage("shortcuts") private var shortcuts = "{}"
    @AppStorage("language") private var language = "system"

    var body: some View {
        let _ = language
        let overrides = (try? JSONDecoder().decode([String: String].self, from: Data(shortcuts.utf8))) ?? [:]
        Group {
            if let state, command.checked(state) != nil {
                Toggle(command.title, isOn: Binding(get: { command.checked(state) ?? false }, set: { value in
                    if value != command.checked(state) { command.run(state) }
                }))
            } else {
                Button(command == .close ? L("Close") : command.title) {
                    if command == .open { open() }
                    else if command == .close {
                        // About, Settings and Find have no focused ReaderState.
                        // AppKit closes the key window through its existing delegate.
                        NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
                    }
                    else if let state { command.run(state) }
                    else if command == .copy || command == .selectAll {
                        NSApp.sendAction(Selector(command == .copy ? "copy:" : "selectAll:"), to: nil, from: nil)
                    }
                }
            }
        }
        .keyboardShortcut(readerShortcut(readerShortcutBindings(overrides[command.id] ?? command.defaultShortcut).first ?? ""))
        .disabled(command == .close
            ? NSApp.keyWindow?.standardWindowButton(.closeButton)?.isEnabled != true
            : !command.enabled(state))
    }
}

@MainActor
struct CommandPalette: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    let open: () -> Void
    @State private var query = "> "
    @State private var selected: String?
    @State private var nativeAnnotations: [(page: Int, annotation: PDFAnnotationSnapshot)] = []
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id: String
        let title: String
        var detail = ""
        var enabled = true
        var page: Int?
        let action: () -> Void
    }
    // Prefixes are the same as Sumatra's palette. Rows are projections of the
    // existing owners, not a second history, tab or annotation model.
    private var items: [Item] {
        let prefix = query.first ?? ">"
        let recognized = ">@#$%&*=".contains(prefix)
        let filter = (recognized ? String(query.dropFirst()) : query).trimmingCharacters(in: .whitespaces)
        var items: [Item] = []
        switch recognized ? prefix : ">" {
        case "@":
            items = ReaderWindows.states.enumerated().map { index, reader in
                Item(id: "tab:\(reader.window?.windowNumber ?? index)", title: reader.document?.url.lastPathComponent ?? L("Home"), detail: reader.positionLabel) { reader.window?.makeKeyAndOrderFront(nil) }
            }
        case "#":
            items = ReaderFiles.recent.map { url in Item(id: "file:" + url.path, title: url.lastPathComponent, detail: url.deletingLastPathComponent().path) { state.open(url) } }
        case "$":
            items = state.bookmarks.map { bookmark in Item(id: "bookmark:" + bookmark.id.uuidString, title: bookmark.title, detail: URL(fileURLWithPath: bookmark.path).lastPathComponent) { state.openBookmark(bookmark) } }
        case "%":
            items = state.outline.enumerated().map { index, entry in Item(id: "toc:\(index)", title: entry.title, enabled: !entry.target.isEmpty) { state.navigate(.href(entry.target)) } }
        case "&":
            items = (0..<state.count).map { page in Item(id: "page:\(page)", title: String(format: L("Page %d"), page + 1), page: page) { state.navigate(.page(page)) } }
        case "*":
            if state.nativePDF != nil {
                items = nativeAnnotations.map { row in
                    let annotation = row.annotation
                    return Item(id: "annotation:\(row.page):\(annotation.id)", title: annotation.contents.isEmpty ? L(annotation.type) : annotation.contents,
                        detail: String(format: L("Page %d"), row.page + 1) + " · " + annotation.author) {
                        state.send(.selectAnnotation(page: row.page, index: Int(annotation.id)))
                    }
                }
            }
        case "=":
            items = ReaderPreferences.booleans.sorted().map { key in
                Item(id: "setting:" + key, title: key, detail: ReaderPreferences.boolean(for: key) ? L("On") : L("Off")) {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: [key: !ReaderPreferences.boolean(for: key)])
                        try ReaderPreferences.apply(data)
                    } catch { state.error = error.localizedDescription }
                }
            }
        default:
            items = ReaderMenuCommand.allCases.map { command in Item(id: command.id, title: command.title, detail: command.defaultShortcut, enabled: command.enabled(state)) { if command == .open { open() } else { command.run(state) } } }
            if let commands = try? ExternalReaderCommand.read(UserDefaults.standard.string(forKey: "externalCommands") ?? "[]") {
                items += commands.map { command in Item(id: "external:" + command.name, title: command.name, enabled: command.enabled(state)) { command.run(state) } }
            }
            if let commands = try? ReaderConfiguredCommand.read(UserDefaults.standard.string(forKey: "customCommands") ?? "[]") {
                items += commands.map { command in Item(id: "custom:" + command.name, title: command.name, detail: command.shortcut ?? "", enabled: command.enabled(state)) { command.run(state) } }
            }
        }
        let recent = UserDefaults.standard.stringArray(forKey: "paletteMRU") ?? []
        return items.filter { filter.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(filter) }.sorted {
            (recent.firstIndex(of: $0.id) ?? Int.max) < (recent.firstIndex(of: $1.id) ?? Int.max)
        }
    }

    private func activate(_ item: Item) {
        guard item.enabled else { return }
        var recent = UserDefaults.standard.stringArray(forKey: "paletteMRU") ?? []
        recent.removeAll { $0 == item.id }; recent.insert(item.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(50)), forKey: "paletteMRU")
        dismiss(); item.action()
    }

    var body: some View {
        let _ = language
        VStack {
            TextField(L("Search"), text: $query).textFieldStyle(.roundedBorder)
                .onSubmit { if let item = items.first(where: { $0.id == selected }) ?? items.first { activate(item) } }
                .onChange(of: query) { _ in selected = nil }
            HStack {
                ForEach(["> Commands", "@ Tabs", "# History", "$ Bookmarks", "% Contents", "& Pages", "* Annotations", "= Settings"], id: \.self) { mode in
                    Button(L(mode)) { query = String(mode.prefix(1)) + " "; selected = nil }.buttonStyle(.borderless)
                }
            }.font(.caption)
            List(items, selection: $selected) { item in
                Button { activate(item) } label: {
                    HStack {
                        if let page = item.page { ReaderPagePreview(state: state, index: page).frame(width: 56, height: 70) }
                        Text(item.title).lineLimit(2); Spacer(); Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.disabled(!item.enabled).buttonStyle(.plain).tag(item.id)
            }
            Button(L("Close")) { dismiss() }.keyboardShortcut(.escape, modifiers: [])
        }
        .onMoveCommand { direction in
            guard direction == .up || direction == .down, !items.isEmpty else { return }
            let index = selected.flatMap { selection in items.firstIndex { $0.id == selection } } ?? -1
            selected = items[min(items.count - 1, max(0, index + (direction == .up ? -1 : 1)))].id
        }
        .padding().frame(width: 720, height: 460)
        .onAppear { query = state.paletteMode; state.paletteContentsVisible = query.first == "%" }
        .onChange(of: query.first) { state.paletteContentsVisible = $0 == "%" }
        .onDisappear { state.paletteContentsVisible = false }
        .task(id: query.first == "*" ? "\(state.document?.id.uuidString ?? ""):\(state.editRevision)" : "") {
            nativeAnnotations = []
            guard query.first == "*", let pages = state.nativePDF else { return }
            let documentID = state.document?.id, revision = state.editRevision
            do {
                var rows: [(page: Int, annotation: PDFAnnotationSnapshot)] = []
                let count = await pages.count
                for page in 0..<count {
                    try Task.checkCancellation()
                    let annotations = try await pages.pdfAnnotations(page)
                    rows += annotations.filter { !["Widget", "Link", "Popup"].contains($0.type) }.map { (page, $0) }
                }
                guard !Task.isCancelled, state.document?.id == documentID, state.editRevision == revision else { return }
                nativeAnnotations = rows
            } catch { if !Task.isCancelled, state.document?.id == documentID { state.error = error.localizedDescription } }
        }
    }
}
#endif
