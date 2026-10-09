#if os(macOS)
import XCTest
import Combine
import CoreText
import SwiftUI
import PDFKit
import SumraCore
@testable import Sumra

final class ReaderNavigationTests: XCTestCase {
    @MainActor
    func testFixedMarkupLinksKeepTheirFileAndFragmentDestinations() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "useFixedPageUI")
        defaults.set(true, forKey: "useFixedPageUI")
        defer { defaults.set(previous, forKey: "useFixedPageUI") }
        for suffix in ["md", "html"] {
            let directory = try TemporaryDirectory()
            let source = directory.url.appendingPathComponent("source." + suffix)
            let destination = directory.url.appendingPathComponent("Other #Book." + suffix)
            let filler = (1...60).map { "Paragraph \($0): fixed page navigation preserves the reading destination.\n\n" }.joined()
            let fragment = suffix == "html" ? "#literal%2520id" : "#late%2Dtarget"
            let sibling = "Other%20%23Book." + suffix + fragment
            if suffix == "md" {
                try "# Source\n\n[Sibling](\(sibling))\n\n[Self](source.md#local)\n\n## Late target\n\n\(filler)\n## Local\n".write(to: source, atomically: true, encoding: .utf8)
                try "# Destination\n\n\(filler)\n## Late target\n\nDestinationTailMarker\n".write(to: destination, atomically: true, encoding: .utf8)
            } else {
                let paragraphs = filler.components(separatedBy: "\n\n").map { "<p>\($0)</p>" }.joined()
                try "<h1>Source</h1><a href='\(sibling)'>Sibling</a><a href='source.html#local'>Self</a><h2 id='literal%20id'>Late target</h2>\(paragraphs)<h2 id='local'>Local</h2>".write(to: source, atomically: true, encoding: .utf8)
                try "<h1>Destination</h1>\(paragraphs)<h2 id='literal%20id'>Late target</h2><p>DestinationTailMarker</p>".write(to: destination, atomically: true, encoding: .utf8)
            }
            let state = ReaderState(recordsHistory: false)
            state.document = try ReadingDocument.open(source)
            state.document?.sourceTemporary = directory
            state.flow = "paged"; state.fit = "page"; state.spread = false; state.automaticLayout = false
            state.fontSize = 17; state.lineHeight = 1.6; state.font = "system"
            guard case .pages(let pages) = state.document?.content else { return XCTFail("Expected fixed markup") }
            let rooted = await pages.fileTarget("/" + sibling, relativeTo: source)
            XCTAssertEqual(rooted?.url, destination, "Markup root-relative links follow the book directory")
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReaderView(state: state))
            defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
            func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    window.contentView?.layoutSubtreeIfNeeded()
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline && state.error == nil
                XCTAssertTrue(condition(), state.error ?? "Markup navigation did not finish", line: line)
            }
            try await waitFor { state.count > 2 }
            let links = try await pages.links(0)
            let siblingLink = try XCTUnwrap(links.first { $0.uri.contains("Other") })
            XCTAssertEqual(siblingLink.uri, sibling, "Encoded filename delimiters must survive native link extraction")
            let selfLink = try XCTUnwrap(links.first { $0.uri.contains("source.") })
            let identity = state.document?.id
            state.navigate(.href(selfLink.uri))
            try await waitFor { state.page > 0 }
            XCTAssertEqual(state.document?.id, identity, "A current-file fragment must not reopen the document")
            let localPage = state.page
            state.navigate(.href("source." + suffix + "#missing"))
            state.send(.none)
            try await waitFor { state.command.action == .none && !state.busy && state.count > 2 }
            XCTAssertEqual(state.document?.id, identity, "An unresolved current-file fragment must not reload the document")
            XCTAssertEqual(state.page, localPage)
            state.navigate(.href(siblingLink.uri))
            try await waitFor { state.document?.url == destination && state.page > 0 }
            XCTAssertNotEqual(state.document?.id, identity)
            XCTAssertFalse(state.recordsDocumentHistory)
            XCTAssertTrue(state.document?.sourceTemporary === directory)
            guard case .pages(let opened) = state.document?.content else { return XCTFail("Destination must retain fixed mode") }
            let text = try await opened.text(state.pageLocation(state.page))
            XCTAssertTrue(text.contains("Late target"), "The destination must follow its heading across a page break")
            if suffix == "html" {
                let outlined = try await opened.resolve("#literal%20id")
                XCTAssertEqual(outlined?.page, state.page, "Native outline IDs are already decoded and must retain literal percent escapes")
            }
            XCTAssertNil(state.error)
        }
    }

    @MainActor
    func testRasterCommandQueuedBeforeMountExecutesOnceAcrossRemount() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture()
        let pages = try XCTUnwrap(state.nativePDF)
        state.count = 1; state.flow = "paged"; state.fit = "page"
        state.spread = false; state.automaticLayout = false
        let clipboard = NativePDFClipboard.current
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            NativePDFClipboard.current = clipboard
            if let path = state.document?.url.path { UserDefaults.standard.removeObject(forKey: "position:" + path) }
            state.windowClosed(); window.contentView = nil; window.close()
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                window.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertTrue(condition(), state.error ?? "Reader command did not complete", line: line)
        }
        state.setPDFEditingEnabled(true)
        try await waitFor { state.pdfEditingEnabled }
        let id = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
            bounds: CGRect(x: 20, y: 30, width: 40, height: 50))
        let original = try await pages.pdfAnnotations(0)
        state.nativePDFSelection = .annotation(page: 0, try XCTUnwrap(original.first { $0.id == id }))
        _ = try await NativePDFClipboard.copy(state: state, pages: pages, cut: false)

        // A command issued before the reader subscribes must still execute.
        state.send(.annotate("paste", at: .init(page: 0, x: 100, y: 100)))
        state.send(.none)
        window.contentView = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        try await waitFor { state.command.action == .none }
        var annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.count, 2)

        // Keep a mutating command as the published value, then recreate the
        // subscriber. Its current-value delivery must not paste a second time.
        state.send(.annotate("paste", at: .init(page: 0, x: 150, y: 150)))
        let deadline = Date().addingTimeInterval(5)
        repeat {
            annotations = try await pages.pdfAnnotations(0)
            if annotations.count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTAssertEqual(annotations.count, 3)
        window.contentView = nil
        window.contentView = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        // Let the replacement subscribe before submitting the drain marker.
        try await waitFor { state.readerFocusView?.window === window }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        state.send(.none)
        try await waitFor { state.command.action == .none }
        annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.count, 3, "Resubscribing must never repeat a PDF edit")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSwitchingFindPresentationKeepsReaderSearchCommandsAlive() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("find-panel.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &box, nil))
        for text in ["FIRST PRINT PAGE", "SECOND PRINT PAGE"] {
            writer.beginPDFPage(nil); writer.textPosition = CGPoint(x: 20, y: 350)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 18)])), writer)
            writer.endPDFPage()
        }
        writer.closePDF()
        let pages = try Pages(input, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.flow = "paged"; state.fit = "page"; state.spread = false; state.automaticLayout = false
        let defaults = UserDefaults.standard, oldFloating = defaults.object(forKey: "findFloating")
        defaults.set(false, forKey: "findFloating")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 865, height: 512),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.isReleasedWhenClosed = false; state.window = window; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            state.closeFind(); state.windowClosed(); window.contentView = nil; window.close()
            defaults.set(oldFloating, forKey: "findFloating")
            defaults.removeObject(forKey: "position:" + input.path)
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil,
                "Find transition failed: \(state.command), query=\(state.findQuery), results=\(state.searchResults.count), parent=\(window.isMainWindow)/\(window.isKeyWindow), panel=\(state.findWindow != nil), editor=\(state.findInputField?.currentEditor() != nil), error=\(state.error ?? "none")", line: line)
        }
        try await waitFor { state.count == 2 && state.readerFocusView != nil }
        for (floating, query, count) in [(false, "SECOND", 1), (true, "PRINT", 2), (false, "FIRST", 1)] {
            defaults.set(floating, forKey: "findFloating")
            state.showFindPanel()
            // Exercise the reader's structural transition and command owner.
            // NSPanel activation and native typing are separate GUI checks.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            state.updateFindQuery(query)
            state.findNext(inResults: floating)
            try await waitFor { !state.searchCounting && state.searchResults.count == count }
            XCTAssertEqual(state.findQuery, query)
        }
    }

    @MainActor
    func testFindInputFocusesOnMountAndReselectsWithoutRestartingSearch() async throws {
        _ = NSApplication.shared
        for floating in [false, true] {
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/find-input.txt"), content: .text("first second"))
            state.findQuery = "first"
            state.showFindPanel()
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 80),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ReaderFindInput(state: state, floating: floating,
                close: { state.closeFind(); window.makeFirstResponder(nil) }).frame(width: 250, height: 24))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.makeFirstResponder(nil); window.contentView = nil; window.close(); state.windowClosed() }
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if state.findInputField?.currentEditor() != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let field = try XCTUnwrap(state.findInputField)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertTrue(window.firstResponder === editor, "Opening Find must focus the mounted edit control")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 5))
            XCTAssertEqual(state.command.action, .none, "Opening Find must not restart a previous search")
            editor.insertText("second", replacementRange: editor.selectedRange())
            XCTAssertEqual(state.findQuery, "second")
            XCTAssertEqual(state.command.action, .toc, "Replacing a query clears the old reader selection")
            state.didHandleCommand(state.command.revision)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            guard case .find(let query, let backwards, _, let selection, let inResults) = state.command.action else {
                XCTFail("Return must submit the entered query"); continue
            }
            XCTAssertEqual(query, "second")
            XCTAssertFalse(backwards)
            XCTAssertFalse(selection)
            XCTAssertEqual(inResults, floating)
            state.didHandleCommand(state.command.revision)
            let searchRevision = state.command.revision

            window.makeFirstResponder(nil)
            XCTAssertNil(field.currentEditor())
            state.showFindPanel()
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if field.currentEditor() != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let repeated = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertEqual(repeated.string, "second")
            XCTAssertEqual(repeated.selectedRange(), NSRange(location: 0, length: 6))
            XCTAssertEqual(state.command.revision, searchRevision)
            repeated.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertFalse(state.showFind)
            XCTAssertNil(field.currentEditor())
        }
    }

    @MainActor
    func testScrollingWithinAPageKeepsPositionWithoutRefreshingReaderChrome() {
        let state = ReaderState()
        state.updatePosition(.init(page: 4, y: 0))
        var updates = 0
        let observer = state.objectWillChange.sink { updates += 1 }
        defer { withExtendedLifetime(observer) {} }
        for y in 1...100 { state.updatePosition(.init(page: 4, y: Double(y))) }
        XCTAssertEqual(state.currentPosition.y, 100)
        XCTAssertEqual(updates, 0)
        state.updatePosition(.init(page: 5, y: 0))
        XCTAssertEqual(state.page, 5)
        XCTAssertEqual(updates, 1)
    }

    @MainActor
    func testCurrentContentsFindsNearestPageInAnUnorderedOutline() {
        let state = ReaderState()
        XCTAssertNil(state.currentContentsIndex)
        state.outline = [.init(title: "Part", target: "part.xhtml", page: 0),
                         .init(title: "Later", target: "later.xhtml", depth: 1, page: 12),
                         .init(title: "Earlier group", target: "earlier.xhtml", page: 3),
                         .init(title: "Same page", target: "same.xhtml", depth: 1, page: 12)]
        state.page = 15
        XCTAssertEqual(state.currentContentsIndex, 3)
        state.page = 12
        XCTAssertEqual(state.currentContentsIndex, 1)
        state.page = 8
        XCTAssertEqual(state.currentContentsIndex, 2)
        state.page = 0
        XCTAssertEqual(state.currentContentsIndex, 0)
    }

    @MainActor
    func testContentsKeyboardSelectsGroupsAndExternalLinksWithoutOpeningThem() throws {
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture()
        defer { state.windowClosed() }
        state.outline = [.init(title: "Group", target: ""),
                         .init(title: "Website", target: "https://example.com"),
                         .init(title: "Other PDF", target: "other.pdf#page=1"),
                         .init(title: "Local page", target: "#page=1", page: 0)]
        for index in 0..<3 {
            state.activateContents(index, allowExternal: false)
            XCTAssertEqual(state.selectedContents, index)
            XCTAssertEqual(state.command.action, .none)
        }
        state.activateContents(3, allowExternal: false)
        XCTAssertEqual(state.command.action, .href("#page=1"))
        let clicked = ReaderState(recordsHistory: false)
        clicked.outline = state.outline
        clicked.activateContents(1, allowExternal: true)
        XCTAssertEqual(clicked.command.action, .href("https://example.com"))
    }

    @MainActor
    func testContentsRemotePDFOpensRelativeFileAtDestinationAndKeepsCommandsWorking() async throws {
        _ = NSApplication.shared
        let source = try nativePDFReadingFixture(), target = try nativePDFReadingFixture(pageCount: 3)
        let directory = try XCTUnwrap(source.temporary)
        let destination = directory.url.appendingPathComponent("Other Book.pdf")
        try FileManager.default.copyItem(at: target.url, to: destination)
        let state = ReaderState(recordsHistory: false)
        state.document = source
        state.flow = "paged"; state.fit = "page"; state.spread = false; state.automaticLayout = false
        state.showContents = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReaderView(state: state))
        window.makeKeyAndOrderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime((source, target)) {} }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                window.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertTrue(condition(), state.error ?? "Contents navigation did not finish", line: line)
        }
        try await waitFor { state.count == 1 }
        state.outline = [.init(title: "Other book", target: "file:Other%20Book.pdf#page=2&view=Fit")]
        try await waitFor { state.contentsFocusView?.window === window }
        XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(state.contentsFocusView)))
        state.activateContents(0, allowExternal: true)
        try await waitFor { state.document?.url == destination && state.count == 3 && state.page == 1 }
        XCTAssertFalse(state.recordsDocumentHistory)
        XCTAssertTrue(state.document?.sourceTemporary === directory, "Remote files extracted with the source must keep their lease")
        try await waitFor {
            guard let view = state.readerFocusView, view.window === window, let pages = state.nativePDF else { return false }
            return state.contentsFocusView == nil && RasterReader.pageIsRendered(in: view, pages: pages, location: .init(page: 1))
        }
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f703}",
            charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
        window.sendEvent(right)
        try await waitFor { state.page == 2 }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeContentsHierarchyAndProgrammaticUpdatesDoNotReplayNavigation() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.outline = [.init(title: "Group", target: ""),
                         .init(title: "Child", target: "#page=2", depth: 1, page: 1),
                         .init(title: "Website", target: "https://example.invalid"),
                         .init(title: "Last", target: "#page=4", page: 3)]
        state.collapsedContents = [0]; state.selectedContents = 0
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NativeContentsTree(state: state))
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        func settle() async {
            for _ in 0..<3 {
                window.contentView?.layoutSubtreeIfNeeded()
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }
        await settle()
        let tree = try XCTUnwrap(state.contentsFocusView)
        XCTAssertTrue(window.makeFirstResponder(tree))
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            tree.keyDown(with: event)
        }
        XCTAssertEqual(tree.numberOfRows, 3)
        try key(124, "\u{f703}") // Right expands an empty-target group without navigating.
        await settle()
        XCTAssertEqual(tree.numberOfRows, 4)
        XCTAssertFalse(state.collapsedContents.contains(0))
        XCTAssertEqual(state.command.action, .none)
        try key(124, "\u{f703}") // AppKit keeps an expanded row selected.
        await settle()
        XCTAssertEqual(state.selectedContents, 0)
        XCTAssertEqual(state.command.action, .none)
        try key(125, "\u{f701}") // Down enters its local child.
        await settle()
        XCTAssertEqual(state.selectedContents, 1)
        XCTAssertEqual(state.command.action, .href("#page=2"))
        let revision = state.command.revision
        state.didHandleCommand(revision)
        await settle()
        try key(125, "\u{f701}") // Keyboard selection must not open the website.
        await settle()
        XCTAssertEqual(state.selectedContents, 2)
        XCTAssertEqual(state.command.revision, revision)

        tree.deselectAll(nil)
        XCTAssertNil(state.selectedContents)
        state.page = 2
        await settle()
        XCTAssertEqual(tree.selectedRow, -1, "An unrelated update must not restore a cleared selection")

        state.selectedContents = 1 // Page-follow and resolved page metadata are not user activation.
        state.outline[1].page = 2
        await settle()
        XCTAssertEqual(tree.selectedRow, 1)
        XCTAssertEqual(state.command.revision, revision)
        try key(123, "\u{f702}") // Left selects the parent; Left again collapses it.
        await settle()
        XCTAssertEqual(state.selectedContents, 0)
        try key(123, "\u{f702}")
        await settle()
        XCTAssertEqual(tree.numberOfRows, 3)
        XCTAssertTrue(state.collapsedContents.contains(0))
        XCTAssertEqual(state.command.revision, revision)

        state.outline = [.init(title: "Replacement", target: "#page=1")]
        await settle()
        XCTAssertEqual(tree.numberOfRows, 1)
        XCTAssertEqual(tree.selectedRow, -1)
        XCTAssertEqual(state.command.revision, revision, "Replacing the document outline must not navigate")
    }

    @MainActor
    func testContentsFocusCycleReturnsToTheNativeTreeAfterReaderFocus() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture()
        state.showContents = true; state.followContents = false
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window
        window.contentView = NSHostingView(rootView: ReaderView(state: state))
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func settle() async {
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while state.count == 0 && Date() < deadline {
            await settle()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        state.outline = [.init(title: "Group", target: ""), .init(title: "Page", target: "#page=1", depth: 1)]
        await settle()
        let tree = try XCTUnwrap(state.contentsFocusView), reader = try XCTUnwrap(state.readerFocusView)
        window.makeFirstResponder(reader)
        for _ in 0..<2 {
            ReaderMenuCommand.cycleFocus.run(state)
            await settle()
            XCTAssertTrue(window.firstResponder === tree)
            ReaderMenuCommand.cycleFocus.run(state)
            await settle()
            XCTAssertTrue(window.firstResponder === reader)
        }
        state.showContents = false
        await settle()
        XCTAssertNil(state.contentsFocusView)
    }

    @MainActor
    func testResolvingOutlinePagesPreservesTheChosenBranchAndSelection() {
        let state = ReaderState()
        state.outline = [.init(title: "Part", target: "part.xhtml"),
                         .init(title: "Chapter", target: "chapter.xhtml", depth: 1)]
        state.collapsedContents = [0]; state.selectedContents = 0
        var located = state.outline
        located[0].page = 0; located[1].page = 4
        state.outline = located
        XCTAssertEqual(state.collapsedContents, [0])
        XCTAssertEqual(state.selectedContents, 0)
        state.page = 5
        XCTAssertEqual(state.currentContentsIndex, 1)
        state.outline = [.init(title: "Different book", target: "other.xhtml")]
        XCTAssertNil(state.selectedContents)
    }

    @MainActor
    func testFollowingLinesWithinAChapterDoesNotRepublishContentsSelectionOrExpansion() {
        let state = ReaderState()
        state.outline = [.init(title: "Part", target: "0", page: 0),
                         .init(title: "Chapter", target: "10", depth: 1, page: 10),
                         .init(title: "Next part", target: "200", page: 200),
                         .init(title: "Later chapter", target: "210", depth: 1, page: 210)]
        state.collapsedContents = [2]
        state.page = 10; state.revealCurrentContents()
        var selectionUpdates = 0, expansionUpdates = 0
        let selection = state.$selectedContents.dropFirst().sink { _ in selectionUpdates += 1 }
        let expansion = state.$collapsedContents.dropFirst().sink { _ in expansionUpdates += 1 }
        defer { withExtendedLifetime((selection, expansion)) {} }
        for line in 11...100 {
            state.page = line
            state.revealCurrentContents()
        }
        XCTAssertEqual(state.selectedContents, 1)
        XCTAssertEqual(state.collapsedContents, [2])
        XCTAssertEqual(selectionUpdates, 0)
        XCTAssertEqual(expansionUpdates, 0)
        XCTAssertEqual(state.command.action, .none, "Following the reading position must not navigate the document")
    }

    @MainActor
    func testRevealCurrentContentsExpandsOnlyItsAncestorsAndCanRevealAnExistingSelection() {
        let state = ReaderState()
        state.outline = [.init(title: "Part", target: "0", page: 0),
                         .init(title: "Chapter", target: "10", depth: 1, page: 10),
                         .init(title: "Section", target: "20", depth: 2, page: 20),
                         .init(title: "Other part", target: "100", page: 100),
                         .init(title: "Other chapter", target: "110", depth: 1, page: 110)]
        state.page = 25; state.collapsedContents = [0, 1, 3]
        var updates = 0
        let observer = state.$collapsedContents.dropFirst().sink { _ in updates += 1 }
        defer { withExtendedLifetime(observer) {} }
        state.revealCurrentContents()
        XCTAssertEqual(state.selectedContents, 2)
        XCTAssertEqual(state.collapsedContents, [3])
        XCTAssertEqual(updates, 1, "Revealing a nested heading should update its ancestor rows together")
        state.collapsedContents.insert(0)
        XCTAssertTrue(state.collapsedContents.contains(0))
        state.revealCurrentContents()
        XCTAssertEqual(state.selectedContents, 2)
        XCTAssertFalse(state.collapsedContents.contains(0))
        XCTAssertEqual(state.collapsedContents, [3], "Explicit reveal must preserve unrelated collapsed branches")
    }

    @MainActor
    func testGoToPageIsAvailableWithHiddenToolbarAndInPresentation() throws {
        let state = ReaderState()
        XCTAssertFalse(ReaderMenuCommand.goToPage.enabled(state))
        let pdf = PDFDocument()
        for _ in 0..<4 { pdf.insert(PDFPage(), at: pdf.pageCount) }
        state.document = try nativePDFReadingFixture(pdf)
        state.count = 4; state.page = 2
        for (toolbar, presentation) in [(true, false), (false, false), (true, true)] {
            state.toolbarVisible = toolbar; state.presentation = presentation
            XCTAssertTrue(ReaderMenuCommand.goToPage.enabled(state))
        }
        let configured = try ReaderConfiguredCommand.read("""
        [{"name":"Page","command":"goToPage","shortcut":"alt+g"}]
        """)
        XCTAssertEqual(configured.first?.command, .goToPage)
        let toolbar = try ReaderToolbarButton.read("""
        [{"command":"goToPage","text":"Page"}]
        """)
        XCTAssertEqual(toolbar.first?.command, "goToPage")
        for shortcut in readerShortcutBindings(ReaderMenuCommand.goToPage.defaultShortcut) {
            XCTAssertNotNil(readerShortcut(shortcut))
            XCTAssertFalse(ReaderMenuCommand.allCases.filter { $0 != .goToPage }.contains {
                readerShortcutBindings($0.defaultShortcut).contains(shortcut)
            })
        }
    }

    @MainActor
    func testFindHistoryKeepsTenDistinctTrimmedQueriesPerSession() {
        let history = ReaderSearchHistory()
        for index in 0..<12 { history.remember("query \(index)") }
        XCTAssertEqual(history.queries.count, 10)
        XCTAssertEqual(history.queries.last, "query 2")
        history.remember("  query 5 \n")
        XCTAssertEqual(history.queries.first, "query 5")
        XCTAssertEqual(history.queries.filter { $0 == "query 5" }.count, 1)
        history.remember(" \n")
        XCTAssertEqual(history.queries.count, 10)
        XCTAssertTrue(ReaderSearchHistory().queries.isEmpty)
    }

    @MainActor
    func testFixedPageSearchCapturesRangeAndClearDropsCurrentResult() throws {
        let state = ReaderState()
        state.document = try nativePDFReadingFixture(pageCount: 20)
        state.count = 20
        state.setSearchPageRange("3,18-")
        state.send(.find("needle"))
        XCTAssertEqual(state.command.action, .find("needle", options: .init(allowedPages: IndexSet([2, 17, 18, 19]))))
        state.searchResults = [.init(title: "match", target: "pdf-search:0")]
        state.selectedSearchTarget = "pdf-search:0"
        state.searchResults = []
        XCTAssertNil(state.selectedSearchTarget)
        state.reflowable = true
        XCTAssertFalse(state.supportsSearchPageRange)
    }

    @MainActor
    func testSearchResultsListStreamsThousandsAndScrollsUsingResultIdentity() async {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let results = (0..<5_000).map {
            ContentsItem(title: "Page \($0 / 10 + 1): A matching passage containing BPF and surrounding text \($0)",
                         target: "raster-search:\($0 / 10):\($0 % 10)")
        }
        let selectedTarget = results[4_992].target
        state.searchResults = Array(results.suffix(16))
        state.selectedSearchTarget = selectedTarget
        let host = NSHostingView(rootView: ReaderSearchResults(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 440),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil); window.makeFirstResponder(nil)
            window.contentView = nil; window.close(); state.windowClosed()
        }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        func settle(_ stage: String, line: UInt = #line, _ condition: (NSTableView) -> Bool) async -> NSTableView? {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                if let list = table(in: host), condition(list), Date() < deadline { return list }
                do { try await Task.sleep(nanoseconds: 10_000_000) }
                catch { XCTFail("Search results \(stage) wait failed: \(error)", line: line); return nil }
            } while Date() < deadline
            let list = table(in: host)
            let visibleRange = list.map { String(describing: $0.rows(in: $0.visibleRect)) } ?? "no table"
            XCTFail("Search results \(stage) did not settle: rows=\(list?.numberOfRows ?? -1), visibleRange=\(visibleRange), visibleRect=\(String(describing: list?.visibleRect)), hostBounds=\(host.bounds), windowVisible=\(window.isVisible)", line: line)
            return nil
        }
        guard await settle("initial 16 rows with selected result visible", {
            $0.numberOfRows == 16 && NSLocationInRange(8, $0.rows(in: $0.visibleRect))
        }) != nil else { return }
        let started = Date()
        for count in [1_000, 2_000, 3_000, 4_000, 5_000] {
            state.searchResults = Array(results.suffix(count))
            XCTAssertEqual(state.selectedSearchTarget, selectedTarget, "Prepending results must preserve the selected match")
            guard await settle("prepend to \(count) rows with selected result visible", {
                $0.numberOfRows == count && NSLocationInRange(count - 8, $0.rows(in: $0.visibleRect))
            }) != nil else { return }
            XCTAssertEqual(state.selectedSearchTarget, selectedTarget)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "Streaming results must not occupy the UI for the observed minute-long diff")
        state.selectedSearchTarget = results.last?.target
        guard let list = await settle("scroll to last result", { NSLocationInRange(4_999, $0.rows(in: $0.visibleRect)) }) else { return }
        XCTAssertEqual(list.numberOfRows, results.count)
        state.selectedSearchTarget = results.first?.target
        guard await settle("scroll to first result", { NSLocationInRange(0, $0.rows(in: $0.visibleRect)) }) != nil else { return }
        state.searchResults = []
        guard await settle("clear results", { $0.numberOfRows == 0 }) != nil else { return }
        XCTAssertNil(state.selectedSearchTarget)
    }

    @MainActor
    func testFindTypingIsDebouncedButEnterAndClearTakeEffectImmediately() async throws {
        let state = ReaderState()
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/search.txt"), content: .text("needle"))
        state.showFindPanel()
        state.updateFindQuery("needle")
        XCTAssertEqual(state.command.action, .none)
        state.findNext()
        let searched = state.command
        XCTAssertEqual(searched.action, .find("needle", options: .init()))
        state.didHandleCommand(searched.revision)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(state.command.revision, searched.revision, "Enter must cancel the delayed duplicate search")
        state.updateFindQuery("")
        XCTAssertEqual(state.command.action, .find("", options: .init()))
        XCTAssertTrue(state.searchResults.isEmpty)
    }

    @MainActor
    func testDelayedFindCannotSearchAReplacementOrClosedPanel() async throws {
        let state = ReaderState()
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/first.txt"), content: .text("first"))
        state.showFindPanel()
        state.updateFindQuery("first")
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/second.txt"), content: .text("second"))
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(state.command.action, .none)
        state.updateFindQuery("second")
        state.closeFind()
        for _ in 0..<2 {
            state.didHandleCommand(state.command.revision)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        let closed = state.command
        XCTAssertEqual(closed.action, .toc)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(state.command.revision, closed.revision)
    }

    @MainActor
    func testSearchSidebarCanCloseWithoutClosingFindOrReturningBehindContents() {
        let state = ReaderState()
        state.showFindPanel()
        XCTAssertTrue(state.showSearchResults)
        let focus = state.findFocusRevision
        state.showFindPanel()
        XCTAssertGreaterThan(state.findFocusRevision, focus)
        state.closeSidebar()
        XCTAssertTrue(state.showFind)
        XCTAssertFalse(state.showSearchResults)
        state.showFindPanel()
        state.showContents = true
        XCTAssertFalse(state.showSearchResults)
        state.closeSidebar()
        XCTAssertFalse(state.showContents)
        XCTAssertFalse(state.showSearchResults)
        XCTAssertTrue(state.showFind)
    }

    @MainActor
    func testPDFEditingRequiresExplicitUnlockAndResetsForNewDocument() async throws {
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture()
        let pages = try XCTUnwrap(state.nativePDF)
        state.nativePDFInfo = try await pages.pdfInfo()
        defer { state.windowClosed() }
        let mutations: [ReaderMenuCommand] = [.highlight, .freeText, .editAnnotation, .deleteAnnotation, .pasteAnnotation]
        XCTAssertFalse(state.pdfEditingEnabled)
        for command in mutations { XCTAssertFalse(command.enabled(state)) }
        ReaderMenuCommand.highlight.run(state)
        XCTAssertEqual(state.command.action, .none)
        XCTAssertTrue(ReaderMenuCommand.find.enabled(state))
        XCTAssertTrue(ReaderMenuCommand.pdfText.enabled(state))
        for output in [ReaderMenuCommand.pdfExtract, .pdfDelete, .pdfMerge, .pdfEncrypt, .pdfDecrypt,
                       .pdfFlatten, .pdfCompress, .pdfDecompress, .pdfBake, .pdfRedact, .pdfSign] {
            XCTAssertTrue(output.enabled(state), "Tools writing another file do not unlock the current PDF")
        }
        func waitForEditing(_ enabled: Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while state.pdfEditingEnabled != enabled && state.error == nil && Date() < deadline {
                await Task.yield()
            }
            XCTAssertEqual(state.pdfEditingEnabled, enabled, state.error ?? "Editing state did not settle")
        }
        ReaderMenuCommand.pdfEditing.run(state)
        try await waitForEditing(true)
        XCTAssertTrue(ReaderMenuCommand.highlight.enabled(state))
        XCTAssertTrue(ReaderMenuCommand.freeText.enabled(state))
        XCTAssertFalse(ReaderMenuCommand.editAnnotation.enabled(state), "Editing requires a selected annotation")
        let id = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 20, y: 30, width: 40, height: 50))
        let annotations = try await pages.pdfAnnotations(0)
        state.nativePDFSelection = .annotation(page: 0, try XCTUnwrap(annotations.first { $0.id == id }))
        try await state.nativePDFDidChange(pages)
        XCTAssertTrue(ReaderMenuCommand.editAnnotation.enabled(state))
        XCTAssertTrue(ReaderMenuCommand.deleteAnnotation.enabled(state))
        state.busy = true
        XCTAssertTrue(ReaderMenuCommand.pdfEditing.enabled(state))
        ReaderMenuCommand.pdfEditing.run(state)
        try await waitForEditing(false)
        XCTAssertTrue(state.busy, "Locking must not finish another document's load")
        XCTAssertFalse(ReaderMenuCommand.pdfEditing.enabled(state))
        state.busy = false
        XCTAssertTrue(state.modified, "Locking retains edits for Save or Discard")
        XCTAssertTrue(ReaderMenuCommand.save.enabled(state))
        state.setPDFEditingEnabled(true)
        try await waitForEditing(true)
        state.document = try nativePDFReadingFixture()
        XCTAssertFalse(state.pdfEditingEnabled, "An unlock belongs only to the open document")
    }

    @MainActor
    func testFitPresetsShareOneReturnPointAcrossBothButtons() throws {
        let defaults = UserDefaults.standard
        let saved = ["fit", "flow"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        for first in [ReaderMenuCommand.fitPageSingle, .fitWidthContinuous] {
            let state = ReaderState()
            state.document = try nativePDFReadingFixture()
            state.fit = "custom"; state.zoom = 1.75; state.flow = "paged"
            state.spread = true; state.cover = true; state.automaticLayout = true
            let second: ReaderMenuCommand = first == .fitPageSingle ? .fitWidthContinuous : .fitPageSingle
            first.run(state)
            XCTAssertFalse(state.spread, "Both presets must leave two-page/book layout")
            XCTAssertFalse(state.automaticLayout)
            XCTAssertEqual(first.checked(state), true)
            XCTAssertEqual(second.checked(state), false)
            // A resize changes the computed fitted scale, not the return point.
            state.zoom = 0.63
            second.run(state)
            XCTAssertFalse(state.spread)
            XCTAssertEqual(second.checked(state), true)
            second.run(state)
            XCTAssertEqual(state.fit, "custom")
            XCTAssertEqual(state.zoom, 1.75)
            XCTAssertEqual(state.flow, "paged")
            XCTAssertTrue(state.spread)
            XCTAssertTrue(state.cover)
            XCTAssertTrue(state.automaticLayout)
            XCTAssertEqual(first.checked(state), false)
            XCTAssertEqual(second.checked(state), false)
        }
    }

    @MainActor
    func testOrdinaryZoomAndLayoutChangesDiscardThePresetReturnPoint() throws {
        let defaults = UserDefaults.standard
        let saved = ["fit", "flow"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        let changes: [(ReaderState) -> Void] = [
            { $0.setZoom(2.5) }, { $0.setFit("height") },
            { $0.setFlow("paged") }, { $0.spread = true }, { $0.cover.toggle() }
        ]
        for change in changes {
            let state = ReaderState()
            state.document = try nativePDFReadingFixture()
            state.fit = "custom"; state.zoom = 1.25; state.flow = "paged"; state.spread = false
            ReaderMenuCommand.fitWidthContinuous.run(state)
            change(state)
            let fit = state.fit, zoom = state.zoom, flow = state.flow, spread = state.spread
            ReaderMenuCommand.fitPageSingle.run(state)
            XCTAssertEqual(ReaderMenuCommand.fitPageSingle.checked(state), true)
            ReaderMenuCommand.fitPageSingle.run(state)
            XCTAssertEqual(state.fit, fit)
            XCTAssertEqual(state.flow, flow)
            XCTAssertEqual(state.spread, spread)
            if fit == "custom" { XCTAssertEqual(state.zoom, zoom) }
        }
    }

    @MainActor
    func testPresetRestoreDoesNotCrossDocumentsOrInventAPreviousView() throws {
        let defaults = UserDefaults.standard
        let saved = ["fit", "flow", "disableReadingState"].map { ($0, defaults.object(forKey: $0)) }
        defaults.set(true, forKey: "disableReadingState")
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        let state = ReaderState()
        state.document = try nativePDFReadingFixture()
        state.fit = "custom"; state.zoom = 2; state.flow = "paged"; state.spread = true
        ReaderMenuCommand.fitWidthContinuous.run(state)
        state.document = try nativePDFReadingFixture()
        ReaderMenuCommand.fitWidthContinuous.run(state)
        XCTAssertEqual(state.fit, "width")
        XCTAssertEqual(state.flow, "continuous")
        XCTAssertFalse(state.spread)
        ReaderMenuCommand.fitPageSingle.run(state)
        state.windowClosed()
        state.document = try nativePDFReadingFixture()
        ReaderMenuCommand.fitPageSingle.run(state)
        XCTAssertEqual(state.fit, "page")
        XCTAssertEqual(state.flow, "paged")
        XCTAssertFalse(state.spread)
    }

    @MainActor
    func testSavedAndInteractiveZoomUseTheSameBoundsAndModes() {
        let state = ReaderState()
        state.restore(.init(zoom: 64, fit: "height"))
        XCTAssertEqual(state.zoom, 64); XCTAssertEqual(state.fit, "height")
        state.setZoom(80)
        XCTAssertEqual(state.zoom, ReadingZoom.maximum)
        state.setZoom(0.01)
        XCTAssertEqual(state.zoom, ReadingZoom.minimum)
        state.setZoom(.nan)
        XCTAssertEqual(state.zoom, ReadingZoom.minimum)
        state.zoomLimit = 2
        state.setZoom(64)
        XCTAssertEqual(state.zoom, 2)
        state.restore(.init(zoom: 1.2, fit: "content"))
        XCTAssertEqual(state.fit, "content")
    }
    @MainActor
    func testPageJumpDropsPreviousChapterAnchorBeforePersistence() async throws {
        let state = ReaderState()
        let reading = try nativePDFReadingFixture(pageCount: 10)
        let url = reading.url
        let key = "position:" + url.standardizedFileURL.path
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "disableReadingState")
        defaults.set(false, forKey: "disableReadingState")
        defer {
            defaults.removeObject(forKey: key)
            if let previous { defaults.set(previous, forKey: "disableReadingState") }
            else { defaults.removeObject(forKey: "disableReadingState") }
        }
        state.document = reading
        state.nativePDFInfo = try await state.nativePDF?.pdfInfo()
        state.count = 10
        state.spread = false
        let jumps: [(Int, () -> Void)] = [
            (3, { state.turn(1) }), (7, { state.go("8") }),
            (0, { state.firstPage() }), (9, { state.lastPage() })
        ]
        for (page, jump) in jumps {
            state.updatePosition(.init(page: 2, x: 20, y: 30, anchor: "0:2"))
            jump()
            // A close before the reader callback must restore the requested
            // page, never an anchor/coordinate belonging to the previous page.
            state.persist()
            let saved = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: key)))
            XCTAssertEqual(saved.page, page)
            XCTAssertNil(saved.anchor)
            XCTAssertNil(saved.x)
            XCTAssertNil(saved.y)
        }
    }
    @MainActor
    func testQueuedSearchIsNotOverwrittenByPrint() async {
        let state = ReaderState()
        state.send(.find("chapter"))
        let first = state.command
        state.send(.print)
        XCTAssertEqual(state.command.action, .find("chapter", options: .init()))
        state.didHandleCommand(first.revision)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(state.command.action, .print)
        XCTAssertGreaterThan(state.command.revision, first.revision)
    }

    @MainActor
    func testFindCapturesOptionsAndSelectionAtQueueBoundary() async {
        let state = ReaderState()
        state.searchCaseSensitive = true; state.searchWholeWord = true; state.selectedText = "chosen"
        state.send(.copy)
        state.findNext(backwards: true, fromSelection: true)
        state.searchWholeWord = false
        state.didHandleCommand(state.command.revision)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(state.command.action, .find("chosen", backwards: true, options: .init(caseSensitive: true, wholeWord: true), fromSelection: true))
        XCTAssertEqual(state.findQuery, "chosen")
    }

    @MainActor
    func testFirstAndLastPagesDoNotDependOnPageLabelsOrSpread() async {
        let state = ReaderState()
        state.count = 8; state.spread = true; state.cover = true
        state.firstPage()
        XCTAssertEqual(state.page, 0)
        state.lastPage()
        XCTAssertEqual(state.page, 7)
        state.didHandleCommand(state.command.revision)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(state.command.action, .page(7))
        XCTAssertEqual(ReaderState.chapterInput("2:4", offset: -1), "1:3")
        XCTAssertEqual(ReaderState.chapterInput("1:3", offset: 1), "2:4")
        XCTAssertNil(ReaderState.chapterInput("0:2", offset: -1))
        XCTAssertNil(ReaderState.chapterInput("2147483648:2", offset: -1))
    }

    @MainActor
    func testScrollUsesClipBoundsAndStopsAtDocumentEdges() {
        for flipped in [true, false] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            let document = FixedScrollDocument(frame: NSRect(x: 0, y: 0, width: 600, height: 1200))
            document.hasFlippedCoordinates = flipped
            scroll.documentView = document
            scroll.verticalLineScroll = 20
            let viewport = scroll.contentView.bounds.height
            let top = flipped ? 0 : document.bounds.maxY - viewport
            scroll.contentView.scroll(to: CGPoint(x: 0, y: top))
            XCTAssertTrue(ReaderScroll.perform(in: scroll, direction: .down, amount: .line))
            XCTAssertEqual(scroll.contentView.bounds.minY, top + (flipped ? 20 : -20), accuracy: 0.1)
            XCTAssertTrue(ReaderScroll.perform(in: scroll, direction: .down, amount: .halfPage))
            XCTAssertEqual(scroll.contentView.bounds.minY, top + (flipped ? 1 : -1) * (20 + viewport / 2), accuracy: 0.1)
            var rect = scroll.contentView.bounds
            rect.origin.y = flipped ? document.bounds.maxY - rect.height : 0
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(rect).origin)
            XCTAssertFalse(ReaderScroll.perform(in: scroll, direction: .down, amount: .page))
            XCTAssertTrue(ReaderScroll.perform(in: scroll, direction: .up, amount: .page))
        }
    }

    @MainActor
    func testFixedPageScrollDecisionsUseCanvasExtentFitAndCommandKind() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let document = FixedScrollDocument(frame: CGRect(x: 0, y: 0, width: 300, height: 1200))
        scroll.documentView = document; scroll.verticalLineScroll = 20
        func command(_ direction: ReaderScrollDirection, _ amount: ReaderScrollAmount,
                     fit: String = "custom", continuous: Bool = false, count: Int = 1) -> (direction: Int, toBottom: Bool)? {
            ReaderScroll.pageTurn(in: scroll, direction: direction, amount: amount, fit: fit, continuous: continuous, rtl: false, count: count)
        }
        XCTAssertNil(command(.down, .line, count: 3))
        XCTAssertEqual(scroll.contentView.bounds.minY, 60, accuracy: 0.1)
        XCTAssertNil(command(.down, .line, count: -2))
        XCTAssertEqual(scroll.contentView.bounds.minY, 20, accuracy: 0.1)
        let bottom = document.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
        XCTAssertNil(command(.down, .line), "A tall page remains scrollable even when this step is at its bottom")
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom, accuracy: 0.1)
        XCTAssertNil(command(.down, .halfPage), "Paged half-page scrolling never flips pages")
        XCTAssertEqual(command(.down, .halfPage, continuous: true)?.direction, 1)
        XCTAssertEqual(command(.down, .page)?.direction, 1)
        scroll.contentView.scroll(to: .zero)
        for amount in [ReaderScrollAmount.line, .page] {
            XCTAssertEqual(command(.down, amount, fit: "content", continuous: true)?.direction, 1)
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, "Fit Content skips viewport scrolling")
            XCTAssertEqual(command(.up, amount, fit: "content", continuous: true)?.toBottom, false)
            XCTAssertEqual(command(.down, amount, fit: "content", continuous: true, count: -2)?.direction, -1)
            XCTAssertEqual(command(.up, amount, fit: "content", continuous: true, count: -2)?.direction, 1)
        }
        XCTAssertNil(command(.down, .halfPage, fit: "content", continuous: true))
        XCTAssertEqual(scroll.contentView.bounds.minY, scroll.contentView.bounds.height / 2, accuracy: 0.1)
        scroll.contentView.scroll(to: .zero)
        XCTAssertNil(command(.down, .line, fit: "visible", continuous: true), "Fit Visible is not Fit Content")
        XCTAssertEqual(scroll.contentView.bounds.minY, 20, accuracy: 0.1)
        scroll.contentView.scroll(to: .zero)
        XCTAssertEqual(command(.up, .page)?.toBottom, true)
        XCTAssertEqual(command(.down, .page, count: -1)?.toBottom, true)
        XCTAssertNil(command(.down, .page, count: 0))
    }

    @MainActor
    func testFixedPageHorizontalCommandsFollowRTLOnlyWhenTheCanvasFits() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let document = FixedScrollDocument(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = document; scroll.horizontalLineScroll = 20
        document.setFrameSize(scroll.contentView.bounds.size)
        for rtl in [false, true] {
            for direction in [ReaderScrollDirection.left, .right] {
                let expected = (direction == .right) != rtl ? 1 : -1
                let turn = ReaderScroll.pageTurn(in: scroll, direction: direction, amount: .line, fit: "page", continuous: false, rtl: rtl)
                XCTAssertEqual(turn?.direction, expected)
                XCTAssertEqual(turn?.toBottom, false)
                XCTAssertEqual(ReaderScroll.pageTurn(in: scroll, direction: direction, amount: .line,
                    fit: "page", continuous: false, rtl: rtl, count: -2)?.direction, -expected)
                XCTAssertNil(ReaderScroll.pageTurn(in: scroll, direction: direction, amount: .page, fit: "page", continuous: false, rtl: rtl))
            }
        }
        document.setFrameSize(CGSize(width: 900, height: 200))
        let edge = document.frame.width - scroll.contentView.bounds.width
        scroll.contentView.scroll(to: CGPoint(x: edge, y: 0))
        XCTAssertNil(ReaderScroll.pageTurn(in: scroll, direction: .right, amount: .line, fit: "content", continuous: false, rtl: false),
                     "Reaching the horizontal edge does not turn a page when the canvas still needs horizontal scrolling")
        XCTAssertEqual(scroll.contentView.bounds.minX, edge, accuracy: 0.1)
    }

    @MainActor
    func testPDFPageUpLandsAtPreviousPageBottomAndLineDownDoesNotTurnAgain() async throws {
        _ = NSApplication.shared
        let document = PDFDocument(), heights: [CGFloat] = [1600, 800, 1400]
        for (index, height) in heights.enumerated() {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: height), for: .mediaBox)
            document.insert(page, at: index)
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(document)
        let pages = try XCTUnwrap(state.nativePDF)
        state.count = 3; state.flow = "paged"; state.spread = false; state.cover = false
        state.fit = "actual"; state.zoom = 1; state.rotation = 0; state.freePan = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false; state.automaticLayout = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Navigation did not settle", line: line)
        }
        func pageIsAtEdge(_ index: Int, bottom: Bool = false) -> Bool {
            guard state.page == index, let canvas = state.readerFocusView, canvas.window === window,
                  let scroll = state.readerScrollView, let documentView = scroll.documentView,
                  abs(canvas.bounds.width - 300) <= 1, abs(canvas.bounds.height - heights[index]) <= 1 else { return false }
            let bounds = canvas.convert(canvas.bounds, to: documentView), clip = scroll.contentView.bounds
            return abs(bottom ? clip.maxY - bounds.maxY : clip.minY - bounds.minY) <= 1
        }
        // Distinct physical heights ensure the destination page has replaced
        // its predecessor, rather than only the published page number changing.
        try await waitFor { pageIsAtEdge(0) }
        state.restore(.init(page: 1, x: 0, y: 0))
        try await waitFor { pageIsAtEdge(1) }
        state.scroll(.up, amount: .page)
        try await waitFor { pageIsAtEdge(0, bottom: true) }

        let beforeLine = state.command.revision
        state.scroll(.down, amount: .line)
        state.send(.none)
        try await waitFor { state.command.revision > beforeLine && state.command.action == .none }
        // The first marker follows the scroll handler, but a page/restore it
        // enqueues may follow that marker. This second marker follows those
        // derived commands too, so an erroneous page turn cannot pass early.
        let firstMarker = state.command.revision
        state.send(.none)
        try await waitFor { state.command.revision > firstMarker && state.command.action == .none }
        XCTAssertEqual(state.page, 0, "Line Down at the bottom of a tall page stays on that page")
        XCTAssertTrue(pageIsAtEdge(0, bottom: true), "Line Down must retain the previous page's bottom position")

        state.scroll(.down, amount: .page)
        try await waitFor { pageIsAtEdge(1) }
        // The last page of the previous facing row is shorter. Page Up must
        // use the mounted row's bottom, not that last page's source height.
        state.spread = true
        state.restore(.init(page: 2, x: 0, y: 0))
        try await waitFor { pageIsAtEdge(2) }
        state.scroll(.up, amount: .page)
        try await waitFor {
            guard state.page == 1, let scroll = state.readerScrollView,
                  let documentView = scroll.documentView else { return false }
            return documentView.bounds.height >= heights[0] &&
                abs(scroll.contentView.bounds.maxY - documentView.bounds.maxY) <= 1
        }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testWheelRoutesAcrossPageMarginsWithoutSkippingOnMomentum() async throws {
        _ = NSApplication.shared
        let document = PDFDocument(), heights: [CGFloat] = [1200, 1400, 1600]
        for height in heights {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: height), for: .mediaBox)
            document.insert(page, at: document.pageCount)
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(document)
        let pages = try XCTUnwrap(state.nativePDF)
        state.count = 3; state.flow = "paged"; state.spread = false; state.cover = false
        state.fit = "page"; state.rotation = 0; state.freePan = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false; state.automaticLayout = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.orderFront(nil)
        var intercepted: Bool?
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === window else { return event }
            let handled = state.handleScrollWheel(event)
            intercepted = handled
            return handled ? nil : event
        })
        defer {
            NSEvent.removeMonitor(monitor)
            state.windowClosed(); window.contentView = nil; window.close()
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Wheel navigation did not settle", line: line)
        }
        func settle(_ page: Int, bottom: Bool = false) async throws {
            try await waitFor {
                guard state.page == page, let canvas = state.readerFocusView, canvas.window === window,
                      let scroll = state.readerScrollView, let view = scroll.documentView else { return false }
                if state.fit == "actual" {
                    guard abs(canvas.bounds.height - heights[page]) <= 1 else { return false }
                    let rect = canvas.convert(canvas.bounds, to: view), visible = scroll.contentView.safeAreaRect
                    return abs(bottom ? visible.maxY - rect.maxY : visible.minY - rect.minY) <= 1
                }
                return abs(canvas.bounds.height - scroll.contentView.safeAreaRect.height) <= 1
            }
            // Navigation can enqueue a derived page/restore command. Drain it
            // before sending the next independent user gesture.
            for _ in 0..<2 {
                let revision = state.command.revision
                state.send(.none)
                try await waitFor { state.command.revision > revision && state.command.action == .none }
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }
        func wheel(_ y: Int32, x: Int32 = 0, phase: NSEvent.Phase = [], momentum: Int64 = 0,
                   flags: CGEventFlags = [], outside: Bool = false, dispatch: Bool = true) throws -> Bool {
            let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
            let margin = CGPoint(x: outside ? clip.safeAreaRect.maxX + 30 : clip.safeAreaRect.minX + 4,
                                 y: clip.safeAreaRect.midY)
            if !outside, let canvas = state.readerFocusView {
                XCTAssertFalse(canvas.convert(canvas.bounds, to: clip).contains(margin), "Route wheel events over the blank page margin")
            }
            let point = clip.convert(margin, to: nil)
            let event = try wheelEvent(window: window, at: point, y: y, x: x,
                                       phase: phase, momentum: momentum, flags: flags)
            if !dispatch { return state.handleScrollWheel(event) }
            intercepted = nil
            NSApp.sendEvent(event)
            return try XCTUnwrap(intercepted, "The local reader monitor must receive the actual scroll event")
        }

        try await settle(0)
        state.restore(.init(page: 1))
        try await settle(1)
        XCTAssertTrue(try wheel(1))
        XCTAssertTrue(try wheel(1), "A second notch while navigation is in flight must not queue another turn")
        try await settle(0)
        XCTAssertTrue(try wheel(-1, phase: .began))
        try await settle(1)
        XCTAssertTrue(try wheel(-1, phase: .changed))
        XCTAssertFalse(try wheel(0, phase: .ended))
        XCTAssertTrue(try wheel(-1, momentum: 1))
        for momentum: Int64 in [2, 3] {
            XCTAssertTrue(try wheel(-1, momentum: momentum, outside: true),
                          "AppKit's original gesture target must not receive momentum after the pointer leaves it")
        }
        try await settle(1)
        XCTAssertTrue(try wheel(-1, phase: .began))
        try await settle(2)
        XCTAssertFalse(try wheel(0, phase: .cancelled))
        XCTAssertTrue(try wheel(1), "A fresh discrete wheel must not inherit the touch gesture's latch")
        try await settle(1)
        // Check pass-through without starting unrelated AppKit rubber-band
        // animations that would race the next explicit layout/restore below.
        for flags: CGEventFlags in [.maskShift, .maskControl, .maskAlternate, .maskCommand] {
            XCTAssertFalse(try wheel(-1, flags: flags, dispatch: false))
        }
        XCTAssertFalse(try wheel(0, x: 2, dispatch: false))
        XCTAssertFalse(try wheel(-1, outside: true, dispatch: false))
        try await settle(1)

        state.fit = "actual"; state.zoom = 1
        state.restore(.init(page: 1, x: 0, y: 0))
        try await settle(1)
        XCTAssertTrue(try wheel(1))
        try await settle(0, bottom: true)
        XCTAssertTrue(try wheel(-1))
        try await settle(1)
        let scroll = try XCTUnwrap(state.readerScrollView), before = scroll.contentView.bounds.minY
        XCTAssertFalse(try wheel(-20), "The system scroll view owns movement inside a tall page")
        try await waitFor { scroll.contentView.bounds.minY > before }
        XCTAssertEqual(state.page, 1)

        state.flow = "continuous"
        try await waitFor { state.readerScrollView !== scroll && state.readerScrollView?.documentView != nil }
        let continuous = try XCTUnwrap(state.readerScrollView), position = continuous.contentView.bounds.minY
        XCTAssertFalse(try wheel(-20))
        try await waitFor { continuous.contentView.bounds.minY > position }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testFitWidthWheelReturnsToPreviousPageBottomBelowToolbar() async throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF engine is not built")
        }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("wheel-layout.pdf")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0.9, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        bitmap.setFillColor(CGColor(gray: 0.2, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1024, height: 64))
        let image = try XCTUnwrap(bitmap.makeImage())
        // These real page proportions differ from the initial layout estimate.
        // Returning to a page must wait for its newly mounted, measured frame.
        var media = CGRect(x: 0, y: 0, width: 504.48, height: 681.84)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &media, nil))
        for _ in 0..<3 {
            writer.beginPDFPage(nil); writer.draw(image, in: media); writer.endPDFPage()
        }
        writer.closePDF()
        let pages = try Pages(input, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = 3
        state.flow = "paged"; state.fit = "width"; state.spread = false; state.cover = false; state.rtl = false
        state.rotation = 0; state.automaticLayout = false; state.uniformPageWidth = false
        state.freePan = false; state.trimEmptyMargins = false; state.scrollbarMode = "shown"
        state.toolbarVisible = true; state.presentation = false
        state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 900, height: 740),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: .init("SumraWheelLayout-" + UUID().uuidString))
        window.toolbarStyle = .unified; window.contentView = host; state.window = window
        window.orderFront(nil)
        var intercepted: Bool?
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === window else { return event }
            let handled = state.handleScrollWheel(event)
            intercepted = handled
            return handled ? nil : event
        })
        defer {
            NSEvent.removeMonitor(monitor)
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: "position:" + input.path)
            withExtendedLifetime(directory) {}
        }
        func waitForEdge(_ page: Int, bottom: Bool = false, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5), tolerance = 1 / window.backingScaleFactor
            repeat {
                // Let the visible window perform its own AppKit/SwiftUI layout.
                // Forcing layout here would hide a lost pending scroll request.
                if state.page == page, state.nativePDFInfo != nil,
                   let canvas = state.readerFocusView, let clip = state.readerScrollView?.contentView,
                   RasterReader.pageIsRendered(in: canvas, pages: pages, location: state.pageLocation(page)),
                   clip.safeAreaRect.height < clip.bounds.height,
                   abs(canvas.bounds.width - clip.safeAreaRect.width) <= tolerance,
                   abs(canvas.bounds.height - clip.safeAreaRect.width * media.height / media.width) <= tolerance {
                    let visible = window.contentLayoutRect.intersection(clip.convert(clip.bounds, to: nil))
                    let frame = canvas.convert(canvas.bounds, to: nil)
                    if abs(bottom ? frame.minY - visible.minY : frame.maxY - visible.maxY) <= tolerance {
                        // Positioning may finish before the command's deferred
                        // acknowledgement; start the next distinct input after it.
                        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                        return
                    }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(Optional<Bool>.none,
                "Page \(page + 1) did not reach its \(bottom ? "bottom" : "top"); current page \(state.page + 1), clip \(String(describing: state.readerScrollView?.contentView.bounds)): \(state.error ?? "no error")", line: line)
        }
        func wheel(_ delta: Int32) throws -> Bool {
            let clip = try XCTUnwrap(state.readerScrollView?.contentView)
            let point = clip.convert(CGPoint(x: clip.safeAreaRect.midX, y: clip.safeAreaRect.midY), to: nil)
            let event = try wheelEvent(window: window, at: point, y: delta)
            intercepted = nil
            NSApp.sendEvent(event)
            return try XCTUnwrap(intercepted, "The window's reader monitor must receive the wheel")
        }
        try await waitForEdge(0)
        XCTAssertFalse(try wheel(-740), "AppKit scrolls within the first page")
        try await waitForEdge(0, bottom: true)
        for page in 1...2 {
            XCTAssertTrue(try wheel(-1))
            try await waitForEdge(page)
            XCTAssertTrue(try wheel(1))
            try await waitForEdge(page - 1, bottom: true)
            XCTAssertTrue(try wheel(-1))
            try await waitForEdge(page)
            XCTAssertFalse(try wheel(-740))
            try await waitForEdge(page, bottom: true)
        }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testReadingRotationDoesNotChangeSavedSnapshot() async throws {
        let pdf = PDFDocument(), page = PDFPage()
        page.rotation = 90; pdf.insert(page, at: 0)
        let reading = try nativePDFReadingFixture(pdf), state = ReaderState(recordsHistory: false)
        state.document = reading; state.rotation = 90
        defer { state.windowClosed() }
        let pages = try XCTUnwrap(state.nativePDF)
        let output = reading.url.deletingLastPathComponent().appendingPathComponent("copy.pdf")
        try await pages.pdfSaveCopy(to: output)
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.rotation, 90)
        XCTAssertEqual(state.rotation, 90)
        let info = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(info).dirty)
    }
    @MainActor
    func testBackForwardAndNewBranchRestoreActualPosition() {
        let state = ReaderState()
        state.updatePosition(.init(page: 2, x: 12, y: 30, anchor: "2:1"))
        state.navigate(.page(8))
        state.updatePosition(.init(page: 8, x: 5, y: 15, anchor: "3:2"))
        state.navigateHistory(-1)
        XCTAssertEqual(state.page, 2)
        XCTAssertEqual(state.location.anchor, "2:1")
        XCTAssertEqual(state.location.y, 30)
        state.navigateHistory(1)
        XCTAssertEqual(state.page, 8)
        state.navigateHistory(-1)
        state.navigate(.page(10))
        state.updatePosition(.init(page: 10))
        XCTAssertFalse(state.canNavigateForward)
        state.navigateHistory(-1)
        XCTAssertEqual(state.page, 2)
    }

    func testOldSavedPositionAndTypographyRemainReadable() throws {
        let old = try JSONDecoder().decode(ReadingPosition.self, from: Data("{\"page\":7}".utf8))
        XCTAssertEqual(old.page, 7)
        var position = ReadingPosition(page: 4, x: 11, y: 20, anchor: "1:4")
        position.fontSize = 23
        let data = try JSONEncoder().encode(position)
        let restored = try JSONDecoder().decode(ReadingPosition.self, from: data)
        XCTAssertEqual(restored.anchor, "1:4")
        XCTAssertEqual(restored.fontSize, 23)
        XCTAssertEqual(restored.x, 11)
    }

    @MainActor
    func testHistoryBoundAndEmptyHistory() {
        let state = ReaderState()
        state.navigateHistory(-1)
        XCTAssertFalse(state.canNavigateBack)
        for index in 0..<70 {
            state.page = index
            state.navigate(.page(index + 1))
        }
        state.page = 70
        for _ in 0..<100 { state.navigateHistory(-1) }
        XCTAssertEqual(state.page, 21)
        XCTAssertFalse(state.canNavigateBack)
    }

    @MainActor
    private func wheelEvent(window: NSWindow, at point: CGPoint, y: Int32, x: Int32 = 0,
                            phase: NSEvent.Phase = [], momentum: Int64 = 0, flags: CGEventFlags = []) throws -> NSEvent {
        let seed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let cg = try XCTUnwrap(seed.cgEvent?.copy())
        cg.type = .scrollWheel; cg.flags = flags
        // A phase-less wheel is a discrete mouse notch. SwiftUI's native
        // HostingScrollView ignores precise events without a trackpad phase.
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: phase.isEmpty && momentum == 0 ? 0 : 1)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(y))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(x))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x))
        let scrollPhase: CGScrollPhase?
        switch phase {
        case .began: scrollPhase = .began
        case .changed: scrollPhase = .changed
        case .ended: scrollPhase = .ended
        case .cancelled: scrollPhase = .cancelled
        case .mayBegin: scrollPhase = .mayBegin
        default: scrollPhase = nil
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase?.rawValue ?? 0))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(event.window === window, "CG event window \(event.windowNumber), expected \(window.windowNumber)")
        XCTAssertEqual(event.phase, phase)
        XCTAssertEqual(event.momentumPhase.isEmpty, momentum == 0)
        return event
    }
}

private final class FixedScrollDocument: NSView {
    var hasFlippedCoordinates = true
    override var isFlipped: Bool { hasFlippedCoordinates }
}
@MainActor
func nativePDFReadingFixture(_ pdf: PDFDocument? = nil, pageCount: Int = 1) throws -> ReadingDocument {
    let directory = try TemporaryDirectory(), url = directory.url.appendingPathComponent("fixture.pdf")
    let source = pdf ?? PDFDocument()
    if source.pageCount == 0 {
        for _ in 0..<pageCount {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            source.insert(page, at: source.pageCount)
        }
    }
    try XCTUnwrap(source.dataRepresentation()).write(to: url)
    return ReadingDocument(url: url, content: .pages(try Pages(url, format: .pdf)), temporary: directory)
}
#endif
