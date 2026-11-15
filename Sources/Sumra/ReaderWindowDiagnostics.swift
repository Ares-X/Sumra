#if os(macOS)
import AppKit
import Combine
import OSLog
import MachO
import UniformTypeIdentifiers

private let windowDiagnosticsLog = Logger(subsystem: "com.leaf.reader", category: "window-diagnostics")

/// Opt-in, local window traces. Never reads a window's lazy tabGroup or title.
@MainActor
final class ReaderWindowDiagnostics: ObservableObject {
    static let shared = ReaderWindowDiagnostics()
    static let preferenceKey = "windowDiagnosticsEnabled"

    @Published private(set) var enabled: Bool
    @Published private(set) var isExporting = false
    @Published private(set) var lastError: String?
    @Published private var fileCount = 0
    @Published private var byteCount: Int64 = 0
    var reportSummary: String {
        String(format: L("%1$ld recording files · %2$@"), fileCount,
               ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
    }

    private let defaults: UserDefaults
    let directory: URL
    private let processID = UUID()
    private var captureID: UUID?
    private var sequenceCaptureID: UUID?
    private var sequence = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var windowIDs: [ObjectIdentifier: WindowRef] = [:]
    private var groupIDs: [ObjectIdentifier: GroupRef] = [:]
    private var cachedGroups: [ObjectIdentifier: [String: Any]] = [:]
    private var lastValues: [String: NSDictionary] = [:]
    private var nextWindow = 0, nextGroup = 0

    private final class WindowRef {
        weak var window: NSWindow?
        let id: String
        init(_ window: NSWindow, id: String) { self.window = window; self.id = id }
    }
    private final class GroupRef {
        weak var group: NSWindowTabGroup?
        let id: String
        init(_ group: NSWindowTabGroup, id: String) { self.group = group; self.id = id }
    }

    private lazy var log = ReaderDiagnosticLog(directory: directory) { [weak self] error in
        let safe = Self.safeError(error)
        windowDiagnosticsLog.error("Window diagnostic IO failed: \(String(describing: safe), privacy: .public)")
        Task { @MainActor [weak self] in
            self?.lastError = L("Window diagnostics could not be recorded. Earlier logs have been kept.")
        }
    }

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sumra/WindowDiagnostics", isDirectory: true)
        enabled = defaults.bool(forKey: Self.preferenceKey)
    }

    /// Called before constructing NSApplication. No AppKit singleton or screen access here.
    func startAtLaunch() {
        if enabled { beginCapture() }
    }

    /// Called after the existing NSApplication subclass is constructed, before SwiftUI starts.
    func observeApplication() {
        guard enabled, observers.isEmpty else { return }
        observe(.default, names: [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
            NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didEndLiveResizeNotification
        ]) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            // Lifecycle edges must survive repeated fullscreen/key-window cycles.
            let geometry = notification.name == NSWindow.didMoveNotification || notification.name == NSWindow.didResizeNotification
            self.record(notification.name.rawValue, window: window, deduplicate: geometry)
        }
        observe(.default, names: [
            NSApplication.willFinishLaunchingNotification, NSApplication.didFinishLaunchingNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didFinishRestoringWindowsNotification,
            NSApplication.didChangeScreenParametersNotification
        ]) { [weak self] notification in self?.snapshot(notification.name.rawValue) }
        observe(.default, names: [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification]) {
            [weak self] notification in self?.record(notification.name.rawValue)
        }
        observe(NSWorkspace.shared.notificationCenter, names: [NSWorkspace.activeSpaceDidChangeNotification]) {
            [weak self] _ in self?.snapshot("workspace.activeSpaceChanged")
        }
        snapshot("application.observersInstalled")
    }

    private func observe(_ center: NotificationCenter, names: [Notification.Name],
                         receive: @escaping @MainActor (Notification) -> Void) {
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated { receive(notification) }
            }
            observers.append((center, token))
        }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value {
            enabled = true
            defaults.set(true, forKey: Self.preferenceKey)
            beginCapture()
            observeApplication()
        } else {
            record("capture.disabled")
            removeObservers()
            enabled = false
            defaults.set(false, forKey: Self.preferenceKey)
            log.stop()
            captureID = nil
            refresh()
        }
    }

    private func beginCapture() {
        guard captureID == nil else { return }
        let id = UUID()
        captureID = id
        sequenceCaptureID = id
        sequence = 0
        windowIDs = [:]; groupIDs = [:]; cachedGroups = [:]; lastValues = [:]
        nextWindow = 0; nextGroup = 0
        lastError = nil
        log.start(fileID: id)
        record("capture.started", fields: [
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.architecture,
            "mainImageLoadAddress": _dyld_get_image_header(0).map { String(UInt(bitPattern: UnsafeRawPointer($0)), radix: 16) } as Any? ?? NSNull(),
            "processID": ProcessInfo.processInfo.processIdentifier,
            "settings": ["restoreSession": defaults.bool(forKey: "restoreSession"),
                         "disableTabs": defaults.bool(forKey: "disableTabs"),
                         "openBehavior": (DocumentOpenBehavior(rawValue: defaults.string(forKey: "documentOpenBehavior") ?? "") ?? .newWindow).rawValue]
        ])
        windowDiagnosticsLog.notice("Window diagnostics started: \(id.uuidString, privacy: .public)")
        refresh()
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "other"
        #endif
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    func finishAtTermination() {
        // Stopping recording can leave queued writes even though captureID is nil.
        guard sequence > 0 else { return }
        record("process.endedNormally")
        removeObservers()
        log.closeAndWait()
        captureID = nil
    }

    /// Field closures are deliberately unevaluated while recording is off.
    static func event(_ name: String, window: NSWindow? = nil, request: UUID? = nil,
                      deduplicate: Bool = false, fields: @autoclosure () -> [String: Any] = [:]) {
        shared.record(name, window: window, request: request, deduplicate: deduplicate, fields: fields())
    }

    @discardableResult
    func record(_ name: String, window: NSWindow? = nil, request: UUID? = nil,
                deduplicate: Bool = false, fields: @autoclosure () -> [String: Any] = [:]) -> Int? {
        guard enabled, let captureID else { return nil }
        // Timestamp precedes public getters; no disk work occurs on this thread.
        let time = DispatchTime.now().uptimeNanoseconds
        var values = fields()
        if let window { values["window"] = windowSnapshot(window) }
        if let app = NSApp {
            values["app"] = ["active": app.isActive, "hidden": app.isHidden,
                             "key": app.keyWindow.map(windowID) ?? "none",
                             "main": app.mainWindow.map(windowID) ?? "none",
                             "presentationOptions": app.presentationOptions.rawValue]
        }
        if let request { values["request"] = request.uuidString }
        if deduplicate {
            let key = name + ":" + (window.map(windowID) ?? "application")
            let current = NSDictionary(dictionary: values)
            if lastValues[key]?.isEqual(current) == true { return nil }
            lastValues[key] = current
        }
        sequence += 1
        log.append(["schema": 1, "capture": captureID.uuidString, "process": processID.uuidString,
                    "sequence": sequence, "monotonicNS": time,
                    "unixTime": Date().timeIntervalSince1970, "event": name, "data": values])
        return sequence
    }

    private func windowID(_ window: NSWindow) -> String {
        let key = ObjectIdentifier(window)
        if let previous = windowIDs[key], previous.window === window { return previous.id }
        cachedGroups.removeValue(forKey: key)
        nextWindow += 1
        let id = "w\(nextWindow)"
        windowIDs[key] = WindowRef(window, id: id)
        return id
    }

    private func windowSnapshot(_ window: NSWindow) -> [String: Any] {
        var values: [String: Any] = [
            "id": windowID(window), "number": window.windowNumber,
            "class": NSStringFromClass(type(of: window)),
            "visible": window.isVisible, "miniaturized": window.isMiniaturized,
            "key": window.isKeyWindow, "main": window.isMainWindow,
            "onActiveSpace": window.isOnActiveSpace,
            "fullscreen": window.styleMask.contains(.fullScreen),
            "style": window.styleMask.rawValue, "collectionBehavior": window.collectionBehavior.rawValue,
            "occlusion": window.occlusionState.rawValue, "alpha": window.alphaValue,
            "frame": Self.rect(window.frame), "tabbingMode": window.tabbingMode.rawValue,
            "attachedSheet": window.attachedSheet != nil,
            "parent": window.parent.map(windowID) ?? "none",
            "children": (window.childWindows ?? []).map(windowID)
        ]
        if let content = window.contentView {
            values["content"] = ["class": NSStringFromClass(type(of: content)),
                                 "hidden": content.isHidden, "alpha": content.alphaValue,
                                 "frame": Self.rect(content.frame)]
        }
        if let delegate = window.delegate { values["delegateClass"] = NSStringFromClass(type(of: delegate)) }
        if let controller = window.windowController { values["controllerClass"] = NSStringFromClass(type(of: controller)) }
        values["cachedGroup"] = cachedGroups[ObjectIdentifier(window)] ?? ["observation": "not_observed"]
        return values
    }

    private static func rect(_ value: NSRect) -> [CGFloat] {
        [value.origin.x, value.origin.y, value.size.width, value.size.height]
    }

    /// Only called with a group/member list already obtained by the business owner.
    static func groupObserved(_ window: NSWindow, group: NSWindowTabGroup?, members: @autoclosure () -> [NSWindow]) {
        let recorder = shared
        guard recorder.enabled, recorder.captureID != nil else { return }
        let members = members()
        let groupID: String
        if let group {
            let key = ObjectIdentifier(group)
            if let previous = recorder.groupIDs[key], previous.group === group { groupID = previous.id }
            else {
                recorder.nextGroup += 1
                groupID = "g\(recorder.nextGroup)"
                recorder.groupIDs[key] = GroupRef(group, id: groupID)
            }
        } else { groupID = "none" }
        let observed: [String: Any] = ["observation": "cached_from_application_getter", "id": groupID,
                                     "members": members.map(recorder.windowID),
                                     "selected": group?.selectedWindow.map(recorder.windowID) ?? "none"]
        let key = ObjectIdentifier(window)
        if let cached = recorder.cachedGroups[key], NSDictionary(dictionary: cached).isEqual(to: observed) { return }
        recorder.cachedGroups[key] = observed
        recorder.record("tabGroup.observed", window: window, fields: observed)
    }

    static func state(_ name: String, _ state: ReaderState) {
        guard shared.enabled else { return }
        event(name, window: state.window, fields: stateValues(state))
    }

    private static func stateValues(_ state: ReaderState) -> [String: Any] {
        ["documentPresent": state.document != nil, "busy": state.busy,
         "generation": state.generation, "restoringPayload": state.restoredPayload != nil,
         "closed": state.isWindowClosed, "customChrome": state.usesCustomChrome,
         "floatingChrome": state.usesFloatingChrome, "toolbarMode": state.toolbarDisplayMode.rawValue,
         "toolbarShown": state.toolbarShown, "toolbarHover": state.toolbarHoverVisible,
         "page": state.page, "tabCount": state.tabCount]
    }

    static func chrome(_ window: NSWindow, state: ReaderState, fields: @autoclosure () -> [String: Any] = [:]) {
        guard shared.enabled else { return }
        var values = fields()
        values["reader"] = stateValues(state)
        event("chrome.applied", window: window, deduplicate: true, fields: values)
    }

    nonisolated static func safeError(_ error: Error) -> [String: Any] {
        ReaderDiagnosticLog.safeError(error)
    }

    func snapshot(_ name: String) {
        guard enabled, captureID != nil else { return }
        let windows = NSApp?.windows ?? []
        // WindowServer metadata is filtered to this process; titles and other apps are never exported.
        let server = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let own = server?.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == Int(ProcessInfo.processInfo.processIdentifier) }
            .map { entry -> [String: Any] in
                var record: [String: Any] = [:]
                for key in [kCGWindowNumber, kCGWindowLayer, kCGWindowAlpha, kCGWindowBounds] {
                    if let value = entry[key as String] { record[key as String] = value }
                }
                return record
            }
        record(name, fields: ["windows": windows.map(windowSnapshot),
                              "ownOnScreenWindows": own as Any? ?? NSNull(),
                              "automaticTabbing": NSWindow.allowsAutomaticWindowTabbing,
                              "separateSpaces": NSScreen.screensHaveSeparateSpaces,
                              "screens": NSScreen.screens.map { ["frame": Self.rect($0.frame),
                                                                  "visibleFrame": Self.rect($0.visibleFrame),
                                                                  "scale": $0.backingScaleFactor] }])
    }

    func markProblem() { snapshot("user.markedProblem") }

    func refresh() {
        log.inventory { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let size): self.fileCount = size.count; self.byteCount = size.bytes
                case .failure: self.lastError = L("Window diagnostics could not be read. Earlier logs have been kept.")
                }
            }
        }
    }

    func exportReport() {
        guard !isExporting else { return }
        snapshot("report.exportRequested")
        let panel = NSSavePanel()
        panel.title = L("Export Window Diagnostics")
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Sumra-Window-Diagnostics.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(to: destination) { result in
            if case .failure(let error) = result {
                if case ReaderDiagnosticLog.ExportError.noRecords = error {
                    Self.alert("No Window Diagnostics", "Enable window diagnostics, reproduce the problem, then export the report.")
                } else {
                    Self.alert("Export Failed", "Window diagnostics could not be exported. Earlier logs have been kept.")
                }
            }
        }
    }

    func export(to destination: URL, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        isExporting = true
        let metadata: [String: Any] = [
            "schema": 1, "exportedAtUnixTime": Date().timeIntervalSince1970, "completeness": "best_effort",
            "process": processID.uuidString, "activeCapture": captureID?.uuidString as Any? ?? NSNull(),
            "sequenceCapture": sequenceCaptureID?.uuidString as Any? ?? NSNull(),
            "recordingEnabled": enabled, "lastEnqueuedSequence": sequence,
            "privacy": "No document names, paths, contents, user text, screenshots or other applications' windows are recorded.",
            "notObserved": ["Private Space IDs, topology and window ownership by Space",
                            "SwiftUI/AppKit internal first order and native tab mutations before the app host attaches",
                            "Cached group membership can be stale until the next natural application getter",
                            "A crash or power loss can leave an incomplete final JSON line or unwritten tail",
                            "Recording adds observational overhead; group count and isOnActiveSpace do not prove visible pixels"]
        ]
        log.exportReport(to: destination, metadata: metadata) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.isExporting = false
                switch result {
                case .success: self?.refresh()
                case .failure(let error):
                    if case ReaderDiagnosticLog.ExportError.noRecords = error {} else {
                        self?.lastError = L("Window diagnostics could not be exported. Earlier logs have been kept.")
                    }
                }
                completion(result)
            }
        }
    }

    func showFolder() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !NSWorkspace.shared.open(directory) {
                Self.alert("Unable to Open Diagnostics Folder", "The diagnostics folder could not be opened.")
            }
        } catch { Self.alert("Unable to Open Diagnostics Folder", "The diagnostics folder could not be opened.") }
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = L(title)
        alert.informativeText = L(message)
        alert.runModal()
    }
}
#endif
