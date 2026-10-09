#if os(macOS)
import AppKit
import CoreText
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class NativePDFAnnotationPlacementTests: XCTestCase {
    func testSuccessiveEraserGesturesReadTheRemainingLiveStrokes() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("ink.pdf")
        defer { withExtendedLifetime(directory) {} }
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: input)
        let pages = try Pages(input, format: .pdf)
        try await pages.pdfSetEditing(true)
        let strokes = [20.0, 60.0, 100.0].map { y in [CGPoint(x: 10, y: y), CGPoint(x: 50, y: y)] }
        let id = try await pages.pdfCreateAnnotation(page: 0, type: "Ink", bounds: box,
            edits: [.ink(strokes), .border(width: 1, style: 0, dash: [])])
        let first = try await pages.pdfEraseInk(page: 0, points: [CGPoint(x: 25, y: 20)], radius: 3)
        let second = try await pages.pdfEraseInk(page: 0, points: [CGPoint(x: 25, y: 60)], radius: 3)
        XCTAssertTrue(first); XCTAssertTrue(second)
        let remaining = try await pages.pdfAnnotations(0)
        let ink = try XCTUnwrap(remaining.first(where: { $0.id == id }))
        XCTAssertEqual(ink.ink, [[[10, 100], [50, 100]]], "The second gesture must not put the first erased stroke back")
        let before = try await pages.pdfInfo()
        let missed = try await pages.pdfEraseInk(page: 0, points: [CGPoint(x: 150, y: 150)], radius: 3)
        let after = try await pages.pdfInfo()
        XCTAssertFalse(missed); XCTAssertEqual(before?.undoPosition, after?.undoPosition)
        try await pages.pdfUndo()
        let undone = try await pages.pdfAnnotations(0)
        XCTAssertEqual(try XCTUnwrap(undone.first(where: { $0.id == id })).ink.count, 2)
    }

    func testSlantedNativeTextSelectionRetainsItsActualFourCorners() throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("slanted.pdf")
        let bytes = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.translateBy(x: 70, y: 100); context.rotate(by: .pi / 6)
        let text = NSAttributedString(string: "Slanted", attributes: [.font: try XCTUnwrap(NSFont(name: "Helvetica", size: 24))])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        try (bytes as Data).write(to: input)
        let native = try NativeFile(input, engine: .mupdf)
        let words = try native.words(0).filter { !$0.bounds.isEmpty }
        let first = try XCTUnwrap(words.first).bounds, last = try XCTUnwrap(words.last).bounds
        let selection = try native.selection(0, from: CGPoint(x: first.midX, y: first.midY),
            to: CGPoint(x: last.midX, y: last.midY), mode: 1)
        XCTAssertEqual(selection.text.trimmingCharacters(in: .whitespacesAndNewlines), "Slanted")
        let quads = try XCTUnwrap(selection.quads)
        XCTAssertEqual(quads.count, selection.rects.count)
        let quad = try XCTUnwrap(quads.first)
        XCTAssertEqual(quad.count, 4)
        guard quad.count == 4, quad.allSatisfy({ $0.count == 2 }) else { return XCTFail("Missing selection corners") }
        XCTAssertGreaterThan(abs(quad[1][1] - quad[0][1]), 1, "The top edge must retain the text's slope")
        XCTAssertGreaterThan(abs(quad[2][0] - quad[0][0]), 1, "The side edge must retain the text's slope")
        let x = quad.map { $0[0] }, y = quad.map { $0[1] }, rect = try XCTUnwrap(selection.bounds.first)
        XCTAssertEqual(Double(rect.minX), try XCTUnwrap(x.min()), accuracy: 0.001)
        XCTAssertEqual(Double(rect.maxX), try XCTUnwrap(x.max()), accuracy: 0.001)
        XCTAssertEqual(Double(rect.minY), try XCTUnwrap(y.min()), accuracy: 0.001)
        XCTAssertEqual(Double(rect.maxY), try XCTUnwrap(y.max()), accuracy: 0.001)
        withExtendedLifetime(directory) {}
    }

    func testSelectionFromAnEngineWithoutQuadsKeepsItsExistingRectangle() throws {
        let data = Data(#"{"text":"word","rects":[[10,20,30,40]]}"#.utf8)
        let selection = try JSONDecoder().decode(RasterSelection.self, from: data)
        XCTAssertNil(selection.quads)
        XCTAssertEqual(selection.bounds, [CGRect(x: 10, y: 20, width: 30, height: 40)])
    }

    func testCaretAnchorsItsLeftMiddleInFitzPageCoordinates() throws {
        let tool = NativePDFAnnotationTool("caret", type: "Caret")
        tool.size = CGSize(width: 18, height: 15)
        tool.page = 2; tool.end = CGPoint(x: 100, y: 80)
        let creation = try XCTUnwrap(tool.creation(scale: 1))
        XCTAssertEqual(creation.page, 2); XCTAssertEqual(creation.type, "Caret")
        XCTAssertEqual(creation.bounds, CGRect(x: 100, y: 72.5, width: 18, height: 15))
        XCTAssertTrue(creation.edits.isEmpty)
    }

    func testPointPlacementUsesPreviewSizeWithoutFlippingPageY() throws {
        let tool = NativePDFAnnotationTool("stamp", type: "Stamp")
        tool.size = CGSize(width: 190, height: 50)
        tool.page = 0; tool.end = CGPoint(x: -10, y: 35)
        let creation = try XCTUnwrap(tool.creation(scale: 2))
        XCTAssertEqual(creation.bounds, CGRect(x: -10, y: 35, width: 190, height: 50))
        tool.clearPreview()
        XCTAssertNil(tool.creation(scale: 2))
    }

    func testReverseRectangleDragNormalizesBoundsAndShiftMakesSquare() throws {
        let tool = NativePDFAnnotationTool("square", type: "Square")
        tool.page = 0; tool.points = [CGPoint(x: 30, y: 20)]
        tool.end = CGPoint(x: 10, y: -5)
        XCTAssertEqual(try XCTUnwrap(tool.creation(scale: 1)).bounds, CGRect(x: 10, y: -5, width: 20, height: 25))
        let constrained = tool.constrained(CGPoint(x: 10, y: 15), shift: true)
        XCTAssertEqual(constrained, CGPoint(x: 10, y: 0))
        tool.end = constrained
        let square = try XCTUnwrap(tool.creation(scale: 1))
        XCTAssertEqual(square.bounds.width, square.bounds.height)
    }

    func testLineRetainsDirectionAndUsesVisualMinimumLength() throws {
        let tool = NativePDFAnnotationTool("line", type: "Line")
        tool.page = 0; tool.points = [CGPoint(x: 90, y: 10)]; tool.end = CGPoint(x: 10, y: 90)
        let creation = try XCTUnwrap(tool.creation(scale: 1))
        guard case .line(let first, let last, let start, let end)? = creation.edits.last else { return XCTFail("Missing line endpoints") }
        XCTAssertEqual(first, CGPoint(x: 90, y: 10)); XCTAssertEqual(last, CGPoint(x: 10, y: 90))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 0)
        tool.end = CGPoint(x: 91, y: 10)
        XCTAssertNil(tool.creation(scale: 1))
        XCTAssertNotNil(tool.creation(scale: 3), "Gesture size is measured on screen, not fixed PDF points")
    }

    func testShiftSnapsLineAndPolySegmentsFromTheCorrectAnchor() {
        let tool = NativePDFAnnotationTool("line", type: "Line")
        tool.points = [.zero]
        let point = tool.constrained(CGPoint(x: 10, y: 8), shift: true)
        XCTAssertEqual(point.x, point.y, accuracy: 0.0001)
        XCTAssertEqual(hypot(point.x, point.y), hypot(10, 8), accuracy: 0.0001)
        let poly = NativePDFAnnotationTool("polyline", type: "PolyLine")
        poly.points = [.zero, CGPoint(x: 100, y: 50)]
        let next = poly.constrained(CGPoint(x: 108, y: 60), shift: true)
        XCTAssertEqual(next.x - 100, next.y - 50, accuracy: 0.0001)
        XCTAssertEqual(poly.constrained(CGPoint(x: 108, y: 60), shift: false), CGPoint(x: 108, y: 60))
    }

    func testPolygonNeedsThreeVerticesAndDoesNotCommitHoverPreview() throws {
        let tool = NativePDFAnnotationTool("polygon", type: "Polygon")
        tool.page = 1; tool.points = [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 20)]
        tool.end = CGPoint(x: 80, y: 100)
        XCTAssertNil(tool.creation(scale: 1))
        tool.points.append(CGPoint(x: 25, y: 50))
        let creation = try XCTUnwrap(tool.creation(scale: 1))
        guard case .vertices(let points)? = creation.edits.last else { return XCTFail("Missing polygon vertices") }
        XCTAssertEqual(points, tool.points)
        XCTAssertFalse(points.contains(CGPoint(x: 80, y: 100)), "A hover segment is not a committed vertex")
    }

    func testInkKeepsTheCompletedStrokeAndItsCreationProperties() throws {
        let tool = NativePDFAnnotationTool("ink", type: "Ink", preset: .init(borderWidth: 4))
        tool.page = 0; tool.points = [CGPoint(x: 10, y: 20)]; tool.end = tool.points.last
        tool.edits = [.border(width: 4, style: 0, dash: [])]
        let dot = try XCTUnwrap(tool.creation(scale: 1))
        guard case .ink(let dotStrokes)? = dot.edits.last else { return XCTFail("Missing ink dot") }
        XCTAssertEqual(dotStrokes, [[CGPoint(x: 10, y: 20)]], "A pen click remains one point; MuPDF draws its round cap")
        tool.points += [CGPoint(x: 12, y: 28), CGPoint(x: 30, y: 14)]
        tool.end = tool.points.last
        let creation = try XCTUnwrap(tool.creation(scale: 1))
        XCTAssertEqual(creation.edits.count, 2)
        guard case .ink(let strokes)? = creation.edits.last else { return XCTFail("Missing ink stroke") }
        XCTAssertEqual(strokes, [tool.points])
        tool.clearPreview()
        XCTAssertNil(tool.page); XCTAssertTrue(tool.points.isEmpty); XCTAssertNil(tool.end)
        XCTAssertEqual(tool.preset?.borderWidth, 4, "Finishing a stroke retains the persistent tool's preset")
        XCTAssertEqual(tool.edits.count, 1)
    }
}
#endif
