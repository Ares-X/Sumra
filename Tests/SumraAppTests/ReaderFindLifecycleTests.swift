#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderFindLifecycleTests: XCTestCase {
    private static var accessibilityLaunched = false
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
