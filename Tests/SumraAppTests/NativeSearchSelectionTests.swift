#if os(macOS)
import AppKit
import Combine
import CryptoKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeSearchSelectionTests: XCTestCase {
    func testOriginalChineseEPUBSelectedHitRemainsInCompletedResults() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_SEARCH_SELECTION_BOOK"] else {
            throw XCTSkip("Set SUMRA_SEARCH_SELECTION_BOOK to the original Li Hongzhang EPUB")
        }
        let input = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: input)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        defer {
            XCTAssertEqual(try? Data(contentsOf: input), original, "Searching must preserve original bytes")
            XCTAssertEqual(try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date,
                           attributes[.modificationDate] as? Date)
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.flow = "paged"; state.fit = "page"; state.zoom = 1; state.spread = false; state.cover = false
        state.theme = "light"; state.automaticLayout = false; state.fontSize = 17; state.lineHeight = 1.4
        state.font = "system"; state.margin = 32; state.userCSS = ""; state.pageMargins = nil
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func painted() -> Bool {
            guard case .pages(let pages) = state.document?.content else { return false }
            return RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page))
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            repeat {
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if let error = state.error { throw ReadError(error) }
                if condition() { return }
            } while Date() < deadline
            XCTFail("Search workflow stalled: page=\(state.page), count=\(state.searchCountText)")
            throw CancellationError()
        }
        state.openWithoutHistory(input, at: state.currentPosition)
        try await wait { !state.busy && painted() }
        guard case .pages(let pages) = state.document?.content else { return XCTFail("Missing native reader") }
        // Match the original corpus workflow: warm first/middle/final source
        // chapters, follow the first contents entry, then search the phrase
        // extracted from the middle of the supplied book.
        for fraction in [0.0, 0.5, 1.0] {
            var target = 0
            if fraction > 0 {
                let table = await pages.chapterLayout
                let chapter = fraction == 1 ? table.chapterCount - 1 : table.chapterCount / 2
                let count = try await pages.searchPageCount(chapter)
                _ = state.applyChapterLayout(await pages.chapterLayout)
                target = state.pageNumber(.init(chapter: chapter, page: fraction == 1 ? max(0, count - 1) : count / 2))
            }
            let location = state.pageLocation(target)
            state.send(.page(target))
            try await wait { state.pageLocation(state.page) == location && painted() }
        }
        state.showContents = true; state.send(.toc)
        try await wait { !state.outlineBusy && painted() }
        if let entry = state.outline.first(where: { !$0.target.isEmpty }) {
            state.send(.href(entry.target))
            try await wait { painted() }
        }
        state.showContents = false
        try await wait { painted() }
        var mismatchedSelections = [String]()
        let selectionObservation = state.$selectedSearchTarget.sink { target in
            guard let target, !state.searchCounting, !state.searchResults.isEmpty else { return }
            if !state.searchResults.contains(where: { $0.target == target }) {
                mismatchedSelections.append("selected=\(target) published=\(state.searchResults.map(\.target))")
            }
        }
        defer { selectionObservation.cancel() }
        state.send(.find("合计四十九营二万五千人之"))
        try await wait { state.selectedSearchTarget != nil && !state.searchResults.isEmpty && !state.searchCounting && painted() }
        // Counting resumes lazy background pagination after the search finishes.
        // The selected result's displayed ordinal must survive those page-number
        // changes without publishing a target outside the visible result list.
        try await wait { state.chapterLayout?.complete == true && painted() }
        let selected = try XCTUnwrap(state.selectedSearchTarget)
        print("SEARCH_SELECTION selected=\(selected) results=\(state.searchResults.map(\.target)) count=\(state.searchCountText) sha256=\(SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())")
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertTrue(mismatchedSelections.isEmpty, mismatchedSelections.joined(separator: "\n"))
        XCTAssertTrue(state.searchResults.contains { $0.target == selected },
                      "The navigated hit must retain the same identity in the completed result list")
        XCTAssertEqual(state.searchCountText, "1 / 1")
    }
}
#endif
