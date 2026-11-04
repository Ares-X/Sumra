#if os(macOS)
import AppKit
import ApplicationServices
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class PaletteSelectionInteractionTests: XCTestCase {
    func testCommandRowMouseSelectionIsImmediateAndHandsArrowKeysToTheList() async throws {
        try await checkSelection(thumbnails: false)
    }

    func testThumbnailMouseSelectionIsImmediateAndKeepsKeyboardNavigation() async throws {
        try await checkSelection(thumbnails: true)
    }

    private func checkSelection(thumbnails: Bool) async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let defaults = UserDefaults.standard, savedMRU = defaults.object(forKey: "paletteMRU")
        defer { defaults.set(savedMRU, forKey: "paletteMRU") }
        let state = ReaderState(recordsHistory: false)
        state.paletteMode = thumbnails ? "& " : "= "
        state.count = 3
        var activations = 0
        let host = NSHostingView(rootView: CommandPalette(state: state, open: {}, perform: { _ in activations += 1 }))
        let window = OffscreenWindow(contentRect: NSRect(x: -3000, y: -3000, width: 720, height: 460),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Palette selection \(UUID().uuidString)"
        window.contentView = host
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            state.windowClosed()
        }
        let ids = thumbnails ? (0..<3).map { "palette-row:page:\($0)" } :
            ReaderPreferences.booleans.sorted().prefix(3).map { "palette-row:setting:" + $0 }
        let application = AXUIElementCreateApplication(getpid())
        var target: AXUIElement?
        try await wait(seconds: 2) {
            host.layoutSubtreeIfNeeded()
            let windows = self.attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            target = windows.first { self.attribute($0, kAXTitleAttribute) as? String == window.title }
            return target.map { owner in ids.allSatisfy { self.find($0, in: owner) != nil } } ?? false
        }
        let owner = try XCTUnwrap(target)
        let clicked = try XCTUnwrap(find(ids[1], in: owner))
        if !thumbnails {
            let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first)
            XCTAssertTrue(window.makeFirstResponder(field))
            XCTAssertTrue(window.firstResponder is NSTextView, "The click must start with the search field editor active")
        }
        // The SwiftUI selected trait is visible to XCUI, but does not expose
        // AXSelected through the public AX API. Inspect the painted row instead.
        let point = try center(clicked, in: window)
        let following = try XCTUnwrap(find(ids[2], in: owner))
        let followingPoint = try center(following, in: window)
        func paint(_ point: NSPoint) throws -> NSColor {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var local = host.convert(point, from: nil)
            local.x += 220 // Blank row background, clear of its label and detail.
            if !host.isFlipped { local.y = host.bounds.height-local.y }
            return try XCTUnwrap(bitmap.colorAt(x: Int(local.x * CGFloat(bitmap.pixelsWide)/host.bounds.width),
                y: Int(local.y * CGFloat(bitmap.pixelsHigh)/host.bounds.height))?.usingColorSpace(.deviceRGB))
        }
        func differs(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent-b.redComponent) + abs(a.greenComponent-b.greenComponent) + abs(a.blueComponent-b.blueComponent) > 0.05
        }
        let before = try paint(point), followingBefore = try paint(followingPoint)
        let root = try XCTUnwrap(window.contentView)
        let hit = try XCTUnwrap(root.hitTest(root.superview?.convert(point, from: nil) ?? point))
        print("SUMRA_PALETTE_TARGET point=\(point) hit=\(hit) frame=\(window.frame)")
        func click(count: Int) throws {
            for kind: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: kind == .leftMouseDown ? 1 : 0))
                // Deliver at the native view boundary without making an
                // offscreen test window key on the user's desktop.
                if kind == .leftMouseDown { hit.mouseDown(with: event) }
                else { hit.mouseUp(with: event) }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        try click(count: 1)
        // Verify the candidate native input owner's painted selection before
        // interpreting its response time. Direct native view delivery does not
        // establish a timing baseline for the old SwiftUI gesture entry point.
        let end = Date(timeIntervalSinceNow: 1.5)
        var changed = false
        repeat {
            changed = differs(try paint(point), before)
            if changed { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < end
        XCTAssertTrue(changed, "Fixture must observe the clicked row's eventual painted highlight")
        guard changed else { throw CancellationError() }
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        print("SUMRA_PALETTE_SINGLE_CLICK mode=\(thumbnails ? "thumbnail" : "command") elapsed=\(elapsed) first=\(String(describing: window.firstResponder))")
        XCTAssertLessThan(elapsed, 0.15, "A single click must paint selection without waiting for double-click arbitration")
        XCTAssertFalse(window.firstResponder is NSTextView, "Clicking a row transfers focus out of the search editor")
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}",
            isARepeat: false, keyCode: 125))
        window.sendEvent(down)
        try await wait(seconds: 0.15) { (try? differs(paint(followingPoint), followingBefore)) == true }
        XCTAssertFalse(differs(try paint(point), before), "Down moves the highlight away from the clicked row")
        XCTAssertEqual(activations, 0, "A single click and arrow navigation only select")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await wait(seconds: 0.15) { activations == 1 }
        try click(count: 2)
        try await wait(seconds: 0.15) { activations == 2 }
        if !thumbnails {
            // Selection scrolls the initially clicked row out of the lazy
            // stack. Its disappearance must not take keyboard focus with it.
            let responder = try XCTUnwrap(window.firstResponder)
            for _ in 0..<ReaderPreferences.booleans.count {
                window.sendEvent(down)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(window.firstResponder === responder)
            XCTAssertTrue((responder as? NSView)?.window === window)
            window.sendEvent(enter)
            try await wait(seconds: 0.15) { activations == 3 }
        }
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func wait(seconds: TimeInterval, _ condition: () -> Bool) async throws {
        let end = Date(timeIntervalSinceNow: seconds)
        repeat {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < end
        XCTFail("The native palette interaction did not complete within \(seconds)s")
        throw CancellationError()
    }

    private func center(_ element: AXUIElement, in window: NSWindow) throws -> NSPoint {
        let position = try XCTUnwrap(attribute(element, kAXPositionAttribute))
        let size = try XCTUnwrap(attribute(element, kAXSizeAttribute))
        var origin = CGPoint.zero, extent = CGSize.zero
        XCTAssertTrue(AXValueGetValue(position as! AXValue, .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(size as! AXValue, .cgSize, &extent))
        let top = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        return window.convertPoint(fromScreen: CGPoint(x: origin.x + extent.width/2, y: top-origin.y-extent.height/2))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }
    private func find(_ id: String, in element: AXUIElement) -> AXUIElement? {
        if attribute(element, kAXIdentifierAttribute) as? String == id { return element }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).lazy.compactMap { self.find(id, in: $0) }.first
    }
}
#endif
