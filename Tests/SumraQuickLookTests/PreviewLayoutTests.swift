import AppKit
import XCTest
@testable import SumraQuickLook

@MainActor
final class PreviewLayoutTests: XCTestCase {
    func testRetinaBitmapFitsTheRemoteViewWithoutIntrinsicSizeCropping() throws {
        let source = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); source.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        source.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); source.fillEllipse(in: CGRect(x: 400, y: 600, width: 400, height: 400))
        let view = QuickLookPageView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.image = source.makeImage()
        let output = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 800, bitsPerPixel: 32))
        NSGraphicsContext.saveGraphicsState()
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: output))
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 200, height: 200))
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let center = try XCTUnwrap(output.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.blueComponent, 0.9)
        XCTAssertLessThan(center.redComponent, 0.1)
        let edge = try XCTUnwrap(output.colorAt(x: 5, y: 100))
        XCTAssertLessThan(edge.alphaComponent, 0.1, "The fitted portrait must leave side margins")
    }
}
