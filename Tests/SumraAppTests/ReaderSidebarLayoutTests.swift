#if os(macOS)
import AppKit
import ApplicationServices
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
    func testRemovingActiveContentsSearchReleasesItsOwnNativeEditor() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let host = NSHostingView(rootView: AnyView(ContentsSearchInput(state: state).frame(width: 240, height: 28)))
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 260, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(3)
        while state.contentsSearchField?.window !== window, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let field = try XCTUnwrap(state.contentsSearchField)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(editor.delegate === field)
        XCTAssertTrue(window.firstResponder === editor)
        host.rootView = AnyView(EmptyView())
        let removalDeadline = Date().addingTimeInterval(3)
        while state.contentsSearchField != nil, Date() < removalDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(state.contentsSearchField)
        XCTAssertNil(field.window)
        XCTAssertNil(field.currentEditor())
        XCTAssertFalse(window.firstResponder === editor, "Removing the active client must still release its editor")
    }

    @MainActor
    func testPaletteSearchContentsKeepsNativeFocusAfterSheetDismissal() async throws {
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        pdf.insert(page, at: 0)
        let outline = PDFOutline(), chapter = PDFOutline()
        chapter.label = "Beta Chapter"
        chapter.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 400))
        outline.insertChild(chapter, at: 0)
        pdf.outlineRoot = outline
        let reading = try nativePDFReadingFixture(pdf)
        try await checkPaletteContentsSearch(reading, epub: false)
    }

    @MainActor
    func testEPUBPaletteSearchContentsKeepsNativeFocusAfterAskDocument() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try contentsEPUB(in: directory.url)
        let reading = try ReadingDocument.open(input, deferReflowLayout: true)
        try await checkPaletteContentsSearch(reading, epub: true)
    }

    @MainActor
    private func checkPaletteContentsSearch(_ reading: ReadingDocument, epub: Bool) async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let defaults = UserDefaults.standard
        let keys = ["sidebarWidth", "sidebarRight", "findFloating", "paletteMRU", "language"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(220.0, forKey: "sidebarWidth")
        defaults.set(false, forKey: "sidebarRight")
        defaults.set(false, forKey: "findFloating")
        defaults.set("en", forKey: "language")
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        let state = ReaderState(recordsHistory: false)
        state.document = reading; state.count = epub ? 0 : 1
        state.showContents = true; state.showAI = !epub
        state.paletteMode = "> Search Contents"
        let host = NSHostingView(rootView: ReaderView(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 560, height: 640),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        window.title = "Sumra palette focus regression " + UUID().uuidString
        window.orderBack(nil)
        defer {
            state.showPalette = false
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            state.windowClosed(); window.orderOut(nil); window.contentView = nil; window.close()
            withExtendedLifetime(reading) {}
        }
        func waitFor(_ ready: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
                if ready() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < deadline
            XCTFail("Palette sheet focus did not settle; responder=\(String(describing: window.firstResponder))", file: file, line: line)
            throw CancellationError()
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        func descendants(_ element: AXUIElement) -> [AXUIElement] {
            [element] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
        }
        func paletteAction(_ command: String = "contentsSearch") -> AXUIElement? {
            let application = AXUIElementCreateApplication(getpid())
            let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            return windows.flatMap(descendants).first {
                attribute($0, kAXIdentifierAttribute) as? String == "palette-row:" + command
            }
        }
        try await waitFor {
            state.contentsSearchField?.window === window && state.readerFocusView != nil &&
                (!epub || state.reflowable && state.count > 0)
        }
        if epub, case .pages(let pages) = reading.content {
            let hasChapters = await pages.hasChapters
            print("SUMRA_EPUB_FOCUS nativeHasChapters=\(hasChapters) layoutChapters=\(state.chapterLayout?.chapterCount ?? 0)")
            XCTAssertFalse(hasChapters, "The single-spine GUI reproduction uses the existing outline refresh path")
        }
        let initialField = try XCTUnwrap(state.contentsSearchField)
        window.makeFirstResponder(state.readerFocusView)
        if epub {
            state.paletteMode = "> Ask AI"
            state.showPalette = true
            try await waitFor { window.attachedSheet != nil && paletteAction("ai") != nil }
            XCTAssertEqual(AXUIElementPerformAction(try XCTUnwrap(paletteAction("ai")), kAXPressAction as CFString), .success)
            try await waitFor {
                window.attachedSheet == nil && state.compactSidebars && state.recentSidebarIsAI && initialField.visibleRect.isEmpty
            }
        }
        XCTAssertTrue(initialField.visibleRect.isEmpty)
        state.paletteMode = "> Search Contents"
        state.showPalette = true
        try await waitFor { window.attachedSheet != nil && paletteAction() != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let action = try XCTUnwrap(paletteAction())
        XCTAssertEqual(AXUIElementPerformAction(action, kAXPressAction as CFString), .success)
        try await waitFor {
            window.attachedSheet == nil && state.contentsSearchField?.window === window &&
                state.contentsSearchField?.visibleRect.isEmpty == false
        }
        // Sheet dismissal restores native focus after its didEndSheet callback.
        // Verify the settled responder, rather than only the immediate request.
        try await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(state.contentsSearchField)
        XCTAssertTrue(field.window === window, "Assertions must use the current mounted Contents field")
        XCTAssertFalse(state.outline.isEmpty)
        print("SUMRA_PALETTE_FOCUS responder=\(String(describing: window.firstResponder)) editor=\(String(describing: field.currentEditor())) requested=\(state.contentsSearchRequested) sheetVisible=\(sheet.isVisible)")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        // Coordinate refreshes keep the existing outline usable while Pages
        // publishes outlineBusy. They must retain the native search client.
        if !epub {
            state.outlineBusy = true
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(state.contentsSearchField === field)
            XCTAssertTrue(field.window === window)
            XCTAssertTrue(window.firstResponder === editor)
            state.outlineBusy = false
        }
        for (letter, key) in zip(["B", "e", "t", "a"], [UInt16(11), 14, 17, 0]) {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: letter, charactersIgnoringModifiers: letter,
                isARepeat: false, keyCode: key))
            window.sendEvent(event)
        }
        XCTAssertEqual(field.stringValue, "Beta")
        // Direct window event delivery has no NSApp.currentEvent; exercise the
        // search cell's native target/action boundary explicitly as well.
        XCTAssertTrue(field.sendAction(try XCTUnwrap(field.action), to: field.target))
        XCTAssertEqual(state.contentsQuery, "Beta")
    }

    private func contentsEPUB(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let chapters = [("alpha", "Alpha"), ("beta", "Beta"), ("gamma", "Gamma")]
        let navigation = chapters.map { "<li><a href='body.xhtml#\($0.0)'>\($0.1) chapter</a></li>" }.joined()
        let body = chapters.map { id, title in
            "<h1 id='\(id)'>\(title) chapter</h1>" + (0..<40).map { "<p>\(title) passage \($0): synthetic contents and native reading layout.</p>" }.joined()
        }.joined()
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "book.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='id'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:identifier id='id'>sumra-contents-focus</dc:identifier><dc:title>Synthetic Contents</dc:title><dc:language>en</dc:language><meta property='dcterms:modified'>2026-11-04T00:00:00Z</meta></metadata><manifest><item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/><item id='body' href='body.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='body'/></spine></package>",
            "nav.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head><title>Contents</title></head><body><nav epub:type='toc'><ol>\(navigation)</ol></nav></body></html>",
            "body.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Synthetic Contents</title></head><body>\(body)</body></html>"
        ]
        for (name, contents) in files { try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        guard zip.terminationStatus == 0 else { throw ReadError("Cannot create the native Contents EPUB fixture") }
        return directory.appendingPathComponent("book.epub")
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
