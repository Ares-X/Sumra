#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ExploratoryReaderWorkflowTests: XCTestCase {
    func testLegacyFormatDefaultsIgnoreThePreviousBooksCoordinatesWithoutRewritingSettings() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("fresh.md")
        try "# A new book\n\nThis book has never been opened.\n".write(to: file, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let keys = ["formatDefaults", "theme", MarkdownRenderer.preferenceKey(for: file)]
        let previous = keys.map { defaults.object(forKey: $0) }
        let state = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed()
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        let legacy = ReadingPosition(page: 9, pageCount: 20, scrollFraction: 0.75, x: 25, y: 1200,
            pageLocalOffset: .init(point: CGPoint(x: 40, y: 80), bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            anchor: "old-book", nativePassage: .init(source: .init(node: 317, offset: 0, part: 0), offsetX: 0, offsetY: 12,
                sourceRevision: "previous-book", styleSignature: "previous-style"),
            fit: "width", flow: "continuous", rotation: 90, font: "serif", fontSize: 24, pdfCoordinateSpace: "fitz")
        let json = String(decoding: try JSONEncoder().encode(["markdown": legacy]), as: UTF8.self)
        defaults.set(json, forKey: "formatDefaults")
        defaults.set("dark", forKey: "theme")
        defaults.set(MarkdownRenderer.paged.rawValue, forKey: MarkdownRenderer.preferenceKey(for: file))
        state.openWithoutHistory(file)
        try await settle(state)
        XCTAssertEqual(state.page, 0)
        XCTAssertNil(state.location.pageCount); XCTAssertNil(state.location.scrollFraction)
        XCTAssertNil(state.location.x); XCTAssertNil(state.location.y); XCTAssertNil(state.location.anchor)
        XCTAssertNil(state.location.pageLocalOffset); XCTAssertNil(state.location.nativePassage)
        XCTAssertNil(state.location.pdfCoordinateSpace)
        XCTAssertEqual(state.rotation, 0)
        XCTAssertEqual(state.fit, "width"); XCTAssertEqual(state.flow, "continuous")
        XCTAssertEqual(state.font, "serif"); XCTAssertEqual(state.fontSize, 24); XCTAssertEqual(state.theme, "dark")
        XCTAssertEqual(defaults.string(forKey: "formatDefaults"), json, "Opening must not rewrite the stored settings")
    }

    func testSavingNativeFormatDefaultsDoesNotSendAnotherBookToTheCurrentPassage() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let first = directory.url.appendingPathComponent("first.md")
        let second = directory.url.appendingPathComponent("second.md")
        let text = (0..<100).map { "Paragraph \($0) has enough authored text to retain its source position across native reading modes.\n\n" }.joined()
        try text.write(to: first, atomically: true, encoding: .utf8)
        try text.write(to: second, atomically: true, encoding: .utf8)
        let keys = ["formatDefaults", "theme", "disableHistory", MarkdownRenderer.preferenceKey(for: second)]
        let defaults = UserDefaults.standard
        let previous = keys.map { defaults.object(forKey: $0) }
        let state = ReaderState(recordsHistory: false)
        let other = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed(); other.windowClosed()
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        defaults.set("{}", forKey: "formatDefaults")
        defaults.set("dark", forKey: "theme")
        defaults.set(true, forKey: "disableHistory")
        defaults.set(MarkdownRenderer.paged.rawValue, forKey: MarkdownRenderer.preferenceKey(for: second))
        let pages = try Pages(first, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 19, lineHeight: 1.6, margin: 48, font: "serif", theme: "dark",
                                    pageSize: CGSize(width: 480, height: 0))
        let position = try await pages.position(page: 0, x: 0, y: 1200)
        XCTAssertNotNil(position.nativePassage)
        state.document = ReadingDocument(url: first, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.reflowable = true; state.flow = "continuous"
        state.location = position; state.location.scrollFraction = 0.75
        state.fontSize = 19; state.margin = 48; state.theme = "dark"
        state.saveFormatDefaults()
        let saved = try formatDefaults("markdown")
        XCTAssertNil(saved.nativePassage, "A format default must not carry the source book's semantic passage")
        XCTAssertNil(saved.scrollFraction, "The new book must begin at its own start")
        XCTAssertEqual(saved.fontSize, 19); XCTAssertEqual(saved.margin, 48)
        XCTAssertEqual(saved.flow, "continuous")
        let savedValues = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertNil(savedValues["theme"])
        other.openWithoutHistory(second)
        try await settle(other)
        XCTAssertNil(other.currentPosition.nativePassage)
        XCTAssertNil(other.location.scrollFraction)
        XCTAssertEqual(other.fontSize, 19); XCTAssertEqual(other.theme, "dark")
    }

    func testSavingImageDefaultsDoesNotCopyTheViewportOffsetIntoAnotherImage() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let first = directory.url.appendingPathComponent("first.png")
        let second = directory.url.appendingPathComponent("second.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: first); try bytes.write(to: second)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "formatDefaults")
        let state = ReaderState(recordsHistory: false), other = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed(); other.windowClosed(); defaults.set(previous, forKey: "formatDefaults")
            withExtendedLifetime(directory) {}
        }
        defaults.set("{}", forKey: "formatDefaults")
        state.document = try ReadingDocument.open(first)
        state.location = .init(page: 0, pageLocalOffset: .init(point: CGPoint(x: 40, y: 80),
                                                            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        state.fit = "width"; state.zoom = 2
        state.saveFormatDefaults()
        let saved = try formatDefaults("image")
        XCTAssertNil(saved.pageLocalOffset, "An image default must not carry a viewport position from a different image")
        XCTAssertEqual(saved.fit, "width"); XCTAssertEqual(saved.zoom, 2)
        other.openWithoutHistory(second)
        try await settle(other)
        XCTAssertNil(other.currentPosition.pageLocalOffset)
        XCTAssertEqual(other.fit, "width"); XCTAssertEqual(other.zoom, 2)
    }

    func testOverlappingFormatOpensKeepOnlyTheFinalExplicitSettingsAndResetFind() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let text = directory.url.appendingPathComponent("first.txt")
        let html = directory.url.appendingPathComponent("replacement.html")
        try "Original text reader".write(to: text, atomically: true, encoding: .utf8)
        try "<html><body><p>Replacement HTML reader</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let keys = ["formatDefaults", "theme", "useFixedPageUI", "disableHistory"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let state = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed()
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        let formats = ["text": ReadingPosition(fontSize: 21),
                       "html": ReadingPosition(flow: "continuous", fontSize: 25)]
        defaults.set(String(decoding: try JSONEncoder().encode(formats), as: UTF8.self), forKey: "formatDefaults")
        defaults.set("dark", forKey: "theme")
        defaults.set(false, forKey: "useFixedPageUI"); defaults.set(true, forKey: "disableHistory")
        state.openWithoutHistory(text)
        try await settle(state)
        XCTAssertEqual(state.fontSize, 21); XCTAssertEqual(state.theme, "dark")
        state.showFindPanel(); state.updateFindQuery("Original")
        state.openWithoutHistory(html, at: .init(x: 4, y: 90, fontSize: 29))
        state.openWithoutHistory(text, at: .init(x: 0, y: 12, fontSize: 23))
        state.openWithoutHistory(html, at: .init(x: 8, y: 150, fontSize: 27))
        try await settle(state)
        XCTAssertEqual(state.document?.url, html)
        XCTAssertTrue(state.isBrowser)
        XCTAssertEqual(state.fontSize, 27); XCTAssertEqual(state.theme, "dark")
        XCTAssertEqual(state.flow, "continuous")
        XCTAssertEqual(state.currentPosition.x, 8); XCTAssertEqual(state.currentPosition.y, 150)
        XCTAssertFalse(state.showFind); XCTAssertEqual(state.findQuery, "")
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(state.command.action, .none, "The outgoing text reader's delayed search must not reach HTML")
        state.close()
        XCTAssertNil(state.document)
        state.openWithoutHistory(text)
        try await settle(state)
        XCTAssertEqual(state.fontSize, 21); XCTAssertEqual(state.theme, "dark")
        XCTAssertNil(state.currentPosition.y)
    }

    private func formatDefaults(_ format: String) throws -> ReadingPosition {
        let raw = try XCTUnwrap(UserDefaults.standard.string(forKey: "formatDefaults"))
        return try XCTUnwrap(JSONDecoder().decode([String: ReadingPosition].self, from: Data(raw.utf8))[format])
    }

    private func settle(_ state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        while state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.error)
    }
}
#endif
