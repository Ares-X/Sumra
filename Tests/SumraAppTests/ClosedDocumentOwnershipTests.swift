#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class ClosedDocumentOwnershipTests: XCTestCase {
    private final class WeakPages {
        weak var value: Pages?
        init(_ value: Pages) { self.value = value }
    }

    @MainActor
    private func install(_ url: URL, in state: ReaderState) throws -> WeakPages {
        let pages = try Pages(url, format: .markdown, deferReflowLayout: true)
        state.document = ReadingDocument(url: url, content: .pages(pages), markdownRenderer: .paged)
        return WeakPages(pages)
    }

    @MainActor
    func testClosingWindowOrReturningHomeReleasesNativePagesWhileStateSurvives() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("ownership.md")
        try "# Ownership\n\nSmall native Markdown fixture.\n".write(to: url, atomically: true, encoding: .utf8)
        defer { withExtendedLifetime(directory) {} }

        for closingWindow in [false, true] {
            let state = ReaderState(recordsHistory: false)
            defer { state.windowClosed() }
            let observed = try install(url, in: state)
            XCTAssertNotNil(observed.value)
            if closingWindow { state.windowClosed() } else { state.close() }
            // Home approval is callback based. Drain its scheduled completion;
            // do not infer object ownership from process footprint or GC hints.
            let deadline = Date().addingTimeInterval(2)
            while observed.value != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(state.document)
            XCTAssertNil(observed.value, "A retained reader state must not retain its outgoing native Pages owner")
            withExtendedLifetime(state) {}
        }
    }

    func testNativeMarkdownFileHasNoSelfRetainingOwnershipCycle() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("native-ownership.md")
        try "# Native ownership\n\nSmall fixture.\n".write(to: url, atomically: true, encoding: .utf8)
        weak var observed: NativeFile?
        try autoreleasepool {
            let native = try NativeFile(url, engine: .mupdf)
            observed = native
            XCTAssertGreaterThan(native.count, 0)
        }
        XCTAssertNil(observed, "Releasing the decoder owner must run NativeFile.deinit and its native close path")
        withExtendedLifetime(directory) {}
    }
}
#endif
