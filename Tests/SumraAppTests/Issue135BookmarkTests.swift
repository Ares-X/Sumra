#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class Issue135BookmarkTests: XCTestCase {
    func testRestoredPDFViewportTogglesAtDevicePixelPrecision() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), url = directory.url.appendingPathComponent("viewport.pdf")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Native/AttachmentCompressionLimit.pdf")
        try FileManager.default.copyItem(at: fixture, to: url)
        let pages = try Pages(url, format: .pdf), state = ReaderState(recordsHistory: false)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "bookmarks")
        state.document = ReadingDocument(url: url, content: .pages(pages)); state.count = await pages.count
        state.flow = "continuous"; state.spread = false; state.fit = "custom"; state.zoom = 2.5
        state.automaticLayout = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.contentView = nil; window.close()
            defaults.set(previous, forKey: "bookmarks"); defaults.removeObject(forKey: "position:" + url.path)
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail(state.error ?? "PDF viewport did not settle")
        }
        try await waitFor { state.readerScrollView != nil && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) }
        let scroll = try XCTUnwrap(state.readerScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 40, y: 70)); scroll.reflectScrolledClipView(scroll.contentView)
        try await waitFor { (state.currentPosition.y ?? 0) > 0 }
        RasterReader.recordPosition(in: state.readerFocusView)
        let saved = try XCTUnwrap(state.filePosition)
        let bookmark = ReaderBookmark(title: "Viewport", path: url.path, position: saved)
        state.bookmarks = [bookmark]
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        try await waitFor { (state.currentPosition.y ?? 0) < (saved.y ?? 0) }
        state.openBookmark(bookmark)
        try await waitFor { abs((state.currentPosition.y ?? 0) - (saved.y ?? 0)) < 0.1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        RasterReader.recordPosition(in: state.readerFocusView)
        let restored = try XCTUnwrap(state.filePosition)
        // The observed native restore can differ by one ULP. Anchor this
        // regression to the actual settled viewport even when this fixture's
        // round trip happens to produce an exactly representable coordinate.
        var adjacent = restored; adjacent.x = try XCTUnwrap(restored.x).nextUp
        XCTAssertNotEqual(adjacent.x, restored.x)
        let sameViewport = ReaderBookmark(title: "Viewport", path: url.path, position: adjacent)
        var distinct = restored; distinct.y = (restored.y ?? 0) + 5
        let other = ReaderBookmark(title: "Different viewport", path: url.path, position: distinct)
        var earlierPosition = restored; earlierPosition.y = (restored.y ?? 0) - 5
        let earlier = ReaderBookmark(title: "Earlier viewport", path: url.path, position: earlierPosition)
        state.bookmarks = [other, sameViewport, earlier]
        state.moveBookmark(1)
        try await waitFor { state.currentPosition.y == distinct.y }
        XCTAssertEqual(state.currentPosition.y, distinct.y, "Next must skip the current viewport")
        state.updatePosition(restored)
        adjacent.x = try XCTUnwrap(restored.x).nextDown
        let sameViewportBefore = ReaderBookmark(title: "Viewport", path: url.path, position: adjacent)
        state.bookmarks = [other, sameViewportBefore, earlier]
        state.moveBookmark(-1)
        try await waitFor { state.currentPosition.y == earlierPosition.y }
        XCTAssertEqual(state.currentPosition.y, earlierPosition.y, "Previous must skip the current viewport")
        state.updatePosition(restored)
        let cancelUnexpectedAlert = Timer(timeInterval: 0.5, repeats: false) { _ in
            if NSApp.modalWindow != nil { NSApp.stopModal(withCode: .cancel) }
        }
        RunLoop.main.add(cancelUnexpectedAlert, forMode: .modalPanel)
        state.toggleBookmark()
        cancelUnexpectedAlert.invalidate()
        XCTAssertEqual(state.bookmarks.map(\.id), [other.id, earlier.id], "A restored viewport must toggle only its existing bookmark")
    }

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
