#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFReaderMigrationTests: XCTestCase {
    func testAutomaticLayoutUsesPDFCatalogAndPreservesUnspecifiedDirection() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for (layout, spread, cover) in [(nil, false, false), ("SinglePage", false, false),
            ("OneColumn", false, false), ("TwoColumnLeft", true, false), ("TwoColumnRight", true, true),
            ("TwoPageLeft", true, false), ("TwoPageRight", true, true)] as [(String?, Bool, Bool)] {
            for direction in [nil, "L2R", "R2L"] as [String?] {
                let input = directory.url.appendingPathComponent("layout.pdf")
                try fixture(layout: layout, direction: direction).write(to: input)
                let pages = try Pages(input, format: .pdf), result = try await pages.preferredLayout()
                XCTAssertEqual(result.flow, "continuous")
                XCTAssertEqual(result.spread, spread); XCTAssertEqual(result.cover, cover)
                XCTAssertEqual(result.rtl, direction.map { $0 == "R2L" })
                let info = try await pages.pdfInfo()
                XCTAssertFalse(try XCTUnwrap(info).dirty)
            }
        }
    }

    func testRectangularSelectionKeepsEachPageAreaAndItsText() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("selection.pdf")
        defer { withExtendedLifetime(directory) {} }
        try fixture().write(to: input)
        let pages = try Pages(input, format: .pdf)
        let selected = try await pages.selection(areas: [PageLocation(page: 0): CGRect(x: -20, y: 90, width: 200, height: 70),
            PageLocation(page: 1): CGRect(x: 0, y: 90, width: 160, height: 70)])
        XCTAssertEqual(selected[PageLocation(page: 0)]?.bounds, [CGRect(x: 0, y: 90, width: 180, height: 70)])
        XCTAssertEqual(selected[PageLocation(page: 1)]?.bounds, [CGRect(x: 0, y: 90, width: 160, height: 70)])
        XCTAssertTrue(selected[PageLocation(page: 0)]?.text.contains("FIRST") == true)
        XCTAssertTrue(selected[PageLocation(page: 1)]?.text.contains("SECOND") == true)
        let info = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(info).dirty)
    }

    @MainActor
    func testFacingPageRectangleAndKeyboardLinkUseBothPages() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("reader.pdf")
        try fixture().write(to: input)
        let pages = try Pages(input, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = 3
        state.nativePDFInfo = try await pages.pdfInfo()
        state.flow = "paged"; state.fit = "page"; state.spread = true; state.cover = false; state.rtl = false
        state.automaticLayout = false; state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false
        state.hoverPreview = true; state.disableLinks = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 340), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertTrue(condition(), state.error ?? "Reader interaction did not settle", line: line)
        }
        func linkCount(_ view: NSView) -> Int {
            view.trackingAreas.filter { $0.userInfo?["uri"] != nil }.count + view.subviews.reduce(0) { $0 + linkCount($1) }
        }
        func pageIsRendered(_ page: Int, in view: NSView) -> Bool {
            RasterReader.pageIsRendered(in: view, pages: pages, location: .init(page: page)) ||
                view.subviews.contains { pageIsRendered(page, in: $0) }
        }
        try await waitFor { state.readerScrollView != nil && linkCount(host) == 2 &&
            pageIsRendered(0, in: host) && pageIsRendered(1, in: host) }
        let view = try XCTUnwrap(state.readerFocusView)
        func mouse(_ kind: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: view.convert(CGPoint(x: x, y: y), to: nil),
                modifierFlags: [.option], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, x: 5, y: view.bounds.height * 0.28))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: view.bounds.width * 1.8, y: view.bounds.height * 0.6))
        view.mouseUp(with: try mouse(.leftMouseUp, x: view.bounds.width * 1.8, y: view.bounds.height * 0.6))
        try await waitFor { state.selectedText.contains("FIRST") && state.selectedText.contains("SECOND") }
        state.keyboardTextSelection = true
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertFalse(state.keyboardTextSelection)
        state.keyboardLinkFollowing = true
        for (text, code) in [("2", UInt16(19)), ("\r", UInt16(36))] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            view.keyDown(with: key)
        }
        try await waitFor { state.page == 2 }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testLockedPDFCommentsRemainReadableAndContextCopyUsesSystemText() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("comments.pdf")
        let contents = (1...120).map { "Long comment line \($0)" }.joined(separator: "\n")
        try fixture(comment: contents).write(to: input)
        let pages = try Pages(input, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = 3
        state.nativePDFInfo = try await pages.pdfInfo()
        state.flow = "paged"; state.fit = "page"; state.spread = false; state.rotation = 0
        state.automaticLayout = false; state.freePan = false; state.rectangularSelection = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false; state.annotationsVisible = true
        state.hoverPreview = false; state.disableLinks = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.orderFront(nil)
        let clipboard = NSPasteboard.general
        let previousItems = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let annotationClipboard = NativePDFClipboard.current
        var popovers = [NSPopover]()
        // AppKit's animation completion need not be delivered by the XCTest
        // host. Disable animation before showing; the assertions below still
        // require the real shown/window state and a fully closed popover.
        let observer = NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let popover = notification.object as? NSPopover,
                      let scroll = popover.contentViewController?.view as? NSScrollView,
                      (scroll.documentView as? NSTextView)?.string == contents else { return }
                popover.animates = false
                popovers.append(popover)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            popovers.forEach { $0.close() }
            clipboard.clearContents(); clipboard.writeObjects(previousItems)
            NativePDFClipboard.current = annotationClipboard
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertTrue(condition(), state.error ?? "Comment interaction did not settle", line: line)
        }
        func mouse(_ view: NSView, _ kind: NSEvent.EventType, x: CGFloat = 35, y: CGFloat = 75) throws -> NSEvent {
            let point = CGPoint(x: view.bounds.width * x / 200, y: view.bounds.height * y / 300)
            return try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        try await waitFor {
            guard let view = state.readerFocusView, let event = try? mouse(view, .rightMouseDown) else { return false }
            return view.menu(for: event)?.items.contains { $0.title == L("Show Comment") } == true
        }
        let view = try XCTUnwrap(state.readerFocusView)
        let menu = try XCTUnwrap(view.menu(for: try mouse(view, .rightMouseDown)))
        let copy = try XCTUnwrap(menu.items.first { $0.title == L("Copy Comment") })
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(clipboard.string(forType: .string), contents)
        XCTAssertTrue(NativePDFClipboard.current === annotationClipboard, "Copy Comment must not replace the annotation-object clipboard")
        let links = try await pages.pdfLinks(0)
        let linkMenu = try XCTUnwrap(view.menu(for: try mouse(view, .rightMouseDown, x: 60, y: 37)))
        let copyLink = try XCTUnwrap(linkMenu.items.first { $0.title == L("Copy Link Address") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copyLink.action), to: copyLink.target, from: copyLink))
        XCTAssertEqual(clipboard.string(forType: .string), links.first?.actions.first?.uri)
        let show = try XCTUnwrap(menu.items.first { $0.title == L("Show Comment") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(show.action), to: show.target, from: show))
        try await waitFor { popovers.count == 1 && popovers[0].isShown && popovers[0].contentViewController?.view.window?.isVisible == true }
        let scroll = try XCTUnwrap(popovers.first?.contentViewController?.view as? NSScrollView)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(text.string, contents); XCTAssertFalse(text.isEditable); XCTAssertTrue(text.isSelectable)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertFalse(state.pdfEditingEnabled); XCTAssertFalse(state.modified)

        // A drag starting on a note selects page content, rather than reopening
        // the note after the mouse has moved away from its original position.
        view.mouseDown(with: try mouse(view, .leftMouseDown))
        view.mouseDragged(with: try mouse(view, .leftMouseDragged, x: 120, y: 90))
        view.mouseUp(with: try mouse(view, .leftMouseUp, x: 120, y: 90))
        try await waitFor { popovers.allSatisfy { !$0.isShown } }
        XCTAssertEqual(popovers.count, 1)
        view.mouseDown(with: try mouse(view, .leftMouseDown))
        view.mouseUp(with: try mouse(view, .leftMouseUp))
        try await waitFor { popovers.count == 2 && popovers[1].isShown && popovers[1].contentViewController?.view.window?.isVisible == true }
        window.contentView = nil
        try await waitFor { popovers.allSatisfy { !$0.isShown } }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSelectAllUsesDisplayedPagesAndEmptyTextCopyPreservesClipboard() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), clipboard = NSPasteboard.general
        let input = directory.url.appendingPathComponent("selection.pdf")
        let html = directory.url.appendingPathComponent("selection.html")
        try fixture().write(to: input)
        try "<html><body><p>NATIVE-TEXT</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let previousItems = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let annotationClipboard = NativePDFClipboard.current
        defer {
            clipboard.clearContents(); clipboard.writeObjects(previousItems)
            NativePDFClipboard.current = annotationClipboard
            withExtendedLifetime(directory) {}
        }
        let cases: [(Format, String, Bool, Bool, Bool, Int, [String])] = [
            (.pdf, "paged", false, false, false, 1, ["SECOND"]),
            (.pdf, "paged", true, false, false, 0, ["FIRST", "SECOND"]),
            (.pdf, "paged", true, true, false, 0, ["FIRST"]),
            (.pdf, "paged", true, true, false, 1, ["SECOND", "THIRD"]),
            (.pdf, "continuous", false, false, false, 1, ["FIRST", "SECOND", "THIRD"]),
            (.pdf, "continuous", true, false, true, 1, ["SECOND"]),
            (.html, "paged", false, false, false, 0, ["NATIVE-TEXT"])
        ]
        for (format, flow, spread, cover, presentation, page, expected) in cases {
            let source = format == .pdf ? input : html
            let pages = try Pages(source, format: format), state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: source, content: .pages(pages))
            state.count = await pages.count
            if format == .pdf { state.nativePDFInfo = try await pages.pdfInfo() }
            state.flow = flow; state.fit = "page"; state.spread = spread; state.cover = cover
            state.presentation = presentation; state.rtl = false; state.rotation = 0
            state.automaticLayout = false; state.freePan = false; state.rectangularSelection = false
            state.uniformPageWidth = false; state.trimEmptyMargins = false; state.landscapeAsSpread = false
            state.updatePosition(.init(page: page))
            let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 340),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer {
                state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            }
            func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline && state.error == nil
                _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Selection command did not settle: \(expected)", line: line)
            }
            try await waitFor {
                state.readerScrollView != nil && RasterReader.pageIsRendered(in: state.readerFocusView,
                    pages: pages, location: state.pageLocation(state.page))
            }
            state.send(.selectAll)
            // Queue Copy while native selection is pending; the command queue
            // must copy the completed selection before acknowledging the marker.
            state.send(.copy)
            state.send(.none)
            try await waitFor { state.command.action == .none && state.hasSelection }
            XCTAssertEqual(state.selectedText.split(whereSeparator: { $0.isWhitespace }).map(String.init), expected)
            XCTAssertEqual(clipboard.string(forType: .string), state.selectedText)

            let view = try XCTUnwrap(state.readerFocusView)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind,
                    location: view.convert(CGPoint(x: view.bounds.width * 0.95, y: view.bounds.height * 0.95), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                if kind == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
            XCTAssertFalse(state.hasSelection); XCTAssertTrue(state.selectedText.isEmpty)
            clipboard.clearContents(); clipboard.setString("SUMRA-COPY-SENTINEL", forType: .string)
            let changeCount = clipboard.changeCount
            let copyRevision = state.command.revision
            state.send(.copy)
            state.send(.none)
            try await waitFor { state.command.revision > copyRevision && state.command.action == .none }
            XCTAssertEqual(clipboard.string(forType: .string), "SUMRA-COPY-SENTINEL")
            XCTAssertEqual(clipboard.changeCount, changeCount, "Empty Copy must not write any pasteboard type")
            XCTAssertNil(state.error)
        }
    }

    private func requireMuPDF() throws {
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("MuPDF engine unavailable") }
    }

    private func fixture(layout: String? = nil, direction: String? = nil, comment: String? = nil) -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R\(layout.map { " /PageLayout /" + $0 } ?? "")\(direction.map { " /ViewerPreferences << /Direction /" + $0 + " >>" } ?? "") >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"]
        for index in 0..<3 {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << /Font << /F1 6 0 R >> >> /Contents \(7 + index) 0 R\(index < 2 ? " /Annots [\(10 + index) 0 R\(index == 0 && comment != nil ? " 12 0 R" : "")]" : "") >>")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        for text in ["FIRST", "SECOND", "THIRD"] {
            let stream = "BT /F1 18 Tf 20 175 Td (\(text)) Tj ET"
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        objects += ["<< /Type /Annot /Subtype /Link /Rect [20 250 100 275] /Dest [3 0 R /Fit] >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 250 100 275] /Dest [5 0 R /Fit] >>"]
        if let comment {
            let escaped = comment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            objects.append("<< /Type /Annot /Subtype /Text /Rect [20 210 50 240] /Contents (\(escaped)) >>")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
#endif
