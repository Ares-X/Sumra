#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeTabHostTests: XCTestCase {
    func testClosingMountedTabDoesNotReconfigureItAsHome() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.makeReader(title: "first"), second = fixture.makeReader(title: "second")
        try await fixture.mount(first)
        try await fixture.mount(second, beside: first.window)
        let group = try XCTUnwrap(first.window.tabGroup)
        XCTAssertEqual(group.windows, [first.window, second.window])
        second.window.tabbingChanges.removeAll()

        second.window.performClose(nil)
        XCTAssertTrue(second.state.isWindowClosed, "Exercise the mounted HostView's native close notification")
        for _ in 0..<5 {
            second.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(group.windows, [first.window])
        XCTAssertFalse(second.window.tabbingChanges.contains { $0.mode == .disallowed },
            "A closed document scene must not become Home and alter AppKit's native tab teardown: \(second.window.tabbingChanges)")
        XCTAssertTrue(first.state.document != nil)
        XCTAssertTrue(first.state.window === first.window)
    }

    func testMountedTabMovesOnlyItselfFromAnotherNativeGroupToTheRequestedParent() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = fixture.makeReader(title: "requested")
        let unrelated = fixture.makeReader(title: "unrelated")
        let sibling = fixture.makeReader(title: "unrelated-sibling")
        let child = fixture.makeReader(title: "new-tab")
        try await fixture.mount(parent)
        try await fixture.mount(unrelated)
        try await fixture.mount(sibling, beside: unrelated.window)
        // SwiftUI/AppKit may have attached a scene before its native host is
        // installed. Exercise the existing group with real AppKit membership.
        unrelated.window.addTabbedWindow(child.window, ordered: .above)
        let otherGroup = try XCTUnwrap(unrelated.window.tabGroup)
        let otherSelection = otherGroup.selectedWindow
        let otherFrame = unrelated.window.frame
        try await fixture.mount(child, beside: parent.window)

        XCTAssertEqual(parent.window.tabGroup?.windows, [parent.window, child.window])
        XCTAssertEqual(otherGroup.windows, [unrelated.window, sibling.window])
        if otherSelection !== child.window { XCTAssertTrue(otherGroup.selectedWindow === otherSelection) }
        XCTAssertEqual(unrelated.window.frame, otherFrame)
        XCTAssertEqual(child.window.tabbingIdentifier, parent.window.tabbingIdentifier)
        XCTAssertTrue(child.state.window === child.window)
        XCTAssertTrue(child.window.styleMask.contains([.titled, .closable, .resizable]))
        XCTAssertNotNil(child.window.standardWindowButton(.closeButton))
        XCTAssertFalse(child.window.standardWindowButton(.closeButton)?.isHidden ?? true)
    }

    @MainActor private final class Window: NSWindow {
        struct Change: CustomStringConvertible {
            let mode: NSWindow.TabbingMode
            let groupCount: Int
            var description: String { "mode=\(mode.rawValue) group-count=\(groupCount)" }
        }
        var tabbingChanges = [Change]()
        override var tabbingMode: NSWindow.TabbingMode {
            didSet { tabbingChanges.append(Change(mode: tabbingMode, groupCount: tabGroup?.windows.count ?? 0)) }
        }
    }

    private struct HostContent: View {
        @ObservedObject var state: ReaderState
        let parent: Int?
        let identifier: String
        var body: some View {
            ZStack {
                if !state.isWindowClosed { Color.clear }
            }
            .background(WindowTabs(state: state, tabWith: parent, identifier: identifier,
                openingPath: state.document?.url.path, onWindowReady: {}))
        }
    }

    @MainActor private final class Fixture {
        struct Reader {
            let state: ReaderState
            let window: Window
        }
        private var readers = [Reader]()
        private let previousArguments: [String: Any]

        init() {
            _ = NSApplication.shared
            previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            var arguments = previousArguments
            arguments["disableTabs"] = false
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }

        func makeReader(title: String) -> Reader {
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-host-\(UUID().uuidString)-\(title).txt"),
                                             content: .text("Book " + title))
            let window = Window(contentRect: CGRect(x: 2400, y: 100, width: 640, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.title = title
            window.tabbingIdentifier = "Native-Host-" + UUID().uuidString
            let reader = Reader(state: state, window: window)
            readers.append(reader)
            return reader
        }

        func mount(_ reader: Reader, beside parent: NSWindow? = nil) async throws {
            let identifier = parent?.tabbingIdentifier ?? reader.window.tabbingIdentifier
            reader.window.contentView = NSHostingView(rootView: HostContent(state: reader.state,
                parent: parent?.windowNumber, identifier: identifier))
            let deadline = Date().addingTimeInterval(3)
            while reader.state.window !== reader.window, Date() < deadline {
                reader.window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(reader.state.window === reader.window, "The real NSViewRepresentable host must install its reader delegate")
        }

        func close() {
            for reader in readers {
                reader.window.contentView = nil
                reader.window.delegate = nil
                reader.window.close()
                if !reader.state.isWindowClosed { reader.state.windowClosed() }
            }
            UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
