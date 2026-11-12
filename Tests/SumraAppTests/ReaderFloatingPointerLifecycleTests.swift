#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

/// Native event-entry and observed-window lifecycle coverage. The pointer is
/// controlled by the fixture; these tests do not exercise WindowServer hover
/// delivery or the system green-button popover.
@MainActor final class ReaderFloatingPointerLifecycleTests: XCTestCase {
    func testVisibleAncestorDoesNotExtendHoverPastTheControlBounds() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.window.setContentSize(.init(width: 700, height: 500))
        fixture.controls.clipsToBounds = false
        fixture.pointOutside()
        let point = fixture.controls.convert(fixture.window.pointer, from: nil)
        XCTAssertFalse(fixture.controls.bounds.contains(point))
        XCTAssertTrue(fixture.controls.visibleRect.contains(point),
            "An unclipped control can inherit visible space outside its own bounds")
        fixture.controls.updateTrackingAreas()
        let outside = try fixture.raster()

        fixture.pointInside()
        fixture.controls.updateTrackingAreas()
        XCTAssertNotEqual(try fixture.raster(), outside)
        fixture.pointOutside()
        fixture.controls.updateButtons()
        XCTAssertEqual(try fixture.raster(), outside,
            "Window updates must not treat the larger ancestor region as a button hover")
    }

    func testStaleTrackingEventsUseTheCurrentPointerAndVisibleRegion() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let controls = fixture.controls
        fixture.pointOutside()
        controls.updateTrackingAreas()
        let outside = try fixture.raster()

        // A queued entry belongs to an old area: the actual pointer has left.
        controls.mouseEntered(with: try fixture.event(.mouseEntered, at: .init(x: 27, y: 10)))
        XCTAssertEqual(try fixture.raster(), outside)

        fixture.pointInside()
        controls.updateTrackingAreas()
        let inside = try fixture.raster()
        XCTAssertNotEqual(inside, outside)
        // Conversely, a queued exit must not erase the current area's hover.
        controls.mouseExited(with: try fixture.event(.mouseExited, at: .init(x: 300, y: 200)))
        XCTAssertEqual(try fixture.raster(), inside)

        fixture.pointOutside()
        controls.mouseMoved(with: try fixture.event(.mouseMoved, at: .init(x: 27, y: 10)))
        XCTAssertEqual(try fixture.raster(), outside, "A retained event location does not own current hover")

        // Clip the right side while leaving the pointer inside control bounds.
        fixture.host.setFrameSize(.init(width: 40, height: 80))
        fixture.window.pointer = controls.convert(.init(x: 50, y: 10), to: nil)
        XCTAssertTrue(controls.bounds.contains(controls.convert(fixture.window.pointer, from: nil)))
        XCTAssertFalse(controls.visibleRect.contains(controls.convert(fixture.window.pointer, from: nil)))
        controls.mouseEntered(with: try fixture.event(.mouseEntered, at: .init(x: 50, y: 10)))
        let clippedOutside = try fixture.raster()
        fixture.pointOutside()
        controls.updateTrackingAreas()
        XCTAssertEqual(try fixture.raster(), clippedOutside, "Clipped controls cannot acquire hover")

        fixture.host.setFrameSize(.init(width: 120, height: 80))
        fixture.pointInside()
        controls.updateTrackingAreas()
        XCTAssertNotEqual(try fixture.raster(), outside)
        fixture.host.isHidden = true
        controls.updateButtons()
        fixture.host.isHidden = false
        XCTAssertEqual(try fixture.raster(), outside, "A hidden ancestor clears retained glyphs")
    }

    func testObservedWindowNotificationsResampleAStationaryPointer() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.pointOutside()
        fixture.controls.updateTrackingAreas()
        let outside = try fixture.raster()

        for name in [NSWindow.didUpdateNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            fixture.pointInside()
            NotificationCenter.default.post(name: name, object: fixture.window)
            XCTAssertNotEqual(try fixture.raster(), outside, "\(name.rawValue) must reveal a stationary pointer")
            fixture.pointOutside()
            NotificationCenter.default.post(name: name, object: fixture.window)
            XCTAssertEqual(try fixture.raster(), outside, "\(name.rawValue) must clear a stationary pointer")
        }

        fixture.pointInside()
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: fixture.window)
        fixture.controls.removeFromSuperview()
        let detached = try fixture.raster()
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: fixture.window)
        XCTAssertEqual(try fixture.raster(), detached, "A former window cannot restore detached hover")
        fixture.pointOutside()
        fixture.host.addSubview(fixture.controls)
        XCTAssertEqual(try fixture.raster(), outside)
    }

    private final class PointerWindow: NSWindow {
        var pointer = NSPoint(x: 300, y: 200)
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    }

    @MainActor private final class Fixture {
        let window: PointerWindow
        let host: NSView
        let controls = ReaderFloatingWindowButtons.Buttons(frame: .init(x: 0, y: 20, width: 54, height: 20))

        init() throws {
            _ = NSApplication.shared
            window = PointerWindow(contentRect: .init(x: 2200, y: 100, width: 120, height: 80),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = try XCTUnwrap(window.contentView)
            // NSView no longer clips by default on macOS 14+. This fixture
            // explicitly owns the clipping boundary exercised above.
            host.clipsToBounds = true
            host.addSubview(controls)
        }

        func pointInside() { window.pointer = controls.convert(.init(x: 27, y: 10), to: nil) }
        func pointOutside() { window.pointer = .init(x: 300, y: 200) }

        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            let location = controls.convert(point, to: nil)
            if type == .mouseMoved {
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0))
            }
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
        }

        func raster() throws -> Data {
            controls.needsDisplay = true
            let bitmap = try XCTUnwrap(controls.bitmapImageRepForCachingDisplay(in: controls.bounds))
            controls.cacheDisplay(in: controls.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }

        func close() {
            controls.stopObservingWindow()
            window.contentView = nil
            window.close()
        }
    }
}
#endif
