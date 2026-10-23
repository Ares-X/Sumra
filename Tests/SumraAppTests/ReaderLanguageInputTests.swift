#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderLanguageInputTests: XCTestCase {
    func testFindCompositionSurvivesViewUpdatesAndCommitsMultilingualQuery() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        var closes = 0
        let host = NSHostingView(rootView: ReaderFindInput(state: state, floating: false, close: { closes += 1 })
            .frame(width: 280, height: 28))
        let window = makeWindow(content: host)
        defer { state.windowClosed(); close(window) }
        try await settle(host) { state.findInputField?.window === window }
        let field = try XCTUnwrap(state.findInputField as? ReaderFindInput.Field)
        field.selectText(nil)
        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let delegate = try XCTUnwrap(field.delegate as? ReaderFindInput.Coordinator)
        let draft = "にほん"
        input.setMarkedText(draft, selectedRange: NSRange(location: draft.utf16.count, length: 0),
                            replacementRange: input.selectedRange())
        XCTAssertTrue(input.hasMarkedText())
        let revision = state.command.revision
        XCTAssertFalse(delegate.control(field, textView: input, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(delegate.control(field, textView: input, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(state.command.revision, revision, "Candidate confirmation must not run Find Next")
        XCTAssertEqual(closes, 0, "Candidate cancellation must not close Find")
        state.status = "Composition update"
        try await Task.sleep(nanoseconds: 30_000_000)
        try await settle(host) { field.placeholderString == L("Find in document") }
        XCTAssertTrue(input.hasMarkedText())
        XCTAssertEqual(input.string, draft)

        let query = "日本語 中文 한국어 العربية עברית e\u{301} 👩🏽‍💻"
        input.insertText(query, replacementRange: input.markedRange())
        XCTAssertFalse(input.hasMarkedText())
        try await settle(host) { state.findQuery == query }
        XCTAssertEqual(field.stringValue, query)
        XCTAssertTrue(delegate.control(field, textView: input, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertGreaterThan(state.command.revision, revision)
        XCTAssertTrue(delegate.control(field, textView: input, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(window.isVisible)
    }

    func testContentsSearchKeepsCompositionThenAcceptsCommittedQuery() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let host = NSHostingView(rootView: ContentsSearchInput(state: state).frame(width: 280, height: 28))
        let window = makeWindow(content: host)
        defer { state.windowClosed(); close(window) }
        try await settle(host) { state.contentsSearchField?.window === window }
        let field = try XCTUnwrap(state.contentsSearchField)
        field.selectText(nil)
        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let delegate = try XCTUnwrap(field.delegate as? ContentsSearchInput.Coordinator)
        input.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: input.selectedRange())
        XCTAssertTrue(input.hasMarkedText())
        XCTAssertFalse(delegate.control(field, textView: input, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(delegate.control(field, textView: input, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        let draftQuery = state.contentsQuery
        state.status = "Composition update"
        try await Task.sleep(nanoseconds: 30_000_000)
        try await settle(host) { field.placeholderString == L("Search Contents") }
        XCTAssertTrue(input.hasMarkedText())
        XCTAssertEqual(input.string, "zhong")
        XCTAssertEqual(state.contentsQuery, draftQuery)
        let query = "中文 العربية עברית"
        input.insertText(query, replacementRange: input.markedRange())
        // NSSearchField's action is the boundary used by the native search cell.
        XCTAssertTrue(field.sendAction(try XCTUnwrap(field.action), to: field.target))
        XCTAssertFalse(input.hasMarkedText())
        XCTAssertEqual(state.contentsQuery, query)
        XCTAssertTrue(delegate.control(field, textView: input, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(state.contentsQuery, "")
        XCTAssertFalse(window.isVisible)
    }

    func testThemeNameCompositionCommitsAndRoundTripsUnicodeLiterally() throws {
        _ = NSApplication.shared
        let editor = ReaderThemeEditorView(theme: ReaderTheme.builtins[0])
        let window = makeWindow(content: editor)
        defer { close(window) }
        editor.name.selectText(nil)
        let input = try XCTUnwrap(editor.name.currentEditor() as? NSTextView)
        input.setMarkedText("han", selectedRange: NSRange(location: 3, length: 0), replacementRange: input.selectedRange())
        XCTAssertTrue(input.hasMarkedText())
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(input.string, "han")
        XCTAssertTrue(input.hasMarkedText())
        let name = "한글 日本語 中文 — العربية עברית — e\u{301} 👩🏽‍💻"
        input.insertText(name, replacementRange: input.markedRange())
        XCTAssertFalse(input.hasMarkedText())
        window.makeFirstResponder(nil)
        XCTAssertEqual(editor.name.stringValue, name)
        XCTAssertTrue(editor.isValid)
        let suite = "Sumra.ReaderLanguageInputTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let theme = ReaderTheme.makeCustom(name: editor.name.stringValue, text: 0, background: 0xffffff, link: 0x123456)
        try ReaderTheme.saveCustom(theme, defaults: defaults)
        XCTAssertEqual(ReaderTheme.custom(defaults: defaults).first?.displayName, name)
        XCTAssertEqual(ReaderTheme.custom(defaults: defaults).first?.name.utf8.map { $0 }, name.utf8.map { $0 },
                       "Saving a user name must preserve its original Unicode representation")
        XCTAssertFalse(window.isVisible)
    }

    func testLanguageMirrorsHostedControlsIndependentlyOfDocumentReadingDirection() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let savedLanguage = defaults.object(forKey: "language")
        defer { defaults.set(savedLanguage, forKey: "language") }
        let state = ReaderState(recordsHistory: false)
        let first = LayoutMarker(), second = LayoutMarker()
        let host = NSHostingView(rootView: HStack(spacing: 20) {
            HostedLayoutMarker(marker: first).frame(width: 30, height: 24)
            HostedLayoutMarker(marker: second).frame(width: 30, height: 24)
        }.modifier(ReaderLanguage()))
        let window = makeWindow(content: host)
        defer { state.windowClosed(); close(window) }
        for readingRTL in [false, true] {
            state.rtl = readingRTL
            for language in ["en", "ar", "he", "ja"] {
                defaults.set(language, forKey: "language")
                let rtl = language == "ar" || language == "he"
                let direction: LayoutDirection = rtl ? .rightToLeft : .leftToRight
                try await settle(host) {
                    first.direction == direction && first.window === window && second.window === window &&
                        (first.convert(first.bounds, to: host).midX > second.convert(second.bounds, to: host).midX) == rtl
                }
                XCTAssertEqual(first.direction, direction, language)
                XCTAssertEqual(second.direction, direction, language)
                XCTAssertEqual(state.rtl, readingRTL, "UI language must leave document reading direction unchanged")
            }
        }
        XCTAssertFalse(window.isVisible)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 260),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func close(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }

    private func settle(_ host: NSView, _ ready: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTFail("Hosted input or layout did not settle", file: file, line: line)
        throw CancellationError()
    }
}

@MainActor
private final class LayoutMarker: NSView {
    var direction: LayoutDirection?
}

@MainActor
private struct HostedLayoutMarker: NSViewRepresentable {
    let marker: LayoutMarker
    func makeNSView(context: Context) -> LayoutMarker { marker }
    func updateNSView(_ view: LayoutMarker, context: Context) { view.direction = context.environment.layoutDirection }
}
#endif
