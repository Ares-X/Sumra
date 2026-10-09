import Foundation
import XCTest
@testable import SumraCore

final class ChapterDetectorTests: XCTestCase {
    func testCombinedIndexKeepsUTF16OffsetsAndChapterLinesAcrossMixedNewlines() {
        let text = "\u{feff}第一章 起点\r\n\t\r\n😀正文。\u{2028}\u{2028}第二章 终点\r\n"
        let index = ChapterDetector.index(text)
        XCTAssertEqual(index.lines, [0, 9, 12, 18, 19, 27])
        XCTAssertEqual(index.chapters, [
            .init(title: "第一章 起点", line: 0),
            .init(title: "第二章 终点", line: 4)
        ])
    }

    func testIsolationUsesBothNeighboursWithoutTreatingBOMAsABlankLine() {
        let text = "正文\n第一章 接正文\n\n \t\nEpilogue\n"
        XCTAssertEqual(ChapterDetector.index(text).chapters, [.init(title: "Epilogue", line: 4)])
        XCTAssertTrue(ChapterDetector.index("\u{feff}\nChapter 1 Adjacent BOM\n").chapters.isEmpty)
        XCTAssertEqual(ChapterDetector.index("Chapter 1 First\nChapter 2 Second").chapters.map(\.line), [0, 1])
    }

    func testHeadingLimitCountsGraphemesAndRejectsLongProse() {
        let prefix = "Chapter 1 "
        let title = prefix + String(repeating: "e\u{0301}", count: 80 - prefix.count)
        XCTAssertEqual(ChapterDetector.index(title).chapters.map(\.title), [title])
        XCTAssertTrue(ChapterDetector.index(title + "e\u{0301}").chapters.isEmpty)
        XCTAssertTrue(ChapterDetector.index(prefix + String(repeating: "字", count: 25_402)).chapters.isEmpty)
    }

    func testLongCRLFBookRetainsNavigationThroughLongAndRepeatedProseLines() {
        let text = "第一章 起点\r\n\r\n" + String(repeating: "字", count: 25_402) + "\r\n"
            + String(repeating: "😀正文。\r\n", count: 10_000) + "\r\n第二章 终点\r\n"
        let index = ChapterDetector.index(text)
        XCTAssertEqual(index.lines.count, 10_006)
        XCTAssertEqual(index.chapters.map(\.line), [0, 10_004])
        XCTAssertEqual(index.lines[10_004], (text as NSString).range(of: "第二章 终点").location)
        XCTAssertEqual(index.lines.last, (text as NSString).length)
    }

    func testCancellationDoesNotPublishAPartialIndex() async {
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ChapterDetector.index("第一章 起点\r\n\r\n正文。\r\n")
        }.value
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertTrue(result.chapters.isEmpty)
    }
}
