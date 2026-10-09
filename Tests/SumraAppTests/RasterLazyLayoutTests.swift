#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class RasterLazyLayoutTests: XCTestCase {
    @MainActor
    func testSearchingAndChoosingRasterMatchesPreservesTheUserSelection() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), state = ReaderState()
        let input = directory.url.appendingPathComponent("search-selection.html")
        let paragraphs = String(repeating: "<p>Enough ordinary text to place each match on a different reading page.</p>", count: 35)
        try """
        <html><body><div>KEPT user selection.</div>\(paragraphs)
        <p>needle first.</p>\(paragraphs)<p>needle second.</p></body></html>
        """.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .html)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.count = await pages.count; state.page = 0
        XCTAssertGreaterThan(state.count, 2, "The fixture must exercise cross-page search navigation")
        state.fontSize = 17; state.lineHeight = 1.4; state.margin = 24; state.font = "serif"; state.theme = "light"
        state.flow = "continuous"; state.fit = "width"; state.spread = false; state.automaticLayout = false
        state.reflowable = true; state.searchable = true; state.renderRevision = 1
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages)); window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: "position:" + input.standardizedFileURL.path)
            withExtendedLifetime(directory) {}
        }
        func waitFor(line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Raster search did not finish: page=\(state.page)/\(state.count), command=\(state.command.action), target=\(state.selectedSearchTarget ?? "nil"), results=\(state.searchResults.count), hasSelection=\(state.hasSelection), selectedLength=\(state.selectedText.count)", line: line)
        }
        try await waitFor { state.readerScrollView != nil }
        state.send(.selectCurrentPage)
        try await waitFor { state.hasSelection && state.selectedText.contains("KEPT") }
        let selection = state.selectedText
        state.showFindPanel(); state.send(.find("needle"))
        try await waitFor { state.searchResults.count == 2 && state.selectedSearchTarget == state.searchResults.first?.target && state.page > 0 }
        XCTAssertEqual(state.selectedText, selection)
        XCTAssertTrue(state.hasSelection)
        let last = try XCTUnwrap(state.searchResults.last?.target)
        let lastPage = try XCTUnwrap(Int(try XCTUnwrap(last.split(separator: ":").dropFirst().first)))
        XCTAssertGreaterThan(lastPage, state.page, "The next match must be on another page")
        state.navigate(.href(last))
        state.send(.none)
        try await waitFor { state.selectedSearchTarget == last && state.page == lastPage }
        XCTAssertEqual(state.selectedText, selection)
        XCTAssertTrue(state.hasSelection)
        state.closeFind(); state.send(.none)
        try await waitFor { state.command.action == .none && state.searchResults.isEmpty }
        XCTAssertEqual(state.selectedText, selection)
        XCTAssertTrue(state.hasSelection)
        state.navigateHistory(-1)
        try await waitFor { state.page == 0 }
        XCTAssertFalse(state.canNavigateBack, "Back must return to the search start, without intermediate matches")
    }

    private func comic(in directory: URL, marked: Bool = false) throws -> URL {
        let folder = directory.appendingPathComponent("Comic", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for page in 0..<5 {
            let width = page == 4 ? 200 : 100, height = page == 4 ? 100 : 200
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if marked {
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: width / 5, y: height * 3 / 10, width: width * 3 / 5, height: height * 2 / 5))
            }
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                folder.appendingPathComponent("\(page + 1).png") as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        // A later unavailable image must not prevent the first page from
        // opening. No decoder should touch it merely to size the canvas.
        try Data("unreadable image".utf8).write(to: folder.appendingPathComponent("6.png"))
        return folder
    }

    func testInitialLayoutDoesNotReadEveryComicPage() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(comic(in: directory.url), format: .comic)
        try await pages.seedImageBounds(page: 0, uniform: false)
        let count = await pages.count
        let limit = try await pages.zoomLimit(rotation: 0)
        let landscape = try await pages.landscapePages(rotation: 0)
        let first = try await pages.image(0, width: 100)
        XCTAssertEqual(count, 6)
        XCTAssertGreaterThan(limit, 0)
        XCTAssertTrue(landscape.isEmpty)
        XCTAssertEqual(first.width, 100)
        XCTAssertEqual(first.height, 200)
    }

    func testImageDirectoryReadsOnlyItsOwnEntriesAndKeepsExternalSymlinkNames() async throws {
        let directory = try TemporaryDirectory(), outside = try TemporaryDirectory()
        defer { withExtendedLifetime((directory, outside)) {} }
        let folder = try comic(in: directory.url)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("not a readable image".utf8).write(to: nested.appendingPathComponent("0.png"))
        let original = try Data(contentsOf: folder.appendingPathComponent("1.png"))
        let target = outside.url.appendingPathComponent("external.png")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("7.png"), withDestinationURL: target)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("8.png", isDirectory: true), withIntermediateDirectories: true)
        let pages = try Pages(folder, format: .comic), count = await pages.count
        XCTAssertEqual(count, 7, "Nested images and directories named like images are not pages")
        let alias = try await pages.originalData(6)
        XCTAssertEqual(alias.filename, "7.png")
        XCTAssertEqual(alias.data, original, "The entry alias must continue to resolve outside the image directory")
        let image = try await pages.image(6, width: 100)
        XCTAssertEqual(image.width, 100); XCTAssertEqual(image.height, 200)
    }

    func testImageCollectionHighZoomKeepsOriginalPixelsWithoutCreatingTiles() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(comic(in: directory.url), format: .comic)
        let high = try await pages.render(0, viewport: CGSize(width: 900, height: 700), scale: 2,
            columns: 1, rotation: 0, fit: "custom", zoom: 64, maximumZoom: 64)
        XCTAssertEqual(high.image.width, 100); XCTAssertEqual(high.image.height, 200)
        XCTAssertEqual(high.tileResolution, 0)
        XCTAssertEqual(high.display, CGSize(width: 6400, height: 12800))
    }

    func testVectorImageAndComicSVGUseTilesAtHighZoom() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("page.svg")
        try "<svg xmlns='http://www.w3.org/2000/svg' width='420' height='595'><path fill='blue' d='M0 0H420V595H0Z'/></svg>".write(to: input, atomically: true, encoding: .utf8)
        for (url, format) in [(input, Format.mupdf), (directory.url, Format.comic)] {
            let pages = try Pages(url, format: format)
            let high = try await pages.render(0, viewport: CGSize(width: 900, height: 700), scale: 2,
                columns: 1, rotation: 0, fit: "custom", zoom: 64, maximumZoom: 64)
            XCTAssertTrue(high.imageCollection)
            XCTAssertGreaterThan(high.tileResolution, 0, "SVG is vector content even when it is a comic image page")
            XCTAssertGreaterThan(high.pixelWidth, 16384)
            let tile = try await pages.image(0, width: high.pixelWidth, transparent: true,
                region: CGRect(x: 10000, y: 20000, width: 512, height: 384))
            XCTAssertEqual(tile.width, 512); XCTAssertEqual(tile.height, 384)
            let color = try XCTUnwrap(NSBitmapImageRep(cgImage: tile).colorAt(x: 256, y: 192)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.blueComponent, 0.9); XCTAssertLessThan(color.redComponent, 0.1)
        }
    }

    func testDiscoveredLandscapePageOwnsItsRowWithoutChangingPortraitEstimate() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(comic(in: directory.url), format: .comic)
        try await pages.seedImageBounds(page: 0, uniform: true)
        let estimateBefore = await pages.estimatedBounds()
        _ = try await pages.bounds(4)
        let landscape = try await pages.landscapePages(rotation: 0)
        let estimateAfter = await pages.estimatedBounds()
        XCTAssertEqual(landscape, [4])
        XCTAssertEqual(PageRows.ranges(count: 6, spread: true, landscape: landscape), [0..<2, 2..<4, 4..<5, 5..<6])
        XCTAssertEqual(PageRows.range(page: 5, count: 6, spread: true, landscape: landscape), 5..<6)
        XCTAssertEqual(estimateBefore, CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(estimateAfter, estimateBefore)
        let rotated = try await pages.landscapePages(rotation: 90)
        XCTAssertEqual(rotated, [0, 1, 2, 3])
        XCTAssertEqual(PageRows.ranges(count: 6, spread: true, landscape: rotated), [0..<1, 1..<2, 2..<3, 3..<4, 4..<6])
    }

    func testConcurrentPageRequestsReturnTheirOwnMeasuredGeometryAndImage() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(comic(in: directory.url), format: .comic)
        async let first = pages.render(0, viewport: CGSize(width: 404, height: 600), scale: 2,
            columns: 2, rotation: 0, fit: "width", zoom: 1)
        async let last = pages.render(4, viewport: CGSize(width: 404, height: 600), scale: 2,
            columns: 2, rotation: 90, fit: "custom", zoom: 1, uniform: true, transparent: true)
        let (portrait, rotated) = try await (first, last)
        XCTAssertEqual(portrait.bounds, CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(rotated.bounds, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(portrait.display, CGSize(width: 200, height: 400))
        XCTAssertEqual(rotated.display, CGSize(width: 200, height: 400))
        XCTAssertEqual(rotated.referenceWidth, 200)
        XCTAssertEqual(portrait.image.height, portrait.image.width * 2)
        XCTAssertEqual(rotated.image.width, rotated.image.height * 2)
        XCTAssertTrue(portrait.imageCollection && rotated.imageCollection)
        XCTAssertTrue(portrait.links.isEmpty && rotated.links.isEmpty)
        XCTAssertNil(portrait.content)
        XCTAssertNil(rotated.content)
        XCTAssertTrue(rotated.landscape.contains(0))
        XCTAssertFalse(rotated.landscape.contains(4))
        // Neither request may eagerly measure the deliberately invalid last page.
        let count = await pages.count
        XCTAssertEqual(count, 6)
    }

    func testPageRequestKeepsContentOverlaySeparateFromTrimAndFit() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(comic(in: directory.url, marked: true), format: .comic)
        let viewport = CGSize(width: 300, height: 600)
        let plain = try await pages.render(0, viewport: viewport, scale: 1, columns: 1,
            rotation: 0, fit: "width", zoom: 1)
        let overlay = try await pages.render(0, viewport: viewport, scale: 1, columns: 1,
            rotation: 0, fit: "width", zoom: 1, showContent: true)
        let content = try XCTUnwrap(overlay.content)
        XCTAssertEqual(overlay.bounds, plain.bounds)
        XCTAssertEqual(overlay.display, plain.display)
        XCTAssertEqual(overlay.image.width, plain.image.width)
        XCTAssertEqual(overlay.image.height, plain.image.height)
        XCTAssertGreaterThan(content.minX, 0)
        XCTAssertGreaterThan(content.minY, 0)
        XCTAssertLessThan(content.maxX, overlay.bounds.maxX)
        XCTAssertLessThan(content.maxY, overlay.bounds.maxY)
        let trimmed = try await pages.render(0, viewport: viewport, scale: 1, columns: 1,
            rotation: 0, fit: "width", zoom: 1, trim: true)
        XCTAssertEqual(trimmed.content, content)
        XCTAssertEqual(trimmed.display.width, viewport.width, accuracy: 0.01)
        XCTAssertEqual(trimmed.display.height, viewport.width * content.height / content.width, accuracy: 0.01)
        let fitted = try await pages.render(0, viewport: viewport, scale: 1, columns: 1,
            rotation: 0, fit: "visible", zoom: 1)
        XCTAssertEqual(fitted.content, content)
        let padded = content.insetBy(dx: -2, dy: -2).intersection(fitted.bounds)
        XCTAssertEqual(fitted.display.width * padded.width / fitted.bounds.width, viewport.width, accuracy: 0.01)
        XCTAssertLessThan(fitted.display.width * content.width / fitted.bounds.width, viewport.width,
                          "Fit Visible keeps the upstream two-point margin around the drawing")
    }

    func testPublisherZeroMarginsAndViewportSurviveUntilExplicitlyOverridden() throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("publisher-layout.html")
        try """
        <html><head><meta name="viewport" content="width=1188,height=1680">
        <style>@page{margin:0}html,body,p{margin:0;padding:0}</style></head>
        <body><p>Publisher page margins remain in effect.</p></body></html>
        """.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        func firstWord(margins: PageMargins?) throws -> CGRect {
            XCTAssertEqual(try file.relayout(fontSize: 17, lineHeight: 1.4,
                font: "serif", theme: "light", pageMargins: margins), 1)
            return try XCTUnwrap(file.words(0).first { !$0.bounds.isEmpty }).bounds
        }
        let publisher = try firstWord(margins: nil)
        let bounds = try XCTUnwrap(file.bounds(0))
        XCTAssertEqual(bounds.width, 1188, accuracy: 0.1)
        XCTAssertEqual(bounds.height, 1680, accuracy: 0.1)
        let explicitZero = try firstWord(margins: PageMargins(cssValues: [0]))
        XCTAssertEqual(publisher.minX, explicitZero.minX, accuracy: 0.1)
        XCTAssertEqual(publisher.minY, explicitZero.minY, accuracy: 0.1)
        let overridden = try firstWord(margins: PageMargins(cssValues: [50, 20, 30, 80]))
        XCTAssertEqual(overridden.minX - publisher.minX, 80, accuracy: 0.1)
        XCTAssertEqual(overridden.minY - publisher.minY, 50, accuracy: 0.1)
        let restored = try firstWord(margins: nil)
        XCTAssertEqual(restored.minX, publisher.minX, accuracy: 0.1)
        XCTAssertEqual(restored.minY, publisher.minY, accuracy: 0.1)
    }

    func testReflowZoomLimitUsesEstimatesUntilPublisherPagesAreMeasured() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("large-viewport.html")
        // A large logical viewport exposes the canvas limit without allocating
        // a large bitmap. This is the same meta viewport used by fixed EPUBs.
        try """
        <html><head><meta name="viewport" content="width=100000,height=200000">
        <style>@page{margin:0}body{margin:0}p{page-break-before:always}</style></head>
        <body><div>First page.</div><p>Second page.</p></body></html>
        """.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .mupdf)
        let prepared = try await pages.prepare(), count = await pages.count
        XCTAssertTrue(prepared.reflowable)
        XCTAssertGreaterThan(count, 0)
        let estimate = await pages.estimatedBounds()
        let initial = try await pages.zoomLimit(rotation: 0, maximumZoom: ReadingZoom.absoluteMaximum)
        let stillUnmeasured = await pages.estimatedBounds()
        XCTAssertEqual(stillUnmeasured, estimate, "Computing a zoom limit must not load every reflow page")
        XCTAssertEqual(initial, ReadingZoom.documentLimit(totalHeight: Double(count) * Double(estimate.height),
            maximumWidth: Double(estimate.width), maximumZoom: ReadingZoom.absoluteMaximum), accuracy: 0.000001)
        let actual = try await pages.bounds(0)
        XCTAssertEqual(actual.size, CGSize(width: 100000, height: 200000))
        let measured = try await pages.zoomLimit(rotation: 0, maximumZoom: ReadingZoom.absoluteMaximum)
        XCTAssertLessThan(measured, initial)
        XCTAssertEqual(measured, ReadingZoom.documentLimit(totalHeight: Double(count) * Double(actual.height),
            maximumWidth: Double(actual.width), maximumZoom: ReadingZoom.absoluteMaximum), accuracy: 0.000001)
        let rotated = try await pages.zoomLimit(rotation: 90, maximumZoom: ReadingZoom.absoluteMaximum, uniform: true)
        XCTAssertEqual(rotated, ReadingZoom.documentLimit(totalHeight: Double(count) * Double(actual.width),
            maximumWidth: Double(actual.height), maximumZoom: ReadingZoom.absoluteMaximum), accuracy: 0.000001)
    }

    private func epubFixture(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        // Same small ZIP/OPF fixture shape as the direction test, with a later
        // fragment whose page changes when the typography changes.
        let paragraphs = String(repeating: "<p>A paragraph keeps this chapter long enough to exercise font reflow.</p>", count: 100)
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='chapter' href='chapter.xhtml' media-type='application/xhtml+xml'/><item id='ncx' href='toc.ncx' media-type='application/x-dtbncx+xml'/></manifest><spine toc='ncx'><itemref idref='chapter'/></spine></package>",
            "chapter.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><h1 id='start'>Start</h1>\(paragraphs)<h1 id='later'>Later</h1><p>End</p></body></html>",
            "toc.ncx": "<ncx xmlns='http://www.daisy.org/z3986/2005/ncx/'><navMap><navPoint id='a'><navLabel><text>Start</text></navLabel><content src='chapter.xhtml#start'/></navPoint><navPoint id='b'><navLabel><text>Later</text></navLabel><content src='chapter.xhtml#later'/></navPoint></navMap></ncx>"
        ]
        for (name, text) in files { try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip); XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("book.epub")
    }

    func testDeferredBookUsesItsFirstReaderStyleBeforeCountingAndResolvingContents() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try epubFixture(in: directory.url)
        let deferred = try ReadingDocument.open(input, deferReflowLayout: true)
        let eager = try ReadingDocument.open(input)
        guard case .pages(let pages) = deferred.content, case .pages(let reference) = eager.content else {
            return XCTFail("EPUB must use the native page reader")
        }
        let pending = await pages.count, initialEager = await reference.count
        XCTAssertEqual(pending, 0, "Deferred layout must not invent a page count")
        XCTAssertGreaterThan(initialEager, 0, "CLI and thumbnail callers still open with a usable page count")
        let laidOut = try await pages.relayout(fontSize: 30, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        _ = try await reference.relayout(fontSize: 30, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        let count = await pages.count, referenceCount = await reference.count
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(laidOut, count)
        XCTAssertEqual(count, referenceCount)
        let prepared = try await pages.prepare()
        XCTAssertEqual(prepared.outline.count, 2)
        var destinations = [ReadingPosition]()
        for item in prepared.outline {
            let actual = try await pages.resolve(item.target), expected = try await reference.resolve(item.target)
            XCTAssertEqual(actual, expected)
            destinations.append(try XCTUnwrap(actual))
        }
        XCTAssertEqual(destinations.first?.page, 0)
        XCTAssertGreaterThan(try XCTUnwrap(destinations.last?.page), 0)
        let unchanged = try await pages.relayout(fontSize: 30, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        XCTAssertNil(unchanged, "Preparing the reader again must reuse its applied style")
    }

    func testScrollingKeepsThePageAnchorButReflowRefreshesItsChapterPageCount() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(epubFixture(in: directory.url), format: .mupdf)
        _ = try await pages.relayout(fontSize: 11, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        let smallCount = await pages.count
        let first = try await pages.position(page: 0, x: 0, y: 0)
        let scrolled = try await pages.position(page: 0, x: 10, y: 120)
        XCTAssertNotNil(first.anchor)
        XCTAssertEqual(scrolled.anchor, first.anchor)
        XCTAssertEqual(scrolled.x, 10)
        XCTAssertEqual(scrolled.y, 120)
        let next = try await pages.position(page: 1)
        XCTAssertNotEqual(next.anchor, first.anchor)
        _ = try await pages.position(page: 0)
        _ = try await pages.relayout(fontSize: 30, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        let largeCount = await pages.count
        let reflowed = try await pages.position(page: 0, x: 5, y: 60)
        XCTAssertGreaterThan(largeCount, smallCount)
        XCTAssertNotEqual(reflowed.anchor, first.anchor)
        // This fixture has one chapter, so its anchor's page count is the book count.
        let anchor = try XCTUnwrap(reflowed.anchor)
        XCTAssertEqual(anchor.split(separator: ":").last.map { String($0) }, String(largeCount))
        let restored = try await pages.restore(reflowed)
        XCTAssertEqual(restored, reflowed)
    }

    func testMarkdownOutlineCarriesLaidOutDestinationsAndRefreshesAfterReflow() throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Outline.md")
        let paragraphs = String(repeating: "A paragraph separates the headings so their destinations change with the reading font.\n\n", count: 60)
        try "# AlphaMark\n\n\(paragraphs)## BetaMark\n\n\(paragraphs)# GammaMark\n".write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 13, lineHeight: 1.4, font: "serif", theme: "light")
        let before = try file.outline()
        XCTAssertEqual(before.map(\.title), ["AlphaMark", "BetaMark", "GammaMark"])
        XCTAssertEqual(before.map(\.depth), [0, 1, 0])
        func checkDestinations(_ outline: [ContentsItem]) throws {
            for item in outline {
                let page = try XCTUnwrap(item.page, "MuPDF already resolved each Markdown heading during layout")
                let pageCharacters = try XCTUnwrap(file.text(page)).filter { !$0.isWhitespace }
                let headingCharacters = item.title.filter { !$0.isWhitespace }
                XCTAssertTrue(pageCharacters.contains(headingCharacters),
                    "The supplied page must contain every heading character across long-word line breaks")
                let destination = try XCTUnwrap(file.resolve(item.target))
                XCTAssertEqual(destination.page, page)
                XCTAssertNotNil(destination.x)
                XCTAssertNotNil(destination.y)
            }
        }
        try checkDestinations(before)
        let oldLastPage = try XCTUnwrap(before.last?.page)
        _ = try file.relayout(fontSize: 30, lineHeight: 1.4, font: "serif", theme: "light")
        let after = try file.outline()
        XCTAssertEqual(after.map(\.target), before.map(\.target))
        XCTAssertGreaterThan(try XCTUnwrap(after.last?.page), oldLastPage)
        try checkDestinations(after)
    }

    @MainActor
    func testOutlinePageNumbersFollowFontReflowInTheReader() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = try epubFixture(in: directory.url), pages = try Pages(input, format: .mupdf)
        _ = try await pages.relayout(fontSize: 11, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        let prepared = try await pages.prepare(), state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.count = await pages.count; state.outline = prepared.outline
        state.fontSize = 11; state.lineHeight = 1.4; state.margin = 24; state.font = "serif"; state.theme = "light"
        state.flow = "paged"; state.spread = false; state.automaticLayout = false; state.renderRevision = 1
        state.reflowable = true; state.searchable = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages)); window.contentView = host
        addTeardownBlock { @MainActor in
            window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: "position:" + input.standardizedFileURL.path)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ ready: () -> Bool) async throws {
            for _ in 0..<150 {
                host.layoutSubtreeIfNeeded()
                if ready() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("Reader did not finish resolving the reflowed outline")
        }
        try await waitFor { !state.outlineBusy && state.outline.count == 2 && state.outline.allSatisfy { $0.page != nil } }
        let before = try XCTUnwrap(state.outline.last?.page), target = try XCTUnwrap(state.outline.last?.target)
        let firstDestination = try await pages.resolve(target)
        XCTAssertEqual(before, firstDestination?.page)
        let revision = state.renderRevision
        state.fontSize = 30; state.send(.style)
        try await waitFor { state.renderRevision > revision && !state.outlineBusy && (state.outline.last?.page ?? -1) > before }
        let after = try XCTUnwrap(state.outline.last?.page), actual = try await pages.resolve(target)
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(after, actual?.page)
    }
}
#endif
