#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class FileBrowserNavigationTests: XCTestCase {
    func testEnteringFilteredFolderClearsActiveSearchAndSelectsItsChild() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), folder = directory.url.appendingPathComponent("Novels")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let book = folder.appendingPathComponent("Book.txt")
        try "The selected child book".write(to: book, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableHistory")
        defaults.set(true, forKey: "disableHistory")
        let state = ReaderState(recordsHistory: false)
        let host = NSHostingView(rootView: DocumentFileBrowser(state: state, folder: directory.url))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        defer {
            state.windowClosed(); window.contentView = nil; window.close()
            defaults.set(previous, forKey: "disableHistory")
            withExtendedLifetime(directory) {}
        }
        func search(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == L("Search files") { return field }
            return view.subviews.lazy.compactMap { search(in: $0) }.first
        }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
        }
        try await settle()
        let field = try XCTUnwrap(search(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        editor.insertText("Novels", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await settle()
        XCTAssertEqual(field.stringValue, "Novels")
        XCTAssertTrue(field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        try await settle()
        XCTAssertEqual(field.stringValue, "", "The active editor must follow the new directory's empty query")
        XCTAssertEqual(editor.string, "")
        XCTAssertNil(state.document, "Entering a folder must keep the file browser open")
        XCTAssertTrue(field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        let deadline = Date().addingTimeInterval(3)
        while state.document == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(state.document?.url, book, "Return must select the visible child rather than retaining the parent-folder filter")
        XCTAssertNil(state.error)
    }
}
#endif
