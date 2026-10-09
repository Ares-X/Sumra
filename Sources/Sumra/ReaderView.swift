#if os(macOS)
import SwiftUI
import SumraCore

@MainActor
struct ReaderView: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    @AppStorage("findFloating") private var findFloating = false
    @AppStorage("sidebarRight") private var sidebarRight = false
    @FocusState private var sidebarFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let _ = language
        VStack(spacing: 0) {
            if state.showFind && !findFloating && !state.presentation {
                ReaderFindControls(state: state, floating: $findFloating, close: closeFind)
                Divider()
            }

            if state.isPDF && state.pdfEditingEnabled && !state.presentation {
                PDFEditingBar(state: state)
                Divider()
            }

            if state.speechRequested && !state.presentation { SpeechControls(state: state); Divider() }
            mainArea

            if state.document != nil && !state.presentation && (!state.status.isEmpty || state.modified) {
                Divider()
                HStack {
                    Text(state.status).lineLimit(1)
                    Spacer()
                    if state.modified { Text(L("Unsaved Changes")) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .preferredColorScheme(state.theme == "system" ? nil : state.palette.dark ? .dark : .light)
        .onChange(of: colorScheme) { _ in
            if state.theme == "system", state.isText || state.isBrowser || state.reflowable {
                state.send(.style)
            }
        }
        .onChange(of: state.spread) {
            UserDefaults.standard.set($0, forKey: "spread")
        }
        .onChange(of: state.rtl) {
            UserDefaults.standard.set($0, forKey: "rtl")
        }
        .onChange(of: state.cover) { UserDefaults.standard.set($0, forKey: "cover") }
        .toolbar(id: "reader") { toolbar }
        .toolbar(state.presentation || !state.toolbarVisible || !state.hasDocument ? .hidden : .visible, for: .windowToolbar)
        .onChange(of: state.presentation) { if !$0 { state.presentationBlank = nil } }
        .onChange(of: state.focusCycle) { _ in
            if state.presentation { sidebarFocused = false; focusReader(); return }
            let sidebarVisible = state.showContents || state.showBookmarks || state.showThumbnails || state.showAnnotations || (state.showSearchResults && !findFloating)
            if findFloating && state.showFind && state.window?.isKeyWindow == false { focusReader() }
            else if state.findInputField?.currentEditor() != nil { focusReader() }
            else if let tree = state.contentsFocusView, tree.window != nil {
                if tree.window?.firstResponder === tree {
                    if state.showFind { state.showFindPanel() } else { focusReader() }
                } else { tree.window?.makeFirstResponder(tree) }
            }
            else if sidebarFocused { sidebarFocused = false; if state.showFind { state.showFindPanel() } else { focusReader() } }
            else if sidebarVisible { sidebarFocused = true }
            else if state.showFind { state.showFindPanel() }
            else { focusReader() }
        }
        .background(ReaderFindPanel(state: state, isPresented: state.showFind && findFloating && !state.presentation).frame(width: 0, height: 0))
        .sheet(isPresented: $state.showPalette) { CommandPalette(state: state, open: openFiles) }
        .sheet(isPresented: $state.showFiles) { DocumentFileBrowser(state: state, folder: state.document?.url.deletingLastPathComponent(), dismissOnOpen: true).frame(width: 620, height: 460) }
        .contextMenu { contextMenu }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            state.open(first)
            for url in urls.dropFirst() {
                openWindow(id: "reader", value: WindowPayload(path: url.path))
            }
            return true
        }
        .alert(
            L("Unable to complete action"),
            isPresented: Binding(
                get: { state.error != nil },
                set: { if !$0 { state.error = nil } }
            )
        ) {
            Button(L("OK")) { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }

    private func closeFind() {
        state.closeFind(); focusReader()
    }

    private func focusReader() {
        if findFloating { state.window?.makeKeyAndOrderFront(nil) }
        let target = (state.browserView as NSView?) ?? state.readerFocusView
        if let target { state.window?.makeFirstResponder(target) }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some CustomizableToolbarContent {
        // Keep the same item set in every window, including empty/loading
        // windows. AppKit shares customization across this toolbar family.
        ToolbarItem(id: "open", placement: .automatic, showsByDefault: true) {
            Button(action: openFiles) { Image(systemName: "folder") }
                .help(L("Open Document")).accessibilityLabel(L("Open Document"))
        }
        ToolbarItem(id: "contents", placement: .automatic, showsByDefault: true) {
            Button { state.showContents.toggle() } label: { Image(systemName: "sidebar.left") }
                .disabled(!state.hasDocument).help(L("Toggle Contents")).accessibilityLabel(L("Toggle Contents"))
        }
        ToolbarItem(id: "print", placement: .automatic, showsByDefault: false) {
            toolbarButton(.print, symbol: "printer")
        }
        ToolbarItem(id: "history", placement: .automatic, showsByDefault: false) {
            HStack(spacing: 4) {
                toolbarButton(.back, symbol: "arrow.uturn.backward")
                toolbarButton(.forward, symbol: "arrow.uturn.forward")
            }
        }
        ToolbarItem(id: "navigation", placement: .automatic, showsByDefault: true) {
            HStack(spacing: 6) {
                toolbarButton(.previous, symbol: "chevron.left")
                ReaderPageInput(state: state, finished: focusReader)
                    .id(state.document?.id)
                    .frame(width: CGFloat(max(4, state.pageLabel.count, String(state.count).count)) * 9 + 16)
                Text((state.chapterLayout?.chapterCount ?? 0) > 1 ? state.positionLabel : "/ \(state.count > 0 ? String(state.count) : "—")")
                    .monospacedDigit().foregroundStyle(.secondary)
                toolbarButton(.next, symbol: "chevron.right")
            }.accessibilityElement(children: .contain)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        navigationToolbar
        ToolbarItem(id: "fit", placement: .automatic, showsByDefault: false) {
            if state.isFixed {
                HStack(spacing: 4) {
                    fitPresetButton(.fitPageSingle, symbol: "rectangle.portrait")
                    fitPresetButton(.fitWidthContinuous, symbol: "arrow.left.and.right")
                }
            }
        }
        ToolbarItem(id: "zoom", placement: .automatic, showsByDefault: true) {
            HStack(spacing: 4) {
                toolbarButton(.zoomOut, symbol: "minus.magnifyingglass")
                zoomOptions.disabled(!state.hasDocument)
                toolbarButton(.zoomIn, symbol: "plus.magnifyingglass")
            }.accessibilityElement(children: .contain)
        }
        ToolbarItem(id: "layout", placement: .automatic, showsByDefault: true) {
            layoutOptions.disabled(!state.hasDocument)
        }
        ToolbarItem(id: "find", placement: .automatic, showsByDefault: true) {
            Button { state.showFindPanel() } label: { Image(systemName: "magnifyingglass") }
                .disabled(!state.supportsSearch).help(L("Find")).accessibilityLabel(L("Find"))
        }
        ToolbarItem(id: "edit", placement: .automatic, showsByDefault: true) {
            if state.isPDF {
                Button { ReaderMenuCommand.pdfEditing.run(state) } label: {
                    Label(L(state.pdfEditingEnabled ? "Lock Editing" : "Enable Editing"),
                          systemImage: state.pdfEditingEnabled ? "lock.open" : "lock")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(state.pdfEditingEnabled ? Color.accentColor : Color.primary)
                .disabled(!ReaderMenuCommand.pdfEditing.enabled(state))
                .help(L(state.pdfEditingEnabled ? "Lock Editing" : "Enable Editing"))
            }
        }
        ToolbarItem(id: "custom", placement: .automatic, showsByDefault: false) {
            ReaderToolbarButtons(state: state, open: openFiles)
        }
    }

    private func toolbarButton(_ command: ReaderMenuCommand, symbol: String) -> some View {
        Button { command.run(state) } label: { Label(command.title, systemImage: symbol) }
            .labelStyle(.iconOnly).help(command.title).disabled(!command.enabled(state))
    }

    private func fitPresetButton(_ command: ReaderMenuCommand, symbol: String) -> some View {
        Toggle(isOn: Binding(get: { command.checked(state) == true }, set: { _ in command.run(state) })) {
            Label(command.title, systemImage: symbol)
        }
        .toggleStyle(.button).labelStyle(.iconOnly)
        .help(command.title).disabled(!command.enabled(state))
    }

    private func menuCommands(_ commands: [ReaderMenuCommand]) -> some View {
        ForEach(commands) { command in
            Button { command.run(state) } label: {
                if command.checked(state) == true { Label(command.title, systemImage: "checkmark") }
                else { Text(command.title) }
            }.disabled(!command.enabled(state))
        }
    }

    private var zoomOptions: some View {
        Menu {
            menuCommands([.actual, .fitPage, .fitWidth, .fitHeight, .fitOrientation, .shrinkToFit,
                          .fitContent, .fitVisible, .zoomToSelection, .customZoom])
        } label: { Text(state.zoomLabel).font(.system(size: 12, weight: .medium)).monospacedDigit() }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("Zoom"))
    }

    private var layoutOptions: some View {
        Menu {
            if state.isFixed {
                menuCommands([.autoLayout, .paged, .continuous, .twoPages, .coverOnItsOwn, .rightToLeft])
                Divider()
                menuCommands([.rotateLeft, .rotateRight])
                Divider()
            }
            if state.isText || state.isBrowser || state.reflowable {
                TypographyMenu(state: state)
                Divider()
            }
            Menu(L("Theme")) {
                Button(L("System Theme")) { state.setTheme("system") }
                ForEach(ReaderTheme.all) { theme in Button(L(theme.name)) { state.setTheme(theme.id) } }
            }
        } label: { Label(L("Reading Options"), systemImage: "rectangle.split.2x1") }
        .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize().help(L("Reading Options"))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(L("Open…"), action: openFiles)
        if state.document != nil {
            Button(L("Show in Finder")) {
                if let url = state.document?.url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button(L("Copy File Path"), action: state.copyPath)
            Divider()
            Button(L("Previous")) { state.turn(-1) }.disabled(!state.canGoBackward)
            Button(L("Next")) { state.turn(1) }.disabled(!state.canGoForward)
            if state.isFixed {
                Button(L("Fit Page")) { state.setFit("page") }
                Button(L("Fit Width")) { state.setFit("width") }
                Button(L("Fit Content")) { state.setFit("content") }
                Button(L("Zoom to Selection"), action: state.zoomToSelection).disabled(!state.canZoomToSelection)
                Button(L("Custom Zoom…"), action: state.customZoom)
            }
        }
    }

    @ViewBuilder
    private var mainArea: some View {
        // The sidebar preference names a physical edge, independent of UI language.
        let sidebarFirst = sidebarRight == (layoutDirection == .rightToLeft)
        HSplitView {
            if sidebarFirst { sidebar }
            documentArea
                .saturation(state.grayscale && !state.isPDF ? 0 : 1)
                .overlay { if state.invertColors && !state.isPDF { Color.white.blendMode(.difference).allowsHitTesting(false) } }
                .compositingGroup()
            if !sidebarFirst { sidebar }
            if state.hasDocument && state.showAI && !state.presentation { ReaderAISidebar(state: state).frame(minWidth: 240, idealWidth: 300, maxWidth: 480) }
        }
    }

    @ViewBuilder private var sidebar: some View {
        if state.hasDocument && !state.presentation && (state.showAnnotations || state.showContents || state.showThumbnails || state.showBookmarks || (state.showSearchResults && !findFloating)) {
                VStack(spacing: 0) {
                    HStack {
                        Menu {
                            menuCommands([.contents, .thumbnails, .bookmarks, .annotations])
                            if state.showFind { Button(L("Find")) { state.showFindPanel() } }
                        } label: { Text(sidebarTitle).font(.headline) }
                        .menuStyle(.borderlessButton)
                        Spacer()
                        Button(action: state.closeSidebar) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(L("Close Sidebar")).accessibilityLabel(L("Close Sidebar"))
                    }.padding(10)
                    Divider()
                    if state.showAnnotations { AnnotationList(state: state) }
                    else if state.showBookmarks { bookmarksSidebar }
                    else if state.showThumbnails { thumbnailsSidebar }
                    else if state.showContents { contentsSidebar }
                    else if state.showSearchResults && !findFloating { ReaderSearchResults(state: state) }
                    else { contentsSidebar }
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 360)
                .focusable(!state.showContents || state.outline.isEmpty || state.outlineBusy).focused($sidebarFocused)
                .background(GeometryReader { geometry in
                    // Persist the splitter without feeding its measured width back into this layout.
                    Color.clear.onChange(of: geometry.size.width) { UserDefaults.standard.set(min(360, max(180, $0)), forKey: "sidebarWidth") }
                })
                .background(ReaderSidebarPosition(documentID: state.document?.id).frame(width: 0, height: 0))
        }
    }

    private var sidebarTitle: String {
        if state.showAnnotations { return L("Annotations") }
        if state.showBookmarks { return L("Bookmarks") }
        if state.showThumbnails { return L("Thumbnails") }
        if state.showContents { return L("Contents") }
        return L("Search Results")
    }

    @ViewBuilder
    private var contentsSidebar: some View {
        if state.outlineBusy {
            VStack {
                Spacer()
                ProgressView()
                Text(L("Detecting chapters…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if state.outline.isEmpty {
            VStack {
                Spacer()
                Text(L("No contents"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            ContentsTree(state: state)
        }
    }

    private var bookmarksSidebar: some View {
        List(state.sortedBookmarks) { bookmark in
            Button(bookmark.title) { state.openBookmark(bookmark) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L("Delete")) { state.deleteBookmark(bookmark.id) }
                    Toggle(L("Sort by Name"), isOn: $state.bookmarksByName)
                }
        }.listStyle(.sidebar)
    }

    @ViewBuilder
    private var thumbnailsSidebar: some View {
        if let document = state.document {
            switch document.content {
            case .pages:
                ScrollView {
                    LazyVStack {
                        ForEach(0..<state.count, id: \.self) { index in
                            PageThumbnail(state: state, index: index)
                        }
                    }.padding(8)
                }
            default: Text(L("This document has no page thumbnails")).foregroundStyle(.secondary)
            }
        }
    }

    private func openFiles() {
        chooseDocuments { urls in
            ReaderWindows.open(urls, in: state) { openWindow(id: "reader", value: $0) }
        }
    }

    @ViewBuilder
    private var documentArea: some View {
        Group {
            if let document = state.document {
                content(document).id(document.id)
                    // UI direction must not mirror page coordinates or change
                    // the document's independently selected reading order.
                    .environment(\.layoutDirection, .leftToRight)
            } else if state.busy {
                ProgressView(L("Opening…"))
            } else {
                WelcomeView(state: state, open: openFiles)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if state.hasDocument {
                ReaderGuides(state: state).allowsHitTesting(false)
                if state.showPageInfo {
                    VStack { Spacer(); Text(state.positionLabel + " · " + state.zoomLabel).font(.caption.monospacedDigit()).padding(6).background(.regularMaterial).cornerRadius(5).padding() }.allowsHitTesting(false)
                }
                if state.presentation, let blank = state.presentationBlank {
                    (blank == "white" ? Color.white : Color.black).onTapGesture { state.presentationBlank = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ document: ReadingDocument) -> some View {
        switch document.content {
        case .text(let text):
            TextReader(state: state, text: text)
        case .browser(let source):
            BrowserReader(state: state, source: source)
        case .pages(let pages):
            RasterReader(state: state, pages: pages)
                .task {
                    let started = DispatchTime.now().uptimeNanoseconds
                    NativeReadingPerformance.mark("prepare-request", pages: pages, revision: state.renderRevision)
                    defer { NativeReadingPerformance.mark("prepare-return", pages: pages, revision: state.renderRevision, started: started) }
                    do {
                        NativeReadingPerformance.mark("relayout-request", pages: pages, revision: state.renderRevision)
                        _ = try await pages.relayout(
                            fontSize: state.fontSize, lineHeight: state.lineHeight,
                            margin: state.margin, font: state.font, theme: state.resolvedTheme,
                            userCSS: state.effectiveUserCSS, useDocumentCSS: state.useDocumentCSS, pageMargins: state.pageMargins,
                            textZoom: pages.isMarkdown ? state.zoom : 1)
                        NativeReadingPerformance.mark("relayout-return", pages: pages, revision: state.renderRevision)
                        let prepared = try await pages.prepare()
                        var initial = state.currentPosition
                        if pages.isPDF, state.useDocumentOpenAction, let page = try await pages.pdfInitialPage() { initial.page = page }
                        let restored = try await pages.restore(initial, userCSS: state.effectiveUserCSS, theme: state.resolvedTheme)
                        let count = await pages.count
                        let chapterLayout = await pages.chapterLayout
                        try await pages.seedImageBounds(page: restored.page, uniform: state.uniformPageWidth)
                        let zoomLimit = try await pages.zoomLimit(rotation: state.rotation, maximumZoom: state.configuredZoomMaximum, uniform: state.uniformPageWidth)
                        let landscape = try await pages.landscapePages(rotation: state.rotation)
                        let pdfInfo = pages.isPDF ? try await pages.pdfInfo() : nil
                        guard !Task.isCancelled,
                              case .pages(let current)? = state.document?.content,
                              current === pages else { return }
                        state.outline = prepared.outline
                        if pages.isPDF { state.useDocumentOpenAction = false }
                        state.nativePDFInfo = pdfInfo
                        state.searchable = prepared.searchable
                        state.reflowable = prepared.reflowable
                        state.chapterLayout = chapterLayout
                        state.count = count
                        state.landscapePages = landscape
                        state.zoomLimit = zoomLimit
                        if pages.isPDF { state.apply(restored) }
                        state.zoom = ReadingZoom.clamp(state.zoom, limit: zoomLimit)
                        if pages.isPDF { state.persist() }
                        else { state.updatePosition(restored) }
                        state.renderRevision += 1
                        NativeReadingPerformance.mark("prepare-publish", pages: pages, revision: state.renderRevision, page: state.page)
                    } catch {
                        guard !Task.isCancelled, state.document?.id == document.id else { return }
                        state.error = error.localizedDescription
                    }
                }
        }
    }
}

// AppKit owns dragging. Restore its measured divider once when replacing the
// document, because SwiftUI reallocates the split when the main pane is rebuilt.
private struct ReaderSidebarPosition: NSViewRepresentable {
    let documentID: UUID?
    func makeNSView(context: Context) -> PositionView { PositionView(documentID: documentID) }
    func updateNSView(_ view: PositionView, context: Context) { view.replaceDocument(documentID) }

    final class PositionView: NSView {
        private var width = min(360, max(180, UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 220))
        private var documentID: UUID?
        private var aiWidth: CGFloat?
        private var positioned = false
        private var restoring = false
        private var resizeObserver: NSObjectProtocol?

        init(documentID: UUID?) { self.documentID = documentID; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }

        func replaceDocument(_ id: UUID?) {
            guard documentID != id else { return }
            documentID = id
            restorePosition()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !positioned else { return }
            restorePosition()
        }

        private func restorePosition() {
            restoring = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView, split.isVertical,
                       let index = split.arrangedSubviews.firstIndex(where: { self.isDescendant(of: $0) }) {
                        self.positioned = true
                        if let aiWidth = self.aiWidth, split.arrangedSubviews.count == 3 {
                            split.setPosition(split.bounds.width - aiWidth - split.dividerThickness, ofDividerAt: 1)
                        }
                        let position = index == 0 ? self.width : split.arrangedSubviews[index].frame.maxX - self.width
                        split.setPosition(position, ofDividerAt: max(0, index - 1))
                        self.aiWidth = split.arrangedSubviews.count == 3 ? split.arrangedSubviews.last?.frame.width : nil
                        self.restoring = false
                        if self.resizeObserver == nil {
                            self.resizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                object: split, queue: .main) { [weak self, weak split] _ in
                                guard let self, !self.restoring, let split,
                                      let pane = split.arrangedSubviews.first(where: { self.isDescendant(of: $0) }) else { return }
                                self.width = min(360, max(180, pane.frame.width))
                                self.aiWidth = split.arrangedSubviews.count == 3 ? split.arrangedSubviews.last?.frame.width : nil
                            }
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

private struct ReaderFindControls: View {
    @ObservedObject var state: ReaderState
    @ObservedObject private var history = ReaderSearchHistory.shared
    @AppStorage("language") private var language = "system"
    @Binding var floating: Bool
    let close: () -> Void

    var body: some View {
        let _ = language
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ReaderFindInput(state: state, floating: floating, close: close)
                    .layoutPriority(1)
                Menu {
                    ForEach(history.queries, id: \.self) { query in
                        Button(query) { state.updateFindQuery(query); state.findNext(inResults: floating) }
                    }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).frame(width: 28).disabled(history.queries.isEmpty)
                .help(L("Recent Searches")).accessibilityLabel(L("Recent Searches"))
                Button { state.findNext(backwards: true, inResults: floating) } label: { Image(systemName: "chevron.up") }
                    .disabled(state.findQuery.isEmpty).help(L("Find Previous")).accessibilityLabel(L("Find Previous"))
                Button { state.findNext(inResults: floating) } label: { Image(systemName: "chevron.down") }
                    .disabled(state.findQuery.isEmpty).help(L("Find Next")).accessibilityLabel(L("Find Next"))
                Menu {
                    Toggle(L("Match Case"), isOn: $state.searchCaseSensitive)
                    Toggle(L("Match Whole Word"), isOn: $state.searchWholeWord)
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).frame(width: 28)
                .help(L("Search Options")).accessibilityLabel(L("Search Options"))
                Button {
                    floating.toggle()
                    if !floating { state.window?.makeKeyAndOrderFront(nil) }
                } label: {
                    Image(systemName: floating ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(L(floating ? "Find in Reader" : "Open Find in a Window"))
                .accessibilityLabel(L(floating ? "Find in Reader" : "Open Find in a Window"))
                Button(action: close) { Image(systemName: "xmark") }
                    .help(L("Close Find")).accessibilityLabel(L("Close Find"))
            }
            HStack {
                if state.supportsSearchPageRange {
                    Text(L("Pages"))
                    TextField(L("All pages"), text: Binding(get: { state.searchPageRange }, set: state.setSearchPageRange))
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .onSubmit { state.findNext() }
                        .help(L("Page range, for example 3, 4-6, 18-"))
                        .accessibilityLabel(L("Search Page Range"))
                }
                Spacer()
                Text(state.searchCountText)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .onExitCommand(perform: close)
    }
}

// FindBar::ShowFindBar / FocusFindEditSelectAll focus the mounted edit control.
// Query, delayed search and result navigation remain owned by ReaderState.
@MainActor
struct ReaderFindInput: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    let floating: Bool
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(string: state.findQuery)
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        state.findInputField = field
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        state.findInputField = field
        field.placeholderString = L("Find in document")
        field.setAccessibilityLabel(L("Find in document"))
        if field.stringValue != state.findQuery { field.stringValue = state.findQuery }
        context.coordinator.updateFocus(field)
    }
    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.delegate = nil
        field.abortEditing()
        if coordinator.parent.state.findInputField === field { coordinator.parent.state.findInputField = nil }
    }
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let coordinator = delegate as? Coordinator else { return }
            coordinator.focusRevision = nil
            coordinator.updateFocus(self)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReaderFindInput
        var focusRevision: Int?
        init(_ parent: ReaderFindInput) { self.parent = parent }
        func updateFocus(_ field: NSTextField) {
            guard field.window != nil, focusRevision != parent.state.findFocusRevision else { return }
            focusRevision = parent.state.findFocusRevision
            field.selectText(nil)
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.state.updateFindQuery(field.stringValue) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.state.findNext(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true, inResults: parent.floating)
            } else if selector == #selector(NSResponder.cancelOperation(_:)) { parent.close() }
            else { return false }
            return true
        }
    }
}

struct ReaderSearchResults: View {
    @ObservedObject var state: ReaderState
    var body: some View {
        let selectedIndex = state.searchResults.firstIndex { $0.target == state.selectedSearchTarget }
        return ScrollViewReader { proxy in
            List(state.searchResults, id: \.target) { item in
                Button { state.navigate(.href(item.target)) } label: {
                    Text(item.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(state.selectedSearchTarget == item.target ? Color.accentColor.opacity(0.18) : Color.clear)
                .accessibilityAddTraits(state.selectedSearchTarget == item.target ? .isSelected : [])
            }
            .listStyle(.sidebar)
            .onAppear {
                if let target = state.selectedSearchTarget { proxy.scrollTo(target, anchor: .center) }
            }
            .onChange(of: selectedIndex) { index in
                if let index { proxy.scrollTo(state.searchResults[index].target, anchor: .center) }
            }
        }
    }
}

private struct ReaderFloatingFindView: View {
    @ObservedObject var state: ReaderState
    @AppStorage("findFloating") private var floating = false
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ReaderFindControls(state: state, floating: $floating, close: close)
            Divider()
            ReaderSearchResults(state: state)
        }
        .focusedSceneObject(state)
        .frame(minWidth: 480, minHeight: 200)
    }
}

// The panel owns only its window. Query, results and navigation remain in the
// reader; detaching this bridge or changing presentation never clears a search.
@MainActor
private struct ReaderFindPanel: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    let isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.windowChanged = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: HostView, context: Context) {
        let _ = language
        context.coordinator.state = state
        context.coordinator.isPresented = isPresented
        context.coordinator.attach(view.window)
    }
    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.attach(nil)
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor final class HostView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?(window) }
    }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        weak var state: ReaderState?
        private weak var parent: NSWindow?
        private var panel: NSPanel?
        private var focusRevision: Int?
        var isPresented = false

        func attach(_ window: NSWindow?) {
            if parent !== window {
                NotificationCenter.default.removeObserver(self)
                dismiss()
                parent = window
                if let window {
                    for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                        NotificationCenter.default.addObserver(self, selector: #selector(windowActivityChanged), name: name, object: window)
                    }
                }
            }
            update()
        }
        @objc private func windowActivityChanged(_ notification: Notification) { update() }
        private func update() {
            guard isPresented, let state, let parent else { dismiss(); return }
            guard parent.isMainWindow || parent.isKeyWindow else { panel?.orderOut(nil); return }
            let needsFocus = focusRevision != state.findFocusRevision
            if panel == nil {
                let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                                     styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.isFloatingPanel = true
                window.hidesOnDeactivate = true
                window.tabbingMode = .disallowed
                window.contentView = NSHostingView(rootView: ReaderFloatingFindView(state: state, close: { [weak self] in self?.closeFind() }).modifier(ReaderLanguage()))
                window.contentMinSize = NSSize(width: 480, height: 200)
                window.delegate = self
                window.setFrameTopLeftPoint(NSPoint(x: parent.frame.maxX - 540, y: parent.frame.maxY - 80))
                parent.addChildWindow(window, ordered: .above)
                panel = window
                state.findWindow = window
            }
            panel?.title = L("Find in document")
            panel?.appearance = parent.effectiveAppearance
            focusRevision = state.findFocusRevision
            if needsFocus { panel?.makeKeyAndOrderFront(nil) }
            else { panel?.orderFront(nil) }
        }
        private func dismiss() {
            guard let panel else { return }
            if state?.findWindow === panel { state?.findWindow = nil }
            panel.delegate = nil
            parent?.removeChildWindow(panel)
            panel.close()
            self.panel = nil
            focusRevision = nil
        }
        private func closeFind() {
            isPresented = false
            dismiss()
            state?.closeFind()
            parent?.makeKeyAndOrderFront(nil)
            if let state, let target = (state.browserView as NSView?) ?? state.readerFocusView {
                parent?.makeFirstResponder(target)
            }
        }
        func windowWillClose(_ notification: Notification) {
            guard let closed = notification.object as? NSWindow, closed === panel else { return }
            if state?.findWindow === closed { state?.findWindow = nil }
            closed.delegate = nil
            parent?.removeChildWindow(closed)
            panel = nil
            focusRevision = nil
            closeFind()
        }
    }
}

private struct PageThumbnail: View {
    @ObservedObject var state: ReaderState
    let index: Int
    var body: some View {
        Button { state.navigate(.page(index)) } label: {
            VStack {
                ReaderPagePreview(state: state, index: index).frame(width: 120, height: 160)
                Text(String(index + 1)).font(.caption)
            }
            .padding(4)
            .background(state.page == index ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
    }
}

struct ReaderPagePreview: View {
    @ObservedObject var state: ReaderState
    let index: Int
    @State private var preview: (key: String, image: NSImage)?
    var body: some View {
        // Like Sumatra's ThumbnailRenderWorker.loc, bind rendering to the
        // chapter/page, since preceding chapters can change this flat index.
        let location = state.pageLocation(index), revision = state.renderRevision, rotation = state.rotation
        let document = state.document
        let key = "\(document?.id.uuidString ?? ""):\(revision):\(rotation):\(location.chapter):\(location.page)"
        Group {
            if let preview, preview.key == key { Image(nsImage: preview.image).resizable().scaledToFit() }
            else { Image(systemName: "doc").foregroundStyle(.secondary) }
        }
        .task(id: key) {
            guard let document else { return }
            var image: NSImage?
            switch document.content {
            case .pages(let pages):
                if let rendered = try? await pages.image(location, width: 128), !Task.isCancelled {
                    if let oriented = try? RasterLayout.image(rendered, bounds: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height), crop: nil, rotation: rotation) {
                        image = NSImage(cgImage: oriented, size: .zero)
                    }
                }
            default: image = nil
            }
            guard !Task.isCancelled, state.document?.id == document.id, state.renderRevision == revision,
                  state.rotation == rotation, state.pageLocation(index) == location, let image else { return }
            preview = (key, image)
        }
        .onDisappear { preview = nil }
    }
}

private struct WelcomeView: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    let open: () -> Void

    var body: some View {
        let _ = language
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Sumra")).font(.system(size: 24, weight: .semibold))
                    Text(L("PDF, books, comics & Markdown"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                Button(action: open) {
                    Label(L("Open Document…"), systemImage: "folder")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .fixedSize(horizontal: true, vertical: false).keyboardShortcut("o")
            }
            .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 24)
            Divider().padding(.horizontal, 24)
            DocumentFileBrowser(state: state)
        }
        .frame(maxWidth: 760, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TypographyMenu: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"

    var body: some View {
        let _ = language
        Group {
            Button(L("Typography and CSS…"), action: state.editTypography)
            Toggle(L("Use Changes as Defaults"), isOn: $state.typographyForAll)
            if state.isCHM {
                Toggle(L("Use document styles"), isOn: Binding(
                    get: { state.useDocumentCSS },
                    set: { state.useDocumentCSS = $0; state.applyTypography() }))
            }
            Group {
                Picker(L("Font"), selection: $state.font) {
                    Text(L("System")).tag("system")
                    Text(L("Serif")).tag("serif")
                    Text(L("Sans Serif")).tag("sans-serif")
                    Text(L("Monospace")).tag("monospace")
                }
                .onChange(of: state.font) { _ in state.applyTypography() }

                Stepper(String(format: L("Font %d pt"), Int(state.fontSize)), value: $state.fontSize, in: 10...36, step: 1)
                    .onChange(of: state.fontSize) { _ in state.applyTypography() }

                Stepper(String(format: L("Line %.1f"), state.lineHeight), value: $state.lineHeight, in: 1...2.4, step: 0.1)
                    .onChange(of: state.lineHeight) { _ in state.applyTypography() }
            }
            .disabled(state.isCHM && state.useDocumentCSS)

            Stepper(String(format: L("Margin %d"), Int(state.margin)), value: Binding(
                get: { state.margin },
                set: { value in
                    state.margin = value
                    state.pageMargins = PageMargins(cssValues: [value])
                    state.applyTypography()
                }), in: 0...96, step: 8)
        }
    }
}
#endif
