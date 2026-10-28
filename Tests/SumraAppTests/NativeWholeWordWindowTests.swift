#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeWholeWordWindowTests: XCTestCase {
    func testNormalizedUnicodePositionsKeepForwardBackwardAndAfterHits() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("unicode-positions.xhtml")
        let unit = "🙂 café cafe\u{301} CAFÉ office Straße STRASSE 中文 cafe"
        let repetitions = 32
        try "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>\(Array(repeating: unit, count: repetitions).joined(separator: " "))</p></body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        let file = try NativeFile(url, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "system", theme: "light",
            pageSize: CGSize(width: 779, height: 40000))
        XCTAssertEqual(file.count, 1)
        for (query, perUnit) in [("cafe", 4), ("strasse", 2), ("office", 1), ("中文", 1)] {
            let options = TextSearchOptions(wholeWord: true)
            let hits = try file.matches(query, page: 0, options: options)
            XCTAssertEqual(hits.count, repetitions * perUnit, query)
            XCTAssertTrue(hits.allSatisfy { !$0.rects.isEmpty && $0.source != nil })
            XCTAssertEqual(try file.matches(query, page: 0, options: options, backwards: true), Array(hits.reversed()))
            let middle = hits.count / 2
            XCTAssertEqual(try file.matches(query, page: 0, options: options, after: hits[middle].index, maximum: 1).first,
                hits[middle + 1])
            XCTAssertEqual(try file.matches(query, page: 0, options: options, after: hits[middle].index, backwards: true, maximum: 1).first,
                hits[middle - 1])
        }
    }

    func testDenseWholeWordsKeepUnicodeBoundariesAndReverseNavigation() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("whole-words.xhtml")
        let unit = "the other THE thé there _the the_ the1 1the (the) 中文the中文 the"
        let repetitions = 256
        try "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>\(Array(repeating: unit, count: repetitions).joined(separator: " "))</p></body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        let file = try NativeFile(url, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "system", theme: "light",
            pageSize: CGSize(width: 779, height: 40000))
        XCTAssertEqual(file.count, 1, "Exercise many hits in one normalized search window")
        let options = TextSearchOptions(wholeWord: true)
        let forward = try file.matches("the", page: 0, options: options)
        XCTAssertEqual(forward.count, repetitions * 5)
        XCTAssertEqual(Set(forward.map(\.index)).count, forward.count)
        XCTAssertTrue(forward.allSatisfy { !$0.rects.isEmpty && $0.source != nil })
        XCTAssertEqual(try file.matches("the", page: 0, options: options, backwards: true), Array(forward.reversed()))
        let middle = try XCTUnwrap(forward.dropFirst(forward.count / 2).first)
        XCTAssertEqual(try file.matches("the", page: 0, options: options, after: middle.index, maximum: 1).first,
            forward[forward.count / 2 + 1])
        XCTAssertEqual(try file.matches("the", page: 0, options: options, after: middle.index, backwards: true, maximum: 1).first,
            forward[forward.count / 2 - 1])
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "system", theme: "light",
            pageSize: CGSize(width: 779, height: 0))
        let continuous = try file.matches("the", page: 0, options: options)
        XCTAssertEqual(continuous.count, forward.count, "The nonwindow whole-word path keeps its existing boundaries")
        XCTAssertEqual(Set(continuous.map(\.index)).count, continuous.count)
        XCTAssertTrue(continuous.allSatisfy { !$0.rects.isEmpty })
        XCTAssertEqual(try file.matches("the", page: 0, options: options, backwards: true), Array(continuous.reversed()))
    }
}
#endif
