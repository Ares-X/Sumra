#if os(macOS)
import AppKit
import Darwin
import ImageIO
import PDFKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class RasterReaderTests: XCTestCase {
    @MainActor
    func testRasterContentFitAndRTLKeyboardCommandsTurnPagesThroughTheExistingReader() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), state = ReaderState()
        for index in 0..<3 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 800, bitsPerComponent: 8, bytesPerRow: 800,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 800))
            let image = try XCTUnwrap(context.makeImage())
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: directory.url.appendingPathComponent("\(index).png"))
        }
        let pages = try Pages(directory.url, format: .comic)
        state.document = ReadingDocument(url: directory.url, content: .pages(pages)); state.count = 3
        state.flow = "continuous"; state.fit = "content"; state.spread = false; state.rtl = false
        state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false; state.automaticLayout = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: "position:" + directory.url.path)
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, "Keyboard navigation did not settle: page \(state.page), \(state.error ?? "no error")")
        }
        try await waitFor { state.readerFocusView != nil && state.readerScrollView != nil }
        let scroll = try XCTUnwrap(state.readerScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
        state.scroll(.down)
        try await waitFor { state.page == 1 }
        state.send(.none)
        try await waitFor { state.command.action == .none }
        state.scroll(.up, amount: .page)
        try await waitFor { state.page == 0 }
        state.send(.none)
        try await waitFor { state.command.action == .none }

        state.flow = "paged"; state.fit = "page"; state.rtl = true
        let layoutRevision = state.command.revision
        state.send(.fit("page")); state.send(.none)
        try await waitFor {
            guard let scroll = state.readerScrollView, let document = scroll.documentView else { return false }
            return state.command.revision > layoutRevision && state.command.action == .none && document.frame.width <= scroll.contentView.bounds.width
        }
        state.scroll(.left)
        try await waitFor { state.page == 1 }
        state.send(.none)
        try await waitFor { state.command.action == .none }
        state.scroll(.right)
        try await waitFor { state.page == 0 }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testKeyboardLinkInputClearsConsumedHintAndPreservesOtherStatus() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("keyboard.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
            .write(to: input)
        let pages = try Pages(input, format: .image), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = 1
        state.flow = "paged"; state.fit = "page"; state.spread = false; state.freePan = false
        state.automaticLayout = false; state.keyboardLinkFollowing = true
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        let deadline = Date().addingTimeInterval(3)
        while state.readerFocusView == nil, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let canvas = try XCTUnwrap(state.readerFocusView)
        func key(_ characters: String, _ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            canvas.keyDown(with: event)
        }
        try key("1", 18)
        XCTAssertFalse(state.status.isEmpty, "Entering a link number presents the follow hint")
        try key("\r", 36)
        XCTAssertEqual(state.status, "", "Return consumes the number even when no visible link matches")
        try key("2", 19)
        XCTAssertFalse(state.status.isEmpty)
        try key("\u{1b}", 53)
        XCTAssertFalse(state.keyboardLinkFollowing)
        XCTAssertEqual(state.status, "", "Escape must remove the cancelled input's hint")
        state.keyboardLinkFollowing = true
        try key("3", 20)
        state.status = "File changed on disk"
        try key("\r", 36)
        XCTAssertEqual(state.status, "File changed on disk", "Consuming link input must not clear a newer document status")
        try key("4", 21)
        state.status = "Opening replacement…"
        try key("\u{1b}", 53)
        XCTAssertEqual(state.status, "Opening replacement…", "Cancelling link input must not clear another owner's status")
    }

    @MainActor
    func testContinuousAsyncOpenKeepsInitialChapterAndRestoredOffset() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), state = ReaderState()
        let input = try epubFixture(in: directory.url, chapters: 32, paragraphs: 30)
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        }
        func waitFor(line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                paint()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, "Initial reader layout failed: \(state.error ?? state.currentPosition.anchor ?? String(state.page))", line: line)
        }
        for target in [PageLocation(chapter: 0, page: 0), PageLocation(chapter: 20, page: 1)] {
            state.font = "system"; state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32
            state.theme = "light"; state.flow = "continuous"
            state.fit = target.chapter == 0 ? "actual" : "custom"; state.zoom = target.chapter == 0 ? 1 : 3
            state.spread = false; state.cover = false; state.automaticLayout = false
            state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false
            var initial = state.currentPosition
            initial.page = 0; initial.anchor = "\(target.chapter):\(target.page)"
            initial.x = target.chapter == 0 ? 0 : 7; initial.y = target.chapter == 0 ? 0 : 40
            let previousDocument = state.document?.id
            state.openWithoutHistory(input, at: initial)
            try await waitFor { state.document?.id != previousDocument && !state.busy && state.count > 0 && state.readerScrollView != nil && state.readerFocusView != nil }
            try await waitFor { state.chapterLayout?.complete == true }
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 20_000_000); paint()
                XCTAssertEqual(state.pageLocation(state.page), target, "The first geometry report must not replace the requested chapter")
                XCTAssertEqual(state.location.x ?? 0, initial.x ?? 0, accuracy: 1)
                XCTAssertEqual(state.location.y ?? 0, initial.y ?? 0, accuracy: 1)
            }
            let canvas = try XCTUnwrap(state.readerFocusView), scroll = try XCTUnwrap(state.readerScrollView)
            guard case .pages(let pages) = try XCTUnwrap(state.document).content else { return XCTFail("Expected EPUB reader") }
            let bounds = try await pages.bounds(target)
            let actual = canvas.convert(scroll.contentView.bounds.origin, from: scroll.contentView)
            if canvas.bounds.width > scroll.contentView.bounds.width {
                XCTAssertEqual(actual.x * bounds.width / canvas.bounds.width, initial.x ?? 0, accuracy: 1)
            } else {
                XCTAssertEqual(actual.x, (canvas.bounds.width - scroll.contentView.bounds.width) / 2, accuracy: 1, "A page narrower than the viewport must stay centered")
            }
            XCTAssertEqual(actual.y * bounds.height / canvas.bounds.height, initial.y ?? 0, accuracy: 1, "The actual native page must retain its restored offset")
        }
    }

    @MainActor
    func testVisibleUnlaidChapterIsRecordedBeforePublicationAndKeepsOffsets() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let input = try epubFixture(in: directory.url)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light")
        let table = await pages.chapterLayout, state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.reflowable = true
        state.applyChapterLayout(table)
        defer {
            UserDefaults.standard.removeObject(forKey: "position:" + input.standardizedFileURL.path)
            withExtendedLifetime(directory) {}
        }
        let target = PageLocation(chapter: 2, page: 0)
        XCTAssertFalse(table.isLaidOut(target.chapter))
        // This is the geometry callback produced by dragging onto an unresolved
        // row. It must be recorded before the decoder can yield a layout event.
        let reader = RasterReader(state: state, pages: pages)
        reader.savePosition(location: target, x: 7, y: 19)
        XCTAssertEqual(state.pageLocation(state.page), target)
        XCTAssertEqual(state.location.x, 7); XCTAssertEqual(state.location.y, 19)
        _ = try await pages.position(target)
        let countedTarget = await pages.chapterLayout
        state.applyChapterLayout(countedTarget)
        XCTAssertEqual(state.pageLocation(state.page), target)
        try await pages.publishWarmedChapters()
        let complete = await pages.chapterLayout
        state.applyChapterLayout(complete)
        XCTAssertGreaterThan(state.page, table.page(for: target) ?? 0)
        XCTAssertEqual(state.pageLocation(state.page), target)
        XCTAssertEqual(state.location.x, 7); XCTAssertEqual(state.location.y, 19)
    }

    func testDjVuRelativeLinksUseTheVisiblePageInsteadOfTheLastDecoderPosition() async throws {
        let engine = try NativeFile.libraryURL(for: .djvu)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("DjVu engine is required") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let input = root.appendingPathComponent("build/deps/djvulibre-3.5.30/doc/djvu3spec.djvu")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("DjVuLibre's multi-page fixture is required") }
        let pages = try Pages(input, format: .djvu)
        let count = await pages.count
        XCTAssertGreaterThan(count, 3)
        _ = try await pages.position(page: 0)
        let next = try await pages.resolve("#+1", from: .init(page: 2))
        XCTAssertEqual(next?.page, 3)
        let previous = try await pages.resolve("#-1", from: .init(page: 2))
        XCTAssertEqual(previous?.page, 1)
        let preview = try await pages.previewImage("#+1", from: 2), expected = try await pages.image(3, width: 640)
        let image = try XCTUnwrap(preview)
        XCTAssertEqual(image.width, expected.width); XCTAssertEqual(image.height, expected.height)
        XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, try XCTUnwrap(expected.dataProvider?.data) as Data)
    }

    @MainActor
    func testContinuousScrollingDoesNotReplayConsumedJumpsAndSamePageRestoreStillWorks() async throws {
        _ = NSApplication.shared
        let input = try htmlFixture(String(repeating: "<p>A visible paragraph for scrolling through recycled page views.</p>", count: 300))
        let pages = try Pages(input, format: .html)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light")
        let state = ReaderState(), table = await pages.chapterLayout
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.reflowable = true
        state.applyChapterLayout(table)
        state.flow = "continuous"; state.fit = "actual"; state.zoom = 1
        state.spread = false; state.rotation = 0; state.freePan = false; state.trimEmptyMargins = false
        state.automaticLayout = false; state.uniformPageWidth = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: "position:" + input.standardizedFileURL.path)
        }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        }
        func waitFor(line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                paint()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            _ = try XCTUnwrap(condition() ? true : nil, "The native raster view did not reach its requested position (page \(state.page), y \(state.readerScrollView?.contentView.bounds.minY ?? -1))", line: line)
        }
        try await waitFor { state.readerScrollView != nil }
        let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
        let pageHeight = try await pages.bounds(0).height
        func actualOffset() -> CGFloat? {
            guard let canvas = state.readerFocusView, canvas.bounds.height > 0 else { return nil }
            return canvas.convert(clip.bounds.origin, from: clip).y * pageHeight / canvas.bounds.height
        }
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 20_000_000); paint()
            XCTAssertEqual(state.page, 0, "Opening a continuous document must begin at the first page")
            XCTAssertEqual(clip.bounds.minY, 0, accuracy: 1)
        }
        // First consume an explicit jump. Returning to the start and dragging
        // away recreates lazy cells; those cells must not replay that old jump.
        let jumpRevision = state.command.revision + 2
        state.send(.page(0)); state.send(.none)
        try await waitFor { state.command.revision >= jumpRevision && state.command.action == .none }
        for _ in 0..<2 {
            let dragSource = try XCTUnwrap(state.readerFocusView)
            XCTAssertTrue(window.makeFirstResponder(dragSource))
            let target = max(0, ((scroll.documentView?.frame.height ?? 0) - clip.bounds.height) * 0.6)
            XCTAssertGreaterThan(target, clip.bounds.height)
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            clip.scroll(to: NSPoint(x: 0, y: target)); scroll.reflectScrolledClipView(clip)
            try await waitFor { state.page > 0 && clip.bounds.minY > clip.bounds.height }
            XCTAssertTrue(dragSource.enclosingScrollView === scroll, "The active drag/selection source must survive leaving the viewport")
            window.makeFirstResponder(nil)
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 20_000_000); paint()
                XCTAssertGreaterThan(clip.bounds.minY, clip.bounds.height, "Rendering a recycled page must not restore the first page")
            }
            let page = state.page
            let restoreRevision = state.command.revision + 2
            state.send(.restore(.init(page: page, y: 40))); state.send(.none)
            try await waitFor { state.command.revision >= restoreRevision && state.command.action == .none && state.page == page && abs((actualOffset() ?? -1) - 40) < 1 }
            for zoom in [1.2, 0.85, 1.5] {
                let zoomRevision = state.command.revision + 2
                state.setZoom(zoom); state.send(.none)
                paint()
                try await waitFor { state.command.revision >= zoomRevision && state.command.action == .none && state.page == page && abs((actualOffset() ?? -1) - 40) < 1 }
            }
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
            try await waitFor { state.page == 0 }
        }

    }

    @MainActor
    func testContinuousUnequalSpreadKeepsTheRowThroughItsGapAndOuterMargin() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), state = ReaderState()
        for (index, height) in [200, 800, 400, 400].enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: height, bitsPerComponent: 8, bytesPerRow: 800,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: height))
            let image = try XCTUnwrap(context.makeImage())
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: directory.url.appendingPathComponent("\(index).png"))
        }
        let pages = try Pages(directory.url, format: .comic)
        state.document = ReadingDocument(url: directory.url, content: .pages(pages)); state.count = 4
        state.flow = "continuous"; state.fit = "actual"; state.zoom = 1; state.spread = true; state.cover = false
        state.freePan = true; state.uniformPageWidth = false; state.landscapeAsSpread = false; state.automaticLayout = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func waitFor(line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            let native = state.readerFocusView.flatMap { page in state.readerScrollView.map { page.convert($0.contentView.bounds.origin, from: $0.contentView) } }
            _ = try XCTUnwrap(condition() ? true : nil, "The spread did not retain its visible row: page \(state.page), offset \(state.location.x ?? -1),\(state.location.y ?? -1), native \(String(describing: native)), canvas \(state.readerFocusView?.bounds ?? .zero), document \(state.readerScrollView?.documentView?.frame ?? .zero), error \(state.error ?? "none")", line: line)
        }
        // Wait for both visible pages, not an estimated total document height.
        // The offscreen second row may still use estimated image dimensions.
        func hasTallPage(_ view: NSView) -> Bool {
            view.bounds.size == CGSize(width: 200, height: 800) || view.subviews.contains(where: hasTallPage)
        }
        try await waitFor {
            state.readerFocusView?.bounds.height == 200 && state.readerScrollView?.documentView.map(hasTallPage) == true
        }
        let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
        let firstPage = try XCTUnwrap(state.readerFocusView)
        let top = firstPage.convert(.zero, to: scroll.documentView).y
        func scrollTo(_ y: CGFloat) {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            clip.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
        }
        scrollTo(top + 550)
        try await waitFor { state.page == 0 && abs((state.location.y ?? -1) - 550) < 1 }
        scrollTo(top + 802)
        try await waitFor { state.page == 0 && abs((state.location.y ?? -1) - 802) < 1 }
        scrollTo(top + 804)
        try await waitFor { state.page == 2 && abs(state.location.y ?? -1) < 1 }
        scrollTo(0)
        try await waitFor { state.page == 0 && abs((state.location.y ?? 0) + top) < 1 }
        let restoredPage = try XCTUnwrap(state.readerFocusView)
        let actual = restoredPage.convert(clip.bounds.origin, from: clip)
        XCTAssertLessThan(actual.x, 0); XCTAssertLessThan(actual.y, 0)
        XCTAssertEqual(state.location.x ?? 0, actual.x, accuracy: 1)
        XCTAssertEqual(state.location.y ?? 0, actual.y, accuracy: 1, "Free pan must preserve the visible outer margin")
        let restoreRevision = state.command.revision + 3 // Zoom, restore, then this batch's .none.
        state.freePan = false; state.rtl = true; state.setZoom(2)
        state.send(.restore(.init(page: 0, y: 0))); state.send(.none)
        try await waitFor { state.command.revision >= restoreRevision && state.command.action == .none && state.readerFocusView?.bounds.width == 400 }
        scrollTo(0)
        try await waitFor {
            guard let page = state.readerFocusView else { return false }
            let actual = page.convert(clip.bounds.origin, from: clip).x * 200 / page.bounds.width
            return actual < 0 && abs((state.location.x ?? 0) - actual) < 1
        }
        let rtlPage = try XCTUnwrap(state.readerFocusView)
        let rtlOffset = rtlPage.convert(clip.bounds.origin, from: clip).x * 200 / rtlPage.bounds.width
        XCTAssertEqual(state.location.x ?? 0, rtlOffset, accuracy: 1, "RTL must preserve the visible left page as an offset from its logical row start")
        let zoomRevision = state.command.revision + 2
        state.setZoom(1.5); state.send(.none)
        try await waitFor {
            guard state.command.revision >= zoomRevision, state.command.action == .none, let page = state.readerFocusView else { return false }
            return abs(page.convert(clip.bounds.origin, from: clip).x * 200 / page.bounds.width - rtlOffset) < 1
        }

    }

    @MainActor
    func testPDFFitPageBelowToolbarAndPersistedPositionRoundTrip() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("toolbar.pdf")
        var media = CGRect(x: 0, y: 0, width: 487.2, height: 681.84)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &media, nil))
        writer.beginPDFPage(nil); writer.setFillColor(CGColor(gray: 0.9, alpha: 1)); writer.fill(media)
        writer.setStrokeColor(CGColor(gray: 0, alpha: 1)); writer.stroke(media.insetBy(dx: 2, dy: 2))
        writer.endPDFPage(); writer.closePDF()
        let pages = try Pages(input, format: .pdf), pageBounds = try await pages.bounds(0)
        let defaults = UserDefaults.standard, keys = ["fit", "disableReadingState"]
        let previous = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        defaults.set(false, forKey: "disableReadingState")
        let state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = 1
        state.flow = "paged"; state.fit = "page"; state.spread = false; state.cover = false; state.rtl = false
        state.rotation = 0; state.automaticLayout = false; state.uniformPageWidth = false
        state.freePan = false; state.trimEmptyMargins = false; state.scrollbarMode = "shown"
        state.toolbarVisible = true; state.presentation = false
        state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 740),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: .init("SumraToolbarViewport-" + UUID().uuidString))
        window.toolbarStyle = .unified; window.contentView = host; state.window = window
        window.makeKeyAndOrderFront(nil)
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            defaults.removeObject(forKey: "position:" + input.path)
            for key in keys {
                if let value = previous[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, "Toolbar page layout did not settle: \(state.error ?? "no error")", line: line)
        }
        // Use the window's actual unobscured content to check the result,
        // independently of the clip safe-area geometry used by the reader.
        func visibleWindowRect() -> CGRect? {
            guard let clip = state.readerScrollView?.contentView else { return nil }
            return window.contentLayoutRect.intersection(clip.convert(clip.bounds, to: nil))
        }
        func pageOrigin() -> CGPoint? {
            guard let canvas = state.readerFocusView, let visible = visibleWindowRect(),
                  canvas.bounds.width > 0, canvas.bounds.height > 0 else { return nil }
            let point = canvas.convert(CGPoint(x: visible.minX, y: visible.maxY), from: nil)
            return CGPoint(x: point.x * pageBounds.width / canvas.bounds.width,
                           y: point.y * pageBounds.height / canvas.bounds.height)
        }
        let tolerance = 1 / window.backingScaleFactor
        try await waitFor {
            guard let canvas = state.readerFocusView, let clip = state.readerScrollView?.contentView,
                  let visible = visibleWindowRect(), state.nativePDFInfo != nil else { return false }
            return clip.safeAreaRect.height < clip.bounds.height &&
                abs(canvas.bounds.width / canvas.bounds.height - pageBounds.width / pageBounds.height) < 0.002 &&
                visible.insetBy(dx: -tolerance, dy: -tolerance).contains(canvas.convert(canvas.bounds, to: nil))
        }
        state.setZoom(3); state.send(.none)
        try await waitFor {
            guard let canvas = state.readerFocusView else { return false }
            return state.command.action == .none && abs(canvas.bounds.height - pageBounds.height * 3) <= tolerance
        }
        let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
        // A real native scroll must publish the point visible below the toolbar,
        // not the hidden point at the raw clip origin.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        var bounds = clip.bounds; bounds.origin = CGPoint(x: 130, y: 350)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin); scroll.reflectScrolledClipView(clip)
        try await waitFor {
            guard let actual = pageOrigin(), let x = state.location.x, let y = state.location.y else { return false }
            return abs(x - Double(actual.x)) <= Double(tolerance) && abs(y - Double(actual.y)) <= Double(tolerance)
        }
        state.persist()
        let saved = try JSONDecoder().decode(ReadingPosition.self,
            from: XCTUnwrap(defaults.data(forKey: "position:" + input.path)))
        let savedX = try XCTUnwrap(saved.x), savedY = try XCTUnwrap(saved.y)
        XCTAssertGreaterThan(savedX, 0); XCTAssertGreaterThan(savedY, 0)
        state.send(.page(0)); state.send(.none)
        try await waitFor { state.command.action == .none && pageOrigin().map { abs($0.y) <= tolerance } == true }
        state.restore(saved); state.send(.none)
        try await waitFor {
            guard state.command.action == .none, let actual = pageOrigin() else { return false }
            return abs(Double(actual.x) - savedX) <= Double(tolerance) && abs(Double(actual.y) - savedY) <= Double(tolerance)
        }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testPDFMixedCropFacingPagesShareFitScaleAndKeepUniformRTLGeometry() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("mixed-facing.pdf")
        var media = CGRect(x: -20, y: -30, width: 460, height: 900)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &media, nil))
        for content in [CGRect(x: 50, y: 40, width: 200, height: 100), CGRect(x: 120, y: 530, width: 200, height: 200),
                        CGRect(x: 70, y: 70, width: 100, height: 50), CGRect(x: 140, y: 630, width: 100, height: 120)] {
            writer.beginPDFPage(nil); writer.setFillColor(CGColor(gray: 0, alpha: 1)); writer.fill(content); writer.endPDFPage()
        }
        writer.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(url: input)), first = try XCTUnwrap(pdf.page(at: 0)), second = try XCTUnwrap(pdf.page(at: 1))
        first.setBounds(CGRect(x: -20, y: -30, width: 460, height: 300), for: .mediaBox)
        first.setBounds(CGRect(x: 10, y: 20, width: 400, height: 200), for: .cropBox)
        first.rotation = 90
        second.setBounds(CGRect(x: 0, y: 0, width: 460, height: 860), for: .mediaBox)
        second.setBounds(CGRect(x: 20, y: 30, width: 400, height: 800), for: .cropBox)
        for index in 2..<4 {
            let page = try XCTUnwrap(pdf.page(at: index)), reference = index == 2 ? first : second
            page.setBounds(reference.bounds(for: .mediaBox), for: .mediaBox)
            page.setBounds(reference.bounds(for: .cropBox), for: .cropBox)
            page.rotation = reference.rotation
        }
        try XCTUnwrap(pdf.dataRepresentation()).write(to: input)
        let original = try Data(contentsOf: input), pages = try Pages(input, format: .pdf)
        let firstBounds = try await pages.bounds(0), secondBounds = try await pages.bounds(1)
        XCTAssertEqual(firstBounds.size, CGSize(width: 200, height: 400))
        XCTAssertEqual(secondBounds.size, CGSize(width: 400, height: 800))
        let firstContent = try await pages.contentBounds(0), secondContent = try await pages.contentBounds(1)
        XCTAssertEqual(firstContent, CGRect(x: 20, y: 40, width: 100, height: 200))
        XCTAssertEqual(secondContent, CGRect(x: 100, y: 100, width: 200, height: 200))
        let thirdContent = try await pages.contentBounds(2), fourthContent = try await pages.contentBounds(3)
        XCTAssertEqual(thirdContent, CGRect(x: 50, y: 60, width: 50, height: 100))
        XCTAssertEqual(fourthContent, CGRect(x: 120, y: 80, width: 100, height: 120))
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = 4
        state.flow = "paged"; state.fit = "page"; state.spread = true; state.cover = false; state.rtl = false
        state.rotation = 0; state.automaticLayout = false; state.uniformPageWidth = false
        state.freePan = false; state.trimEmptyMargins = false; state.landscapeAsSpread = false
        state.scrollbarMode = "shown"
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let defaults = UserDefaults.standard, previousFit = defaults.object(forKey: "fit"), previousFlow = defaults.object(forKey: "flow")
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            if let previousFit { defaults.set(previousFit, forKey: "fit") } else { defaults.removeObject(forKey: "fit") }
            if let previousFlow { defaults.set(previousFlow, forKey: "flow") } else { defaults.removeObject(forKey: "flow") }
            withExtendedLifetime(directory) {}
        }
        // SwiftUI aligns native view edges to the window backing grid. Keep
        // exact fit arithmetic above separate from these rendered view sizes.
        let pixelTolerance = 1 / window.backingScaleFactor
        func canvases() -> [NSView] {
            guard let first = state.readerFocusView else { return [] }
            func visit(_ view: NSView) -> [NSView] {
                (type(of: view) == type(of: first) ? [view] : []) + view.subviews.flatMap(visit)
            }
            return visit(host).sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, "Facing page geometry: \(canvases().map(\.bounds)), \(state.error ?? "no error")", line: line)
        }
        func setFit(_ mode: String, line: UInt = #line) async throws {
            let revision = state.command.revision + 2
            state.setFit(mode); state.send(.none)
            try await waitFor({ state.command.revision >= revision && state.command.action == .none }, line: line)
        }
        func rowContentIsVisible(mode: String, contents: [CGRect]) -> Bool {
            let views = canvases(), logical = state.rtl ? Array(views.reversed()) : views
            guard logical.count == 2 else { return false }
            for (index, content) in contents.enumerated() {
                let view = logical[index], bounds = index == 0 ? firstBounds : secondBounds
                let padded = mode == "visible" ? content.insetBy(dx: -2, dy: -2) : content
                let expected = padded.applying(CGAffineTransform(scaleX: view.bounds.width / bounds.width, y: view.bounds.height / bounds.height))
                if !view.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(expected) { return false }
            }
            return true
        }
        // DisplayModel::GetZoomReal takes the smaller PDF facing-page scale.
        // The authored CropBox and intrinsic rotation determine physical size.
        // Content spans x=20...504 in LTR, but x=100...524 in RTL.
        // The pinned logical-order union misses asymmetric RTL margins; use
        // the actual columns. Fit Visible adds two points at each outer edge.
        // AppKit keeps the four-point page gap fixed rather than scaling it.
        // User commands begin after RasterReader has mounted its command
        // observer. Property-driven geometry alone is not command readiness.
        try await waitFor { canvases().count == 2 && state.readerScrollView?.window === window }
        for fit in ["page", "orientation", "content", "visible"] {
            try await setFit(fit)
            for rtl in [false, true] {
                state.rtl = rtl
                try await waitFor {
                    let views = canvases()
                    guard views.count == 2, let current = state.readerFocusView,
                          let viewport = state.readerScrollView?.contentView.bounds.size else { return false }
                    let factor: CGFloat
                    switch fit {
                    case "page": factor = min((viewport.width - 4) / 800, viewport.height / 800)
                    case "orientation": factor = (viewport.width - 4) / 800
                    default: factor = (viewport.width - 4) / ((rtl ? 420 : 480) + (fit == "visible" ? 4 : 0))
                    }
                    let other = views.first { $0 !== current }
                    return abs(current.bounds.width - 200 * factor) <= pixelTolerance &&
                        abs(current.bounds.height - 400 * factor) <= pixelTolerance &&
                        abs((other?.bounds.width ?? 0) - 400 * factor) <= pixelTolerance &&
                        abs((other?.bounds.height ?? 0) - 800 * factor) <= pixelTolerance &&
                        (rtl ? views.last === current : views.first === current)
                }
                let views = canvases()
                XCTAssertEqual(views[1].convert(.zero, to: host).x - views[0].convert(.zero, to: host).x - views[0].bounds.width, 4, accuracy: 0.1)
                if fit == "content" || fit == "visible" {
                    try await waitFor { rowContentIsVisible(mode: fit, contents: [firstContent, secondContent]) }
                    // A request for the second logical page must still expose
                    // both fitted content boxes, in either reading direction.
                    for target in [1, 0] {
                        let revision = state.command.revision + 2
                        state.send(.page(target)); state.send(.none)
                        try await waitFor { state.command.revision >= revision && state.command.action == .none && rowContentIsVisible(mode: fit, contents: [firstContent, secondContent]) }
                    }
                }
            }
        }
        // The same row must refit when native scrollbars release their space;
        // the fit calculation must not assume any fixed scroller thickness.
        state.rtl = false; try await setFit("content"); state.scrollbarMode = "hidden"
        try await waitFor {
            guard let viewport = state.readerScrollView?.contentView.bounds.size,
                  let first = state.readerFocusView else { return false }
            return viewport == host.bounds.size &&
                abs(first.bounds.width - 200 * (viewport.width - 4) / 480) <= pixelTolerance &&
                rowContentIsVisible(mode: "content", contents: [firstContent, secondContent])
        }
        state.scrollbarMode = "shown"
        // Absolute uniform width retains per-page scales, including a second
        // viewer rotation; it must not inherit the shared virtual-fit scale.
        state.uniformPageWidth = true; try await setFit("actual")
        for (rotation, expected) in [(0, CGSize(width: 200, height: 400)), (90, CGSize(width: 400, height: 200))] {
            state.rotation = rotation
            try await waitFor { let views = canvases(); return views.count == 2 && views.allSatisfy { $0.bounds.size == expected } }
        }
        // A lone cover or last page still occupies one facing slot. It must
        // not double in size simply because the adjacent slot is empty.
        state.rotation = 0; state.uniformPageWidth = false; state.cover = true; try await setFit("width")
        try await waitFor {
            let views = canvases()
            guard views.count == 1, let viewport = state.readerScrollView?.contentView.bounds.size else { return false }
            return abs(views[0].bounds.width - (viewport.width - 4) / 2) <= pixelTolerance
        }
        state.send(.page(3)); state.send(.none)
        try await waitFor {
            let views = canvases()
            guard state.page == 3, views.count == 1, let viewport = state.readerScrollView?.contentView.bounds.size else { return false }
            return abs(views[0].bounds.width - (viewport.width - 4) / 2) <= pixelTolerance
        }

        state.cover = false; state.setFlow("continuous")
        window.makeFirstResponder(nil)
        for mode in ["content", "visible"] {
            for rtl in [false, true] {
                state.rtl = rtl; try await setFit(mode)
                let revision = state.command.revision + 2
                state.send(.page(0)); state.send(.none)
                try await waitFor {
                    guard state.page == 0, state.command.revision >= revision, state.command.action == .none,
                          let scroll = state.readerScrollView, let first = state.readerFocusView else { return false }
                    let contentWidth: CGFloat = rtl ? 424 : 484
                    let factor = (scroll.contentView.bounds.width - 4) / (contentWidth - 4 + (mode == "visible" ? 4 : 0))
                    return abs(first.bounds.width - 200 * factor) <= pixelTolerance && rowContentIsVisible(mode: mode, contents: [firstContent, secondContent])
                }
                let scroll = try XCTUnwrap(state.readerScrollView), first = try XCTUnwrap(state.readerFocusView)
                let factor = first.bounds.width / 200
                let nextRowY = first.convert(.zero, to: scroll.documentView).y + 800 * factor + 4
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: nextRowY + 100))
                scroll.reflectScrolledClipView(scroll.contentView)
                // The second row's narrower content would choose a larger fit.
                // Ordinary scrolling must retain the reference row's zoom.
                try await waitFor {
                    guard state.page == 2, let current = state.readerFocusView else { return false }
                    return abs(current.bounds.width - 200 * factor) <= pixelTolerance && abs(current.bounds.height - 400 * factor) <= pixelTolerance
                }
                XCTAssertGreaterThan(state.location.y ?? 0, 0)
                let jumpRevision = state.command.revision + 2
                state.send(.page(2)); state.send(.none)
                // A real page jump supersedes the old scroll x/y. It selects a
                // new reference row without changing authored restore axes.
                try await waitFor {
                    guard state.page == 2, state.command.revision >= jumpRevision, state.command.action == .none,
                          let current = state.readerFocusView else { return false }
                    let contentWidth: CGFloat = rtl ? 384 : 374
                    let nextFactor = (scroll.contentView.bounds.width - 4) / (contentWidth - 4 + (mode == "visible" ? 4 : 0))
                    return abs(current.bounds.width - 200 * nextFactor) <= pixelTolerance && rowContentIsVisible(mode: mode, contents: [thirdContent, fourthContent])
                }
            }
        }
        XCTAssertNil(state.error)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    @MainActor
    func testPDFActiveFieldSurvivesPageRecyclingAndCommitsBeforeLayoutReplacement() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("virtualized-form.pdf")
        var objects = ["<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [11 0 R 13 0 R] /DA (/F1 12 Tf 0 g) /DR << /Font << /F1 12 0 R >> >> >> >>",
            "<< /Type /Pages /Count 8 /Kids [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R] >>"]
        for page in 0..<8 {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 800] /Resources << >>\(page < 2 ? " /Annots [\(page == 0 ? 11 : 13) 0 R]" : "") >>")
        }
        objects += ["<< /Type /Annot /Subtype /Widget /FT /Tx /T (input) /V (original) /Rect [20 720 220 750] /F 4 /DA (/F1 12 Tf 0 g) /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (second) /V (original second) /Rect [20 720 220 750] /F 4 /DA (/F1 12 Tf 0 g) /P 4 0 R >>"]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: input)
        let pages = try Pages(input, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = 8
        state.nativePDFInfo = try await pages.pdfInfo()
        state.flow = "continuous"; state.fit = "actual"; state.rotation = 0; state.spread = false; state.cover = false
        state.rtl = false; state.automaticLayout = false; state.uniformPageWidth = false; state.freePan = false
        state.trimEmptyMargins = false; state.rectangularSelection = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let defaults = UserDefaults.standard, previousFlow = defaults.object(forKey: "flow")
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            if let previousFlow { defaults.set(previousFlow, forKey: "flow") } else { defaults.removeObject(forKey: "flow") }
            withExtendedLifetime(directory) {}
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Native field lifecycle did not settle", line: line)
        }
        state.setPDFEditingEnabled(true)
        try await waitFor { state.canEditPDF && state.readerFocusView?.bounds.size == CGSize(width: 300, height: 800) }
        let canvas = try XCTUnwrap(state.readerFocusView), scroll = try XCTUnwrap(state.readerScrollView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(CGPoint(x: 80, y: 65), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        try await waitFor {
            if state.nativePDFFormEditor == nil { canvas.mouseDown(with: event) }
            return state.nativePDFFormEditor != nil
        }
        let editor = try XCTUnwrap(state.nativePDFFormEditor), field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "committed after scroll"
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1610)); scroll.reflectScrolledClipView(scroll.contentView)
        try await waitFor { state.page >= 2 }
        XCTAssertTrue(state.nativePDFFormEditor === editor)
        XCTAssertTrue(canvas.window === window, "The offscreen field host must survive visible-page recycling")
        XCTAssertEqual(field.stringValue, "committed after scroll")
        let beforeCommit = try await pages.pdfAnnotations(0)
        XCTAssertEqual(beforeCommit.first { $0.fieldName == "input" }?.value, "original")
        let targetPage = state.page, beforeInfo = try await pages.pdfInfo()
        func pageViews(_ view: NSView) -> Int {
            (type(of: view) == type(of: canvas) ? 1 : 0) + view.subviews.reduce(0) { $0 + pageViews($1) }
        }
        XCTAssertLessThanOrEqual(pageViews(host), 3, "Only the visible pages and active input host need views")
        state.setFlow("paged")
        try await waitFor { state.flow == "paged" && state.nativePDFFormEditor == nil && state.readerScrollView !== scroll }
        let fields = try await pages.pdfAnnotations(0), info = try await pages.pdfInfo()
        XCTAssertEqual(fields.first { $0.fieldName == "input" }?.value, "committed after scroll")
        XCTAssertEqual(info?.dirty, true)
        XCTAssertEqual(try XCTUnwrap(info).undoPosition, try XCTUnwrap(beforeInfo).undoPosition + 1)
        XCTAssertNil(field.superview)
        try await waitFor { canvas.window == nil }
        // A queued notification from the removed continuous viewport cannot
        // restore its earlier cursor after the paged layout takes ownership.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for _ in 0..<3 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        XCTAssertEqual(state.page, targetPage)
        // These direct layout menu actions can remove the other facing page.
        // Editing that page must commit before its native control is detached.
        for command in [ReaderMenuCommand.twoPages, .coverOnItsOwn] {
            state.cover = false; state.spread = true
            state.send(.page(0)); state.send(.none)
            func displayedPages(_ view: NSView) -> [NSView] {
                (type(of: view) == type(of: canvas) ? [view] : []) + view.subviews.flatMap(displayedPages)
            }
            try await waitFor { state.page == 0 && state.command.action == .none && displayedPages(host).count == 2 }
            let other = try XCTUnwrap(displayedPages(host).max { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x })
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: other.convert(CGPoint(x: 80, y: 65), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            try await waitFor {
                if state.nativePDFFormEditor == nil { other.mouseDown(with: click) }
                return state.nativePDFFormPage == 1 && state.nativePDFFormEditor != nil
            }
            let input = try XCTUnwrap(other.subviews.compactMap { $0 as? NSTextField }.first)
            input.stringValue = command.rawValue
            let before = try await pages.pdfInfo()
            command.run(state)
            try await waitFor { state.nativePDFFormEditor == nil && other.window == nil && (command == .twoPages ? !state.spread : state.cover) }
            let updated = try await pages.pdfAnnotations(1), after = try await pages.pdfInfo()
            XCTAssertEqual(updated.first { $0.fieldName == "second" }?.value, command.rawValue)
            XCTAssertEqual(try XCTUnwrap(after).undoPosition, try XCTUnwrap(before).undoPosition + 1)
            XCTAssertNil(input.superview)
        }
        XCTAssertNil(state.error)
        XCTAssertEqual(try Data(contentsOf: input), data)
    }

    @MainActor
    func testContentAreaOverlayDrawsTheMeasuredBorderWithoutEditingTheImage() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("content.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        bitmap.setFillColor(NSColor.black.cgColor); bitmap.fill(CGRect(x: 36, y: 50, width: 90, height: 170))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        let original = try Data(contentsOf: input)
        let pages = try Pages(input, format: .image), content = try await pages.contentBounds(0)
        let full = try await pages.bounds(0), state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.count = 1; state.flow = "paged"; state.fit = "custom"; state.zoom = 1
        state.spread = false; state.rotation = 90; state.trimEmptyMargins = false
        state.automaticLayout = false; state.uniformPageWidth = false; state.freePan = false
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        window.contentView = host
        addTeardownBlock { @MainActor in
            window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: "position:" + input.standardizedFileURL.path)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            withExtendedLifetime(directory) {}
        }
        func redBounds(_ view: NSView) -> CGRect? {
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: image)
            var rect = CGRect.null
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.redComponent > 0.8,
                          color.redComponent - color.greenComponent > 0.5,
                          color.redComponent - color.blueComponent > 0.5 else { continue }
                    rect = rect.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            guard !rect.isNull else { return nil }
            return rect.applying(CGAffineTransform(scaleX: view.bounds.width / CGFloat(image.pixelsWide),
                                                  y: view.bounds.height / CGFloat(image.pixelsHigh)))
        }
        let expectedSize = CGSize(width: 300, height: 200)
        for _ in 0..<50 where state.readerFocusView?.bounds.size != expectedSize {
            try await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
        let canvas = try XCTUnwrap(state.readerFocusView)
        XCTAssertEqual(canvas.bounds.size, expectedSize)
        XCTAssertNil(redBounds(canvas))
        let originalSize = canvas.bounds.size
        state.showFitContentArea = true
        let expected = content.applying(RasterLayout.transform(bounds: full, size: originalSize, rotation: 90)).insetBy(dx: -1, dy: -1)
        var drawn: CGRect?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            drawn = redBounds(canvas)
            if let drawn, abs(drawn.minX - expected.minX) <= 1, abs(drawn.minY - expected.minY) <= 1,
               abs(drawn.width - expected.width) <= 2, abs(drawn.height - expected.height) <= 2 { break }
        }
        let border = try XCTUnwrap(drawn)
        XCTAssertEqual(border.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(border.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(border.width, expected.width, accuracy: 2)
        XCTAssertEqual(border.height, expected.height, accuracy: 2)
        XCTAssertEqual(canvas.bounds.size, originalSize)
        XCTAssertTrue(canvas.visibleRect.intersects(canvas.bounds))
        XCTAssertEqual(state.fit, "custom"); XCTAssertEqual(state.zoom, 1)
        XCTAssertEqual(try Data(contentsOf: input), original)
        state.showFitContentArea = false
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        XCTAssertNil(redBounds(canvas))
    }

    @MainActor
    func testGIFFramesNavigateAsPagesAndKeepReadingPositionInBothLayouts() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("animation.gif")
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [NSColor.red, NSColor.blue] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(output))
        let pages = try Pages(input, format: .image), state = ReaderState()
        let previousHistorySetting = UserDefaults.standard.object(forKey: "disableReadingState")
        UserDefaults.standard.set(false, forKey: "disableReadingState")
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.count = 2; state.flow = "paged"; state.fit = "actual"; state.zoom = 1
        state.spread = false; state.automaticLayout = false; state.freePan = false
        state.rotation = 0; state.uniformPageWidth = false; state.trimEmptyMargins = false; state.scrollbarMode = "smart"
        let count = await pages.count
        XCTAssertEqual(count, 2)
        state.updatePosition(.init(page: 1))
        let key = "position:" + input.standardizedFileURL.path
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        window.contentView = host
        var layingOut = false, publishedDuringLayout = false
        let positionObserver = state.$page.dropFirst().sink { _ in
            if layingOut { publishedDuringLayout = true }
        }
        defer { positionObserver.cancel() }
        addTeardownBlock { @MainActor in
            window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: key)
            if let previousHistorySetting { UserDefaults.standard.set(previousHistorySetting, forKey: "disableReadingState") }
            else { UserDefaults.standard.removeObject(forKey: "disableReadingState") }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            withExtendedLifetime(directory) {}
        }

        func drawnColors() -> Set<String> {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var red = 0, blue = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.redComponent > 0.8, color.blueComponent < 0.2 { red += 1 }
                    if color.blueComponent > 0.8, color.redComponent < 0.2 { blue += 1 }
                }
            }
            var colors = Set<String>()
            if red >= 16 { colors.insert("red") }
            if blue >= 16 { colors.insert("blue") }
            return colors
        }
        func savedPosition() throws -> ReadingPosition {
            try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(UserDefaults.standard.data(forKey: key)))
        }
        func waitForPage(_ page: Int, colors: Set<String>) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                layingOut = true
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                layingOut = false
                if state.page == page, state.readerFocusView?.bounds.size == CGSize(width: 64, height: 64),
                   state.readerScrollView?.contentView.safeAreaRect.size == host.bounds.size,
                   state.location.x != nil, state.location.y != nil, drawnColors() == colors { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail("GIF page \(page) did not become visible: \(state.error ?? "no error")")
        }
        func checkStationary(_ page: Int, colors: Set<String>) async throws {
            state.persist()
            let saved = try savedPosition()
            XCTAssertEqual(saved.page, page)
            // Wait across multiple source frame durations: only navigation may
            // select another frame or change its persisted reading position.
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 40_000_000)
                layingOut = true
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                layingOut = false
                XCTAssertEqual(state.page, page)
                XCTAssertEqual(drawnColors(), colors)
                XCTAssertEqual(try savedPosition(), saved)
            }
        }

        try await waitForPage(1, colors: ["blue"])
        try await checkStationary(1, colors: ["blue"])
        for (direction, page, color) in [(-1, 0, "red"), (1, 1, "blue"), (-1, 0, "red")] {
            state.turn(direction)
            try await waitForPage(page, colors: [color])
            state.persist() // Window deactivation/close saves the latest frame.
            XCTAssertEqual(try savedPosition().page, page)
        }
        try await checkStationary(0, colors: ["red"])

        state.flow = "continuous"
        try await waitForPage(0, colors: ["red", "blue"])
        try await checkStationary(0, colors: ["red", "blue"])
        XCTAssertNil(state.error)
        XCTAssertFalse(publishedDuringLayout, "Native layout must not publish a reading page inside a SwiftUI update")
    }

    func testIndependentDocumentsShapeTextConcurrently() async throws {
        let input = try htmlFixture(String(repeating: "<p>Office affinity — العربية हिन्दी. Independent document layout.</p>", count: 60))
        @Sendable func snapshot(_ pages: Pages, fontSize: Double) async throws -> String {
            _ = try await pages.relayout(fontSize: fontSize, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
            let count = await pages.count, text = try await pages.text(0)
            let image = try await pages.image(0, width: 256)
            return "\(count):\(image.width)x\(image.height):\(text)"
        }
        let reference = try Pages(input, format: .html)
        var expected = [String]()
        for size in [17.0, 21.0, 17.0] { expected.append(try await snapshot(reference, fontSize: size)) }
        // Each window owns a separate actor and MuPDF context. HarfBuzz's
        // allocator still requires the same process-wide FreeType lock.
        try await withThrowingTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let pages = try Pages(input, format: .html)
                    var result = [String]()
                    for size in [17.0, 21.0, 17.0] {
                        await Task.yield()
                        result.append(try await snapshot(pages, fontSize: size))
                    }
                    return result
                }
            }
            for try await result in group { XCTAssertEqual(result, expected) }
        }
    }
    func testSelectionPrintCoordinatesIncludePageOriginAndExportDensity() {
        let source = CGRect(x: -20, y: 30, width: 400, height: 600)
        let destination = CGRect(x: 7, y: 11, width: 200, height: 300)
        let crop = CGRect(x: 20, y: 90, width: 120, height: 180)
        XCTAssertEqual(RasterLayout.pdfSelectionBounds(crop, source: source, destination: destination),
                       CGRect(x: 27, y: 191, width: 60, height: 90))
        XCTAssertEqual(RasterLayout.pdfSelectionBounds(source.insetBy(dx: -10, dy: -10), source: source, destination: destination), destination)
        XCTAssertTrue(RasterLayout.pdfSelectionBounds(CGRect(x: 500, y: 700, width: 10, height: 10), source: source, destination: destination).isNull)
    }
    func testSelectionSpeechMapsRepeatedTextAndUTF16AcrossPages() {
        let first = RasterSelection(text: "same 😀", rects: [], words: [
            .init(text: "same ", rect: [10, 20, 50, 10]), .init(text: "😀", rect: [60, 20, 10, 10])])
        let second = RasterSelection(text: "same", rects: [], words: [.init(text: "same", rect: [30, 40, 40, 10])])
        let firstPage = PageLocation(chapter: 0, page: 1), secondPage = PageLocation(chapter: 2, page: 0)
        let speech = RasterSpeechSelection([secondPage: second, firstPage: first])
        XCTAssertEqual(speech.text, "same 😀\nsame")
        XCTAssertEqual(speech.rectangles(for: NSRange(location: 5, length: 2)), [firstPage: [CGRect(x: 60, y: 20, width: 10, height: 10)]])
        XCTAssertEqual(speech.rectangles(for: NSRange(location: 8, length: 4)), [secondPage: [CGRect(x: 30, y: 40, width: 40, height: 10)]])
        XCTAssertEqual(Set(speech.rectangles(for: NSRange(location: 5, length: 7)).keys), [firstPage, secondPage])
        XCTAssertTrue(speech.rectangles(for: NSRange(location: 7, length: 1)).isEmpty)
    }
    func testNativeSelectionRetainsTheExactSelectedGlyphStream() async throws {
        let input = try htmlFixture("<p>Repeated text.</p><p>Repeated text.</p>")
        let pages = try Pages(input, format: .html)
        let text = try await pages.text(0) as NSString
        let last = text.range(of: "Repeated", options: .backwards)
        let rangeSelection = try await pages.selection(0, range: last)
        let first = try XCTUnwrap(rangeSelection.bounds.first), final = try XCTUnwrap(rangeSelection.bounds.last)
        let selected = try await pages.selection(0, from: CGPoint(x: first.minX, y: first.midY), to: CGPoint(x: final.maxX, y: final.midY), mode: 1)
        let words = try XCTUnwrap(selected.words)
        XCTAssertEqual(words.map(\.text).joined(), selected.text)
        XCTAssertTrue(selected.text.contains("Repeated"))
        XCTAssertTrue(words.filter { !$0.bounds.isEmpty }.allSatisfy { $0.bounds.midY >= first.minY })
        let location = PageLocation(page: 0)
        let speech = RasterSpeechSelection([location: selected])
        XCTAssertEqual(speech.rectangles(for: NSRange(location: 0, length: selected.text.utf16.count))[location], words.filter { !$0.bounds.isEmpty }.map(\.bounds))
        let box = CGRect(x: first.minX, y: first.minY, width: max(1, first.width / 2), height: first.height)
        let rectangular = try await pages.selection(from: 0, at: box.origin, to: 0, at: CGPoint(x: box.maxX, y: box.maxY), mode: 3)
        let region = try XCTUnwrap(rectangular[0])
        XCTAssertEqual(try XCTUnwrap(region.words).map(\.text).joined(), region.text)
        XCTAssertFalse(region.text.isEmpty)
    }
    func testIndependentMarginsUseTheNativeLayoutAndUniformRestoreReplacesThem() async throws {
        let input = try htmlFixture("<p>Margins follow the native text layout.</p>")
        let pages = try Pages(input, format: .html)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 20, font: "serif", theme: "light", userCSS: "body,p{margin:0;padding:0}", pageMargins: PageMargins(cssValues: [20]))
        let originalWords = try await pages.words(0)
        let original = try XCTUnwrap(originalWords.first { !$0.bounds.isEmpty })
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 20, font: "serif", theme: "light", userCSS: "body,p{margin:0;padding:0}", pageMargins: PageMargins(cssValues: "50 20 30 80"))
        let adjustedWords = try await pages.words(0)
        let adjusted = try XCTUnwrap(adjustedWords.first { !$0.bounds.isEmpty })
        XCTAssertEqual(adjusted.bounds.minX - original.bounds.minX, 60, accuracy: 1)
        XCTAssertEqual(adjusted.bounds.minY - original.bounds.minY, 30, accuracy: 1)
        _ = try await pages.restore(.init(margin: 20, pageMargins: PageMargins(cssValues: [20])))
        let restoredWords = try await pages.words(0)
        let restored = try XCTUnwrap(restoredWords.first { !$0.bounds.isEmpty })
        XCTAssertEqual(restored.bounds.minX, original.bounds.minX, accuracy: 1)
        XCTAssertEqual(restored.bounds.minY, original.bounds.minY, accuracy: 1)
    }
    func testSpeechStartsAtVisibleGlyphOrExplicitUTF16Cursor() async throws {
        let input = try htmlFixture("<p>First paragraph.</p><p>Second paragraph.</p>")
        let pages = try Pages(input, format: .html)
        let text = try await pages.text(0) as NSString
        let range = text.range(of: "Second")
        let selection = try await pages.selection(0, range: range)
        let visible = try XCTUnwrap(selection.bounds.first)
        let fragment = try await pages.speechFragment(0, visible: visible)
        XCTAssertEqual(fragment.offset, range.location)
        XCTAssertTrue(fragment.text.hasPrefix("Second"))
        let cursor = try await pages.speechFragment(0, visible: visible, offset: 0)
        XCTAssertEqual(cursor.offset, 0)
        XCTAssertEqual(cursor.text, text as String)
    }
    func testTransparentBackdropUsesNativeAlphaOnlyWhenRequested() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Alpha.svg")
        let bytes = Data("<svg xmlns='http://www.w3.org/2000/svg' width='128' height='128'><rect x='0' y='0' width='64' height='128' fill='red' opacity='0.5'/></svg>".utf8)
        try bytes.write(to: input)
        let pages = try Pages(input, format: .mupdf)
        let alpha = try await pages.image(0, width: 128, transparent: true), opaque = try await pages.image(0, width: 128)
        let transparent = NSBitmapImageRep(cgImage: alpha), original = NSBitmapImageRep(cgImage: opaque)
        XCTAssertEqual(try XCTUnwrap(transparent.colorAt(x: 100, y: 64)).alphaComponent, 0, accuracy: 0.01)
        let colored = try XCTUnwrap(transparent.colorAt(x: 32, y: 64)?.usingColorSpace(.sRGB))
        XCTAssertEqual(colored.alphaComponent, 0.5, accuracy: 0.02); XCTAssertGreaterThan(colored.redComponent, 0.98)
        XCTAssertEqual(try XCTUnwrap(original.colorAt(x: 100, y: 64)).alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }
    func testImagePrintKeepsIntrinsicDPIWithoutChangingSource() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("DPI.png"), output = directory.url.appendingPathComponent("Print.pdf")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(bitmap.makeImage()), bytes = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        try (bytes as Data).write(to: input)
        let pages = try Pages(input, format: .image)
        try await pages.exportPDF(to: output)
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL)), page = try XCTUnwrap(pdf.page(at: 1))
        XCTAssertEqual(page.getBoxRect(.mediaBox).width, 48, accuracy: 0.001)
        XCTAssertEqual(page.getBoxRect(.mediaBox).height, 24, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: input), bytes as Data)
    }
    func testLandscapeClassificationUsesOriginalImageGeometryAndReadingRotation() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for (index, size) in [(0, CGSize(width: 80, height: 120)), (1, CGSize(width: 200, height: 100)), (2, CGSize(width: 80, height: 80))] {
            let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            try ReaderImages.encoded(image, extension: "png").write(to: directory.url.appendingPathComponent("\(index).png"))
        }
        let pages = try Pages(directory.url, format: .comic)
        try await pages.seedImageBounds(page: 0, uniform: false)
        let normal = try await pages.landscapePages(rotation: 0), rotated = try await pages.landscapePages(rotation: 90)
        XCTAssertEqual(normal, [1]); XCTAssertEqual(rotated, [0])
    }
    func testEPUBDirectionUsesTheExistingOPFMetadataOwner() async throws {
        try requireMuPDF()
        for direction in [nil, "rtl", "ltr", "default"] as [String?] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            let files = ["mimetype": "application/epub+zip",
                         "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
                         "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='chapter' href='chapter.xhtml' media-type='application/xhtml+xml'/></manifest><spine\(direction.map { " page-progression-direction='\($0)'" } ?? "")><itemref idref='chapter'/></spine></package>",
                         "chapter.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>Reading direction</p></body></html>"]
            for (name, contents) in files { try contents.write(to: directory.url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory.url
            zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
            try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
            let pages = try Pages(directory.url.appendingPathComponent("book.epub"), format: .mupdf)
            let layout = try await pages.preferredLayout()
            XCTAssertEqual(layout.rtl, direction.map { $0 == "rtl" })
            XCTAssertEqual(layout.spread, direction == "rtl"); XCTAssertEqual(layout.cover, direction == "rtl")
        }
    }
    func testReflowBookmarkScalesWithinItsOriginalChapter() async throws {
        let url = try htmlFixture(String(repeating: "<p>A complete paragraph keeps the chapter position stable while changing its font size.</p>", count: 100))
        let pages = try Pages(url, format: .html)
        let oldCount = await pages.count, oldPage = oldCount/2
        let saved = try await pages.position(page: oldPage)
        XCTAssertEqual(saved.anchor, "0:\(oldPage):\(oldCount)")
        _ = try await pages.relayout(fontSize: 24, lineHeight: 1.6, margin: 40, font: "serif", theme: "light")
        let newCount = await pages.count
        XCTAssertNotEqual(oldCount, newCount)
        let restored = try await pages.restore(saved)
        let expected = min(newCount-1, max(0, Int((Double(oldPage+1)*Double(newCount)/Double(oldCount)).rounded())-1))
        XCTAssertEqual(restored.page, expected)
        let legacy = try await pages.restore(.init(anchor: "0:1"))
        XCTAssertEqual(legacy.page, 1)
    }
    func testNativeGlyphMapAndRectangleReuseTheExtractedTextOwner() async throws {
        let url = try htmlFixture("<p>First needle phrase.</p><p>Second line after a paragraph.</p>")
        let pages = try Pages(url, format: .html)
        let text = try await pages.text(0), words = try await pages.words(0)
        XCTAssertEqual(words.map(\.text).joined(), text)
        let range = (text as NSString).range(of: "needle")
        let selected = try await pages.selection(0, range: range)
        XCTAssertEqual(selected.text, "needle")
        XCTAssertFalse(selected.bounds.isEmpty)
        let box = selected.bounds.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -1, dy: -1)
        let rectangle = try await pages.selection(from: 0, at: box.origin, to: 0, at: CGPoint(x: box.maxX, y: box.maxY), mode: 3)
        XCTAssertTrue(rectangle[0]?.text.contains("needle") == true)
        XCTAssertFalse(rectangle[0]?.text.contains("Second") == true)
    }
    func testUniformAbsoluteZoomUsesFirstPageWidthWithoutAffectingFitModes() {
        let viewport = CGSize(width: 800, height: 600)
        let narrow = RasterLayout.size(page: CGSize(width: 300, height: 500), viewport: viewport, columns: 1, rotation: 0, fit: "custom", zoom: 2, uniformWidth: 600)
        let wide = RasterLayout.size(page: CGSize(width: 600, height: 500), viewport: viewport, columns: 1, rotation: 0, fit: "custom", zoom: 2, uniformWidth: 600)
        XCTAssertEqual(narrow.width, wide.width)
        XCTAssertEqual(narrow.height, 2000)
        let narrowAtLimit = RasterLayout.size(page: CGSize(width: 300, height: 500), viewport: viewport, columns: 1, rotation: 0, fit: "custom", zoom: 64, limit: 64, uniformWidth: 600)
        let wideAtLimit = RasterLayout.size(page: CGSize(width: 600, height: 500), viewport: viewport, columns: 1, rotation: 0, fit: "custom", zoom: 64, limit: 64, uniformWidth: 600)
        XCTAssertEqual(narrowAtLimit.width, wideAtLimit.width)
        XCTAssertEqual(narrowAtLimit.height, 64_000)
        XCTAssertEqual(RasterLayout.size(page: CGSize(width: 300, height: 500), viewport: viewport, columns: 1, rotation: 0, fit: "page", zoom: 2, uniformWidth: 600), RasterLayout.size(page: CGSize(width: 300, height: 500), viewport: viewport, columns: 1, rotation: 0, fit: "page", zoom: 2))
    }
    func testKeyboardSelectionKeepsUnicodeGraphemesAndWordBoundaries() {
        let text = "A👩‍💻é word"
        let first = RasterTextPosition.move(in: text, from: 1, backwards: false)
        XCTAssertEqual(first, 1 + "👩‍💻".utf16.count)
        XCTAssertEqual(RasterTextPosition.move(in: text, from: first, backwards: true), 1)
        let lastWord = (text as NSString).range(of: "word").location
        XCTAssertEqual(RasterTextPosition.move(in: text, from: text.utf16.count, backwards: true, byWord: true), lastWord)
        XCTAssertEqual(RasterTextPosition.move(in: text, from: 0, backwards: true), 0)
    }
    func testSelectionImageCropsBeforeApplyingReadingRotation() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let source = try XCTUnwrap(context.makeImage())
        let result = try RasterLayout.image(source, bounds: CGRect(x: -20, y: 10, width: 200, height: 100), crop: CGRect(x: -20, y: 10, width: 100, height: 60), rotation: 90)
        XCTAssertEqual(result.width, 60); XCTAssertEqual(result.height, 100)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: result).colorAt(x: 30, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.99); XCTAssertLessThan(color.blueComponent, 0.01)
    }
    func testGeneratedMarkdownHTMLComesFromTheRenderingHandler() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("source.md")
        try Data("# Title\n\n~~strike~~\n\n- [x] Complete\n\n| A | B |\n| - | - |\n| 1 | 2 |\n".utf8).write(to: input)
        let pages = try Pages(input, format: .mupdf)
        let html = try await pages.htmlSource()
        XCTAssertTrue(html?.contains("<table>") == true)
        XCTAssertTrue(html?.contains("<del>strike</del>") == true)
        XCTAssertTrue(html?.contains("checked") == true)
        let text = try await pages.text(0)
        XCTAssertTrue(text.contains("Title"))
    }
    func testPublisherCSSCanBeIgnoredAndUserCSSChangesCurrentLayout() async throws {
        let input = try htmlFixture(String(repeating: "<p>Publisher typography can be replaced by the existing reader controls.</p>", count: 50), head: "<style>p{font-size:40pt;line-height:4}</style>")
        let pages = try Pages(input, format: .html)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        let publisher = await pages.count
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 24, font: "serif", theme: "light", useDocumentCSS: false)
        let plain = await pages.count
        XCTAssertLessThan(plain, publisher)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 24, font: "serif", theme: "light", userCSS: "p {font-size:60pt !important}", useDocumentCSS: false)
        let custom = await pages.count
        XCTAssertGreaterThan(custom, plain)
    }
    func testComicOriginalBytesAndComicInfoUseTheOpenArchiveOwner() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 30, y: 40, width: 140, height: 220))
        let image = try XCTUnwrap(context.makeImage())
        let original = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try original.write(to: directory.url.appendingPathComponent("01.png"))
        try Data("<ComicInfo><Title>Original title</Title><Writer>A &amp; B</Writer><Pages><Page Image='0'/></Pages></ComicInfo>".utf8).write(to: directory.url.appendingPathComponent("ComicInfo.xml"))
        let pages = try Pages(directory.url, format: .comic)
        let extracted = try await pages.originalData(0), metadata = try await pages.metadata()
        XCTAssertEqual(extracted.data, original); XCTAssertEqual(extracted.filename, "01.png")
        XCTAssertEqual(metadata["Title"], "Original title"); XCTAssertEqual(metadata["Writer"], "A & B")
        let cropped = RasterLayout.contentBounds(image)
        XCTAssertGreaterThan(cropped.minX, 20); XCTAssertGreaterThan(cropped.minY, 30)
        XCTAssertLessThan(cropped.width, 160); XCTAssertLessThan(cropped.height, 240)
    }
    func testNativeCaseAndWholeWordOptionsUseRealTextQuads() async throws {
        let url = try htmlFixture("<p>Needle needle needled needle_ (needle) 猫 猫咪</p>")
        let pages = try Pages(url, format: .mupdf)
        let insensitive = try await pages.matches("needle", page: 0)
        let exact = try await pages.matches("needle", page: 0, options: .init(caseSensitive: true, wholeWord: true))
        let words = try await pages.matches("needle", page: 0, options: .init(wholeWord: true))
        XCTAssertEqual(insensitive.count, 5)
        XCTAssertEqual(exact.count, 2)
        XCTAssertEqual(words.count, 3)
        XCTAssertTrue(exact.allSatisfy { !$0.rects.isEmpty && $0.rects.allSatisfy { !$0.isEmpty } })
        let cjk = try await pages.matches("猫", page: 0, options: .init(wholeWord: true))
        XCTAssertEqual(cjk.count, 1)
    }
    func testHeightOrientationAndShrinkUseDistinctGeometry() {
        let page = CGSize(width: 420, height: 595)
        let height = RasterLayout.size(page: page, viewport: CGSize(width: 300, height: 600), columns: 1, rotation: 0, fit: "height", zoom: 1)
        XCTAssertEqual(height.height, 600, accuracy: 0.001)
        XCTAssertGreaterThan(height.width, 300)
        let landscape = CGSize(width: 900, height: 400)
        XCTAssertEqual(RasterLayout.size(page: page, viewport: landscape, columns: 1, rotation: 0, fit: "orientation", zoom: 1), RasterLayout.size(page: page, viewport: landscape, columns: 1, rotation: 0, fit: "width", zoom: 1))
        let portrait = CGSize(width: 400, height: 900)
        XCTAssertEqual(RasterLayout.size(page: page, viewport: portrait, columns: 1, rotation: 0, fit: "orientation", zoom: 1), RasterLayout.size(page: page, viewport: portrait, columns: 1, rotation: 0, fit: "page", zoom: 1))
        XCTAssertEqual(RasterLayout.size(page: page, viewport: CGSize(width: 2000, height: 2000), columns: 1, rotation: 0, fit: "shrink", zoom: 1), page)
    }
    func testContentFitUsesDrawingBoundsAndZoomDoesNotAllocateUnboundedCanvas() {
        let page = CGSize(width: 400, height: 600), viewport = CGSize(width: 800, height: 600)
        let content = CGRect(x: 80, y: 150, width: 100, height: 120)
        let full = RasterLayout.size(page: page, viewport: viewport, columns: 1, rotation: 0, fit: "page", zoom: 1)
        let fitted = RasterLayout.size(page: page, viewport: viewport, columns: 1, rotation: 0, fit: "content", zoom: 1, content: content)
        XCTAssertGreaterThan(fitted.width, full.width)
        XCTAssertEqual(content.height * fitted.height/page.height, viewport.height, accuracy: 0.001)
        let visible = RasterLayout.size(page: page, viewport: viewport, columns: 1, rotation: 0, fit: "visible", zoom: 1, content: content)
        XCTAssertEqual((content.width + 4) * visible.width/page.width, viewport.width, accuracy: 0.001)
        XCTAssertLessThan(content.width * visible.width/page.width, viewport.width)
        let huge = RasterLayout.size(page: CGSize(width: 20_000_000, height: 20_000_000), viewport: viewport, columns: 1, rotation: 0, fit: "custom", zoom: 64)
        XCTAssertLessThanOrEqual(huge.width, ReadingZoom.maximumCanvasExtent)
        XCTAssertLessThanOrEqual(huge.height, ReadingZoom.maximumCanvasExtent)
    }
    func testActualSizeUsesIntrinsicPageGeometryAcrossWindowChanges() {
        let page = CGSize(width: 420, height: 595)
        for viewport in [CGSize(width: 300, height: 400), CGSize(width: 1200, height: 900)] {
            for fit in ["actual", "custom"] {
                XCTAssertEqual(RasterLayout.size(page: page, viewport: viewport, columns: 1, rotation: 0, fit: fit, zoom: 1), page)
            }
        }
    }
    func testFitPageNeverExceedsItsRotatedSpreadSlot() {
        let viewport = CGSize(width: 804, height: 600)
        for rotation in [0, 90, 180, 270] {
            let size = RasterLayout.size(page: CGSize(width: 420, height: 595), viewport: viewport, columns: 2, rotation: rotation, fit: "page", zoom: 1)
            XCTAssertLessThanOrEqual(size.width, 400 + 1e-6)
            XCTAssertLessThanOrEqual(size.height, 600 + 1e-6)
        }
    }
    func testRotatedSelectionCoordinatesRoundTripNonzeroPageOrigins() {
        let bounds = CGRect(x: -20, y: 30, width: 420, height: 595)
        for rotation in [0, 90, 180, 270] {
            let size = RasterLayout.size(page: bounds.size, viewport: CGSize(width: 900, height: 700), columns: 1, rotation: rotation, fit: "width", zoom: 1.5)
            let transform = RasterLayout.transform(bounds: bounds, size: size, rotation: rotation)
            let displayed = bounds.applying(transform)
            XCTAssertEqual(displayed.minX, 0, accuracy: 0.001)
            XCTAssertEqual(displayed.minY, 0, accuracy: 0.001)
            XCTAssertEqual(displayed.width, size.width, accuracy: 0.001)
            XCTAssertEqual(displayed.height, size.height, accuracy: 0.001)
            let point = CGPoint(x: 100, y: 200).applying(transform).applying(transform.inverted())
            XCTAssertEqual(point.x, 100, accuracy: 0.001)
            XCTAssertEqual(point.y, 200, accuracy: 0.001)
        }
    }
    func testTileCoverageUsesExactPixelEdgesAtRotatedTrimmedViewports() throws {
        let bounds = CGRect(x: -20, y: 30, width: 420, height: 595)
        let trimmed = CGRect(x: 20, y: 70, width: 320, height: 420)
        let viewport = CGSize(width: 900, height: 700), pixelWidth = 420 * 128
        let pixelScale = CGFloat(pixelWidth) / bounds.width
        for rotation in [0, 90, 180, 270] {
            let display = RasterLayout.size(page: trimmed.size, viewport: viewport, columns: 1,
                rotation: rotation, fit: "custom", zoom: 64, limit: 64)
            let transform = RasterLayout.transform(bounds: trimmed, size: display, rotation: rotation)
            let visible = CGRect(x: display.width / 3, y: display.height / 2,
                width: viewport.width, height: viewport.height).applying(transform.inverted())
            let pixels = CGSize(width: pixelWidth, height: 595 * 128)
            let resolution = RasterLayout.tileResolution(pixels: rotation % 180 == 0 ? pixels : CGSize(width: pixels.height, height: pixels.width),
                maximum: CGSize(width: 2880, height: 1800), viewport: viewport, fit: "custom")
            let tiles = RasterLayout.tiles(bounds: bounds, pixelWidth: pixelWidth, resolution: resolution, visible: visible)
            XCTAssertFalse(tiles.isEmpty)
            XCTAssertLessThanOrEqual(tiles.count, 4, "A viewport must not queue the entire high-resolution page")
            let covered = tiles.reduce(CGRect.null) { $0.union($1.rect) }
            let requested = CGRect(x: (visible.minX - bounds.minX) * pixelScale, y: (visible.minY - bounds.minY) * pixelScale,
                width: visible.width * pixelScale, height: visible.height * pixelScale).integral
            XCTAssertTrue(covered.contains(requested), "Rotation and cropped, nonzero page origins must map to the same source pixels")
            XCTAssertLessThan(tiles.reduce(0) { $0 + $1.width * $1.height * 4 }, 64 * 1024 * 1024)
        }
        // Odd pixel dimensions split at integer edges, not ideal fractional
        // cell boundaries. A viewport on pixel 25 must include the second tile.
        let square = CGRect(x: 0, y: 0, width: 101, height: 101)
        let narrow = RasterLayout.tiles(bounds: square, pixelWidth: 101, resolution: 2,
            visible: CGRect(x: 25.01, y: 50.01, width: 0.02, height: 0.02))
        XCTAssertEqual(narrow.map(\.rect), [CGRect(x: 25, y: 50, width: 25, height: 25)])
    }

    func testNativePageTilesMatchWholePagePixelsAndHighZoomStaysBounded() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        // MuPDF clips and rounds diagonal stroke edges before rasterizing;
        // axis-aligned fills give an exact check of tile origins and coverage.
        let input = try tiledPDFFixture(in: directory.url, strokes: false)
        let pages = try Pages(input, format: .mupdf)
        let bounds = try await pages.bounds(0)
        let whole = try await pages.image(0, width: 841)
        func rgba(_ image: CGImage) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
        }
        let tiles = RasterLayout.tiles(bounds: bounds, pixelWidth: whole.width, resolution: 2, visible: bounds)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.width * $1.height }, whole.width * whole.height)
        for tile in tiles {
            let actual = try await pages.image(0, width: whole.width, region: tile.rect)
            XCTAssertEqual(actual.width, tile.width); XCTAssertEqual(actual.height, tile.height)
            let expected = try XCTUnwrap(whole.cropping(to: tile.rect))
            let actualBytes = try rgba(actual), expectedBytes = try rgba(expected)
            let firstDifference = zip(actualBytes, expectedBytes).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            XCTAssertEqual(actualBytes, expectedBytes, "Tile \(tile.rect) must preserve the full-page transform; first differing byte: \(String(describing: firstDifference))")
        }
        let high = try await pages.render(0, viewport: CGSize(width: 1000, height: 760), scale: 2,
            columns: 1, rotation: 0, fit: "custom", zoom: 64, maximumZoom: 64)
        XCTAssertGreaterThan(high.pixelWidth, 16384)
        XCTAssertGreaterThan(high.tileResolution, 0)
        XCTAssertLessThan(high.image.bytesPerRow * high.image.height, 16 * 1024 * 1024,
            "The high-zoom placeholder must not allocate a full high-resolution page")
        let visible = CGRect(x: bounds.minX + 210, y: bounds.minY + 200, width: 8, height: 6)
        let highTiles = RasterLayout.tiles(bounds: bounds, pixelWidth: high.pixelWidth, resolution: high.tileResolution, visible: visible)
        XCTAssertFalse(highTiles.isEmpty)
        for tile in highTiles {
            let image = try await pages.image(PageLocation(page: 0), width: high.pixelWidth, region: tile.rect)
            XCTAssertEqual(image.width, tile.width); XCTAssertEqual(image.height, tile.height)
            XCTAssertLessThan(image.bytesPerRow * image.height, 16 * 1024 * 1024)
        }
        // Raster coordinates above MuPDF's 2^24 absolute-bounds limit still
        // describe small, visible regions within a legitimately large canvas.
        let distant = try await pages.image(0, width: 1 << 26,
            region: CGRect(x: (1 << 24) + 1024, y: (1 << 24) + 1024, width: 64, height: 48))
        XCTAssertEqual(distant.width, 64); XCTAssertEqual(distant.height, 48)
        let pixels = try rgba(distant)
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains {
            pixels[$0] > 240 && pixels[$0 + 1] < 10 && pixels[$0 + 2] < 10
        }, "The distant tile must still contain the original red half of the page; first RGBA: \(Array(pixels.prefix(4)))")
    }

    func testNativeRenderCookieCancelsWithoutPoisoningTheNextRender() throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try tiledPDFFixture(in: directory.url), file = try NativeFile(input, engine: .mupdf)
        let clean = try NativeFile(input, engine: .mupdf).image(0, width: 420)
        typealias Render = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UnsafePointer<Int32>?, Int32,
            UnsafePointer<Int32>?, UnsafePointer<UInt32>?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        let render = unsafeBitCast(try XCTUnwrap(dlsym(file.library, "lf_render_cancelable_at")), to: Render.self)
        // Exercise the C boundary itself, before and after the page's display
        // list is cached. No timing assumption or implementation-layout access.
        for _ in 0..<2 {
            let cancelled = try NativeRenderCancellation(), next = try NativeRenderCancellation()
            cancelled.cancel()
            XCTAssertTrue(cancelled.isCancelled); XCTAssertFalse(next.isCancelled)
            var info = [Int32](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
            let pixels = render(file.document, 0, 0, 420, nil, 0, nil, nil, cancelled.handle, &info, &error)
            defer { free(pixels) }
            XCTAssertNil(pixels, "An aborted render must not return a partial page")
            XCTAssertThrowsError(try file.image(0, width: 420, cancellation: cancelled)) {
                XCTAssertTrue($0 is CancellationError, "Cancellation is not a reader error")
            }
            let restored = try file.image(0, width: 420, cancellation: next)
            XCTAssertEqual(restored.width, clean.width); XCTAssertEqual(restored.height, clean.height)
            XCTAssertEqual(try XCTUnwrap(restored.dataProvider?.data) as Data, try XCTUnwrap(clean.dataProvider?.data) as Data)
        }
    }

    func testTaskCancellationSignalsTheNativeCookieAndActorRemainsUsable() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try tiledPDFFixture(in: directory.url), cancellation = try NativeRenderCancellation()
        let cancelled = Task {
            try await withTaskCancellationHandler {
                withUnsafeCurrentTask { $0?.cancel() }
                XCTAssertTrue(cancellation.isCancelled, "Cancellation must reach native code without reentering the decoder actor")
                return try NativeFile(input, engine: .mupdf).image(0, width: 420, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled native rendering returned pixels") }
        catch is CancellationError {} catch { throw error }

        let pages = try Pages(input, format: .mupdf)
        let queued = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pages.image(0, width: 420)
        }
        do { _ = try await queued.value; XCTFail("Cancelled queued rendering returned pixels") }
        catch is CancellationError {} catch { throw error }
        let next = try await pages.render(0, viewport: CGSize(width: 420, height: 595), scale: 1,
            columns: 1, rotation: 0, fit: "actual", zoom: 1)
        XCTAssertEqual(next.image.width, 420)
        let tile = try await pages.image(PageLocation(page: 0), width: 420,
            region: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertEqual(tile.width, 64); XCTAssertEqual(tile.height, 48)
        XCTAssertTrue(cancellation.isCancelled, "Finishing a render must never reset another request's abort flag")
    }

    @MainActor
    func testHighZoomCanvasKeepsVectorDetailAfterPanningAndRotation() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), state = ReaderState()
        let input = try tiledPDFFixture(in: directory.url), pages = try Pages(input, format: .mupdf)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.count = await pages.count
        state.flow = "continuous"; state.fit = "custom"; state.zoom = 64; state.zoomLimit = 64
        state.spread = false; state.cover = false; state.automaticLayout = false; state.rotation = 0
        state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false
        state.showFitContentArea = false; state.showImageBounds = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.colorSpace = .sRGB; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            UserDefaults.standard.removeObject(forKey: "position:" + input.standardizedFileURL.path)
            withExtendedLifetime(directory) {}
        }
        let bounds = try await pages.bounds(0)
        var observed = "No canvas"
        func hasSharpBlueLine() -> Bool {
            guard let scroll = state.readerScrollView, let canvas = state.readerFocusView else { return false }
            let clip = scroll.contentView
            let transform = RasterLayout.transform(bounds: bounds, size: canvas.bounds.size, rotation: state.rotation)
            let point = clip.convert(CGPoint(x: bounds.minX + 210, y: bounds.minY + 200).applying(transform), from: canvas)
            observed = "canvas=\(canvas.bounds), visible=\(canvas.visibleRect), clip=\(clip.bounds), point=\(point), rotation=\(state.rotation)"
            guard clip.bounds.insetBy(dx: 2, dy: 2).contains(point),
                  let bitmap = clip.bitmapImageRepForCachingDisplay(in: clip.bounds) else { return false }
            // Capture the clipped viewport only. A 6400% page is intentionally
            // much larger than a reasonable bitmap or layer backing store.
            clip.cacheDisplay(in: clip.bounds, to: bitmap)
            let x = Int((point.x - clip.bounds.minX) * CGFloat(bitmap.pixelsWide) / clip.bounds.width)
            let y = Int((point.y - clip.bounds.minY) * CGFloat(bitmap.pixelsHigh) / clip.bounds.height)
            // colorAt returns a calibrated NSColor even when the bitmap has
            // an sRGB/display ICC profile. Convert the tagged CGImage instead.
            guard let pixel = bitmap.cgImage?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let sample = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = sample.data?.assumingMemoryBound(to: UInt8.self) else { return false }
            sample.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let red = Double(bytes[0]) / 255, green = Double(bytes[1]) / 255, blue = Double(bytes[2]) / 255
            observed += ", RGB=\(red),\(green),\(blue)"
            return blue > 0.9 && red < 0.1 && green < 0.1
        }
        func waitFor(line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertTrue(condition(), state.error ?? "The clipped high-zoom page did not retain its vector detail: \(observed)", line: line)
        }
        try await waitFor { state.readerScrollView != nil && state.readerFocusView != nil }
        for (rotation, anchor) in [(0, CGPoint(x: 206, y: 196)), (90, CGPoint(x: 206, y: 204)),
                                   (180, CGPoint(x: 214, y: 204)), (270, CGPoint(x: 214, y: 196))] {
            state.rotation = rotation
            state.send(.restore(.init(page: 0, x: Double(bounds.minX + anchor.x), y: Double(bounds.minY + anchor.y))))
            try await waitFor { hasSharpBlueLine() }
            let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
            let before = clip.bounds.origin
            clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 80, dy: 40)).origin)
            scroll.reflectScrolledClipView(clip)
            XCTAssertNotEqual(clip.bounds.origin, before)
            try await waitFor { hasSharpBlueLine() }
        }
        XCTAssertNil(state.error)
    }

    private func tiledPDFFixture(in directory: URL, strokes: Bool = true) throws -> URL {
        let input = directory.appendingPathComponent("tiled-page.pdf")
        var box = CGRect(x: -20, y: 30, width: 420, height: 595)
        let context = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &box, nil))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        context.beginPDFPage(nil)
        context.setFillColorSpace(colorSpace); context.setStrokeColorSpace(colorSpace)
        context.setFillColor([1, 1, 1, 1]); context.fill(box)
        context.setFillColor([1, 0, 0, 1])
        context.fill(CGRect(x: -20, y: 30, width: 210, height: 595))
        if strokes {
            context.setStrokeColor([0, 0, 1, 1]); context.setLineWidth(0.25)
            for offset in stride(from: 0, through: 420, by: 7) {
                context.move(to: CGPoint(x: offset - 20, y: 30)); context.addLine(to: CGPoint(x: 400 - offset, y: 625)); context.strokePath()
            }
        } else {
            let fills: [(CGRect, [CGFloat])] = [
                (CGRect(x: 10, y: 45, width: 70, height: 45), [0, 0, 1, 1]),
                (CGRect(x: 15, y: 400, width: 75, height: 80), [0, 1, 0, 1]),
                (CGRect(x: 220, y: 120, width: 110, height: 80), [0, 1, 1, 1]),
                (CGRect(x: 240, y: 475, width: 60, height: 100), [1, 0, 1, 1])
            ]
            for (rect, color) in fills {
                context.setFillColor(color); context.fill(rect)
            }
        }
        context.endPDFPage(); context.closePDF()
        return input
    }

    private func requireMuPDF() throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
    }
    private func epubFixture(in directory: URL, chapters: Int = 3, paragraphs: Int = 80) throws -> URL {
        let metadata = directory.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest>" + (0..<chapters).map { "<item id='c\($0)' href='c\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined() + "</manifest><spine>" + (0..<chapters).map { "<itemref idref='c\($0)'/>" }.joined() + "</spine></package>"
        ]
        for chapter in 0..<chapters {
            files["c\(chapter).xhtml"] = "<html xmlns='http://www.w3.org/1999/xhtml'><body>" + String(repeating: "<p>Chapter \(chapter) keeps the current page stable while earlier chapters are counted.</p>", count: paragraphs) + "</body></html>"
        }
        for (name, text) in files { try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip); XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("book.epub")
    }
    private func htmlFixture(_ body: String, head: String = "") throws -> URL {
        try requireMuPDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-raster-" + UUID().uuidString + ".html")
        try Data("<!doctype html><html><head><meta charset='utf-8'>\(head)</head><body>\(body)</body></html>".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor
    func testPDFContentBoundsIncludeVectorAndImageDrawingsAndPreservePageRotation() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Content.pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 80, y: 150, width: 100, height: 120))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.blue.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.draw(try XCTUnwrap(bitmap.makeImage()), in: CGRect(x: 260, y: 390, width: 40, height: 50))
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: input)), page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        try XCTUnwrap(document.dataRepresentation()).write(to: input, options: .atomic)
        let original = try Data(contentsOf: input), pages = try Pages(input, format: .pdf)
        let bounds = try await pages.contentBounds(0)
        // Fitz coordinates include the PDF's intrinsic clockwise rotation.
        XCTAssertEqual(bounds.minX, 150, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 80, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 290, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 220, accuracy: 0.01)
        let pageBounds = try await pages.bounds(0)
        XCTAssertEqual(pageBounds.size, CGSize(width: 600, height: 400))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testExternalTealOutlineUsesExistingNativeFragmentResolution() async throws {
        let input = try htmlFixture("<h1 id='bookmark1'>Target chapter</h1><p>Reader content</p>")
        let pages = try Pages(input, format: .html, outline: [.init(title: "Teal chapter", target: "#bookmark1")])
        let prepared = try await pages.prepare()
        XCTAssertEqual(prepared.outline.map(\.title), ["Teal chapter"])
        let destination = try await pages.resolve(prepared.outline[0].target)
        XCTAssertEqual(destination?.page, 0)
    }
    func testNativeSearchKeepsSeparateOccurrencesOnTheSamePage() async throws {
        let url = try htmlFixture("<p>needle marker needle</p>")
        let pages = try Pages(url, format: .html)
        let matches = try await pages.matches("needle", page: 0)
        XCTAssertEqual(matches.count, 2)
        guard matches.count == 2 else { return }
        XCTAssertNotEqual(matches[0].rects, matches[1].rects)
        XCTAssertTrue(matches.allSatisfy { $0.context.contains("needle marker needle") })
    }
    func testSearchSnippetsAcrossParagraphsExcludeSyntheticBreakGeometry() async throws {
        let padding = String(repeating: "段落𠮷其他文字", count: 12)
        let url = try htmlFixture("<p>FIRST needle marker-one. \(padding)</p><p>\(padding) SECOND needle marker-two.</p>")
        let pages = try Pages(url, format: .html)
        let words = try await pages.words(0), breaks = words.filter { $0.text == "\n" }
        XCTAssertFalse(breaks.isEmpty)
        XCTAssertTrue(breaks.allSatisfy { $0.bounds.isEmpty }, "Inserted separators must not select or intersect page content")
        let matches = try await pages.matches("needle", page: 0)
        XCTAssertEqual(matches.count, 2)
        guard matches.count == 2 else { return }
        XCTAssertTrue(matches[0].context.contains("FIRST needle marker-one"), matches[0].context)
        XCTAssertTrue(matches[1].context.contains("SECOND needle marker-two"), matches[1].context)
        XCTAssertTrue(matches.allSatisfy { $0.context.utf16.count < 120 }, "Each snippet must stay around its own occurrence")
    }
    @MainActor
    func testSearchPublishesCurrentPageFirstAndKeepsOrderedWrappedNavigation() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), url = directory.url.appendingPathComponent("search.pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: writer, flipped: false)
        for page in 0..<6 {
            writer.beginPDFPage(nil)
            NSAttributedString(string: "Page \(page) needle marker needle", attributes: [.font: NSFont.systemFont(ofSize: 14)])
                .draw(at: CGPoint(x: 40, y: 500))
            writer.endPDFPage()
        }
        NSGraphicsContext.restoreGraphicsState(); writer.closePDF()
        let firstOffset = "Page 0 ".utf16.count, lastOffset = "Page 0 needle marker ".utf16.count
        let targets = (0..<6).map { page in
            ["raster-search:\(page):\(firstOffset)", "raster-search:\(page):\(lastOffset)"]
        }
        for backwards in [false, true] {
            let pages = try Pages(url, format: .pdf), state = ReaderState(), start = backwards ? 0 : 5
            state.document = ReadingDocument(url: url, content: .pages(pages)); state.count = 6
            state.flow = "paged"; state.fit = "page"; state.spread = false; state.automaticLayout = false
            state.updatePosition(.init(page: start))
            let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            var firstResults: [String]?
            let observation = state.$searchResults.sink { results in
                if firstResults == nil, !results.isEmpty { firstResults = results.map(\.target) }
            }
            var searchStarts = 0
            let countingObservation = state.$searchCounting.sink { if $0 { searchStarts += 1 } }
            defer {
                observation.cancel(); countingObservation.cancel(); state.windowClosed(); window.contentView = nil; window.close()
                UserDefaults.standard.removeObject(forKey: "position:" + url.path)
                withExtendedLifetime(directory) {}
            }
            func wait(_ condition: () -> Bool, line: UInt = #line) async throws {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline && state.error == nil
                _ = try XCTUnwrap(condition() ? true : nil, "Search did not settle: \(state.error ?? state.status)", line: line)
            }
            try await wait { state.readerFocusView?.window === window && state.readerFocusView?.bounds.height ?? 0 > 0 }
            state.send(.find("needle", backwards: backwards))
            try await wait { state.searchResults.count == 12 && !state.searchCounting && state.status == state.searchCountText }
            XCTAssertEqual(firstResults, targets[start])
            XCTAssertEqual(state.searchResults.map(\.target), targets.flatMap { $0 })
            XCTAssertEqual(state.selectedSearchTarget, targets[start][backwards ? 1 : 0])
            state.send(.find("needle", backwards: backwards))
            try await wait { state.selectedSearchTarget == targets[start][backwards ? 0 : 1] }
            state.send(.find("needle", backwards: backwards))
            try await wait { state.selectedSearchTarget == targets[backwards ? 5 : 0][backwards ? 1 : 0] }
            let currentPage = backwards ? 5 : 0
            try await wait {
                guard let view = state.readerFocusView, view.window === window else { return false }
                return RasterReader.pageIsRendered(in: view, pages: pages, location: .init(page: currentPage))
            }
            let matchedCanvas = try XCTUnwrap(state.readerFocusView)
            state.send(.page(2))
            try await wait { state.page == 2 && state.readerFocusView?.window === window && state.readerFocusView !== matchedCanvas }
            let otherCanvas = try XCTUnwrap(state.readerFocusView)
            state.send(.page(currentPage))
            try await wait { state.page == currentPage && state.readerFocusView?.window === window && state.readerFocusView !== otherCanvas }
            state.send(.find("needle", backwards: backwards))
            try await wait { state.selectedSearchTarget == targets[currentPage][backwards ? 0 : 1] }
            // A completed empty search must clear the old result and settle;
            // repeating it must not leave the counter running. A later query
            // must still build its complete result list in either direction.
            for _ in 0..<2 {
                let starts = searchStarts
                state.send(.find("absent-term", backwards: backwards))
                try await wait { searchStarts > starts && !state.searchCounting && state.status == L("No matches") }
                XCTAssertTrue(state.searchResults.isEmpty)
                XCTAssertNil(state.selectedSearchTarget)
                XCTAssertFalse(state.searchCountCapped)
            }
            let starts = searchStarts
            state.send(.find("Page 5", backwards: backwards, options: .init(allowedPages: IndexSet(integersIn: 0..<5))))
            try await wait { searchStarts > starts && !state.searchCounting && state.status == L("No matches") }
            XCTAssertTrue(state.searchResults.isEmpty)
            state.send(.find("Page 5", backwards: backwards))
            try await wait { state.searchResults.count == 1 && !state.searchCounting }
            state.send(.find("needle", backwards: backwards))
            try await wait { state.searchResults.count == 12 && !state.searchCounting }
            XCTAssertEqual(state.searchResults.map(\.target), targets.flatMap { $0 })
            XCTAssertNil(state.error)
        }
    }

    @MainActor
    func testBoundedSearchCountsProbeTheNextPageAndNavigationKeepsItsOwnCursor() async throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for total in [999, 1000] {
            let url = directory.url.appendingPathComponent("search-\(total).pdf")
            var media = CGRect(x: 0, y: 0, width: 400, height: 600)
            let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: writer, flipped: false)
            writer.beginPDFPage(nil)
            for first in stride(from: 0, to: 999, by: 20) {
                NSAttributedString(string: String(repeating: "needle ", count: min(20, 999 - first)),
                    attributes: [.font: NSFont.systemFont(ofSize: 4)])
                    .draw(at: CGPoint(x: 20, y: CGFloat(550 - (first / 20) * 9)))
            }
            writer.endPDFPage(); writer.beginPDFPage(nil)
            NSAttributedString(string: total == 1000 ? "Tail needle" : "No other hits", attributes: [.font: NSFont.systemFont(ofSize: 14)])
                .draw(at: CGPoint(x: 40, y: 500))
            writer.endPDFPage(); NSGraphicsContext.restoreGraphicsState(); writer.closePDF()
            let pages = try Pages(url, format: .pdf), state = ReaderState()
            let text = try await pages.text(0) as NSString
            let offsets = try NSRegularExpression(pattern: "needle")
                .matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { $0.range.location }
            XCTAssertEqual(offsets.count, 999)
            guard offsets.count == 999 else { continue }
            let targets = offsets.map { "raster-search:0:\($0)" }
            state.document = ReadingDocument(url: url, content: .pages(pages)); state.count = 2
            state.flow = "paged"; state.fit = "page"; state.spread = false; state.cover = false; state.automaticLayout = false
            state.searchCaseSensitive = false; state.searchWholeWord = false; state.setSearchPageRange("")
            let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            var publications = 0
            let observation = state.$searchResults.sink { _ in publications += 1 }
            defer {
                observation.cancel(); state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
                UserDefaults.standard.removeObject(forKey: "position:" + url.path)
            }
            func wait(_ condition: () -> Bool, line: UInt = #line) async throws {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline && state.error == nil
                _ = try XCTUnwrap(condition() ? true : nil, "Bounded search did not settle: \(state.error ?? state.status)", line: line)
            }
            try await wait { state.readerFocusView?.window === window && state.readerScrollView != nil }
            // Queue a same-term repeat before the initial find has completed.
            // Whichever navigation wins must still start the bounded counter.
            state.send(.find("needle")); state.send(.find("needle"))
            try await wait {
                state.searchResults.count == 999 && state.selectedSearchTarget != nil && !state.searchCounting && state.status == state.searchCountText
            }
            XCTAssertEqual(state.searchResults.map(\.target), targets)
            XCTAssertEqual(state.searchCountCapped, total == 1000)
            let suffix = total == 1000 ? "+" : "", settledPublications = publications
            // Selecting the current term from Recent Searches must keep the
            // completed list; the following explicit find still advances it.
            state.showFind = true
            state.updateFindQuery("needle")
            XCTAssertEqual(state.searchResults.map(\.target), targets)
            XCTAssertEqual(state.searchCountCapped, total == 1000)
            state.send(.href(targets[998]))
            try await wait { state.selectedSearchTarget == targets[998] && state.status == "999 / 999\(suffix)" }
            state.findNext(inResults: false)
            let beyondList = total == 1000 ? "raster-search:1:\("Tail ".utf16.count)" : targets[0]
            try await wait { state.selectedSearchTarget == beyondList && state.status == state.searchCountText }
            XCTAssertEqual(state.searchCountText, total == 1000 ? "0 / 999+" : "1 / 999")
            XCTAssertEqual(state.searchResults.map(\.target), targets, "Inline navigation must not replace the bounded list")
            XCTAssertEqual(publications, settledPublications, "Inline navigation must not restart counting")

            // These are the floating find window's list-navigation commands.
            // From a document hit outside the list, forward enters its first row.
            state.findNext(inResults: true)
            try await wait {
                state.selectedSearchTarget == targets[total == 1000 ? 0 : 1] && state.status == state.searchCountText
            }
            state.send(.href(targets[998]))
            try await wait { state.selectedSearchTarget == targets[998] && state.status == state.searchCountText }
            state.findNext(inResults: true)
            try await wait { state.selectedSearchTarget == targets[0] && state.status == "1 / 999\(suffix)" }
            state.findNext(backwards: true, inResults: true)
            try await wait { state.selectedSearchTarget == targets[998] && state.status == "999 / 999\(suffix)" }
            XCTAssertEqual(publications, settledPublications, "Floating-list navigation must not clear or republish the counter")
            XCTAssertEqual(state.searchCountCapped, total == 1000)
            XCTAssertFalse(state.searchCounting)
            XCTAssertNil(state.error)
        }
    }

    func testCrossPageSelectionIsOrderedIndependentlyOfDragDirection() async throws {
        let body = "<p>BEGIN-MARKER</p>" + String(repeating: "<p>A paragraph with enough words to occupy multiple lines of the document.</p>", count: 120) + "<p>END-MARKER</p>"
        let url = try htmlFixture(body)
        let pages = try Pages(url, format: .html)
        let count = await pages.count
        XCTAssertGreaterThan(count, 1)
        let forward = try await pages.selection(from: 0, at: nil, to: count-1, at: nil)
        let reverse = try await pages.selection(from: count-1, at: nil, to: 0, at: nil)
        let text = forward.keys.sorted().compactMap { forward[$0]?.text }.joined(separator: "\n")
        XCTAssertTrue(text.contains("BEGIN-MARKER"))
        XCTAssertTrue(text.contains("END-MARKER"))
        XCTAssertEqual(forward.keys.sorted(), Array(0..<count))
        for page in 0..<count { XCTAssertEqual(forward[page]?.text, reverse[page]?.text) }
    }
    @MainActor
    func testMuPDFExportRetainsTextAndCurrentReflowGeometryWithoutChangingSource() async throws {
        let body = "<p>BEGIN-EXPORT-MARKER</p>" + String(repeating: "<p>Selectable text should remain selectable after PDF conversion.</p>", count: 110) + "<p>END-EXPORT-MARKER</p>"
        let input = try htmlFixture(body), original = try Data(contentsOf: input)
        let pages = try Pages(input, format: .html)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
        let count = await pages.count
        XCTAssertGreaterThan(count, 1)
        let output = input.deletingPathExtension().appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try await pages.exportPDF(to: output)
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, count)
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("BEGIN-EXPORT-MARKER"))
        XCTAssertTrue(text.contains("END-EXPORT-MARKER"))
        for index in 0..<count {
            let expected = try await pages.bounds(index)
            let bounds = try XCTUnwrap(pdf.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.minX, 0, accuracy: 0.01)
            XCTAssertEqual(bounds.minY, 0, accuracy: 0.01)
            XCTAssertEqual(bounds.width, expected.width, accuracy: 0.01)
            XCTAssertEqual(bounds.height, expected.height, accuracy: 0.01)
        }
        let selectedOutput = input.deletingPathExtension().appendingPathExtension("selected.pdf")
        defer { try? FileManager.default.removeItem(at: selectedOutput) }
        try await pages.exportPDF(to: selectedOutput, selectedPages: [count-1, 0, count-1])
        let selected = try XCTUnwrap(PDFDocument(url: selectedOutput))
        XCTAssertEqual(selected.pageCount, 3)
        XCTAssertTrue(try XCTUnwrap(selected.page(at: 0)?.string).contains("END-EXPORT-MARKER"))
        XCTAssertTrue(try XCTUnwrap(selected.page(at: 1)?.string).contains("BEGIN-EXPORT-MARKER"))
        XCTAssertEqual(selected.page(at: 0)?.string, selected.page(at: 2)?.string)
        let saved = try Data(contentsOf: selectedOutput)
        for indices in [[], [-1], [count]] {
            do { try await pages.exportPDF(to: selectedOutput, selectedPages: indices); XCTFail("Invalid page selection must fail") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: selectedOutput), saved)
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    @MainActor
    func testMuPDFVectorImageExportDoesNotReplacePathsWithAPageBitmap() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("shape.svg"), output = directory.url.appendingPathComponent("shape.pdf")
        let original = Data("<svg xmlns='http://www.w3.org/2000/svg' width='320' height='180' viewBox='-20 30 320 180'><path d='M -10 40 L 280 40 L 280 180 Z' fill='red'/></svg>".utf8)
        try original.write(to: input)
        let pages = try Pages(input, format: .image)
        try await pages.exportPDF(to: output)
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL)), page = try XCTUnwrap(pdf.page(at: 1))
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(page.getBoxRect(.mediaBox).size, CGSize(width: 320, height: 180))
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
        // A path-only SVG must remain vector commands, with no image/form XObjects.
        if CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xobjects) {
            XCTAssertEqual(CGPDFDictionaryGetCount(try XCTUnwrap(xobjects)), 0)
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        context.drawPDFPage(page)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide*3/4, y: bitmap.pixelsHigh/3)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.2)
        XCTAssertLessThan(color.blueComponent, 0.2)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    @MainActor
    func testImageIOExportStillPreservesPageGeometryAndInputBytes() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("image.png"), output = directory.url.appendingPathComponent("image.pdf")
        let context = try XCTUnwrap(CGContext(data: nil, width: 90, height: 60, bitsPerComponent: 8, bytesPerRow: 90*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 90, height: 60))
        let original = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        try original.write(to: input)
        let pages = try Pages(input, format: .image)
        try await pages.exportPDF(to: output)
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).size, CGSize(width: 90, height: 60))
        XCTAssertEqual(try Data(contentsOf: input), original)
        // This contract also runs in --core, where ImageIO and Quartz remain
        // available without a native engine. Inspect the actual PDF image grid.
        let quartz = try XCTUnwrap(CGPDFDocument(output as CFURL)), page = try XCTUnwrap(quartz.page(at: 1))
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &objects))
        var sizes = [CGSize]()
        CGPDFDictionaryApplyBlock(try XCTUnwrap(objects), { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                guard let dictionary = CGPDFStreamGetDictionary(stream) else { XCTFail("Image stream has no dictionary"); return true }
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height) {
                    sizes.append(CGSize(width: width, height: height))
                }
            }
            return true
        }, nil)
        XCTAssertEqual(sizes, [CGSize(width: 90, height: 60)])
    }
    @MainActor
    func testExportRejectsInputAliasesAndLeavesExistingOutputOnFailure() async throws {
        let input = try htmlFixture("<p>Unchanged source marker</p>"), original = try Data(contentsOf: input)
        let pages = try Pages(input, format: .html)
        let alias = input.deletingPathExtension().appendingPathExtension("alias.pdf")
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        do { try await pages.exportPDF(to: alias); XCTFail("Export must reject an input alias") }
        catch { XCTAssertTrue(error.localizedDescription.contains("different location")) }
        XCTAssertEqual(try Data(contentsOf: input), original)
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let child = directory.url.appendingPathComponent("must-stay.txt")
        try original.write(to: child)
        do { try await pages.exportPDF(to: directory.url); XCTFail("Export must reject replacing a folder") }
        catch { XCTAssertTrue(error.localizedDescription.contains("folder")) }
        XCTAssertEqual(try Data(contentsOf: child), original)
        let sentinel = Data("Existing output must survive cancellation".utf8)
        let output = input.deletingPathExtension().appendingPathExtension("cancelled.pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try sentinel.write(to: output)
        let task = Task {
            try Task.checkCancellation()
            try await pages.exportPDF(to: output)
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export must not succeed") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected export error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
}
#endif
