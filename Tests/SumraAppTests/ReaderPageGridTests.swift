#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

final class ReaderPageGridTests: XCTestCase {
    func testGridAlignmentKeepsOriginalOriginAcrossCropping() {
        XCTAssertEqual(ReaderPageGrid.locations(from: 11, through: 45, origin: -2, step: 9), [7, 16, 25, 34, 43])
        XCTAssertEqual(ReaderPageGrid.locations(from: -15, through: 15, origin: 0, step: 10), [-20, -10, 0, 10])
        XCTAssertEqual(ReaderPageGrid.locations(from: 0, through: 20, origin: 0, step: 0), [])
    }
    @MainActor
    func testMeasurementGridFollowsRotationAndClipsWithoutMovingTheOrigin() throws {
        let state = ReaderState()
        state.showPageGrid = true; state.pageGridWidth = 20; state.pageGridHeight = 30
        state.pageGridSubdivisions = 1; state.pageGridOffsetX = 0; state.pageGridOffsetY = 0
        state.pageGridStyle = "solid"; state.pageGridColor = 0x0000ff
        let context = try bitmap(width: 100, height: 100)
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 100, ty: 0)
        ReaderPageGrid.draw(in: context, bounds: CGRect(x: 10, y: 15, width: 90, height: 85), visible: CGRect(x: 35, y: 30, width: 40, height: 40), transform: transform, state: state)
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let line = try XCTUnwrap(image.colorAt(x: 58, y: 50)?.usingColorSpace(.sRGB))
        let clipped = try XCTUnwrap(image.colorAt(x: 58, y: 80)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(line.blueComponent, 0.99); XCTAssertGreaterThan(line.alphaComponent, 0.99)
        XCTAssertEqual(clipped.alphaComponent, 0, accuracy: 0.001)
    }
    func testCheckerboardMatchesUpstreamEightPixelWhiteAndGrayCells() throws {
        let context = try bitmap(width: 16, height: 8)
        ReaderPageGrid.checkerboard(in: context, rect: CGRect(x: 0, y: 0, width: 16, height: 8))
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)).redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 12, y: 4)?.usingColorSpace(.sRGB)).redComponent, 0.8, accuracy: 0.01)
    }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
}
#endif
