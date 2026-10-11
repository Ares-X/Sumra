#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class FiniteReaderPredictionTests: XCTestCase {
    private func value(_ name: String, in object: Any) -> Any? {
        Mirror(reflecting: object).children.first { $0.label == name }?.value
    }

    private func unwrapped(_ object: Any?) -> Any? {
        guard let object else { return nil }
        let mirror = Mirror(reflecting: object)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : object
    }

    private func predictedPage(_ state: ReaderState) -> Int? {
        guard let canvas = state.readerFocusView,
              let token = unwrapped(value("finitePredictionStarted", in: canvas)),
              let request = value("request", in: token),
              let target = value("target", in: request) as? PageLocation else { return nil }
        return state.pageNumber(target)
    }

    private func waitForPrediction(_ target: Int, host: NSHostingView<RasterReader>, state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            if predictedPage(state) == target { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "Finite neighbor was not predicted")
        throw CancellationError()
    }

    private func comic(_ directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent("FinitePrediction", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for page in 0..<6 {
            let output = folder.appendingPathComponent("\(page + 1).png")
            let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 420,
                bitsPerComponent: 8, bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(page) / 6, green: 0.25, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 420))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return folder
    }

    func testSinglePagePredictionFollowsNavigationDirection() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let folder = try comic(directory.url)
        let pages = try Pages(folder, format: .comic)
        try await pages.seedImageBounds(page: 0, uniform: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: folder, content: .pages(pages))
        state.count = await pages.count; state.page = 2
        state.flow = "paged"; state.fit = "page"; state.spread = false
        state.automaticLayout = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 450),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }

        try await waitForPrediction(3, host: host, state: state)
        state.send(.preservePosition(.init(page: 1, x: 0, y: 0)))
        try await waitForPrediction(0, host: host, state: state)
        XCTAssertNil(state.error)
    }

    func testSpreadPredictionUsesNextRowAndReverseDirection() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let folder = try comic(directory.url)
        let pages = try Pages(folder, format: .comic)
        try await pages.seedImageBounds(page: 0, uniform: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: folder, content: .pages(pages))
        state.count = await pages.count; state.page = 2
        state.flow = "paged"; state.fit = "page"; state.spread = true; state.cover = false
        state.automaticLayout = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 450),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }

        try await waitForPrediction(4, host: host, state: state)
        state.send(.preservePosition(.init(page: 4, x: 0, y: 0)))
        state.send(.preservePosition(.init(page: 2, x: 0, y: 0)))
        try await waitForPrediction(1, host: host, state: state)
        XCTAssertNil(state.error)
    }
}
#endif
