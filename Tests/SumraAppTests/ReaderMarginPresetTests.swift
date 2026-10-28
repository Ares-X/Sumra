#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderMarginPresetTests: XCTestCase {
    func testPresetsResolveActualFourSideMarginsAndPreserveCustomValues() throws {
        for (preset, value) in zip(ReaderMarginPreset.allCases, [8.0, 16.0, 24.0]) {
            XCTAssertEqual(preset.margin, value)
            XCTAssertEqual(ReaderMarginPreset.current(pageMargins: PageMargins(cssValues: [value])), preset)
        }
        XCTAssertNil(ReaderMarginPreset.current(pageMargins: nil))
        XCTAssertNil(ReaderMarginPreset.current(pageMargins: PageMargins(cssValues: "16 8 16 8")))
    }

    func testSelectingPresetOverridesEverySideAndRestoredBookRetainsCustomMargins() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.typographyForAll = false
        var position = ReadingPosition(page: 4)
        position.margin = 27
        position.pageMargins = PageMargins(cssValues: "10 20 30 40")
        state.restore(position)
        XCTAssertNil(state.marginPreset)
        XCTAssertEqual(state.margin, 27)
        XCTAssertEqual(state.pageMargins?.values, [10, 20, 30, 40])

        for preset in ReaderMarginPreset.allCases {
            state.applyMarginPreset(preset)
            XCTAssertEqual(state.marginPreset, preset)
            XCTAssertEqual(state.margin, preset.margin)
            XCTAssertEqual(state.currentPosition.pageMargins?.values, Array(repeating: preset.margin, count: 4))
            XCTAssertEqual(state.page, 4)
        }

        state.restore(position)
        XCTAssertEqual(state.pageMargins, position.pageMargins)
        XCTAssertNil(state.marginPreset)

        position.margin = 16
        position.pageMargins = nil
        state.restore(position)
        XCTAssertEqual(state.margin, 16)
        XCTAssertNil(state.pageMargins)
        XCTAssertNil(state.marginPreset, "Document margins must not appear as an explicit Medium override")
    }
}

@MainActor
final class ReaderPreferencesMigrationTests: XCTestCase {
    func testFreshProfileStartsMediumAndKeepsSchemaInternal() throws {
        try withDefaults { defaults in
            ReaderPreferences.migrate(defaults: defaults)
            XCTAssertEqual(defaults.double(forKey: "margin"), 16)
            let margins = try JSONDecoder().decode(PageMargins.self, from: XCTUnwrap(defaults.data(forKey: "pageMargins")))
            XCTAssertEqual(margins.values, [16, 16, 16, 16])
            XCTAssertEqual(ReaderMarginPreset.current(pageMargins: margins), .medium)
            XCTAssertEqual(defaults.integer(forKey: "settingsSchemaVersion"), ReaderPreferences.settingsSchemaVersion)
            XCTAssertEqual(defaults.string(forKey: "toolbarDisplayMode"), "shown")
            XCTAssertFalse(ReaderPreferences.keys.contains("settingsSchemaVersion"))
        }
    }

    func testKnownLegacyProfilesKeepImplicitWideMargin() throws {
        let markers: [(String, Any)] = [("theme", "light"), ("toolbarDisplayMode", "auto"), ("fontSize", 19),
            ("restoreSession", false), ("documentOpenHistory", Data()), ("position:/legacy/book.epub", Data()),
            ("language", "zh-Hans"), ("spread", true), ("fit", "width"), ("immersiveControls", true),
            ("progressDisplayMode", "hidden"), ("documentOpenBehavior", "newTab")]
        for (marker, value) in markers {
            try withDefaults { defaults in
                defaults.set(value, forKey: marker)
                ReaderPreferences.migrate(defaults: defaults)
                XCTAssertEqual(defaults.double(forKey: "margin"), 32, marker)
                XCTAssertNil(defaults.object(forKey: "pageMargins"), marker)
            }
        }
    }

    func testFreshMigrationAppliesSixteenPointNativeMarginsWhileLegacyKeepsPublisherMargins() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("ProfileMargins.html")
        try "<html><head><style>@page{margin:44pt}html,body,p{margin:0;padding:0}</style></head><body><p>PROFILE</p></body></html>"
            .write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        func leftEdge(_ margins: PageMargins?) throws -> CGFloat {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "serif", theme: "light",
                                  pageMargins: margins, pageSize: CGSize(width: 420, height: 300))
            return try XCTUnwrap(file.matches("PROFILE", page: 0).first?.rects.first).minX
        }
        let publisherLeft = try leftEdge(nil)
        try withDefaults { defaults in
            ReaderPreferences.migrate(defaults: defaults)
            let margins = try JSONDecoder().decode(PageMargins.self, from: XCTUnwrap(defaults.data(forKey: "pageMargins")))
            let freshLeft = try leftEdge(margins)
            XCTAssertEqual(publisherLeft - freshLeft, 28, accuracy: 0.1)
            XCTAssertEqual(freshLeft, try leftEdge(PageMargins(cssValues: [16])), accuracy: 0.1)
        }
        try withDefaults { defaults in
            defaults.set("light", forKey: "theme")
            ReaderPreferences.migrate(defaults: defaults)
            XCTAssertNil(defaults.data(forKey: "pageMargins"))
            XCTAssertEqual(try leftEdge(nil), publisherLeft, accuracy: 0.1)
        }
    }

    func testLegacyClosedWindowsTabGroupsAndBookmarksPreserveTheirBytesAndDocumentMargins() throws {
        var position = ReadingPosition(page: 7)
        position.margin = 32
        let bookmark = try JSONEncoder().encode(position)
        let windows = try JSONEncoder().encode([WindowPayload(path: "/legacy/book.epub", position: position)])
        for (key, data) in [("closedDocuments", windows), ("tabGroup:Saved Books", windows), ("bookmark:/legacy/book.epub", bookmark)] {
            try withDefaults { defaults in
                defaults.set(data, forKey: key)
                ReaderPreferences.migrate(defaults: defaults)
                ReaderPreferences.migrate(defaults: defaults)
                XCTAssertEqual(defaults.double(forKey: "margin"), 32, key)
                XCTAssertNil(defaults.object(forKey: "pageMargins"), key)
                XCTAssertEqual(defaults.data(forKey: key), data, key)
            }
        }
    }

    func testSavedScalarWithoutOverrideStaysDocumentDefaultAcrossMigration() throws {
        for margin in [8.0, 16.0, 32.0, 23.5] {
            try withDefaults { defaults in
                defaults.set(margin, forKey: "margin")
                ReaderPreferences.migrate(defaults: defaults)
                ReaderPreferences.migrate(defaults: defaults)
                XCTAssertEqual(defaults.double(forKey: "margin"), margin)
                XCTAssertNil(defaults.object(forKey: "pageMargins"))
                XCTAssertNil(ReaderMarginPreset.current(pageMargins: nil))
            }
        }
    }

    func testFreshProfileLaterDocumentDefaultChoiceSurvivesAnotherUpgradePass() throws {
        try withDefaults { defaults in
            ReaderPreferences.migrate(defaults: defaults)
            defaults.removeObject(forKey: "pageMargins")
            defaults.set(32.0, forKey: "margin")
            ReaderPreferences.migrate(defaults: defaults)
            XCTAssertEqual(defaults.double(forKey: "margin"), 32)
            XCTAssertNil(defaults.object(forKey: "pageMargins"))
        }
    }

    func testSavedWideAndCustomMarginsAndBookPositionsRemainUnchanged() throws {
        for margin in [32.0, 23.5] {
            try withDefaults { defaults in
                let asymmetric = try JSONEncoder().encode(XCTUnwrap(PageMargins(cssValues: "9 17 25 33")))
                var position = ReadingPosition(page: 12)
                position.margin = 41
                position.pageMargins = PageMargins(cssValues: "1 2 3 4")
                let book = try JSONEncoder().encode(position)
                defaults.set(margin, forKey: "margin")
                defaults.set(asymmetric, forKey: "pageMargins")
                defaults.set(book, forKey: "position:/legacy/book.epub")

                ReaderPreferences.migrate(defaults: defaults)

                XCTAssertEqual(defaults.double(forKey: "margin"), margin)
                XCTAssertEqual(defaults.data(forKey: "pageMargins"), asymmetric)
                XCTAssertEqual(defaults.data(forKey: "position:/legacy/book.epub"), book)
            }
        }
    }

    func testLegacyToolbarMigrationRunsOnceAndUpgradeKeepsLaterChoices() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "revealHiddenToolbar")
            ReaderPreferences.migrate(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: "toolbarDisplayMode"), "auto")
            XCTAssertNil(defaults.object(forKey: "revealHiddenToolbar"))

            defaults.set("hidden", forKey: "toolbarDisplayMode")
            defaults.set("auto", forKey: "progressDisplayMode")
            defaults.set("newTab", forKey: "documentOpenBehavior")
            defaults.set(true, forKey: "immersiveControls")
            defaults.set(8.0, forKey: "margin")
            ReaderPreferences.migrate(defaults: defaults)
            ReaderPreferences.migrate(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: "toolbarDisplayMode"), "hidden")
            XCTAssertEqual(defaults.string(forKey: "progressDisplayMode"), "auto")
            XCTAssertEqual(defaults.string(forKey: "documentOpenBehavior"), "newTab")
            XCTAssertTrue(defaults.bool(forKey: "immersiveControls"))
            XCTAssertEqual(defaults.double(forKey: "margin"), 8)
        }
    }

    func testNewReaderControlsAndMarginsRoundTripThroughPublicExport() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["toolbarDisplayMode", "progressDisplayMode", "documentOpenBehavior", "immersiveControls", "margin", "pageMargins"]
        let cleanupKeys = keys + ["readingPreferenceRevisions"]
        let saved = cleanupKeys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }

        for index in ReaderToolbarDisplayMode.allCases.indices {
            let toolbar = ReaderToolbarDisplayMode.allCases[index].rawValue
            let progress = Array(ReaderToolbarDisplayMode.allCases.reversed())[index].rawValue
            let behavior = DocumentOpenBehavior.allCases[index].rawValue
            let input: [String: Any] = ["toolbarDisplayMode": toolbar, "progressDisplayMode": progress,
                "documentOpenBehavior": behavior, "immersiveControls": index.isMultiple(of: 2),
                "margin": ReaderMarginPreset.allCases[index].margin, "pageMargins": "10 20 30 40"]
            try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: input))
            let all = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderPreferences.data()) as? [String: Any])
            let exported = all.filter { keys.contains($0.key) }
            for key in keys { defaults.removeObject(forKey: key) }
            try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: exported))
            XCTAssertEqual(defaults.string(forKey: "toolbarDisplayMode"), toolbar)
            XCTAssertEqual(defaults.string(forKey: "progressDisplayMode"), progress)
            XCTAssertEqual(DocumentOpenBehavior.current.rawValue, behavior)
            XCTAssertEqual(defaults.bool(forKey: "immersiveControls"), index.isMultiple(of: 2))
            XCTAssertEqual(defaults.double(forKey: "margin"), ReaderMarginPreset.allCases[index].margin)
            let margins = try JSONDecoder().decode(PageMargins.self, from: XCTUnwrap(defaults.data(forKey: "pageMargins")))
            XCTAssertEqual(margins.values, [10, 20, 30, 40])
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "Sumra.ReaderPreferencesMigrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
#endif
