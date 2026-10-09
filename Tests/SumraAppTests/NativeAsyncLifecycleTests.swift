#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class NativeAsyncLifecycleTests: XCTestCase {
    @MainActor
    private final class Lifetime {
        weak var pages: Pages?
        weak var view: NSView?
    }

    @MainActor
    private func mountedLifetime(_ state: ReaderState) throws -> Lifetime {
        guard case .pages(let pages) = state.document?.content else {
            XCTFail("Expected native document")
            throw CancellationError()
        }
        let view = try XCTUnwrap(state.readerFocusView)
        XCTAssertTrue(RasterReader.pageIsRendered(in: view, pages: pages, location: state.pageLocation(state.page)))
        let lifetime = Lifetime()
        lifetime.pages = pages
        lifetime.view = view
        return lifetime
    }

    @MainActor
    private func rendered(_ state: ReaderState, in window: NSWindow) -> Bool {
        guard !state.busy, state.count > 0, state.chapterLayout?.complete == true,
              case .pages(let pages) = state.document?.content,
              state.readerFocusView?.window === window else { return false }
        return RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page))
    }

    @MainActor
    private func waitUntil(_ message: String, host: NSHostingView<ReaderView>,
                           seconds: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            host.layoutSubtreeIfNeeded()
            autoreleasepool {}
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        XCTAssertTrue(condition(), message)
        guard condition() else { throw CancellationError() }
    }

    @MainActor
    private func checkMountedNativeLifetime(replacing: Bool) async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("MuPDF engine must be built before native integration tests")
        }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let markdown = directory.url.appendingPathComponent("mounted-native.md")
        try "# Native owner lifetime\n\nA small owned Markdown document with a rendered page.\n"
            .write(to: markdown, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let keys = ["useFixedPageUI", "disableReadingState", "disableHistory", "spread", "cover", "rtl"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: "useFixedPageUI")
        defaults.set(true, forKey: "disableReadingState")
        defaults.set(true, forKey: "disableHistory")
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            withExtendedLifetime(directory) {}
        }
        // This existing fixture owns its temporary source while the replacement
        // is opened through ReaderState, rather than installing a Pages stub.
        let pdf = replacing ? try nativePDFReadingFixture(pageCount: 2) : nil
        defer { withExtendedLifetime(pdf) {} }
        let state = ReaderState(recordsHistory: false)
        state.flow = "continuous"; state.fit = "page"
        state.spread = false; state.cover = false; state.rtl = false
        state.automaticLayout = false; state.freePan = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        state.window = window
        defer {
            state.windowClosed()
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        state.openWithoutHistory(markdown)
        try await waitUntil("Native Markdown did not finish counting and render: \(state.error ?? "no reader error")", host: host) {
            state.document?.url == markdown && self.rendered(state, in: window)
        }
        XCTAssertNil(state.error)
        let lifetime = try mountedLifetime(state)
        let documentID = state.document?.id

        if let pdf {
            state.openWithoutHistory(pdf.url)
            try await waitUntil("Native PDF replacement did not render: \(state.error ?? "no reader error")", host: host) {
                state.document?.id != documentID && state.document?.url == pdf.url && state.isPDF &&
                    state.count == 2 && self.rendered(state, in: window)
            }
            XCTAssertNil(state.error)
            XCTAssertTrue(window.contentView === host, "The replacement must release outgoing owners while its host stays mounted")
        } else {
            state.windowClosed()
            window.makeFirstResponder(nil)
            window.contentView = nil
            XCTAssertNil(state.document)
        }
        // ReaderView gives each document its own identity. The capture helper
        // returned only weak references, so these assertions cannot retain the
        // outgoing Pages through test locals. Pages owns RasterDocument/NativeFile.
        try await waitUntil("Outgoing native owner or rendered view survived \(replacing ? "replacement" : "close")", host: host) {
            lifetime.pages == nil && lifetime.view == nil
        }
        XCTAssertNil(lifetime.pages, "Outgoing native decoder ownership must end after reader teardown")
        XCTAssertNil(lifetime.view, "The outgoing rendered page view must end after reader teardown")
        withExtendedLifetime((host, window, state)) {}
    }

    @MainActor
    func testMountedNativeMarkdownReplacementWithPDFReleasesOwners() async throws {
        try await checkMountedNativeLifetime(replacing: true)
    }

    @MainActor
    func testClosingMountedNativeMarkdownReleasesOwners() async throws {
        try await checkMountedNativeLifetime(replacing: false)
    }
}
#endif
