#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ImageSpreadRestorationTests: XCTestCase {
    private let count = 31
    private let wide: Set<Int> = [3, 12, 23]

    private func fixture(in directory: URL, archived: Bool = false, unreadablePage: Int? = nil,
                         pageCount: Int? = nil, landscapes: Set<Int>? = nil) throws -> URL {
        let count = pageCount ?? self.count, wide = landscapes ?? self.wide
        let folder = directory.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names = [String]()
        for page in 0..<count {
            let name = "\(page + 1).png", url = folder.appendingPathComponent(name)
            names.append(name)
            if page == unreadablePage {
                try Data("unreadable earlier image".utf8).write(to: url)
                continue
            }
            let width = wide.contains(page) ? 200 : 100, height = wide.contains(page) ? 100 : 200
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(gray: CGFloat(page) / CGFloat(count), alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
        }
        guard archived else { return folder }
        let archive = directory.appendingPathComponent("Pages.cbz")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder; zip.arguments = ["-q", "-0", archive.path] + Array(names.reversed())
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        return archive
    }

    @MainActor
    private func makeState(url: URL, pages: Pages, pageCount: Int, page: Int, landscape: Set<Int>, recordsHistory: Bool = false) -> ReaderState {
        let state = ReaderState(recordsHistory: recordsHistory)
        state.document = ReadingDocument(url: url, content: .pages(pages))
        state.count = pageCount; state.flow = "paged"; state.fit = "page"
        state.spread = true; state.landscapeAsSpread = true; state.landscapePages = landscape
        state.cover = false; state.rtl = false; state.automaticLayout = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false
        state.updatePosition(.init(page: page))
        return state
    }

    @MainActor
    func testColdResumeAtPage117ReturnsThePrecedingFullPortraitPair() async throws {
        for archived in [false, true] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            // Reporter #137's stripped book has this topology; keep its
            // cover rule and all six landscape boundaries without its art.
            let landscapes: Set<Int> = [13, 20, 27, 88, 111, 116]
            let url = try fixture(in: directory.url, archived: archived, pageCount: 144, landscapes: landscapes)
            let pages = try Pages(url, format: .comic)
            try await pages.seedImageBounds(page: 116, uniform: false, rotation: 0)
            let landscape = try await pages.wholeSpreadPages(rotation: 0)
            XCTAssertEqual(landscape, landscapes)
            let state = makeState(url: url, pages: pages, pageCount: 144, page: 116, landscape: landscape)
            defer { state.windowClosed() }
            state.cover = true
            XCTAssertEqual(state.visiblePages, 116..<117)
            let previous = state.pageAfterTurning(-1, from: 116)
            XCTAssertEqual(previous, 114)
            XCTAssertEqual(state.pageRange(containing: previous), 114..<116)
            XCTAssertEqual(state.pageAfterTurning(1, from: previous), 116)
            XCTAssertEqual(state.pageAfterTurning(-1, from: previous), 112)
            XCTAssertEqual(state.pageAfterTurning(-2, from: previous), 111)
            XCTAssertEqual(state.pageAfterTurning(1, from: 111), 112)
            XCTAssertEqual(state.pageAfterTurning(2, from: 111), 114)
        }
    }

    @MainActor
    func testAllRowsAndBatchedTurnsUseTheSameCompleteTopologyBeforeAnyBitmap() async throws {
        for archived in [false, true] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let url = try fixture(in: directory.url, archived: archived)
            let pages = try Pages(url, format: .comic)
            try await pages.seedImageBounds(page: 23, uniform: false, rotation: 0)
            let landscape = try await pages.wholeSpreadPages(rotation: 0)
            let state = makeState(url: url, pages: pages, pageCount: count, page: 23, landscape: landscape)
            defer { state.windowClosed() }
            for cover in [false, true] {
                state.cover = cover
                let rows = PageRows.ranges(count: count, spread: true, cover: cover, landscape: wide)
                for rtl in [false, true] {
                    state.rtl = rtl
                    for index in rows.indices {
                        let current = rows[index].lowerBound
                        XCTAssertEqual(state.pageRange(containing: current), rows[index])
                        XCTAssertEqual(state.pageAfterTurning(-1, from: current), rows[max(0, index - 1)].lowerBound)
                        XCTAssertEqual(state.pageAfterTurning(1, from: current), rows[min(rows.count - 1, index + 1)].lowerBound)
                        XCTAssertEqual(state.pageAfterTurning(-6, from: current, toBottom: true), rows[max(0, index - 6)].upperBound - 1)
                    }
                }
            }
        }
    }

    @MainActor
    func testClosingWithTwelveQueuedPreviousTurnsPersistsTheirCompleteRowDestination() async throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableReadingState")
        defaults.set(false, forKey: "disableReadingState")
        defer { if let previous { defaults.set(previous, forKey: "disableReadingState") } else { defaults.removeObject(forKey: "disableReadingState") } }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = try fixture(in: directory.url, archived: true)
        let key = "position:" + url.standardizedFileURL.path
        defer { defaults.removeObject(forKey: key) }
        let pages = try Pages(url, format: .comic)
        try await pages.seedImageBounds(page: 23, uniform: false, rotation: 0)
        let landscape = try await pages.wholeSpreadPages(rotation: 0)
        let state = makeState(url: url, pages: pages, pageCount: count, page: 23, landscape: landscape, recordsHistory: true)
        for _ in 0..<12 { state.turn(-1) }
        state.windowClosed()
        let saved = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: key)))
        XCTAssertEqual(saved.page, 2)
    }

    @MainActor
    func testPendingLayoutStopsRelativePersistenceUntilAnAbsolutePageReestablishesIt() async throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableReadingState")
        defaults.set(false, forKey: "disableReadingState")
        defer { if let previous { defaults.set(previous, forKey: "disableReadingState") } else { defaults.removeObject(forKey: "disableReadingState") } }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = try fixture(in: directory.url)
        let key = "position:" + url.standardizedFileURL.path
        defer { defaults.removeObject(forKey: key) }
        for absolute in [false, true] {
            let pages = try Pages(url, format: .comic)
            let state = makeState(url: url, pages: pages, pageCount: count, page: 23, landscape: [], recordsHistory: true)
            state.spread = false
            ReaderMenuCommand.twoPages.run(state)
            XCTAssertEqual(state.command.action, .preservePosition(state.currentPosition))
            for _ in 0..<12 { state.turn(-1) }
            if absolute { state.go("8"); state.turn(-1) }
            state.windowClosed()
            let saved = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: key)))
            XCTAssertEqual(saved.page, absolute ? 4 : 23)
        }
    }

    func testCompleteHeaderTopologyReusesMeasuredBoundsAcrossRotations() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = try fixture(in: directory.url)
        let pages = try Pages(url, format: .comic)
        try await pages.seedImageBounds(page: 19, uniform: false, rotation: 0)
        try FileManager.default.removeItem(at: url)
        let rotated = try await pages.wholeSpreadPages(rotation: 90, complete: true)
        XCTAssertEqual(rotated, Set((0..<count).filter { !wide.contains($0) }))
        let original = try await pages.wholeSpreadPages(rotation: 0, complete: true)
        XCTAssertEqual(original, wide)
    }

    @MainActor
    func testUnreadableLaterImageOwnsItsErrorRowAndDoesNotBlockQueuedRecovery() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = try fixture(in: directory.url, archived: true, unreadablePage: 5)
        let pages = try Pages(url, format: .comic)
        try await pages.seedImageBounds(page: 0, uniform: false, rotation: 0)
        let wholeSpread = try await pages.wholeSpreadPages(rotation: 0)
        XCTAssertEqual(wholeSpread, wide.union([5]))
        let state = makeState(url: url, pages: pages, pageCount: count, page: 0, landscape: wholeSpread)
        XCTAssertEqual(state.pageRange(containing: 5), 5..<6)
        XCTAssertEqual(state.pageRange(containing: 4), 4..<5)
        XCTAssertEqual(state.pageRange(containing: 6), 6..<8)
        var originalError: NSError?
        do { _ = try await pages.bounds(5); XCTFail("An unreadable image must retain its dimension error") }
        catch { originalError = error as NSError }
        let expectedError = try XCTUnwrap(originalError)
        // Reindexing a different rotation must reuse the recorded failure,
        // while valid images are still classified in that new rotation.
        let rotated = try await pages.wholeSpreadPages(rotation: 90, complete: true)
        XCTAssertEqual(rotated, Set((0..<count).filter { !wide.contains($0) }).union([5]))
        do { _ = try await pages.bounds(5); XCTFail("The failed page must not acquire invented bounds") }
        catch { XCTAssertEqual((error as NSError).localizedDescription, expectedError.localizedDescription) }
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            _ = try XCTUnwrap(condition() ? true : nil, "Queued image navigation did not settle")
        }
        try await waitFor { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) }
        state.send(.page(5))
        var completed = false
        state.send(.none) { completed = true }
        try await waitFor { completed && state.error != nil }
        XCTAssertEqual(state.error, expectedError.localizedDescription)
        XCTAssertEqual(state.page, 5)
        completed = false
        state.turn(1)
        state.send(.none) { completed = true }
        try await waitFor {
            completed && state.page == 6 && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 6))
        }
        XCTAssertEqual(state.visiblePages, 6..<8)
    }

    func testMissingImageDataStillStopsCompleteIndexing() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = try fixture(in: directory.url)
        let pages = try Pages(url, format: .comic)
        try FileManager.default.removeItem(at: url.appendingPathComponent("6.png"))
        do {
            try await pages.seedImageBounds(page: 0, uniform: false, rotation: 0)
            XCTFail("A source read failure must propagate instead of becoming an image error row")
        } catch is CancellationError { XCTFail("A missing source must retain its read error") }
        catch {}
        let known = try await pages.wholeSpreadPages(rotation: 0)
        XCTAssertFalse(known.contains(5))
    }

    @MainActor
    func testMountedRotationReplacesLandscapeClassificationBeforeQueuedTurns() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = try fixture(in: directory.url)
        let pages = try Pages(url, format: .comic)
        try await pages.seedImageBounds(page: 23, uniform: false, rotation: 0)
        let landscape = try await pages.wholeSpreadPages(rotation: 0)
        let state = makeState(url: url, pages: pages, pageCount: count, page: 23, landscape: landscape)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertTrue(condition(), state.error ?? "Image spread did not settle")
        }
        try await waitFor { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 23)) }
        var completed = false
        state.rotate(90)
        state.send(.none) { completed = true }
        try await waitFor { completed }
        XCTAssertEqual(state.landscapePages, Set((0..<count).filter { !wide.contains($0) }))
        completed = false
        state.rotate(-90)
        state.send(.none) { completed = true }
        try await waitFor { completed }
        XCTAssertEqual(state.landscapePages, wide)
        XCTAssertEqual(state.pageRange(containing: 23), 23..<24)
    }
}
#endif
