#if os(macOS)
import XCTest
import PDFKit
import SwiftUI
@testable import Sumra

final class ReaderConfiguredCommandTests: XCTestCase {
    @MainActor func testPageLayoutCommandsShareMenusConfigurationAndToolbar() throws {
        let state = ReaderState(recordsHistory: false)
        let commands: [(ReaderMenuCommand, ReferenceWritableKeyPath<ReaderState, Bool>)] = [
            (.twoPages, \.spread), (.coverOnItsOwn, \.cover), (.rightToLeft, \.rtl)
        ]
        for (command, property) in commands {
            XCTAssertFalse(command.enabled(state))
            state.document = try nativePDFReadingFixture()
            state[keyPath: property] = false
            let configured = try ReaderConfiguredCommand.read("""
            [{"name":"layout","command":"\(command.rawValue)","shortcut":"cmd+alt+l"}]
            """)[0]
            XCTAssertTrue(configured.enabled(state))
            state.automaticLayout = true
            configured.run(state)
            XCTAssertTrue(state[keyPath: property])
            XCTAssertEqual(command.checked(state), true)
            XCTAssertFalse(state.automaticLayout, "A manual layout choice must stop following document defaults")
            command.run(state)
            XCTAssertFalse(state[keyPath: property])
            XCTAssertEqual(command.checked(state), false)
            let toolbar = try ReaderToolbarButton.read("""
            [{"command":"\(command.rawValue)"}]
            """)
            XCTAssertEqual(toolbar.first?.command, command.rawValue)
            state.document = nil
        }
    }

    func testCommandArgumentsRejectMeaninglessCombinations() throws {
        XCTAssertThrowsError(try ReaderConfiguredCommand.read("""
        [{"name":"wrong","command":"next","arguments":{"level":"120%"}}]
        """))
        XCTAssertThrowsError(try ReaderConfiguredCommand.read("""
        [{"name":"wrong","command":"open","arguments":{"page":0}}]
        """))
        let commands = try ReaderConfiguredCommand.read("""
        [{"name":"warm","command":"setTheme","arguments":{"theme":"light-warm"},"shortcut":"alt+t;cmd+alt+t"}]
        """)
        XCTAssertEqual(commands[0].arguments?.theme, "light-warm")
    }

    @MainActor func testRepeatedPageCommandMovesFacingRowsOnceAndClampsAtEnd() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(pageCount: 9)
        state.count = 9; state.spread = true; state.cover = true; state.page = 0
        state.flow = "paged"; state.fit = "page"; state.automaticLayout = false; state.freePan = false
        let pages = try XCTUnwrap(state.nativePDF)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func settle(_ page: Int) async throws {
            var complete = false
            state.send(.none) { complete = true }
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if complete, state.page == page,
                   RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: page)) { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(Optional<Bool>.none, state.error ?? "Facing-page command did not reach \(page)")
        }
        try await settle(0)
        let forward = try ReaderConfiguredCommand.read("""
        [{"name":"next three","command":"next","arguments":{"n":3}}]
        """)[0]
        forward.run(state)
        try await settle(5)
        state.turn(1, count: .max)
        try await settle(7)
        state.turn(-1, count: 2)
        try await settle(3)
        state.turn(1, count: 0)
        try await settle(3)
    }

    @MainActor func testExplicitToggleIsIdempotentAndUsesExistingState() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, key = "toolbarDisplayMode"
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }
        let state = ReaderState()
        state.toolbarDisplayMode = .shown
        let command = try ReaderConfiguredCommand.read("""
        [{"name":"hide toolbar","command":"toolbar","arguments":{"state":false}}]
        """)[0]
        command.run(state); command.run(state)
        XCTAssertEqual(state.toolbarDisplayMode, .hidden)
        XCTAssertEqual(defaults.string(forKey: key), "hidden")
        state.toolbarDisplayMode = .auto
        command.run(state)
        XCTAssertEqual(state.toolbarDisplayMode, .hidden, "An explicit hide must also disable hover reveal")
        state.toolbarDisplayMode = .auto
        let show = try ReaderConfiguredCommand.read("""
        [{"name":"show toolbar","command":"toolbar","arguments":{"state":true}}]
        """)[0]
        show.run(state); show.run(state)
        XCTAssertEqual(state.toolbarDisplayMode, .shown)
        XCTAssertEqual(defaults.string(forKey: key), "shown")
    }
}
#endif
