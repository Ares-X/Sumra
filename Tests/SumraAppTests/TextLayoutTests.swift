#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import SumraCore
@testable import Sumra

final class TextLayoutTests: XCTestCase {
    @MainActor
    func testThemeChangeRetainsDistantContinuousSourcePosition() async throws {
        let text = (0..<40_000).map { index in
            index % 2 == 0 ? "Paragraph \(index): " + String(repeating: "中文 English neutral text. ", count: 1 + index % 11) + "\n" : "\n"
        }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        window.setContentSize(NSSize(width: 1_200, height: 700))
        state.theme = "dark"
        try await navigate(.style, state: state, host: host)
        try await navigate(.page(24_000), state: state, host: host)
        await settle(host)
        let saved = state.currentPosition
        let before = visibleTextLines(in: view).map { ($0.range, $0.rect.minY - view.visibleRect.minY) }
        XCTAssertFalse(before.isEmpty)

        state.theme = "light"
        try await navigate(.style, state: state, host: host)
        await settle(host)
        let after = visibleTextLines(in: view).map { ($0.range, $0.rect.minY - view.visibleRect.minY) }
        XCTAssertEqual(state.location.anchor, saved.anchor)
        XCTAssertEqual(state.location.y ?? 0, saved.y ?? 0, accuracy: 0.5)
        XCTAssertEqual(before.map { $0.0 }, after.map { $0.0 })
        for (left, right) in zip(before, after) { XCTAssertEqual(left.1, right.1, accuracy: 0.5) }
    }

    @MainActor
    func testContinuousPositionSurvivesRecreationAfterFacingPageNavigation() async throws {
        let text = (0..<5_584).map { index in
            index % 2 == 0 ? "Paragraph \(index): " + String(repeating: "中文 English neutral text. ", count: 1 + index % 11) + "\n" : "\n"
        }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        window.setContentSize(NSSize(width: 1_200, height: 700))
        await settle(host)
        state.fontSize += 1
        try await navigate(.style, state: state, host: host)
        state.fontSize -= 1
        try await navigate(.style, state: state, host: host)
        state.flow = "paged"
        try await navigate(.style, state: state, host: host)
        try await navigate(.turnPages(1), state: state, host: host)
        try await navigate(.turnPages(1), state: state, host: host)
        state.spread = true
        try await navigate(.style, state: state, host: host)
        try await navigate(.turnPages(1), state: state, host: host)
        try await navigate(.turnPages(1), state: state, host: host)
        state.spread = false; state.flow = "continuous"
        try await navigate(.style, state: state, host: host)
        try await navigate(.scroll(.down, .page), state: state, host: host)
        await settle(host)
        let saved = state.currentPosition
        let before = visibleTextLines(in: view).map { ($0.range, $0.rect.minY - view.visibleRect.minY) }

        let (againWindow, againHost, againView, again) = try await makeReader(text, withDocument: true, position: saved)
        defer { close(againWindow) }
        againWindow.setContentSize(NSSize(width: 1_200, height: 700))
        await settle(againHost)
        let after = visibleTextLines(in: againView).map { ($0.range, $0.rect.minY - againView.visibleRect.minY) }
        XCTAssertEqual(again.location.anchor, saved.anchor)
        XCTAssertEqual(again.location.y ?? 0, saved.y ?? 0, accuracy: 0.5)
        XCTAssertEqual(before.map { $0.0 }, after.map { $0.0 })
        for (left, right) in zip(before, after) { XCTAssertEqual(left.1, right.1, accuracy: 0.5) }
    }

    @MainActor
    func testInitialInsertionUsesTheRequestedAttributesThroughoutTheBook() async throws {
        let text = String(repeating: "English 中文 😀\n", count: 100)
        let (window, _, view, state) = try await makeReader(text)
        defer { close(window) }
        let storage = try XCTUnwrap(view.textContentStorage?.textStorage)
        XCTAssertEqual(view.string, text)
        for offset in [0, storage.length / 2, storage.length - 1] {
            let attributes = storage.attributes(at: offset, effectiveRange: nil)
            XCTAssertEqual((attributes[.font] as? NSFont)?.pointSize, CGFloat(state.fontSize))
            XCTAssertEqual((attributes[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple, CGFloat(state.lineHeight))
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, ReaderTheme.color(state.palette.text))
        }
    }

    @MainActor
    func testLiveResizeRetainsTheReadingAnchorUntilItsFinalViewport() async throws {
        let text = (0..<1_000).map { "Line \($0): " + String(repeating: "中文 English 😀 text. ", count: 8) + "\n" }.joined()
        for spread in [false, true] {
            let (window, host, view, state) = try await makeReader(text, withDocument: true)
            defer { close(window) }
            state.spread = spread; state.flow = spread ? "paged" : "continuous"
            try await navigate(.style, state: state, host: host)
            try await navigate(.page(200), state: state, host: host)
            let saved = state.currentPosition
            let readerHost = try XCTUnwrap(view.enclosingScrollView?.superview as? TextReaderHost)
            readerHost.viewWillStartLiveResize()
            for width in [490.0, 620.0, 400.0] {
                window.setContentSize(NSSize(width: width, height: 180))
                await settle(host)
                XCTAssertEqual(state.location.anchor, saved.anchor)
                XCTAssertEqual(state.location.y ?? 0, saved.y ?? 0, accuracy: 0.5)
            }
            readerHost.viewDidEndLiveResize()
            await settle(host)
            let rect = try XCTUnwrap(lineRect(at: try XCTUnwrap(Int(saved.anchor ?? "")), in: view))
            XCTAssertTrue(rect.intersects(view.visibleRect))
            XCTAssertEqual(view.visibleRect.minY - rect.minY, saved.y ?? 0, accuracy: 0.5)
            XCTAssertEqual(state.location.anchor, saved.anchor)
        }
    }

    @MainActor
    func testNavigationDuringLiveResizeSupersedesTheStartingAnchor() async throws {
        let text = (0..<1_000).map { "Line \($0): a paragraph.\n" }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        try await navigate(.page(100), state: state, host: host)
        let readerHost = try XCTUnwrap(view.enclosingScrollView?.superview as? TextReaderHost)
        readerHost.viewWillStartLiveResize()
        window.setContentSize(NSSize(width: 490, height: 180))
        await settle(host)
        try await navigate(.page(300), state: state, host: host)
        readerHost.viewDidEndLiveResize()
        await settle(host)
        XCTAssertEqual(state.page, 300)
    }

    @MainActor
    func testTextViewportTurnsWrappedParagraphsWithoutUsingSourceLines() async throws {
        let text = String(repeating: "中文与 English 😀 mixed text。 ", count: 2_000)
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        state.flow = "paged"
        try await navigate(.style, state: state, host: host)
        XCTAssertEqual(state.count, 1)
        XCTAssertFalse(state.canGoBackward)
        try await navigate(.turnPages(1), state: state, host: host)
        XCTAssertGreaterThan(try XCTUnwrap(Int(state.location.anchor ?? "")), 0)
        XCTAssertEqual(state.page, 0, "The toolbar keeps the source line rather than inventing a whole-book page count")
        XCTAssertTrue(state.canGoBackward, "A wrapped paragraph can move backward while its source line stays zero")
        XCTAssertTrue(state.canGoForward)
        try await navigate(.scroll(.right, .line), state: state, host: host)
        let forward = try XCTUnwrap(Int(state.location.anchor ?? ""))
        XCTAssertGreaterThan(forward, 0)
        state.rtl = true
        try await navigate(.scroll(.right, .line), state: state, host: host)
        XCTAssertLessThan(try XCTUnwrap(Int(state.location.anchor ?? "")), forward)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testTextNextPreviousRestoresSingleAndFacingPageBoundaries() async throws {
        let text = (0..<1_000).map { index in
            "Line \(index): " + String(repeating: "中文和 English 😀 text. ", count: 1 + index % 4) + "\n"
        }.joined()
        for spread in [false, true] {
            let (window, host, view, state) = try await makeReader(text, withDocument: true)
            defer { close(window) }
            state.spread = spread; state.flow = "paged"
            try await navigate(.style, state: state, host: host)
            let beginning = state.currentPosition
            if spread {
                let facing = try XCTUnwrap((view.enclosingScrollView?.superview as? TextReaderHost)?.trailing?.documentView as? NSTextView)
                XCTAssertEqual(NSMaxRange(try XCTUnwrap(visibleTextLines(in: view).last).range), try XCTUnwrap(visibleTextLines(in: facing).first).range.location)
            }
            try await navigate(.turnPages(1), state: state, host: host)
            let second = state.currentPosition
            XCTAssertGreaterThan(try XCTUnwrap(Int(second.anchor ?? "")), 0)
            try await navigate(.turnPages(1), state: state, host: host)
            let third = state.currentPosition
            XCTAssertNotEqual(second.anchor, third.anchor)
            try await navigate(.turnPages(-1), state: state, host: host)
            XCTAssertEqual(state.location.anchor, second.anchor)
            XCTAssertEqual(state.location.y ?? 0, second.y ?? 0, accuracy: 0.5)
            try await navigate(.turnPages(-1), state: state, host: host)
            XCTAssertEqual(state.location.anchor, beginning.anchor)
            XCTAssertEqual(state.location.y ?? 0, beginning.y ?? 0, accuracy: 0.5)
            try await navigate(.turnPages(1), state: state, host: host)
            XCTAssertEqual(state.location.anchor, second.anchor)
        }
    }

    @MainActor
    func testTextArrowKeysTurnReadingPagesAndPreserveNativeSelection() async throws {
        let text = (0..<1_000).map { "Line \($0): a short paragraph.\n" }.joined()
        for flow in ["paged", "continuous"] {
            for spread in [false, true] {
                let (window, host, view, state) = try await makeReader(text, withDocument: true)
                defer { close(window) }
                state.flow = flow; state.spread = spread
                try await navigate(.style, state: state, host: host)
                let facing = (view.enclosingScrollView?.superview as? TextReaderHost)?.trailing?.documentView as? NSTextView
                let input = try XCTUnwrap(spread ? facing : view)
                func arrow(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
                    let characters = keyCode == 123 ? "\u{f702}" : "\u{f703}"
                    return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: keyCode))
                }
                let beginning = state.currentPosition
                input.keyDown(with: try arrow(124))
                await settle(host)
                XCTAssertGreaterThan(try XCTUnwrap(Int(state.location.anchor ?? "")), try XCTUnwrap(Int(beginning.anchor ?? "")))
                view.keyDown(with: try arrow(123, modifiers: [.function, .numericPad]))
                await settle(host)
                XCTAssertEqual(state.location.anchor, beginning.anchor)
                XCTAssertEqual(state.location.y ?? 0, beginning.y ?? 0, accuracy: 0.5)
                state.rtl = true
                try await navigate(.style, state: state, host: host)
                input.keyDown(with: try arrow(123))
                await settle(host)
                XCTAssertGreaterThan(try XCTUnwrap(Int(state.location.anchor ?? "")), try XCTUnwrap(Int(beginning.anchor ?? "")))
                view.keyDown(with: try arrow(124))
                await settle(host)
                XCTAssertEqual(state.location.anchor, beginning.anchor)

                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                view.keyDown(with: try arrow(124, modifiers: .shift))
                await settle(host)
                XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 1), "Shift-arrow must retain native text selection")
                XCTAssertEqual(state.location.anchor, beginning.anchor)
                state.keyboardTextSelection = true
                view.setSelectedRange(NSRange(location: 0, length: 0))
                view.keyDown(with: try arrow(124))
                await settle(host)
                XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0), "Opt-in text selection keeps bare arrows as caret movement")
                XCTAssertEqual(state.location.anchor, beginning.anchor)
            }
        }
    }

    @MainActor
    func testTextContinuousWheelCrossesViewportBoundaryWithoutPageSnap() async throws {
        let text = (0..<1_000).map { "Line \($0): a short paragraph.\n" }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        state.flow = "paged"
        try await navigate(.style, state: state, host: host)
        state.flow = "continuous"
        try await navigate(.style, state: state, host: host)
        let scroll = try XCTUnwrap(view.enclosingScrollView), clip = scroll.contentView
        XCTAssertEqual(view.string, text, "Continuous reading keeps the complete native text document")
        XCTAssertNotNil(view.textLayoutManager)
        XCTAssertEqual(clip.frame.height, scroll.bounds.height, accuracy: 0.5,
                       "Continuous mode releases the paged complete-line clip height")
        let boundary = clip.bounds.height * 2
        clip.scroll(to: NSPoint(x: 0, y: boundary - 4))
        scroll.reflectScrolledClipView(clip)
        await settle(host)
        func wheel(_ phase: CGScrollPhase) throws -> NSEvent {
            let point = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
            let seed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let cg = try XCTUnwrap(seed.cgEvent?.copy())
            cg.type = .scrollWheel
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -3)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -3)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        for phase: CGScrollPhase in [.began, .changed] {
            let before = clip.bounds.minY, event = try wheel(phase)
            XCTAssertTrue(event.hasPreciseScrollingDeltas)
            view.scrollWheel(with: event)
            await settle(host)
            XCTAssertEqual(clip.bounds.minY - before, -event.scrollingDeltaY, accuracy: 0.5,
                           "Each small native wheel input keeps its distance across a former page boundary")
            XCTAssertEqual(clip.frame.height, scroll.bounds.height, accuracy: 0.5)
        }
        XCTAssertGreaterThan(clip.bounds.minY, boundary)
    }

    @MainActor
    func testTextMouseWheelTurnsAfterTrackpadGesture() async throws {
        let text = (0..<1_000).map { "Line \($0): a short paragraph.\n" }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        state.flow = "paged"
        try await navigate(.style, state: state, host: host)
        func wheel(phase: CGScrollPhase? = nil, momentum: Int64 = 0) throws -> NSEvent {
            let seed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let cg = try XCTUnwrap(seed.cgEvent?.copy())
            cg.type = .scrollWheel
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: phase == nil && momentum == 0 ? 0 : 1)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -10)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -10)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        view.scrollWheel(with: try wheel(phase: .began))
        await settle(host)
        let afterTouch = try XCTUnwrap(Int(state.location.anchor ?? ""))
        XCTAssertGreaterThan(afterTouch, 0)
        view.scrollWheel(with: try wheel(phase: .changed))
        view.scrollWheel(with: try wheel(momentum: 1))
        await settle(host)
        XCTAssertEqual(Int(state.location.anchor ?? ""), afterTouch, "A touch gesture and its momentum turn once")
        view.scrollWheel(with: try wheel())
        await settle(host)
        let afterMouse = try XCTUnwrap(Int(state.location.anchor ?? ""))
        XCTAssertGreaterThan(afterMouse, afterTouch, "A discrete mouse wheel must not inherit the trackpad latch")
        view.scrollWheel(with: try wheel())
        await settle(host)
        XCTAssertGreaterThan(try XCTUnwrap(Int(state.location.anchor ?? "")), afterMouse)
    }

    @MainActor
    func testTextFacingPagesShareContentAndRetainSelectionAcrossModes() async throws {
        let text = (0..<1_000).map { "Line \($0): 中文和 English 😀 text.\n" }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        try await navigate(.page(100), state: state, host: host)
        let anchor = state.location.anchor
        let selection = NSRange(location: try XCTUnwrap(Int(anchor ?? "")), length: 4)
        view.setSelectedRange(selection)
        state.spread = true; state.flow = "paged"
        try await navigate(.style, state: state, host: host)
        let reader = try XCTUnwrap(view.enclosingScrollView?.superview as? TextReaderHost)
        let second = try XCTUnwrap(reader.trailing?.documentView as? NSTextView)
        XCTAssertTrue(view.textContentStorage === second.textContentStorage)
        XCTAssertNotNil(second.textLayoutManager)
        XCTAssertLessThan(view.visibleRect.width, host.bounds.width / 2 + 1)
        XCTAssertEqual(view.visibleRect.width, second.visibleRect.width, accuracy: 0.5)
        let leftLines = visibleTextLines(in: view), rightLines = visibleTextLines(in: second)
        XCTAssertEqual(NSMaxRange(try XCTUnwrap(leftLines.last).range), try XCTUnwrap(rightLines.first).range.location,
                       "Facing pages meet at the same UTF-16 boundary without repeated or skipped text")
        XCTAssertLessThanOrEqual(try XCTUnwrap(leftLines.last).rect.maxY, view.visibleRect.maxY + 0.5)
        XCTAssertEqual(state.location.anchor, anchor)
        XCTAssertEqual(view.selectedRange(), selection)
        let primary = try XCTUnwrap(view.textLayoutManager?.textViewportLayoutController.viewportRange)
        let facing = try XCTUnwrap(second.textLayoutManager?.textViewportLayoutController.viewportRange)
        XCTAssertEqual(primary.location.compare(facing.location), .orderedAscending)
        let secondSelection = NSRange(location: try XCTUnwrap(second.textContentStorage).offset(from: try XCTUnwrap(second.textContentStorage).documentRange.location, to: facing.location), length: 4)
        second.setSelectedRange(secondSelection)
        await settle(host)
        XCTAssertEqual(state.selectedText, (text as NSString).substring(with: secondSelection))
        state.spread = false
        try await navigate(.style, state: state, host: host)
        XCTAssertEqual(view.selectedRange(), secondSelection)
        XCTAssertEqual(state.location.anchor, anchor)
        XCTAssertTrue(reader.trailing?.isHidden == true)
    }

    @MainActor
    func testTextFacingEndAndSearchRespectBothNativeViewports() async throws {
        let text = (0..<300).map { "Line \($0): a short paragraph.\n" }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        state.spread = true
        try await navigate(.style, state: state, host: host)
        try await navigate(.find("Line 200:"), state: state, host: host)
        let match = (text as NSString).range(of: "Line 200:")
        try await waitFor(host) { state.selectedSearchTarget == "text:\(match.location):\(match.length)" && self.lineRect(at: match.location, in: view)?.intersects(view.visibleRect) == true }
        try await navigate(.page(state.count - 1), state: state, host: host)
        XCTAssertTrue(TextReader.isAtEnd(in: view))
        XCTAssertFalse(state.canGoForward)
        let end = state.location.anchor
        try await navigate(.turnPages(1), state: state, host: host)
        XCTAssertEqual(state.location.anchor, end)
        state.spread = false; state.flow = "continuous"
        try await navigate(.style, state: state, host: host)
        XCTAssertTrue(ReaderScroll.isAtTextEnd(view))
        XCTAssertNotNil(view.textLayoutManager)
    }
    @MainActor
    func testTextEndPositionSurvivesReflowAndReaderRecreation() async throws {
        for ending in ["", "\n"] {
            let text = (0..<1_000).map { "Line \($0): a short paragraph." }.joined(separator: "\n") + ending
            let end = (text as NSString).length
            let (window, host, view, state) = try await makeReader(text, withDocument: true)
            var closed = false
            defer { if !closed { close(window) } }
            try await navigate(.page(state.count - 1), state: state, host: host)
            await settle(host)
            assertAtEnd(view)
            XCTAssertEqual(state.location.anchor, String(end), "The saved end must survive changed wrapping")
            XCTAssertEqual(state.location.y, 0)
            state.fontSize = 24
            try await navigate(.style, state: state, host: host)
            assertAtEnd(view)
            host.setFrameSize(NSSize(width: 420, height: 180))
            await settle(host)
            assertAtEnd(view)
            let saved = state.currentPosition
            close(window); closed = true

            let (reopenedWindow, reopenedHost, reopenedView, reopened) = try await makeReader(text, withDocument: true, position: saved)
            defer { close(reopenedWindow) }
            await settle(reopenedHost)
            assertAtEnd(reopenedView)
            XCTAssertFalse(reopened.canGoForward)
            XCTAssertEqual(reopened.location.anchor, String(end))
            XCTAssertEqual(reopened.fontSize, 24)
        }
    }

    @MainActor
    func testTextEndPositionLeavesFittingAndFinalParagraphAnchorsIntact() async throws {
        let (window, host, view, state) = try await makeReader("first\nlast", withDocument: true)
        defer { close(window) }
        await settle(host)
        XCTAssertEqual(state.location.anchor, "0")
        state.fontSize = 36
        try await navigate(.style, state: state, host: host)
        host.setFrameSize(NSSize(width: 160, height: 60))
        await settle(host)
        XCTAssertEqual(state.location.anchor, "0", "A fitting book must retain its top when it begins to overflow")
        XCTAssertEqual(view.enclosingScrollView?.contentView.bounds.minY ?? -1, 0, accuracy: 0.5)

        let prefix = String(repeating: "A short paragraph.\n", count: 100)
        let text = prefix + String(repeating: "final wrapped paragraph ", count: 200)
        let (lastWindow, lastHost, _, lastState) = try await makeReader(text, withDocument: true)
        defer { close(lastWindow) }
        try await navigate(.restore(.init(page: 100, anchor: String((prefix as NSString).length + 400))), state: lastState, host: lastHost)
        await settle(lastHost)
        let saved = lastState.currentPosition
        XCTAssertLessThan(try XCTUnwrap(Int(saved.anchor ?? "")), (text as NSString).length)
        XCTAssertTrue(lastState.canGoForward, "A long final source paragraph still has later reading screens")
        let (againWindow, againHost, _, again) = try await makeReader(text, withDocument: true, position: saved)
        defer { close(againWindow) }
        await settle(againHost)
        XCTAssertEqual(again.location.anchor, saved.anchor)
        XCTAssertEqual(again.location.y ?? 0, saved.y ?? 0, accuracy: 0.5)
        try await navigate(.restore(.init(page: again.count - 1, anchor: String((text as NSString).length))), state: again, host: againHost)
        XCTAssertFalse(again.canGoForward, "Next stops at the actual end of the displayed text")
    }

    @MainActor
    func testTextForwardNavigationStopsAtTheVisibleDocumentEnd() async throws {
        let text = (0..<1_000).map { "Line \($0): a short paragraph.\n" }.joined()
        let (window, host, view, state) = try await makeReader(text, withDocument: true)
        defer { close(window) }
        XCTAssertFalse(state.canGoBackward)
        XCTAssertTrue(state.canGoForward)

        try await navigate(.page(state.count - 1), state: state, host: host)
        XCTAssertLessThan(state.page, state.count - 1, "The header reports the first visible logical line")
        XCTAssertFalse(state.canGoForward, "Next must be disabled when the viewport already shows the end")
        XCTAssertFalse(ReaderMenuCommand.next.enabled(state))
        XCTAssertTrue(state.canGoBackward)

        state.scroll(.up, amount: .page)
        try await navigate(.none, state: state, host: host)
        XCTAssertTrue(state.canGoForward)
        try await navigate(.page(400), state: state, host: host)
        state.fontSize = 24
        try await navigate(.style, state: state, host: host)
        host.setFrameSize(NSSize(width: 420, height: 180))
        await settle(host)
        XCTAssertTrue(state.canGoForward)
        XCTAssertTrue(state.canGoBackward)
        XCTAssertNotNil(view.textLayoutManager)

        try await navigate(.page(state.count - 1), state: state, host: host)
        XCTAssertFalse(state.canGoForward)
    }

    @MainActor
    func testTextForwardNavigationRetainsLogicalBoundsUntilMounted() async throws {
        let state = ReaderState()
        state.flow = "continuous"
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/text-navigation.txt"), content: .text("first\nlast"))
        state.count = 2
        XCTAssertTrue(state.canGoForward, "Unavailable viewport geometry must retain logical navigation")
        state.page = 1
        XCTAssertFalse(state.canGoForward)

        let (window, host, _, fitted) = try await makeReader("first\nlast", withDocument: true)
        defer { close(window) }
        await settle(host)
        XCTAssertFalse(fitted.canGoForward, "A complete fitting document needs no Next command")
        XCTAssertFalse(fitted.canGoBackward)
    }

    @MainActor
    func testEarlyRestoreScrollAndPositionRoundTrip() async throws {
        let line = "😀 A short paragraph.\r\n", text = String(repeating: line, count: 20_000)
        let (window, host, view, state) = try await makeReader(text)
        defer { close(window) }
        let anchor = 20 * (line as NSString).length
        try await navigate(.restore(.init(page: 20, y: 3, anchor: String(anchor))), state: state, host: host)
        XCTAssertEqual(state.page, 20)
        XCTAssertEqual(state.location.anchor, String(anchor))
        XCTAssertEqual(state.location.y ?? 0, 3, accuracy: 0.5)
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + 90))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitFor(host) { state.page > 20 }
        let saved = state.currentPosition
        try await navigate(.page(0), state: state, host: host)
        try await navigate(.restore(saved), state: state, host: host)
        XCTAssertEqual(state.page, saved.page)
        XCTAssertEqual(state.location.anchor, saved.anchor)
        XCTAssertEqual(state.location.y ?? 0, saved.y ?? 0, accuracy: 0.5)
        XCTAssertNotNil(view.textLayoutManager, "Reading must remain on the native viewport layout engine")
    }

    @MainActor
    func testQueuedNavigationKeepsTheLastRequestedPosition() async throws {
        let line = "A short paragraph.\n"
        let (window, host, view, state) = try await makeReader(String(repeating: line, count: 1_000))
        defer { close(window) }
        state.send(.href("100")); state.send(.href("40"))
        try await navigate(.href("200"), state: state, host: host)
        XCTAssertEqual(state.page, 200)
        XCTAssertEqual(state.location.anchor, String(200 * (line as NSString).length))
        await settle(host)
        XCTAssertEqual(state.page, 200, "A deferred report from an earlier jump must not overwrite the final destination")
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testQueuedStyleFinishesBeforeNavigationAndSearch() async throws {
        let text = (0..<1_000).map { "Line \($0): a short paragraph.\n" }.joined()
        let (window, host, view, state) = try await makeReader(text)
        defer { close(window) }
        try await navigate(.page(100), state: state, host: host)

        state.fontSize = 24; state.send(.style)
        try await navigate(.href("700"), state: state, host: host)
        let anchor = ChapterDetector.index(text).lines[700]
        XCTAssertEqual(state.location.anchor, String(anchor))
        await settle(host)
        XCTAssertEqual(state.location.anchor, String(anchor), "An earlier style restoration must not undo the queued jump")
        XCTAssertTrue(try XCTUnwrap(lineRect(at: anchor, in: view)).intersects(view.visibleRect))

        let selection = NSRange(location: anchor, length: 4)
        view.setSelectedRange(selection)
        state.fontSize = 21; state.send(.style)
        try await navigate(.find("Line 200:"), state: state, host: host)
        let match = (text as NSString).range(of: "Line 200:")
        try await waitFor(host) { state.selectedSearchTarget == "text:\(match.location):\(match.length)" && self.lineRect(at: match.location, in: view)?.intersects(view.visibleRect) == true }
        await settle(host)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(try XCTUnwrap(lineRect(at: match.location, in: view)).intersects(view.visibleRect),
                      "A completed style command must not later scroll away from the search result")
        let manager = try XCTUnwrap(view.textLayoutManager), content = try XCTUnwrap(view.textContentStorage)
        var highlighted = false
        manager.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            if attributes[.backgroundColor] != nil, start <= match.location, end >= NSMaxRange(match) { highlighted = true }
            return start <= NSMaxRange(match)
        }
        XCTAssertTrue(highlighted, "Search must render its own highlight without changing the selected text")
        XCTAssertNil(content.textStorage?.attribute(.backgroundColor, at: match.location, effectiveRange: nil))
        state.closeFind()
        await settle(host)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testStyleBatchesChangedAttributesAndLeavesUnchangedTextAlone() async throws {
        let text = String(repeating: "中文和 English share one line.\r\n", count: 500)
        let (window, host, view, state) = try await makeReader(text)
        defer { close(window) }
        try await navigate(.page(100), state: state, host: host)
        let anchor = try XCTUnwrap(Int(state.location.anchor ?? ""))
        view.setSelectedRange(NSRange(location: anchor, length: 2))
        let selection = view.selectedRange()
        let storage = try XCTUnwrap(view.textContentStorage?.textStorage)
        var edits = 0
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        try await navigate(.style, state: state, host: host)
        XCTAssertEqual(edits, 0)
        state.margin = 40
        try await navigate(.style, state: state, host: host)
        XCTAssertEqual(edits, 0, "Changing margins must not rewrite the book's font or colors")
        state.customBackgroundColor = 0xeeddcc
        try await navigate(.style, state: state, host: host)
        XCTAssertEqual(edits, 0, "Paper color is a view property, not a text edit")
        XCTAssertEqual(ReaderTheme.rgb(view.backgroundColor), 0xeeddcc)

        state.customTextColor = 0x123456
        try await navigate(.style, state: state, host: host)
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(ReaderTheme.rgb(try XCTUnwrap(view.textColor)), 0x123456)
        state.fontSize = 24; state.lineHeight = 1.8; state.customTextColor = 0x345678
        try await navigate(.style, state: state, host: host)
        try await waitFor(host) { state.location.anchor == String(anchor) && self.lineRect(at: anchor, in: view)?.intersects(view.visibleRect) == true }
        XCTAssertEqual(edits, 2, "Font, paragraph and color changes must share one attribute-processing pass")
        for index in [0, storage.length - 2] {
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            XCTAssertEqual((attributes[.font] as? NSFont)?.pointSize, 24)
            XCTAssertEqual((attributes[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple, 1.8)
            XCTAssertEqual(ReaderTheme.rgb(try XCTUnwrap(attributes[.foregroundColor] as? NSColor)), 0x345678)
        }
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(state.location.anchor, String(anchor))
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testFarNavigationAndFontChangesPreserveTheCharacterAndOffset() async throws {
        let line = "😀 A short paragraph.\r\n", text = String(repeating: line, count: 20_000)
        let (window, host, view, state) = try await makeReader(text)
        defer { close(window) }
        let target = 18_000 * (line as NSString).length
        try await navigate(.restore(.init(page: 18_000, y: 3, anchor: String(target))), state: state, host: host)
        XCTAssertEqual(state.page, 18_000)
        XCTAssertEqual(state.location.anchor, String(target))
        XCTAssertEqual(state.location.y ?? 0, 3, accuracy: 0.5)
        let saved = state.currentPosition
        try await navigate(.page(0), state: state, host: host)
        try await navigate(.restore(saved), state: state, host: host)
        XCTAssertEqual(state.location.anchor, saved.anchor)
        XCTAssertEqual(state.location.y ?? 0, saved.y ?? 0, accuracy: 0.5)
        state.fontSize = 24
        try await navigate(.style, state: state, host: host)
        try await waitFor(host) {
            guard let rect = self.lineRect(at: target, in: view) else { return false }
            return rect.intersects(view.visibleRect) && abs(view.visibleRect.minY - rect.minY - 3) < 0.5
        }
        XCTAssertEqual(state.location.anchor, String(target))
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testMixedParagraphNavigationUsesLaidOutCoordinatesAfterReflow() async throws {
        let text = (0..<8_000).map { index in
            let repeats = index < 1_000 ? 1 : index < 5_000 ? 1 + index % 80 : 1 + index % 7
            return "Heading \(index) " + String(repeating: "中文与 English 😀 mixed text。", count: repeats) + "\r\n"
        }.joined()
        let offsets = ChapterDetector.index(text).lines
        let (window, host, view, state) = try await makeReader(text)
        defer { close(window) }
        for fontSize in [17.0, 24.0, 15.0] {
            state.fontSize = fontSize
            try await navigate(.style, state: state, host: host)
            for index in [100, 4_000, 7_900] {
                let anchor = offsets[index]
                try await navigate(.restore(.init(page: index, y: 3, anchor: String(anchor))), state: state, host: host)
                await settle(host)
                let rect = try XCTUnwrap(lineRect(at: anchor, in: view))
                XCTAssertTrue(rect.intersects(view.visibleRect))
                XCTAssertEqual(view.visibleRect.minY - rect.minY, 3, accuracy: 0.5)
                XCTAssertEqual(state.location.anchor, String(anchor))
            }
        }
        let saved = state.currentPosition
        let anchor = try XCTUnwrap(Int(saved.anchor ?? ""))
        let scrollerWidth = host.bounds.width - view.visibleRect.width
        for width in [622.0, 802.0, 622.0, 480.0] {
            window.setContentSize(NSSize(width: width + scrollerWidth, height: 160))
            await settle(host)
            let rect = try XCTUnwrap(lineRect(at: anchor, in: view))
            XCTAssertEqual(view.visibleRect.width, width, accuracy: 0.5)
            XCTAssertTrue(rect.intersects(view.visibleRect), "Resizing the native reader must preserve the visible character")
            XCTAssertEqual(view.visibleRect.minY - rect.minY, saved.y ?? 0, accuracy: 0.5)
            XCTAssertEqual(state.location.anchor, saved.anchor)
        }
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testRestoreToTerminalEmptyLineKeepsItVisible() async throws {
        let text = String(repeating: "Line with an emoji 😀.\r\n", count: 50)
        let (window, host, view, state) = try await makeReader(text)
        defer { close(window) }
        let end = (text as NSString).length
        try await navigate(.restore(.init(page: 50, anchor: String(end))), state: state, host: host)
        let terminal = try XCTUnwrap(lineRect(at: end, in: view))
        let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
        let proposed = NSRect(origin: NSPoint(x: 0, y: terminal.minY), size: clip.bounds.size)
        XCTAssertEqual(clip.bounds, clip.constrainBoundsRect(proposed))
        XCTAssertGreaterThan(terminal.maxY, view.visibleRect.minY)
        XCTAssertLessThan(terminal.minY, view.visibleRect.maxY)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testSpeechHighlightPreservesSelectionAndSourceAttributes() async throws {
        let text = String(repeating: "中文和 English share one line.\r\n", count: 100)
        let (window, host, view, state) = try await makeReader(text)
        defer { close(window) }
        let selection = NSRange(location: 2, length: 12)
        view.setSelectedRange(selection)
        let bounds = await state.selectionScreenBounds?()
        XCTAssertNotNil(bounds)
        XCTAssertGreaterThan(bounds?.height ?? 0, 0)
        state.speechFollow = false
        try await navigate(.speechHighlight(location: 5, length: 7), state: state, host: host)
        XCTAssertEqual(view.selectedRange(), selection)
        let manager = try XCTUnwrap(view.textLayoutManager), content = try XCTUnwrap(view.textContentStorage)
        func highlighted() -> Bool {
            var found = false
            manager.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
                let start = content.offset(from: content.documentRange.location, to: range.location)
                let end = content.offset(from: content.documentRange.location, to: range.endLocation)
                if attributes[.backgroundColor] != nil, start <= 5, end >= 12 { found = true }
                return start <= 12
            }
            return found
        }
        XCTAssertTrue(highlighted())
        XCTAssertNil(content.textStorage?.attribute(.backgroundColor, at: 5, effectiveRange: nil))
        state.fontSize = 24
        try await navigate(.style, state: state, host: host)
        await settle(host)
        XCTAssertTrue(highlighted(), "A native relayout must retain the current spoken word")
        try await navigate(.speechHighlight(location: 0, length: 0), state: state, host: host)
        XCTAssertFalse(highlighted())
        XCTAssertEqual(view.selectedRange(), selection)
        try await navigate(.selectAll, state: state, host: host)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: (text as NSString).length))
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    private func makeReader(_ text: String, withDocument: Bool = false, position: ReadingPosition? = nil) async throws -> (NSWindow, NSHostingView<TextReader>, NSTextView, ReaderState) {
        _ = NSApplication.shared
        let state = ReaderState()
        state.flow = "continuous"
        state.font = "system"; state.fontSize = 17; state.zoom = 1; state.lineHeight = 1.6
        state.margin = 32; state.pageMargins = nil; state.theme = "light"
        if withDocument {
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/text-layout.txt"), content: .text(text))
        }
        if let position { state.apply(position) }
        let host = NSHostingView(rootView: TextReader(state: state, text: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let count = ChapterDetector.index(text).lines.count
        try await waitFor(host) { state.count == count && state.readerFocusView != nil }
        let view = try XCTUnwrap(state.readerFocusView as? NSTextView)
        try await waitFor(host) { view.textLayoutManager?.textViewportLayoutController.viewportRange != nil }
        return (window, host, view, state)
    }

    @MainActor
    private func navigate(_ action: ReaderAction, state: ReaderState, host: NSHostingView<TextReader>) async throws {
        let revision = state.command.revision
        state.send(action); state.send(.none)
        try await waitFor(host) { state.command.revision > revision && state.command.action == .none }
    }

    @MainActor
    private func waitFor(_ host: NSHostingView<TextReader>, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            await settle(host)
            if ready() { return }
        } while Date() < deadline
        _ = try XCTUnwrap(ready() ? true : nil, "The native reader did not finish the requested layout/navigation: \(host.rootView.state.command.action)")
    }

    @MainActor
    private func settle(_ host: NSHostingView<TextReader>) async {
        host.layoutSubtreeIfNeeded()
        let primary = host.rootView.state.readerFocusView as? NSTextView
        let facing = (primary?.enclosingScrollView?.superview as? TextReaderHost)?.trailing?.documentView as? NSTextView
        for view in [primary, facing].compactMap({ $0 }) where !view.isHiddenOrHasHiddenAncestor && view.visibleRect.width > 0 && view.visibleRect.height > 0 {
            view.layoutSubtreeIfNeeded()
            autoreleasepool {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) { view.cacheDisplay(in: view.visibleRect, to: bitmap) }
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    @MainActor
    private func visibleTextLines(in view: NSTextView) -> [(range: NSRange, rect: CGRect)] {
        guard let content = view.textContentStorage, let manager = view.textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        var result: [(range: NSRange, rect: CGRect)] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let start = content.offset(from: content.documentRange.location, to: fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let rect = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                                          dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
                if rect.maxY > view.visibleRect.minY + 0.5, rect.minY < view.visibleRect.maxY - 0.5 {
                    result.append((NSRange(location: start + line.characterRange.location, length: line.characterRange.length), rect))
                }
            }
            return fragment.layoutFragmentFrame.maxY + view.textContainerOrigin.y < view.visibleRect.maxY
        }
        return result
    }

    @MainActor
    private func lineRect(at character: Int, in view: NSTextView) -> CGRect? {
        guard let content = view.textContentStorage, let manager = view.textLayoutManager,
              let location = content.location(content.documentRange.location, offsetBy: character == content.textStorage?.length ? max(0, character - 1) : character) else { return nil }
        var result: CGRect?
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresExtraLineFragment]) { fragment in
            let start = content.offset(from: content.documentRange.location, to: fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
                if NSLocationInRange(character, range) || character == range.location && range.length == 0
                    || character == content.textStorage?.length && character == NSMaxRange(range) {
                    result = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                                             dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
                }
            }
            return false
        }
        return result
    }

    @MainActor
    private func assertAtEnd(_ view: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        guard let clip = view.enclosingScrollView?.contentView else { XCTFail("Missing scroll view", file: file, line: line); return }
        var down = clip.bounds
        down.origin.y += 1
        XCTAssertEqual(clip.constrainBoundsRect(down).minY, clip.bounds.minY, accuracy: 0.5, file: file, line: line)
    }

    @MainActor
    private func close(_ window: NSWindow) {
        window.makeFirstResponder(nil); window.contentView = nil; window.close()
    }
}
#endif
