#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

final class BrowserRangeHighlightTests: XCTestCase {
    @MainActor
    func testBridgeRectanglesScaleClipAndRejectInvalidNumbers() {
        let body: [String: Any] = [
            "find": [[-1.0, -2, 8, 10], [true, 0, 10, 10], [Double.nan, 0, 10, 10],
                     [Double.infinity, 0, 10, 10], [0, 0, -1, 10], [0, 0, 10, 0],
                     [0, 0, Double.greatestFiniteMagnitude, 10], [800, 0, 2, 2],
                     [0, 0, 1], ["0", 0, 2, 2]],
            "current": Array(repeating: [0, 0, 1, 1], count: 6000),
            "speech": [[5.0, 6, 7, 8]]
        ]
        let rects = BrowserRangeHighlightView.rectangles(body, zoom: 2, size: CGSize(width: 700, height: 400))
        XCTAssertEqual(rects.find, [CGRect(x: 0, y: 0, width: 14, height: 16)])
        XCTAssertEqual(rects.current.count, 5000)
        XCTAssertEqual(rects.speech, [CGRect(x: 10, y: 12, width: 14, height: 16)])
        XCTAssertTrue(BrowserRangeHighlightView.rectangles(body, zoom: .infinity, size: CGSize(width: 700, height: 400)).isEmpty)
        XCTAssertTrue(BrowserRangeHighlightView.rectangles([:], zoom: 1, size: CGSize(width: 700, height: 400)).isEmpty)
    }

    @MainActor
    func testTransformedFrameHighlightPaintsTheQuadRatherThanItsBoundingBox() throws {
        _ = NSApplication.shared
        let view = BrowserRangeHighlightView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.rectangles = BrowserRangeHighlightView.rectangles([
            "current": [[50.0, 10, 90, 50, 50, 90, 10, 50]],
            "find": [[10.0, 10, 50, 50, 10, 50, 50, 10], [true, 10, 90, 50, 50, 90, 10, 50]],
            "speech": [[-40.0, 50, 50, -40, 140, 50, 50, 140]]
        ], zoom: 1, size: view.bounds.size)
        XCTAssertEqual(view.rectangles.current, [CGRect(x: 10, y: 10, width: 80, height: 80)])
        XCTAssertTrue(view.rectangles.find.isEmpty)
        XCTAssertEqual(view.rectangles.speech, [view.bounds])
        view.rectangles = BrowserRangeHighlightView.rectangles([
            "current": [[50.0, 10, 90, 50, 50, 90, 10, 50]]
        ], zoom: 1, size: view.bounds.size)
        let screen = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: screen)
        let scale = CGFloat(screen.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(try XCTUnwrap(screen.colorAt(x: Int(50 * scale), y: Int(50 * scale))).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(screen.colorAt(x: Int(15 * scale), y: Int(15 * scale))).alphaComponent, 0)
    }

    @MainActor
    func testScreenHighlightIsExcludedFromNativePrinting() throws {
        _ = NSApplication.shared
        let view = BrowserRangeHighlightView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.rectangles = BrowserRangeHighlightView.rectangles([
            "find": [[10.0, 10, 50, 50]], "current": [[50.0, 10, 90, 50, 50, 90, 10, 50]]
        ], zoom: 1, size: view.bounds.size)
        let screen = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: screen)
        let scale = CGFloat(screen.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(try XCTUnwrap(screen.colorAt(x: Int(20 * scale), y: Int(20 * scale))).alphaComponent, 0)
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertFalse(view.isAccessibilityElement())
        XCTAssertTrue(view.accessibilityIsIgnored())

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = view.bounds.size
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        let output = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: output, printInfo: info)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        XCTAssertTrue(operation.run())
        let provider = try XCTUnwrap(CGDataProvider(data: output as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 400, bitsPerPixel: 32))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.drawPDFPage(page)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        XCTAssertTrue((0..<10000).allSatisfy { index in
            bytes[index * 4] == 255 && bytes[index * 4 + 1] == 255 && bytes[index * 4 + 2] == 255
        }, "Screen-only highlights must not appear in printed PDF output")
    }
}
#endif
