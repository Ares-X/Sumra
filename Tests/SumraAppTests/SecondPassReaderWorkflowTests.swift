#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class SecondPassReaderWorkflowTests: XCTestCase {
    func testDocumentColorDialogCannotApplyTheDepartingDocumentsPaletteToItsReplacement() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let first = directory.url.appendingPathComponent("first.txt")
        let second = directory.url.appendingPathComponent("second.html")
        try "The original text document".write(to: first, atomically: true, encoding: .utf8)
        try "<html><body><p>The replacement HTML document</p></body></html>".write(to: second, atomically: true, encoding: .utf8)
        let original = try ReadingDocument.open(first), replacement = try ReadingDocument.open(second)
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed(); withExtendedLifetime(directory) {} }
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn] {
            state.document = original
            state.customTextColor = 0x112233; state.customBackgroundColor = 0xeeeedd; state.customLinkColor = 0x445566
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated {
                    // A source-opening completion can publish while AppKit is
                    // running a dialog, just like the close-confirmation case.
                    state.document = replacement
                    state.customTextColor = 0x334455; state.customBackgroundColor = 0xeeddcc; state.customLinkColor = 0x556677
                    NSApp.stopModal(withCode: response)
                }
            }
            state.configureDocumentColors()
            XCTAssertEqual(state.document?.id, replacement.id)
            XCTAssertEqual(state.customTextColor, 0x334455, "A dialog for the old document must not recolor the replacement")
            XCTAssertEqual(state.customBackgroundColor, 0xeeddcc)
            XCTAssertEqual(state.customLinkColor, 0x556677)
            XCTAssertEqual(state.command.action, .none, "No old palette style command may reach the replacement")
            XCTAssertFalse(NSColorPanel.shared.isVisible)
            XCTAssertNil(NSApp.modalWindow)
        }
    }

    func testDocumentColorDialogApplyUseThemeAndCancelKeepTheOriginalOwnerAndCloseItsColorPanel() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("colors.txt")
        try "An unchanged document keeps its color dialog".write(to: input, atomically: true, encoding: .utf8)
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn] {
            let state = ReaderState(recordsHistory: false)
            state.document = try ReadingDocument.open(input)
            state.customTextColor = 0x112233; state.customBackgroundColor = 0xeeeedd; state.customLinkColor = 0x445566
            let original = state.document?.id
            defer { state.windowClosed(); withExtendedLifetime(directory) {} }
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated {
                    defer { NSApp.stopModal(withCode: response) }
                    do {
                        let content = try XCTUnwrap(NSApp.modalWindow?.contentView)
                        func editor(in view: NSView) -> ReaderThemeEditorView? {
                            (view as? ReaderThemeEditorView) ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
                        }
                        let colors = try XCTUnwrap(editor(in: content))
                        colors.text.hex.stringValue = "#AABBCC"
                        colors.paper.hex.stringValue = "#102030"
                        colors.link.hex.stringValue = "#DDEEFF"
                        for input in [colors.text, colors.paper, colors.link] {
                            input.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: input.hex))
                        }
                        colors.text.well.activate(true)
                        XCTAssertTrue(NSColorPanel.shared.isVisible)
                    } catch { XCTFail("Color dialog inspection failed: \(error)") }
                }
            }
            state.configureDocumentColors()
            XCTAssertEqual(state.document?.id, original)
            switch response {
            case .alertFirstButtonReturn:
                XCTAssertEqual(state.customTextColor, 0xaabbcc)
                XCTAssertEqual(state.customBackgroundColor, 0x102030)
                XCTAssertEqual(state.customLinkColor, 0xddeeff)
                XCTAssertEqual(state.documentColors, "smart")
                XCTAssertEqual(state.command.action, .style)
            case .alertSecondButtonReturn:
                XCTAssertNil(state.customTextColor); XCTAssertNil(state.customBackgroundColor); XCTAssertNil(state.customLinkColor)
                XCTAssertEqual(state.command.action, .style)
            default:
                XCTAssertEqual(state.customTextColor, 0x112233)
                XCTAssertEqual(state.customBackgroundColor, 0xeeeedd)
                XCTAssertEqual(state.customLinkColor, 0x445566)
                XCTAssertEqual(state.command.action, .none)
            }
            XCTAssertFalse(NSColorPanel.shared.isVisible)
            XCTAssertNil(NSApp.modalWindow)
        }
    }

    func testFB2RapidNavigationThenQueuedModeFontAndResizeChangesRetainTheChosenSource() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("rapid.fb2")
        let body = (0..<180).map { index in
            "<p>Paragraph \(index). " + String(repeating: "A stable authored passage remains readable across queued navigation and reader reflow. ", count: 5) + "</p>"
        }.joined()
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><description><title-info><book-title>Rapid reader</book-title><lang>en</lang></title-info></description><body><section>\(body)</section></body></FictionBook>"
            .write(to: input, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, keys = ["flow", "theme", "lastDarkTheme", "lastLightTheme", "font", "fontSize", "margin", "pageMargins"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let state = ReaderState(recordsHistory: false)
        state.document = try ReadingDocument.open(input, deferReflowLayout: true)
        guard case .pages(let pages) = state.document?.content else { return XCTFail("FB2 must use native pages") }
        state.flow = "paged"; state.spread = false; state.cover = false; state.fit = "page"
        state.theme = "light"; state.font = "serif"; state.fontSize = 17; state.lineHeight = 1.4
        state.margin = 32; state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.rtl = false; state.rotation = 0; state.automaticLayout = false; state.scrollbarMode = "hidden"
        state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false
        state.landscapeAsSpread = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        func painted(_ view: NSView) -> Bool {
            RasterReader.pageIsRendered(in: view, pages: pages, location: state.pageLocation(state.page)) || view.subviews.contains { painted($0) }
        }
        func settle(_ condition: () -> Bool = { true }) async throws {
            let deadline = Date().addingTimeInterval(12)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if state.reflowable, state.pendingReflowPosition == nil, state.currentPosition.nativePassage != nil,
                   painted(host), condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            throw ReadError(state.error ?? "FB2 workflow did not settle: page=\(state.page), command=\(state.command), source=\(String(describing: state.currentPosition.nativePassage)), pending=\(state.pendingReflowPosition != nil)")
        }
        try await settle()
        XCTAssertGreaterThan(state.count, 12)
        for _ in 0..<8 { state.turn(1) }
        for _ in 0..<3 { state.turn(-1) }
        state.send(.none)
        try await settle { state.page == 5 && state.command.action == .none }
        let chosen = try XCTUnwrap(state.currentPosition.nativePassage)
        state.setFlow("continuous")
        state.font = "Iowan Old Style"; state.fontSize = 23; state.applyTypography()
        state.setTheme("dark")
        state.setFlow("paged")
        window.setContentSize(CGSize(width: 540, height: 720))
        state.fontSize = 19; state.margin = 44; state.applyTypography()
        state.send(.none)
        try await settle { state.command.action == .none && state.currentPosition.nativePassage?.source == chosen.source }
        XCTAssertEqual(state.font, "Iowan Old Style")
        XCTAssertEqual(state.fontSize, 19); XCTAssertEqual(state.margin, 44); XCTAssertEqual(state.theme, "dark")
        XCTAssertEqual(state.currentPosition.nativePassage?.source, chosen.source)
        let restored = try await pages.restore(.init(nativePassage: chosen), userCSS: state.effectiveUserCSS, theme: state.resolvedTheme)
        XCTAssertEqual(state.page, restored.page)
        XCTAssertNil(state.error)
    }
}
#endif
