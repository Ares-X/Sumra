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
        NSApp.finishLaunching()
        let defaults = UserDefaults.standard, savedLanguage = defaults.object(forKey: "language")
        defaults.set("en", forKey: "language")
        defer { defaults.set(savedLanguage, forKey: "language") }
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
            let commands = [ReaderMenuCommand.save, .saveTabGroup, .saveImage]
            let rows = try await waitForRows(commands, window: window, host: host)
            for (command, row) in zip(commands, rows) {
                XCTAssertEqual(attribute(row, kAXRoleAttribute) as? String, kAXButtonRole)
                XCTAssertEqual((attribute(row, kAXEnabledAttribute) as? NSNumber)?.boolValue, command.enabled(state),
                               "\(command.id) must advertise actual availability, document=\(withDocument)")
            }
        }
    }

    private func waitForRows<Content: View>(_ commands: [ReaderMenuCommand], window: NSWindow,
                                          host: NSHostingView<Content>) async throws -> [AXUIElement] {
        // Inspect only this process; no global accessibility-trust request or user input.
        let application = AXUIElementCreateApplication(getpid())
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let target = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == window.title }) {
                let rows = commands.compactMap { find("palette-row:" + $0.id, in: target) }
                if rows.count == commands.count { return rows }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The owned palette must publish its command rows")
        throw NSError(domain: "CommandPaletteAccessibilityTests", code: 1)
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
