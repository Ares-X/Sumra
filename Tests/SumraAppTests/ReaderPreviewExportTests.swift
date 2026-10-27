#if os(macOS)
import AppKit
import ImageIO
import PDFKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderPreviewExportTests: XCTestCase {
    func testNaturalChapterPreviewsHaveBoundedPixelsAcrossAllRotations() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF is required") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let paragraphs = (0..<300).map { "Paragraph \($0). " + String(repeating: "Readable preview text. ", count: 8) }
        for format in [Format.html, .markdown] {
            let input = directory.url.appendingPathComponent(format == .html ? "long.html" : "long.md")
            let source = format == .html ? "<html><body>" + paragraphs.map { "<p>\($0)</p>" }.joined() + "</body></html>"
                : paragraphs.joined(separator: "\n\n")
            try source.write(to: input, atomically: true, encoding: .utf8)
            let original = try Data(contentsOf: input)
            let pages = try Pages(input, format: format)
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 20, font: "serif", theme: "light",
                                         pageSize: CGSize(width: 480, height: 0))
            let location = PageLocation(page: 0), bounds = try await pages.bounds(location)
            XCTAssertGreaterThan(bounds.height, 10_000)
            let revision = await pages.layoutRevision, table = await pages.chapterLayout
            for rotation in [0, 90, 180, 270] {
                let start = ContinuousClock.now
                let image = try await pages.previewImage(location, size: CGSize(width: 128, height: 160), rotation: rotation)
                print("PREVIEW \(format) rotation=\(rotation) pixels=\(image.width)x\(image.height) bytes=\(image.bytesPerRow * image.height) elapsed=\(start.duration(to: .now))")
                XCTAssertLessThanOrEqual(image.width, 128)
                XCTAssertLessThanOrEqual(image.height, 160)
                XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, 128 * 160 * 4)
            }
            let finalRevision = await pages.layoutRevision, finalTable = await pages.chapterLayout
            XCTAssertEqual(finalRevision, revision)
            XCTAssertEqual(finalTable.totalPages, table.totalPages)
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testNaturalLinkPreviewShowsItsDestinationWithoutRenderingTheWholeChapter() async throws {
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("link.html")
        defer { withExtendedLifetime(directory) {} }
        let paragraphs = String(repeating: "<p>Ordinary text before the destination with enough content for continuous scrolling.</p>", count: 250)
        try ("<html><body><a href='#destination'>Target</a>" + paragraphs +
             "<div id='destination' style='height:500pt;background-color:#ff0000!important'>Preview destination</div>" + paragraphs + "</body></html>")
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .html)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 0, font: "serif", theme: "light",
                                     userCSS: "#destination{background-color:#ff0000!important}",
                                     pageSize: CGSize(width: 480, height: 0))
        let links = try await pages.links(0)
        let href = try XCTUnwrap(links.first?.uri)
        let destination = try await pages.resolve(href)
        XCTAssertGreaterThan(try XCTUnwrap(destination?.y), 10_000)
        let before = await pages.layoutPosition
        let start = ContinuousClock.now
        let rendered = try await pages.previewImage(href, from: 0)
        let image = try XCTUnwrap(rendered)
        print("LINK_PREVIEW pixels=\(image.width)x\(image.height) bytes=\(image.bytesPerRow * image.height) elapsed=\(start.duration(to: .now))")
        XCTAssertLessThanOrEqual(image.width, 640)
        XCTAssertLessThanOrEqual(image.height, 880)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(bitmap.colorAt(x: image.width / 2, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, color.greenComponent + 0.5,
                             "The preview must show the red link destination rather than the white chapter start")
        XCTAssertGreaterThan(color.redComponent, color.blueComponent + 0.5)
        let after = await pages.layoutPosition
        XCTAssertEqual(after.page, before.page); XCTAssertEqual(after.y, before.y)
    }

    @MainActor
    func testFinitePagePreviewKeepsTheWholePageAndViewerRotation() async throws {
        let reading = try nativePDFReadingFixture()
        guard case .pages(let pages) = reading.content else { return XCTFail("Expected native PDF") }
        for rotation in [0, 90, 180, 270] {
            let image = try await pages.previewImage(PageLocation(page: 0), size: CGSize(width: 128, height: 160), rotation: rotation)
            let raw = try await pages.image(0, width: rotation % 180 == 0 ? 128 : 160)
            let expected = try RasterLayout.image(raw, bounds: CGRect(x: 0, y: 0, width: raw.width, height: raw.height), crop: nil, rotation: rotation)
            XCTAssertEqual(image.width, expected.width); XCTAssertEqual(image.height, expected.height)
            XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, try XCTUnwrap(expected.dataProvider?.data) as Data)
        }
    }

    @MainActor
    func testThumbnailFollowsItsPageWhenEarlierChapterCountsChange() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before chapter preview tests") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = try epub(in: directory.url)
        let original = try Data(contentsOf: input)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 0, font: "serif", theme: "light",
                                     userCSS: ".red{background-color:#ff0000!important}.blue{background-color:#0000ff!important}")
        _ = try await pages.text(PageLocation(chapter: 1, page: 0))
        let initial = await pages.chapterLayout
        XCTAssertFalse(initial.isLaidOut(0))
        XCTAssertEqual(initial.location(page: 1), PageLocation(chapter: 1, page: 0))

        let state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.rotation = 0
        state.applyChapterLayout(initial)
        let host = NSHostingView(rootView: ReaderPagePreview(state: state, index: 1).frame(width: 128, height: 160))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 128, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            window.contentView = nil; window.close(); state.document = nil
            UserDefaults.standard.removeObject(forKey: "position:" + input.standardizedFileURL.path)
            withExtendedLifetime(directory) {}
        }
        func waitForColor(red: Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    var redPixels = 0, bluePixels = 0
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            if color.redComponent > color.blueComponent + 0.5 { redPixels += 1 }
                            if color.blueComponent > color.redComponent + 0.5 { bluePixels += 1 }
                        }
                    }
                    if red ? redPixels > 5 && bluePixels == 0 : bluePixels > 5 && redPixels == 0 { return }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            XCTFail("The thumbnail did not show the current flat page's \(red ? "red" : "blue") chapter", line: line)
        }
        try await waitForColor(red: false)
        _ = try await pages.text(PageLocation(chapter: 0, page: 0))
        let published = await pages.chapterLayout
        XCTAssertGreaterThan(published.pageCount(0), 1)
        XCTAssertTrue(state.applyChapterLayout(published))
        XCTAssertEqual(state.pageLocation(1), PageLocation(chapter: 0, page: 1))
        try await waitForColor(red: true)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    @MainActor
    func testPDFImageExportAddsViewerRotationWithoutChangingSavedRotation() async throws {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 120, height: 80)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data)), page = try XCTUnwrap(document.page(at: 0))
        // Intrinsic rotation belongs to the PDF; viewer rotation stays in state.
        page.rotation = 90
        let reading = try nativePDFReadingFixture(document), state = ReaderState(recordsHistory: false)
        state.document = reading; state.rotation = 90
        defer { state.windowClosed() }
        let pages = try XCTUnwrap(state.nativePDF)
        let data = try await pages.pdfRenderedImage(page: 0, dpi: 72, type: .png, rotation: state.rotation)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 80)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let left = try XCTUnwrap(bitmap.colorAt(x: 20, y: 40)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(bitmap.colorAt(x: 100, y: 40)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.blueComponent, 0.9); XCTAssertLessThan(left.redComponent, 0.1)
        XCTAssertGreaterThan(right.redComponent, 0.9); XCTAssertLessThan(right.blueComponent, 0.1)
        XCTAssertEqual(state.rotation, 90, "Export must not change the live reading orientation")
        let output = reading.url.deletingLastPathComponent().appendingPathComponent("saved.pdf")
        try await pages.pdfSaveCopy(to: output)
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.rotation, 90, "Viewer rotation must not enter saved PDF page dictionaries")
        let unrotated = try await pages.pdfRenderedImage(page: 0, dpi: 72, type: .png, rotation: 0)
        let savedSource = try XCTUnwrap(CGImageSourceCreateWithData(unrotated as CFData, nil))
        let savedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(savedSource, 0, nil))
        XCTAssertEqual(savedImage.width, 80); XCTAssertEqual(savedImage.height, 120)
    }

    private func epub(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='a' href='first.xhtml' media-type='application/xhtml+xml'/><item id='b' href='second.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>",
            "first.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><div class='red' style='height:300pt'>First</div><div class='red' style='page-break-before:always;height:300pt'>Second</div></body></html>",
            "second.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><div class='blue' style='height:300pt'>Last chapter</div></body></html>"
        ]
        for (name, text) in files { try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("book.epub")
    }
}
#endif
