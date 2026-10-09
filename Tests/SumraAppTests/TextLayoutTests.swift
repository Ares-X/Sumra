#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import SumraCore
@testable import Sumra

final class TextLayoutTests: XCTestCase {
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
        XCTAssertFalse(lastState.canGoForward, "The logical Next command must not return to the start of the final paragraph")
        let (againWindow, againHost, _, again) = try await makeReader(text, withDocument: true, position: saved)
        defer { close(againWindow) }
        await settle(againHost)
        XCTAssertEqual(again.location.anchor, saved.anchor)
        XCTAssertEqual(again.location.y ?? 0, saved.y ?? 0, accuracy: 0.5)
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
        let offsets = ChapterDetector.lineOffsets(text)
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
        if let view = host.rootView.state.readerFocusView as? NSTextView, view.visibleRect.width > 0, view.visibleRect.height > 0 {
            view.layoutSubtreeIfNeeded()
            autoreleasepool {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) { view.cacheDisplay(in: view.visibleRect, to: bitmap) }
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
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
