#if os(macOS)
import SwiftUI
import SumraCore
import CoreText

@MainActor
struct ReaderView: View {
    @ObservedObject var state: ReaderState
    var awaitingDocumentOpen = false
    @AppStorage("language") private var language = "system"
    @AppStorage("customThemes") private var customThemes = "[]"
    @AppStorage("findFloating") private var findFloating = false
    @AppStorage("sidebarRight") private var sidebarRight = false
    @AppStorage("progressDisplayMode") private var progressDisplayMode = ReaderToolbarDisplayMode.auto
    @FocusState private var sidebarFocused: Bool
    @State private var initialNativeCanvas: (document: UUID, bounds: CGRect, position: ReadingPosition)?
    @State private var initialNativeViewport: (document: UUID, size: CGSize)?
    @State private var fullscreenMenuInset: CGFloat = 0
    @State private var nativeTopClearance: CGFloat = 0
    @State private var bottomStatusHeight: CGFloat = 0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        let _ = language
        let _ = customThemes
        let findStatusVisible = state.showFind || state.searchSessionActive
        let findControlsShown = state.showFind && !findFloating && !state.presentation
        let editingControlsShown = state.isPDF && state.pdfEditingEnabled && !state.presentation
        let speechControlsShown = state.speechRequested && !state.presentation
        let hasTopControls = findControlsShown || editingControlsShown || speechControlsShown
        let topClearance = floatingTopClearance(forControls: hasTopControls)
        VStack(spacing: 0) {
            if !state.hasDocument { ReaderHomeHeader() }
            if findControlsShown {
                ReaderFindControls(state: state, floating: $findFloating, close: closeFind)
                    .modifier(ReaderChromeEntrance())
                Divider()
            }

            if editingControlsShown {
                PDFEditingBar(state: state)
                Divider()
            }

            if speechControlsShown { SpeechControls(state: state); Divider() }
            mainArea(topClearance: hasTopControls ? 0 : topClearance, topControlsShown: hasTopControls)

            if state.hasDocument && !state.presentation && !overlaysProgress && progressDisplayMode != .hidden {
                ReaderProgressFooter(state: state).id(state.document?.id)
            }

            if state.document != nil && !state.presentation && (findStatusVisible || !state.status.isEmpty || state.modified) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Text(state.status.isEmpty && findStatusVisible ? state.searchCountText : state.status).lineLimit(1)
                        Spacer()
                        if state.modified { Text(L("Unsaved Changes")) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { bottomStatusHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { bottomStatusHeight = $0 }
                            .onDisappear { bottomStatusHeight = 0 }
                    }
                }
            }
        }
        .padding(.top, (hasTopControls ? topClearance : 0) + (reclaimsNativeInsets || state.usesFloatingChrome ? 0 : fullscreenMenuInset))
        .padding(.bottom, floatingBottomClearance)
        .overlay(alignment: .top) {
            if state.usesFloatingChrome {
                ReaderFloatingControls(state: state, open: openFiles).padding(.top, fullscreenMenuInset)
            }
        }
        .overlay(alignment: .bottom) {
            if overlaysProgress && state.hasDocument && !state.presentation && progressDisplayMode != .hidden {
                ReaderProgressFooter(state: state, floating: state.usesFloatingChrome).id(state.document?.id)
            }
        }
        .background(state.hasDocument ? Color(nsColor: ReaderTheme.color(state.palette.background)) : Color(nsColor: .windowBackgroundColor))
        .background(ReaderScrollbarClearance(state: state,
            top: hasTopControls ? 0 : (state.usesFloatingChrome ? floatingControlsClearance : (reclaimsNativeInsets ? nativeTopClearance : 0)),
            bottom: overlaysProgress && state.hasDocument && !state.presentation && progressDisplayMode != .hidden
                ? ReaderProgressFooter.layoutHeight(floating: state.usesFloatingChrome) : 0))
        .overlay(ReaderToolbarWindow(state: state, reducedMotion: reducedMotion, fullscreenMenuInset: $fullscreenMenuInset, nativeTopClearance: $nativeTopClearance))
        .onChange(of: state.showAI) { if $0 { state.recentSidebarIsAI = true } }
        .onChange(of: state.showContents) { if $0 { state.recentSidebarIsAI = false } }
        .onChange(of: state.showBookmarks) { if $0 { state.recentSidebarIsAI = false } }
        .onChange(of: state.showThumbnails) { if $0 { state.recentSidebarIsAI = false } }
        .onChange(of: state.showAnnotations) { if $0 { state.recentSidebarIsAI = false } }
        .onChange(of: state.showSearchResults) { if $0 { state.recentSidebarIsAI = false } }
        .onChange(of: colorScheme) { _ in
            if state.theme == "system", state.isText || state.isBrowser || state.reflowable {
                state.send(.style)
            }
        }
        .toolbar(id: "reader") { toolbar }
        // Auto Hide keeps the native layout installed for hover. Always Hide
        // removes the toolbar; the window buttons keep their own hover owner.
        .toolbar(state.usesCustomChrome || (state.hasDocument && state.toolbarDisplayMode == .hidden) ? .hidden : .visible, for: .windowToolbar)
        .modifier(ReaderToolbarAppearance(shown: state.toolbarShown && !state.usesCustomChrome, hidesNativeTitle: state.usesCustomChrome,
                                          permanentlyHidden: state.toolbarDisplayMode == .hidden, background: ReaderTheme.color(state.palette.background)))
        .onChange(of: reducedMotion) { _ in state.toolbarHoverVisible = false }
        .onChange(of: state.presentation) {
            state.toolbarHoverVisible = false
            if !$0 { state.presentationBlank = nil }
        }
        .onChange(of: state.focusCycle) { _ in
            if state.presentation { sidebarFocused = false; focusReader(); return }
            let sidebarVisible = !(state.compactSidebars && state.recentSidebarIsAI) &&
                (state.showContents || state.showBookmarks || state.showThumbnails || state.showAnnotations || (state.showSearchResults && !findFloating))
            if findFloating && state.showFind && state.window?.isKeyWindow == false { focusReader() }
            else if state.findInputField?.currentEditor() != nil { focusReader() }
            else if sidebarVisible, let tree = state.contentsFocusView, tree.window != nil, !tree.visibleRect.isEmpty {
                if tree.window?.firstResponder === tree {
                    if state.showFind { state.showFindPanel() } else { focusReader() }
                } else { tree.window?.makeFirstResponder(tree) }
            }
            else if sidebarFocused { sidebarFocused = false; if state.showFind { state.showFindPanel() } else { focusReader() } }
            else if sidebarVisible { sidebarFocused = true }
            else if state.showFind { state.showFindPanel() }
            else { focusReader() }
        }
        .background(ReaderSelectionToolbar(state: state).frame(width: 0, height: 0))
        .background(ReaderFindPanel(state: state, isPresented: state.showFind && findFloating && !state.presentation).frame(width: 0, height: 0))
        .modifier(ReaderCommandSheets(state: state, open: openFiles))
        .contextMenu { contextMenu }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            ReaderWindows.open(urls, in: state) { openWindow(id: "reader", value: $0) }
            return true
        }
        .alert(
            L("Unable to complete action"),
            isPresented: Binding(
                get: { state.error != nil && state.missingFile == nil },
                set: { if !$0 { state.error = nil } }
            )
        ) {
            Button(L("OK")) { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
        .ignoresSafeArea(.container, edges: state.extendsReadingUnderChrome ? .top : [])
    }

    private var reclaimsNativeInsets: Bool {
        state.extendsReadingUnderChrome && !state.usesFloatingChrome
    }
    private var overlaysProgress: Bool {
        state.usesFloatingChrome || (progressDisplayMode == .auto && reclaimsNativeInsets)
    }
    private var floatingControlsClearance: CGFloat {
        fullscreenMenuInset + ReaderFloatingControls.topInset + ReaderFloatingControls.height
    }
    private func floatingTopClearance(forControls: Bool) -> CGFloat {
        guard state.usesFloatingChrome else {
            // Reading content may extend under native hover chrome, but its
            // interactive rows must stay below the measured titlebar and tabs,
            // including the separate menu strip revealed in native fullscreen.
            return forControls && reclaimsNativeInsets ? nativeTopClearance + fullscreenMenuInset : 0
        }
        if state.toolbarDisplayMode == .hidden {
            return forControls ? floatingControlsClearance : 0
        }
        // The book already reserves its own page margin. Add only the space
        // still needed to clear the controls, rather than stacking two margins.
        // An unset override leaves publisher margins in charge; the legacy
        // scalar is not the actual margin of a native reflowable book.
        // Find, speech and editing rows stay reachable even when the user
        // allows the toolbar to overlap reading content.
        // Fixed pages consume the same margins outside their native canvas.
        let pageMargin = !forControls ? state.contentMargins?.top ?? 0 : 0
        // Positive reading clearance starts below the fullscreen menu band;
        // zero still lets the book extend beneath the floating controls.
        let readingClearance = state.controlTopMargin > 0 ? state.controlTopMargin + fullscreenMenuInset : 0
        let clearance = forControls
            ? max(state.controlTopMargin, floatingControlsClearance)
            : readingClearance
        return max(0, clearance - pageMargin)
    }
    private var sidebarTopClearance: CGFloat {
        if state.usesFloatingChrome {
            let windowControlsClearance = floatingControlsClearance + 10
            return state.toolbarDisplayMode == .hidden ? windowControlsClearance : max(state.controlTopMargin, windowControlsClearance)
        }
        return reclaimsNativeInsets ? nativeTopClearance : 0
    }
    private var sidebarBottomClearance: CGFloat {
        guard overlaysProgress, state.hasDocument, !state.presentation, progressDisplayMode != .hidden else { return 0 }
        // Sidebars have interactive content down to their bottom edge. Clear
        // the whole footer hover target, counting root padding/status only once.
        return max(0, ReaderProgressFooter.layoutHeight(floating: state.usesFloatingChrome) - floatingBottomClearance - bottomStatusHeight)
    }
    private var floatingBottomClearance: CGFloat {
        guard state.usesFloatingChrome, progressDisplayMode != .hidden else { return 0 }
        let pageMargin = state.contentMargins?.bottom ?? 0
        return max(0, state.controlBottomMargin - pageMargin)
    }

    private func closeFind() {
        state.closeFind()
    }

    private func focusReader() {
        if findFloating { state.window?.makeKeyAndOrderFront(nil) }
        let target = (state.browserView as NSView?) ?? state.readerFocusView
        if let target { state.window?.makeFirstResponder(target) }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some CustomizableToolbarContent {
        // Keep each item's content present in every window, including empty,
        // loading and closing windows. AppKit shares item indexes across this
        // toolbar family; unsupported commands use their existing enabled state.
        ToolbarItem(id: "open", placement: .automatic, showsByDefault: true) {
            Button(action: openFiles) { Label(L("Open Document"), systemImage: "folder") }
                .labelStyle(.iconOnly).help(L("Open Document")).accessibilityLabel(L("Open Document"))
        }
        ToolbarItem(id: "newTab", placement: .automatic, showsByDefault: true) {
            toolbarButton(.newTab, symbol: "plus")
        }
        ToolbarItem(id: "contents", placement: .automatic, showsByDefault: true) {
            Button { if !state.showContents || !state.revealCompactSidebar(ai: false) { state.showContents.toggle() } } label: { Label(L("Toggle Contents"), systemImage: "sidebar.left") }
                .labelStyle(.iconOnly).disabled(!state.hasDocument).help(L("Toggle Contents")).accessibilityLabel(L("Toggle Contents"))
                .foregroundStyle(state.showContents ? Color.accentColor : Color.primary)
                .accessibilityValue(state.showContents ? L("On") : L("Off"))
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
            HStack(spacing: 4) {
                fitPresetButton(.fitPageSingle, symbol: "rectangle.portrait")
                fitPresetButton(.fitWidthContinuous, symbol: "arrow.left.and.right")
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
        ToolbarItem(id: "readingSettings", placement: .automatic, showsByDefault: true) {
            Button(action: state.editTypography) {
                Label { Text(L("Reading Settings")) } icon: {
                    Text(verbatim: "Aa").font(.system(size: 12, weight: .medium))
                }
            }
            .accessibilityLabel(L("Reading Settings"))
            .help(L("Reading Settings")).disabled(!state.hasDocument)
        }
        ToolbarItem(id: "find", placement: .automatic, showsByDefault: true) {
            Button { state.toggleFindPanel() } label: { Label(L("Find"), systemImage: "magnifyingglass") }
                .labelStyle(.iconOnly).disabled(!state.supportsSearch).help(L("Find")).accessibilityLabel(L("Find"))
                .foregroundStyle(state.showFind ? Color.accentColor : Color.primary)
        }
        ToolbarItem(id: "edit", placement: .automatic, showsByDefault: true) {
            Button { ReaderMenuCommand.pdfEditing.run(state) } label: {
                Label(L(state.pdfEditingEnabled ? "Lock Editing" : "Enable Editing"),
                      systemImage: state.pdfEditingEnabled ? "lock.open" : "lock")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(state.pdfEditingEnabled ? Color.accentColor : Color.primary)
            .disabled(!ReaderMenuCommand.pdfEditing.enabled(state))
            .help(L(state.pdfEditingEnabled ? "Lock Editing" : "Enable Editing"))
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
        ReaderCommandMenuItems(state: state, commands: commands)
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
            if state.supportsPagination {
                if state.isFixed { menuCommands([.autoLayout]) }
                menuCommands([.paged, .continuous, .twoPages])
                if state.isFixed { menuCommands([.coverOnItsOwn]) }
                menuCommands([.rightToLeft])
                Divider()
                if state.isFixed {
                    menuCommands([.rotateLeft, .rotateRight])
                    Divider()
                }
            }
            if state.isText || state.isBrowser || state.reflowable {
                TypographyMenu(state: state)
                Divider()
            }
            Menu(L("Theme")) {
                Button(L("System Theme")) { state.setTheme("system") }
                ForEach(ReaderTheme.all) { theme in Button(theme.displayName) { state.setTheme(theme.id) } }
                Divider()
                Button(L("Choose Theme…")) { state.chooseTheme() }
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
    private func mainArea(topClearance: CGFloat, topControlsShown: Bool) -> some View {
        // The sidebar preference names a physical edge, independent of UI language.
        let sidebarFirst = sidebarRight == (layoutDirection == .rightToLeft)
        // Shared Find/edit/speech rows already start below the window controls.
        // Sidebars below those rows must not reserve the toolbar a second time.
        let sidebarInset = topControlsShown ? 0 : sidebarTopClearance
        // Each pane reserves chrome clearance itself; reclaim the native safe
        // area in every split child so sidebars do not count that space twice.
        GeometryReader { geometry in
            let hasSidebar = state.hasDocument && !state.presentation && (state.showAnnotations || state.showContents || state.showThumbnails || state.showBookmarks || (state.showSearchResults && !findFloating))
            let hasAI = state.hasDocument && state.showAI && !state.presentation
            let compactBoth = hasSidebar && hasAI && geometry.size.width < 882
            let hideSidebar = compactBoth && state.recentSidebarIsAI
            let hideAI = compactBoth && !state.recentSidebarIsAI
            HSplitView {
                if sidebarFirst {
                    sidebar(hidden: hideSidebar).padding(.top, sidebarInset).padding(.bottom, sidebarBottomClearance)
                        .frame(width: hideSidebar ? 0 : nil).clipped().accessibilityHidden(hideSidebar).allowsHitTesting(!hideSidebar)
                        .ignoresSafeArea(.container, edges: state.extendsReadingUnderChrome ? .top : [])
                }
                documentArea
                    // Keep reader clearance inside the ignored safe area. Outer
                    // padding within the native titlebar inset would be reclaimed
                    // along with that inset by the split view's child.
                    .padding(.top, topClearance)
                    .ignoresSafeArea(.container, edges: state.extendsReadingUnderChrome ? .top : [])
                    .saturation(state.grayscale && !state.isPDF ? 0 : 1)
                    .overlay { if state.invertColors && !state.isPDF { Color.white.blendMode(.difference).allowsHitTesting(false) } }
                    .compositingGroup()
                    .frame(minWidth: hasAI && !hideAI && geometry.size.width < 701 ? 200 : 360)
                if !sidebarFirst {
                    sidebar(hidden: hideSidebar).padding(.top, sidebarInset).padding(.bottom, sidebarBottomClearance)
                        .frame(width: hideSidebar ? 0 : nil).clipped().accessibilityHidden(hideSidebar).allowsHitTesting(!hideSidebar)
                        .ignoresSafeArea(.container, edges: state.extendsReadingUnderChrome ? .top : [])
                }
                if state.hasDocument && state.showAI && !state.presentation {
                    ReaderAISidebar(state: state).padding(.top, sidebarInset).padding(.bottom, sidebarBottomClearance)
                        .background(ReaderPaneFocus(state: state, hidden: hideAI).frame(width: 0, height: 0))
                        .frame(width: hideAI ? 0 : nil).clipped().accessibilityHidden(hideAI).allowsHitTesting(!hideAI)
                        .ignoresSafeArea(.container, edges: state.extendsReadingUnderChrome ? .top : [])
                }
            }
            .onAppear { state.compactSidebars = compactBoth }
            .onChange(of: compactBoth) { state.compactSidebars = $0 }
        }
    }

    @ViewBuilder private func sidebar(hidden: Bool) -> some View {
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
                    else if state.showContents { contentsNavigation }
                    else if state.showSearchResults && !findFloating { ReaderSearchResults(state: state) }
                    else { contentsSidebar }
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 360)
                .focusable(!hidden && (!state.showContents || state.outline.isEmpty || state.outlineBusy)).focused($sidebarFocused)
                .background(ReaderPaneFocus(state: state, hidden: hidden).frame(width: 0, height: 0))
                .background(ReaderSidebarPosition(documentID: state.document?.id, hidden: hidden).frame(width: 0, height: 0))
                .modifier(ReaderChromeEntrance())
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
    private var contentsNavigation: some View {
        if state.isCHM && !state.chmIndex.isEmpty {
            CHMContentsPane(state: state) { contentsSidebar }
        } else { contentsSidebar }
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
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack {
                            ForEach(0..<state.count, id: \.self) { index in
                                PageThumbnail(state: state, index: index).id(index)
                            }
                        }.padding(8)
                    }
                    .onAppear { scroll.scrollTo(state.page, anchor: .center) }
                    .onChange(of: state.page) { page in scroll.scrollTo(page, anchor: .center) }
                    .onChange(of: document.id) { _ in scroll.scrollTo(state.page, anchor: .center) }
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
            } else if state.busy || awaitingDocumentOpen {
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
            RasterReader(state: state, pages: pages,
                initialBounds: initialNativeCanvas?.document == document.id ? initialNativeCanvas?.bounds : nil,
                initialPosition: initialNativeCanvas?.document == document.id ? initialNativeCanvas?.position : nil)
                .background(ReaderInitialViewport { size in
                    initialNativeViewport = (document.id, size)
                })
                .task(id: initialNativeViewport?.document) {
                    guard let viewport = initialNativeViewport, viewport.document == document.id else { return }
                    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                        reason: "Prepare document for reading")
                    defer { ProcessInfo.processInfo.endActivity(activity) }
                    let started = DispatchTime.now().uptimeNanoseconds
                    NativeReadingPerformance.mark("prepare-request", pages: pages, revision: state.renderRevision, persistent: true)
                    defer { NativeReadingPerformance.mark("prepare-return", pages: pages, revision: state.renderRevision, started: started, persistent: true) }
                    do {
                        var initial = state.currentPosition
                        let bookmark = initial.anchor.flatMap(ChapterTable.bookmarkLocation)
                        // Legacy finite-page records must resolve their source
                        // in the recorded geometry before entering natural flow.
                        // An unresolved chapter start has no old pagination;
                        // a later page still identifies a legacy finite layout.
                        let legacyPages = initial.nativePassage == nil && bookmark.map { $0.count > 1 || $0.location.page > 0 } == true
                        let continuous = state.flow == "continuous" && !state.presentation
                        let initialViewport = ReaderScrollbars.initialReadingViewport(in: viewport.size, mode: state.scrollbarMode, continuous: continuous)
                        let pageSize = RasterReader.pageSize(in: initialViewport,
                            spread: state.spread && !state.presentation,
                            continuous: continuous)
                        let initialPageSize = legacyPages ? nil : pageSize
                        let flags = (initial.nativePassage == nil ? 0 : 1) | (legacyPages ? 2 : 0)
                            | (bookmark?.count == 1 ? 4 : 0) | (continuous ? 8 : 0)
                        let layoutStarted = DispatchTime.now().uptimeNanoseconds
                        NativeReadingPerformance.mark("relayout-request", pages: pages, revision: state.renderRevision,
                                                      size: initialPageSize ?? CGSize(width: 420, height: 595), persistent: true, flags: flags)
                        _ = try await pages.relayout(
                            fontSize: state.fontSize, lineHeight: state.lineHeight,
                            margin: state.margin, font: state.font, theme: state.resolvedTheme,
                            userCSS: state.effectiveUserCSS, useDocumentCSS: state.useDocumentCSS, pageMargins: state.contentMargins,
                            textZoom: pages.isMarkdown ? state.zoom : 1,
                            pageSize: initialPageSize, viewport: initialViewport)
                        NativeReadingPerformance.mark("relayout-return", pages: pages, revision: state.renderRevision, started: layoutStarted, persistent: true, flags: flags)
                        if pages.isPDF, state.useDocumentOpenAction, let page = try await pages.pdfInitialPage() { initial.page = page }
                        let restoreStarted = DispatchTime.now().uptimeNanoseconds
                        NativeReadingPerformance.mark("prepare-restore-entry", pages: pages, persistent: true, flags: flags)
                        var restored = try await pages.restore(initial, userCSS: state.effectiveUserCSS, theme: state.resolvedTheme,
                            viewport: initialViewport)
                        NativeReadingPerformance.mark("prepare-restore-return", pages: pages, started: restoreStarted, persistent: true)
                        let finalViewport = ReaderScrollbars.initialReadingViewport(in: viewport.size,
                            mode: state.scrollbarMode, continuous: continuous)
                        let finalPageSize = RasterReader.pageSize(in: finalViewport,
                            spread: state.spread && !state.presentation, continuous: continuous)
                        if legacyPages || finalPageSize != pageSize {
                            // Resolve the saved source before publishing the
                            // final viewport geometry, including scrollbar changes.
                            let changed = try await pages.relayout(
                                fontSize: state.fontSize, lineHeight: state.lineHeight,
                                margin: state.margin, font: state.font, theme: state.resolvedTheme,
                                userCSS: state.effectiveUserCSS, useDocumentCSS: state.useDocumentCSS, pageMargins: state.contentMargins,
                                textZoom: pages.isMarkdown ? state.zoom : 1,
                                pageSize: finalPageSize, readingPosition: restored, viewport: finalViewport)
                            if changed != nil { restored = await pages.layoutPosition }
                        }
                        if state.spread && !state.presentation && !continuous {
                            restored = try await pages.prepareFacingPages(restored, cover: state.cover)
                        }
                        let outlineStarted = DispatchTime.now().uptimeNanoseconds
                        NativeReadingPerformance.mark("prepare-outline-entry", pages: pages, persistent: true)
                        let prepared = try await pages.prepare()
                        NativeReadingPerformance.mark("prepare-outline-return", pages: pages, started: outlineStarted, persistent: true)
                        let geometryStarted = DispatchTime.now().uptimeNanoseconds
                        NativeReadingPerformance.mark("prepare-geometry-entry", pages: pages, persistent: true)
                        let count = await pages.count
                        let chapterLayout = await pages.chapterLayout
                        try await pages.seedImageBounds(page: restored.page, uniform: state.uniformPageWidth)
                        let zoomLimit = try await pages.zoomLimit(rotation: state.rotation, maximumZoom: state.configuredZoomMaximum, uniform: state.uniformPageWidth)
                        let landscape = try await pages.landscapePages(rotation: state.rotation)
                        let pdfInfo = pages.isPDF ? try await pages.pdfInfo() : nil
                        NativeReadingPerformance.mark("prepare-geometry-return", pages: pages, started: geometryStarted, persistent: true)
                        let boundsStarted = DispatchTime.now().uptimeNanoseconds
                        NativeReadingPerformance.mark("prepare-bounds-entry", pages: pages, page: restored.page, persistent: true)
                        let initialBounds = try await pages.bounds(restored.page)
                        NativeReadingPerformance.mark("prepare-bounds-return", pages: pages, page: restored.page, started: boundsStarted, size: initialBounds.size, persistent: true)
                        guard !Task.isCancelled,
                              case .pages(let current)? = state.document?.content,
                              current === pages else { return }
                        let publicationStarted = DispatchTime.now().uptimeNanoseconds
                        NativeReadingPerformance.mark("prepare-publication-entry", pages: pages, revision: state.renderRevision, persistent: true)
                        initialNativeCanvas = (document.id, initialBounds, restored)
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
                        NativeReadingPerformance.mark("prepare-publish", pages: pages, revision: state.renderRevision, page: state.page, started: publicationStarted, persistent: true)
                    } catch {
                        guard !Task.isCancelled, state.document?.id == document.id else { return }
                        state.error = error.localizedDescription
                    }
                }
        }
    }
}

// SwiftUI's first size proposal can precede the window's actual reader layout.
// Measure its mounted AppKit surface after applying the pending window layout.
struct ReaderInitialViewport: NSViewRepresentable {
    let measured: (CGSize) -> Void
    func makeNSView(context: Context) -> View { View(measured: measured) }
    func updateNSView(_ view: View, context: Context) { view.measured = measured }

    final class View: NSView {
        var measured: (CGSize) -> Void
        private var delivered = false
        private var scheduled = false

        init(measured: @escaping (CGSize) -> Void) { self.measured = measured; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measureAfterLayout() }
        override func layout() { super.layout(); measureAfterLayout() }

        private func measureAfterLayout() {
            guard !delivered, !scheduled, window != nil else { return }
            scheduled = true
            let scheduledAt = DispatchTime.now().uptimeNanoseconds
            NativeReadingPerformance.mark("initial-viewport-scheduled", persistent: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NativeReadingPerformance.mark("initial-viewport-entry", started: scheduledAt, persistent: true)
                self.scheduled = false
                guard !self.delivered, let window = self.window else { return }
                let layoutStarted = DispatchTime.now().uptimeNanoseconds
                window.contentView?.layoutSubtreeIfNeeded()
                NativeReadingPerformance.mark("initial-viewport-layout-return", started: layoutStarted, size: self.bounds.size, persistent: true)
                guard !self.bounds.isEmpty else { return }
                self.delivered = true
                self.measured(self.bounds.size)
                NativeReadingPerformance.mark("initial-viewport-delivered", started: scheduledAt, size: self.bounds.size, persistent: true)
            }
        }
    }
}

// Zero-width panes remain mounted. Move focus back to the document when a
// resize or sidebar choice hides the native control that currently owns it.
private struct ReaderPaneFocus: NSViewRepresentable {
    let state: ReaderState
    let hidden: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard hidden else { return }
        DispatchQueue.main.async { [weak view, weak state] in
            guard let view, let state, let window = view.window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            var ancestor = view.superview
            while let pane = ancestor {
                if let split = pane.superview as? NSSplitView, split.arrangedSubviews.contains(pane) {
                    let responder = window.firstResponder as? NSView
                    let editor = responder as? NSTextView
                    let owner = editor?.isFieldEditor == true ? (editor?.delegate as? NSView) : responder
                    if pane.frame.width < 1, owner?.isDescendant(of: pane) == true {
                        window.makeFirstResponder((state.browserView as NSView?) ?? state.readerFocusView)
                    }
                    return
                }
                ancestor = pane.superview
            }
        }
    }
}

// AppKit owns dragging. Restore its measured divider once when replacing the
// document, because SwiftUI reallocates the split when the main pane is rebuilt.
private struct ReaderSidebarPosition: NSViewRepresentable {
    let documentID: UUID?
    let hidden: Bool
    @AppStorage("sidebarWidth") private var width = 220.0
    func makeNSView(context: Context) -> PositionView { PositionView(documentID: documentID, width: width, hidden: hidden) }
    func updateNSView(_ view: PositionView, context: Context) { view.update(documentID, width: width, hidden: hidden) }

    final class PositionView: NSView {
        private var width: CGFloat
        private var sidebarHidden: Bool
        private var documentID: UUID?
        private var aiWidth: CGFloat?
        private var positioned = false
        private var restoring = false
        private var splitWidth: CGFloat?
        private var resizeObserver: NSObjectProtocol?

        init(documentID: UUID?, width: CGFloat, hidden: Bool) {
            self.sidebarHidden = hidden; self.documentID = documentID; self.width = min(360, max(180, width))
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }

        func update(_ id: UUID?, width: CGFloat, hidden: Bool) {
            let wasHidden = self.sidebarHidden
            self.sidebarHidden = hidden
            if wasHidden && !hidden { restorePosition() }
            let width = min(360, max(180, width))
            guard documentID != id || self.width != width else { return }
            documentID = id; self.width = width
            restorePosition()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !positioned else { return }
            restorePosition()
        }

        private func restorePosition() {
            guard !sidebarHidden else { return }
            restoring = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.sidebarHidden else { return }
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
                        self.splitWidth = split.bounds.width
                        self.restoring = false
                        if self.resizeObserver == nil {
                            self.resizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                object: split, queue: .main) { [weak self, weak split] _ in
                                guard let self, !self.restoring, !self.sidebarHidden, let split,
                                      let pane = split.arrangedSubviews.first(where: { self.isDescendant(of: $0) }) else { return }
                                // Window resizing can constrain the sidebar below
                                // its saved width. Reapply that preference through
                                // native constraints without saving the allocation.
                                if self.splitWidth != split.bounds.width {
                                    self.restorePosition()
                                    return
                                }
                                self.width = min(360, max(180, pane.frame.width))
                                self.aiWidth = split.arrangedSubviews.count == 3 ? split.arrangedSubviews.last?.frame.width : nil
                                // Record the native allocation before publishing
                                // it, so AppStorage cannot restore a transient
                                // geometry measurement over the saved width.
                                UserDefaults.standard.set(Double(self.width), forKey: "sidebarWidth")
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
                    .frame(minWidth: 0, maxWidth: floating ? .infinity : 248)
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
                if !state.findQuery.isEmpty {
                    Text(state.searchCountText)
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            }
            if state.supportsSearchPageRange {
                HStack {
                    Text(L("Pages"))
                    TextField(L("All pages"), text: Binding(get: { state.searchPageRange }, set: state.setSearchPageRange))
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .onSubmit { state.findNext() }
                        .help(L("Page range, for example 3, 4-6, 18-"))
                        .accessibilityLabel(L("Search Page Range"))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != state.findQuery {
            field.stringValue = state.findQuery
        }
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
        private var composing = false
        init(_ parent: ReaderFindInput) { self.parent = parent }
        func updateFocus(_ field: NSTextField) {
            guard field.window != nil, focusRevision != parent.state.findFocusRevision else { return }
            focusRevision = parent.state.findFocusRevision
            field.selectText(nil)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let marked = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
            parent.state.updateFindQuery(field.stringValue, refresh: composing && !marked, composing: marked)
            composing = marked
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
        ReaderSearchResultsTable(state: state)
            .overlay(alignment: .topLeading) {
                if state.findQuery.isEmpty && state.searchResults.isEmpty {
                    Text(L("Type a search term to see matches."))
                        .font(.callout).foregroundStyle(.secondary).padding(12)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct ReaderSearchResultsTable: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = Table()
        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 44; table.intercellSpacing = .zero
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.coordinator = context.coordinator
        table.setAccessibilityLabel(L("Search Results"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let table = scroll.documentView as! NSTableView
        table.setAccessibilityLabel(L("Search Results"))
        context.coordinator.update(table)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let table = scroll.documentView as? NSTableView else { return }
        if table.window?.firstResponder === table { table.window?.makeFirstResponder(nil) }
        table.delegate = nil; table.dataSource = nil; table.target = nil
    }
    final class Table: NSTableView {
        weak var coordinator: Coordinator?
        override func mouseDown(with event: NSEvent) {
            let previous = selectedRow
            super.mouseDown(with: event)
            if selectedRow == previous { coordinator?.activate(self) }
        }
        override func keyDown(with event: NSEvent) {
            if [36, 76, 49].contains(event.keyCode),
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                coordinator?.activate(self)
            } else { super.keyDown(with: event) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let state: ReaderState
        private var revision = -1
        private var items = [ContentsItem]()
        private var selectedTarget: String?
        private var updatingSelection = false
        init(_ state: ReaderState) { self.state = state }
        func update(_ table: NSTableView) {
            updatingSelection = true
            defer { updatingSelection = false }
            let changed = revision != state.searchResultsRevision
            let previousRow = table.selectedRow
            let targetChanged = selectedTarget != state.selectedSearchTarget
            if changed {
                revision = state.searchResultsRevision
                items = state.searchResults
                // Fixed-height native rows only create views for the viewport.
                // Replacing the data does not build a SwiftUI Button per hit.
                table.reloadData()
            }
            if changed || targetChanged {
                selectedTarget = state.selectedSearchTarget
                if let target = selectedTarget, let row = items.firstIndex(where: { $0.target == target }) {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    if targetChanged || row != previousRow { table.scrollRowToVisible(row) }
                } else { table.deselectAll(nil) }
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("result")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = reused }
            else {
                cell = NSTableCellView(); cell.identifier = identifier
                let text = NSTextField(wrappingLabelWithString: "")
                text.maximumNumberOfLines = 2; text.lineBreakMode = .byTruncatingTail
                text.font = .systemFont(ofSize: NSFont.systemFontSize)
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text); cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    text.heightAnchor.constraint(lessThanOrEqualToConstant: 40)
                ])
            }
            cell.textField?.stringValue = items[row].title
            cell.toolTip = items[row].title
            return cell
        }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { items[row].title }
        func tableViewSelectionDidChange(_ notification: Notification) {
            if !updatingSelection, let table = notification.object as? NSTableView { activate(table) }
        }
        func activate(_ table: NSTableView) {
            let row = table.selectedRow
            // A pending SwiftUI update may still display the preceding query.
            guard revision == state.searchResultsRevision, items.indices.contains(row) else { return }
            state.navigate(.href(items[row].target))
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
            state?.closeFind()
            dismiss()
            parent?.makeKeyAndOrderFront(nil)
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
                if let rendered = try? await pages.previewImage(location, size: CGSize(width: 128, height: 160), rotation: rotation), !Task.isCancelled {
                    image = NSImage(cgImage: rendered, size: .zero)
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
            Button(L("Reading Settings…"), action: state.editTypography)
            Toggle(L("Use Changes as Defaults"), isOn: $state.typographyForAll)
            if state.isCHM {
                Toggle(L("Use document styles"), isOn: Binding(
                    get: { state.useDocumentCSS },
                    set: { state.useDocumentCSS = $0; state.applyTypography() }))
            }
            Group {
                ReaderFontPicker(selection: $state.font)
                .onChange(of: state.font) { _ in state.applyTypography(overrideDocumentStyles: true) }

                Stepper(String(format: L("Font %d pt"), Int(state.fontSize)), value: $state.fontSize, in: 10...36, step: 1)
                    .onChange(of: state.fontSize) { _ in state.applyTypography(overrideDocumentStyles: true) }

                Stepper(String(format: L("Line %.1f"), state.lineHeight), value: $state.lineHeight, in: 1...2.4, step: 0.1)
                    .onChange(of: state.lineHeight) { _ in state.applyTypography(overrideDocumentStyles: true) }
            }

            Stepper(String(format: L("Margin %d"), Int(state.contentMargins?.left ?? state.margin)), value: Binding(
                get: { state.contentMargins?.left ?? state.margin },
                set: { state.setCustomMargins(PageMargins(cssValues: [$0])) }), in: 0...96, step: 8)
        }
    }
}

struct ReaderFontPicker: View {
    @Binding var selection: String
    private static let supplementalFamilies: Set<String> = {
        do {
            let directory = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            return Set(files.flatMap { file in
                let faces = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []
                return faces.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
            })
        } catch {
            ReaderHelp.recordError("Unable to read supplemental font names: \(error.localizedDescription)")
            return []
        }
    }()
    static var families: [String] {
        Set(NSFontManager.shared.availableFontFamilies).union(supplementalFamilies).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        LabeledContent(L("Font")) {
            ReaderFontNamePicker(selection: $selection)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        }
    }
}
#endif
