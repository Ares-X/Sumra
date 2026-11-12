#if os(macOS)
import XCTest
import Combine
import SwiftUI
import PDFKit
import ImageIO
import SumraCore
@testable import Sumra

final class RapidNavigationTests: XCTestCase {
    @MainActor
    func testRapidScrollPublishesEveryPageOnceInOrder() async throws {
        try await exercise(spread: false, rtl: false)
    }

    @MainActor
    func testRapidScrollPublishesFacingPagesInReadingOrder() async throws {
        try await exercise(spread: true, rtl: true)
    }

    @MainActor
    func testClosingBeforePageCommandsAreHandledPersistsRequestedPosition() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "disableReadingState")
        defaults.set(false, forKey: "disableReadingState")
        defer {
            if let previous { defaults.set(previous, forKey: "disableReadingState") }
            else { defaults.removeObject(forKey: "disableReadingState") }
        }
        let actions: [(Int, (ReaderState) -> Void)] = [
            (3, { $0.turn(1) }), (0, { $0.firstPage() }),
            (9, { $0.lastPage() }), (7, { $0.go("8") })
        ]
        for (expected, action) in actions {
          for claimed in [false, true] {
            let state = ReaderState()
            let reading = try nativePDFReadingFixture(pageCount: 10)
            let key = "position:" + reading.url.standardizedFileURL.path
            defer { defaults.removeObject(forKey: key) }
            state.document = reading; state.count = 10; state.spread = false
            state.nativePDFInfo = try await state.nativePDF?.pdfInfo()
            state.updatePosition(.init(page: 2, x: 20, y: 30, anchor: "0:2"))
            action(state)
            if claimed { XCTAssertTrue(state.claimCommand(state.command, for: try XCTUnwrap(state.nativePDF))) }
            // Close before the request has been applied or acknowledged.
            state.windowClosed()
            let saved = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: key)))
            XCTAssertEqual(saved.page, expected)
            XCTAssertNil(saved.anchor); XCTAssertNil(saved.x); XCTAssertNil(saved.y)
          }
        }
    }

    @MainActor
    func testQueuedTurnsPreservePageLocalOffset() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "preservePageTurnPosition")
        defaults.set(true, forKey: "preservePageTurnPosition")
        defer {
            if let previous { defaults.set(previous, forKey: "preservePageTurnPosition") }
            else { defaults.removeObject(forKey: "preservePageTurnPosition") }
        }
        let document = PDFDocument()
        for size in [CGSize(width: 1200, height: 1400), CGSize(width: 1600, height: 1800)] {
            let page = PDFPage(); page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            document.insert(page, at: document.pageCount)
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(document)
        let pages = try XCTUnwrap(state.nativePDF)
        state.count = 2; state.flow = "paged"; state.fit = "actual"; state.zoom = 1
        state.spread = false; state.freePan = false; state.automaticLayout = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window; window.contentView = host
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Navigation did not settle", line: line)
        }
        try await waitFor { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) }
        let scroll = try XCTUnwrap(state.readerScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 240, y: 280))
        scroll.reflectScrolledClipView(scroll.contentView)
        let initial = try XCTUnwrap(RasterReader.pageLocalOffset(in: state.readerFocusView))
        XCTAssertGreaterThan(initial.x, 0); XCTAssertGreaterThan(initial.y, 0)
        var offsets: [PageLocalOffset] = []
        state.turn(1)
        state.send(.none) { if let offset = RasterReader.pageLocalOffset(in: state.readerFocusView) { offsets.append(offset) } }
        state.turn(-1)
        state.send(.none) { if let offset = RasterReader.pageLocalOffset(in: state.readerFocusView) { offsets.append(offset) } }
        try await waitFor { offsets.count == 2 && state.page == 0 }
        for offset in offsets {
            XCTAssertEqual(offset.x, initial.x, accuracy: 0.01)
            XCTAssertEqual(offset.y, initial.y, accuracy: 0.01)
        }
    }

    @MainActor
    func testQueuedScrollUsesDestinationGeometryBeforeTurningAgain() async throws {
        _ = NSApplication.shared
        let document = PDFDocument()
        for size in [CGSize(width: 200, height: 200), CGSize(width: 1100, height: 1200), CGSize(width: 200, height: 200)] {
            let page = PDFPage(); page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            document.insert(page, at: document.pageCount)
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(document)
        let pages = try XCTUnwrap(state.nativePDF)
        state.count = 3; state.flow = "paged"; state.fit = "actual"; state.zoom = 1
        state.spread = false; state.cover = false; state.rtl = false
        state.freePan = false; state.automaticLayout = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window; window.contentView = host
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Navigation did not settle: page=\(state.page), command=\(state.command)", line: line)
        }
        try await waitFor {
            guard let scroll = state.readerScrollView, let view = scroll.documentView else { return false }
            return view.frame.width <= scroll.contentView.bounds.width + 1 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        var published: [Int] = []
        let subscription = state.$page.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }
        state.scroll(.right, amount: .line)
        state.scroll(.right, amount: .line)
        for _ in 0..<2 {
            let revision = state.command.revision
            state.send(.none)
            try await waitFor { state.command.revision > revision && state.command.action == .none }
        }
        try await waitFor {
            guard let scroll = state.readerScrollView, let view = scroll.documentView else { return false }
            return RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 1)) &&
                view.frame.width > scroll.contentView.bounds.width && scroll.contentView.bounds.minX > 0
        }
        XCTAssertEqual(published, [1], "The second input must pan the large destination rather than skip it")
        XCTAssertEqual(state.page, 1)
    }

    @MainActor
    func testFailedDestinationDoesNotBlockQueuedCommands() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        for index in 0..<3 {
            let url = directory.url.appendingPathComponent("\(index).png")
            if index == 1 { try Data("broken page".utf8).write(to: url); continue }
            let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let archive = directory.url.appendingPathComponent("broken.cbz")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory.url
        zip.arguments = ["-q", "-0", archive.lastPathComponent, "0.png", "1.png", "2.png"]
        try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
        let pages = try Pages(archive, format: .comic)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: archive, content: .pages(pages))
        state.count = await pages.count; state.flow = "paged"; state.fit = "page"; state.spread = false
        state.automaticLayout = false; state.freePan = false; state.trimEmptyMargins = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window; window.contentView = host
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            _ = try XCTUnwrap(condition() ? true : nil, "Navigation did not settle: page=\(state.page), command=\(state.command), error=\(String(describing: state.error))", line: line)
        }
        try await waitFor { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) }
        state.scroll(.right, amount: .line)
        let revision = state.command.revision
        state.send(.none)
        try await waitFor { state.error != nil }
        try await waitFor { state.command.revision > revision && state.command.action == .none }
        XCTAssertNotNil(state.error, "A failed visible page must remain observable")

        // A request for the same failed page must also complete, even though
        // the canvas has already reported its failure before this request.
        let retryRevision = state.command.revision
        state.send(.page(1))
        state.send(.none)
        try await waitFor { state.command.revision > retryRevision && state.command.action == .none }
        XCTAssertNotNil(state.error)

        state.turn(1)
        let leaveRevision = state.command.revision
        state.send(.none)
        try await waitFor { state.command.revision > leaveRevision && state.command.action == .none }
        try await waitFor {
            state.page == 2 && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 2))
        }
    }

    @MainActor
    private func exercise(spread: Bool, rtl: Bool) async throws {
        _ = NSApplication.shared
        let document = PDFDocument()
        for index in 0..<12 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: CGFloat(280 + index * 3), height: CGFloat(360 + index * 7)), for: .mediaBox)
            document.insert(page, at: index)
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(document)
        let pages = try XCTUnwrap(state.nativePDF)
        state.count = 12; state.flow = "paged"; state.fit = "page"
        state.spread = spread; state.cover = false; state.rtl = rtl
        state.freePan = false; state.automaticLayout = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window; window.contentView = host
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }

        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil, state.error ?? "Navigation did not settle: page=\(state.page), command=\(state.command)", line: line)
        }
        func drain() async throws {
            // A scroll can enqueue a derived command behind the first marker.
            for _ in 0..<2 {
                let previous = state.command.revision
                state.send(.none)
                try await waitFor { state.command.revision > previous && state.command.action == .none }
            }
        }
        try await waitFor {
            state.readerFocusView?.window === window &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        var published: [Int] = []
        let subscription = state.$page.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }
        let forward: ReaderScrollDirection = rtl ? .left : .right
        let backward: ReaderScrollDirection = rtl ? .right : .left
        let step = spread ? 2 : 1

        for _ in 0..<4 { state.scroll(forward, amount: .line) }
        try await drain()
        XCTAssertEqual(published, (1...4).map { $0 * step }, "Forward burst must never replay older pages")
        published.removeAll()

        for _ in 0..<4 { state.scroll(backward, amount: .line) }
        try await drain()
        XCTAssertEqual(published, (0..<4).reversed().map { $0 * step }, "Backward burst must never replay older pages")
        published.removeAll()

        for direction in [forward, backward, forward, backward] { state.scroll(direction, amount: .line) }
        try await drain()
        XCTAssertEqual(published, [step, 0, step, 0], "Alternating input must retain its order")
        published.removeAll()

        for _ in 0..<4 { ReaderMenuCommand.next.run(state) }
        try await drain()
        XCTAssertEqual(published, (1...4).map { $0 * step }, "Menu turns must not replay older pages")
        published.removeAll()

        state.turn(-1)
        state.firstPage()
        state.lastPage()
        try await drain()
        XCTAssertEqual(published, [3 * step, 0, 11], "Absolute jumps and relative turns must retain input order")
        state.navigateHistory(-1)
        try await drain()
        XCTAssertEqual(state.page, 0, "Back must restore the intermediate first-page jump")
        state.navigateHistory(-1)
        try await drain()
        XCTAssertEqual(state.page, 3 * step, "Back again must restore the preceding relative turn")
        XCTAssertNil(state.error)
    }
}
#endif
