#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderInitialLayoutTests: XCTestCase {
    func testInitialViewportUsesTheMountedWindowLayout() async throws {
        _ = NSApplication.shared
        var measurements = [CGSize]()
        let host = NSHostingView(rootView: ReaderInitialViewport { measurements.append($0) })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        window.setContentSize(CGSize(width: 800, height: 600))
        window.orderFront(nil)

        let deadline = Date().addingTimeInterval(5)
        while measurements.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(measurements, [CGSize(width: 800, height: 600)])
        window.setContentSize(CGSize(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(measurements.count, 1, "Later resizing belongs to the mounted raster reader")
    }

    func testMarkdownUsesItsReadingModeViewportForItsFirstLayout() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("FirstViewport.md")
        try String(repeating: "Text remains continuous through the whole book.\n\n", count: 160)
            .write(to: input, atomically: true, encoding: .utf8)

        for (flow, spread) in [("continuous", false), ("paged", false), ("paged", true)] {
        for mode in ["shown", "smart", "hidden"] {
            let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: input, content: .pages(pages))
            state.flow = flow; state.spread = spread; state.fit = "width"
            state.font = "serif"; state.fontSize = 17; state.lineHeight = 1.4
            state.theme = "light"; state.userCSS = ""; state.pageMargins = nil
            state.scrollbarMode = mode; state.automaticLayout = false
            state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
            let host = NSHostingView(rootView: ReaderView(state: state))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
            window.orderFront(nil)
            defer { state.windowClosed(); window.contentView = nil; window.close() }

            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertNil(state.error)
            XCTAssertTrue(RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)))
            // Allow mounted-scroll-view callbacks to deliver any width change.
            try await Task.sleep(nanoseconds: 100_000_000)
            let revision = await pages.layoutRevision
            let bounds = try await pages.bounds(0)
            let clip = try XCTUnwrap(state.readerScrollView?.contentView.safeAreaRect.size)
            let expected = RasterReader.pageSize(in: clip, spread: spread, continuous: flow == "continuous")
            XCTAssertEqual(bounds.width, expected.width, accuracy: 0.01, "\(flow) \(spread) \(mode)")
            XCTAssertEqual(revision, 1, "\(flow) \(spread) \(mode) must use the actual viewport before mounting")
            if flow == "continuous" { XCTAssertGreaterThan(bounds.height, clip.height) }
            else { XCTAssertEqual(bounds.height, expected.height, accuracy: 0.01) }
        }
        }
    }
}
#endif
