#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderSidebarLayoutTests: XCTestCase {
    @MainActor
    func testCompactBothSidebarsStayInsideWindow() async throws {
        _ = NSApplication.shared
        let priorWidth = UserDefaults.standard.object(forKey: "sidebarWidth")
        UserDefaults.standard.set(300.0, forKey: "sidebarWidth")
        defer { UserDefaults.standard.set(priorWidth, forKey: "sidebarWidth") }
        let reading = try nativePDFReadingFixture()
        let state = ReaderState(recordsHistory: false)
        state.document = reading; state.count = 1
        state.showContents = true; state.showAI = true
        let host = NSHostingView(rootView: ReaderView(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 438),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.contentView = host; window.setContentSize(CGSize(width: 560, height: 400)); state.window = window
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(reading) {} }
        func splits(_ view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(splits(host).first { $0.isVertical && $0.arrangedSubviews.count == 3 })
        print("WINDOW=\(window.frame) HOST=\(host.frame) COMPACT split=\(split.frame) bounds=\(split.bounds) panes=\(split.arrangedSubviews.map(\.frame))")
        XCTAssertLessThanOrEqual(split.frame.width, host.bounds.width + 1)
        XCTAssertLessThanOrEqual(split.frame.height, host.bounds.height + 1)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].frame.width, 199)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[2].frame.width, 339)
        XCTAssertLessThanOrEqual(split.arrangedSubviews[2].frame.maxX, split.bounds.maxX + 1)
        XCTAssertTrue(state.revealCompactSidebar(ai: false))
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        print("COMPACT sidebar panes=\(split.arrangedSubviews.map(\.frame))")
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[0].frame.width, 179)
        XCTAssertEqual(split.arrangedSubviews[2].frame.width, 0, accuracy: 1)
        XCTAssertTrue(state.revealCompactSidebar(ai: true))
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[2].frame.width, 339)
        window.setContentSize(CGSize(width: 1000, height: 640))
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        print("WIDE panes=\(split.arrangedSubviews.map(\.frame))")
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 300, accuracy: 2)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sidebarWidth"), 300, accuracy: 2)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].frame.width, 359)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[2].frame.width, 339)
    }

    @MainActor
    func testSearchContentsRevealsHiddenPaneAndMovesNativeFocusOnLeft() async throws {
        try await checkCompactContentsFocus(right: false)
    }

    @MainActor
    func testSearchContentsRevealsHiddenPaneAndMovesNativeFocusOnRight() async throws {
        try await checkCompactContentsFocus(right: true)
    }

    @MainActor
    private func checkCompactContentsFocus(right: Bool) async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["sidebarWidth", "sidebarRight", "findFloating"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(220.0, forKey: "sidebarWidth")
        defaults.set(right, forKey: "sidebarRight")
        defaults.set(false, forKey: "findFloating")
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        let reading = try nativePDFReadingFixture()
        let state = ReaderState(recordsHistory: false)
        state.document = reading; state.count = 1
        state.outline = [.init(title: "Chapter One", target: "#page=1")]
        state.showContents = true; state.showAI = true
        state.aiQuestion = "Keep this draft"
        let host = NSHostingView(rootView: ReaderView(state: state).environment(\.layoutDirection, .leftToRight))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 640),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(reading) {} }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func waitFor(_ ready: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if ready() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < deadline
            XCTFail("Compact sidebar focus did not settle", file: file, line: line)
            throw CancellationError()
        }
        try await waitFor {
            state.compactSidebars && state.contentsSearchField?.window === window &&
                state.contentsFocusView != nil && state.readerFocusView != nil
        }
        let field = try XCTUnwrap(state.contentsSearchField)
        let tree = try XCTUnwrap(state.contentsFocusView)
        let split = try XCTUnwrap(views(host).compactMap { $0 as? NSSplitView }.first {
            $0.isVertical && $0.arrangedSubviews.count == 3
        })
        let sidebar = split.arrangedSubviews[right ? 1 : 0]
        try await waitFor { sidebar.frame.width < 1 }
        XCTAssertTrue(field.visibleRect.isEmpty)
        XCTAssertTrue(ReaderMenuCommand.contentsSearch.enabled(state))
        ReaderMenuCommand.contentsSearch.run(state)
        try await waitFor {
            sidebar.frame.width >= 179 && !field.visibleRect.isEmpty &&
                field.currentEditor() != nil && window.firstResponder === field.currentEditor()
        }
        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        input.insertText("Chapter", replacementRange: input.selectedRange())
        XCTAssertTrue(field.sendAction(try XCTUnwrap(field.action), to: field.target))
        XCTAssertEqual(state.contentsQuery, "Chapter")
        XCTAssertEqual(state.aiQuestion, "Keep this draft")
        window.makeFirstResponder(tree)
        ReaderMenuCommand.cycleFocus.run(state)
        try await waitFor { window.firstResponder === state.readerFocusView }

        window.setContentSize(CGSize(width: 1000, height: 640))
        try await waitFor { !state.compactSidebars && sidebar.frame.width >= 179 }
        state.recentSidebarIsAI = true
        field.selectText(nil)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        window.setContentSize(CGSize(width: 560, height: 640))
        try await waitFor { state.compactSidebars && sidebar.frame.width < 1 && window.firstResponder === state.readerFocusView }
        for _ in 0..<3 {
            ReaderMenuCommand.cycleFocus.run(state)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertFalse(window.firstResponder === tree, "Cycle Focus must skip a mounted zero-width Contents tree")
            XCTAssertNil(field.currentEditor())
        }

        window.setContentSize(CGSize(width: 1000, height: 640))
        try await waitFor { !state.compactSidebars }
        let editor = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor })
        window.makeFirstResponder(editor)
        state.recentSidebarIsAI = false
        window.setContentSize(CGSize(width: 560, height: 640))
        try await waitFor { state.compactSidebars && split.arrangedSubviews[2].frame.width < 1 && window.firstResponder === state.readerFocusView }
        XCTAssertEqual(state.aiQuestion, "Keep this draft")
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testNarrowLeftSearchSidebarPreservesReadingWidthAndItsSavedPreference() async throws {
        try await checkNarrowSearch(right: false)
    }

    @MainActor
    func testNarrowRightSearchSidebarPreservesReadingWidthAndItsSavedPreference() async throws {
        try await checkNarrowSearch(right: true)
    }

    @MainActor
    private func checkNarrowSearch(right: Bool) async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["sidebarWidth", "sidebarRight", "findFloating", "disableHistory", "disableReadingState"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(360.0, forKey: "sidebarWidth")
        defaults.set(right, forKey: "sidebarRight")
        defaults.set(false, forKey: "findFloating")
        defaults.set(true, forKey: "disableHistory")
        defaults.set(true, forKey: "disableReadingState")
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }

        let reading = try nativePDFReadingFixture()
        let state = ReaderState(recordsHistory: false)
        state.document = reading; state.count = 1
        state.showFindPanel()
        state.flow = "paged"; state.fit = "page"; state.spread = true
        state.automaticLayout = false; state.showAI = false; state.presentation = false
        state.immersiveControls = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: ReaderView(state: state).environment(\.layoutDirection, .leftToRight))
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 1000, height: 640),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.contentView = host; state.window = window
        defer {
            state.windowClosed(); window.contentView = nil; window.close()
            withExtendedLifetime(reading) {}
        }
        func splits(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
        }
        func mainSplit() -> NSSplitView? {
            splits(in: host).first { $0.isVertical && $0.arrangedSubviews.count == 2 }
        }
        func waitFor(_ ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if ready() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < deadline
            XCTFail("Search sidebar allocation did not settle")
        }
        try await waitFor {
            guard let split = mainSplit() else { return false }
            return abs(split.arrangedSubviews[right ? 1 : 0].frame.width - 360) < 1
        }
        let split = try XCTUnwrap(mainSplit())
        for width in [560.0, 1000.0, 560.0, 1000.0] {
            window.setContentSize(CGSize(width: width, height: 640))
            try await waitFor {
                let sidebar = split.arrangedSubviews[right ? 1 : 0].frame.width
                let document = split.arrangedSubviews[right ? 0 : 1].frame.width
                return abs(split.bounds.width - width) < 1 && document >= 359.5 &&
                    (width == 560 ? sidebar < 201 : abs(sidebar - 360) < 1)
            }
            XCTAssertGreaterThanOrEqual(split.arrangedSubviews[right ? 0 : 1].frame.width, 359.5)
            XCTAssertEqual(defaults.double(forKey: "sidebarWidth"), 360,
                           "Temporary native compression must not replace the user's saved width")
            XCTAssertTrue(state.spread, "Making room for search must retain the chosen spread")
            XCTAssertEqual(window.frame.width, width, accuracy: 1)
        }
        XCTAssertNil(state.error)
    }

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
    func testLeftSidebarKeepsWidthWithAISidebarAfterSaveReload() async throws {
        try await checkSaveReload(initial: 220, dragged: 240, right: false, ai: true)
    }

    @MainActor
    func testLeftSidebarAppliesExplicitSettingsWhileOpenAndKeepsDraggedWidthAfterSave() async throws {
        try await checkSaveReload(initial: 220, dragged: 240, right: false, updatedPreference: 280)
    }

    @MainActor
    func testRightSidebarAppliesExplicitSettingsBesideAIAndKeepsDraggedWidthAfterSave() async throws {
        try await checkSaveReload(initial: 220, dragged: 240, right: true, ai: true, updatedPreference: 280)
    }

    @MainActor
    private func checkSaveReload(initial: CGFloat, dragged: CGFloat, right: Bool, ai: Bool = false,
                                 updatedPreference: CGFloat? = nil) async throws {
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
        // Leave room for the saved sidebar, the AI pane and the readable document minimum.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: ai ? 1000 : 847, height: 640),
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
        if let updatedPreference {
            let settings = try JSONSerialization.data(withJSONObject: ["sidebarWidth": Double(updatedPreference)])
            try ReaderPreferences.apply(settings)
            try await waitFor { abs((sidebarWidth() ?? 0) - updatedPreference) < 2 }
            XCTAssertEqual(try XCTUnwrap(sidebarWidth()), updatedPreference, accuracy: 2,
                           "An explicit settings edit must resize an already mounted sidebar")
        }
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
