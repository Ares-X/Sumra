#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderHomeFullscreenTests: XCTestCase {
    func testHomeFullscreenControlsFollowThePointerForEveryReadingToolbarPreference() async throws {
        for mode in ReaderToolbarDisplayMode.allCases {
            let fixture = Fixture(mode: mode)
            defer { fixture.close() }
            try await fixture.settle()
            try fixture.assertControls(visible: true)

            fixture.window.simulatesFullscreen = true
            fixture.observer.updateChrome(revealingNativeControls: false)
            try await fixture.settle()
            try fixture.assertControls(visible: false)
            let welcomeFrame = try fixture.welcomeOpenFrame()
            let controlsFrame = try fixture.controlsFrame()

            fixture.movePointer(depth: 20)
            try await fixture.settle()
            try fixture.assertControls(visible: true)
            XCTAssertEqual(try fixture.welcomeOpenFrame(), welcomeFrame, "Hover must not move Welcome for \(mode)")
            XCTAssertEqual(try fixture.controlsFrame(), controlsFrame, "The Home header keeps its layout while hidden")

            for changedMode in ReaderToolbarDisplayMode.allCases {
                fixture.state.toolbarDisplayMode = changedMode
                XCTAssertTrue(fixture.state.toolbarHoverVisible, "Reading preferences must preserve Home hover without another pointer event")
                try await fixture.settle()
                try fixture.assertControls(visible: true)
                XCTAssertEqual(try fixture.welcomeOpenFrame(), welcomeFrame)
                XCTAssertEqual(try fixture.controlsFrame(), controlsFrame)
            }
            fixture.state.toolbarDisplayMode = mode
            try await fixture.settle()
            fixture.observer.reducedMotion = false
            fixture.movePointer(depth: 180)
            XCTAssertFalse(fixture.state.toolbarHoverVisible, "Home must hide on exit with the same timing for every reading preference")
            try await fixture.settle()
            try fixture.assertControls(visible: false)
            XCTAssertEqual(try fixture.welcomeOpenFrame(), welcomeFrame)

            fixture.window.simulatesFullscreen = false
            fixture.observer.updateChrome(revealingNativeControls: false)
            try await fixture.settle()
            try fixture.assertControls(visible: true)
            XCTAssertEqual(fixture.state.toolbarDisplayMode, mode, "Home must not rewrite the reader preference")
        }
    }

    func testReturningFromADocumentToFullscreenHomeRestoresPointerDrivenControls() async throws {
        let fixture = Fixture(mode: .shown)
        defer { fixture.close() }
        try await fixture.settle()
        fixture.window.simulatesFullscreen = true
        fixture.observer.updateChrome(revealingNativeControls: false)
        try await fixture.settle()
        fixture.movePointer(depth: 180)
        try await fixture.settle()
        try fixture.assertControls(visible: false)

        fixture.state.document = ReadingDocument(url: URL(fileURLWithPath: "/home-fullscreen-boundary.txt"),
            content: .text("A document opened from fullscreen Home."))
        try await fixture.settle()
        XCTAssertTrue(fixture.state.hasDocument)
        XCTAssertTrue(fixture.controls.isEmpty, "The normal reader must replace Home's content controls")
        fixture.state.document = nil
        fixture.observer.updateChrome(revealingNativeControls: false)
        try await fixture.settle()
        fixture.movePointer(depth: 180)
        try await fixture.settle()
        try fixture.assertControls(visible: false)
        let welcomeFrame = try fixture.welcomeOpenFrame()
        let controlsFrame = try fixture.controlsFrame()
        fixture.movePointer(depth: 20)
        try await fixture.settle()
        try fixture.assertControls(visible: true)
        XCTAssertEqual(try fixture.welcomeOpenFrame(), welcomeFrame)
        XCTAssertEqual(try fixture.controlsFrame(), controlsFrame)
        fixture.movePointer(depth: 180)
        try await fixture.settle()
        try fixture.assertControls(visible: false)
        XCTAssertEqual(try fixture.welcomeOpenFrame(), welcomeFrame)
        XCTAssertEqual(try fixture.controlsFrame(), controlsFrame)
    }

    private final class FullscreenWindow: NSWindow {
        var simulatesFullscreen = false
        override var styleMask: NSWindow.StyleMask {
            get { simulatesFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
            set { super.styleMask = newValue.subtracting(.fullScreen) }
        }
    }

    @MainActor private final class Fixture {
        let state: ReaderState
        let window: FullscreenWindow
        let controller: NSHostingController<ReaderView>
        var host: NSView { controller.view }
        var observer: ReaderToolbarWindow.Host {
            descendants(host).compactMap { $0 as? ReaderToolbarWindow.Host }.first!
        }
        var controls: [ReaderFloatingWindowButtons.Buttons] {
            descendants(host).compactMap { $0 as? ReaderFloatingWindowButtons.Buttons }
        }

        init(mode: ReaderToolbarDisplayMode) {
            _ = NSApplication.shared
            NSApp.finishLaunching()
            state = ReaderState(recordsHistory: false)
            state.immersiveControls = false
            state.toolbarDisplayMode = mode
            state.showContents = false; state.showAI = false; state.showFind = false
            controller = NSHostingController(rootView: ReaderView(state: state))
            window = FullscreenWindow(contentRect: CGRect(x: 2200, y: 100, width: 800, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Home fullscreen fixture \(UUID().uuidString)"
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.contentViewController = controller
            state.window = window
            window.orderBack(nil)
        }

        func settle() async throws {
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(descendants(host).compactMap { $0 as? ReaderToolbarWindow.Host }.count, 1,
                "Exercise ReaderView's mounted chrome owner, not a separate observer")
            observer.reducedMotion = true
        }

        func movePointer(depth: CGFloat) {
            observer.pointerMoved(to: NSPoint(x: 30, y: window.frame.height - depth))
            observer.updateChrome(revealingNativeControls: false)
        }

        func controlsFrame() throws -> CGRect {
            let buttons = try XCTUnwrap(controls.first)
            return buttons.convert(buttons.bounds, to: host)
        }

        func assertControls(visible: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(controls.count, 1, file: file, line: line)
            let group = try XCTUnwrap(controls.first)
            let buttons = group.subviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 3, file: file, line: line)
            for button in buttons {
                let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
                let hit = host.hitTest(button.convert(center, to: host.superview))
                XCTAssertEqual(hit === button || hit?.isDescendant(of: button) == true, visible,
                    "Hidden Home controls must not receive pointer input", file: file, line: line)
            }
            let elements = try accessibleElements()
            let header = elements.first { $0.identifier == "home-header" }
            XCTAssertEqual(header != nil, visible,
                "Home controls must enter and leave the public AX tree with their visibility", file: file, line: line)
            let controlsScreen = window.convertToScreen(group.convert(group.bounds, to: nil))
            let exposedButtons = elements.filter {
                $0.role == kAXButtonRole && controlsScreen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            XCTAssertEqual(exposedButtons.count, visible ? 3 : 0, file: file, line: line)
        }

        func welcomeOpenFrame() throws -> CGRect {
            let element = try XCTUnwrap(accessibleElements().first {
                $0.role == kAXButtonRole && $0.label == L("Open Document…")
            }, "Welcome's Open action must remain available when the header is hidden")
            return element.frame
        }

        private struct AccessibleElement {
            let role: String
            let label: String?
            let identifier: String?
            let frame: CGRect
        }

        private func accessibleElements() throws -> [AccessibleElement] {
            func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                var value: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                return value
            }
            let app = AXUIElementCreateApplication(getpid())
            let windows = try XCTUnwrap(attribute(app, kAXWindowsAttribute) as? [AXUIElement])
            let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
            func visit(_ element: AXUIElement) -> [AccessibleElement] {
                var point = CGPoint.zero, size = CGSize.zero
                if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(value as! AXValue, .cgPoint, &point)
                }
                if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(value as! AXValue, .cgSize, &size)
                }
                let frame = CGRect(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y - size.height,
                    width: size.width, height: size.height)
                let item = AccessibleElement(role: attribute(element, kAXRoleAttribute) as? String ?? "",
                    label: attribute(element, kAXDescriptionAttribute) as? String ?? attribute(element, kAXTitleAttribute) as? String,
                    identifier: attribute(element, kAXIdentifierAttribute) as? String, frame: frame)
                return [item] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(visit)
            }
            return visit(target)
        }

        private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        func close() {
            for observer in descendants(host).compactMap({ $0 as? ReaderToolbarWindow.Host }) { observer.detach() }
            state.windowClosed()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
    }
}
#endif
