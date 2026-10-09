#if os(macOS)
import AppKit
import CoreText
import SumraCore
import XCTest
@testable import Sumra

final class PDFTextFeaturesTests: XCTestCase {
    @MainActor
    func testNativePDFSearchKeepsAllMatchesAndWholeWordSemantics() async throws {
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("many-matches.pdf")
        defer { withExtendedLifetime(directory) {} }
        var box = CGRect(x: 0, y: 0, width: 600, height: 1300)
        let context = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 8, nil)]
        let word = CTLineCreateWithAttributedString(NSAttributedString(string: "one", attributes: attributes))
        for index in 0..<1_201 {
            context.textPosition = CGPoint(x: 10 + (index % 20) * 25, y: 1250 - (index / 20) * 20)
            CTLineDraw(word, context)
        }
        context.textPosition = CGPoint(x: 10, y: 1280)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "One ones one", attributes: attributes)), context)
        context.endPDFPage(); context.closePDF()
        let pages = try Pages(input, format: .pdf)
        let all = try await pages.matches("one", page: 0)
        let whole = try await pages.matches("one", page: 0, options: .init(wholeWord: true))
        let exact = try await pages.matches("one", page: 0, options: .init(caseSensitive: true, wholeWord: true))
        XCTAssertEqual(all.count, 1_204)
        XCTAssertEqual(whole.count, 1_203)
        XCTAssertEqual(exact.count, 1_202)
        let info = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(info).dirty)
    }

    @MainActor
    func testTextSearchUsesUTF16RangesAndFindsEveryMatch() throws {
        let source = "😀 Match MATCH match"
        XCTAssertEqual(try TextReader.Coordinator.matches(source, query: "match"), [
            NSRange(location: 3, length: 5), NSRange(location: 9, length: 5), NSRange(location: 15, length: 5),
        ])
        XCTAssertEqual(try TextReader.Coordinator.matches(String(repeating: "a ", count: 1_201), query: "a").count, 1_201)
        XCTAssertTrue(try TextReader.Coordinator.matches(source, query: "").isEmpty)
    }

    @MainActor
    func testTextSearchMovesBothDirectionsAndWraps() async {
        _ = NSApplication.shared
        let state = ReaderState()
        let view = NSTextView(usingTextLayoutManager: true)
        view.string = "keep one one one"
        let selection = NSRange(location: 0, length: 4)
        view.setSelectedRange(selection)
        let coordinator = TextReader.Coordinator(state)
        coordinator.view = view
        coordinator.find("one")
        await coordinator.searchTask?.value
        XCTAssertEqual(coordinator.hit, 0)
        XCTAssertEqual(state.selectedSearchTarget, "text:5:3")
        coordinator.find("one")
        XCTAssertEqual(coordinator.hit, 1)
        coordinator.find("one", backwards: true)
        XCTAssertEqual(coordinator.hit, 0)
        coordinator.find("one", backwards: true)
        XCTAssertEqual(coordinator.hit, 2)
        XCTAssertEqual(state.status, "3 of 3 matches")
        XCTAssertEqual(state.searchResults.count, 3)
        coordinator.go(state.searchResults[1].target)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(coordinator.hit, 1)
        XCTAssertEqual(state.status, "2 of 3 matches")
        XCTAssertEqual(state.selectedSearchTarget, state.searchResults[1].target)
        coordinator.find("one", fromSelection: true)
        XCTAssertEqual(coordinator.hit, 0)
        coordinator.find("")
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testChangingSearchOptionsReplacesResultsAndCancelledSearchCannotPublish() async {
        let state = ReaderState(), view = NSTextView(usingTextLayoutManager: true)
        view.string = "One ones one"
        let coordinator = TextReader.Coordinator(state)
        coordinator.view = view
        coordinator.find("one")
        await coordinator.searchTask?.value
        XCTAssertEqual(coordinator.results.count, 3)
        coordinator.find("one", options: .init(caseSensitive: true, wholeWord: true))
        await coordinator.searchTask?.value
        XCTAssertEqual(coordinator.results, [NSRange(location: 9, length: 3)])
        view.string = String(repeating: "one ", count: 20_000)
        coordinator.find("one", options: .init(wholeWord: true))
        let pending = coordinator.searchTask
        coordinator.cancelFind()
        await pending?.value
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testTextAnchorFindsTheContainingLineAtBothEdges() {
        let offsets = [0, 8, 19]
        XCTAssertEqual(TextReader.Coordinator.lineIndex(0, offsets: offsets), 0)
        XCTAssertEqual(TextReader.Coordinator.lineIndex(7, offsets: offsets), 0)
        XCTAssertEqual(TextReader.Coordinator.lineIndex(8, offsets: offsets), 1)
        XCTAssertEqual(TextReader.Coordinator.lineIndex(200, offsets: offsets), 2)
    }

}
#endif
