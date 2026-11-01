#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderNumericFlowTests: XCTestCase {
    func testControlMarginFieldsRemainAccessibleAndCommitIndependently() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/accessible-control-margins.txt"), content: .text("Text"))
        state.typographyForAll = false
        state.pageMargins = PageMargins(cssValues: [9, 17, 25, 33])
        state.marginPresetSelection = "custom"
        state.controlTopMargin = 54; state.controlBottomMargin = 44
        let host = NSHostingView(rootView: ReaderReadingSettings(state: state))
        let window = makeWindow(host: host, size: NSSize(width: 430, height: 900))
        window.title = "Accessible control margins"
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        let top = try await numericField("Top clearance", unit: "pt", in: host)
        let bottom = try await numericField("Bottom clearance", unit: "pt", in: host)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        let application = AXUIElementCreateApplication(getpid())
        let windows = try XCTUnwrap(attribute(application, kAXWindowsAttribute) as? [AXUIElement])
        let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
        func fields(_ element: AXUIElement) -> [String] {
            let own = attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole
                ? [attribute(element, kAXDescriptionAttribute) as? String ?? ""] : []
            return own + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(fields)
        }
        let labels = fields(target)
        XCTAssertTrue(labels.contains("\(L("Top clearance")) (pt)"), "Assistive tools must identify the top editor")
        XCTAssertTrue(labels.contains("\(L("Bottom clearance")) (pt)"), "Assistive tools must identify the bottom editor")
        try replaceDraft(in: top, with: "76", window: window)
        try XCTUnwrap(top.currentEditor() as? NSTextView).insertNewline(nil)
        XCTAssertEqual(state.controlTopMargin, 76)
        XCTAssertEqual(state.controlBottomMargin, 44)
        try replaceDraft(in: bottom, with: "0", window: window)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(state.controlTopMargin, 76)
        XCTAssertEqual(state.controlBottomMargin, 0)
        XCTAssertEqual(state.contentMargins?.values, [9, 17, 25, 33])
    }

    func testDefaultMarginsRetainAllFourNativeFocusCommits() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["margin", "pageMargins", "marginPresetSelection", "readingPreferenceRevisions"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.set(try JSONEncoder().encode(PageMargins(cssValues: [16, 32, 16, 32])!), forKey: "pageMargins")
        defaults.set("custom", forKey: "marginPresetSelection")
        defaults.set(32, forKey: "margin")

        let host = NSHostingView(rootView: SettingsView())
        let window = makeWindow(host: host, size: NSSize(width: 500, height: 540))
        defer { window.contentView = nil; window.close() }
        let names = ["Top margin", "Right margin", "Bottom margin", "Left margin"]
        var fields: [NSTextField] = []
        for name in names { fields.append(try await numericField(name, unit: "pt", in: host)) }

        // Move between the actual native editors without forcing a SwiftUI
        // reconstruction between commits. Each edit must merge with the most
        // recently accepted four-side value.
        let edited = [11.0, 22.0, 33.0, 44.0]
        var expected = [16.0, 32.0, 16.0, 32.0]
        for (index, field) in fields.enumerated() {
            try replaceDraft(in: field, with: String(edited[index]), window: window)
            XCTAssertTrue(window.makeFirstResponder(nil))
            expected[index] = edited[index]
            let margins = try JSONDecoder().decode(PageMargins.self, from: XCTUnwrap(defaults.data(forKey: "pageMargins")))
            XCTAssertEqual(margins.values, expected, "Editing \(names[index]) must retain previously accepted sides")
        }
    }

    func testDefaultTypographyAcceptsConsecutiveNativeReturnCommits() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["fontSize", "readingPreferenceRevisions"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.set(17, forKey: "fontSize")
        let host = NSHostingView(rootView: SettingsView())
        let window = makeWindow(host: host, size: NSSize(width: 500, height: 540))
        defer { window.contentView = nil; window.close() }
        let field = try await numericField("Font size", unit: "pt", in: host)
        for value in [23.5, 18.25, 36] {
            try replaceDraft(in: field, with: String(value), window: window)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertNewline(nil)
            XCTAssertEqual(defaults.double(forKey: "fontSize"), value)
            XCTAssertEqual(field.stringValue, ReaderNumericField.Coordinator.string(value))
        }
    }

    func testReplacingDocumentDoesNotCommitOutgoingNumericDraftIntoNewDocument() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let savedFontSize = defaults.object(forKey: "fontSize")
        defaults.set(19, forKey: "fontSize")
        defer { defaults.set(savedFontSize, forKey: "fontSize") }
        let directory = try TemporaryDirectory()
        let next = directory.url.appendingPathComponent("next.txt")
        try "Next document".write(to: next, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: directory.url.appendingPathComponent("first.txt"), content: .text("First document"))
        state.fontSize = 17
        state.typographyForAll = false
        let host = NSHostingView(rootView: ReaderReadingSettings(state: state))
        let window = makeWindow(host: host, size: NSSize(width: 430, height: 900))
        defer {
            window.contentView = nil; window.close(); state.windowClosed()
            withExtendedLifetime(directory) {}
        }
        let field = try await numericField("Font size", unit: "pt", in: host)
        try replaceDraft(in: field, with: "24", window: window)
        XCTAssertEqual(state.fontSize, 17, "An in-progress draft belongs to the outgoing document")

        // Replacement can finish while the live settings editor has focus.
        // Exercise the real asynchronous load owner rather than assigning the
        // incoming document or its typography directly.
        state.openWithoutHistory(next)
        let deadline = Date().addingTimeInterval(3)
        while state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(state.error)
        XCTAssertFalse(state.busy)
        XCTAssertEqual(state.document?.url, next)
        XCTAssertEqual(state.fontSize, 19)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(state.fontSize, 19, "Losing focus after replacement must not submit the outgoing document's draft")
        let incomingField = try await numericField("Font size", unit: "pt", in: host)
        XCTAssertEqual(incomingField.stringValue, "19")
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 2200, y: 100), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func numericField(_ name: String, unit: String, in host: NSView) async throws -> NSTextField {
        let label = "\(L(name)) (\(unit))"
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let field = descendants(host).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == label }) {
                field.scrollToVisible(field.bounds)
                return field
            }
            for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
                scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView?.bounds.height ?? 0))
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        return try XCTUnwrap(nil as NSTextField?, "Numeric field was not mounted: \(label)")
    }

    private func replaceDraft(in field: NSTextField, with text: String, window: NSWindow) throws {
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
