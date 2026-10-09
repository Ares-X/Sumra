#if os(macOS)
import AppKit
import ImageIO
import PDFKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderPreviewExportTests: XCTestCase {
    @MainActor
    func testThumbnailFollowsItsPageWhenEarlierChapterCountsChange() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before chapter preview tests") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = try epub(in: directory.url)
        let original = try Data(contentsOf: input)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 0, font: "serif", theme: "light")
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
            "first.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><div style='height:300pt;background:#ff0000'>First</div><div style='page-break-before:always;height:300pt;background:#ff0000'>Second</div></body></html>",
            "second.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><div style='height:300pt;background:#0000ff'>Last chapter</div></body></html>"
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
