#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class Issue135BookmarkTests: XCTestCase {
    func testPDFBookmarksDistinguishPositionsOnOnePage() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("bookmark.pdf")
        // An existing PDF fixture exercises the actual Pages document owner.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Native/AttachmentCompressionLimit.pdf")
        try FileManager.default.copyItem(at: fixture, to: url)
        let pages = try Pages(url, format: .pdf), state = ReaderState(recordsHistory: false)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "bookmarks")
        defer {
            state.windowClosed(); defaults.set(previous, forKey: "bookmarks")
            defaults.removeObject(forKey: "position:" + url.path)
            withExtendedLifetime(directory) {}
        }
        state.document = ReadingDocument(url: url, content: .pages(pages)); state.count = await pages.count
        let firstPosition = ReadingPosition(page: 0, x: 10, y: 50, pdfCoordinateSpace: "fitz")
        let secondPosition = ReadingPosition(page: 0, x: 10, y: 400, pdfCoordinateSpace: "fitz")
        let first = ReaderBookmark(title: "First", path: url.path, position: firstPosition)
        let second = ReaderBookmark(title: "Second", path: url.path, position: secondPosition)
        state.bookmarks = [first, second]; state.bookmarksByName = false
        XCTAssertEqual(state.sortedBookmarks.map(\.id), [first.id, second.id])
        state.updatePosition(secondPosition)
        state.toggleBookmark()
        XCTAssertEqual(state.bookmarks.map(\.id), [first.id], "Toggle must remove the matching viewport, not the first bookmark on the page")
        state.bookmarks = [first, second]
        state.updatePosition(firstPosition)
        state.moveBookmark(1)
        let deadline = Date().addingTimeInterval(3)
        while state.currentPosition.y != 400 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(state.currentPosition.y, 400)
        state.moveBookmark(1)
        while state.currentPosition.y != 50 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(state.currentPosition.y, 50, "Next wraps within the file")
    }

    func testOpeningPDFConvertsLegacyBookmarksBeforeToggle() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), url = directory.url.appendingPathComponent("legacy.pdf")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Native/AttachmentCompressionLimit.pdf")
        try FileManager.default.copyItem(at: fixture, to: url)
        let pages = try Pages(url, format: .pdf), state = ReaderState(recordsHistory: false)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "bookmarks")
        defer {
            state.windowClosed(); defaults.set(previous, forKey: "bookmarks")
            defaults.removeObject(forKey: "position:" + url.path)
            withExtendedLifetime(directory) {}
        }
        let old = ReadingPosition(page: 0, x: 10, y: 10)
        let converted = try await ReaderState.restoreSavedPDFPosition(old, pages: pages)
        XCTAssertNotEqual(converted.y, old.y, "Fixture must distinguish PDFKit and MuPDF coordinates")
        let legacy = ReaderBookmark(title: "Legacy", path: url.path, position: old)
        let current = ReaderBookmark(title: "Current", path: url.path,
            position: ReadingPosition(page: 0, x: 10, y: 10, pdfCoordinateSpace: "fitz"))
        state.bookmarks = [legacy, current]
        state.openWithoutHistory(url)
        let deadline = Date().addingTimeInterval(5)
        while state.document == nil && state.error == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(state.document); XCTAssertNil(state.error)
        XCTAssertEqual(state.bookmarks.first(where: { $0.id == legacy.id })?.position, converted)
        state.updatePosition(current.position)
        state.toggleBookmark()
        XCTAssertEqual(state.bookmarks.map(\.id), [legacy.id], "The raw legacy coordinates must not match the new viewport")
    }
}
#endif
