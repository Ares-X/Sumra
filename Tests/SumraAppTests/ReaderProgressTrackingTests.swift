#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderProgressTrackingTests: XCTestCase {
    @MainActor
    private func withFooter(_ body: (ReaderState, NSHostingView<ReaderProgressFooter>, ReaderProgressSliderControl) async throws -> Void) async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "progressDisplayMode")
        defaults.set(ReaderToolbarDisplayMode.shown.rawValue, forKey: "progressDisplayMode")
        defer {
            if let previous { defaults.set(previous, forKey: "progressDisplayMode") }
            else { defaults.removeObject(forKey: "progressDisplayMode") }
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(pageCount: 11)
        state.count = 11; state.page = 0; state.spread = false; state.flow = "paged"; state.automaticLayout = false
        let host = NSHostingView(rootView: ReaderProgressFooter(state: state, floating: true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 56),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            state.windowClosed()
            window.contentView = nil
            window.close()
        }
        await settle(host)
        try await body(state, host, XCTUnwrap(slider(in: host)))
    }

    @MainActor
    private func slider(in view: NSView) -> ReaderProgressSliderControl? {
        if let slider = view as? ReaderProgressSliderControl { return slider }
        return view.subviews.lazy.compactMap { self.slider(in: $0) }.first
    }

    @MainActor
    private func settle(_ host: NSView) async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testReleasedPreviewSurvivesUntilTheRendererAcknowledgesNavigation() async throws {
        try await withFooter { state, host, control in
            let revision = state.command.revision
            control.began?()
            control.changed?(0.76)
            control.ended?()
            await self.settle(host)
            XCTAssertEqual(state.command.revision, revision + 1)
            XCTAssertEqual(state.command.action, .page(8))
            XCTAssertEqual(state.page, 0, "This host deliberately leaves the renderer command pending")
            XCTAssertEqual(control.doubleValue, 0.76, accuracy: 0.0001,
                           "Mouse-up must not repaint the old document position")
            state.updatePosition(.init(page: 8))
            await self.settle(host)
            XCTAssertEqual(control.doubleValue, 0.76, accuracy: 0.0001,
                           "The pending preview remains authoritative until acknowledgement")
            state.didHandleCommand(state.command.revision)
            await self.settle(host)
            XCTAssertEqual(control.doubleValue, 0.8, accuracy: 0.0001,
                           "The confirmed page owns the final quantized position")
        }
    }

    @MainActor
    func testReturningToTheOldPageQueuesASecondSeekAndKeepsItsPreview() async throws {
        try await withFooter { state, host, control in
            control.began?(); control.changed?(0.76); control.ended?()
            await self.settle(host)
            let firstRevision = state.command.revision
            XCTAssertEqual(state.command.action, .page(8))
            control.began?(); control.changed?(0.02); control.ended?()
            await self.settle(host)
            XCTAssertEqual(state.command.revision, firstRevision, "The second seek waits behind the first")
            XCTAssertEqual(control.doubleValue, 0.02, accuracy: 0.0001)
            state.updatePosition(.init(page: 8))
            state.didHandleCommand(firstRevision)
            await self.settle(host)
            XCTAssertEqual(state.command.revision, firstRevision + 1)
            XCTAssertEqual(state.command.action, .page(0), "Returning to the old current page must still supersede the first seek")
            XCTAssertEqual(control.doubleValue, 0.02, accuracy: 0.0001,
                           "The first completion must not erase the second seek's preview")
            state.updatePosition(.init(page: 0))
            state.didHandleCommand(state.command.revision)
            await self.settle(host)
            XCTAssertEqual(control.doubleValue, 0, accuracy: 0.0001)
        }
    }

    @MainActor
    func testNativeMouseTrackingBracketsActionCallbacks() throws {
        _ = NSApplication.shared
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 56))
        let control = ReaderProgressSliderControl(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        control.frame = CGRect(x: 20, y: 16, width: 360, height: 24)
        control.isContinuous = true
        control.target = control
        control.action = #selector(ReaderProgressSliderControl.changedValue)
        container.addSubview(control)
        let window = NSWindow(contentRect: container.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }
        container.layoutSubtreeIfNeeded()
        let initialFrame = control.frame
        let cell = try XCTUnwrap(control.cell as? NSSliderCell)
        let knob = cell.knobRect(flipped: control.isFlipped)
        let start = control.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
        let target = control.convert(CGPoint(x: control.bounds.width * 0.8, y: knob.midY), to: nil)
        var callbacks: [String] = []
        var values: [Double] = []
        control.began = {
            XCTAssertTrue(control.tracking)
            callbacks.append("began")
        }
        control.changed = { value in
            XCTAssertTrue(control.tracking, "AppKit actions belong inside the native tracking lifecycle")
            XCTAssertEqual(control.doubleValue, value)
            XCTAssertTrue(container.subviews.first === control)
            XCTAssertEqual(control.frame, initialFrame)
            callbacks.append("changed")
            values.append(value)
        }
        control.ended = {
            XCTAssertFalse(control.tracking)
            callbacks.append("ended")
        }
        let marker = 743_200, windowNumber = window.windowNumber
        let timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ index: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: timestamp + Double(index) * 0.01, windowNumber: windowNumber,
                context: nil, eventNumber: marker + index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, start, 0)
        let dragged = try event(.leftMouseDragged, target, 1)
        let up = try event(.leftMouseUp, target, 2)
        // App-local events reliably exercise NSSlider's blocking tracking and
        // callbacks, but do not reliably simulate pointer movement. Real drag
        // displacement and painted rail stability require the GUI acceptance
        // script; the two footer tests above retain the seek commit assertions.
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(dragged, atStart: true)
        defer {
            let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
            while let event = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: false),
                  event.windowNumber == window.windowNumber,
                  (marker + 1...marker + 2).contains(event.eventNumber) {
                _ = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true)
            }
        }
        control.mouseDown(with: down)
        XCTAssertEqual(callbacks.first, "began")
        XCTAssertEqual(callbacks.last, "ended")
        XCTAssertEqual(callbacks.filter { $0 == "began" }.count, 1)
        XCTAssertEqual(callbacks.filter { $0 == "ended" }.count, 1)
        XCTAssertFalse(values.isEmpty,
                       "Expected native actions; posted target=\(target), first=\(String(describing: values.first)), last=\(String(describing: values.last)), actual=\(control.doubleValue)")
        XCTAssertEqual(callbacks.count, values.count + 2)
        XCTAssertFalse(control.tracking)
        XCTAssertEqual(control.frame, initialFrame)
    }
}
#endif
