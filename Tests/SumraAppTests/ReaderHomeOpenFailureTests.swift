#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderHomeOpenFailureTests: XCTestCase {
    func testFailedImageFolderOpenKeepsBrowsedFolderAndSearchUsable() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["documentOpenHistory", "pinnedDocuments", "closedDocuments", "disableHistory"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        defer {
            ReaderFiles.setRecent(recent)
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        ReaderFiles.clearHistory()
        defaults.removeObject(forKey: "pinnedDocuments")
        defaults.set(false, forKey: "disableHistory")
        let directory = try TemporaryDirectory()
        let note = directory.url.appendingPathComponent("Note.txt")
        try "A folder without image pages".write(to: note, atomically: true, encoding: .utf8)
        ReaderFiles.recordBrowse(directory.url, recordsHistory: true)
        let browseHistory = defaults.data(forKey: "documentOpenHistory")
        let state = ReaderState(recordsHistory: false)
        var requestedWindows = [WindowPayload]()
        state.createWindow = { requestedWindows.append($0) }
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 760, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        state.window = window
        defer {
            state.windowClosed()
            window.contentView = nil
            window.close()
            withExtendedLifetime(directory) {}
        }
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == L("Search files") { return field }
            return view.subviews.lazy.compactMap { search($0) }.first
        }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
        }
        try await settle()
        let field = try XCTUnwrap(search(host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        // The sole recent entry is a browsed folder. Return enters its browser.
        XCTAssertTrue(field.delegate?.control?(field, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        try await settle()
        XCTAssertNil(state.document)
        field.selectText(nil)
        let folderEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        folderEditor.insertText("Note", replacementRange: NSRange(location: 0, length: (folderEditor.string as NSString).length))
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await settle()
        XCTAssertEqual(field.stringValue, "Note")

        // Hold loading across a render update; a fast filesystem error must not
        // make this test miss the Home-to-progress reconciliation.
        state.busy = true
        try await settle()
        XCTAssertTrue(search(host) === field, "Loading must retain the Home browser")
        XCTAssertFalse(field.isEnabled)
        XCTAssertNil(field.currentEditor(), "The invisible browser must release its native field editor")
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:))] {
            XCTAssertTrue(field.delegate?.control?(field, textView: folderEditor, doCommandBy: selector) == true)
        }
        XCTAssertTrue(requestedWindows.isEmpty, "Repeated Return during loading must not open another window")
        XCTAssertEqual(state.generation, 0)
        // Repeat the loading boundary with the file-grid responder selected.
        state.busy = false
        try await settle()
        let activeEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(field.delegate?.control?(field, textView: activeEditor,
            doCommandBy: #selector(NSResponder.moveDown(_:))) == true)
        try await settle()
        let grid = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertFalse(grid is NSTextView)
        XCTAssertFalse(grid is NSTextField)
        state.busy = true
        try await settle()
        XCTAssertFalse(grid.acceptsFirstResponder)
        XCTAssertFalse(window.firstResponder === grid)
        grid.moveUp(nil)
        grid.insertNewline(nil)
        XCTAssertTrue(requestedWindows.isEmpty)
        XCTAssertEqual(state.generation, 0)
        state.busy = false
        try await settle()
        XCTAssertTrue(window.firstResponder === grid, "Disabled arrows must not change the retained grid focus")
        state.openWithoutHistory(directory.url)
        let deadline = Date().addingTimeInterval(3)
        while state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
        XCTAssertNotNil(state.error)
        XCTAssertNil(state.document)
        state.error = nil // Dismiss the error through the alert's existing binding.
        try await settle()
        XCTAssertTrue(search(host) === field)
        XCTAssertTrue(field.isEnabled)
        XCTAssertEqual(field.stringValue, "Note")
        XCTAssertEqual(defaults.data(forKey: "documentOpenHistory"), browseHistory)
        XCTAssertTrue(ReaderFiles.opensInFolderBrowser(directory.url))

        // Return still targets the filtered child in the same browsed folder.
        XCTAssertTrue(window.makeFirstResponder(field))
        let restoredEditor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        XCTAssertTrue(field.delegate?.control?(field, textView: restoredEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        let openedDeadline = Date().addingTimeInterval(3)
        while state.document == nil, Date() < openedDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(state.document?.url, note)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.recordsDocumentHistory)
        XCTAssertEqual(defaults.data(forKey: "documentOpenHistory"), browseHistory)
    }
}
#endif
