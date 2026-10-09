#if os(macOS)
import XCTest
import PDFKit
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

    @MainActor func testRepeatedPageCommandMovesFacingRowsOnceAndClampsAtEnd() throws {
        let state = ReaderState()
        state.document = try nativePDFReadingFixture(pageCount: 9)
        state.count = 9; state.spread = true; state.cover = true; state.page = 0
        let forward = try ReaderConfiguredCommand.read("""
        [{"name":"next three","command":"next","arguments":{"n":3}}]
        """)[0]
        forward.run(state)
        XCTAssertEqual(state.page, 5)
        state.turn(1, count: .max)
        XCTAssertEqual(state.page, 7)
        state.turn(-1, count: 2)
        XCTAssertEqual(state.page, 3)
        state.turn(1, count: 0)
        XCTAssertEqual(state.page, 3)
    }

    @MainActor func testExplicitToggleIsIdempotentAndUsesExistingState() throws {
        let state = ReaderState()
        state.toolbarVisible = true
        let command = try ReaderConfiguredCommand.read("""
        [{"name":"hide toolbar","command":"toolbar","arguments":{"state":false}}]
        """)[0]
        command.run(state); command.run(state)
        XCTAssertFalse(state.toolbarVisible)
    }
}
#endif
