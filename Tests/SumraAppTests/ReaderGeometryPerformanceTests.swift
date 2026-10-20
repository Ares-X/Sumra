#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderGeometryPerformanceTests: XCTestCase {
    private func writeImage(_ size: CGSize, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        try ReaderImages.encoded(XCTUnwrap(context.makeImage()), extension: "png").write(to: url)
    }

    func testImageEstimateInvalidatesForNewMeasurementsAndKeepsPageOrderTies() async throws {
        let directory = try TemporaryDirectory()
        let a = CGSize(width: 120, height: 160), b = CGSize(width: 140, height: 180)
        for (index, size) in [a, b, b, a].enumerated() {
            try writeImage(size, to: directory.url.appendingPathComponent("\(index).png"))
        }
        let pages = try Pages(directory.url, format: .comic)
        let empty = await pages.estimatedBounds()
        XCTAssertEqual(empty.size, CGSize(width: 420, height: 595))
        for (page, expected) in [(3, a), (2, b), (0, a), (1, a)] {
            _ = try await pages.bounds(page)
            for _ in 0..<3 {
                let estimate = await pages.estimatedBounds()
                XCTAssertEqual(estimate.size, expected, "Ties follow page order, not measurement order")
            }
        }
        _ = try await pages.image(1, width: 32)
        let afterRendering = await pages.estimatedBounds()
        XCTAssertEqual(afterRendering.size, a)
        withExtendedLifetime(directory) {}
    }

    func testImageEstimateKeepsFirstSixteenSizesAndIgnoresSmallSpacers() async throws {
        let directory = try TemporaryDirectory()
        let first = CGSize(width: 120, height: 160), ignored = CGSize(width: 240, height: 320)
        var sizes = [CGSize(width: 40, height: 60)]
        sizes += (0..<16).map { CGSize(width: 120 + $0, height: 160 + $0) }
        sizes += Array(repeating: ignored, count: 4)
        for (index, size) in sizes.enumerated() {
            try writeImage(size, to: directory.url.appendingPathComponent(String(format: "%02d.png", index)))
        }
        let pages = try Pages(directory.url, format: .comic)
        // Discover the frequent late size first; admission is still determined
        // by page order once the earlier sizes have been measured.
        for page in sizes.indices.reversed() { _ = try await pages.bounds(page) }
        let estimate = await pages.estimatedBounds()
        XCTAssertEqual(estimate.size, first)
        withExtendedLifetime(directory) {}
    }

    private func field(_ name: String, in value: Any) -> Any? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value
    }

    private func unwrapped(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
    }

    @MainActor
    func testFixedDocumentArithmeticGeometryMatchesPlacedPagesAndRestoresTailPosition() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), count = 7
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 160)
        let pdf = directory.url.appendingPathComponent("uniform.pdf")
        var mediaBox = bounds
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &mediaBox, nil))
        for _ in 0..<count {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
        let images = directory.url.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for index in 0..<count { try writeImage(bounds.size, to: images.appendingPathComponent("\(index).png")) }

        for isPDF in [false, true] {
            let input = isPDF ? pdf : images
            let pages = try Pages(input, format: isPDF ? .pdf : .comic)
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: input, content: .pages(pages))
            state.count = count; state.flow = "continuous"; state.fit = "width"
            state.automaticLayout = false; state.freePan = false; state.uniformPageWidth = false
            state.trimEmptyMargins = false; state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
            state.showFitContentArea = false; state.engineeringEnhance = "off"
            let host = NSHostingView(rootView: RasterReader(state: state, pages: pages, initialBounds: bounds))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { state.windowClosed(); window.contentView = nil; window.close() }

            func geometry() -> (PageRows.UniformLayout, CGSize)? {
                guard let scroll = state.readerScrollView,
                      let key = unwrapped(field("key", in: scroll)),
                      field("spread", in: key) as? Bool == state.spread,
                      field("cover", in: key) as? Bool == state.cover,
                      field("rtl", in: key) as? Bool == state.rtl,
                      field("rotation", in: key) as? Int == state.rotation,
                      let viewport = field("viewport", in: key) as? CGSize,
                      let value = unwrapped(field("geometry", in: scroll)),
                      let payload = Mirror(reflecting: value).children.first,
                      payload.label == "uniform", let layout = payload.value as? PageRows.UniformLayout else { return nil }
                return (layout, viewport)
            }

            func settle() async throws -> (PageRows.UniformLayout, CGSize) {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    if let result = geometry() { return result }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline && state.error == nil
                XCTFail(state.error ?? "Fixed document did not use arithmetic page geometry")
                throw CancellationError()
            }

            for spread in [false, true] {
                for cover in [false, true] {
                    for rtl in [false, true] {
                        for rotation in [0, 90] {
                            state.spread = spread; state.cover = cover; state.rtl = rtl; state.rotation = rotation
                            let (actual, viewport) = try await settle()
                            let rows = PageRows.ranges(count: count, spread: spread, cover: cover)
                            var sizes = [CGSize](repeating: .zero, count: count)
                            for row in rows {
                                let size = RasterLayout.size(page: bounds.size, viewport: viewport,
                                    columns: isPDF && spread ? 2 : row.count, rotation: rotation, fit: "width", zoom: 1,
                                    limit: state.zoomLimit, origin: bounds.origin)
                                for page in row { sizes[page] = size }
                            }
                            let expected = PageRows.layout(displaySizes: sizes, viewport: viewport, page: 0,
                                continuous: true, spread: spread, cover: cover, rtl: rtl,
                                spacing: CGSize(width: 4, height: 4), inset: .zero)
                            XCTAssertEqual(actual.count, count); XCTAssertEqual(actual.rowCount, rows.count)
                            XCTAssertEqual(actual.canvas.width, expected.canvas.width, accuracy: 0.0001)
                            XCTAssertEqual(actual.canvas.height, expected.canvas.height, accuracy: 0.0001)
                            for page in 0..<count {
                                let frame = try XCTUnwrap(actual.frame(page: page)), placed = try XCTUnwrap(expected.pages[page])
                                XCTAssertEqual(frame.minX, placed.minX, accuracy: 0.0001)
                                XCTAssertEqual(frame.minY, placed.minY, accuracy: 0.0001)
                                XCTAssertEqual(frame.size, placed.size)
                            }
                            for row in rows.indices {
                                XCTAssertEqual(actual.range(row: row), rows[row])
                                let frame = try XCTUnwrap(actual.frame(page: rows[row].lowerBound))
                                XCTAssertEqual(actual.row(atY: frame.midY), row)
                            }
                        }
                    }
                }
            }
            state.spread = false; state.cover = false; state.rtl = false; state.rotation = 0
            state.landscapeAsSpread = true
            state.landscapePages = Set(0..<count)
            // Landscape grouping only affects spreads; ordinary single-column
            // scrolling retains compact geometry even with that preference on.
            _ = try await settle()
            state.send(.preservePosition(.init(page: count - 1, x: 0, y: 40)))
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if state.command.action == .none, state.page == count - 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertEqual(state.page, count - 1)
            XCTAssertEqual(state.location.y ?? -1, 40, accuracy: 1)
        }
        withExtendedLifetime(directory) {}
    }

    @MainActor
    func testDifferentFixedPageSizesRetainIndividualPlacements() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let sizes = [CGSize(width: 120, height: 160), CGSize(width: 180, height: 140)]
        for (index, size) in sizes.enumerated() {
            try writeImage(size, to: directory.url.appendingPathComponent("\(index).png"))
        }
        let pages = try Pages(directory.url, format: .comic), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: directory.url, content: .pages(pages))
        state.count = sizes.count; state.flow = "continuous"; state.fit = "actual"
        state.spread = false; state.cover = false; state.rtl = false; state.rotation = 0
        state.automaticLayout = false; state.freePan = false; state.uniformPageWidth = false
        state.trimEmptyMargins = false; state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages,
            initialBounds: CGRect(origin: .zero, size: sizes[0])))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        var placed: PageRows.Layout?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let scroll = state.readerScrollView,
               let geometry = unwrapped(field("geometry", in: scroll)),
               let payload = Mirror(reflecting: geometry).children.first,
               payload.label == "listed", let layout = payload.value as? PageRows.Layout,
               layout.pages.compactMap({ $0?.size }) == sizes {
                placed = layout; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        let actual = try XCTUnwrap(placed, state.error ?? "Mixed pages lost their individual geometry")
        let viewport = try XCTUnwrap(state.readerScrollView).contentView.bounds.size
        let expected = PageRows.layout(displaySizes: sizes, viewport: viewport, page: 0,
            continuous: true, spread: false, cover: false, rtl: false,
            spacing: CGSize(width: 4, height: 4), inset: .zero)
        XCTAssertEqual(actual.canvas, expected.canvas)
        XCTAssertEqual(actual.pages, expected.pages)
    }
}
#endif
