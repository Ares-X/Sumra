#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class LiveReaderPreferencesTests: XCTestCase {
    func testExplicitSettingsBindingUpdatesEveryUnfocusedReaderWithoutReplacingBookSettings() throws {
        try preservingDefaults {
            try withReaders { readers in
                for reader in readers {
                    reader.reflowable = true
                    reader.font = "serif"
                    reader.fontSize = 19
                    reader.lineHeight = 1.9
                    reader.margin = 33
                    reader.pageMargins = PageMargins(cssValues: "9 17 25 33")
                    reader.flow = "continuous"
                    reader.fit = "width"
                }
                let positions = readers.map(\.currentPosition)
                let revisions = readers.map { $0.command.revision }
                // These windows never become key. The setter must address all
                // readers even when Settings itself owns keyboard focus.
                let binding = Binding<Double>(
                    get: { UserDefaults.standard.double(forKey: "fontSize") },
                    set: { UserDefaults.standard.set($0, forKey: "fontSize") })
                ReaderPreferences.live(binding, keys: ["fontSize"]).wrappedValue = 26

                XCTAssertEqual(UserDefaults.standard.double(forKey: "fontSize"), 26)
                for index in readers.indices {
                    let reader = readers[index]
                    XCTAssertEqual(reader.fontSize, 26)
                    XCTAssertEqual(reader.font, "serif")
                    XCTAssertEqual(reader.lineHeight, 1.9)
                    XCTAssertEqual(reader.pageMargins?.values, [9, 17, 25, 33])
                    XCTAssertEqual(reader.flow, "continuous")
                    XCTAssertEqual(reader.fit, "width")
                    XCTAssertEqual(reader.zoom, positions[index].zoom)
                    XCTAssertEqual(reader.currentPosition.y, positions[index].y)
                    XCTAssertEqual(reader.pendingReflowPosition?.y, positions[index].y)
                    XCTAssertEqual(reader.command.action, .style)
                    XCTAssertEqual(reader.command.revision, revisions[index] + 1)
                }
                readers[0].typographyForAll = true
                readers[0].fontSize = 21
                readers[0].applyTypography()
                XCTAssertEqual(UserDefaults.standard.double(forKey: "fontSize"), 21)
                XCTAssertEqual(readers.map(\.fontSize), [21, 21],
                    "Aa's explicit Use Changes as Defaults option must share the global typography owner")
            }
        }
    }

    func testLayoutSettingsChangeOnlyTheSelectedFields() throws {
        try preservingDefaults {
            try withReaders { readers in
                let defaults = UserDefaults.standard
                for reader in readers {
                    reader.fit = "width"
                    reader.flow = "paged"
                    reader.spread = false
                    reader.rtl = false
                    reader.cover = false
                    reader.fontSize = 23
                    reader.automaticLayout = false
                }
                defaults.set("page", forKey: "fit")
                defaults.set("continuous", forKey: "flow")
                defaults.set(true, forKey: "spread")
                defaults.set(true, forKey: "rtl")
                defaults.set(true, forKey: "cover")
                defaults.set(true, forKey: "automaticLayout")

                ReaderPreferences.applyReadingDefaults(changed: ["fit"])
                for reader in readers {
                    XCTAssertEqual(reader.fit, "page")
                    XCTAssertEqual(reader.flow, "paged")
                    XCTAssertFalse(reader.spread)
                    XCTAssertFalse(reader.automaticLayout)
                    XCTAssertEqual(reader.fontSize, 23)
                }
                ReaderPreferences.applyReadingDefaults(changed: ["flow"])
                for reader in readers {
                    XCTAssertEqual(reader.flow, "continuous")
                    XCTAssertFalse(reader.spread)
                    XCTAssertFalse(reader.rtl)
                    XCTAssertFalse(reader.cover)
                    XCTAssertFalse(reader.automaticLayout)
                }
                ReaderPreferences.applyReadingDefaults(changed: ["spread", "rtl", "cover", "automaticLayout"])
                for reader in readers {
                    XCTAssertTrue(reader.spread)
                    XCTAssertTrue(reader.rtl)
                    XCTAssertTrue(reader.cover)
                    XCTAssertTrue(reader.automaticLayout)
                    XCTAssertEqual(reader.fontSize, 23)
                    XCTAssertEqual(reader.flow, "continuous")
                }
            }
        }
    }

    func testGlobalMarginsUpdateBothRepresentationsAndKeepUnrelatedTypography() throws {
        try preservingDefaults {
            try withReaders { readers in
                for reader in readers {
                    reader.font = "monospace"
                    reader.fontSize = 21
                    reader.lineHeight = 2
                    reader.pageMargins = PageMargins(cssValues: "1 2 3 4")
                }
                ReaderPreferences.setMargins(24)
                XCTAssertEqual(UserDefaults.standard.double(forKey: "margin"), 24)
                let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "pageMargins"))
                XCTAssertEqual(try JSONDecoder().decode(PageMargins.self, from: data).values, [24, 24, 24, 24])
                for reader in readers {
                    XCTAssertEqual(reader.margin, 24)
                    XCTAssertEqual(reader.pageMargins?.values, [24, 24, 24, 24])
                    XCTAssertEqual(reader.font, "monospace")
                    XCTAssertEqual(reader.fontSize, 21)
                    XCTAssertEqual(reader.lineHeight, 2)
                    XCTAssertEqual(reader.command.action, .style)
                }
            }
        }
    }

    func testLegacyBookSettingsSurviveUntilAGlobalChoiceAndLaterAaChoicesStillRestore() throws {
        try preservingDefaults {
            var legacy = ReadingPosition(page: 7, x: 18, y: 321)
            legacy.font = "serif"
            legacy.fontSize = 19
            legacy.lineHeight = 1.8
            legacy.margin = 29
            legacy.pageMargins = PageMargins(cssValues: "9 17 25 33")
            legacy.zoom = 1.4
            let reader = ReaderState(recordsHistory: false)
            defer { reader.windowClosed() }
            reader.apply(legacy)
            XCTAssertEqual(reader.fontSize, 19, "Unmarked legacy books must keep their settings before any new global choice")
            XCTAssertEqual(reader.pageMargins, legacy.pageMargins)

            UserDefaults.standard.set(27, forKey: "fontSize")
            ReaderPreferences.applyReadingDefaults(changed: ["fontSize"])
            reader.readPreferences()
            reader.restore(legacy)
            XCTAssertEqual(reader.fontSize, 27)
            XCTAssertEqual(reader.font, "serif")
            XCTAssertEqual(reader.lineHeight, 1.8)
            XCTAssertEqual(reader.pageMargins, legacy.pageMargins)
            XCTAssertEqual(reader.page, 7)
            XCTAssertEqual(reader.currentPosition.x, 18)
            XCTAssertEqual(reader.currentPosition.y, 321)
            XCTAssertEqual(reader.zoom, 1.4)

            // Aa changes remain local and receive the current global marker
            // when the book's next snapshot is saved.
            reader.typographyForAll = false
            reader.fontSize = 22
            reader.applyTypography()
            XCTAssertEqual(UserDefaults.standard.double(forKey: "fontSize"), 27)
            let saved = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(reader.currentPosition))
            XCTAssertEqual(saved.preferenceRevisions, ReaderPreferences.readingRevisions)
            let reopened = ReaderState(recordsHistory: false)
            defer { reopened.windowClosed() }
            reopened.apply(saved)
            XCTAssertEqual(reopened.fontSize, 22)

            ReaderPreferences.setMargins(16)
            reopened.readPreferences()
            reopened.apply(saved)
            XCTAssertEqual(reopened.fontSize, 22, "A newer margin choice must not invalidate a later per-book font choice")
            XCTAssertEqual(reopened.margin, 16)
            XCTAssertEqual(reopened.pageMargins?.values, [16, 16, 16, 16])
            XCTAssertEqual(reopened.currentPosition.y, 321)
        }
    }

    func testConfigurationImportRejectsAlreadyCapturedOldFieldsAndKeepsMetadataPrivate() throws {
        try preservingDefaults {
            try withReaders { readers in
                let reader = readers[0]
                reader.font = "serif"
                reader.fontSize = 18
                reader.lineHeight = 1.8
                reader.fit = "width"
                reader.flow = "paged"
                reader.pageMargins = PageMargins(cssValues: "4 8 12 16")
                let captured = try JSONEncoder().encode(reader.currentPosition)
                try ReaderPreferences.apply(Data("""
                {"fontSize":25,"font":"monospace","lineHeight":2.1,"pageMargins":"10 20 30 40","fit":"page","flow":"continuous"}
                """.utf8))
                for state in readers {
                    XCTAssertEqual(state.fontSize, 25)
                    XCTAssertEqual(state.font, "monospace")
                    XCTAssertEqual(state.lineHeight, 2.1)
                    XCTAssertEqual(state.pageMargins?.values, [10, 20, 30, 40])
                    XCTAssertEqual(state.fit, "page")
                    XCTAssertEqual(state.flow, "continuous")
                }
                // Models an opening worker or restoration request holding a
                // snapshot across an await while Settings changes globally.
                reader.restore(try JSONDecoder().decode(ReadingPosition.self, from: captured))
                XCTAssertEqual(reader.fontSize, 25)
                XCTAssertEqual(reader.font, "monospace")
                XCTAssertEqual(reader.lineHeight, 2.1)
                XCTAssertEqual(reader.pageMargins?.values, [10, 20, 30, 40])
                XCTAssertEqual(reader.fit, "page")
                XCTAssertEqual(reader.flow, "continuous")
                XCTAssertEqual(reader.currentPosition.y, 210)
                let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderPreferences.data()) as? [String: Any])
                XCTAssertFalse(exported.keys.contains { $0.localizedCaseInsensitiveContains("revision") })
            }
        }
    }

    func testOpeningSavedAndNewBooksUsesNewGlobalChoiceWithRememberingOnOrOff() async throws {
        let savedDefaults = snapshotDefaults()
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "readingPreferenceRevisions")
        let recent = NSDocumentController.shared.recentDocumentURLs
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Live settings.txt").standardizedFileURL
        try "Reader preferences must apply when the next document opens.".write(to: url, atomically: true, encoding: .utf8)
        let positionKey = "position:" + url.path
        defer {
            defaults.removeObject(forKey: positionKey)
            ReaderFiles.setRecent(recent)
            restoreDefaults(savedDefaults)
            withExtendedLifetime(directory) {}
        }
        for disabled in [false, true] {
            defaults.set(false, forKey: "disableHistory")
            defaults.set(disabled, forKey: "disableReadingState")
            var saved = ReadingPosition(page: 0, x: 18, y: 210)
            saved.font = "serif"
            saved.fontSize = 19
            saved.zoom = 1.4
            defaults.set(try JSONEncoder().encode(saved), forKey: positionKey)
            let formatDefaults = try JSONEncoder().encode(["text": saved.formatSettings])
            defaults.set(String(decoding: formatDefaults, as: UTF8.self), forKey: "formatDefaults")
            // Construct before changing Settings to exercise the load-time
            // reread, rather than relying only on initializer defaults.
            let state = ReaderState(recordsHistory: true)
            defer { state.windowClosed() }
            defaults.set(28, forKey: "fontSize")
            ReaderPreferences.applyReadingDefaults(changed: ["fontSize"])
            state.open(url)
            for _ in 0..<500 where state.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(state.busy)
            XCTAssertNil(state.error)
            XCTAssertEqual(state.document?.url, url)
            XCTAssertEqual(state.fontSize, 28)
            if !disabled {
                XCTAssertEqual(state.font, "serif")
                XCTAssertEqual(state.currentPosition.x, 18)
                XCTAssertEqual(state.currentPosition.y, 210)
                XCTAssertEqual(state.zoom, 1.4)
            }
            let fresh = ReaderState(recordsHistory: false)
            defer { fresh.windowClosed() }
            fresh.openWithoutHistory(url)
            for _ in 0..<500 where fresh.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(fresh.busy)
            XCTAssertNil(fresh.error)
            XCTAssertEqual(fresh.fontSize, 28)
            XCTAssertEqual(fresh.font, "serif", "An unrelated per-format default must survive a global font-size change")
        }
    }

    private func snapshotDefaults() -> [(String, Any?)] {
        let keys = ReaderPreferences.keys.union(["readingPreferenceRevisions", "documentOpenHistory", "bookmarks"])
        return keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    private func restoreDefaults(_ saved: [(String, Any?)]) {
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
    }

    private func preservingDefaults(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let saved = snapshotDefaults()
        defer { restoreDefaults(saved) }
        UserDefaults.standard.removeObject(forKey: "readingPreferenceRevisions")
        try body()
    }

    private func withReaders(_ body: ([ReaderState]) throws -> Void) rethrows {
        let readers = (0..<2).map { index -> ReaderState in
            let reader = ReaderState(recordsHistory: false)
            reader.document = ReadingDocument(url: URL(fileURLWithPath: "/live-preferences-reader-\(index).txt"), content: .text("Reading settings fixture"))
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
