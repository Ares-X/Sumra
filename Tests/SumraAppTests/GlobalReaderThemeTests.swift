#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class GlobalReaderThemeTests: XCTestCase {
    func testSettingsThemeSelectionUpdatesNativeAppearanceWithoutAFocusedReader() throws {
        try preservingThemeDefaults {
            // Settings and Welcome use native semantic colors. Starting from
            // the opposite appearance reproduces the reported transition.
            for (old, selected, expected) in [
                (NSAppearance.Name.darkAqua, "light", NSAppearance.Name.aqua),
                (.aqua, "dracula", .darkAqua),
                (.darkAqua, "light-warm", .aqua)
            ] {
                NSApp.appearance = NSAppearance(named: old)
                ReaderState.selectTheme(selected)
                XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected,
                    "Global theme selection must update native Settings and Welcome surfaces")
            }
            ReaderState.selectTheme("system")
            XCTAssertNil(NSApp.appearance, "System theme must restore the macOS appearance owner")
        }
    }

    func testReaderCommandsChangeEveryWindowAndNewReadersWithRememberingOnOrOff() throws {
        try preservingThemeDefaults {
            for disabled in [false, true] {
                UserDefaults.standard.set(disabled, forKey: "disableReadingState")
                try withReaders { readers in
                    for reader in readers {
                        reader.reflowable = true
                        reader.customTextColor = 0x123456
                        reader.customBackgroundColor = 0xabcdef
                        reader.customLinkColor = 0x456789
                    }
                    let positions = readers.map(\.currentPosition)
                    let command = try ReaderConfiguredCommand.read("""
                    [{"name":"Dark paper","command":"setTheme","arguments":{"theme":"dracula"}}]
                    """)[0]
                    command.run(readers[0])
                    XCTAssertEqual(UserDefaults.standard.string(forKey: "theme"), "dracula")
                    XCTAssertEqual(ReaderState(recordsHistory: false).theme, "dracula")
                    for (reader, position) in zip(readers, positions) {
                        XCTAssertEqual(reader.theme, "dracula")
                        XCTAssertNil(reader.customTextColor)
                        XCTAssertNil(reader.customBackgroundColor)
                        XCTAssertNil(reader.customLinkColor)
                        XCTAssertEqual(reader.command.action, .style)
                        XCTAssertEqual(reader.pendingReflowPosition?.page, position.page)
                        XCTAssertEqual(reader.pendingReflowPosition?.y, position.y)
                        XCTAssertEqual(reader.currentPosition.page, position.page)
                        XCTAssertEqual(reader.currentPosition.x, position.x)
                        XCTAssertEqual(reader.currentPosition.y, position.y)
                        XCTAssertEqual(reader.zoom, position.zoom)
                    }
                }
            }
        }
    }

    func testPreferencesSelectionImportAndLightDarkMenuShareTheGlobalTheme() throws {
        try preservingThemeDefaults {
            try withReaders { readers in
                // Settings uses this owner even when no reader is focused.
                ReaderState.selectTheme("light-warm")
                XCTAssertEqual(readers.map(\.theme), ["light-warm", "light-warm"])
                try ReaderPreferences.apply(Data("{\"theme\":\"gruvbox\"}".utf8))
                XCTAssertEqual(readers.map(\.theme), ["gruvbox", "gruvbox"])
                ReaderMenuCommand.toggleLightDark.run(readers[1])
                XCTAssertEqual(readers.map(\.theme), ["light-warm", "light-warm"])
                ReaderState.selectTheme("system")
                XCTAssertEqual(readers.map(\.theme), ["system", "system"])
                XCTAssertEqual(ReaderState(recordsHistory: false).theme, "system")
            }
        }
    }

    func testImportingTheSelectedCustomPaletteRefreshesEveryReaderAndDeletionSelectsOneReplacement() throws {
        try preservingThemeDefaults {
            let defaults = UserDefaults.standard
            let original = ReaderTheme.makeCustom(name: "Paper", text: 0x112233, background: 0xffffff, link: 0x123456)
            try ReaderTheme.saveCustom(original)
            defaults.set(original.id, forKey: "theme")
            defaults.removeObject(forKey: "customCommands")
            try withReaders { readers in
                let edited = ReaderTheme(id: original.id, name: "Dark Paper", text: 0xffffff, background: 0x112233, link: 0xabcdef)
                let palettes = String(decoding: try JSONEncoder().encode([edited]), as: UTF8.self)
                try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: ["customThemes": palettes]))
                for reader in readers {
                    XCTAssertEqual(reader.theme, original.id)
                    XCTAssertEqual(reader.palette, edited)
                    XCTAssertEqual(reader.command.action, .style)
                }
                try ReaderPreferences.apply(Data("{\"customThemes\":\"[]\"}".utf8))
                XCTAssertEqual(readers.map(\.theme), ["dark", "dark"])
                XCTAssertEqual(defaults.string(forKey: "theme"), "dark")
                XCTAssertEqual(ReaderState(recordsHistory: false).theme, "dark")
            }
        }
    }

    func testReopeningLegacySavedThemeKeepsGlobalThemeAndRestoresReadingPosition() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Saved position.txt").standardizedFileURL
        try "A saved reading position must survive a global theme change.".write(to: url, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let positionKey = "position:" + url.path
        let keys = ["theme", "disableReadingState", "disableHistory", "formatDefaults", "documentOpenHistory", positionKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        let state = ReaderState(recordsHistory: true)
        defer {
            state.windowClosed()
            ReaderFiles.setRecent(recent)
            for (key, value) in saved { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        defaults.set("light-warm", forKey: "theme")
        defaults.set(false, forKey: "disableReadingState")
        defaults.set(false, forKey: "disableHistory")
        defaults.set("{}", forKey: "formatDefaults")
        defaults.set(Data("""
        {"page":0,"x":18,"y":210,"zoom":1.4,"fontSize":19,"theme":"dracula"}
        """.utf8), forKey: positionKey)
        state.open(url)
        for _ in 0..<500 where state.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.document?.url, url)
        XCTAssertEqual(state.theme, "light-warm")
        XCTAssertEqual(state.currentPosition.page, 0)
        XCTAssertEqual(state.currentPosition.x, 18)
        XCTAssertEqual(state.currentPosition.y, 210)
        XCTAssertEqual(state.zoom, 1.4)
        XCTAssertEqual(state.fontSize, 19)
        state.persist()
        let persisted = try XCTUnwrap(defaults.data(forKey: positionKey))
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        XCTAssertNil(values["theme"], "New positions must not preserve a per-document theme")
        XCTAssertEqual(values["y"] as? Double, 210)
    }

    private func preservingThemeDefaults(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["theme", "lastLightTheme", "lastDarkTheme", "customThemes", "customCommands", "disableReadingState"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let appearance = NSApp.appearance
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
            NSApp.appearance = appearance
        }
        try body()
    }

    private func withReaders(_ body: ([ReaderState]) throws -> Void) rethrows {
        let readers = (0..<2).map { index -> ReaderState in
            let reader = ReaderState(recordsHistory: false)
            reader.document = ReadingDocument(url: URL(fileURLWithPath: "/theme-reader-\(index).txt"), content: .text("Reading position fixture"))
            reader.page = index + 2
            reader.count = 10
            reader.zoom = 1.25
            reader.location = ReadingPosition(page: reader.page, x: 18, y: Double(210 + index * 100))
            return reader
        }
        let windows = readers.map { reader -> NSWindow in
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            reader.window = window
            return window
        }
        let delegates = readers.map { ReaderCloseGuard(state: $0, previous: nil) }
        for (window, delegate) in zip(windows, delegates) { window.delegate = delegate }
        defer {
            for (reader, window) in zip(readers, windows) {
                reader.windowClosed()
                window.delegate = nil
                window.close()
            }
            withExtendedLifetime(delegates) {}
        }
        XCTAssertTrue(readers.allSatisfy { reader in ReaderWindows.states.contains { $0 === reader } })
        try body(readers)
    }
}
#endif
