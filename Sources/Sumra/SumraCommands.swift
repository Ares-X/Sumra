#if os(macOS)
import SwiftUI

struct SumraCommands: Commands {
    let application: ReaderApplicationDelegate
    @FocusedObject private var state: ReaderState?
    @AppStorage("language") private var language = "system"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = language
        let _ = application.installWindowOpener { [openWindow] in openWindow(id: "reader", value: $0) }
        applicationCommands
        readingCommands
        documentTools
    }

    @CommandsBuilder
    private var applicationCommands: some Commands {
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
            buttons([.save, .saveCopy, .exportPDF, .reload, .discard, .properties, .copyPath, .rename, .relocate, .trash, .trashAndNext, .shareEmail, .openWith, .home, .close, .closeAndQuit])
        }
        CommandGroup(replacing: .printItem) {
            ReaderCommandButton(command: .print)
        }
        CommandGroup(after: .pasteboard) {
            ReaderCommandButton(command: .copyImage)
            buttons([.selectCurrentPage, .selectRectangle, .copySelectionImage, .saveSelection, .printSelection, .copyLocation, .keyboardSelection])
            Menu(L("Find")) {
                buttons([.find, .findNext, .findPrevious, .findSelectionNext, .findSelectionPrevious])
                Divider()
                buttons([.matchCase, .wholeWord])
            }
            Button(L("Translate Selection…")) { state?.translateSelection() }
                .disabled(state?.hasTextSelection != true)
            Menu(L("Search Selection")) { buttons([.searchGoogle, .searchBing, .searchWikipedia, .searchScholar, .translateGoogle, .translateDeepL]) }
        }
    }

    @CommandsBuilder
    private var readingCommands: some Commands {
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
                buttons([.setTheme, .toggleLightDark, .documentColorsOff, .documentColorsSmart, .documentColorsLegacy, .customDocumentColors, .invertColors, .grayscale, .preserveImages, .enhanceScans])
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
