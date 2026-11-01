#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderFullscreenTitleLayoutTests: XCTestCase {
    private struct NativeLayout {
        let titles: [(NSTextField, CGRect)]
        let buttons: [(NSButton, CGRect)]
        let icons: [(NSButton, CGRect)]
    }

    func testRealFullscreenNativeTitleAndDocumentIconAvoidWindowButtonsAfterTabSelection() async throws {
        guard ProcessInfo.processInfo.environment["SUMRA_FULLSCREEN_TITLE_GUI"] == "1" else {
            throw XCTSkip("This test enters a real fullscreen Space; opt in with SUMRA_FULLSCREEN_TITLE_GUI=1")
        }
        guard #available(macOS 15, *) else {
            throw XCTSkip("This fixture exercises the public SwiftUI fullscreen toolbar policy on macOS 15+")
        }
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        let previousMenuVisible = NSMenu.menuBarVisible()
        let previousPresentation = NSApp.presentationOptions
        let previousActivation = NSApp.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let directory = try TemporaryDirectory()
        let menu = NSMenu(title: "Window"), main = NSMenu(title: "Sumra fullscreen title fixture")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = menu
        NSApp.mainMenu = main; NSApp.windowsMenu = menu
        NSApp.setActivationPolicy(.regular)

        let names = [
            "Fullscreen native title first document with a long readable filename.txt",
            "Fullscreen native title second document after selecting another native tab.txt"
        ]
        var states: [ReaderState] = [], windows: [NSWindow] = []
        defer {
            for (state, window) in zip(states, windows) {
                window.orderOut(nil); NSApp.removeWindowsItem(window)
                state.windowClosed(); window.contentViewController = nil; window.close()
            }
            NSApp.presentationOptions = previousPresentation
            NSMenu.setMenuBarVisible(previousMenuVisible)
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu
            NSApp.setActivationPolicy(previousActivation)
            if previousApplication?.processIdentifier != getpid() {
                previousApplication?.activate(options: [])
            }
            withExtendedLifetime(directory) {}
        }
        for (index, name) in names.enumerated() {
            let input = directory.url.appendingPathComponent(name)
            let text = "Public fullscreen title fixture \(index).\n" + String(repeating: "Reading text remains below the native toolbar.\n", count: 40)
            try text.write(to: input, atomically: true, encoding: .utf8)
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: input, content: .text(text))
            state.immersiveControls = false; state.toolbarDisplayMode = .shown
            state.showContents = false; state.showAI = false; state.showFind = false
            let controller = NSHostingController(rootView: ReaderView(state: state).navigationTitle(name))
            let window = NSWindow(contentViewController: controller)
            window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
            window.isReleasedWhenClosed = false; window.toolbarStyle = .unifiedCompact
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.representedURL = input; window.isExcludedFromWindowsMenu = false
            window.setContentSize(NSSize(width: 1000, height: 600))
            state.window = window
            states.append(state); windows.append(window)
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        let group = try XCTUnwrap(windows[0].tabGroup)
        group.selectedWindow = windows[0]
        windows[0].makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let activationDeadline = Date().addingTimeInterval(5)
        while (!NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid()), Date() < activationDeadline {
            dispatchPendingAppKitEvents(until: activationDeadline)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard NSApp.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            XCTFail("Fixture condition not met: the test's own application must receive its real activation events")
            return
        }

        // Exiting fullscreen needs an asynchronous notification too. Keep that
        // cleanup outside the synchronous defer, including assertion/error paths.
        do {
            try await transition(windows[0], entering: true)
            let fullscreenPresentation = NSApp.presentationOptions
            let evidenceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/feedback-68-69-20261030/fullscreen-title-overlap", isDirectory: true)
            try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            let evidenceLabel = ProcessInfo.processInfo.environment["SUMRA_FULLSCREEN_TITLE_EVIDENCE_LABEL"] ?? "real-fullscreen-positive"
            for index in [0, 1] {
                group.selectedWindow = windows[index]
                windows[index].makeKeyAndOrderFront(nil)
                print("[fullscreen-title] selected=\(index) title=\(windows[index].title) tab=\(String(describing: windows[index].tab.title)) menu=\(menu.items.map(\.title))")
                XCTAssertTrue(windows[index].styleMask.contains(.fullScreen), "The selected native tab must actually be fullscreen")
                XCTAssertTrue(group.selectedWindow === windows[index])
                XCTAssertEqual(windows[index].title, names[index])
                XCTAssertEqual(windows[index].tab.title, names[index])
                XCTAssertTrue(menu.items.contains { $0.title == names[index] }, "The native Window menu retains the document name")
                // Keep the actual system menu unrevealed. AppKit owns whether
                // its traffic lights are present beside the persistent title.
                NSApp.presentationOptions = fullscreenPresentation
                NSMenu.setMenuBarVisible(false)
                let menuDeadline = Date().addingTimeInterval(5)
                while (!NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() ||
                       NSMenu.menuBarVisible()), Date() < menuDeadline {
                    dispatchPendingAppKitEvents(until: menuDeadline)
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let phase = "tab\(index)-menu-hidden"
                print("[fullscreen-title] phase=\(phase)")
                let layout = await settledLayout(for: windows[index], excluding: windows.compactMap(\.contentView))
                try saveCompanion(layout, for: windows[index], to: evidenceDirectory.appendingPathComponent("\(evidenceLabel)-\(phase).png"))
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard NSApp.isActive, frontmostPID == getpid(), !NSMenu.menuBarVisible() else {
                    XCTFail("Fixture condition not met: \(phase) requires an active foreground test application and an unrevealed real system menu")
                    continue
                }
                assertNoOverlap(layout, expectedTitle: names[index], phase: phase)
            }
            NSApp.presentationOptions = fullscreenPresentation
        } catch {
            if let fullscreen = group.selectedWindow, fullscreen.styleMask.contains(.fullScreen) {
                try await transition(fullscreen, entering: false)
            }
            throw error
        }
        if let fullscreen = group.selectedWindow, fullscreen.styleMask.contains(.fullScreen) {
            try await transition(fullscreen, entering: false)
        }
    }

    func testNativeFullscreenButtonAlphaBelongsToAppKitAcrossToolbarModes() throws {
        final class FullscreenWindow: NSWindow {
            var fullscreen = false
            override var styleMask: NSWindow.StyleMask {
                get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
                set { super.styleMask = newValue.subtracting(.fullScreen) }
            }
        }
        // This is an ownership unit test using real AppKit buttons. The mask
        // override exercises Host branches without claiming real Space/menu QA.
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-fullscreen-alpha-owner.txt"), content: .text("Book"))
        state.immersiveControls = false; state.toolbarDisplayMode = .shown
        let window = FullscreenWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try XCTUnwrap(window.standardWindowButton($0))
        }
        let originalHidden = buttons.map(\.isHidden)
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer {
            observer.detach(); window.fullscreen = false
            window.contentView = nil; window.close(); state.windowClosed()
        }
        window.fullscreen = true
        for systemAlpha in [CGFloat(0), 0.5, 1] {
            for mode in [ReaderToolbarDisplayMode.hidden, .shown, .auto] {
                state.toolbarDisplayMode = mode
                state.toolbarHoverVisible = false
                for revealed in [false, true, false] {
                    // The mask override still uses windowed AppKit layout,
                    // which can expose its buttons between Host calls. Seed
                    // the owned hidden state when verifying its handoff.
                    if mode == .shown || revealed {
                        for button in buttons { button.isHidden = true }
                    }
                    for button in buttons { button.alphaValue = systemAlpha }
                    observer.updateChrome(revealingNativeControls: revealed)
                    for (index, button) in buttons.enumerated() {
                        let context = "mode=\(mode), revealed=\(revealed), index=\(index), hover=\(state.toolbarHoverVisible), systemAlpha=\(systemAlpha)"
                        XCTAssertEqual(button.alphaValue, systemAlpha,
                            "Native fullscreen alpha belongs to AppKit: \(context)")
                        if mode == .shown || revealed {
                            XCTAssertEqual(button.isHidden, originalHidden[index],
                                "Host must hand isHidden back when Hidden changes to Shown or native controls reveal: \(context)")
                        }
                    }
                }
            }
        }
        // These are the same captured native buttons throughout the handoff;
        // floating factory controls have separate integration coverage.
        state.toolbarDisplayMode = .shown
        for button in buttons { button.alphaValue = 0.5 }
        for floating in [false, true, false] {
            state.immersiveControls = floating
            observer.updateChrome(revealingNativeControls: false)
            for (index, button) in buttons.enumerated() {
                XCTAssertEqual(button.alphaValue, 0.5,
                    "Captured native fullscreen alpha survives native→floating→native: floating=\(floating), index=\(index)")
            }
        }
        for button in buttons { button.alphaValue = 0.5 }
        observer.detach()
        for (index, button) in buttons.enumerated() {
            XCTAssertEqual(button.alphaValue, 0.5,
                "Detaching the observer must preserve the captured native button's current system fullscreen alpha: index=\(index)")
        }
        XCTAssertFalse(window.isVisible, "The ownership unit test must not create a fullscreen Space or visible window")
    }

    // XCTest services its run loop without running NSApplication.run(). Deliver
    // this process's queued AppKit activation/menu events through the real app
    // dispatcher rather than posting synthetic lifecycle notifications.
    private func dispatchPendingAppKitEvents(until deadline: Date) {
        while Date() < deadline,
              let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    private func transition(_ window: NSWindow, entering: Bool) async throws {
        let name = entering ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let completed = expectation(forNotification: name, object: window)
        print("[fullscreen-title] transition \(entering ? "enter" : "exit") window=\(window.windowNumber) frame=\(window.frame)")
        window.toggleFullScreen(nil)
        await fulfillment(of: [completed], timeout: 15)
        guard window.styleMask.contains(.fullScreen) == entering else {
            throw NSError(domain: "ReaderFullscreenTitleLayoutTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture fullscreen transition did not reach its requested state"])
        }
    }

    private func assertNoOverlap(_ layout: NativeLayout, expectedTitle: String, phase: String) {
        guard !layout.titles.isEmpty else {
            XCTFail("Fixture condition not met: \(phase) needs a visible native title")
            return
        }
        for (title, frame) in layout.titles {
            XCTAssertEqual(title.accessibilityValue(), expectedTitle, "\(phase): the native title keeps its accessibility name")
            for (_, buttonFrame) in layout.buttons {
                XCTAssertFalse(frame.intersects(buttonFrame), "\(phase): native title overlaps a visible fullscreen window button: title=\(frame), button=\(buttonFrame)")
            }
        }
        for (_, iconFrame) in layout.icons {
            for (_, buttonFrame) in layout.buttons {
                XCTAssertFalse(iconFrame.intersects(buttonFrame), "\(phase): document icon overlaps a visible fullscreen window button: icon=\(iconFrame), button=\(buttonFrame)")
            }
        }
    }

    private func saveCompanion(_ layout: NativeLayout, for window: NSWindow, to output: URL) throws {
        let companion = try XCTUnwrap(layout.titles.first?.0.window,
            "Fixture condition not met: a native title owner is needed to capture its actual companion")
        XCTAssertFalse(companion === window, "The capture must belong to AppKit's actual fullscreen companion")
        let view = try XCTUnwrap(companion.contentView)
        let height = min(110, view.bounds.height)
        let rect = CGRect(x: view.bounds.minX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - height,
            width: min(1100, view.bounds.width), height: height)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output)
        print("[fullscreen-title] companion PNG=\(output.path) rect=\(rect) window=\(companion.windowNumber)")
    }

    private func settledLayout(for window: NSWindow, excluding readerRoots: [NSView]) async -> NativeLayout {
        let deadline = Date().addingTimeInterval(5)
        dispatchPendingAppKitEvents(until: deadline)
        var layout = nativeLayout(for: window, excluding: readerRoots, diagnose: false)
        while layout.titles.isEmpty, Date() < deadline {
            dispatchPendingAppKitEvents(until: deadline)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
            layout = nativeLayout(for: window, excluding: readerRoots, diagnose: false)
        }
        return nativeLayout(for: window, excluding: readerRoots, diagnose: true)
    }

    private func nativeLayout(for window: NSWindow, excluding readerRoots: [NSView], diagnose: Bool) -> NativeLayout {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let nativeButtons = types.compactMap { window.standardWindowButton($0) }
        let icon = window.standardWindowButton(.documentIconButton)
        var roots: [NSWindow] = [window]
        for candidate in (window.childWindows ?? []) + (nativeButtons + (icon.map { [$0] } ?? [])).compactMap(\.window) {
            if !roots.contains(where: { $0 === candidate }) { roots.append(candidate) }
        }
        let accessoryRoots = (window.tabbedWindows ?? [window]).flatMap(\.titlebarAccessoryViewControllers).map(\.view)
        func visible(_ view: NSView) -> Bool {
            guard let owner = view.window, owner.isVisible, owner.alphaValue > 0 else { return false }
            guard !view.visibleRect.intersection(view.bounds).isEmpty else { return false }
            var current: NSView? = view
            while let ancestor = current {
                if ancestor.isHidden || ancestor.alphaValue <= 0 { return false }
                current = ancestor.superview
            }
            return true
        }
        func screenRect(_ view: NSView) -> CGRect {
            guard let owner = view.window else { return .zero }
            return owner.convertToScreen(view.convert(view.bounds, to: nil))
        }
        func describe(_ view: NSView, kind: String) {
            guard diagnose else { return }
            var hierarchy: [String] = [], current: NSView? = view
            while let ancestor = current {
                hierarchy.append("\(type(of: ancestor))(hidden=\(ancestor.isHidden),alpha=\(ancestor.alphaValue),frame=\(ancestor.frame))")
                current = ancestor.superview
            }
            print("[fullscreen-title] \(kind) visible=\(visible(view)) screen=\(screenRect(view)) window=\(view.window?.windowNumber ?? -1) ax=\(String(describing: view.accessibilityValue())) hierarchy=\(hierarchy.joined(separator: " -> "))")
        }
        func titles(in view: NSView) -> [NSTextField] {
            if readerRoots.contains(where: { view === $0 }) { return [] }
            var found: [NSTextField] = []
            if let title = view as? NSTextField, title.stringValue == window.title {
                let isAccessory = accessoryRoots.contains { title === $0 || title.isDescendant(of: $0) }
                describe(title, kind: isAccessory ? "accessory-title" : "native-title")
                if !isAccessory, visible(title) { found.append(title) }
            }
            return found + view.subviews.flatMap { titles(in: $0) }
        }
        if diagnose {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            print("[fullscreen-title] selected=\(window.windowNumber) fullScreen=\(window.styleMask.contains(.fullScreen)) active=\(NSApp.isActive) testPID=\(getpid()) frontmostPID=\(String(describing: frontmostPID)) presentation=\(NSApp.presentationOptions.rawValue) systemPresentation=\(NSApp.currentSystemPresentationOptions.rawValue) menuVisible=\(NSMenu.menuBarVisible()) titleVisibility=\(window.titleVisibility.rawValue) representedURL=\(String(describing: window.representedURL))")
            for root in roots { print("[fullscreen-title] owner=\(root.windowNumber) visible=\(root.isVisible) alpha=\(root.alphaValue) frame=\(root.frame) parent=\(root.parent?.windowNumber ?? -1)") }
        }
        for button in nativeButtons { describe(button, kind: "traffic-light-\(button.tag)") }
        if let icon { describe(icon, kind: "document-icon") }
        let nativeTitles = roots.compactMap { $0.contentView?.superview }.flatMap { titles(in: $0) }
        return NativeLayout(titles: nativeTitles.map { ($0, screenRect($0)) },
            buttons: nativeButtons.filter(visible).map { ($0, screenRect($0)) },
            icons: (icon.map { [$0] } ?? []).filter(visible).map { ($0, screenRect($0)) })
    }
}
#endif
