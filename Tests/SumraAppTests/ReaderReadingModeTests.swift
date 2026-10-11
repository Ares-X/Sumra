#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderReadingModeTests: XCTestCase {
    func testConsecutivePageKeysKeepReaderFocusWithoutTakingFocusFromControls() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(pageCount: 8)
        guard case .pages(let pages) = state.document?.content else { return XCTFail("Missing pages") }
        state.count = 8; state.page = 0; state.flow = "paged"; state.spread = false
        state.fit = "page"; state.rtl = false; state.automaticLayout = false
        state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false
        state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; state.windowClosed(); window.close() }
        func waitFor(line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail("Reader did not settle at page \(state.page): \(state.error ?? "no error"), reader focus \(window.firstResponder === state.readerFocusView)", line: line)
            throw CancellationError()
        }
        try await waitFor { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(0)) }
        XCTAssertTrue(window.makeFirstResponder(state.readerFocusView))
        func key(_ code: UInt16, _ character: String, to page: Int) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
            try XCTUnwrap(window.firstResponder).keyDown(with: event)
            try await waitFor { state.page == page && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(page)) && window.firstResponder === state.readerFocusView }
        }
        try await key(124, "\u{f703}", to: 1)
        try await key(124, "\u{f703}", to: 2)
        try await key(123, "\u{f702}", to: 1)
        try await key(123, "\u{f702}", to: 0)
        state.spread = true; state.cover = false
        try await waitFor { window.firstResponder === state.readerFocusView && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(0)) }
        try await key(124, "\u{f703}", to: 2)
        try await key(124, "\u{f703}", to: 4)
        try await key(123, "\u{f702}", to: 2)
        try await key(124, "\u{f703}", to: 4)
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        try XCTUnwrap(host.superview).addSubview(field)
        state.turn(-1)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = window.firstResponder
        try await waitFor { state.page == 2 && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(2)) }
        XCTAssertTrue(window.firstResponder === editor, "Page replacement must preserve text entry focus")
        state.spread = false
        try await waitFor { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(2)) }
        XCTAssertTrue(window.firstResponder === editor)
    }
    func testPlainTextOffersSingleContinuousAndFacingReadingModes() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/reading-modes.txt"), content: .text("Reading modes share the same source text."))
        let defaults = UserDefaults.standard, oldFlow = defaults.object(forKey: "flow")
        defer { defaults.set(oldFlow, forKey: "flow") }
        for command in [ReaderMenuCommand.paged, .continuous, .twoPages, .rightToLeft] {
            XCTAssertTrue(command.enabled(state))
        }
        XCTAssertFalse(ReaderMenuCommand.coverOnItsOwn.enabled(state))
        state.flow = "continuous"; state.spread = false
        ReaderMenuCommand.twoPages.run(state)
        XCTAssertTrue(state.spread); XCTAssertEqual(state.flow, "paged")
        ReaderMenuCommand.paged.run(state)
        XCTAssertFalse(state.spread); XCTAssertEqual(state.flow, "paged")
        ReaderMenuCommand.twoPages.run(state)
        ReaderMenuCommand.continuous.run(state)
        XCTAssertFalse(state.spread); XCTAssertEqual(state.flow, "continuous")
        XCTAssertFalse(state.effectiveUserCSS.isEmpty)
        XCTAssertTrue(state.effectiveUserCSS.contains(state.palette.css))
    }
}
#endif
