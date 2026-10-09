import XCTest
@testable import SumraCore

final class ReadingZoomTests: XCTestCase {
    func testPerPageUniformScaleUsesReferenceWidthWithoutClampingOrViewportPolicy() {
        XCTAssertEqual(ReadingZoom.pageScale(zoom: 1.25, referenceWidth: 600, pageWidth: 300, uniform: true), 2.5)
        XCTAssertEqual(ReadingZoom.pageScale(zoom: 1.25, referenceWidth: 600, pageWidth: 300, uniform: false), 1.25)
        XCTAssertEqual(ReadingZoom.pageScale(zoom: 64, referenceWidth: 600, pageWidth: 300, uniform: true), 128)
        XCTAssertEqual(ReadingZoom.pageScale(zoom: 1, referenceWidth: 600, pageWidth: 0, uniform: true), 1)
    }
    func testDocumentMeasurementBoundsMixedPagesWithAndWithoutUniformWidths() {
        let sizes = [(width: 600.0, height: 800.0), (width: 10.0, height: 100_000.0)]
        let uniform = ReadingZoom.documentLimit(pageCount: sizes.count, uniform: true, maximumZoom: 10_000) { sizes[$0] }
        XCTAssertEqual(uniform, ReadingZoom.maximumCanvasExtent / 6_000_800, accuracy: 0.0001)
        let natural = ReadingZoom.documentLimit(pageCount: sizes.count, uniform: false, maximumZoom: 10_000) { sizes[$0] }
        XCTAssertEqual(natural, ReadingZoom.maximumCanvasExtent / 100_800, accuracy: 0.0001)
        let rotated = ReadingZoom.documentLimit(pageCount: sizes.count, uniform: true, maximumZoom: 10_000) {
            (sizes[$0].height, sizes[$0].width)
        }
        XCTAssertEqual(rotated, 10_000)
        let wide = ReadingZoom.documentLimit(pageCount: 1, uniform: false, maximumZoom: 10_000) { _ in (100_000, 10) }
        XCTAssertEqual(wide, ReadingZoom.maximumCanvasExtent / 200_000, accuracy: 0.0001)
        XCTAssertEqual(ReadingZoom.documentLimit(pageCount: 0, uniform: true) { _ in XCTFail("Empty document"); return nil }, 64)
    }
    func testCustomStopsAreSortedAndRaiseOnlyTheConfiguredMaximum() throws {
        let levels = try ReadingZoom.parseLevels("10000%, 125 75 125 1000000")
        XCTAssertEqual(levels, [0.75, 1.25, 100, 10_000])
        XCTAssertEqual(ReadingZoom.maximum(for: levels), 10_000)
        XCTAssertEqual(ReadingZoom.maximum(for: [0.75, 1.25]), 64)
        XCTAssertEqual(try ReadingZoom.parseLevels(" "), [])
        for value in ["nan", "-1", "1000001", "8.32", "100 bad"] { XCTAssertThrowsError(try ReadingZoom.parseLevels(value)) }
        XCTAssertEqual(ReadingZoom.nextStep(from: 1.25, direction: 1, limit: 10_000, levels: levels).zoom, 100)
        XCTAssertEqual(ReadingZoom.nextStep(from: 80, direction: -1, limit: 10_000, levels: levels).zoom, 1.25)
        XCTAssertEqual(try ReadingZoom.parsePercent("1000000", limit: 10_000), 10_000)
        XCTAssertThrowsError(try ReadingZoom.parsePercent("1000000"))
    }
    func testPercentageIncrementPrecedesFixedAndFitStopsAndKeepsDirection() {
        let up = ReadingZoom.nextStep(from: 1, direction: 1, pageFit: 1.1, widthFit: 1.2, increment: 50)
        XCTAssertEqual(up.zoom, 1.5); XCTAssertNil(up.fit)
        XCTAssertEqual(ReadingZoom.nextStep(from: 1.5, direction: -1, increment: 50).zoom, 1)
        XCTAssertEqual(ReadingZoom.nextStep(from: 1.5, direction: 1, limit: 1.6, increment: 50).zoom, 1.6)
        XCTAssertEqual(ReadingZoom.nextStep(from: 0.04, direction: -1, increment: 50).zoom, 0.04)
        XCTAssertEqual(ReadingZoom.nextStep(from: 1, direction: 1, increment: 0).zoom, 1.25)
    }
    func testLargeConfiguredZoomStillFitsTheDocumentCanvas() {
        let limit = ReadingZoom.documentLimit(totalHeight: 100_000, maximumWidth: 600, maximumZoom: 10_000)
        XCTAssertGreaterThan(limit, ReadingZoom.maximum)
        XCTAssertLessThan(limit, ReadingZoom.absoluteMaximum)
        XCTAssertLessThanOrEqual(100_000 * ReadingZoom.clamp(10_000, limit: limit), ReadingZoom.maximumCanvasExtent)
        XCTAssertEqual(ReadingZoom.clamp(100, limit: 10_000), 100)
        XCTAssertEqual(ReadingZoom.documentLimit(totalHeight: 600, maximumWidth: 400), 64)
        let tall = ReadingZoom.documentLimit(totalHeight: 20_000_000, maximumWidth: 600)
        XCTAssertLessThan(tall, ReadingZoom.maximum)
        XCTAssertLessThanOrEqual(20_000_000 * ReadingZoom.clamp(64, limit: tall), ReadingZoom.maximumCanvasExtent)
    }
    func testZoomStepsIncludeCurrentPageFitsAndRespectDirectionAndDocumentLimit() {
        XCTAssertEqual(ReadingZoom.nextStep(from: 1, direction: 1).zoom, 1.25)
        XCTAssertEqual(ReadingZoom.nextStep(from: 1, direction: -1).zoom, 0.75)
        let step = ReadingZoom.nextStep(from: 1, direction: 1, pageFit: 1.1, widthFit: 1.2)
        XCTAssertEqual(step.zoom, 1.1); XCTAssertEqual(step.fit, "page")
        let smaller = ReadingZoom.nextStep(from: 1.15, direction: -1, pageFit: 1.1, widthFit: 1.2)
        XCTAssertEqual(smaller.zoom, 1.1); XCTAssertEqual(smaller.fit, "page")
        let larger = ReadingZoom.nextStep(from: 1.15, direction: 1, pageFit: 1.1, widthFit: 1.2)
        XCTAssertEqual(larger.zoom, 1.2); XCTAssertEqual(larger.fit, "width")
        XCTAssertEqual(ReadingZoom.nextStep(from: 1.5, direction: 1, limit: 1.6).zoom, 1.6)
        XCTAssertEqual(ReadingZoom.nextStep(from: 0.04, direction: -1).zoom, 0.04)
    }
}
