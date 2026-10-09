#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

final class ContentsSearchTests: XCTestCase {
    @MainActor
    private func settle(_ window: NSWindow) async {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    @MainActor
    private func makeWindow(_ state: ReaderState) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentsTree(state: state))
        return window
    }

    @MainActor
    private func titles(_ tree: NSOutlineView) -> [String] {
        (0..<tree.numberOfRows).compactMap { (tree.item(atRow: $0) as? NativeContentsTree.Node)?.title }
    }

    @MainActor
    func testSearchContentsCommandRevealsSidebarAndFocusesExistingQueryWithoutNavigation() async throws {
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/contents-command.txt"), content: .text("chapter"))
        state.outline = [.init(title: "第一章", target: "#page=1")]
        state.contentsQuery = "章"
        state.showBookmarks = true
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        let field = try XCTUnwrap(state.contentsSearchField)
        XCTAssertNil(field.currentEditor(), "Showing Contents normally must not steal reader focus")
        let revision = state.command.revision
        XCTAssertTrue(ReaderMenuCommand.contentsSearch.enabled(state))
        ReaderMenuCommand.contentsSearch.run(state)
        await settle(window)
        XCTAssertTrue(state.showContents)
        XCTAssertFalse(state.showBookmarks)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "章")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertEqual(state.command.revision, revision)
        window.makeFirstResponder(state.contentsFocusView)
        ReaderMenuCommand.contentsSearch.run(state)
        XCTAssertTrue(window.firstResponder === editor, "The command must focus search even when Contents is already open")
        state.presentation = true
        XCTAssertFalse(ReaderMenuCommand.contentsSearch.enabled(state))
        XCTAssertFalse(ReaderMenuCommand.contentsSearch.enabled(nil))
    }

    @MainActor
    func testSearchContentsRequestSurvivesInitialMountAndCancelsWhenSidebarCloses() async throws {
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/contents-command.txt"), content: .text("chapter"))
        state.outline = [.init(title: "Chapter", target: "#page=1")]
        state.contentsQuery = "Chap"
        ReaderMenuCommand.contentsSearch.run(state)
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        let field = try XCTUnwrap(state.contentsSearchField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Chap")
        window.makeFirstResponder(nil)
        window.contentView = nil
        await settle(window)
        XCTAssertNil(state.contentsSearchField)
        ReaderMenuCommand.contentsSearch.run(state)
        state.closeSidebar()
        state.showContents = true
        window.contentView = NSHostingView(rootView: ContentsTree(state: state))
        await settle(window)
        XCTAssertNil(try XCTUnwrap(state.contentsSearchField).currentEditor(), "A cancelled search request must not steal focus when Contents reopens")
    }

    @MainActor
    func testContentsSearchRevealsMatchesWithAncestorsAndRestoresCollapsedState() async throws {
        let state = ReaderState(recordsHistory: false)
        state.followContents = false
        state.outline = [.init(title: "Guide", target: ""),
                         .init(title: "Introduction", target: "#page=1", depth: 1),
                         .init(title: "Café example", target: "#page=3", depth: 2),
                         .init(title: "Unrelated", target: "#page=4", depth: 2),
                         .init(title: "Appendix", target: "#page=8")]
        state.collapsedContents = [0, 1]
        state.selectedContents = 4
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        let tree = try XCTUnwrap(state.contentsFocusView)
        XCTAssertEqual(titles(tree), ["Guide", "Appendix"])
        let revision = state.command.revision
        state.contentsQuery = " CAFE "
        await settle(window)
        XCTAssertEqual(titles(tree), ["Guide", "Introduction", "Café example"])
        XCTAssertEqual(state.collapsedContents, [0, 1])
        XCTAssertEqual(state.selectedContents, 4, "Filtering must preserve a hidden selection")
        XCTAssertEqual(tree.selectedRow, -1)
        XCTAssertEqual(state.command.revision, revision, "Typing must not navigate")

        tree.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(state.selectedContents, 2, "Filtered rows must retain the original destination index")
        XCTAssertEqual(state.command.action, .href("#page=3"))
        state.didHandleCommand(state.command.revision)
        let activatedRevision = state.command.revision
        state.contentsQuery = ""
        await settle(window)
        XCTAssertEqual(titles(tree), ["Guide", "Appendix"])
        XCTAssertEqual(state.collapsedContents, [0, 1])
        XCTAssertEqual(state.selectedContents, 2)
        XCTAssertEqual(state.command.revision, activatedRevision)
    }

    @MainActor
    func testContentsSearchHandlesNoResultsOutlineReplacementAndDocumentClose() async throws {
        let state = ReaderState(recordsHistory: false)
        state.followContents = false
        state.outline = [.init(title: "性能优化", target: "#page=2")]
        state.contentsQuery = "missing"
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        let tree = try XCTUnwrap(state.contentsFocusView)
        let coordinator = try XCTUnwrap(tree.delegate as? NativeContentsTree.Coordinator)
        XCTAssertEqual(tree.numberOfRows, 0)
        XCTAssertEqual(coordinator.emptyLabel?.isHidden, false)
        XCTAssertFalse(coordinator.emptyLabel?.stringValue.isEmpty ?? true)
        XCTAssertFalse(coordinator.focusSearchResult(tree))
        let revision = state.command.revision
        state.outline = [.init(title: "Missing chapter", target: "#page=7")]
        await settle(window)
        XCTAssertEqual(titles(tree), ["Missing chapter"])
        XCTAssertEqual(coordinator.emptyLabel?.isHidden, true)
        XCTAssertEqual(coordinator.emptyLabel?.stringValue, "", "A matching tree must not expose a stale no-results message")
        XCTAssertEqual(state.command.revision, revision)
        state.contentsQuery = "章"
        await settle(window)
        XCTAssertEqual(tree.numberOfRows, 0)
        state.outline = [.init(title: "第一章", target: "#page=1")]
        await settle(window)
        XCTAssertEqual(titles(tree), ["第一章"])
        state.windowClosed()
        XCTAssertEqual(state.contentsQuery, "")
    }

    @MainActor
    func testContentsSearchKeyboardActivationSkipsContextParentsAndProtectsExternalTargets() async throws {
        let state = ReaderState(recordsHistory: false)
        state.followContents = false
        state.outline = [.init(title: "Context", target: "#page=1"),
                         .init(title: "Match chapter", target: "#page=3", depth: 1),
                         .init(title: "Match website", target: "https://example.invalid", depth: 1)]
        state.contentsQuery = "match"
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        let tree = try XCTUnwrap(state.contentsFocusView)
        let coordinator = try XCTUnwrap(tree.delegate as? NativeContentsTree.Coordinator)
        XCTAssertTrue(coordinator.focusSearchResult(tree))
        XCTAssertTrue(window.firstResponder === tree)
        XCTAssertEqual(state.selectedContents, 1)
        XCTAssertEqual(state.command.action, .href("#page=3"))
        let revision = state.command.revision
        state.didHandleCommand(revision)
        state.contentsQuery = "website"
        await settle(window)
        XCTAssertTrue(coordinator.focusSearchResult(tree))
        XCTAssertEqual(state.selectedContents, 2)
        XCTAssertEqual(state.command.revision, revision, "Search keyboard activation must not open an external website")
    }

    @MainActor
    func testSearchingWithPageFollowingPreservesExpansionAndDisablesCollapseMenus() async throws {
        let state = ReaderState(recordsHistory: false)
        state.outline = [.init(title: "Guide", target: "#page=1", page: 0),
                         .init(title: "Match chapter", target: "#page=3", depth: 1, page: 2)]
        state.collapsedContents = [0]
        state.contentsQuery = "match"
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        let tree = try XCTUnwrap(state.contentsFocusView)
        let coordinator = try XCTUnwrap(tree.delegate as? NativeContentsTree.Coordinator)
        XCTAssertTrue(state.followContents)
        state.page = 2
        await settle(window)
        XCTAssertEqual(titles(tree), ["Guide", "Match chapter"])
        XCTAssertEqual(state.collapsedContents, [0], "Automatic page following must not change expansion during search")
        let menu = try XCTUnwrap(tree.menu)
        coordinator.menuNeedsUpdate(menu)
        menu.update()
        XCTAssertEqual(menu.items.map(\.isEnabled), [false, false, false, true])
        state.contentsQuery = ""
        await settle(window)
        XCTAssertEqual(titles(tree), ["Guide"])
        XCTAssertEqual(state.collapsedContents, [0])
        coordinator.menuNeedsUpdate(menu)
        menu.update()
        XCTAssertTrue(menu.items.allSatisfy(\.isEnabled))
    }

    @MainActor
    func testNativeSearchCancelButtonClearsFilterAndRestoresCollapsedTree() async throws {
        let state = ReaderState(recordsHistory: false)
        state.followContents = false
        state.outline = [.init(title: "Group", target: ""),
                         .init(title: "Match", target: "#page=3", depth: 1)]
        state.collapsedContents = [0]
        state.contentsQuery = "match"
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: try XCTUnwrap(window.contentView)))
        let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
        let cancel = try XCTUnwrap(cell.cancelButtonCell)
        let tree = try XCTUnwrap(state.contentsFocusView)
        XCTAssertEqual(field.stringValue, "match")
        XCTAssertEqual(titles(tree), ["Group", "Match"])
        cancel.performClick(field)
        XCTAssertEqual(field.stringValue, "", "AppKit must execute the actual search cancel action")
        await settle(window)
        XCTAssertEqual(state.contentsQuery, "")
        XCTAssertEqual(titles(tree), ["Group"])
        XCTAssertEqual(state.collapsedContents, [0])
        XCTAssertEqual(state.command.action, .none)
    }

    @MainActor
    func testSearchKeyboardCommandsDoNotConsumeMarkedTextAndCommittedReturnActivatesMatch() async throws {
        let state = ReaderState(recordsHistory: false)
        state.followContents = false
        state.outline = [.init(title: "Context", target: "#page=1"),
                         .init(title: "Matching chapter", target: "#page=3", depth: 1)]
        state.contentsQuery = "match"
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)

        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        let coordinator = try XCTUnwrap(field.delegate as? ContentsSearchInput.Coordinator)
        let tree = try XCTUnwrap(state.contentsFocusView as? NativeContentsTree.OutlineView)
        let revision = state.command.revision
        state.selectedContents = 0

        editor.setMarkedText("章节", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)),
                         #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: selector))
            XCTAssertTrue(editor.hasMarkedText(), "A navigation or cancel command must remain available to the text input system during composition")
            XCTAssertEqual(state.contentsQuery, "match")
            XCTAssertEqual(state.selectedContents, 0)
            XCTAssertEqual(state.command.revision, revision)
        }

        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        editor.insertText("match", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertFalse(editor.hasMarkedText())
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(state.contentsQuery, "match")
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(state.selectedContents, 1)
        XCTAssertEqual(state.command.action, .href("#page=3"))
        XCTAssertEqual(state.command.revision, revision + 1)
        XCTAssertEqual(tree.selectedRow, 1)
    }

    @MainActor
    func testNoMatchingChapterMessageHasReadableLayout() async throws {
        let state = ReaderState(recordsHistory: false)
        state.outline = [.init(title: "Guide", target: "#page=1")]
        state.contentsQuery = "absent"
        let window = makeWindow(state)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        await settle(window)
        let tree = try XCTUnwrap(state.contentsFocusView)
        let coordinator = try XCTUnwrap(tree.delegate as? NativeContentsTree.Coordinator)
        let label = try XCTUnwrap(coordinator.emptyLabel)
        XCTAssertFalse(label.isHidden)
        XCTAssertGreaterThan(label.frame.width, 80, "A wrapping empty-state message needs readable width")
        XCTAssertGreaterThan(label.frame.height, 0)
        let parent = try XCTUnwrap(label.superview)
        XCTAssertTrue(parent.bounds.contains(label.frame))
        window.setContentSize(NSSize(width: 140, height: 320))
        await settle(window)
        XCTAssertGreaterThan(label.frame.width, 80)
        XCTAssertTrue(parent.bounds.contains(label.frame), "The message must remain visible after sidebar resizing")
    }
}
#endif
