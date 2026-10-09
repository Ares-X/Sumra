#if os(macOS)
import SwiftUI
import SumraCore
import UniformTypeIdentifiers
import WebKit

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
    enum CodingKeys: String, CodingKey { case id, path, position, tabWith, tabIdentifier, recordsHistory, tabColor }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(tabIdentifier, forKey: .tabIdentifier)
        try values.encodeIfPresent(recordsHistory, forKey: .recordsHistory)
        try values.encodeIfPresent(tabColor, forKey: .tabColor)
        // Scene restoration must not persist a private or temporary file path.
        if temporary == nil, recordsHistory != false {
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
}

@MainActor
private struct ReaderWindow: View {
    @Binding var payload: WindowPayload
    let application: ReaderApplicationDelegate
    @StateObject private var state = ReaderState()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("fullPathTitle") private var fullPathTitle = false
    @AppStorage("pageInTitle") private var pageInTitle = false

    private var windowTitle: String {
        guard let document = state.document else { return "Sumra" }
        return (fullPathTitle ? document.url.path : document.url.lastPathComponent) + (pageInTitle && state.count > 0 ? " — " + state.positionLabel : "")
    }

    var body: some View {
        ReaderView(state: state)
            .frame(minWidth: 560, minHeight: state.hasDocument ? 400 : 500)
            .navigationTitle(windowTitle)
            .background(WindowTabs(state: state, tabWith: payload.tabWith, identifier: payload.tabIdentifier) {
                application.connect(state, canReuse: payload.path == nil)
            })
            .focusedSceneObject(state)
            .onAppear {
                state.tabColor = payload.tabColor
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

private struct WindowTabs: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    let tabWith: Int?
    let identifier: String?
    let onWindowReady: () -> Void

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.state = state
        view.tabWith = tabWith
        view.groupIdentifier = identifier
        view.onWindowReady = onWindowReady
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.state = state
        view.onWindowReady = onWindowReady
        view.updateDocumentProperties()
    }

    @MainActor
    final class HostView: NSView {
        weak var state: ReaderState?
        var tabWith: Int?
        var groupIdentifier: String?
        var onWindowReady: (() -> Void)?
        private var closeGuard: ReaderCloseGuard?
        private weak var guardedWindow: NSWindow?

        func updateDocumentProperties() {
            window?.representedURL = state?.document?.url
        }


        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let previousWindow = guardedWindow, previousWindow.delegate === closeGuard {
                previousWindow.delegate = closeGuard?.previous
            }
            if state?.window === guardedWindow { state?.window = nil }
            closeGuard = nil
            guardedWindow = nil
            guard let window else { return }

            let previous: NSWindowDelegate?
            if let installed = window.delegate as? ReaderCloseGuard { previous = installed.previous }
            else { previous = window.delegate }
            let guardDelegate = ReaderCloseGuard(state: state, previous: previous)
            closeGuard = guardDelegate
            guardedWindow = window
            window.delegate = guardDelegate
            state?.window = window
            updateDocumentProperties()
            state?.applyTabColor()
            window.tabbingIdentifier = groupIdentifier ?? "SumraReader"
            window.tabbingMode = UserDefaults.standard.bool(forKey: "disableTabs") ? .disallowed : .preferred
            if let tabWith, let parent = ReaderWindows.states.compactMap(\.window).first(where: { $0.windowNumber == tabWith }), parent !== window {
                parent.addTabbedWindow(window, ordered: .above)
                self.tabWith = nil
            } else if let groupIdentifier, let parent = ReaderWindows.states.compactMap(\.window).first(where: { $0 !== window && $0.tabbingIdentifier == groupIdentifier }) {
                parent.addTabbedWindow(window, ordered: .above)
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
final class ReaderCloseGuard: NSObject, NSWindowDelegate {
    weak var state: ReaderState?
    // NSWindow caches forwarded notification selectors while this proxy is installed.
    let previous: NSWindowDelegate?
    private var closePending = false
    init(state: ReaderState?, previous: NSWindowDelegate?) {
        self.state = state
        self.previous = previous
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let state else { return previous?.windowShouldClose?(sender) ?? true }
        guard !closePending else { return false }
        closePending = true
        let documentID = state.document?.id, generation = state.generation
        Task { [weak self] in
            guard let self else { return }
            defer { closePending = false }
            guard await state.confirmClose(),
                  previous?.windowShouldClose?(sender) ?? true,
                  state.document?.id == documentID, state.generation == generation else { return }
            // close() completes the approved request without recursively asking
            // windowShouldClose again, and still sends the normal willClose event.
            sender.close()
        }
        return false
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
    }
}

@MainActor
final class ReaderApplicationDelegate: NSObject, NSApplicationDelegate {
    let undoCommands = ReaderUndoCommands()
    private var keyMonitor: Any?
    private var terminationPending = false
    private var pendingFiles: [URL] = []
    private var createWindow: ((WindowPayload) -> Void)?
    private weak var emptyReader: ReaderState?

    // Finder may deliver files before a SwiftUI scene has installed its
    // OpenWindowAction. Keep the request until that existing owner is ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFiles.append(contentsOf: urls.filter(\.isFileURL))
        openPendingFiles()
    }

    func connect(_ state: ReaderState, canReuse: Bool) {
        guard state.window != nil else { return }
        createWindow = state.createWindow
        // A restoration payload can still be waiting for its .task even
        // though its state has no document yet. Never replace that request.
        if canReuse, state.document == nil, !state.busy { emptyReader = state }
        openPendingFiles()
    }

    private func openPendingFiles() {
        guard let createWindow, !pendingFiles.isEmpty else { return }
        let urls = pendingFiles
        pendingFiles.removeAll()
        for url in urls {
            if let state = emptyReader, state.window != nil, state.document == nil, !state.busy {
                emptyReader = nil
                state.open(url)
                state.window?.makeKeyAndOrderFront(nil)
            } else {
                createWindow(WindowPayload(path: url.path))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillUpdate(_ notification: Notification) {
        undoCommands.update()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenshotHotkey.restore()
        ReaderHelp.checkForUpdatesOnLaunch()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .otherMouseDown, .scrollWheel]) { event in
            if event.type == .scrollWheel {
                guard NSApp.modalWindow == nil, let window = event.window,
                      let state = ReaderWindows.states.first(where: { $0.window === window }) else { return event }
                return state.handleScrollWheel(event) ? nil : event
            }
            if event.type == .flagsChanged {
                if !event.modifierFlags.contains(.control) { ReaderWindows.finishSmartSwitch() }
                return event
            }
            guard let window = NSApp.keyWindow, NSApp.modalWindow == nil,
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
                    let extra = readerShortcutBindings(overrides[command.id] ?? command.defaultShortcut).dropFirst()
                    if extra.contains(where: matches) {
                        if command == .open {
                            chooseDocuments { urls in
                                ReaderWindows.open(urls, in: state) { state.createWindow?($0) }
                            }
                        } else if command == .close { window.performClose(nil) }
                        else { command.run(state) }
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
            guard let responder = window.firstResponder as? NSView,
                  readers.compactMap({ $0 }).contains(where: { responder === $0 || responder.isDescendant(of: $0) }) else { return event }
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
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        ReaderWindows.isTerminating = false
        let states = sender.windows.compactMap { ($0.delegate as? ReaderCloseGuard)?.state }
        Task {
            defer { terminationPending = false }
            var approved: [(ReaderState, UUID?, Int, Int)] = []
            for state in states {
                guard await state.confirmClose() else { sender.reply(toApplicationShouldTerminate: false); return }
                approved.append((state, state.document?.id, state.generation, state.editRevision))
            }
            // Later sheets/field validation can pump events in another window.
            let current = sender.windows.compactMap { ($0.delegate as? ReaderCloseGuard)?.state }
            guard current.allSatisfy({ state in
                approved.contains { previous, id, generation, revision in
                    state === previous && state.document?.id == id && state.generation == generation && state.editRevision == revision && state.nativePDFFormEditor == nil
                }
            }) else { sender.reply(toApplicationShouldTerminate: false); return }
            ReaderWindows.saveSession(current)
            ReaderWindows.isTerminating = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// AppKit owns the actual tabs and close lifecycle. Only MRU order and saved
// positions belong to the app; there is no parallel tab model or view cache.
@MainActor
enum ReaderWindows {
    fileprivate static var mru: [Int] = []
    fileprivate static var smartOrder: [Int]?
    static var isTerminating = false
    static var states: [ReaderState] { NSApp.windows.compactMap { ($0.delegate as? ReaderCloseGuard)?.state } }

    static func open(_ urls: [URL], in state: ReaderState?, recordsHistory: Bool = true,
                     createWindow: (WindowPayload) -> Void) {
        for (index, url) in urls.enumerated() {
            // A file picker can finish after its captured reader window closes.
            if index == 0, let state, state.window != nil {
                if recordsHistory { state.open(url) }
                else { state.openWithoutHistory(url) }
            } else {
                createWindow(WindowPayload(path: url.path, recordsHistory: recordsHistory ? nil : false))
            }
        }
    }

    static func isTyping(in window: NSWindow, state: ReaderState) -> Bool {
        if (window.firstResponder as? NSTextView)?.isEditable == true { return true }
        guard let web = state.browserView, let responder = window.firstResponder as? NSView,
              responder === web || responder.isDescendant(of: web),
              let owner = web.navigationDelegate as? BrowserReader.Coordinator, owner.isCurrent else { return false }
        return owner.textInputFocused
    }

    static func activated(_ window: NSWindow) {
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
        guard let path = state.document?.url.path else { return nil }
        var payload = WindowPayload(path: path, position: state.filePosition, temporary: state.document?.sourceTemporary, recordsHistory: state.recordsDocumentHistory)
        payload.tabColor = state.tabColor
        return payload
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
        for state in states {
            guard let window = state.window, !visited.contains(window.windowNumber) else { continue }
            let identifier = "Sumra-" + UUID().uuidString
            for tab in window.tabbedWindows ?? [window] {
                visited.insert(tab.windowNumber)
                guard let reader = states.first(where: { $0.window === tab }), reader.recordsDocumentHistory, var payload = payload(reader) else { continue }
                payload.tabIdentifier = identifier; windows.append(payload)
            }
        }
        save(windows, key: "session")
    }
}

@MainActor
enum ReaderFiles {
    private static func identity(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // A renamed or removed leaf must still resolve aliases in its existing parent.
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath().path
    }
    private struct OpenRecord: Codable {
        var count: Int
        var lastOpened: Date

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
    static func isPinned(_ url: URL) -> Bool {
        let key = identity(url.path)
        return pinned.contains { identity($0) == key }
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
    static func recordOpen(_ document: ReadingDocument, recordsHistory: Bool, at date: Date = Date()) {
        guard recordsHistory, !UserDefaults.standard.bool(forKey: "disableHistory"), document.sourceTemporary == nil else { return }
        let url = document.url
        var records = history
        let key = identity(url.path), aliases = records.keys.filter { identity($0) == key }
        let count = aliases.reduce(1) { $0 + records[$1]!.count(at: date) }
        for path in aliases { records.removeValue(forKey: path) }
        records[url.path] = OpenRecord(count: count, lastOpened: date)
        let pinned = Set(Self.pinned.map(identity))
        let unpinned = records.keys.filter { !pinned.contains(identity($0)) }.sorted { records[$0]!.lastOpened > records[$1]!.lastOpened }
        for path in unpinned.dropFirst(1000) { records.removeValue(forKey: path) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        saveHistory(records)
    }
    static func clearHistory() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        UserDefaults.standard.removeObject(forKey: "documentOpenHistory")
        UserDefaults.standard.removeObject(forKey: "closedDocuments")
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
    static func replaceHistory(_ source: URL, with destination: URL) {
        let key = identity(source.path)
        setRecent(NSDocumentController.shared.recentDocumentURLs.map { identity($0.path) == key ? destination : $0 })
        var records = history
        let aliases = records.keys.filter { identity($0) == key }
        if let date = aliases.compactMap({ records[$0]?.lastOpened }).max() {
            let count = aliases.reduce(0) { $0 + records[$1]!.count(at: date) }
            for path in aliases { records.removeValue(forKey: path) }
            records[destination.path] = OpenRecord(count: count, lastOpened: date)
            saveHistory(records)
        }
        UserDefaults.standard.set(pinned.map { identity($0) == key ? destination.path : $0 }, forKey: "pinnedDocuments")
        var closed = ReaderWindows.saved("closedDocuments")
        for index in closed.indices where identity(closed[index].path ?? "") == key { closed[index].path = destination.path }
        ReaderWindows.save(closed, key: "closedDocuments")
    }
    static func removeMissing() {
        forget(Set(recent.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.path)))
    }
}

@MainActor
struct DocumentFileBrowser: View {
    @ObservedObject var state: ReaderState
    @State private var folder: URL?
    @State private var entries: [URL] = []
    @State private var query = ""
    @State private var revision = 0
    @State private var selected: URL?
    @State private var focus: Focus?
    private enum Focus { case search, files }
    @AppStorage("homePageSortByFrequentlyRead") private var frequentlyRead = false
    @AppStorage("homePageViewMode") private var viewMode = "thumbnails"
    let dismissOnOpen: Bool
    @Environment(\.dismiss) private var dismiss
    init(state: ReaderState, folder: URL? = nil, dismissOnOpen: Bool = false) { self.state = state; self.dismissOnOpen = dismissOnOpen; _folder = State(initialValue: folder) }
    var body: some View {
        let _ = revision
        let files = (folder == nil ? ReaderFiles.ordered(frequentlyRead: frequentlyRead) : entries)
            .filter { query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder?.lastPathComponent ?? L("Recent Documents"))
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
                Picker(L("File View"), selection: $viewMode) {
                    Image(systemName: "list.bullet").tag("list").help(L("List"))
                    Image(systemName: "square.grid.2x2").tag("thumbnails").help(L("Thumbnails"))
                }.labelsHidden().pickerStyle(.segmented).frame(width: 64)
            }
            HStack(spacing: 8) {
                Button { folder = nil } label: { Label(L("Recent"), systemImage: "clock") }
                Button {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                    panel.directoryURL = folder ?? state.document?.url.deletingLastPathComponent()
                    if panel.runModal() == .OK { folder = panel.url }
                } label: { Label(L("Folder…"), systemImage: "folder") }
                if let folder {
                    Divider().frame(height: 16)
                    Button { self.folder = folder.deletingLastPathComponent() } label: { Image(systemName: "arrow.up") }
                        .help(L("Parent folder")).accessibilityLabel(L("Parent folder"))
                    Button(L("Open Folder")) { state.open(folder); closeBrowser() }
                }
                Spacer()
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
                    .background(ReaderFileKeys(focused: Binding(
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
        .onAppear { selected = files.first; focus = .search }
        .onChange(of: files) { values in
            if selected.map({ !values.contains($0) }) ?? true { selected = values.first }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in revision += 1 }
        .task(id: folder) {
            entries = []
            guard let folder else { entries = []; return }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || Format.detect($0.lastPathComponent) != .unknown }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                }.value
                if !Task.isCancelled, self.folder == folder { entries = loaded }
            } catch { if !Task.isCancelled, self.folder == folder { state.error = error.localizedDescription } }
        }
    }
    private func fileItem(_ url: URL, thumbnail: Bool) -> some View {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let pinned = ReaderFiles.isPinned(url)
        return Button { open(url) } label: {
            if thumbnail {
                VStack(spacing: 8) {
                    ReaderFileThumbnail(url: url, isFolder: isFolder)
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
            Button(pinned ? L("Unpin") : L("Pin")) { ReaderFiles.pin(url); revision += 1 }
            Button(L("Open without History")) { state.openWithoutHistory(url); closeBrowser() }
            Button(L("Open in New Tab")) { state.createWindow?(WindowPayload(path: url.path, tabWith: state.window?.windowNumber)); closeBrowser() }
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(L("Forget")) { ReaderFiles.forget(url); revision += 1 }
        }
    }
    @ViewBuilder private func readingProgress(_ url: URL) -> some View {
        if let data = UserDefaults.standard.data(forKey: "position:" + url.path), let position = try? JSONDecoder().decode(ReadingPosition.self, from: data) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: L("Page %d"), position.page + 1)).font(.caption).foregroundStyle(.secondary)
                if let count = position.pageCount, count > 0 {
                    ProgressView(value: min(1, Double(position.page + 1) / Double(count))).frame(width: 72)
                        .accessibilityLabel(L("Reading progress"))
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
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folder = url }
        else { state.open(url); closeBrowser() }
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
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
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
    @Binding var focused: Bool
    let move: (MoveCommandDirection) -> Void
    let submit: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView(frame: .zero) }
    func updateNSView(_ view: KeyView, context: Context) {
        view.parent = self
        view.updateFocus()
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.parent = nil }
    final class KeyView: NSView {
        var parent: ReaderFileKeys?
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

@MainActor
private struct ReaderFileThumbnail: View {
    let url: URL
    let isFolder: Bool
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
                let render = Task.detached(priority: .utility) { try await ReadingDocument.thumbnail(url, size: size) }
                do {
                    let bitmap = try await withTaskCancellationHandler(operation: { try await render.value }, onCancel: { render.cancel() })
                    guard !Task.isCancelled else { return }
                    image = bitmap.map { NSImage(cgImage: $0, size: .zero) }
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
        let tabs = window.tabbedWindows ?? [window]
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
        group.insertWindow(window, at: destination)
        window.makeKeyAndOrderFront(nil)
    }
    func closeTabs(_ subset: String) {
        guard let window else { return }
        let tabs = window.tabbedWindows ?? [window]
        guard let index = tabs.firstIndex(of: window) else { return }
        for (offset, tab) in tabs.enumerated() where subset == "all" || subset == "other" && tab !== window || subset == "left" && offset < index || subset == "right" && offset > index {
            let state = (tab.delegate as? ReaderCloseGuard)?.state
            tab.performClose(nil)
            if state?.document != nil { break } // User cancelled this tab's close.
        }
    }
    func saveTabGroup() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = L("Save Tab Group")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = L("Group name"); alert.accessoryView = name; alert.window.initialFirstResponder = name
        alert.addButton(withTitle: L("Save")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let group = (window.tabbedWindows ?? [window]).compactMap { ($0.delegate as? ReaderCloseGuard)?.state }.compactMap(ReaderWindows.payload)
        ReaderWindows.save(group, key: "tabGroup:" + name.stringValue)
    }
    func restoreTabGroup() {
        let names = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("tabGroup:") }.sorted()
        guard !names.isEmpty else { status = L("No saved tab groups"); return }
        let alert = NSAlert(); alert.messageText = L("Restore Tab Group")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        picker.addItems(withTitles: names.map { String($0.dropFirst(9)) }); alert.accessoryView = picker
        alert.addButton(withTitle: L("Open")); alert.addButton(withTitle: L("Delete")); alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal(); let key = names[picker.indexOfSelectedItem]
        if response == .alertSecondButtonReturn { UserDefaults.standard.removeObject(forKey: key); return }
        guard response == .alertFirstButtonReturn else { return }
        for var payload in ReaderWindows.saved(key) { payload.id = UUID(); payload.tabWith = window?.windowNumber; createWindow?(payload) }
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
        guard let url = document?.url, let service = NSSharingService(named: .composeEmail) else { return }
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
        NSWindow.allowsAutomaticWindowTabbing = !UserDefaults.standard.bool(forKey: "disableTabs")
        AppIcon.apply(UserDefaults.standard.string(forKey: "appIcon") ?? "light")
        if UserDefaults.standard.bool(forKey: "restoreSession") { Self.restoring = ReaderWindows.saved("session") }
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
        .commands { SumraCommands(undoCommands: delegate.undoCommands) }

        Settings {
            SettingsView()
                .modifier(ReaderLanguage())
        }
        Window("Bookmarks", id: "bookmarks") { BookmarkBrowser().modifier(ReaderLanguage()) }.defaultSize(width: 460, height: 480)
    }
}

#endif
