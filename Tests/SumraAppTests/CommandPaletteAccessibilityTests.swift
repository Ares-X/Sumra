#if os(macOS)
import AppKit
import ApplicationServices
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class CommandPaletteAccessibilityTests: XCTestCase {
    func testUnavailableCommandRowsExposeDisabledNativeAccessibility() async throws {
        _ = NSApplication.shared
        for withDocument in [false, true] {
            let state = ReaderState(recordsHistory: false)
            if withDocument {
                state.document = ReadingDocument(url: URL(fileURLWithPath: "/palette-accessibility.txt"), content: .text("Reader text"))
            }
            // Search includes actions with different availability on Home and text.
            state.paletteMode = "> Save"
            let host = NSHostingView(rootView: CommandPalette(state: state, open: {}, perform: { $0() }))
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 720, height: 460),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Palette accessibility \(withDocument)"
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close(); state.windowClosed() }
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            let application = AXUIElementCreateApplication(getpid())
            let windows = try XCTUnwrap(attribute(application, kAXWindowsAttribute) as? [AXUIElement])
            let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
            for command in [ReaderMenuCommand.save, .saveTabGroup, .saveImage] {
                let row = try XCTUnwrap(find("palette-row:" + command.id, in: target))
                XCTAssertEqual(attribute(row, kAXRoleAttribute) as? String, kAXButtonRole)
                XCTAssertEqual((attribute(row, kAXEnabledAttribute) as? NSNumber)?.boolValue, command.enabled(state),
                               "\(command.id) must advertise actual availability, document=\(withDocument)")
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }

    private func find(_ identifier: String, in element: AXUIElement) -> AXUIElement? {
        if attribute(element, kAXIdentifierAttribute) as? String == identifier { return element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }
}
#endif
