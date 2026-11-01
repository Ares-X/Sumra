#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import Sumra

@MainActor
final class ReaderSpeechCompletionTests: XCTestCase {
    func testFinalBrowserPageClearsTheLastSpokenWord() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("Last.html")
        try "<p>The final paragraph.</p>".write(to: url, atomically: true, encoding: .utf8)
        let document = ReadingDocument(url: url, content: .browser(try MarkupSource(url)))
        try await assertFinalPageClearsHighlight(document)
    }

    func testFinalNativePageClearsTheLastSpokenWord() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("Last.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        writer.beginPDFPage(nil); writer.endPDFPage(); writer.closePDF()
        let document = try ReadingDocument.open(url)
        guard case .pages = document.content else { return XCTFail("Expected the native page reader") }
        try await assertFinalPageClearsHighlight(document)
    }

    private func assertFinalPageClearsHighlight(_ document: ReadingDocument,
                                              file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = document
        state.count = 1
        let word = ReaderAction.speechHighlight(location: 4, length: 3)
        let clear = ReaderAction.speechHighlight(location: 0, length: 0)
        var actions = [ReaderAction]()
        let observation = state.$command.dropFirst().sink { command in
            actions.append(command.action)
            state.didHandleCommand(command.revision)
        }
        defer {
            observation.cancel()
            state.document = nil
            state.windowClosed()
        }

        // Empty final passages enter the same readNextPage termination as a
        // completed page, without starting audible system speech in the test.
        // Queue a last word before that asynchronous termination is delivered.
        state.readText("", page: 0)
        state.send(word)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, state.speechRequested || actions.last != clear || actions.count < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(actions, [clear, word, clear],
            "Completing the last page must clear its last highlighted word", file: file, line: line)
        XCTAssertFalse(state.speechRequested, file: file, line: line)
        XCTAssertFalse(state.speechActive, file: file, line: line)
        XCTAssertFalse(state.speechPaused, file: file, line: line)
        XCTAssertNil(state.speechPage, file: file, line: line)
        XCTAssertNil(state.error, file: file, line: line)
    }
}
#endif
