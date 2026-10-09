#if os(macOS)
import AppKit
import SumraCore
import WebKit
import XCTest
@testable import Sumra

final class BrowserSchemeErrorTests: XCTestCase {
    @MainActor
    func testFailedMainTopicPreservesReadErrorThroughWebKitNavigation() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-Scheme-" + UUID().uuidString)
        let book = fixture.appendingPathComponent("book", isDirectory: true)
        let topic = book.appendingPathComponent("broken.html")
        let outside = fixture.appendingPathComponent("outside.html")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("<p>Original topic</p>".utf8).write(to: topic)
        try Data("<p>Outside topic</p>".utf8).write(to: outside)
        let source = try MarkupSource(topic)
        // Page identity remains registered, but the source rejects this moved
        // target at its document-folder boundary during the scheme request.
        try FileManager.default.removeItem(at: topic)
        try FileManager.default.createSymbolicLink(at: topic, withDestinationURL: outside)
        let state = ReaderState(recordsHistory: false)
        state.document = .init(url: source.url, content: .browser(source))
        let coordinator = BrowserReader.Coordinator(state: state, source: source)
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            window.contentView = nil
            window.close()
        }

        coordinator.load(view)
        for _ in 0..<100 {
            if coordinator.readerError != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let actual = try XCTUnwrap(coordinator.readerError.map { $0 as NSError })
        let original = ReadError("Resource is outside the document folder") as NSError
        XCTAssertEqual(actual.domain, original.domain)
        XCTAssertEqual(actual.code, original.code)
        XCTAssertEqual(actual.userInfo[NSLocalizedDescriptionKey] as? String, original.localizedDescription)
        XCTAssertEqual(state.error, original.localizedDescription)
        XCTAssertFalse(coordinator.ready)
    }
}
#endif
