#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

/// Manual CUA acceptance only. Ordinary test runs skip this event-loop host.
@MainActor
final class FeedbackInteractionHarnessTests: XCTestCase {
    func testPreparedHoverPhysicalClickAndProductionColorsDialog() throws {
        guard ProcessInfo.processInfo.environment["SUMRA_FEEDBACK_INTERACTION_HARNESS"] == "1" else {
            throw XCTSkip("Set SUMRA_FEEDBACK_INTERACTION_HARNESS=1 for manual CUA interaction")
        }
        let app = NSApplication.shared
        guard !app.isRunning else { throw XCTSkip("Run this harness alone in an unhosted XCTest process") }
        let policy = app.activationPolicy(), menu = app.mainMenu
        let harness = try FeedbackInteractionHarness(directory: TemporaryDirectory())
        defer {
            harness.close()
            app.mainMenu = menu
            app.setActivationPolicy(policy)
        }
        app.setActivationPolicy(.regular)
        harness.start()
        app.run()
        XCTAssertTrue(harness.receipt.finishedByControl, "Use the harness Finish control after CUA interaction")
        XCTAssertTrue(harness.receipt.destinationPainted, "The first measured click must paint the link destination")
        XCTAssertTrue(harness.receipt.previewClosedAfterNavigation)
        if harness.receipt.physicalHoverRequested {
            XCTAssertTrue(harness.receipt.physicalPointerEntryVerified, "Physical mode requires the actual source-link tracking entry")
            XCTAssertTrue(harness.receipt.cursorFeedbackVerified, "Physical mode requires observed pointing-hand feedback")
        }
        XCTAssertEqual(harness.receipt.downCount, 1)
        XCTAssertEqual(harness.receipt.upCount, 1)
        XCTAssertTrue(harness.receipt.rejections.isEmpty, harness.receipt.rejections.joined(separator: "; "))
        XCTAssertNil(harness.receipt.error)
        XCTAssertNil(harness.writeError)
    }
}

@MainActor
private final class FeedbackInteractionHarness: NSObject, NSWindowDelegate {
    struct MouseReceipt: Codable {
        let kind: String, timestamp: TimeInterval, point: String
        let sourceWindow: Bool, keyWindow: Bool, canvasHit: Bool, insideLink: Bool
        let previewVisible: Bool, previewIgnoresMouseEvents: Bool
    }
    struct ColorsReceipt: Codable, Equatable {
        let text: String, background: String, link: String
        let activeWell: String?, panelVisible: Bool, panelColor: String?
    }
    struct WindowReceipt: Codable, Equatable {
        let title: String, windowNumber: Int, frame: String, className: String
        let isKey: Bool, isMain: Bool, isVisible: Bool, isColorPanel: Bool
    }
    struct WindowSnapshot: Codable {
        let timestamp: TimeInterval
        let windows: [WindowReceipt]
    }
    struct PointerReceipt: Codable {
        let kind: String, timestamp: TimeInterval, phase: String, windowNumber: Int, point: String
        let sourceWindow: Bool, insideSourceLink: Bool?, sourceURI: String?
        var sampleTiming: String, pointingHand: Bool
    }
    struct Receipt: Codable {
        var phase = "starting"
        var processID = ProcessInfo.processInfo.processIdentifier
        var windowTitle = "Sumra Feedback Interaction Harness"
        var sourceLinkScreenRect: String?
        var preparation = "Programmatic Canvas.mouseMoved; no synthetic mouse-down/up"
        var physicalHoverRequested = false
        var physicalPointerEntryVerified = false
        var cursorFeedbackVerified = false
        var previewVisibleAtDown: Bool?
        var previewAtArming: WindowReceipt?
        var downCount = 0, upCount = 0
        var events = [MouseReceipt]()
        var rejections = [String]()
        var destinationPainted = false, previewClosedAfterNavigation = false
        var finishedByControl = false
        var colorsDialogCalls = 0
        var colorsObservations = [ColorsReceipt]()
        var windowsWhileColorPanelVisible = [WindowSnapshot]()
        var pointerEventCounts = [String: Int]()
        var pointerObservations = [PointerReceipt]()
        var appliedDocumentColors: [String: String]?
        var lastOwnedInteractionAt: TimeInterval?
        var error: String?
    }

    private(set) var receipt = Receipt()
    private(set) var writeError: String?
    private let directory: TemporaryDirectory
    private let pages: Pages
    private let state = ReaderState(recordsHistory: false)
    private let window = NSWindow(contentRect: CGRect(x: 160, y: 120, width: 760, height: 700),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let status = NSTextField(labelWithString: "Preparing the production reader…")
    private var host: NSHostingView<ReaderView>!
    private var task: Task<Void, Never>?
    private var timer: Timer?, monitor: Any?
    private weak var sourceCanvas: RasterCanvas.Canvas?
    private var sourceLink: RasterLink?
    private var sourcePosition = ReadingPosition(page: 0), destinationPage: Int?
    private var expired = false
    private var physicalHoverMode = false
    private var pointerDirty = false
    private var lastPointerWrite = Date.distantPast
    private var lastInteractionUptime = ProcessInfo.processInfo.systemUptime
    private let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/issue42/feedback-interaction-harness.json")

    init(directory: TemporaryDirectory) throws {
        self.directory = directory
        let input = directory.url.appendingPathComponent("feedback-link.md")
        try ("[Click this source link](#destination)\n\n"
            + String(repeating: "The source remains here while the destination is on a later page.\n\n", count: 60)
            + "# Destination\n\nHARNESS DESTINATION REACHED.\n")
            .write(to: input, atomically: true, encoding: .utf8)
        pages = try Pages(input, format: .markdown)
        super.init()
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.flow = "paged"; state.spread = false; state.cover = false; state.automaticLayout = false
        state.fit = "page"; state.zoom = 1; state.font = "system"; state.fontSize = 17; state.lineHeight = 1.6
        state.theme = "light"; state.margin = 32; state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.rectangularSelection = false; state.keyboardTextSelection = false
        state.keyboardLinkFollowing = false; state.hoverPreview = true; state.disableLinks = false
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.landscapeAsSpread = false
        state.showContents = false; state.scrollbarMode = "hidden"
        host = NSHostingView(rootView: ReaderView(state: state))
        window.title = receipt.windowTitle; window.isReleasedWhenClosed = false; window.delegate = self
        window.acceptsMouseMovedEvents = true
        state.window = window
        let content = NSView(), buttons = NSStackView()
        buttons.orientation = .horizontal; buttons.spacing = 12
        for (title, action, key) in [("Reset + Prepare Hover (⌘R)", #selector(prepareHover), "r"),
            ("Document Colors (⌘K)", #selector(colors), "k"), ("Finish (⌘Return)", #selector(finish), "\r")] {
            let button = NSButton(title: title, target: self, action: action)
            button.keyEquivalent = key; button.keyEquivalentModifierMask = .command
            buttons.addArrangedSubview(button)
        }
        let showColors = NSButton(title: "Show Colors (⇧⌘C)", target: self, action: #selector(showSystemColors(_:)))
        showColors.keyEquivalent = "c"; showColors.keyEquivalentModifierMask = [.command, .shift]
        buttons.addArrangedSubview(showColors)
        let physicalHover = NSButton(title: "Reset for Physical Hover (⇧⌘R)", target: self, action: #selector(preparePhysicalHover))
        physicalHover.keyEquivalent = "r"; physicalHover.keyEquivalentModifierMask = [.command, .shift]
        let instructions = NSTextField(wrappingLabelWithString:
            "Physical hover: ⇧⌘R, then move outside and onto the source link. Wait for ARMED and click once. Programmatic preparation remains on ⌘R. Colors uses the production modal dialog; ⌘Return finishes.")
        let views: [NSView] = [buttons, physicalHover, instructions, status, host!]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            physicalHover.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 4), physicalHover.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            instructions.topAnchor.constraint(equalTo: physicalHover.bottomAnchor, constant: 4), instructions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            instructions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), instructions.heightAnchor.constraint(equalToConstant: 44),
            status.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 4), status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), status.heightAnchor.constraint(equalToConstant: 24),
            host.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4), host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor), host.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        let main = NSMenu(), item = NSMenuItem(), actions = NSMenu(title: "Harness")
        main.addItem(item); item.submenu = actions
        for (title, action, key) in [("Reset + Prepare Hover", #selector(prepareHover), "r"),
            ("Document Colors", #selector(colors), "k"), ("Finish", #selector(finish), "\r")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self
            actions.addItem(entry)
        }
        let colorsItem = NSMenuItem(title: "Show Colors", action: #selector(showSystemColors(_:)), keyEquivalent: "c")
        colorsItem.target = self; colorsItem.keyEquivalentModifierMask = [.command, .shift]
        actions.addItem(colorsItem)
        let physicalItem = NSMenuItem(title: "Reset for Physical Hover", action: #selector(preparePhysicalHover), keyEquivalent: "r")
        physicalItem.target = self; physicalItem.keyEquivalentModifierMask = [.command, .shift]
        actions.addItem(physicalItem)
        NSApp.mainMenu = main
    }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved,
            .mouseEntered, .mouseExited, .cursorUpdate, .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        let pulse = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = pulse
        RunLoop.main.add(pulse, forMode: .common); RunLoop.main.add(pulse, forMode: .modalPanel)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await pages.prepare()
                state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
                _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                    pageSize: CGSize(width: 760, height: 570))
                _ = state.applyChapterLayout(await pages.chapterLayout)
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await waitForSource()
                sourcePosition = state.currentPosition
                setPhase("calibration", "Click the source link once, keep the pointer there, then press ⌘R.")
            } catch { fail(error) }
        }
    }

    @objc private func prepareHover() { beginHover(physical: false) }
    @objc private func preparePhysicalHover() { beginHover(physical: true) }
    private func beginHover(physical: Bool) {
        guard !expired else { return }
        noteInteraction()
        task?.cancel()
        physicalHoverMode = physical
        receipt.physicalHoverRequested = physical
        receipt.downCount = 0; receipt.upCount = 0; receipt.events = []; receipt.rejections = []
        receipt.previewVisibleAtDown = nil; receipt.destinationPainted = false; receipt.previewClosedAfterNavigation = false
        receipt.previewAtArming = nil; receipt.physicalPointerEntryVerified = false; receipt.cursorFeedbackVerified = false; receipt.error = nil
        receipt.preparation = physical ? "Physical pointer entry; no programmatic Canvas.mouseMoved" : "Programmatic Canvas.mouseMoved; no synthetic mouse-down/up"
        setPhase("preparing", physical ? "Resetting for physical hover; move outside the source link." : "Resetting and preparing hover; keep the pointer stationary.")
        // Let the production interaction update dismiss any previous preview.
        // The physical branch never calls Canvas.mouseMoved itself.
        state.hoverPreview = !physical
        state.restore(sourcePosition)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitForSource()
                let canvas = try XCTUnwrap(sourceCanvas), link = try XCTUnwrap(sourceLink)
                let position = try await pages.resolve(link.uri, from: sourcePosition)
                destinationPage = try XCTUnwrap(position).page
                state.hoverPreview = true
                if physical {
                    setPhase("hover-ready", "HOVER READY: move outside, then onto the source link; wait for the real preview.")
                    return
                }
                let point = canvas.convert(CGPoint(x: link.bounds.midX, y: link.bounds.midY).applying(canvas.pageTransform), to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                canvas.mouseMoved(with: event)
                let until = Date().addingTimeInterval(10)
                while preview?.isVisible != true, Date() < until {
                    try Task.checkCancellation(); try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard preview?.isVisible == true else { throw ReadError("The production hover preview did not open") }
                setPhase("armed", "ARMED: preview is open. Click the source link once without moving away.")
            } catch is CancellationError { }
            catch { fail(error) }
        }
    }

    private var preview: NSWindow? { window.childWindows?.first { $0.contentView is NSImageView } }

    private func waitForSource() async throws {
        let until = Date().addingTimeInterval(15)
        var stable = 0, lastRevision = -1
        while Date() < until {
            try Task.checkCancellation()
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let revision = await pages.layoutRevision
            if state.page == 0, let canvas = descendants(host, RasterCanvas.Canvas.self).first(where: {
                $0.readingReady && $0.links.contains { $0.uri == "#destination" }
            }), let link = canvas.links.first(where: { $0.uri == "#destination" }),
               canvas.visibleRect.intersects(link.bounds.applying(canvas.pageTransform)) {
                stable = lastRevision == revision ? stable + 1 : 0
                if stable == 10 {
                    sourceCanvas = canvas; sourceLink = link
                    receipt.sourceLinkScreenRect = NSStringFromRect(window.convertToScreen(canvas.convert(link.bounds.applying(canvas.pageTransform), to: nil)))
                    return
                }
            } else { stable = 0 }
            lastRevision = revision
            if let error = state.error { throw ReadError(error) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ReadError("The production source link did not become visible")
    }

    private func observe(_ event: NSEvent) {
        if let target = event.window, NSApp.windows.contains(where: { $0 === target }),
           [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .scrollWheel, .keyDown].contains(event.type) {
            noteInteraction()
        }
        observePointer(event)
        guard event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
        guard receipt.phase == "armed" || receipt.phase == "clicked", let canvas = sourceCanvas, let link = sourceLink else { return }
        let content = window.contentView
        let parentPoint = content?.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        let hit = content?.hitTest(parentPoint)
        let point = canvas.convert(event.locationInWindow, from: nil).applying(canvas.pageTransform.inverted())
        let entry = MouseReceipt(kind: event.type == .leftMouseDown ? "down" : "up", timestamp: event.timestamp,
            point: NSStringFromPoint(event.locationInWindow), sourceWindow: event.window === window,
            keyWindow: window.isKeyWindow, canvasHit: hit === canvas, insideLink: link.bounds.contains(point),
            previewVisible: preview?.isVisible == true, previewIgnoresMouseEvents: preview?.ignoresMouseEvents == true)
        receipt.events.append(entry)
        if event.type == .leftMouseDown {
            receipt.downCount += 1
            if receipt.downCount == 1 {
                receipt.previewVisibleAtDown = entry.previewVisible
                if !entry.previewVisible { receipt.rejections.append("Preview was not visible at actual mouse-down; pointer entry may have restarted hover") }
                if !entry.previewIgnoresMouseEvents { receipt.rejections.append("Preview was not configured to pass mouse events through") }
                if !entry.sourceWindow || !entry.keyWindow || !entry.canvasHit || !entry.insideLink {
                    receipt.rejections.append("Actual mouse-down did not target the source link in the key reader window")
                }
            } else { receipt.rejections.append("More than one mouse-down occurred before the destination painted") }
            setPhase("clicked", "Mouse-down recorded; waiting for native destination paint.")
        } else { receipt.upCount += 1; writeReceipt() }
    }

    private func tick() {
        if ProcessInfo.processInfo.systemUptime - lastInteractionUptime >= 600, !expired {
            expired = true; receipt.error = "Manual harness expired after 600 seconds without owned input"
            stop(); return
        }
        if receipt.phase == "hover-ready", preview?.isVisible == true {
            setPhase("armed", "ARMED: native hover opened the preview. Click the source link once.")
        }
        if receipt.phase == "clicked", receipt.upCount > 0, let destinationPage,
           state.page == destinationPage,
           descendants(host, RasterCanvas.Canvas.self).contains(where: {
               $0.page == destinationPage && $0.readingReady && $0.hasPaintedPreview && !$0.visibleRect.isEmpty
           }) {
            receipt.destinationPainted = true; receipt.previewClosedAfterNavigation = preview?.isVisible != true
            setPhase("complete", "Destination painted. Optional: Document Colors. Finish with ⌘Return.")
        }
        if let content = NSApp.modalWindow?.contentView, let editor = descendants(content, ReaderThemeEditorView.self).first {
            let active = editor.text.well.isActive ? "text" : editor.paper.well.isActive ? "background" : editor.link.well.isActive ? "link" : nil
            let observation = ColorsReceipt(text: editor.text.hex.stringValue, background: editor.paper.hex.stringValue,
                link: editor.link.hex.stringValue, activeWell: active,
                panelVisible: NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible,
                panelColor: NSColorPanel.sharedColorPanelExists ? ReaderTheme.rgb(NSColorPanel.shared.color).map(hex) : nil)
            if receipt.colorsObservations.last != observation { receipt.colorsObservations.append(observation); writeReceipt() }
        }
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
            let windows = NSApp.windows.map(windowReceipt)
            if receipt.windowsWhileColorPanelVisible.last?.windows != windows {
                receipt.windowsWhileColorPanelVisible.append(WindowSnapshot(timestamp: Date().timeIntervalSince1970, windows: windows))
                writeReceipt()
            }
        }
        if pointerDirty, Date().timeIntervalSince(lastPointerWrite) >= 0.25 {
            pointerDirty = false; lastPointerWrite = Date(); writeReceipt()
        }
    }

    private func observePointer(_ event: NSEvent) {
        let kind: String
        switch event.type {
        case .leftMouseDown: kind = "mouseDown"
        case .leftMouseUp: kind = "mouseUp"
        case .mouseMoved: kind = "mouseMoved"
        case .mouseEntered: kind = "mouseEntered"
        case .mouseExited: kind = "mouseExited"
        case .cursorUpdate: kind = "cursorUpdate"
        case .leftMouseDragged: kind = "mouseDragged"
        case .scrollWheel: kind = "scrollWheel"
        default: return
        }
        receipt.pointerEventCounts[kind, default: 0] += 1
        let inside = sourceCanvas.flatMap { canvas in sourceLink.map {
            $0.bounds.contains(canvas.convert(event.locationInWindow, from: nil).applying(canvas.pageTransform.inverted()))
        } }
        let physicalAtEvent = physicalHoverMode
        let sample = PointerReceipt(kind: kind, timestamp: event.timestamp, phase: receipt.phase,
            windowNumber: event.windowNumber, point: NSStringFromPoint(event.locationInWindow),
            sourceWindow: event.window === window, insideSourceLink: event.window === window ? inside : nil,
            sourceURI: event.window === window && inside == true ? sourceLink?.uri : nil,
            sampleTiming: "beforeDispatch", pointingHand: NSCursor.current.isEqual(NSCursor.pointingHand))
        if physicalHoverMode, receipt.phase == "hover-ready" || receipt.phase == "armed",
           [.mouseEntered, .mouseMoved].contains(event.type), sample.sourceWindow, sample.insideSourceLink == true,
           sample.sourceURI == sourceLink?.uri {
            receipt.physicalPointerEntryVerified = true
        }
        receipt.pointerObservations.append(sample); pointerDirty = true
        // Observe cursor updates after AppKit dispatch too; no event is changed
        // or injected. Direct programmatic hover preparation bypasses this monitor.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.receipt.phase != "finished" else { return }
            var after = sample; after.sampleTiming = "afterDispatch"
            after.pointingHand = NSCursor.current.isEqual(NSCursor.pointingHand)
            if physicalAtEvent, self.physicalHoverMode,
               self.receipt.phase == "hover-ready" || self.receipt.phase == "armed",
               after.phase == "hover-ready" || after.phase == "armed",
               after.sourceWindow, after.insideSourceLink == true, after.pointingHand {
                self.receipt.cursorFeedbackVerified = true
            }
            self.receipt.pointerObservations.append(after); self.pointerDirty = true
        }
    }

    @objc private func colors() {
        guard !expired, receipt.phase != "preparing" else { return }
        noteInteraction()
        if receipt.phase != "complete" { setPhase("calibration", "Colors interaction; prepare hover afterward with ⌘R.") }
        receipt.colorsDialogCalls += 1; writeReceipt()
        state.configureDocumentColors()
        receipt.appliedDocumentColors = ["text": state.customTextColor.map(hex) ?? "theme",
            "background": state.customBackgroundColor.map(hex) ?? "theme", "link": state.customLinkColor.map(hex) ?? "theme"]
        writeReceipt()
    }

    @objc private func showSystemColors(_ sender: Any?) {
        guard !expired else { return }
        noteInteraction()
        NSApp.orderFrontColorPanel(sender)
    }

    private func noteInteraction() {
        lastInteractionUptime = ProcessInfo.processInfo.systemUptime
        receipt.lastOwnedInteractionAt = Date().timeIntervalSince1970
        pointerDirty = true
    }

    @objc private func finish() { receipt.finishedByControl = true; stop() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(); return false }
    private func stop() {
        receipt.phase = "finished"; writeReceipt()
        if NSApp.modalWindow != nil {
            // Stop the outer application loop only after the production modal
            // session unwinds. Stopping inside modalPanel can leave run() alive.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { self.stopApplicationLoop() }
            }
            NSApp.abortModal()
            wakeApplicationLoop()
        } else { stopApplicationLoop() }
    }
    private func stopApplicationLoop() {
        NSApp.stop(nil)
        wakeApplicationLoop()
    }
    private func wakeApplicationLoop() {
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(wake, atStart: true) }
    }
    private func fail(_ error: Error) {
        guard !expired else { return }
        receipt.error = String(describing: error); setPhase("error", receipt.error ?? "Harness error")
    }
    private func setPhase(_ phase: String, _ message: String) {
        receipt.phase = phase; status.stringValue = message
        if phase == "armed", let preview { receipt.previewAtArming = windowReceipt(preview) }
        window.title = receipt.windowTitle + " — " + phase.uppercased(); writeReceipt()
    }
    private func writeReceipt() {
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipt).write(to: output, options: .atomic)
        } catch { writeError = String(describing: error) }
    }
    private func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
    private func windowReceipt(_ window: NSWindow) -> WindowReceipt {
        WindowReceipt(title: window.title, windowNumber: window.windowNumber, frame: NSStringFromRect(window.frame),
            className: NSStringFromClass(type(of: window)), isKey: window.isKeyWindow, isMain: window.isMainWindow,
            isVisible: window.isVisible, isColorPanel: window is NSColorPanel)
    }
    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
    func close() {
        task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        state.windowClosed(); window.makeFirstResponder(nil); window.delegate = nil; window.contentView = nil; window.close()
    }
}

#endif
