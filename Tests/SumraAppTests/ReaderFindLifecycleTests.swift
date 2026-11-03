#if os(macOS)
import AppKit
import Combine
import CoreText
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderFindLifecycleTests: XCTestCase {
    private static var accessibilityLaunched = false
    func testNativePDFReopenSearchRestoresResultsAndRangeWithoutRefocusAdvancing() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("find-reopen.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &box, nil))
        for _ in 0..<9 {
            writer.beginPDFPage(nil); writer.textPosition = CGPoint(x: 20, y: 350)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: Array(repeating: "needle", count: 8).joined(separator: " "),
                attributes: [.font: NSFont.systemFont(ofSize: 9)]))
            CTLineDraw(line, writer); writer.endPDFPage()
        }
        writer.closePDF()
        let pages = try Pages(input, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.flow = "paged"; state.fit = "page"; state.spread = false; state.automaticLayout = false
        state.showContents = false; state.showAI = false
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 865, height: 512),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        state.window = window; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail("PDF Find did not settle: \(state.error ?? state.searchCountText)", line: line)
            throw CancellationError()
        }
        try await waitFor { state.count == 9 && state.readerFocusView != nil }
        state.showFindPanel(); state.updateFindQuery("needle"); state.findNext()
        try await waitFor { state.searchResults.count == 72 && !state.searchCounting && state.selectedSearchTarget != nil }
        state.setSearchPageRange("2-3")
        try await waitFor { state.searchResults.count == 16 && !state.searchCounting && state.selectedSearchTarget != nil }
        state.closeFind()
        try await waitFor { !state.showFind && state.searchResults.isEmpty && !state.searchCounting }
        XCTAssertEqual(state.findQuery, "needle")
        XCTAssertEqual(state.searchPageRange, "2-3")
        state.showFindPanel()
        try await waitFor { state.searchResults.count == 16 && !state.searchCounting && state.selectedSearchTarget != nil }
        XCTAssertEqual(state.searchResults.filter { $0.target.hasPrefix("raster-search:1:") }.count, 8)
        XCTAssertEqual(state.searchResults.filter { $0.target.hasPrefix("raster-search:2:") }.count, 8)
        let selected = state.selectedSearchTarget
        var findCommands = 0
        let observation = state.$command.dropFirst().sink { command in
            if case .find = command.action { findCommands += 1 }
        }
        defer { observation.cancel() }
        state.showFindPanel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(findCommands, 0, "Refocusing an open Find panel must not start or advance a search")
        XCTAssertEqual(state.selectedSearchTarget, selected)
        XCTAssertEqual(state.searchResults.count, 16)
        XCTAssertFalse(window.isVisible)
    }

    func testToolbarFindTogglesButFindCommandReselectsExistingInput() {
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/find-toggle.txt"), content: .text("needle"))
        state.toggleFindPanel()
        XCTAssertTrue(state.showFind)
        XCTAssertTrue(state.showSearchResults)
        let focus = state.findFocusRevision
        ReaderMenuCommand.find.run(state)
        XCTAssertTrue(state.showFind, "Cmd-F keeps Find open")
        XCTAssertGreaterThan(state.findFocusRevision, focus)
        state.findQuery = "needle"
        state.setSearchPageRange("2-4")
        state.toggleFindPanel()
        XCTAssertFalse(state.showFind)
        XCTAssertFalse(state.showSearchResults)
        XCTAssertFalse(state.searchSessionActive)
        XCTAssertEqual(state.findQuery, "needle", "Closing Find retains the query for Cmd-G")
        XCTAssertEqual(state.searchPageRange, "2-4")
        state.toggleFindPanel()
        XCTAssertTrue(state.showFind)
        XCTAssertTrue(state.showSearchResults)
        XCTAssertEqual(state.findQuery, "needle")
    }

    func testEscapeClosesFindFromReaderAndClosedFindNavigationButLeavesTypingNative() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/find-escape.txt"), content: .text("needle"))
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 500, height: 300),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state.window = window
        let guardOwner = ReaderCloseGuard(state: state, previous: nil)
        window.delegate = guardOwner
        let reader = NSTextView(frame: window.contentLayoutRect)
        reader.isEditable = false
        window.contentView = reader
        state.readerFocusView = reader
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let application = ReaderApplicationDelegate()
        defer {
            state.windowClosed(); window.contentView = nil; window.close()
            withExtendedLifetime(guardOwner) {}
        }
        XCTAssertTrue(ReaderWindows.states.contains { $0 === state })
        window.makeFirstResponder(reader)
        state.showFindPanel()
        state.findQuery = "needle"
        XCTAssertNil(application.handleReaderEvent(event))
        XCTAssertFalse(state.showFind)
        XCTAssertFalse(state.showSearchResults)
        XCTAssertFalse(state.searchSessionActive)
        XCTAssertTrue(window.firstResponder === reader)
        state.didHandleCommand(state.command.revision)
        ReaderMenuCommand.findNext.run(state)
        XCTAssertFalse(state.showFind, "Cmd-G must work with the Find controls closed")
        XCTAssertTrue(state.searchSessionActive)
        state.didHandleCommand(state.command.revision)
        XCTAssertNil(application.handleReaderEvent(event), "A closed-Find Cmd-G session can also be canceled")
        XCTAssertFalse(state.searchSessionActive)
        XCTAssertEqual(state.findQuery, "needle")
        XCTAssertNotNil(application.handleReaderEvent(event), "A reader with no Find session keeps native Escape")

        state.showFindPanel()
        reader.isEditable = true
        XCTAssertNotNil(application.handleReaderEvent(event), "Native text input owns Escape and IME cancellation")
        XCTAssertTrue(state.showFind)
        XCTAssertFalse(window.isVisible, "This event-routing regression must not show a window")
    }

    func testMountedCloseButtonRemovesPageRangeAndEndsEditing() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture()
        state.count = 1; state.toolbarDisplayMode = .shown; state.immersiveControls = false
        state.showContents = false; state.showAI = false
        let defaults = UserDefaults.standard, savedFloating = defaults.object(forKey: "findFloating")
        defaults.set(false, forKey: "findFloating")
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 800, height: 600),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Find range close regression"
        window.alphaValue = 0; window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ReaderView(state: state))
        state.window = window; window.contentView = host
        window.orderBack(nil)
        let guardOwner = ReaderCloseGuard(state: state, previous: nil)
        window.delegate = guardOwner
        defer {
            state.windowClosed(); window.orderOut(nil); window.contentView = nil; window.close()
            defaults.set(savedFloating, forKey: "findFloating")
            withExtendedLifetime(guardOwner) {}
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            XCTFail("\(label): shown=\(state.showFind), input=\(state.findInputField != nil), firstResponder=\(String(describing: window.firstResponder))")
            throw CancellationError()
        }
        state.showFindPanel()
        try await settle("Mount Find and reader") { state.findInputField != nil && state.readerFocusView != nil }
        let range = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == L("All pages")
        })
        range.selectText(nil)
        let editor = try XCTUnwrap(range.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(ReaderWindows.isTyping(in: window, state: state))
        if !Self.accessibilityLaunched {
            NSApp.finishLaunching()
            Self.accessibilityLaunched = true
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        let application = AXUIElementCreateApplication(getpid())
        let windows = try XCTUnwrap(attribute(application, kAXWindowsAttribute) as? [AXUIElement])
        let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
        func closeButton(in element: AXUIElement) -> AXUIElement? {
            if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
               attribute(element, kAXDescriptionAttribute) as? String == L("Close Find") { return element }
            return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).lazy.compactMap { closeButton(in: $0) }.first
        }
        let close = try XCTUnwrap(closeButton(in: target), "The mounted Find controls must expose their Close Find button")
        XCTAssertEqual(AXUIElementPerformAction(close, kAXPressAction as CFString), .success)
        try await settle("Close Find button") { !state.showFind && state.findInputField == nil }
        XCTAssertFalse(state.showSearchResults)
        XCTAssertFalse(state.searchSessionActive)
        XCTAssertFalse(descendants(host).contains { ($0 as? NSTextField)?.placeholderString == L("All pages") },
            "Closing from the page range removes its complete row")
        print("Mounted Find close: firstResponder=\(String(describing: window.firstResponder)), reader=\(String(describing: state.readerFocusView)), readerMounted=\(state.readerFocusView?.window === window), key=\(window.isKeyWindow)")
        XCTAssertNil(range.currentEditor(), "The removed range field must release its native editor")
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertFalse(ReaderWindows.isTyping(in: window, state: state))
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertFalse(window.isKeyWindow)
    }
}
#endif
