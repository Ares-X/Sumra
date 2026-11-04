#if os(macOS)
import AppKit
import ApplicationServices
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor final class ReaderSidebarFooterLayoutTests: XCTestCase {
    func testAIButtonsClearTheProgressInteractionStripInOrdinaryAutoHide() async throws {
        try await checkButtons(floating: false, preset: .narrow)
    }

    func testAIButtonsClearTheProgressInteractionStripInFloatingNarrow() async throws {
        try await checkButtons(floating: true, preset: .narrow)
    }

    func testAIButtonsClearTheProgressInteractionStripInFloatingMedium() async throws {
        try await checkButtons(floating: true, preset: .medium)
    }

    private func checkButtons(floating: Bool, preset: ReaderMarginPreset) async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let defaults = UserDefaults.standard
        let keys = ["language", "progressDisplayMode", "toolbarDisplayMode", "immersiveControls", "pageMargins", "marginPresetSelection"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set("en", forKey: "language")
        defaults.set("auto", forKey: "progressDisplayMode")
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/sidebar-footer-layout.txt"), content: .text("A paragraph for the reader."))
        state.count = 2; state.showAI = true; state.showContents = false
        state.showFind = false; state.showAnnotations = false; state.showBookmarks = false; state.showThumbnails = false
        state.toolbarDisplayMode = .auto; state.immersiveControls = floating
        state.controlTopMargin = 0; state.controlBottomMargin = 0
        state.pageMargins = preset.margins(reflow: true); state.marginPresetSelection = preset.rawValue
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 760, height: 680),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.title = "AI footer separation \(floating) \(preset.rawValue)"
        window.contentView = host; state.window = window; window.orderBack(nil)
        defer { state.windowClosed(); window.orderOut(nil); window.contentView = nil; window.close() }
        // Measure the actual footer view, including its hover target outside the
        // visible floating surface, rather than restating its layout constants.
        let footer = NSHostingView(rootView: ReaderProgressFooter(state: state, floating: floating))
        footer.frame.size = CGSize(width: 760, height: footer.fittingSize.height)
        let footprint = footer.fittingSize.height
        XCTAssertGreaterThan(footprint, 0)
        func settle() async throws {
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        // AppKit can publish the split group before SwiftUI publishes its button children.
        func mountedButtons() async throws -> [(String, CGRect)] {
            let names = Set([L("Translate Selection"), L("Send")])
            let deadline = Date().addingTimeInterval(5)
            var elements = try buttons(in: window)
            while !names.isSubset(of: elements.map(\.0)) && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
                elements = try buttons(in: window)
            }
            return elements
        }
        for width in [760.0, 1040.0, 760.0] {
            window.setContentSize(CGSize(width: width, height: 680))
            try await settle()
            let elements = try await mountedButtons()
            let hostFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
            let strip = CGRect(x: hostFrame.minX, y: hostFrame.minY, width: hostFrame.width, height: footprint)
            for label in [L("Translate Selection"), L("Send")] {
                let button = try XCTUnwrap(elements.first { $0.0 == label }, "AI button \(label) must be mounted")
                XCTAssertFalse(button.1.intersects(strip), "\(label) overlaps the live footer interaction strip at width \(width): button=\(button.1), strip=\(strip)")
                XCTAssertTrue(hostFrame.contains(button.1), "AI button must remain inside the reader")
            }
        }
        let initialButtons = try await mountedButtons()
        let initial = try XCTUnwrap(initialButtons.first { $0.0 == L("Send") }).1
        let initialReader = try XCTUnwrap(state.readerScrollView)
        let initialReadingBottom = window.convertToScreen(initialReader.convert(initialReader.bounds, to: nil)).minY
        state.status = "Reader status"
        try await settle()
        let withStatusButtons = try await mountedButtons()
        let withStatus = try XCTUnwrap(withStatusButtons.first { $0.0 == L("Send") }).1
        if floating {
            XCTAssertEqual(withStatus.minY, initial.minY, accuracy: 1,
                "The existing status row must count toward floating footer clearance instead of adding another gap")
        } else {
            let reader = try XCTUnwrap(state.readerScrollView)
            let statusFootprint = window.convertToScreen(reader.convert(reader.bounds, to: nil)).minY - initialReadingBottom
            XCTAssertGreaterThan(statusFootprint, 0, "The normal footer and status each reserve their own row")
            XCTAssertEqual(withStatus.minY - initial.minY, statusFootprint, accuracy: 1,
                "The normal sidebar must clear the same footer and status rows as the reader")
        }
        state.status = ""
        defaults.set("hidden", forKey: "progressDisplayMode")
        try await settle()
        let withoutFooterButtons = try await mountedButtons()
        let withoutFooter = try XCTUnwrap(withoutFooterButtons.first { $0.0 == L("Send") }).1
        XCTAssertEqual(initial.minY - withoutFooter.minY, footprint, accuracy: 1,
            "A hidden footer must release its whole footprint, including root floating padding")
    }

    private func buttons(in window: NSWindow) throws -> [(String, CGRect)] {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        let application = AXUIElementCreateApplication(getpid())
        let windows = try XCTUnwrap(attribute(application, kAXWindowsAttribute) as? [AXUIElement])
        let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
        func descendants(_ element: AXUIElement) -> [(String, CGRect)] {
            var result: [(String, CGRect)] = []
            if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole {
                let label = attribute(element, kAXDescriptionAttribute) as? String ?? attribute(element, kAXTitleAttribute) as? String ?? ""
                var position = CGPoint.zero, size = CGSize.zero
                if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
                if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
                result.append((label, CGRect(x: position.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - position.y - size.height, width: size.width, height: size.height)))
            }
            return result + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
        }
        return descendants(target)
    }
}
#endif
