#if os(macOS)
import SwiftUI
import SumraCore
import UniformTypeIdentifiers
import WebKit
import OSLog

private let documentOpenLog = Logger(subsystem: "com.leaf.reader", category: "document-open")

struct WindowPayload: Codable, Hashable {
    var id = UUID()
    var path: String?
    var position: ReadingPosition?
    var tabWith: Int?
    var tabIdentifier: String?
    // SwiftUI can retain the original openWindow value after its binding changes.
    // Copies of one request share the pending lease; loaded documents own theirs.
    private final class TemporaryInput {
        var directory: TemporaryDirectory?
        init(_ directory: TemporaryDirectory) { self.directory = directory }
    }
    private var temporaryInput: TemporaryInput?
    var temporary: TemporaryDirectory? {
        get { temporaryInput?.directory }
        set {
            if let newValue { temporaryInput = TemporaryInput(newValue) }
            else {
                temporaryInput?.directory = nil
                temporaryInput = nil
            }
        }
    }
    var recordsHistory: Bool?
    var tabColor: UInt32?
    var fileBookmark: Data?
    // A new bookmark window uses the same identity-aware opening as the sidebar.
    var bookmarkRequest: ReaderBookmark?
    // A folder-browsing request is transient, not a document/session payload.
    var browserFolder: URL?
    var selected: Bool?
    var active: Bool?
    // Startup metadata only; the native tab group owns order after restoration.
    var restoring = false
    enum CodingKeys: String, CodingKey { case id, path, position, tabWith, tabIdentifier, recordsHistory, tabColor, fileBookmark, selected, active }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(tabIdentifier, forKey: .tabIdentifier)
        try values.encodeIfPresent(recordsHistory, forKey: .recordsHistory)
        try values.encodeIfPresent(tabColor, forKey: .tabColor)
        try values.encodeIfPresent(selected, forKey: .selected)
        try values.encodeIfPresent(active, forKey: .active)
        // Scene restoration must not persist a private or temporary file path.
        if temporary == nil, recordsHistory != false {
            try values.encodeIfPresent(fileBookmark, forKey: .fileBookmark)
            try values.encodeIfPresent(path, forKey: .path)
            try values.encodeIfPresent(position, forKey: .position)
            try values.encodeIfPresent(tabWith, forKey: .tabWith)
        }
    }

    init(path: String? = nil, position: ReadingPosition? = nil, tabWith: Int? = nil, temporary: TemporaryDirectory? = nil, recordsHistory: Bool? = nil) {
        self.path = path
        self.position = position
        self.tabWith = tabWith
        self.temporary = temporary
        self.recordsHistory = recordsHistory
    }

    init(bookmark: ReaderBookmark) {
        self.init(path: bookmark.path, position: bookmark.position)
        fileBookmark = bookmark.fileBookmark
        bookmarkRequest = bookmark
    }
}

@MainActor
struct ReaderWindow: View {
    @Binding var payload: WindowPayload
    let application: ReaderApplicationDelegate
    @StateObject private var state = ReaderState()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("fullPathTitle") private var fullPathTitle = false
    @AppStorage("pageInTitle") private var pageInTitle = false

    init(payload: Binding<WindowPayload>, application: ReaderApplicationDelegate) {
        _payload = payload
        _state = StateObject(wrappedValue: ReaderState(restoring: payload.wrappedValue.restoring ? payload.wrappedValue : nil))
        self.application = application
    }

    private var windowTitle: String {
        guard let path = state.document?.url.path ?? state.restoredPayload?.path ?? payload.path else { return "Sumra" }
        return (fullPathTitle ? path : URL(fileURLWithPath: path).lastPathComponent) + (pageInTitle && state.count > 0 ? " — " + state.positionLabel : "")
    }

    func readerView(for state: ReaderState) -> ReaderView {
        // The selected file owns the scene before its opening task starts.
        // Once a load has run, its normal success/error state owns the view.
        ReaderView(state: state, awaitingDocumentOpen: payload.path != nil && state.generation == 0)
    }

    var body: some View {
        // Keep the window delegate and native tab placement mounted as a dormant
        // scene changes from its placeholder to the loaded document.
        ZStack {
            if !state.isWindowClosed {
                if state.restoredPayload != nil, !state.busy, state.error == nil, state.missingFile == nil { Color.clear }
                else { readerView(for: state) }
            }
        }
            .frame(minWidth: 560, minHeight: state.hasDocument ? 400 : 500)
            .ignoresSafeArea(.container, edges: state.extendsReadingUnderChrome ? .top : [])
            .navigationTitle(windowTitle)
            .background(WindowTabs(state: state, tabWith: payload.tabWith, identifier: payload.tabIdentifier, openingPath: payload.path, restorationID: payload.restoring ? payload.id : nil) {
                documentOpenLog.notice("scene-ready payload=\(payload.id.uuidString, privacy: .public) window=\(state.window?.windowNumber ?? -1, privacy: .public)")
                application.connect(state, canReuse: payload.path == nil)
                if payload.restoring, let window = state.window { ReaderWindows.restoredWindowReady(window, payload: payload) }
            })
            .focusedSceneObject(state)
            .onAppear {
                documentOpenLog.notice("scene-appeared payload=\(payload.id.uuidString, privacy: .public) window=\(state.window?.windowNumber ?? -1, privacy: .public)")
                state.tabColor = payload.tabColor
                if let folder = payload.browserFolder {
                    state.fileBrowserFolder = folder
                    state.fileBrowserRecordsHistory = payload.recordsHistory
                    state.showFiles = true
                    payload.browserFolder = nil
                }
                let opener = openWindow
                state.createWindow = { [opener] in opener(id: "reader", value: $0) }
                state.openAuxiliaryWindow = { [opener] in opener(id: $0) }
                application.connect(state, canReuse: payload.path == nil)
                ScreenshotHotkey.capture = { [opener] in
                    let receiver = ReaderWindows.states.first(where: { $0.window === NSApp.keyWindow }) ?? ReaderWindows.states.first ?? ReaderState()
                    receiver.createWindow = { [opener] in opener(id: "reader", value: $0) }
                    ReaderImages.capture(receiver)
                }
                if payload.id == SumraApp.restoring.first?.id {
                    let remaining = Array(SumraApp.restoring.dropFirst())
                    SumraApp.restoring = []
                    for saved in remaining { openWindow(id: "reader", value: saved) }
                }
            }
            .task(id: payload.path) {
                if payload.restoring {
                    if payload.active == true { state.activateRestoredDocument() }
                    return
                }
                if let bookmark = payload.bookmarkRequest {
                    payload.bookmarkRequest = nil
                    state.openBookmark(bookmark)
                    return
                }
                guard !state.busy,
                      state.document == nil,
                      let path = payload.path
                else { return }
                if let temporary = payload.temporary {
                    state.openTemporary(URL(fileURLWithPath: path), keeping: temporary, at: payload.position)
                } else if payload.recordsHistory == false {
                    state.openWithoutHistory(URL(fileURLWithPath: path), at: payload.position)
                } else if let position = payload.position {
                    state.open(URL(fileURLWithPath: path), at: position)
                } else { state.open(URL(fileURLWithPath: path)) }
            }
            .onChange(of: state.document?.url.path) {
                payload.path = $0
                // The loaded document owns the lease now; closed SwiftUI scene
                // values must not keep temporary attachments alive indefinitely.
                payload.temporary = nil
                payload.recordsHistory = state.recordsDocumentHistory
            }
            .onChange(of: state.tabColor) { payload.tabColor = $0 }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                state.persist()
            }
    }
}

struct WindowTabs: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    let tabWith: Int?
    let identifier: String?
    let openingPath: String?
    var restorationID: UUID? = nil
    let onWindowReady: () -> Void

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.state = state
        view.tabWith = tabWith
        view.groupIdentifier = identifier
        view.restorationID = restorationID
        view.openingPath = openingPath
        view.onWindowReady = onWindowReady
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.state = state
        view.openingPath = openingPath
        view.onWindowReady = onWindowReady
        view.updateDocumentProperties()
    }

    @MainActor
    final class HostView: NSView {
        weak var state: ReaderState?
        var tabWith: Int?
        var groupIdentifier: String?
        var restorationID: UUID?
        var openingPath: String?
        var onWindowReady: (() -> Void)?
        private var closeGuard: ReaderCloseGuard?
        private weak var guardedWindow: NSWindow?
        private var placed = false
        func updateDocumentProperties() {
            guard let window, state?.isWindowClosed != true else { return }
            let url = state?.document?.url
            if window.representedURL != url { window.representedURL = url }
            closeGuard?.openingPath = openingPath
            let home = closeGuard?.isHome == true
            let mode: NSWindow.TabbingMode = home || UserDefaults.standard.bool(forKey: "disableTabs") ? .disallowed : .preferred
            if window.tabbingMode != mode { window.tabbingMode = mode }
            if home, let group = window.tabGroup, group.windows.count > 1 { group.removeWindow(window) }
        }


        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard guardedWindow !== window else { return }
            NotificationCenter.default.removeObserver(self)
            if let previousWindow = guardedWindow, previousWindow.delegate === closeGuard {
                previousWindow.delegate = closeGuard?.previous
                if state?.window === previousWindow { state?.window = nil }
            }
            if let previousWindow = guardedWindow, previousWindow.nextResponder === closeGuard {
                previousWindow.nextResponder = closeGuard?.nextResponder
            }
            closeGuard = nil
            guardedWindow = nil
            guard let window else { return }

            let previous: NSWindowDelegate?
            if let installed = window.delegate as? ReaderCloseGuard { previous = installed.previous }
            else { previous = window.delegate }
            let guardDelegate = ReaderCloseGuard(state: state, previous: previous)
            guardDelegate.restorationID = restorationID ?? state?.restoredPayload?.id
            closeGuard = guardDelegate
            guardedWindow = window
            // SwiftUI's window controller handles the native tab-bar and tab
            // overview + actions before consulting its window delegate. Keep
            // that controller in the chain, after our document-first action.
            if let installed = window.nextResponder as? ReaderCloseGuard {
                guardDelegate.nextResponder = installed.nextResponder
            } else { guardDelegate.nextResponder = window.nextResponder }
            window.nextResponder = guardDelegate
            window.delegate = guardDelegate
            state?.window = window
            updateDocumentProperties()
            state?.applyTabColor()
            if !placed {
                placed = true
                let readers = ReaderWindows.states.compactMap(\.window).filter {
                    $0 !== window && ($0.delegate as? ReaderCloseGuard)?.isHome == false
                }
                let parent = tabWith.flatMap { number in readers.first { $0.windowNumber == number } }
                    ?? readers.first { $0.tabbingIdentifier == (groupIdentifier ?? "SumraReader") }
                window.tabbingIdentifier = groupIdentifier ?? parent?.tabbingIdentifier ?? "SumraReader"
                documentOpenLog.info("tab-place window=\(window.windowNumber, privacy: .public) requested-parent=\(self.tabWith ?? -1, privacy: .public) resolved-parent=\(parent?.windowNumber ?? -1, privacy: .public) enabled=\(window.tabbingMode != .disallowed, privacy: .public) existing-count=\(parent?.tabGroup?.windows.count ?? 0, privacy: .public)")
                if !guardDelegate.isHome, window.tabbingMode != .disallowed, let parent {
                    ReaderWindows.placeTab(window, beside: parent, restorationID: guardDelegate.restorationID)
                }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(deactivated), name: NSWindow.didResignKeyNotification, object: window)
            if window.isKeyWindow { ReaderWindows.activated(window) }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(closing),
                name: NSWindow.willCloseNotification,
                object: window
            )
            // File opening publishes SwiftUI state after native view installation.
            DispatchQueue.main.async { [weak self] in self?.onWindowReady?() }
        }

        @objc private func closing(_ notification: Notification) {
            if let state { ReaderWindows.rememberClosed(state) }
            state?.windowClosed()
        }

        @objc private func activated(_ notification: Notification) {
            if let window { ReaderWindows.activated(window) }
        }

        @objc private func deactivated(_ notification: Notification) { state?.persist() }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

@MainActor
final class ReaderCloseGuard: NSResponder, NSWindowDelegate, NSUserInterfaceValidations, NSSharingServiceDelegate {
    weak var state: ReaderState?
    var openingPath: String?
    var restorationID: UUID?
    var isHome: Bool { openingPath == nil && state?.document == nil && state?.restoredPayload == nil && state?.busy != true }
    // NSWindow caches forwarded notification selectors while this proxy is installed.
    let previous: NSWindowDelegate?
    private var closePending = false
    var emailService: NSSharingService?
    init(state: ReaderState?, previous: NSWindowDelegate?) {
        self.state = state
        self.previous = previous
        super.init()
    }
    required init?(coder: NSCoder) { previous = nil; super.init(coder: coder) }
    // Preserve reader selection commands when a sibling sidebar has focus.
    @objc func copy(_ sender: Any?) { state?.send(.copy) }
    override func selectAll(_ sender: Any?) { state?.send(.selectAll) }
    override func newWindowForTab(_ sender: Any?) {
        if let state { ReaderMenuCommand.newTab.run(state) }
    }
    @objc func toggleTabBar(_ sender: Any?) {
        guard let state, !state.usesCustomChrome else { return }
        state.window?.toggleTabBar(sender)
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { emailService = nil }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let message: String
        if let application = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!) {
            message = String(format: L("%1$@\n\nDefault email app: %2$@. Choose a default email app that supports file attachments, then try again."),
                             error.localizedDescription, FileManager.default.displayName(atPath: application.path))
        } else { message = error.localizedDescription }
        state?.error = message
        emailService = nil
    }
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        state?.window
    }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(newWindowForTab(_:)) { return ReaderMenuCommand.newTab.enabled(state) }
        if item.action == #selector(toggleTabBar(_:)) { return state?.window != nil && state?.usesCustomChrome == false }
        if item.action == #selector(copy(_:)) { return ReaderMenuCommand.copy.enabled(state) }
        if item.action == #selector(selectAll(_:)) { return ReaderMenuCommand.selectAll.enabled(state) }
        return (previous as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Let AppKit finish a synchronous approval inside its original tab
        // click. Only a pending edit/save needs to resume the close later.
        var insideDelegate = true, approved = false
        approveClose(sender) { allowed in
            if insideDelegate { approved = allowed }
            else if allowed { sender.close() }
        }
        insideDelegate = false
        return approved
    }
    func close(_ sender: NSWindow, completion: @escaping (Bool) -> Void) {
        approveClose(sender) { allowed in
            if allowed { sender.close() }
            completion(allowed)
        }
    }
    private func approveClose(_ sender: NSWindow, completion: @escaping (Bool) -> Void) {
        guard let state else { completion(previous?.windowShouldClose?(sender) ?? true); return }
        guard !closePending else { completion(false); return }
        closePending = true
        let documentID = state.document?.id, generation = state.generation
        state.confirmClose { [self] allowed in
            let approved = allowed && (previous?.windowShouldClose?(sender) ?? true)
                && state.document?.id == documentID && state.generation == generation
            closePending = false
            completion(approved)
        }
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
    }
}

@MainActor
final class ReaderApplicationDelegate: NSResponder, NSApplicationDelegate {
    let undoCommands = ReaderUndoCommands()
    private var keyMonitor: Any?
    private var routingNativeTabMenu = false
    private var terminationPending = false
    private var pendingFiles: [URL] = []
    private var pendingSyncTeX: [SyncTeXForwardRequest] = []
    private var syncTeXTasks: [String: Task<Void, Never>] = [:]
    private var createWindow: ((WindowPayload) -> Void)?
    private var hasFinishedLaunching = false
    private weak var emptyReader: ReaderState?

    func installTabResponder() {
        guard NSApp.nextResponder !== self else { return }
        nextResponder = NSApp.nextResponder
        NSApp.nextResponder = self
    }

    func removeTabResponder() {
        if NSApp.nextResponder === self { NSApp.nextResponder = nextResponder }
        nextResponder = nil
    }

    override func newWindowForTab(_ sender: Any?) {
        if let state = ReaderWindows.newTabState { ReaderMenuCommand.newTab.run(state) }
    }

    deinit {
        MainActor.assumeIsolated { removeTabResponder() }
        NotificationCenter.default.removeObserver(self)
    }

    // Finder can launch the app without creating an initial reader scene.
    // Commands installs the app-wide action without requiring a window first.
    func installWindowOpener(_ opener: @escaping (WindowPayload) -> Void) {
        guard createWindow == nil else { return }
        createWindow = opener
        documentOpenLog.notice("opener-ready")
        // Registration happens while SwiftUI builds commands. Open scenes only
        // after that update, also allowing an existing Home to connect first.
        Task { @MainActor [weak self] in self?.openPendingFiles() }
    }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let readers = ReaderWindows.states.filter { !$0.isWindowClosed }.compactMap(\.window)
        let front = application.orderedWindows.first { readers.contains($0) }
            ?? ReaderWindows.mru.lazy.compactMap { number in readers.first { $0.windowNumber == number } }.first
            ?? readers.first
        if let front {
            let selected = front.tabGroup?.selectedWindow
            let window = selected.flatMap { readers.contains($0) ? $0 : nil } ?? front
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // Shared system and auxiliary windows can keep hasVisibleWindows true
        // after the last reader closes. Only reader ownership counts here.
        guard let createWindow else { return true }
        createWindow(WindowPayload())
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        pendingFiles.append(contentsOf: files)
        documentOpenLog.notice("request-received count=\(urls.count, privacy: .public) files=\(files.count, privacy: .public) pending=\(self.pendingFiles.count, privacy: .public) launch-ready=\(self.hasFinishedLaunching, privacy: .public) opener-ready=\(self.createWindow != nil, privacy: .public)")
        for url in urls where url.scheme?.lowercased() == "sumra" {
            do { pendingSyncTeX.append(try SyncTeXForwardRequest(url: url)) }
            catch { presentSyncTeXError(error) }
        }
        openPendingFiles()
    }

    func connect(_ state: ReaderState, canReuse: Bool) {
        guard state.window != nil else { return }
        if canReuse { emptyReader = state }
        documentOpenLog.notice("reader-connected window=\(state.window?.windowNumber ?? -1, privacy: .public)")
        openPendingFiles()
    }

    // Let an initial Home connect during launch before opening pending books,
    // so a later empty Home cannot cover an already opened book.
    func finishLaunching() {
        hasFinishedLaunching = true
        documentOpenLog.notice("launch-finished")
        openPendingFiles()
    }

    private func openPendingFiles() {
        guard hasFinishedLaunching, let createWindow,
              !pendingFiles.isEmpty || !pendingSyncTeX.isEmpty else { return }
        // Finder and editor requests can arrive before SwiftUI installs a window.
        NSApp.activate(ignoringOtherApps: true)
        let urls = pendingFiles
        pendingFiles.removeAll()
        if !urls.isEmpty {
            documentOpenLog.notice("pending-handoff count=\(urls.count, privacy: .public)")
            ReaderWindows.open(urls, in: emptyReader, createWindow: createWindow)
            emptyReader = nil
        }
        let requests = pendingSyncTeX
        pendingSyncTeX.removeAll()
        for request in requests { openSyncTeX(request, createWindow: createWindow) }
    }

    private func openSyncTeX(_ request: SyncTeXForwardRequest, createWindow: @escaping (WindowPayload) -> Void) {
        let identity = request.identity
        syncTeXTasks[identity]?.cancel()
        let initialReader = SyncTeXForward.reader(for: request, among: ReaderWindows.states, preferred: NSApp.keyWindow)
        let pageHint = initialReader.map { $0.page + 1 } ?? 0
        syncTeXTasks[identity] = Task { [weak self] in
            do {
                let position = try await SyncTeXForward.position(for: request, pageHint: pageHint)
                guard let self else { return }
                // Resolve again after the background query: a reader may have
                // closed or switched documents while the index was parsed.
                if let state = SyncTeXForward.reader(for: request, among: ReaderWindows.states, preferred: NSApp.keyWindow) {
                    if state.document != nil { state.reload(at: position) }
                    else { state.open(request.pdf, at: position) }
                    state.window?.makeKeyAndOrderFront(nil)
                } else if let state = self.emptyReader, state.window != nil, state.document == nil, !state.busy {
                    self.emptyReader = nil
                    state.open(request.pdf, at: position)
                    state.window?.makeKeyAndOrderFront(nil)
                } else { createWindow(WindowPayload(path: request.pdf.path, position: position)) }
                self.syncTeXTasks.removeValue(forKey: identity)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.syncTeXTasks.removeValue(forKey: identity)
                self.presentSyncTeXError(error)
            }
        }
    }

    private func presentSyncTeXError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "SyncTeX"
        alert.informativeText = error.localizedDescription
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
    func applicationWillUpdate(_ notification: Notification) {
        undoCommands.update()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        installTabResponder()
        finishLaunching()
        installNativeTabMenuRouting()
        ScreenshotHotkey.restore()
        ReaderHelp.checkForUpdatesOnLaunch()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .otherMouseDown, .scrollWheel]) { [self] event in
            handleReaderEvent(event)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeTabResponder()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func installNativeTabMenuRouting() {
        NotificationCenter.default.addObserver(self, selector: #selector(tabMenuWillTrack(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(tabMenuItemChanged(_:)),
                                                   name: name, object: nil)
        }
    }

    @objc private func tabMenuWillTrack(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        routeNativeTabMenu(menu, for: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    @objc private func tabMenuItemChanged(_ notification: Notification) {
        guard !routingNativeTabMenu, let menu = notification.object as? NSMenu,
              let index = notification.userInfo?["NSMenuItemIndex"] as? Int,
              let item = menu.item(at: index) else { return }
        routeNativeTabMenuItem(item, for: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    func routeNativeTabMenu(_ menu: NSMenu, for window: NSWindow?) {
        for item in menu.items {
            routeNativeTabMenuItem(item, for: window)
            if let submenu = item.submenu { routeNativeTabMenu(submenu, for: window) }
        }
    }

    private func routeNativeTabMenuItem(_ item: NSMenuItem, for window: NSWindow?) {
        guard item.action == #selector(NSWindow.toggleTabBar(_:)) else { return }
        // Native tab commands may be inserted or rebuilt after main-menu
        // tracking begins. Route the changed item without updating its menu;
        // changing enabled state itself posts another appearance notification.
        routingNativeTabMenu = true
        defer { routingNativeTabMenu = false }
        let closeGuard = window?.delegate as? ReaderCloseGuard
        item.target = closeGuard
        if let closeGuard { item.isEnabled = closeGuard.validateUserInterfaceItem(item) }
    }

    func handleReaderEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .scrollWheel {
            guard NSApp.modalWindow == nil, let window = event.window,
                  let state = ReaderWindows.states.first(where: { $0.window === window }) else { return event }
            return state.handleScrollWheel(event) ? nil : event
        }
        if event.type == .flagsChanged {
            if !event.modifierFlags.contains(.control) { ReaderWindows.finishSmartSwitch() }
            return event
        }
        guard let window = event.window, NSApp.modalWindow == nil,
              let state = ReaderWindows.states.first(where: { $0.window === (window.parent ?? window) }) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let typing = ReaderWindows.isTyping(in: window, state: state)
        if event.type == .keyDown, !typing || !modifiers.intersection([.command, .control]).isEmpty,
           let overrides = (try? JSONDecoder().decode([String: String].self, from: Data((UserDefaults.standard.string(forKey: "shortcuts") ?? "{}").utf8))) {
            var flags: EventModifiers = []
            if modifiers.contains(.command) { flags.insert(.command) }
            if modifiers.contains(.control) { flags.insert(.control) }
            if modifiers.contains(.option) { flags.insert(.option) }
            if modifiers.contains(.shift) { flags.insert(.shift) }
            func matches(_ binding: String) -> Bool {
                guard let shortcut = readerShortcut(binding) else { return false }
                return shortcut.modifiers == flags && String(shortcut.key.character).lowercased() == event.characters(byApplyingModifiers: [])?.lowercased()
            }
            for command in ReaderMenuCommand.allCases where command.enabled(state) {
                // Standard editing menus target the native responder, including
                // modal text fields. Reader overrides belong only to the book.
                let nativeEditing = command == .copy || command == .selectAll
                if nativeEditing && typing { continue }
                let bindings = readerShortcutBindings(overrides[command.id] ?? command.defaultShortcut)
                let extra = nativeEditing ? bindings[...] : bindings.dropFirst()
                if extra.contains(where: matches) {
                    if command == .open {
                        chooseDocuments { urls in
                            ReaderWindows.open(urls, in: state) { state.createWindow?($0) }
                        }
                    } else { command.run(state) }
                    return nil
                }
            }
            for command in (try? ReaderConfiguredCommand.read(UserDefaults.standard.string(forKey: "customCommands") ?? "[]")) ?? [] where command.enabled(state) {
                if readerShortcutBindings(command.shortcut ?? "").contains(where: matches) { command.run(state); return nil }
            }
            for command in (try? ExternalReaderCommand.read(UserDefaults.standard.string(forKey: "externalCommands") ?? "[]")) ?? [] where command.enabled(state) {
                if readerShortcutBindings(command.shortcut ?? "").contains(where: matches) { command.run(state); return nil }
            }
        }
        guard state.hasDocument, !typing else { return event }
        if event.type == .keyDown, state.nativePDFAnnotationTool != nil, [36, 49, 53, 76].contains(event.keyCode) { return event }
        if event.type == .keyDown, event.keyCode == 53 {
            if state.presentationBlank != nil { state.presentationBlank = nil; return nil }
            if state.autoScroll { state.setAutoScroll(false); return nil }
            if state.presentation { ReaderMenuCommand.presentation.run(state); return nil }
            if state.showFind || state.searchSessionActive {
                state.closeFind()
                return nil
            }
        }
        if state.presentation, event.type == .keyDown, modifiers.isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b", ".": ReaderMenuCommand.blankBlack.run(state); return nil
            case "w", ",": ReaderMenuCommand.blankWhite.run(state); return nil
            case "l": state.laserPointer.toggle(); return nil
            case " ": state.presentationBlank = nil; state.turn(1); return nil
            default: break
            }
        }
        let readers: [NSView?] = [state.browserView, state.readerScrollView]
        let responder = window.firstResponder
        let readerFocused = (responder as? NSView).map { responder in
            readers.compactMap({ $0 }).contains { responder === $0 || responder.isDescendant(of: $0) }
        } ?? false
        // Paged canvases are replaced during navigation. Their SwiftUI move
        // handler can lose focus before the next canvas is ready, so consume
        // native arrows here and keep repeated input in the reader command queue.
        if event.type == .keyDown, modifiers.isEmpty,
           !state.keyboardLinkFollowing, !state.keyboardTextSelection,
           state.nativePDFAnnotationTool?.isPlacement != true,
           case .pages = state.document?.content,
           readerFocused || (window === state.window && (responder == nil || responder === window)) {
            switch event.keyCode {
            case 123: state.scroll(.left); return nil
            case 124: state.scroll(.right); return nil
            case 125: state.scroll(.down); return nil
            case 126: state.scroll(.up); return nil
            default: break
            }
        }
        guard readerFocused else { return event }
        if event.type == .otherMouseDown, event.buttonNumber == 2 { state.setAutoScroll(!state.autoScroll); return nil }
        guard event.type == .keyDown, modifiers.isEmpty,
              !state.keyboardLinkFollowing, !state.keyboardTextSelection else { return event }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h": state.scroll(.left); return nil
        case "j": state.scroll(.down); return nil
        case "k": state.scroll(.up); return nil
        case "l": state.scroll(.right); return nil
        default: break
        }
        return event
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        var decision: NSApplication.TerminateReply?
        var insideDelegate = true
        prepareToTerminate { approved in
            self.terminationPending = false
            if insideDelegate { decision = approved ? .terminateNow : .terminateCancel }
            else { sender.reply(toApplicationShouldTerminate: approved) }
        }
        insideDelegate = false
        return decision ?? .terminateLater
    }

    private func prepareToTerminate(completion: @escaping (Bool) -> Void) {
        ReaderWindows.isTerminating = false
        let states = ReaderWindows.states
        var approved: [(ReaderState, UUID?, Int, Int)] = []
        func confirmNext() {
            if approved.count < states.count {
                let state = states[approved.count]
                state.confirmClose { allowed in
                    guard allowed else { completion(false); return }
                    approved.append((state, state.document?.id, state.generation, state.editRevision))
                    confirmNext()
                }
                return
            }
            // A save or modal form editor can pump events in another window.
            let current = ReaderWindows.states
            guard current.allSatisfy({ state in
                approved.contains { previous, id, generation, revision in
                    state === previous && state.document?.id == id && state.generation == generation && state.editRevision == revision && state.nativePDFFormEditor == nil
                }
            }) else { completion(false); return }
            ReaderWindows.saveSession(current)
            ReaderWindows.isTerminating = true
            completion(true)
        }
        confirmNext()
    }
}

enum DocumentOpenBehavior: String, CaseIterable, Identifiable {
    case newWindow, newTab, replaceCurrent

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newWindow: return L("Open in New Window")
        case .newTab: return L("Open in New Tab")
        case .replaceCurrent: return L("Replace Current Document")
        }
    }

    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "documentOpenBehavior") ?? "") ?? .newWindow
    }
}

// AppKit owns the actual tabs and close lifecycle. Only MRU order and saved
// positions belong to the app; there is no parallel tab model or view cache.
@MainActor
enum ReaderWindows {
    fileprivate static var mru: [Int] = []
    fileprivate static var smartOrder: [Int]?
    private static var restorationPayloads: [WindowPayload] = []
    private static var restorationWindows: [UUID: NSWindow] = [:]
    private static weak var restorationSelection: NSWindow?
    static var isRestoringWindows: Bool { !restorationPayloads.isEmpty }
    static var isTerminating = false
    static var states: [ReaderState] { NSApp.windows.compactMap { ($0.delegate as? ReaderCloseGuard)?.state } }

    static var newTabState: ReaderState? {
        let readers = states
        for window in NSApp.orderedWindows where window.delegate is ReaderCloseGuard {
            guard let group = window.tabGroup, group.isOverviewVisible,
                  let selected = group.selectedWindow,
                  let state = readers.first(where: { $0.window === selected }) else { continue }
            return state
        }
        if let active = readers.first(where: { $0.window === NSApp.keyWindow }) { return active }
        return mru.lazy.compactMap { number in readers.first { $0.window?.windowNumber == number } }.first
    }

    static func open(_ urls: [URL], in state: ReaderState?, recordsHistory: Bool = true,
                     behavior: DocumentOpenBehavior = .current,
                     createWindow: (WindowPayload) -> Void) {
        let state = state ?? NSApp.orderedWindows.compactMap { ($0.delegate as? ReaderCloseGuard)?.state }.first
        let opensInTabs = behavior == .newTab && !UserDefaults.standard.bool(forKey: "disableTabs")
        let tabWith = opensInTabs ? state?.window?.windowNumber : nil
        let tabIdentifier = opensInTabs && tabWith == nil ? UUID().uuidString : nil
        for (index, url) in urls.enumerated() {
            // Home always receives the first file. Replacing a loaded document
            // still goes through ReaderState's unsaved-changes confirmation.
            if index == 0, let state, state.window != nil,
               state.restoredPayload == nil, !state.busy,
               state.document == nil || behavior == .replaceCurrent {
                documentOpenLog.notice("route-reuse window=\(state.window?.windowNumber ?? -1, privacy: .public)")
                if recordsHistory { state.open(url) }
                else { state.openWithoutHistory(url) }
                state.window?.makeKeyAndOrderFront(nil)
            } else {
                var payload = WindowPayload(path: url.path, tabWith: tabWith, recordsHistory: recordsHistory ? nil : false)
                payload.tabIdentifier = tabIdentifier ?? (opensInTabs ? nil : "Sumra-" + UUID().uuidString)
                documentOpenLog.notice("route-create payload=\(payload.id.uuidString, privacy: .public)")
                createWindow(payload)
            }
        }
    }

    static func close(_ window: NSWindow) {
        guard window.styleMask.contains(.closable), window.attachedSheet == nil else { return }
        if let owner = window.delegate as? ReaderCloseGuard { owner.close(window) { _ in } }
        else { window.performClose(nil) }
    }

    static func leaveOverview(of window: NSWindow?, then action: @escaping @MainActor () -> Void) {
        guard let group = window?.tabGroup, group.isOverviewVisible else { action(); return }
        NSAnimationContext.runAnimationGroup { _ in
            group.isOverviewVisible = false
        } completionHandler: {
            Task { @MainActor in action() }
        }
    }

    static func showHome(from state: ReaderState) {
        if let home = states.first(where: {
            !$0.isWindowClosed && ($0.window?.delegate as? ReaderCloseGuard)?.isHome == true
        })?.window {
            if home.isMiniaturized { home.deminiaturize(nil) }
            home.makeKeyAndOrderFront(nil)
        } else { state.createWindow?(WindowPayload()) }
    }

    static func isTyping(in window: NSWindow, state: ReaderState) -> Bool {
        if state.nativePDFFormEditor?.ownsInput(window.firstResponder) == true { return true }
        if (window.firstResponder as? NSTextView)?.isEditable == true { return true }
        guard let web = state.browserView, let responder = window.firstResponder as? NSView,
              responder === web || responder.isDescendant(of: web),
              let owner = web.navigationDelegate as? BrowserReader.Coordinator, owner.isCurrent else { return false }
        return owner.textInputFocused
    }

    static func activated(_ window: NSWindow) {
        if isRestoringWindows {
            // Opening each scene can make it key. If the user explicitly
            // selects a tab while the last scenes attach, keep that choice.
            if let event = NSApp.currentEvent, event.type == .leftMouseDown,
               let source = event.window, let group = window.tabGroup, source.tabGroup === group {
                restorationSelection = window
            }
        } else {
            if let state = states.first(where: { $0.window === window }) {
                state.activateRestoredDocument()
                state.offerFileRelocation()
            }
        }
        guard smartOrder == nil else { return }
        let valid = Set(states.compactMap { $0.window?.windowNumber })
        mru.removeAll { $0 == window.windowNumber || !valid.contains($0) }
        mru.insert(window.windowNumber, at: 0)
    }
    static func finishSmartSwitch() {
        smartOrder = nil
        if let window = NSApp.keyWindow { activated(window) }
    }
    static func payload(_ state: ReaderState) -> WindowPayload? {
        guard let path = state.document?.url.path ?? state.restoredPayload?.path else { return nil }
        var payload = WindowPayload(path: path, position: state.document == nil ? state.restoredPayload?.position : state.filePosition,
                                    temporary: state.document?.sourceTemporary, recordsHistory: state.recordsDocumentHistory)
        payload.tabColor = state.tabColor
        if state.recordsDocumentHistory, state.document?.sourceTemporary == nil {
            payload.fileBookmark = state.document == nil ? state.restoredPayload?.fileBookmark : state.fileBookmark
        }
        return payload
    }

    static var savedTabGroupKeys: [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("tabGroup:") && !saved($0).isEmpty }.sorted()
    }

    static func restoreTabGroup(_ saved: [WindowPayload], in state: ReaderState?,
                                behavior: DocumentOpenBehavior = .current,
                                createWindow: @escaping (WindowPayload) -> Void) {
        guard !saved.isEmpty else { return }
        let tabsEnabled = !UserDefaults.standard.bool(forKey: "disableTabs")
        let reuse = state?.window != nil && state?.busy != true &&
            (behavior == .replaceCurrent || (state?.document == nil && state?.restoredPayload == nil))
        let parent = tabsEnabled && (reuse || behavior == .newTab) ? state?.window : nil
        let identifier = parent?.tabbingIdentifier ?? "Sumra-" + UUID().uuidString
        var payloads = saved.map { saved -> WindowPayload in
            var payload = saved
            payload.id = UUID(); payload.tabWith = parent?.windowNumber
            payload.tabIdentifier = tabsEnabled ? identifier : "Sumra-" + UUID().uuidString
            return payload
        }
        let openRemaining: ([WindowPayload], NSWindow?) -> Void = { remaining, selected in
            for payload in prepareRestoration(remaining, selecting: selected) { createWindow(payload) }
        }
        if reuse, let state {
            let first = payloads.removeFirst()
            state.open(first) {
                state.window?.makeKeyAndOrderFront(nil)
                openRemaining(payloads, first.selected == true ? state.window : nil)
            }
        } else { openRemaining(payloads, nil) }
    }

    static func prepareRestoration(_ payloads: [WindowPayload], selecting selected: NSWindow? = nil) -> [WindowPayload] {
        restorationPayloads = payloads
        restorationWindows = [:]
        restorationSelection = selected
        guard !payloads.isEmpty else { return [] }
        let activeID = payloads.first(where: { $0.active == true })?.id
            ?? payloads.first(where: { $0.selected == true })?.id ?? payloads[0].id
        let windows = payloads.map { saved -> WindowPayload in
            var payload = saved
            payload.restoring = true
            payload.active = selected == nil && payload.id == activeID
            return payload
        }
        // Parse the current document first while AppKit assembles its other tabs.
        return windows.filter { $0.id == activeID } + windows.filter { $0.id != activeID }
    }

    static func placeTab(_ window: NSWindow, beside parent: NSWindow, restorationID: UUID?) {
        let siblings = parent.tabGroup?.windows ?? [parent]
        guard !siblings.contains(window) else { return }
        if let restorationID, let index = restorationPayloads.firstIndex(where: { $0.id == restorationID }) {
            // An independent native window can have no tab group yet. Add to
            // the actual neighboring window so AppKit creates the group too.
            let following = Set(restorationPayloads.dropFirst(index + 1).map(\.id))
            if let next = siblings.first(where: { ($0.delegate as? ReaderCloseGuard)?.restorationID.map(following.contains) == true }) {
                next.addTabbedWindow(window, ordered: .below)
            } else {
                (siblings.last ?? parent).addTabbedWindow(window, ordered: .above)
            }
        } else {
            parent.addTabbedWindow(window, ordered: .above)
        }
        documentOpenLog.info("tab-placed window=\(window.windowNumber, privacy: .public) parent=\(parent.windowNumber, privacy: .public) group-count=\(parent.tabGroup?.windows.count ?? 0, privacy: .public)")
    }

    static func restoredWindowReady(_ window: NSWindow, payload: WindowPayload) {
        guard restorationPayloads.contains(where: { $0.id == payload.id }) else { return }
        restorationWindows[payload.id] = window
        guard restorationWindows.count == restorationPayloads.count else { return }
        let saved = restorationPayloads, windows = restorationWindows
        // Incidental key-window changes during assembly must not launch a
        // background parser. Apply the saved selection once all scenes are ready.
        for payload in saved where payload.selected == true {
            if let window = windows[payload.id] { window.tabGroup?.selectedWindow = window }
        }
        restorationPayloads = []
        restorationWindows = [:]
        let selected = restorationSelection
        restorationSelection = nil
        let active = saved.first(where: { $0.active == true })
            ?? saved.first(where: { $0.selected == true }) ?? saved.first
        if let window = selected ?? active.flatMap({ windows[$0.id] }) {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            activated(window)
        }
    }
    static func rememberClosed(_ state: ReaderState) {
        guard !isTerminating, state.recordsDocumentHistory, let payload = payload(state) else { return }
        var closed = saved("closedDocuments")
        closed.append(payload)
        save(Array(closed.suffix(20)), key: "closedDocuments")
    }
    static func saved(_ key: String) -> [WindowPayload] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([WindowPayload].self, from: $0) } ?? []
    }
    static func save(_ windows: [WindowPayload], key: String) {
        let restorable = windows.filter { $0.path != nil && $0.temporary == nil && $0.recordsHistory != false }
        if let data = try? JSONEncoder().encode(restorable) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func saveSession(_ states: [ReaderState]) {
        guard UserDefaults.standard.bool(forKey: "restoreSession") else {
            UserDefaults.standard.removeObject(forKey: "session"); return
        }
        var visited = Set<Int>(), windows: [WindowPayload] = []
        let activeWindow = NSApp.keyWindow ?? states.compactMap(\.window).first { $0.windowNumber == mru.first }
        for state in states {
            guard let window = state.window, !visited.contains(window.windowNumber) else { continue }
            let identifier = "Sumra-" + UUID().uuidString
            for tab in window.tabGroup?.windows ?? [window] {
                visited.insert(tab.windowNumber)
                guard let reader = states.first(where: { $0.window === tab }), reader.recordsDocumentHistory, var payload = payload(reader) else { continue }
                payload.tabIdentifier = identifier
                payload.selected = tab === (window.tabGroup?.selectedWindow ?? window)
                payload.active = tab === activeWindow
                windows.append(payload)
            }
        }
        save(windows, key: "session")
    }
}

@MainActor
enum ReaderFiles {
    static let recentDocumentsChanged = Notification.Name("SumraRecentDocumentsChanged")
    private static func identity(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // A renamed or removed leaf must still resolve aliases in its existing parent.
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath().path
    }
    private struct OpenRecord: Codable {
        var count: Int
        var lastOpened: Date
        var fileBookmark: Data?
        var browseFolder: Bool?

        func count(at date: Date) -> Int {
            let weeks = Int(date.timeIntervalSinceReferenceDate / 604_800) - Int(lastOpened.timeIntervalSinceReferenceDate / 604_800)
            return count >> max(0, weeks)
        }
    }
    private static var history: [String: OpenRecord] {
        UserDefaults.standard.data(forKey: "documentOpenHistory")
            .flatMap { try? JSONDecoder().decode([String: OpenRecord].self, from: $0) } ?? [:]
    }
    private static func saveHistory(_ records: [String: OpenRecord]) {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: "documentOpenHistory") }
    }
    static var pinned: [String] { UserDefaults.standard.stringArray(forKey: "pinnedDocuments") ?? [] }
    static func isPinned(_ url: URL) -> Bool { pinnedURLs(in: [url]).contains(url) }
    static func pinnedURLs(in urls: [URL]) -> Set<URL> {
        let keys = Set(pinned.map(identity))
        if keys.isEmpty { return [] }
        return Set(urls.filter { keys.contains(identity($0.path)) })
    }
    static var recent: [URL] { ordered(frequentlyRead: false) }

    // Sumatra FileHistory.cpp / AppSettings.cpp at 012d997f: pinned names first,
    // then frequency (halved weekly), with recency breaking equal counts.
    static func ordered(frequentlyRead: Bool, at date: Date = Date()) -> [URL] {
        let records = history, pinned = Set(Self.pinned.map(identity))
        let saved = records.keys.sorted {
            if records[$0]!.lastOpened != records[$1]!.lastOpened { return records[$0]!.lastOpened > records[$1]!.lastOpened }
            return $0 < $1
        }.map { URL(fileURLWithPath: $0) }
        // Keep the opened path for reading-position keys; AppKit may return its resolved alias.
        var recorded: [String: (url: URL, count: Int)] = [:]
        for url in saved {
            let key = identity(url.path), count = records[url.path]!.count(at: date)
            if recorded[key] == nil { recorded[key] = (url, count) }
            else { recorded[key]!.count += count }
        }
        var seen = Set<String>()
        let urls = (Self.pinned.map { URL(fileURLWithPath: $0) } + NSDocumentController.shared.recentDocumentURLs + saved)
            .compactMap { url -> (url: URL, key: String)? in
                let key = identity(url.path)
                return seen.insert(key).inserted ? (recorded[key]?.url ?? url, key) : nil
            }
        return urls.enumerated().sorted { left, right in
            let a = left.element.url, b = right.element.url
            let aPinned = pinned.contains(left.element.key), bPinned = pinned.contains(right.element.key)
            if aPinned != bPinned { return aPinned }
            if aPinned {
                let order = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
                if order != .orderedSame { return order == .orderedAscending }
            } else if frequentlyRead {
                let aCount = recorded[left.element.key]?.count ?? 0, bCount = recorded[right.element.key]?.count ?? 0
                if aCount != bCount { return aCount > bCount }
            }
            return left.offset < right.offset
        }.map { $0.element.url }
    }
    static func opensInFolderBrowser(_ url: URL) -> Bool {
        let key = identity(url.path)
        return history.first { identity($0.key) == key }?.value.browseFolder == true
    }
    static func openRecent(_ url: URL, in state: ReaderState?, recordsHistory: Bool = true,
                           behavior: DocumentOpenBehavior? = nil, browseFolder: Bool = false,
                           createWindow: (WindowPayload) -> Void) {
        guard browseFolder || opensInFolderBrowser(url) else {
            if behavior == .newWindow {
                var payload = WindowPayload(path: url.path, recordsHistory: recordsHistory ? nil : false)
                payload.tabIdentifier = "Sumra-" + UUID().uuidString
                createWindow(payload)
                return
            }
            ReaderWindows.open([url], in: state, recordsHistory: recordsHistory,
                               behavior: behavior ?? .current, createWindow: createWindow)
            return
        }
        if let state, behavior == nil || behavior == .replaceCurrent {
            state.fileBrowserFolder = url
            state.fileBrowserRecordsHistory = recordsHistory ? nil : false
            state.showFiles = true
            state.window?.makeKeyAndOrderFront(nil)
        } else {
            var payload = WindowPayload(recordsHistory: recordsHistory ? nil : false)
            payload.browserFolder = url
            if behavior == .newTab, !UserDefaults.standard.bool(forKey: "disableTabs") {
                payload.tabWith = state?.window?.windowNumber
                if payload.tabWith == nil { payload.tabIdentifier = UUID().uuidString }
            } else { payload.tabIdentifier = "Sumra-" + UUID().uuidString }
            createWindow(payload)
        }
    }
    static func recordBrowse(_ url: URL, recordsHistory: Bool, at date: Date = Date()) {
        record(url, recordsHistory: recordsHistory, browsing: true, at: date)
    }
    static func recordOpen(_ document: ReadingDocument, recordsHistory: Bool, at date: Date = Date()) {
        guard document.sourceTemporary == nil else { return }
        record(document.url, recordsHistory: recordsHistory, browsing: false, at: date)
    }
    private static func record(_ url: URL, recordsHistory: Bool, browsing: Bool, at date: Date) {
        guard recordsHistory, !UserDefaults.standard.bool(forKey: "disableHistory") else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        NativeReadingPerformance.mark("history-record-entry", persistent: true)
        defer { NativeReadingPerformance.mark("history-record-return", started: started, persistent: true) }
        var records = history
        let key = identity(url.path), aliases = records.keys.filter { identity($0) == key }
        let count = aliases.reduce(browsing ? 0 : 1) { $0 + records[$1]!.count(at: date) }
        // Browsing a previously read image folder must retain its reader destination.
        let browseFolder = browsing && (aliases.isEmpty || aliases.allSatisfy { records[$0]!.browseFolder == true })
        for path in aliases { records.removeValue(forKey: path) }
        records[url.path] = OpenRecord(count: count, lastOpened: date, fileBookmark: DocumentFileIdentity.bookmark(for: url),
                                       browseFolder: browseFolder ? true : nil)
        let pinned = Set(Self.pinned.map(identity))
        let unpinned = records.keys.filter { !pinned.contains(identity($0)) }.sorted { records[$0]!.lastOpened > records[$1]!.lastOpened }
        for path in unpinned.dropFirst(1000) { records.removeValue(forKey: path) }
        let recentStarted = DispatchTime.now().uptimeNanoseconds
        NativeReadingPerformance.mark("history-recent-entry", persistent: true)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NativeReadingPerformance.mark("history-recent-return", started: recentStarted, persistent: true)
        saveHistory(records)
        NotificationCenter.default.post(name: recentDocumentsChanged, object: nil)
    }
    static func clearHistory() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        UserDefaults.standard.removeObject(forKey: "documentOpenHistory")
        UserDefaults.standard.removeObject(forKey: "closedDocuments")
        NotificationCenter.default.post(name: recentDocumentsChanged, object: nil)
    }
    static func pin(_ url: URL) {
        var paths = pinned
        let key = identity(url.path)
        if paths.contains(where: { identity($0) == key }) { paths.removeAll { identity($0) == key } } else { paths.insert(url.path, at: 0) }
        UserDefaults.standard.set(paths, forKey: "pinnedDocuments")
    }
    static func setRecent(_ urls: [URL]) {
        let controller = NSDocumentController.shared
        controller.clearRecentDocuments(nil)
        for url in urls.reversed() { controller.noteNewRecentDocumentURL(url) }
        NotificationCenter.default.post(name: recentDocumentsChanged, object: nil)
    }
    static func forget(_ url: URL) { forget(Set([url.path])) }
    private static func forget(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        var records = history
        let keys = Set(paths.map(identity)), recent = NSDocumentController.shared.recentDocumentURLs
        let matches: (String) -> Bool = { keys.contains(identity($0)) }
        let aliases = paths.union(records.keys).union(pinned).union(recent.map(\.path)).filter(matches)
        setRecent(recent.filter { !matches($0.path) })
        for path in aliases {
            records.removeValue(forKey: path)
            UserDefaults.standard.removeObject(forKey: "position:" + path)
        }
        saveHistory(records)
        UserDefaults.standard.set(pinned.filter { !matches($0) }, forKey: "pinnedDocuments")
        ReaderWindows.save(ReaderWindows.saved("closedDocuments").filter { !matches($0.path ?? "") }, key: "closedDocuments")
    }
    static func resolve(_ url: URL, bookmark: Data? = nil) -> URL? {
        if let bookmark = bookmark ?? history[url.path]?.fileBookmark { return DocumentFileIdentity.resolve(bookmark) }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func migrate(_ source: URL, to destination: URL, recordsHistory: Bool) {
        guard recordsHistory, !UserDefaults.standard.bool(forKey: "disableHistory") else { return }
        let defaults = UserDefaults.standard
        let key = identity(source.path)
        let aliases = Set(history.keys).union(pinned).union(NSDocumentController.shared.recentDocumentURLs.map(\.path)).union([source.path])
            .filter { identity($0) == key }
        for state in ReaderWindows.states {
            for alias in aliases { state.retargetRestoredFile(from: URL(fileURLWithPath: alias), to: destination) }
        }
        for key in defaults.dictionaryRepresentation().keys {
            if let alias = aliases.first(where: { path in
                key == "position:" + path || key.hasPrefix("position:" + path + ":markdown:") || key == "bookmark:" + path || key == "markdownRenderer:" + path
            }) {
                let replacement = key.replacingOccurrences(of: alias, with: destination.path)
                guard replacement != key else { continue }
                defaults.set(defaults.object(forKey: key), forKey: replacement)
                defaults.removeObject(forKey: key)
            }
        }
        if let data = defaults.data(forKey: "bookmarks"), var bookmarks = try? JSONDecoder().decode([ReaderBookmark].self, from: data) {
            for index in bookmarks.indices where identity(bookmarks[index].path) == key {
                bookmarks[index].path = destination.path
                bookmarks[index].fileBookmark = DocumentFileIdentity.bookmark(for: destination)
            }
            if let data = try? JSONEncoder().encode(bookmarks) { defaults.set(data, forKey: "bookmarks") }
            for state in ReaderWindows.states { state.bookmarks = bookmarks }
        }
        setRecent(NSDocumentController.shared.recentDocumentURLs.map { identity($0.path) == key ? destination : $0 })
        var records = history
        let historyAliases = records.keys.filter { identity($0) == key }
        if let date = historyAliases.compactMap({ records[$0]?.lastOpened }).max() {
            let count = historyAliases.reduce(0) { $0 + records[$1]!.count(at: date) }
            let browseFolder = historyAliases.allSatisfy { records[$0]!.browseFolder == true }
            for path in historyAliases { records.removeValue(forKey: path) }
            records[destination.path] = OpenRecord(count: count, lastOpened: date, fileBookmark: DocumentFileIdentity.bookmark(for: destination),
                                                   browseFolder: browseFolder ? true : nil)
            saveHistory(records)
        }
        UserDefaults.standard.set(pinned.map { identity($0) == key ? destination.path : $0 }, forKey: "pinnedDocuments")
        let savedKeys = ["closedDocuments", "session"] + defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("tabGroup:") }
        for savedKey in savedKeys {
            var windows = ReaderWindows.saved(savedKey)
            for index in windows.indices where identity(windows[index].path ?? "") == key {
                windows[index].path = destination.path
                windows[index].fileBookmark = DocumentFileIdentity.bookmark(for: destination)
            }
            ReaderWindows.save(windows, key: savedKey)
        }
    }
    static func removeMissing() {
        forget(Set(recent.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.path)))
    }
}

@MainActor
struct ReaderCommandSheets: ViewModifier {
    @ObservedObject var state: ReaderState
    let open: () -> Void
    @State private var pendingAction: (() -> Void)?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $state.showPalette) {
            CommandPalette(state: state, open: open, perform: { pendingAction = $0 })
        }
        .sheet(isPresented: $state.showFiles, onDismiss: {
            // A deferred context action may already have requested the next sheet.
            if !state.showFiles {
                state.fileBrowserFolder = nil
                state.fileBrowserRecordsHistory = nil
            }
        }) {
            DocumentFileBrowser(state: state, folder: state.fileBrowserFolder ?? state.document?.url.deletingLastPathComponent(),
                                dismissOnOpen: true, recordsHistory: state.fileBrowserRecordsHistory,
                                performOpen: { pendingAction = $0 })
                .frame(width: 620, height: 460)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { notification in
            guard notification.object as? NSWindow === state.window else { return }
            let action = pendingAction
            pendingAction = nil
            action?()
        }
    }
}

@MainActor
struct DocumentFileBrowser: View {
    @ObservedObject var state: ReaderState
    @State private var folder: URL?
    @State private var entries: [URL] = []
    @State private var query = ""
    @State private var revision = 0
    @State private var recentFiles: [URL] = []
    @State private var pinnedFiles = Set<URL>()
    @State private var historyInputs: HistoryInputs?
    @State private var thumbnails = ReaderFileThumbnails()
    @State private var viewChange: UInt64?
    @State private var selected: URL?
    @State private var focus: Focus?
    private enum Focus { case search, files }
    private struct HistoryInputs: Equatable {
        let history: Data?
        let pinned: [String]
        let frequentlyRead: Bool
    }
    @AppStorage("homePageSortByFrequentlyRead") private var frequentlyRead = false
    @AppStorage("homePageViewMode") private var viewMode = "thumbnails"
    let dismissOnOpen: Bool
    let recordsHistory: Bool?
    let performOpen: (@escaping () -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    init(state: ReaderState, folder: URL? = nil, dismissOnOpen: Bool = false, recordsHistory: Bool? = nil,
         performOpen: @escaping (@escaping () -> Void) -> Void = { $0() }) {
        self.state = state
        self.dismissOnOpen = dismissOnOpen
        self.recordsHistory = recordsHistory
        self.performOpen = performOpen
        _folder = State(initialValue: folder)
    }
    private var fileViewSelection: Binding<String> {
        Binding(get: { viewMode }, set: { mode in
            viewChange = DispatchTime.now().uptimeNanoseconds
            NativeReadingPerformance.mark("home-view-request", pagesIdentity: ObjectIdentifier(thumbnails),
                                          flags: mode == "thumbnails" ? 1 : 0)
            viewMode = mode
        })
    }
    var body: some View {
        let _ = revision
        let files = (folder == nil ? recentFiles : entries)
            .filter { query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(folder?.lastPathComponent ?? L("Recent Documents"), systemImage: folder == nil ? "clock" : "folder")
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let folder {
                        Text(folder.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                ReaderFileSearchInput(text: $query, focused: Binding(
                    get: { focus == .search },
                    set: { focused in
                        if focused { focus = .search }
                        else if focus == .search { focus = nil }
                    }), down: {
                        if !files.isEmpty { selected = selected ?? files.first; focus = .files }
                    }, submit: { if let url = selected ?? files.first { open(url) } })
                    .frame(minWidth: 120, idealWidth: 200, maxWidth: 200).frame(height: 24)
                if folder == nil {
                    Menu {
                        Button { frequentlyRead = false } label: {
                            Label(L("Recently Opened"), systemImage: frequentlyRead ? "clock" : "checkmark")
                        }
                        Button { frequentlyRead = true } label: {
                            Label(L("Frequently Read"), systemImage: frequentlyRead ? "checkmark" : "book")
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L("Sort Documents")).accessibilityLabel(L("Sort Documents"))
                }
                Picker(L("File View"), selection: fileViewSelection) {
                    Image(systemName: "list.bullet").tag("list").help(L("List"))
                    Image(systemName: "square.grid.2x2").tag("thumbnails").help(L("Thumbnails"))
                }.labelsHidden().pickerStyle(.segmented).frame(width: 64)
            }
            HStack(spacing: 8) {
                if folder != nil {
                    Button { folder = nil } label: { Label(L("Recent Documents"), systemImage: "clock") }
                }
                Button {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                    panel.directoryURL = folder ?? state.document?.url.deletingLastPathComponent()
                    if panel.runModal() == .OK { folder = panel.url }
                } label: { Label(L("Browse Folder…"), systemImage: "folder") }
                if let folder {
                    Divider().frame(height: 16)
                    Button { self.folder = folder.deletingLastPathComponent() } label: { Image(systemName: "arrow.up") }
                        .help(L("Parent folder")).accessibilityLabel(L("Parent folder"))
                }
                Spacer()
                if let folder {
                    Button { openDocument(folder) } label: {
                        Label(L("Read Images as Pages"), systemImage: "book")
                    }
                }
                if folder == nil {
                    Menu {
                        Button(L("Remove Missing Files")) { ReaderFiles.removeMissing(); revision += 1 }
                        Button(L("Clear History")) { ReaderFiles.clearHistory(); revision += 1 }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L("History Actions")).accessibilityLabel(L("History Actions"))
                }
            }.controlSize(.small).buttonStyle(.borderless)
            GeometryReader { geometry in
                let columns = viewMode == "thumbnails" ? max(1, Int(geometry.size.width / 164)) : 1
                ScrollViewReader { proxy in
                    ScrollView {
                        let thumbnails = viewMode == "thumbnails"
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 148, maximum: thumbnails ? 190 : .infinity), spacing: 16), count: columns), spacing: thumbnails ? 20 : 2) {
                            ForEach(files, id: \.self) { url in
                                fileItem(url, thumbnail: thumbnails)
                                    .padding(thumbnails ? 8 : 10)
                                    .accessibilityAddTraits(selected == url && focus == .files ? .isSelected : [])
                                    .background(selected == url && focus == .files ? Color.accentColor.opacity(0.15) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(8)
                    }
                    .background(ReaderFileKeys(performanceOwner: ObjectIdentifier(thumbnails),
                        viewChange: viewChange, thumbnails: viewMode == "thumbnails",
                        focused: Binding(
                        get: { focus == .files },
                        set: { focused in if !focused && focus == .files { focus = nil } }),
                        move: { moveSelection($0, files: files, columns: columns) },
                        submit: { if let selected { open(selected) } }))
                    .onChange(of: selected) { url in if let url { proxy.scrollTo(url, anchor: .top) } }
                }
            }.overlay {
                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: query.isEmpty ? "doc.text" : "magnifyingglass")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                        Text(L(query.isEmpty && folder == nil ? "No Recent Documents" : "No matching files"))
                            .font(.system(size: 13, weight: .medium))
                        Text(L(query.isEmpty && folder == nil ? "Documents you open will appear here." : "Choose another folder or adjust your search."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(24)
                }
            }
            if dismissOnOpen {
                Divider()
                HStack {
                    Spacer()
                    Button(L("Close")) { dismiss() }.keyboardShortcut(.escape, modifiers: [])
                    Button(L("Open")) { if let selected { open(selected) } }
                        .keyboardShortcut(.return, modifiers: []).disabled(selected == nil)
                }.controlSize(.regular)
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .onAppear { refreshHistory(); selected = files.first; focus = .search }
        .onChange(of: frequentlyRead) { _ in refreshHistory() }
        .onChange(of: files) { values in
            if selected.map({ !values.contains($0) }) ?? true { selected = values.first }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshHistory()
            revision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderFiles.recentDocumentsChanged)) { _ in
            refreshHistory(force: true)
        }
        .task(id: folder) {
            query = ""
            selected = nil
            entries = []
            guard let folder else { entries = []; return }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || Format.detect($0.lastPathComponent) != .unknown }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                }.value
                if !Task.isCancelled, self.folder == folder {
                    entries = loaded
                    ReaderFiles.recordBrowse(folder, recordsHistory: recordsHistory ?? state.recordsDocumentHistory)
                    refreshPins()
                }
            } catch { if !Task.isCancelled, self.folder == folder { state.error = error.localizedDescription } }
        }
    }
    // Layout, focus and file-view changes must not resolve the complete history's
    // filesystem aliases again. Defaults notifications also include view settings.
    private func refreshHistory(force: Bool = false) {
        let inputs = HistoryInputs(history: UserDefaults.standard.data(forKey: "documentOpenHistory"),
                                   pinned: ReaderFiles.pinned,
                                   frequentlyRead: frequentlyRead)
        guard force || historyInputs != inputs else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        historyInputs = inputs
        recentFiles = ReaderFiles.ordered(frequentlyRead: frequentlyRead)
        refreshPins()
        NativeReadingPerformance.mark("home-catalog-refresh", pagesIdentity: ObjectIdentifier(thumbnails),
                                      page: recentFiles.count, started: started)
    }
    private func refreshPins() {
        pinnedFiles = ReaderFiles.pinnedURLs(in: recentFiles + entries)
    }
    private func fileItem(_ url: URL, thumbnail: Bool) -> some View {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let pinned = pinnedFiles.contains(url)
        return Button { open(url) } label: {
            if thumbnail {
                VStack(spacing: 8) {
                    ReaderFileThumbnail(url: url, isFolder: isFolder, thumbnails: thumbnails)
                    HStack(spacing: 4) {
                        if pinned { Image(systemName: "pin.fill") }
                        Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    }
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(url.deletingLastPathComponent().path)
                    readingProgress(url)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    Image(systemName: isFolder ? "folder" : pinned ? "pin.fill" : "doc")
                        .font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    readingProgress(url)
                }.contentShape(Rectangle())
            }
        }.buttonStyle(.plain).contextMenu {
            Button(L("Open")) { open(url) }
            Button(L("Open in New Window")) {
                openAfterClosing {
                    ReaderFiles.openRecent(url, in: state, recordsHistory: recordsHistory ?? state.recordsDocumentHistory,
                                           behavior: .newWindow, browseFolder: isFolder && folder != nil) {
                        state.createWindow?($0)
                    }
                }
            }
            Button(pinned ? L("Unpin") : L("Pin")) { ReaderFiles.pin(url); revision += 1 }
            Button(L("Open without History")) {
                openAfterClosing {
                    ReaderFiles.openRecent(url, in: state, recordsHistory: false, behavior: .replaceCurrent,
                                           browseFolder: isFolder && folder != nil) { state.createWindow?($0) }
                }
            }
            if state.hasDocument {
                Button(L("Open in New Tab")) {
                    openAfterClosing {
                        ReaderFiles.openRecent(url, in: state, recordsHistory: recordsHistory ?? state.recordsDocumentHistory,
                                           behavior: .newTab, browseFolder: isFolder && folder != nil) {
                            state.createWindow?($0)
                        }
                    }
                }.disabled(!ReaderMenuCommand.newTab.enabled(state))
            }
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(L("Forget")) { ReaderFiles.forget(url); revision += 1 }
        }
    }
    @ViewBuilder private func readingProgress(_ url: URL) -> some View {
        if let data = UserDefaults.standard.data(forKey: "position:" + url.path), let position = try? JSONDecoder().decode(ReadingPosition.self, from: data) {
            VStack(alignment: .trailing, spacing: 4) {
                // Lazy chapter heights change as EPUB chapters are laid out.
                // Only a complete single canvas has a stable scroll percentage.
                if position.pageCount == 1, let fraction = position.scrollFraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0...1))).font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: fraction).frame(width: 72)
                        .accessibilityLabel(L("Reading progress"))
                } else {
                    if let count = position.pageCount, count > 1, position.flow == "continuous", let passage = position.nativePassage {
                        Text(String(format: L("Chapter %@"), String(passage.chapter + 1))).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(String(format: L("Page %d"), position.page + 1)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let count = position.pageCount, count > 0,
                       !(count == 1 && position.flow == "continuous" && (position.markdownRenderer == .paged || position.nativePassage != nil)) {
                        ProgressView(value: min(1, Double(position.page + 1) / Double(count))).frame(width: 72)
                            .accessibilityLabel(L("Reading progress"))
                    }
                }
            }
        }
    }
    // HomePageMoveSelection: grid steps, clamped ends, and Up above the first
    // row returns to search while retaining the selected column.
    private func moveSelection(_ direction: MoveCommandDirection, files: [URL], columns: Int) {
        guard !files.isEmpty else { return }
        guard let selected, let index = files.firstIndex(of: selected) else {
            selected = files.first; focus = .files; return
        }
        let delta: Int
        switch direction {
        case .up: delta = -columns
        case .down: delta = columns
        case .left: delta = viewMode == "thumbnails" ? -1 : 0
        case .right: delta = viewMode == "thumbnails" ? 1 : 0
        @unknown default: return
        }
        if direction == .up, index + delta < 0 { focus = .search; return }
        self.selected = files[min(files.count - 1, max(0, index + delta))]
        focus = .files
    }
    private func open(_ url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           folder != nil || ReaderFiles.opensInFolderBrowser(url) { folder = url }
        else { openDocument(url) }
    }
    private func openDocument(_ url: URL) {
        openAfterClosing {
            ReaderWindows.open([url], in: state, recordsHistory: recordsHistory ?? state.recordsDocumentHistory) { state.createWindow?($0) }
        }
    }
    private func openAfterClosing(_ action: @escaping () -> Void) {
        // Sheet dismissal restores its parent's activation. Open the destination
        // after the native sheet ends so restoration cannot cover the reader.
        performOpen(action)
        closeBrowser()
    }
    private func closeBrowser() { if dismissOnOpen { dismiss() } }
}

// The single-line field editor consumes Down before SwiftUI's onMoveCommand.
// Keep file selection and its destination focus in DocumentFileBrowser.
@MainActor
private struct ReaderFileSearchInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let down: () -> Void
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField(string: text)
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = L("Search files")
        field.setAccessibilityLabel(L("Search files"))
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text { field.stringValue = text }
        context.coordinator.updateFocus(field)
    }
    static func dismantleNSView(_ field: SearchField, coordinator: Coordinator) {
        field.delegate = nil
        field.abortEditing()
    }
    final class SearchField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (delegate as? Coordinator)?.updateFocus(self)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReaderFileSearchInput
        init(_ parent: ReaderFileSearchInput) { self.parent = parent }
        func updateFocus(_ field: NSTextField) {
            guard let window = field.window else { return }
            if parent.focused {
                if field.currentEditor() == nil { field.selectText(nil) }
            } else if let editor = field.currentEditor(), window.firstResponder === editor {
                window.makeFirstResponder(nil)
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField, parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            if !parent.focused { parent.focused = true }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.focused { parent.focused = false }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.moveDown(_:)) { parent.down() }
            else if selector == #selector(NSResponder.insertNewline(_:)) { parent.submit() }
            else { return false }
            return true
        }
    }
}

// The file area receives only its own navigation keys. Its SwiftUI content
// still owns selection, scrolling, menus and opening files.
@MainActor
private struct ReaderFileKeys: NSViewRepresentable {
    let performanceOwner: ObjectIdentifier
    let viewChange: UInt64?
    let thumbnails: Bool
    @Binding var focused: Bool
    let move: (MoveCommandDirection) -> Void
    let submit: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView(frame: .zero) }
    func updateNSView(_ view: KeyView, context: Context) {
        view.parent = self
        view.updateFocus()
        if let viewChange, viewChange != view.drawnChange { view.needsDisplay = true }
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.parent = nil }
    final class KeyView: NSView {
        var parent: ReaderFileKeys?
        var drawnChange: UInt64?
        override func draw(_ dirtyRect: NSRect) {
            guard let parent, let started = parent.viewChange, drawnChange != started else { return }
            drawnChange = started
            NativeReadingPerformance.mark("home-view-first-draw", pagesIdentity: parent.performanceOwner,
                                          started: started, size: bounds.size, flags: parent.thumbnails ? 1 : 0)
        }
        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateFocus() }
        func updateFocus() {
            if parent?.focused == true, let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result, parent?.focused == true { parent?.focused = false }
            return result
        }
        override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
        override func moveUp(_ sender: Any?) { parent?.move(.up) }
        override func moveDown(_ sender: Any?) { parent?.move(.down) }
        override func moveLeft(_ sender: Any?) { parent?.move(.left) }
        override func moveRight(_ sender: Any?) { parent?.move(.right) }
        override func insertNewline(_ sender: Any?) { parent?.submit() }
    }
}

// Retain completed covers across list/grid transitions without retaining their
// reader documents. NSCache can reclaim images under memory pressure.
@MainActor
private final class ReaderFileThumbnails {
    let images = NSCache<NSString, NSImage>()
}

@MainActor
private struct ReaderFileThumbnail: View {
    let url: URL
    let isFolder: Bool
    let thumbnails: ReaderFileThumbnails
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text(url.pathExtension.uppercased())
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(width: 116, height: 148)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
            }
        }
            .frame(width: 136, height: 168)
            .accessibilityHidden(true)
            .task(id: scale) {
                guard !isFolder else { return }
                let size = CGSize(width: 136 * scale, height: 168 * scale), url = url
                let key = ReadingDocument.thumbnailCacheKey(url, size: size) as NSString
                if let cached = thumbnails.images.object(forKey: key) { image = cached; return }
                let render = Task.detached(priority: .utility) { try await ReadingDocument.thumbnail(url, size: size) }
                do {
                    let bitmap = try await withTaskCancellationHandler(operation: { try await render.value }, onCancel: { render.cancel() })
                    guard !Task.isCancelled else { return }
                    image = bitmap.map { NSImage(cgImage: $0, size: .zero) }
                    if let image { thumbnails.images.setObject(image, forKey: key) }
                } catch { /* Unavailable or password-protected files keep their format cover. */ }
            }
            .onDisappear { image = nil }
    }
}

extension ReaderState {
    func duplicate(inTab: Bool) {
        guard var payload = ReaderWindows.payload(self) else { return }
        payload.tabWith = inTab ? window?.windowNumber : nil
        // A different tabbing identifier forces a distinct native window.
        if !inTab { payload.tabIdentifier = "Sumra-" + UUID().uuidString }
        createWindow?(payload)
    }
    func reopenClosed() {
        var closed = ReaderWindows.saved("closedDocuments")
        guard let payload = closed.popLast() else { return }
        ReaderWindows.save(closed, key: "closedDocuments")
        createWindow?(payload)
    }
    func selectTab(_ direction: Int, smart: Bool = false) {
        guard let window else { return }
        let tabs = window.tabGroup?.windows ?? [window]
        if smart {
            if ReaderWindows.smartOrder == nil {
                let numbers = Set(tabs.map(\.windowNumber))
                ReaderWindows.smartOrder = ReaderWindows.mru.filter { numbers.contains($0) }
                for tab in tabs where !(ReaderWindows.smartOrder?.contains(tab.windowNumber) ?? false) { ReaderWindows.smartOrder?.append(tab.windowNumber) }
            }
            let order = ReaderWindows.smartOrder ?? []
            guard let index = order.firstIndex(of: window.windowNumber), !order.isEmpty else { return }
            let number = order[(index + direction + order.count) % order.count]
            tabs.first { $0.windowNumber == number }?.makeKeyAndOrderFront(nil)
            if !NSEvent.modifierFlags.contains(.control) { ReaderWindows.finishSmartSwitch() }
        } else {
            ReaderWindows.finishSmartSwitch()
            if direction > 0 { window.selectNextTab(nil) } else { window.selectPreviousTab(nil) }
        }
    }
    func moveTab(_ direction: Int) {
        guard let window, let group = window.tabGroup, let index = group.windows.firstIndex(of: window) else { return }
        let destination = index + direction
        guard group.windows.indices.contains(destination) else { return }
        // Moving an existing group entry leaves AppKit's native tab captions
        // in their old slots. Reattach the neighbor on the opposite side,
        // keeping the selected reader in its window and fullscreen Space.
        let neighbor = group.windows[destination]
        group.removeWindow(neighbor)
        window.addTabbedWindow(neighbor, ordered: direction < 0 ? .above : .below)
        window.makeKeyAndOrderFront(nil)
    }
    func closeTabs(_ subset: String) {
        guard let window else { return }
        let tabs = window.tabGroup?.windows ?? [window]
        guard let index = tabs.firstIndex(of: window) else { return }
        let targets = tabs.enumerated().filter { offset, tab in
            subset == "all" || subset == "other" && tab !== window || subset == "left" && offset < index || subset == "right" && offset > index
        }.map(\.element)
        Task {
            for tab in targets {
                guard let closeGuard = tab.delegate as? ReaderCloseGuard else { return }
                let closed = await withCheckedContinuation { continuation in
                    closeGuard.close(tab) { continuation.resume(returning: $0) }
                }
                if !closed { return }
            }
        }
    }
    func saveTabGroup() {
        guard let window else { return }
        let group = (window.tabGroup?.windows ?? [window]).compactMap { tab -> WindowPayload? in
            guard let state = (tab.delegate as? ReaderCloseGuard)?.state, var payload = ReaderWindows.payload(state) else { return nil }
            payload.selected = tab === (window.tabGroup?.selectedWindow ?? window)
            payload.active = payload.selected
            return payload
        }
        guard !group.isEmpty else { return }
        let alert = ReaderInputAlert(); alert.messageText = L("Save Tab Group")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = L("Group name"); alert.accessoryView = name; alert.window.initialFirstResponder = name
        alert.addButton(withTitle: L("Save")); alert.addButton(withTitle: L("Cancel"))
        while alert.runModal() == .alertFirstButtonReturn {
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = "tabGroup:" + title
            if UserDefaults.standard.object(forKey: key) != nil {
                let duplicate = NSAlert()
                duplicate.messageText = L("Replace Saved Tab Group?")
                duplicate.informativeText = title
                duplicate.addButton(withTitle: L("Replace")); duplicate.addButton(withTitle: L("Rename")); duplicate.addButton(withTitle: L("Cancel"))
                switch duplicate.runModal() {
                case .alertFirstButtonReturn: break
                case .alertSecondButtonReturn: continue
                default: return
                }
            }
            ReaderWindows.save(group, key: key)
            return
        }
    }
    func restoreTabGroup() {
        let names = ReaderWindows.savedTabGroupKeys
        guard !names.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = L("Restore Tab Group")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        picker.addItems(withTitles: names.map { String($0.dropFirst(9)) }); alert.accessoryView = picker
        alert.addButton(withTitle: L("Open")); alert.addButton(withTitle: L("Delete")); alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal(); let key = names[picker.indexOfSelectedItem]
        if response == .alertSecondButtonReturn { UserDefaults.standard.removeObject(forKey: key); return }
        guard response == .alertFirstButtonReturn else { return }
        ReaderWindows.restoreTabGroup(ReaderWindows.saved(key), in: self) { self.createWindow?($0) }
    }
    func setTabColor() {
        guard window != nil else { return }
        let alert = NSAlert(); alert.messageText = L("Tab Color")
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 120, height: 32))
        color.color = tabColor.map(ReaderTheme.color) ?? .controlAccentColor; alert.accessoryView = color
        alert.addButton(withTitle: L("Set")); alert.addButton(withTitle: L("Clear")); alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            tabColor = ReaderTheme.rgb(color.color)
        case .alertSecondButtonReturn: tabColor = nil
        default: break
        }
    }
    func applyTabColor() {
        guard let window else { return }
        guard let tabColor else { window.tab.accessoryView = nil; return }
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12)); dot.wantsLayer = true
        dot.layer?.backgroundColor = ReaderTheme.color(tabColor).cgColor; dot.layer?.cornerRadius = 6
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true; dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
        window.tab.accessoryView = dot
    }
    func shareByEmail() {
        guard let url = document?.url else { return }
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [url]) else {
            error = L("No email application is available to compose a message with this document.")
            return
        }
        if let owner = window?.delegate as? ReaderCloseGuard {
            owner.emailService = service
            service.delegate = owner
        }
        service.perform(withItems: [url])
    }
    func openWithApplication() {
        guard let url = document?.url else { return }
        let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]; panel.treatsFilePackagesAsDirectories = false
        let documentID = document?.id
        panel.begin { response in
            guard response == .OK, let application = panel.url, self.document?.id == documentID else { return }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { _, error in
                if let error { Task { @MainActor in if self.document?.id == documentID { self.error = error.localizedDescription } } }
            }
        }
    }
}

@main
@MainActor
struct SumraApp: App {
    static var restoring: [WindowPayload] = []
    @NSApplicationDelegateAdaptor(ReaderApplicationDelegate.self) private var delegate
    init() {
        ReaderPreferences.migrate()
        // AppKit installs View's tab overview and Window's tab commands only
        // when tabbing is enabled. Each scene still owns its requested placement.
        NSWindow.allowsAutomaticWindowTabbing = !UserDefaults.standard.bool(forKey: "disableTabs")
        ReaderTheme.applyAppearance(UserDefaults.standard.string(forKey: "theme") ?? ReaderTheme.builtins[0].id)
        AppIcon.apply(UserDefaults.standard.string(forKey: "appIcon") ?? "light")
        if UserDefaults.standard.bool(forKey: "restoreSession") { Self.restoring = ReaderWindows.prepareRestoration(ReaderWindows.saved("session")) }
    }

    var body: some Scene {
        WindowGroup("Sumra", id: "reader", for: WindowPayload.self) { $payload in
            ReaderWindow(payload: $payload, application: delegate)
                .modifier(ReaderLanguage())
        } defaultValue: {
            Self.restoring.first ?? WindowPayload()
        }
        .defaultSize(width: 900, height: 740)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        // AppKit's delegate owns Finder files and SyncTeX URLs. Let it receive
        // those requests instead of SwiftUI consuming them for an empty scene.
        .handlesExternalEvents(matching: [])
        .commands { SumraCommands(application: delegate, undoCommands: delegate.undoCommands) }

        Settings {
            SettingsView()
                .modifier(ReaderLanguage())
        }
        .handlesExternalEvents(matching: [])
        Window("Bookmarks", id: "bookmarks") { BookmarkBrowser().modifier(ReaderLanguage()) }
            .defaultSize(width: 460, height: 480)
            .handlesExternalEvents(matching: [])
    }
}

#endif
