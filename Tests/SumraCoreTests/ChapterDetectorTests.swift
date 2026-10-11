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

    func testStructuralCandidatesRetainTrimmedTitlesAndProseRejection() {
        let suffix = String(repeating: "👨‍👩‍👧‍👦", count: 70)
        let title = "Chapter 1 " + suffix
        let text = "\u{feff}\t" + title + "  \r\n\r\nChapter 2 ends like prose。\r\n\r\n"
            + title + "👨‍👩‍👧‍👦\r\n\r\n" + String(repeating: "ordinary prose ", count: 1_000)
        let result = ChapterDetector.index(text)
        XCTAssertEqual(result.chapters, [.init(title: title, line: 0)])
        XCTAssertEqual(result.lines, ChapterDetector.lineOffsets(text))
        for ending in ["。", "！", "?", ";", ","] {
            XCTAssertTrue(ChapterDetector.detect("Chapter 1 a title" + ending).isEmpty)
        }
    }

    func testWrappedNumberedProseDoesNotBecomeAChapterThroughFamilyConsistency() {
        let text = "第一章 开始\r\n\r\n正文上一行\r\n"
            + "    第二回交谈了一小时左右，我坐在地板上喘着，对方正坐在一旁继续\r\n"
            + "正文接着写\r\n\r\n第三章 收束\r\n\r\n"
        let index = ChapterDetector.index(text)
        XCTAssertEqual(index.chapters, [
            .init(title: "第一章 开始", line: 0),
            .init(title: "第三章 收束", line: 6)
        ])
        XCTAssertEqual(index.lines, ChapterDetector.lineOffsets(text))
    }

    func testRejectedProseDoesNotEstablishChapterFamilyConsistency() {
        let text = "正文\n第一章提及过往\n正文继续\n"
            + "第二回交谈了一小时左右，我坐在地板上喘着，对方正坐在一旁继续\n"
            + "正文结束"
        XCTAssertTrue(ChapterDetector.detect(text).isEmpty)
    }

    func testPunctuatedAndCompactChapterTitlesKeepTheirStructuralBoundaries() {
        let separated = ["第1章 平原，山谷", "第2章：雨天，晴天", "第3章—风雪；归途"]
        let unisolated = "正文\n" + separated.joined(separator: "\n正文\n") + "\n正文"
        XCTAssertEqual(ChapterDetector.detect(unisolated).map(\.title), separated)

        let compact = ["第一回山河，故人", "第二回风雨；归途", "第三回何处？远方"]
        let isolated = "正文\n\n" + compact.joined(separator: "\n\n正文\n\n") + "\n\n正文"
        XCTAssertEqual(ChapterDetector.detect(isolated).map(\.title), compact)
        XCTAssertEqual(ChapterDetector.detect("第一章科学边界\n正文\n第二章黑暗森林").map(\.line), [0, 2])
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
