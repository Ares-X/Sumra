#if os(macOS)
import AppKit
import XCTest
import SumraCore
@testable import Sumra

@MainActor
final class TextBookmarkTests: XCTestCase {
    func testSameWrappedLineBookmarksSortByCharacterAndNavigateBothWaysWithWrapping() async throws {
        try await withReader(String(repeating: "word ", count: 3_000)) { state, file in
            let positions = [9, 100, 9_000].map { ReadingPosition(page: 0, anchor: String($0)) }
            let marks = positions.enumerated().map { ReaderBookmark(title: "Passage \(2 - $0.offset)", path: file.path, position: $0.element) }
            state.bookmarks = Array(marks.reversed())
            XCTAssertEqual(state.sortedBookmarks.map(\.id), marks.map(\.id))
            state.updatePosition(positions[0])
            for index in [1, 2, 0] {
                state.moveBookmark(1)
                try await assertRestore(positions[index], in: state)
            }
            for index in [2, 1, 0] {
                state.moveBookmark(-1)
                try await assertRestore(positions[index], in: state)
            }
        }
    }

    func testChineseAndNonBMPBookmarksKeepUTF16OrderAcrossSourceLines() async throws {
        let firstLine = String(repeating: "中文😀 ", count: 50) + "甲定位" + String(repeating: "文字𠀀 ", count: 80) + "乙定位"
        let text = firstLine + "\n第二行😀 丙定位\n结束"
        let source = text as NSString
        let positions = ["甲定位", "乙定位", "丙定位"].map { marker -> ReadingPosition in
            let offset = source.range(of: marker).location
            return .init(page: TextReader.Coordinator.lineIndex(offset, offsets: ChapterDetector.index(text).lines), anchor: String(offset))
        }
        XCTAssertGreaterThan(firstLine.utf16.count, firstLine.count)
        try await withReader(text) { state, file in
            let marks = positions.enumerated().map { ReaderBookmark(title: "Passage \($0.offset)", path: file.path, position: $0.element) }
            state.bookmarks = Array(marks.reversed())
            XCTAssertEqual(state.sortedBookmarks.map(\.id), marks.map(\.id))
            state.updatePosition(positions[0])
            for index in [1, 2, 0] {
                state.moveBookmark(1)
                try await assertRestore(positions[index], in: state)
            }
            for index in [2, 1, 0] {
                state.moveBookmark(-1)
                try await assertRestore(positions[index], in: state)
            }
        }
    }

    func testLegacyLineOnlyBookmarksNavigateAlongsideCharacterBookmarks() async throws {
        let text = "First line\n" + String(repeating: "中文😀 ", count: 100) + "\nLast line"
        let lineStart = ChapterDetector.index(text).lines[1]
        let positions = [ReadingPosition(page: 0), .init(page: 1), .init(page: 1, anchor: String(lineStart + 100)), .init(page: 2)]
        try await withReader(text) { state, file in
            let marks = positions.enumerated().map { ReaderBookmark(title: "Passage \($0.offset)", path: file.path, position: $0.element) }
            state.bookmarks = Array(marks.reversed())
            XCTAssertEqual(state.sortedBookmarks.map(\.id), marks.map(\.id))
            state.updatePosition(positions[0])
            for index in [1, 2, 3, 0] {
                state.moveBookmark(1)
                try await assertRestore(positions[index], in: state)
            }
            for index in [3, 2, 1, 0] {
                state.moveBookmark(-1)
                try await assertRestore(positions[index], in: state)
            }
        }
    }

    func testOpeningTextBookmarkRetainsExactCharacterAndViewportRestore() async throws {
        let text = "标题😀\n" + String(repeating: "中文𠀀 ", count: 100) + "目标😀段落"
        let offset = (text as NSString).range(of: "目标😀段落").location
        try await withReader(text) { state, file in
            let position = ReadingPosition(page: 1, x: 12, y: 3.5, anchor: String(offset), zoom: 1.75)
            state.openBookmark(.init(title: "Exact passage", path: file.path, position: position))
            try await assertRestore(position, in: state)
            XCTAssertEqual(state.zoom, 1.75)
        }
    }

    private func assertRestore(_ expected: ReadingPosition, in state: ReaderState, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard case .restore(let actual) = state.command.action else {
            return XCTFail("Expected the selected bookmark's restore request", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(state.currentPosition.page, expected.page, file: file, line: line)
        XCTAssertEqual(state.currentPosition.anchor, expected.anchor, file: file, line: line)
        XCTAssertEqual(state.currentPosition.x, expected.x, file: file, line: line)
        XCTAssertEqual(state.currentPosition.y, expected.y, file: file, line: line)
        state.didHandleCommand(state.command.revision)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func withReader(_ text: String, _ body: (ReaderState, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("book.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableHistory")
        defaults.set(true, forKey: "disableHistory")
        let state = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed()
            defaults.set(previous, forKey: "disableHistory")
            withExtendedLifetime(directory) {}
        }
        state.document = ReadingDocument(url: file, content: .text(text))
        state.count = ChapterDetector.index(text).lines.count
        state.bookmarksByName = false
        try await body(state, file)
    }
}
#endif
