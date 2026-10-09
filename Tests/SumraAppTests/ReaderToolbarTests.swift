#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import Sumra

@MainActor
final class ReaderToolbarTests: XCTestCase {
    func testFocusedPageInputTracksNavigationAndPreservesDraftAndComposition() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/page-input.txt"), content: .text("one\ntwo\nthree\nfour"))
        state.count = 4; state.page = 0
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window
        let host = NSHostingView(rootView: ReaderPageInput(state: state, finished: { window.makeFirstResponder(nil) })
            .frame(width: 80, height: 24))
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close(); state.windowClosed() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if state.pageInputField?.window === window { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let field = try XCTUnwrap(state.pageInputField)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertFalse(window.isVisible, "The regression fixture must not disturb the user's windows")
        XCTAssertEqual(editor.string, "1")
        state.page = 1
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if editor.string == "2" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(editor.string, "2", "An untouched focused input must track external navigation")
        XCTAssertEqual(field.stringValue, "2")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertTrue(window.firstResponder === editor)

        editor.insertText("2", replacementRange: editor.selectedRange())
        state.page = 2
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if field.toolTip == state.positionLabel { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(editor.string, "2", "Even a draft equal to the old page label belongs to the user")
        window.makeFirstResponder(nil)
        XCTAssertEqual(field.stringValue, "3", "Blur discards the draft and shows the actual page")

        field.selectText(nil)
        let compositionEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        compositionEditor.setMarkedText("3", selectedRange: NSRange(location: 1, length: 0), replacementRange: compositionEditor.selectedRange())
        XCTAssertTrue(compositionEditor.hasMarkedText())
        state.page = 3
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if field.toolTip == state.positionLabel { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(compositionEditor.string, "3")
        XCTAssertTrue(compositionEditor.hasMarkedText(), "Navigation must leave input method composition intact")
    }

    func testPageInputFocusSelectsTextAndReturnCommitsWhileEscapeAndBlurDiscard() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/page-input.txt"), content: .text("one\ntwo\nthree\nfour"))
        state.count = 4; state.page = 2
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window
        let host = NSHostingView(rootView: ReaderPageInput(state: state, finished: { window.makeFirstResponder(nil) })
            .frame(width: 80, height: 24))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close(); state.windowClosed() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if state.pageInputField?.window === window { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let field = try XCTUnwrap(state.pageInputField)
        ReaderMenuCommand.goToPage.run(state)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "3")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertEqual(state.page, 2, "Focusing the input must not navigate")
        editor.insertText("4", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(state.page, 3)
        XCTAssertEqual(field.stringValue, "4")
        XCTAssertNil(field.currentEditor())

        ReaderMenuCommand.goToPage.run(state)
        let nextEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        nextEditor.insertText("2", replacementRange: nextEditor.selectedRange())
        ReaderMenuCommand.goToPage.run(state)
        XCTAssertEqual(nextEditor.string, "2", "Repeated focus preserves the draft and selects it")
        XCTAssertEqual(nextEditor.selectedRange(), NSRange(location: 0, length: 1))
        nextEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(state.page, 3)
        XCTAssertEqual(field.stringValue, "4")
        XCTAssertNil(field.currentEditor())

        ReaderMenuCommand.goToPage.run(state)
        let lastEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        lastEditor.insertText("1", replacementRange: lastEditor.selectedRange())
        window.makeFirstResponder(nil)
        XCTAssertEqual(state.page, 3, "Leaving an unfinished draft must not navigate")
        XCTAssertEqual(field.stringValue, "4")

        state.page = 0
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if field.stringValue == "1" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(field.stringValue, "1", "Navigation outside the field must refresh its displayed page")
    }

    func testToolbarTargetsExistingCommandsAndKeepsUserOrder() throws {
        let entries = try ReaderToolbarButton.read("""
        [{"command":"next","symbol":"chevron.right"},{"external":"Preview","text":"Open Preview"},{"custom":"Next 3 pages","text":"Next three"},{"command":"next","text":"Next"}]
        """)
        XCTAssertEqual(entries.map(\.command), ["next", nil, nil, "next"])
        XCTAssertEqual(entries[1].external, "Preview")
        XCTAssertEqual(entries[2].custom, "Next 3 pages")
        for invalid in ["[{}]", "[{\"command\":\"missing\"}]", "[{\"external\":\"  \"}]",
                        "[{\"command\":\"next\",\"external\":\"Preview\"}]", "[{\"command\":\"next\",\"custom\":\"Next 3 pages\"}]",
                        "[{\"external\":\"Preview\",\"custom\":\"Next 3 pages\"}]", "[{\"custom\":\"  \"}]",
                        "[{\"command\":\"next\",\"symbol\":\"invalid-sumra-symbol\"}]"] {
            XCTAssertThrowsError(try ReaderToolbarButton.read(invalid))
        }
    }

    func testSVGIconsUseMuPDFWithAlphaAndExplicitColor() throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("MuPDF engine is not built") }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><circle cx=\"10\" cy=\"10\" r=\"6\" fill=\"#d00000\"/></svg>"
        let image = try ReaderToolbarSVGRenderer.render(svg, size: 40)
        XCTAssertEqual(image.width, 40); XCTAssertEqual(image.height, 40)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertEqual(bytes[3], 0)
        let center = 20 * image.bytesPerRow + 20 * 4
        XCTAssertGreaterThan(bytes[center], 190)
        XCTAssertLessThan(bytes[center + 1], 10)
        XCTAssertEqual(bytes[center + 3], 255)
        XCTAssertThrowsError(try ReaderToolbarSVGRenderer.render("<svg><broken", size: 40))
        XCTAssertEqual(try ReaderToolbarSVGRenderer.render(svg, size: 20).width, 20)
    }
}
#endif
