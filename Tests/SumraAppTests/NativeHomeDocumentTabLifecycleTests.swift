#if os(macOS)
import AppKit
import CryptoKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

/// Mounted scene/loading behavior only. Hidden windows and activation
/// notifications do not enter fullscreen or establish macOS Space acceptance.
@MainActor
final class NativeHomeDocumentTabLifecycleTests: XCTestCase {
    func testOriginalHomeBatchKeepsEveryDocumentWhenFirstComicIsActivatedAndDuplicated() async throws {
        let inputs = try originalInputs()
        defer {
            for input in inputs {
                XCTAssertEqual(try? checkpoint(input.url), input,
                    "The original fixture's bytes, size and modification date must remain unchanged")
            }
        }
        let fixture = Fixture()
        defer { fixture.close() }
        var payload = WindowPayload(recordsHistory: false)
        payload.tabIdentifier = "Native-Home-Document-" + UUID().uuidString
        let home = fixture.mount(payload)
        try await fixture.waitUntil("The real Home scene did not attach") { home.state != nil }
        let originalState = try XCTUnwrap(home.state)
        XCTAssertTrue(try XCTUnwrap(home.window.delegate as? ReaderCloseGuard).isHome)
        XCTAssertNil(home.payload.value.path)

        ReaderWindows.open(inputs.map(\.url), in: originalState, recordsHistory: false,
                           behavior: .newTab) { fixture.mount($0) }
        XCTAssertEqual(fixture.scenes.count, 6, "The first selected file must reuse Home")
        try await fixture.waitUntil("The six original documents did not finish loading") {
            fixture.scenes.allSatisfy {
                $0.state?.document != nil && $0.state?.busy == false &&
                    $0.payload.value.path == $0.state?.document?.url.path
            } && (fixture.scenes.last?.window.focusRequests ?? 0) > 0
        }
        let originals = fixture.scenes
        let states = try originals.map { try XCTUnwrap($0.state) }
        let documentIDs = try states.map { try XCTUnwrap($0.document?.id) }
        let group = try XCTUnwrap(home.window.tabGroup)
        XCTAssertEqual(originals.compactMap { $0.state?.document?.url }, inputs.map(\.url))
        XCTAssertEqual(home.payload.value.path, inputs[0].url.path,
                       "The reused Home's real scene binding must adopt the loaded CBR")
        try fixture.assertOwnership(of: originals)
        XCTAssertEqual(Set(group.windows.map(\.windowNumber)), Set(originals.map { $0.window.windowNumber }))

        // Deliver the native selection/activation lifecycle through the mounted
        // HostView observer, without activating or ordering the host desktop.
        let mobi = try XCTUnwrap(originals.first { $0.state?.document?.url.pathExtension == "mobi" })
        for scene in [mobi, home] {
            group.selectedWindow = scene.window
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: scene.window)
            try await fixture.waitUntil("Native selection did not settle on the requested document") {
                group.selectedWindow === scene.window
            }
            XCTAssertEqual(Set(group.windows.map(\.windowNumber)), Set(originals.map { $0.window.windowNumber }))
            XCTAssertTrue(home.state === originalState)
            XCTAssertEqual(home.state?.document?.id, documentIDs[0])
            try fixture.assertOwnership(of: originals)
        }

        originalState.createWindow = { [weak fixture] in fixture?.mount($0) }
        ReaderMenuCommand.duplicateTab.run(originalState)
        XCTAssertEqual(fixture.scenes.count, 7, "Duplicate must create exactly one additional scene")
        let duplicate = try XCTUnwrap(fixture.scenes.last)
        try await fixture.waitUntil("The duplicate CBR did not finish loading and selection") {
            duplicate.state?.document?.url == inputs[0].url && duplicate.state?.busy == false &&
                group.selectedWindow === duplicate.window
        }
        XCTAssertEqual(Set(group.windows.map(\.windowNumber)), Set(fixture.scenes.map { $0.window.windowNumber }))
        XCTAssertEqual(group.windows.count, 7)
        XCTAssertGreaterThan(duplicate.window.focusRequests, 0)
        for (index, scene) in originals.enumerated() {
            XCTAssertTrue(scene.state === states[index], "Tab selection must preserve each scene's reader")
            XCTAssertEqual(scene.state?.document?.id, documentIDs[index])
            XCTAssertTrue(scene.window.tabGroup === group)
        }
        XCTAssertTrue(home.state === originalState)
        XCTAssertNotEqual(duplicate.state?.document?.id, documentIDs[0])
        try fixture.assertOwnership(of: fixture.scenes)
    }

    private struct Checkpoint: Equatable {
        let url: URL
        let size: Int
        let modified: Date
        let digest: String
    }

    private func checkpoint(_ url: URL) throws -> Checkpoint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        return Checkpoint(url: url, size: try XCTUnwrap(values.fileSize),
                          modified: try XCTUnwrap(values.contentModificationDate), digest: digest)
    }

    private func originalInputs() throws -> [Checkpoint] {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE42_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("Set SUMRA_ISSUE42_FIXTURES to the original formatsampler directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let expected = [
            ("sample_comic.cbr", "9de19d3c796b4d84748bd8c08c7180959820b8c1f63701980358dc673338ba51"),
            ("sample_comic.cbz", "c71bcc7bbc4bcc8778c2a3c443ecb8d2d130e145c56e3301ed38a2fe98faaa9a"),
            ("sample_illustrated.azw3", "d4f2dd94f7b4208849b75ef564eec16481554ee501fcbf50ab29486773f46825"),
            ("sample_illustrated.epub", "672d0f8c8c95557b86086ea92e0211428ae2db2519e49054e3aa34e92ea9d6f1"),
            ("sample_illustrated.fb2", "408877f31fc9ad017ae061d94db3e8d3b810a148e40f53afa3b8cc28cc5fbac6"),
            ("sample_illustrated.mobi", "287543513806133a5772e3fa2d01d5448d9d14ad85d7ffa8bc5176724e4694ad")
        ]
        return try expected.map { name, digest in
            let input = try checkpoint(directory.appendingPathComponent(name))
            XCTAssertEqual(input.digest, digest, "Use the original issue #42 sample bytes: \(name)")
            return input
        }
    }

    @MainActor private final class Window: NSWindow {
        var focusRequests = 0
        override func makeKeyAndOrderFront(_ sender: Any?) {
            focusRequests += 1
            // Native WindowServer activation and Spaces belong to GUI acceptance.
        }
    }

    @MainActor private final class PayloadStore {
        var value: WindowPayload
        init(_ value: WindowPayload) { self.value = value }
    }

    @MainActor private final class Scene {
        let payload: PayloadStore
        let window: Window
        let host: NSHostingView<ReaderWindow>
        var state: ReaderState? { (window.delegate as? ReaderCloseGuard)?.state }
        var nativeHost: WindowTabs.HostView? {
            @MainActor func find(in view: NSView) -> WindowTabs.HostView? {
                (view as? WindowTabs.HostView) ?? view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return find(in: host)
        }

        init(_ request: WindowPayload, application: ReaderApplicationDelegate) {
            let store = PayloadStore(request)
            payload = store
            host = NSHostingView(rootView: ReaderWindow(
                payload: Binding(get: { store.value }, set: { store.value = $0 }), application: application))
            window = Window(contentRect: CGRect(x: 2400, y: 100, width: 800, height: 600),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.contentView = host
        }
    }

    @MainActor private final class Fixture {
        private let application: ReaderApplicationDelegate
        private let arguments: [String: Any]
        private let capture: (() -> Void)?
        private let restoring: [WindowPayload]
        private(set) var scenes = [Scene]()

        init() {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            capture = ScreenshotHotkey.capture
            restoring = SumraApp.restoring
            SumraApp.restoring = []
            defaults.setVolatileDomain(arguments.merging([
                "disableHistory": true, "disableReadingState": true, "disableTabs": false,
                "homePageViewMode": "list", "showContentsOnOpen": false,
                "documentOpenHistory": Data("[]".utf8), "pinnedDocuments": [String](),
                "pageAspectLayout": false, "automaticLayout": false,
                "immersiveControls": false, "toolbarDisplayMode": "shown"
            ]) { _, fixture in fixture }, forName: UserDefaults.argumentDomain)
            application = ReaderApplicationDelegate()
        }

        @discardableResult func mount(_ payload: WindowPayload) -> Scene {
            let scene = Scene(payload, application: application)
            scenes.append(scene)
            return scene
        }

        func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            repeat {
                for scene in scenes { scene.host.layoutSubtreeIfNeeded() }
                if condition() { return }
                let errors = scenes.compactMap { $0.state?.error }
                if !errors.isEmpty {
                    XCTFail("\(message): \(errors.joined(separator: "; "))")
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            XCTFail(message)
            throw CancellationError()
        }

        func assertOwnership(of scenes: [Scene], file: StaticString = #filePath, line: UInt = #line) throws {
            for scene in scenes {
                let owner = try XCTUnwrap(scene.window.delegate as? ReaderCloseGuard, file: file, line: line)
                let state = try XCTUnwrap(scene.nativeHost?.state, file: file, line: line)
                XCTAssertTrue(owner.state === state, file: file, line: line)
                XCTAssertTrue(state.window === scene.window, file: file, line: line)
                XCTAssertFalse(owner.isHome, file: file, line: line)
                XCTAssertFalse(state.isWindowClosed, file: file, line: line)
            }
        }

        func close() {
            for scene in scenes {
                for state in [scene.state, scene.nativeHost?.state].compactMap({ $0 }) where !state.isWindowClosed {
                    state.createWindow = nil
                    state.windowClosed()
                }
                scene.window.makeFirstResponder(nil)
                scene.window.contentView = nil
                scene.window.delegate = nil
                scene.window.orderOut(nil)
                scene.window.close()
            }
            scenes.removeAll()
            application.removeTabResponder()
            ScreenshotHotkey.capture = capture
            SumraApp.restoring = restoring
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
