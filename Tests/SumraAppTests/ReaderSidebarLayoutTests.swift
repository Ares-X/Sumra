#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderSidebarLayoutTests: XCTestCase {
    @MainActor
    func testLeftSidebarKeepsMinimumWidthAfterSaveReload() async throws {
        try await checkSaveReload(initial: 220, dragged: 180, right: false)
    }

    @MainActor
    func testLeftSidebarKeepsIntermediateWidthAfterSaveReload() async throws {
        try await checkSaveReload(initial: 280, dragged: 240, right: false)
    }

    @MainActor
    func testLeftSidebarKeepsWideWidthAfterSaveReload() async throws {
        try await checkSaveReload(initial: 220, dragged: 320, right: false)
    }

    @MainActor
    func testLeftSidebarKeepsMaximumWidthAfterSaveReload() async throws {
        try await checkSaveReload(initial: 280, dragged: 360, right: false)
    }

    @MainActor
    func testRightSidebarKeepsIntermediateWidthAfterSaveReload() async throws {
        try await checkSaveReload(initial: 220, dragged: 240, right: true)
    }

    @MainActor
    func testRightSidebarKeepsWideWidthAfterSaveReload() async throws {
        try await checkSaveReload(initial: 280, dragged: 320, right: true)
    }

    @MainActor
    func testRightSidebarKeepsWidthWithAISidebarAfterSaveReload() async throws {
        try await checkSaveReload(initial: 220, dragged: 240, right: true, ai: true)
    }

    @MainActor
    private func checkSaveReload(initial: CGFloat, dragged: CGFloat, right: Bool, ai: Bool = false) async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["sidebarWidth", "sidebarRight", "disableHistory"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(Double(initial), forKey: "sidebarWidth")
        defaults.set(right, forKey: "sidebarRight")
        defaults.set(true, forKey: "disableHistory")
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            for (key, value) in zip(keys, previous) {
                XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject,
                               "The test must restore its preference override")
            }
        }

        let reading = try nativePDFReadingFixture()
        let state = ReaderState(recordsHistory: false)
        state.document = reading
        state.count = 1
        state.showAnnotations = true
        state.flow = "paged"; state.fit = "page"; state.spread = false
        state.presentation = false; state.showAI = ai
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 847, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        state.window = window
        defer {
            state.windowClosed(); window.contentView = nil; window.close()
            defaults.removeObject(forKey: "position:" + reading.url.path)
            withExtendedLifetime(reading) {}
        }
        func splits(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splits(in: $0) }
        }
        func sidebarWidth() -> CGFloat? {
            splits(in: host).first { $0.isVertical && $0.arrangedSubviews.count >= 2 && $0.bounds.width > 800 }?.arrangedSubviews[right ? 1 : 0].frame.width
        }
        func waitFor(_ ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if ready() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < deadline
            XCTFail(state.error ?? "Reader layout did not settle")
        }
        try await waitFor { sidebarWidth() != nil && state.readerScrollView != nil }
        try await waitFor { abs((sidebarWidth() ?? 0) - initial) < 2 }
        XCTAssertEqual(try XCTUnwrap(sidebarWidth()), initial, accuracy: 2,
                       "The saved sidebar width must still be used when opening a reader")
        try await waitFor { abs(defaults.double(forKey: "sidebarWidth") - Double(initial)) < 2 }
        let split = try XCTUnwrap(splits(in: host).first { $0.isVertical && $0.arrangedSubviews.count >= 2 && $0.bounds.width > 800 })
        if ai { print("Split panes: \(split.arrangedSubviews.map { "\(type(of: $0)): \($0.frame)" })") }
        // Exercise AppKit's real divider allocation after the saved position.
        split.setPosition(right ? split.arrangedSubviews[1].frame.maxX - dragged : dragged, ofDividerAt: 0)
        try await waitFor { abs((sidebarWidth() ?? 0) - dragged) < 2 }
        try await waitFor { abs(defaults.double(forKey: "sidebarWidth") - Double(dragged)) < 2 }
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = try XCTUnwrap(sidebarWidth()), windowWidth = window.frame.width
        let aiWidth = ai ? split.arrangedSubviews.last?.frame.width : nil
        print("Sidebar layout: initial=\(initial), dragged=\(dragged), right=\(right), AI width=\(aiWidth ?? 0)")
        let pages = try XCTUnwrap(state.nativePDF)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
            bounds: CGRect(x: 10, y: 20, width: 30, height: 40), edits: [.contents("Save layout fixture")])
        try await state.nativePDFDidChange(pages)
        XCTAssertTrue(state.canSave)
        state.savePDF()
        try await waitFor { state.document?.id != reading.id && !state.busy && state.readerScrollView != nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(state.error)
        XCTAssertTrue(state.showAnnotations)
        XCTAssertEqual(window.frame.width, windowWidth, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(sidebarWidth()), before, accuracy: 2,
                       "Replacing the PDF after an ordinary save must retain the dragged divider")
        XCTAssertEqual(defaults.double(forKey: "sidebarWidth"), Double(before), accuracy: 2,
                       "Saving must retain the user's divider preference")
        if let aiWidth {
            XCTAssertEqual(try XCTUnwrap(split.arrangedSubviews.last?.frame.width), aiWidth, accuracy: 2,
                           "Saving must preserve the neighbouring AI divider too")
        }
    }
}
#endif
