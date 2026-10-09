#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class PDFAnnotationPropertiesTests: XCTestCase {
    func testRectangleEditsKeepTheDesignSizeInsteadOfExpandingItByTheStroke() throws {
        var source = annotation()
        source.designRect = [12, 22, 96, 46]
        var properties = PDFAnnotationProperties(source)
        XCTAssertEqual(properties.bounds, CGRect(x: 12, y: 22, width: 96, height: 46))
        XCTAssertTrue(try properties.edits(from: source).isEmpty)
        properties.bounds.origin.x += 20
        guard case .rect(let bounds)? = try properties.edits(from: source).first else { return XCTFail("Missing rectangle edit") }
        XCTAssertEqual(bounds, CGRect(x: 32, y: 22, width: 96, height: 46))
    }

    func testPolylineEndingChangeKeepsItsVertices() throws {
        let source = annotation(type: "PolyLine", vertices: [[10, 20], [50, 35], [110, 70]])
        var properties = PDFAnnotationProperties(source)
        properties.endStyle = "ClosedArrow"
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 1)
        guard case .lineEnds(let start, let end)? = edits.first else { return XCTFail("Line endings must not replace the polyline's vertices") }
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 5)
    }

    func testUnchangedSnapshotDoesNotRewriteAppearanceOrOpenAnUndoStep() throws {
        let source = annotation(type: "Stamp", opacity: 0.4)
        var properties = PDFAnnotationProperties(source)
        XCTAssertTrue(try properties.edits(from: source).isEmpty)
        properties.contents = "Revised description"
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 1)
        guard case .contents("Revised description")? = edits.first else { return XCTFail("Only the edited text should be written") }
    }

    func testChangingBorderWidthPreservesExistingStyleAndDash() throws {
        let source = annotation()
        var properties = PDFAnnotationProperties(source)
        properties.borderWidth = 5
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 1)
        guard case .border(let width, let style, let dash)? = edits.first else { return XCTFail("Missing border edit") }
        XCTAssertEqual(width, 5); XCTAssertEqual(style, 1); XCTAssertEqual(dash, [3, 2])
    }

    func testTransparentMarkupHidesItsInkWithoutHidingAShapesFill() throws {
        let highlight = annotation(type: "Highlight")
        var properties = PDFAnnotationProperties(highlight)
        properties.color = .clear
        let edits = try properties.edits(from: highlight)
        XCTAssertEqual(edits.count, 2)
        guard case .color(nil, interior: false) = edits[0], case .opacity(0) = edits[1] else {
            return XCTFail("MuPDF's default markup color requires opacity zero for no color")
        }
        let square = annotation()
        properties = PDFAnnotationProperties(square); properties.color = .clear
        let shapeEdits = try properties.edits(from: square)
        XCTAssertEqual(shapeEdits.count, 1, "A transparent stroke must retain the shape's fill and opacity")
        guard case .color(nil, interior: false) = shapeEdits[0] else { return XCTFail("Missing transparent stroke") }
    }

    func testFreeTextStyleAndAppearanceShareTheExistingNativeSetters() throws {
        let source = annotation(type: "FreeText")
        var properties = PDFAnnotationProperties(source)
        XCTAssertEqual(properties.fontFamily, "Helvetica")
        properties.fontFamily = "Georgia"; properties.bold = true; properties.underline = true
        properties.fontSize = 18; properties.alignment = 2
        properties.fontColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 2)
        guard case .textAppearance(let font, let size, let color, let alignment) = edits[0],
              case .textStyle(let family, let style) = edits[1] else { return XCTFail("Missing native text appearance/style") }
        XCTAssertEqual(font, "Helv"); XCTAssertEqual(size, 18); XCTAssertEqual(color, SIMD3(1, 0, 0)); XCTAssertEqual(alignment, 2)
        XCTAssertEqual(family, "Georgia"); XCTAssertEqual(style, 5)
    }

    func testExistingCustomFontIsReadAndKeptWhenOnlySizeChanges() throws {
        var source = annotation(type: "FreeText")
        source.fontFamily = "Georgia"; source.fontStyle = 3
        var properties = PDFAnnotationProperties(source)
        XCTAssertEqual(properties.fontFamily, "Georgia")
        XCTAssertTrue(properties.bold); XCTAssertTrue(properties.italic); XCTAssertFalse(properties.underline)
        XCTAssertTrue(try properties.edits(from: source).isEmpty)
        properties.fontSize = 20
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 1, "The existing native appearance setter retains the custom font and style")
        guard case .textAppearance(_, let size, _, _) = edits[0] else { return XCTFail("Missing text-size edit") }
        XCTAssertEqual(size, 20)
    }

    func testMovingAndResizingLineTransformsItsEndpointsOnce() throws {
        let source = annotation(type: "Line", line: [[10, 20], [110, 70]])
        var properties = PDFAnnotationProperties(source)
        properties.bounds = CGRect(x: 30, y: 40, width: 200, height: 100)
        properties.endStyle = "ClosedArrow"
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 1)
        guard case .line(let first, let last, let start, let end) = edits[0] else { return XCTFail("Line geometry must use endpoints, not Rect") }
        XCTAssertEqual(first, CGPoint(x: 30, y: 40)); XCTAssertEqual(last, CGPoint(x: 230, y: 140))
        XCTAssertEqual(start, 0); XCTAssertEqual(end, 5)
    }

    func testPolygonUsesVerticesAndInkOnlyMovesLikeUpstream() throws {
        let polygon = annotation(type: "Polygon", vertices: [[10, 20], [110, 20], [10, 70]])
        var properties = PDFAnnotationProperties(polygon)
        properties.bounds.origin = CGPoint(x: 20, y: 40)
        let edits = try properties.edits(from: polygon)
        guard case .vertices(let points)? = edits.first else { return XCTFail("Polygon geometry must use vertices") }
        XCTAssertEqual(points, [CGPoint(x: 20, y: 40), CGPoint(x: 120, y: 40), CGPoint(x: 20, y: 90)])
        let ink = annotation(type: "Ink")
        properties = PDFAnnotationProperties(ink); properties.bounds.origin.x += 15
        guard case .move(let offset)? = try properties.edits(from: ink).first else { return XCTFail("Ink move must retain its path geometry") }
        XCTAssertEqual(offset, CGSize(width: 15, height: 0))
        properties.bounds.size.width *= 2
        XCTAssertThrowsError(try properties.edits(from: ink))
        let highlight = annotation(type: "Highlight")
        properties = PDFAnnotationProperties(highlight); properties.bounds.origin.x += 15
        XCTAssertThrowsError(try properties.edits(from: highlight), "Text markup remains anchored to its selected text")
    }

    func testMovingTextRedactionMovesCoverageQuadsInsteadOfOnlyItsRect() throws {
        let source = annotation(type: "Redact", quads: [[[10, 20], [110, 20], [10, 70], [110, 70]]])
        var properties = PDFAnnotationProperties(source)
        properties.bounds.origin = CGPoint(x: 20, y: 40)
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 1)
        guard case .quads(let quads) = edits[0], let quad = quads.first else { return XCTFail("Redaction must move its actual coverage") }
        XCTAssertEqual(quad.upperLeft, CGPoint(x: 20, y: 40))
        XCTAssertEqual(quad.lowerRight, CGPoint(x: 120, y: 90))
    }

    func testCreationPresetUsesFreeTextTextAndBackgroundSeparately() throws {
        let preset = PDFAnnotationPreset(color: 0xff0000, bgColor: .max, opacity: 40,
            textSize: 0, borderWidth: 2, alignment: "right", setContent: true)
        let edits = try PDFAnnotationProperties.edits(for: preset, type: "FreeText", selectedText: "Selection")
        XCTAssertEqual(edits.count, 5)
        guard case .contents("Selection") = edits[0],
              case .textAppearance(let font, let size, let color, let alignment) = edits[1],
              case .color(nil, interior: false) = edits[2],
              case .border(let width, _, _) = edits[3], case .opacity(let opacity) = edits[4] else { return XCTFail("Incorrect preset translation") }
        XCTAssertEqual(font, "Helv"); XCTAssertEqual(size, 12, "Upstream uses 12 points when textSize is zero")
        XCTAssertEqual(color, SIMD3(1, 0, 0)); XCTAssertEqual(alignment, 2)
        XCTAssertEqual(width, 2); XCTAssertEqual(opacity, 0.4)
        XCTAssertTrue(try PDFAnnotationProperties.edits(for: nil, type: "Text").isEmpty)
        XCTAssertTrue(try PDFAnnotationProperties.edits(for: .init(borderWidth: 4), type: "Text").isEmpty)
    }

    func testPresetOpacityOverridesColor() throws {
        let preset = PDFAnnotationPreset(color: .max, opacity: 35)
        let edits = try PDFAnnotationProperties.edits(for: preset, type: "Highlight")
        guard case .color(nil, interior: false)? = edits.first, case .opacity(let alpha)? = edits.last else { return XCTFail("Missing preset color/opacity") }
        XCTAssertEqual(alpha, 0.35)

    }

    func testColorControlsPreserveImportedColorsWithoutAUserSelection() throws {
        let source = annotation(type: "FreeText", color: [])
        let background = PDFAnnotationColorControl(.clear, allowsClear: true)
        // Display normalization is not a user edit, including transparent black.
        background.well.color = .black
        var properties = PDFAnnotationProperties(source)
        properties.color = background.color
        properties.fontSize = 18
        let edits = try properties.edits(from: source)
        XCTAssertEqual(edits.count, 1)
        guard case .textAppearance(_, 18, _, _) = edits[0] else {
            return XCTFail("Changing text size must keep the transparent background")
        }
        let text = PDFAnnotationColorControl(.black, allowsClear: false)
        text.well.color = .red
        XCTAssertEqual(text.color, .black, "Displaying a color must not select it")
    }

    func testExplicitColorSelectionAndClearUseTheNativeColorEdits() throws {
        let source = annotation()
        let control = PDFAnnotationColorControl(.blue, allowsClear: true)
        control.well.color = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.4)
        XCTAssertTrue(control.well.sendAction(control.well.action, to: control.well.target))
        var properties = PDFAnnotationProperties(source)
        properties.color = control.color
        let selected = try properties.edits(from: source)
        XCTAssertEqual(selected.count, 2)
        guard case .color(.some(let rgb), interior: false) = selected[0],
              case .opacity(let opacity) = selected[1] else { return XCTFail("Missing selected color/opacity") }
        XCTAssertEqual(rgb, .zero); XCTAssertEqual(opacity, 0.4)
        let button = try XCTUnwrap((control.view as? NSStackView)?.arrangedSubviews.last as? NSButton)
        button.performClick(nil)
        properties.color = control.color
        let cleared = try properties.edits(from: source)
        XCTAssertEqual(cleared.count, 1)
        guard case .color(nil, interior: false) = cleared[0] else { return XCTFail("Clear must remove the stroke color") }
        properties = PDFAnnotationProperties(source)
        properties.interiorColor = control.color.alphaComponent == 0 ? nil : control.color
        let fill = try properties.edits(from: source)
        XCTAssertEqual(fill.count, 1)
        guard case .color(nil, interior: true) = fill[0] else { return XCTFail("Clear must remove the fill color") }
    }

    private func annotation(type: String = "Square", opacity: Float = 1, color: [Double] = [0, 0, 1],
                            line: [[Double]] = [], vertices: [[Double]] = [], quads: [[[Double]]] = []) -> PDFAnnotationSnapshot {
        .init(id: 7, type: type, contents: "Original", author: "Author", icon: "", flags: 0,
            rect: [10, 20, 100, 50], color: color, interiorColor: [1, 0, 0], opacity: opacity,
            borderWidth: 2, borderStyle: 1, alignment: 0, dash: [3, 2], font: "Helv", fontSize: 12,
            textColor: [0, 0, 0], line: line, vertices: vertices, lineEnds: [0, 0], quads: quads, ink: [],
            fieldName: nil, fieldLabel: nil, value: nil, fieldType: nil, fieldFlags: nil,
            maxLength: nil, readOnly: nil, options: nil)
    }
}
#endif
