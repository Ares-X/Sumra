#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class PagesPDFDisplayTests: XCTestCase {
    func testPreviewTilesAndPlainOutputDoNotShareDifferentColorStyles() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("page.pdf")
        try fixture().write(to: source)
        defer { withExtendedLifetime(directory) {} }
        let original = try Data(contentsOf: source), pages = try Pages(source, format: .pdf)
        let style = PDFColors.Style(mode: .smart, text: 0xffffff, background: 0)
        let plain = try await pages.image(0, width: 200)
        let dark = try await pages.image(0, width: 200, pdfStyle: style)
        XCTAssertEqual(try pixel(plain, 2, 2), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(dark, 2, 2), [0, 0, 0, 255])
        let cachedPlain = try await pages.image(0, width: 200)
        XCTAssertEqual(try pixel(cachedPlain, 2, 2), try pixel(plain, 2, 2))

        let rendered = try await pages.render(0, viewport: CGSize(width: 200, height: 100), scale: 2,
            columns: 1, rotation: 0, fit: "custom", zoom: 4, pdfStyle: style,
            maximumTileSize: CGSize(width: 200, height: 100))
        XCTAssertGreaterThan(rendered.tileResolution, 0)
        XCTAssertEqual(try pixel(rendered.image, 2, 2), [0, 0, 0, 255])
        let tile = try await pages.image(PageLocation(page: 0), width: rendered.pixelWidth,
            region: CGRect(x: 0, y: 0, width: 40, height: 40), pdfStyle: rendered.pdfStyle)
        XCTAssertEqual(try pixel(tile, 2, 2), [0, 0, 0, 255])
        let hover = try await pages.previewImage("#page=1", from: 0, pdfStyle: rendered.pdfStyle)
        XCTAssertEqual(try pixel(XCTUnwrap(hover), 2, 2), [0, 0, 0, 255])

        let exported = try await pages.pdfRenderedImage(page: 0, dpi: 72, type: .png, rotation: 0)
        let exportedImage = try XCTUnwrap(NSBitmapImageRep(data: exported)?.cgImage)
        XCTAssertEqual(try pixel(exportedImage, 2, 2), [255, 255, 255, 255])
        let info = try await pages.pdfInfo()
        XCTAssertEqual(info?.dirty, false)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testColoredPreviewInvalidatesOnLiveEditAndUndo() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("page.pdf")
        try fixture().write(to: source)
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(source, format: .pdf)
        let style = PDFColors.Style(mode: .legacy, text: 0xffffff, background: 0)
        let before = try await pages.image(0, width: 200, pdfStyle: style)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 20, y: 20, width: 40, height: 40),
            edits: [.color(SIMD3(0, 0, 1), interior: true)])
        let edited = try await pages.image(0, width: 200, pdfStyle: style)
        XCTAssertNotEqual(try pixel(before, 40, 40), try pixel(edited, 40, 40))
        try await pages.pdfUndo()
        let undone = try await pages.image(0, width: 200, pdfStyle: style)
        XCTAssertEqual(try pixel(undone, 40, 40), try pixel(before, 40, 40))
    }

    func testAutoEngineeringUsesTheLiveDocumentAndCanBeTurnedOff() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("cad.pdf")
        try fixture(creator: "AutoCAD").write(to: source)
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(source, format: .pdf)
        let automatic = try await pages.render(0, viewport: CGSize(width: 200, height: 100), scale: 1,
            columns: 1, rotation: 0, fit: "page", zoom: 1, pdfStyle: .init(), engineeringAuto: true)
        XCTAssertEqual(automatic.pdfStyle?.engineering, true)
        let disabled = try await pages.render(0, viewport: CGSize(width: 200, height: 100), scale: 1,
            columns: 1, rotation: 0, fit: "page", zoom: 1, pdfStyle: .init())
        XCTAssertNil(disabled.pdfStyle)
        let info = try await pages.pdfInfo()
        XCTAssertEqual(info?.dirty, false)
    }

    private func requireEngine() throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF engine must be built before native integration tests")
        }
    }
    private func fixture(creator: String = "Sumra fixture") throws -> Data {
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds,
            [kCGPDFContextCreator as String: creator] as CFDictionary))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.endPDFPage(); context.closePDF()
        return data as Data
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
    }
}
#endif
