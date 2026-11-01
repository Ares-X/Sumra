#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import Vision
import XCTest
@testable import Sumra

@MainActor
final class ReaderOpeningPresentationTests: XCTestCase {
    func testOrdinaryDocumentPayloadPaintsOpeningBeforeItsLoadTaskStarts() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("new-tab.txt")
        try "The selected document belongs in the new tab.".write(to: input, atomically: true, encoding: .utf8)
        let fixture = Fixture(payload: WindowPayload(path: input.path, recordsHistory: false))
        defer { fixture.close() }

        // Render the production window's presentation composition separately
        // from its .task. NSHostingView starts scene tasks during layout, which
        // cannot reproduce the pre-load frame seen in a real SwiftUI scene.
        let snapshot = try fixture.snapshot(named: "ordinary-payload-first-paint")
        let state = try fixture.state()
        XCTAssertEqual(state.generation, 0, "The first-frame check must precede document loading")
        XCTAssertFalse(state.busy, "Setting busy=true before hosting would miss this regression")
        XCTAssertNil(state.document)
        XCTAssertNil(state.restoredPayload, "A normal new tab must exercise the non-restoration path")
        XCTAssertTrue(snapshot.contains("Opening"), "The selected file must own the first frame: \(snapshot)")
        assertNoWelcome(in: snapshot)
    }

    func testEmptyPayloadStillPaintsWelcomeOnItsFirstFrame() throws {
        let fixture = Fixture(payload: WindowPayload())
        defer { fixture.close() }
        let snapshot = try fixture.snapshot(named: "empty-payload-first-paint")
        XCTAssertTrue(snapshot.contains("PDF, books, comics"), "A genuinely empty window still needs Welcome: \(snapshot)")
        XCTAssertTrue(snapshot.contains("Open Document"), snapshot)
        XCTAssertTrue(snapshot.contains("Recent Documents"), snapshot)
        XCTAssertFalse(snapshot.contains("Opening"), snapshot)
    }

    func testFailedOrdinaryOpenLeavesOpeningAndReturnsToAnUsableWelcome() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let missing = directory.url.appendingPathComponent("missing-new-tab.txt")
        let fixture = Fixture(payload: WindowPayload(path: missing.path, recordsHistory: false))
        defer { fixture.close() }
        let first = try fixture.snapshot(named: "failed-payload-first-paint")
        let initialState = try fixture.state()
        XCTAssertEqual(initialState.generation, 0)
        XCTAssertFalse(initialState.busy)
        XCTAssertTrue(first.contains("Opening"), first)
        assertNoWelcome(in: first)

        fixture.mount()
        let state = try fixture.state()
        let deadline = Date().addingTimeInterval(5)
        while state.missingFile == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state.missingFile, missing, "The real scene load must reach its failure result")
        XCTAssertNotNil(state.error)
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.document)
        let failed = try fixture.snapshot(named: "failed-payload-after-load")
        XCTAssertFalse(failed.contains("Opening"), "A failed load must not leave a permanent spinner: \(failed)")
        XCTAssertTrue(failed.contains("Open Document"), "Opening another file must remain available: \(failed)")
        XCTAssertTrue(failed.contains("Recent Documents"), failed)
    }

    private func assertNoWelcome(in snapshot: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in ["PDF, books, comics", "Open Document", "Recent Documents", "No Recent Documents"] {
            XCTAssertFalse(snapshot.contains(text), "Welcome must never flash while opening: \(snapshot)", file: file, line: line)
        }
    }

    @MainActor
    private final class Fixture {
        let host: NSHostingView<ReaderView>
        let window: NSWindow
        private let scene: ReaderWindow
        private let initialState: ReaderState
        private var lifecycleHost: NSHostingView<ReaderWindow>?
        private let application: ReaderApplicationDelegate
        private let arguments: [String: Any]
        private let capture: (() -> Void)?
        private let restoring: [WindowPayload]

        init(payload: WindowPayload) {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            capture = ScreenshotHotkey.capture
            restoring = SumraApp.restoring
            SumraApp.restoring = []
            defaults.setVolatileDomain(arguments.merging([
                "language": "en", "disableHistory": true, "disableReadingState": true,
                "disableTabs": true, "homePageViewMode": "list",
                "documentOpenHistory": Data("[]".utf8), "pinnedDocuments": [String]()
            ]) { _, fixture in fixture }, forName: UserDefaults.argumentDomain)
            application = ReaderApplicationDelegate()
            scene = ReaderWindow(payload: .constant(payload), application: application)
            initialState = ReaderState(recordsHistory: false)
            host = NSHostingView(rootView: scene.readerView(for: initialState))
            window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 900, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 650)
        }

        func mount() {
            let mounted = NSHostingView(rootView: scene)
            lifecycleHost = mounted
            window.contentView = mounted
            mounted.layoutSubtreeIfNeeded()
        }

        func state() throws -> ReaderState {
            guard let lifecycleHost else { return initialState }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return try XCTUnwrap(descendants(lifecycleHost).compactMap { ($0 as? WindowTabs.HostView)?.state }.first)
        }

        func snapshot(named name: String) throws -> String {
            let host: NSView = (lifecycleHost as NSView?) ?? self.host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            // OCR checks actual painted UI, including SwiftUI's virtual text.
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let state = try state()
            var evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("build/feedback-68-69-20261030/newtab-opening", isDirectory: true)
            if let phase = ProcessInfo.processInfo.environment["SUMRA_OPENING_EVIDENCE_PHASE"] {
                evidence.appendPathComponent(phase, isDirectory: true)
            }
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent(name + ".png"))
            let report: [String: Any] = ["text": text, "generation": state.generation, "busy": state.busy,
                                         "hasDocument": state.document != nil, "error": state.error ?? "",
                                         "width": image.width, "height": image.height]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent(name + ".json"))
            return text
        }

        func close() {
            // Close the scene before detaching its representables so its load,
            // file observation, and view-owned tasks lose their native owner.
            if lifecycleHost != nil { try? state().windowClosed() }
            initialState.windowClosed()
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.orderOut(nil)
            window.close()
            lifecycleHost = nil
            application.removeTabResponder()
            ScreenshotHotkey.capture = capture
            SumraApp.restoring = restoring
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
