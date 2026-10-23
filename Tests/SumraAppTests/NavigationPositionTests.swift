#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class NavigationPositionTests: XCTestCase {
    func testPageTurnOffsetsFollowDisplayedFractionsAcrossSizeAndRotation() {
        let portrait = CGRect(x: 0, y: 0, width: 1200, height: 1800)
        let offset = PageLocalOffset(point: CGPoint(x: 300, y: 720), bounds: portrait)
        XCTAssertEqual(offset.x, 0.25); XCTAssertEqual(offset.y, 0.4)
        // The destination dimensions already include native and view rotation.
        let rotatedLandscape = CGRect(x: 0, y: 0, width: 2000, height: 1400)
        XCTAssertEqual(offset.point(in: rotatedLandscape), CGPoint(x: 500, y: 560))
    }

    func testLinkZoomPreferenceRetainsDestinationAndBackPositionRemainsExact() {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "keepZoomOnLinks")
        let state = ReaderState(recordsHistory: false)
        defer { defaults.set(previous, forKey: "keepZoomOnLinks"); state.windowClosed() }
        state.zoom = 3.5; state.fit = "custom"
        let destination = ReadingPosition(page: 9, x: 48, y: 120, zoom: 1.25, fit: "width")
        defaults.set(false, forKey: "keepZoomOnLinks")
        XCTAssertEqual(state.linkPosition(destination), destination)
        defaults.set(true, forKey: "keepZoomOnLinks")
        let kept = state.linkPosition(destination)
        XCTAssertEqual(kept.page, 9); XCTAssertEqual(kept.x, 48); XCTAssertEqual(kept.y, 120)
        XCTAssertEqual(kept.zoom, 3.5); XCTAssertEqual(kept.fit, "custom")
        let source = ReadingPosition(page: 2, x: 72, y: 540, zoom: 3.5, fit: "custom")
        state.apply(source); state.recordNavigation()
        state.apply(kept); state.navigateHistory(-1)
        XCTAssertEqual(state.page, source.page)
        XCTAssertEqual(state.currentPosition.x, source.x); XCTAssertEqual(state.currentPosition.y, source.y)
        XCTAssertEqual(state.zoom, 3.5)
    }
}
#endif
