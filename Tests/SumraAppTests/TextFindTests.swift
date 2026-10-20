#if os(macOS)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Sumra

final class TextFindTests: XCTestCase {
    @MainActor
    private func makeReader(_ text: String) async throws -> (NSWindow, NSTextView, ReaderState, TextReader.Coordinator) {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.flow = "continuous"; state.spread = false
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/text-find.txt"), content: .text(text))
        let host = NSHostingView(rootView: TextReader(state: state, text: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let deadline = Date().addingTimeInterval(10)
        while state.readerFocusView == nil, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let view = try XCTUnwrap(state.readerFocusView as? NSTextView)
        let coordinator = try XCTUnwrap((view.enclosingScrollView?.superview as? TextReaderHost)?.reader)
        return (window, view, state, coordinator)
    }

    @MainActor
    private func close(_ window: NSWindow, state: ReaderState) {
        window.contentView = nil; window.close(); state.windowClosed()
    }

    @MainActor
    func testFirstMatchNavigatesWhileCountingAndFindNextKeepsItsIdentity() async throws {
        let (window, _, state, coordinator) = try await makeReader("😀 " + String(repeating: "one\n", count: 100_000))
        defer { close(window, state: state) }
        let first = expectation(description: "First match is selected before the complete count")
        var sawFirst = false, earlyCounting = false, earlyResults = 0
        let started = DispatchTime.now().uptimeNanoseconds
        var firstSeconds = 0.0
        let observation = state.$selectedSearchTarget.sink { target in
            guard target == "text:3:3", !sawFirst else { return }
            sawFirst = true
            firstSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            earlyCounting = state.searchCounting
            earlyResults = coordinator.results.count
            first.fulfill()
        }
        defer { observation.cancel() }
        coordinator.find("one")
        await fulfillment(of: [first], timeout: 10)
        XCTAssertTrue(earlyCounting)
        XCTAssertEqual(earlyResults, 1)
        // Find Next must use the selected UTF-16 match, even while the full
        // count is unfinished, rather than wrapping the provisional one-item list.
        coordinator.find("one")
        await coordinator.searchTask?.value
        XCTAssertEqual(state.selectedSearchTarget, "text:7:3")
        XCTAssertEqual(coordinator.hit, 1)
        XCTAssertEqual(coordinator.results.count, 100_000)
        XCTAssertEqual(state.searchResults.count, 100_000)
        XCTAssertFalse(state.searchCounting)
        XCTAssertEqual(state.status, "2 of 100000 matches")
        print("SUMRA_TEXT_FIND first_match_seconds=\(firstSeconds) results=\(coordinator.results.count)")
    }

    @MainActor
    func testSelectionOriginRetainsGlobalNonoverlapRangesAndBackwardWrap() async throws {
        let (window, view, state, coordinator) = try await makeReader("ababa aba")
        defer { close(window, state: state) }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.find("aba", fromSelection: true)
        await coordinator.searchTask?.value
        XCTAssertEqual(coordinator.results, [NSRange(location: 0, length: 3), NSRange(location: 6, length: 3)])
        XCTAssertEqual(state.selectedSearchTarget, "text:6:3")
        coordinator.cancelFind()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.find("aba", backwards: true, fromSelection: true)
        await coordinator.searchTask?.value
        XCTAssertEqual(state.selectedSearchTarget, "text:0:3")
        coordinator.cancelFind()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.find("aba", backwards: true, fromSelection: true)
        await coordinator.searchTask?.value
        XCTAssertEqual(state.selectedSearchTarget, "text:6:3")
    }

    @MainActor
    func testCompletedMissIsReusedAndAnObsoleteQueryCannotPublish() async throws {
        let (window, _, state, coordinator) = try await makeReader(String(repeating: "one\n", count: 20_000) + "other")
        defer { close(window, state: state) }
        coordinator.find("missing")
        await coordinator.searchTask?.value
        coordinator.find("missing")
        XCTAssertNil(coordinator.searchTask)
        XCTAssertEqual(state.status, "No matches")
        coordinator.find("one")
        let cleared = coordinator.searchTask
        XCTAssertTrue(state.searchCounting)
        coordinator.find("")
        XCTAssertFalse(state.searchCounting)
        XCTAssertNil(state.selectedSearchTarget)
        await cleared?.value
        XCTAssertTrue(state.searchResults.isEmpty)
        coordinator.find("one")
        let obsolete = coordinator.searchTask
        coordinator.find("other")
        await coordinator.searchTask?.value
        await obsolete?.value
        XCTAssertEqual(coordinator.results, [NSRange(location: 80_000, length: 5)])
        XCTAssertEqual(state.selectedSearchTarget, "text:80000:5")
        XCTAssertEqual(state.searchResults.map(\.target), ["text:80000:5"])
        XCTAssertFalse(state.searchCounting)
    }
}
#endif
