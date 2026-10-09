#if os(macOS)
import SwiftUI

// MuPDF owns document history; native inputs keep AppKit's undo manager.
// Publish only menu availability so focus changes also update SwiftUI commands.
@MainActor
final class ReaderUndoCommands: ObservableObject {
    @Published private(set) var isEditingText = false
    @Published private var nativeCanUndo = false
    @Published private var nativeCanRedo = false

    private var pdfState: ReaderState? {
        guard let window = NSApp.keyWindow,
              (window.firstResponder as? NSTextView)?.isEditable != true else { return nil }
        return ReaderWindows.states.first { $0.window === window && $0.nativePDF != nil }
    }

    func update() {
        let responder = NSApp.keyWindow?.firstResponder
        let editingText = (responder as? NSTextView)?.isEditable == true
        let manager = responder?.undoManager
        let undo = manager?.canUndo == true, redo = manager?.canRedo == true
        if isEditingText != editingText { isEditingText = editingText }
        if nativeCanUndo != undo { nativeCanUndo = undo }
        if nativeCanRedo != redo { nativeCanRedo = redo }
    }

    func enabled(redo: Bool, state: ReaderState?) -> Bool {
        if !isEditingText, let state, state.nativePDF != nil {
            guard state.canEditPDF, let info = state.nativePDFInfo else { return false }
            return redo ? info.undoPosition < info.undoSteps : info.undoPosition > 0
        }
        return redo ? nativeCanRedo : nativeCanUndo
    }

    func perform(redo: Bool) {
        guard let state = pdfState else {
            NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil)
            update()
            return
        }
        let documentID = state.document?.id
        Task {
            guard state.document?.id == documentID else { return }
            do { try await state.changeNativePDFHistory(redo: redo) }
            catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
        }
    }
}

struct SumraCommands: Commands {
    @ObservedObject var undoCommands: ReaderUndoCommands
    @FocusedObject private var state: ReaderState?
    @AppStorage("language") private var language = "system"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = language
        CommandGroup(replacing: .help) {
            Button(L("Sumra Help")) { ReaderHelp.showManual() }
            Button(L("Keyboard Shortcuts")) { ReaderHelp.showShortcuts() }
            Button(L("Application Log")) { ReaderHelp.showLog() }
            Button(L("Errors in This Session")) { ReaderHelp.showErrors() }
            Divider()
            Button(L("Visit Website")) { NSWorkspace.shared.open(ReaderHelp.website) }
            Button(L("Contribute Translation")) { ReaderHelp.contributeTranslation() }
            Button(L("Check for Updates…")) { ReaderHelp.checkForUpdates() }
        }
        CommandGroup(after: .newItem) {
            ReaderCommandButton(command: .open, open: openFiles)
            buttons([.files, .openNoHistory, .reopenClosed])
            ExternalCommandMenu()
            ReaderConfiguredCommandMenu()
            Menu(L("Open Recent")) {
                ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { open(url) }
                }
                Divider()
                Button(L("Clear Menu")) { ReaderFiles.clearHistory() }
            }
        }
        CommandGroup(replacing: .saveItem) {
            buttons([.save, .saveCopy, .exportPDF, .reload, .discard, .properties, .copyPath, .rename, .trash, .trashAndNext, .shareEmail, .openWith, .home, .close, .closeAndQuit])
        }
        CommandGroup(replacing: .printItem) {
            ReaderCommandButton(command: .print)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(L("Undo")) { undoCommands.perform(redo: false) }
                .keyboardShortcut("z").disabled(!undoCommands.enabled(redo: false, state: state))
            Button(L("Redo")) { undoCommands.perform(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!undoCommands.enabled(redo: true, state: state))
        }
        CommandGroup(replacing: .pasteboard) {
            Button(L("Cut")) { NSApp.sendAction(Selector(("cut:")), to: nil, from: nil) }.keyboardShortcut("x")
            ReaderCommandButton(command: .copy)
            ReaderCommandButton(command: .copyImage)
            Button(L("Paste")) { NSApp.sendAction(Selector(("paste:")), to: nil, from: nil) }.keyboardShortcut("v")
            ReaderCommandButton(command: .selectAll)
            buttons([.selectCurrentPage, .selectRectangle, .copySelectionImage, .saveSelection, .printSelection, .copyLocation, .keyboardSelection])
        }
        CommandGroup(after: .pasteboard) {
            Menu(L("Find")) {
                buttons([.find, .findNext, .findPrevious, .findSelectionNext, .findSelectionPrevious])
                Divider()
                buttons([.matchCase, .wholeWord])
            }
            Button(L("Translate Selection…")) { state?.translateSelection() }
                .disabled(state?.hasTextSelection != true)
            Menu(L("Search Selection")) { buttons([.searchGoogle, .searchBing, .searchWikipedia, .searchScholar, .translateGoogle, .translateDeepL]) }
        }
        CommandGroup(after: .toolbar) {
            buttons([.contents, .thumbnails, .navigateThumbnail, .bookmarks, .bookmarksWindow, .annotations, .toolbar, .fullscreen, .presentation, .palette, .ai])
            Menu(L("Contents")) {
                buttons([.contentsSearch])
                Divider()
                buttons([.tocExpand, .tocCollapse, .tocLevel2, .tocLevel3, .tocCurrent, .tocSiblings, .autoContents])
            }
            Menu(L("Page Layout")) {
                buttons([.paged, .continuous, .autoLayout, .fitPageSingle, .fitWidthContinuous])
                Divider()
                buttons([.twoPages, .coverOnItsOwn, .rightToLeft])
                Divider()
                buttons([.uniformWidth, .trimMargins, .freePan, .rotateLeft, .rotateRight])
                if state?.document?.markdownRenderer != nil {
                    Divider()
                    Menu(L("Markdown Renderer")) {
                        markdownRendererOption(.automatic, title: "Automatic")
                        markdownRendererOption(.paged, title: "Paged Markdown")
                        markdownRendererOption(.compatible, title: "Compatibility Mode")
                    }
                }
            }
            Menu(L("Zoom")) {
                buttons([.zoomIn, .zoomOut, .actual, .customZoom, .cycleZoom])
                Divider()
                buttons([.fitPage, .fitWidth, .fitHeight, .fitOrientation, .shrinkToFit, .fitContent, .fitVisible, .zoomToSelection])
            }
            Menu(L("Document Colors")) {
                buttons([.setTheme, .toggleLightDark, .documentColorsOff, .documentColorsSmart, .documentColorsLegacy, .customDocumentColors, .invertColors, .grayscale, .preserveImages])
                Divider()
                buttons([.engineeringOff, .engineeringAuto, .engineeringOn])
            }
            Menu(L("Reading Guides")) { buttons([.readingBar, .readingBarInvert, .readingBarLarger, .readingBarSmaller, .laserPointer, .pageInfo, .cursorPosition, .pageBoxes, .fitContentArea, .imageBounds, .pageGrid, .configurePageGrid, .transparencyGrid, .blankBlack, .blankWhite]) }
            Menu(L("Links")) { buttons([.showLinks, .disableLinks, .hoverPreview, .keyboardLinks]) }
            Menu(L("Format Defaults")) { buttons([.saveFormatDefaults, .clearFormatDefaults]) }
        }
        CommandMenu(L("Tabs")) {
            buttons([.duplicateTab, .duplicateWindow, .nextTab, .previousTab, .nextTabSmart, .previousTabSmart, .moveTabLeft, .moveTabRight])
            Divider()
            buttons([.closeOtherTabs, .closeLeftTabs, .closeRightTabs, .closeAllTabs, .reopenClosed])
            Divider()
            buttons([.saveTabGroup, .restoreTabGroup, .tabColor])
        }
        CommandMenu(L("Navigation")) {
            buttons([.previous, .next, .firstPage, .lastPage, .goToPage])
            Divider()
            buttons([.back, .forward, .previousFile, .nextFile])
            Divider()
            Menu(L("Scroll")) {
                buttons([.scrollUp, .scrollDown, .scrollLeft, .scrollRight, .pageUp, .pageDown, .halfPageUp, .halfPageDown, .autoScroll, .scrollFaster, .scrollSlower])
                Divider()
                buttons([.scrollbarsSmart, .scrollbarsShown, .scrollbarsHidden])
            }
            buttons([.cycleFocus])
            Menu(L("Bookmarks")) { buttons([.bookmark, .bookmarkToggle, .bookmarkNext, .bookmarkPrevious, .bookmarkSort]) }
            Menu(L("Read Aloud")) { buttons([.speak, .speakFromTop, .speakFromCursor, .speakSelection, .pauseSpeaking, .continueSpeaking, .stopSpeaking]) }
        }
        documentTools
    }

    @CommandsBuilder
    private var documentTools: some Commands {
        CommandMenu(L("Tools")) {
            Menu(L("PDF Tools")) {
                buttons([.embeddedFiles, .generatedHTML, .pdfInfo])
                buttons([.pdfExtract, .pdfDelete, .pdfMerge, .pdfEncrypt, .pdfDecrypt, .pdfFlatten, .pdfCompress, .pdfDecompress, .pdfBake, .pdfRedact, .pdfSign, .pdfSignatures, .pdfText, .pdfOutline, .pdfXMP, .pdfAttachments, .pdfImages])
            }
            Menu(L("Images")) {
                buttons([.saveImage, .cropImage, .resizeImage, .pasteImage, .screenshot, .screenshotHotkey])
                Divider()
                buttons([.lensPage, .lensSelection])
            }
            Menu(L("Annotations")) {
                buttons([.pdfEditing])
                Divider()
                buttons([.annotationsVisible, .highlightFormFields])
                buttons([.highlight, .underline, .strike, .squiggly, .highlightBrush, .note, .freeText, .ink, .inkEraser, .line, .square, .circle, .polygon, .polyline, .caret, .stamp, .link])
                Divider()
                buttons([.insertImage, .pasteImageAnnotation, .attachment, .replaceAttachment, .redactMark, .pdfRedact])
                Divider()
                buttons([.editAnnotations, .editAnnotation, .deleteAnnotation, .copyAnnotation, .cutAnnotation, .pasteAnnotation, .annotations])
            }
            Divider()
            buttons([.inverseSearch, .toggleInverseSearch])
        }
    }

    @ViewBuilder
    private func buttons(_ commands: [ReaderMenuCommand]) -> some View {
        ForEach(commands) { ReaderCommandButton(command: $0) }
    }

    @ViewBuilder
    private func markdownRendererOption(_ renderer: MarkdownRenderer, title: String) -> some View {
        Button { state?.setMarkdownRenderer(renderer) } label: {
            if state?.markdownRendererSelection == renderer {
                Label(L(title), systemImage: "checkmark")
            } else { Text(L(title)) }
        }
    }

    private func open(_ url: URL) {
        ReaderWindows.open([url], in: state) { openWindow(id: "reader", value: $0) }
    }

    private func openFiles() {
        chooseDocuments { urls in
            ReaderWindows.open(urls, in: state) { openWindow(id: "reader", value: $0) }
        }
    }
}
#endif
