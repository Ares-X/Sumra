#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class NativeTabReorderingTests: XCTestCase {
    func testThreeTabsMoveBothWaysWithNativeCaptionsSelectionAndContentTogether() throws {
        let fixture = Fixture(count: 3)
        defer { fixture.close() }
        let moving = fixture.windows[1]
        for _ in 0..<2 {
            for (direction, order) in [(-1, [1, 0, 2]), (-1, [1, 0, 2]),
                                       (1, [0, 1, 2]), (1, [0, 2, 1]),
                                       (1, [0, 2, 1]), (-1, [0, 1, 2])] {
                let frame = moving.frame
                fixture.states[1].moveTab(direction)
                XCTAssertEqual(moving.frame, frame)
                guard try assertPresentation(fixture, order: order, selected: moving) else { return }
            }
        }
    }

    func testTwoTabsKeepTheSelectedReaderWhenItsOnlyNeighborMovesAcrossIt() throws {
        let fixture = Fixture(count: 2)
        defer { fixture.close() }
        let moving = fixture.windows[1]
        for _ in 0..<3 {
            for (direction, order) in [(-1, [1, 0]), (-1, [1, 0]), (1, [0, 1]), (1, [0, 1])] {
                let frame = moving.frame
                fixture.states[1].moveTab(direction)
                XCTAssertEqual(moving.frame, frame)
                guard try assertPresentation(fixture, order: order, selected: moving) else { return }
            }
        }
    }

    func testStandaloneReaderCannotMoveOutsideItsOnlyTab() throws {
        let fixture = Fixture(count: 1)
        defer { fixture.close() }
        for direction in [-1, 1] { fixture.states[0].moveTab(direction) }
        XCTAssertEqual(fixture.windows[0].title, "PDF")
        XCTAssertEqual((fixture.windows[0].contentView as? NSTextField)?.stringValue, "body: PDF")
        XCTAssertEqual(fixture.windows[0].tabGroup?.windows ?? fixture.windows, fixture.windows)
    }

    // Read the actual public native accessibility tree: group.windows alone can
    // change while AppKit's visible captions and their actions stay in old slots.
    private func assertPresentation(_ fixture: Fixture, order: [Int], selected: NSWindow,
                                    file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let expected = order.map { fixture.windows[$0] }
        let group = try XCTUnwrap(selected.tabGroup, file: file, line: line)
        XCTAssertEqual(group.windows, expected, file: file, line: line)
        XCTAssertTrue(group.selectedWindow === selected, file: file, line: line)
        let tabs = try nativeTabs(in: selected)
        let titles = tabs.compactMap { $0.accessibilityTitle() }
        XCTAssertEqual(titles, expected.map(\.title), file: file, line: line)
        XCTAssertEqual(tabs.filter { ($0.accessibilityValue() as? NSNumber)?.boolValue == true }
            .compactMap { $0.accessibilityTitle() }, [selected.title], file: file, line: line)
        // Stop a failing replay before performing actions against stale captions.
        guard titles == expected.map(\.title) else { return false }
        for window in expected {
            let current = try XCTUnwrap(selected.tabGroup?.selectedWindow, file: file, line: line)
            let caption = try XCTUnwrap(try nativeTabs(in: current).first {
                $0.accessibilityTitle() == window.title
            }, file: file, line: line)
            XCTAssertTrue(caption.accessibilityPerformPress(), file: file, line: line)
            XCTAssertTrue(window.tabGroup?.selectedWindow === window, file: file, line: line)
            XCTAssertEqual(try nativeTabs(in: window)
                .filter { ($0.accessibilityValue() as? NSNumber)?.boolValue == true }
                .compactMap { $0.accessibilityTitle() }, [window.title], file: file, line: line)
            XCTAssertEqual(window.accessibilityTitle(), window.title, file: file, line: line)
            XCTAssertEqual(descendants(of: window).first { $0.accessibilityRole() == .staticText }?
                .accessibilityValue() as? String, "body: " + window.title, file: file, line: line)
        }
        selected.makeKeyAndOrderFront(nil)
        for (index, state) in fixture.states.enumerated() {
            XCTAssertTrue(state.window === fixture.windows[index], file: file, line: line)
            XCTAssertEqual(state.document?.id, fixture.documentIDs[index], file: file, line: line)
            XCTAssertEqual(state.document?.url.lastPathComponent, fixture.windows[index].title + ".txt", file: file, line: line)
        }
        return true
    }

    private func nativeTabs(in window: NSWindow) throws -> [any NSAccessibilityProtocol] {
        let bar = try XCTUnwrap(descendants(of: window).first { $0.accessibilityRole() == .tabGroup })
        return (bar.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            .filter { $0.accessibilityRole() == .radioButton }
    }

    private func descendants(of element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        let children = (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        return children.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor private final class Fixture {
        let states: [ReaderState]
        let windows: [NSWindow]
        let documentIDs: [UUID?]
        private let delegates: [ReaderCloseGuard]

        init(count: Int) {
            _ = NSApplication.shared
            let identifier = "Native-Reordering-" + UUID().uuidString
            states = ["PDF", "EPUB", "TXT"].prefix(count).map { title in
                let state = ReaderState(recordsHistory: false)
                state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-tab-order/\(title).txt"),
                                                 content: .text("body: " + title))
                return state
            }
            windows = states.map { state in
                let window = NSWindow(contentRect: CGRect(x: 2400, y: 100, width: 700, height: 400),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0; window.ignoresMouseEvents = true
                window.title = state.document!.url.deletingPathExtension().lastPathComponent
                window.contentView = NSTextField(labelWithString: "body: " + window.title)
                window.tabbingIdentifier = identifier
                state.window = window
                return window
            }
            documentIDs = states.map { $0.document?.id }
            delegates = states.map { ReaderCloseGuard(state: $0, previous: nil) }
            for index in windows.indices {
                windows[index].delegate = delegates[index]
                if index > 0 { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
            }
            if windows.count > 1 { windows[1].makeKeyAndOrderFront(nil) }
        }

        func close() {
            for (window, state) in zip(windows, states) {
                window.delegate = nil; window.orderOut(nil); window.close(); state.windowClosed()
            }
        }
    }
}
#endif
