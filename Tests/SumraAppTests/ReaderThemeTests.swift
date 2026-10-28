#if os(macOS)
import Foundation
import XCTest
@testable import Sumra

final class ReaderThemeTests: XCTestCase {
    func testCustomPageDividerRoundTripsVisibleAndHiddenAndPreservesOldPalettes() throws {
        try withDefaults { defaults in
            let oldPalettes = """
            [{"id":"custom-old-light","name":"Old light","text":0,"background":16777215,"link":0},
             {"id":"custom-old-dark","name":"Old dark","text":16777215,"background":0,"link":0}]
            """
            let old = try ReaderTheme.decodeCustom(oldPalettes)
            XCTAssertEqual(old.map(\.pageDivider), [0xffffff, 0x0f0f0f])
            for divider in [UInt32?(0x123456), nil] {
                let theme = ReaderTheme(id: "custom-divider", name: "Divider", text: 0, background: 0xffffff, link: 0, pageDivider: divider)
                try ReaderTheme.saveCustom(theme, defaults: defaults)
                XCTAssertEqual(ReaderTheme.resolve(theme.id, defaults: defaults), theme)
                let saved = try XCTUnwrap(defaults.string(forKey: "customThemes"))
                let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[String: Any]])
                XCTAssertNotNil(entries[0]["pageDivider"], "Hidden must persist as explicit null, distinct from an old missing key")
                if divider == nil { XCTAssertTrue(entries[0]["pageDivider"] is NSNull) }
            }
            let invalid = ReaderTheme(id: "custom-invalid-divider", name: "Invalid", text: 0, background: 0xffffff, link: 0, pageDivider: 0x1000000)
            XCTAssertThrowsError(try ReaderTheme.saveCustom(invalid, defaults: defaults))
            XCTAssertNil(ReaderTheme.resolve(invalid.id, defaults: defaults))
        }
    }

    func testBuiltinTextAndLinksRemainReadableAtNormalReadingSizes() {
        // WCAG 2.2 SC 1.4.3 uses the authored sRGB colors, before font
        // antialiasing. Custom palettes remain the user's explicit choice.
        func luminance(_ rgb: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((rgb >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for theme in ReaderTheme.builtins {
            for foreground in [theme.text, theme.link] {
                let a = luminance(foreground), b = luminance(theme.background)
                XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5,
                    "\(theme.id) must keep both body text and links readable")
            }
        }
    }

    func testFivePresetsAndRetiredIDsRemainReadable() throws {
        XCTAssertEqual(ReaderTheme.builtins.map(\.id), ["light", "light-warm", "dark", "dracula", "gruvbox"])
        XCTAssertEqual(ReaderTheme.builtins.first?.background, 0xffffff)
        let retired = ["dark-from-3-5", "charcoal", "solarized-light", "solarized-dark", "nebula", "greeny", "choco", "purpy", "one-dark", "monokai", "nord", "github-dark", "catppuccin-mocha", "tokyo-night", "night-owl", "ayu", "palenight"]
        try withDefaults { defaults in
            for id in retired {
                XCTAssertNotNil(ReaderTheme.resolve(id, defaults: defaults), id)
                XCTAssertFalse(ReaderTheme.builtins.contains { $0.id == id })
            }
            let solarized = try XCTUnwrap(ReaderTheme.resolve("solarized-dark", defaults: defaults))
            XCTAssertEqual(solarized.background, 0x002b36)
            XCTAssertEqual(solarized.text, 0x839496)
            XCTAssertNil(ReaderTheme.resolve("unknown", defaults: defaults))
            XCTAssertTrue(ReaderTheme.custom(defaults: defaults).isEmpty)
        }
    }

    func testNamedPaletteSaveEditReloadAndDeletePreserveItsIdentity() throws {
        try withDefaults { defaults in
            let original = ReaderTheme.makeCustom(name: "My paper", text: 0x123456, background: 0xfedcba, link: 0xabcdef)
            XCTAssertTrue(original.isCustom)
            XCTAssertEqual(original.displayName, "My paper")
            try ReaderTheme.saveCustom(original, defaults: defaults)
            XCTAssertEqual(ReaderTheme.custom(defaults: defaults), [original])
            XCTAssertEqual(ReaderTheme.resolve(original.id, defaults: defaults), original)

            let second = ReaderTheme.makeCustom(name: "Dark", text: 0xffffff, background: 0x010203, link: 0x405060)
            try ReaderTheme.saveCustom(second, defaults: defaults)
            let edited = ReaderTheme(id: original.id, name: "Renamed", text: 0x112233, background: 0xffffff, link: 0x445566)
            try ReaderTheme.saveCustom(edited, defaults: defaults)
            XCTAssertEqual(ReaderTheme.custom(defaults: defaults), [edited, second])
            let stored = try XCTUnwrap(defaults.string(forKey: "customThemes"))
            XCTAssertEqual(try ReaderTheme.decodeCustom(stored), [edited, second])
            XCTAssertEqual(ReaderTheme.resolve(original.id, defaults: defaults), edited)
            XCTAssertEqual(second.displayName, "Dark", "User-entered names must remain literal")

            try ReaderTheme.deleteCustom(id: original.id, defaults: defaults)
            XCTAssertEqual(ReaderTheme.custom(defaults: defaults), [second])
            XCTAssertNil(ReaderTheme.resolve(original.id, defaults: defaults))
            try ReaderTheme.deleteCustom(id: second.id, defaults: defaults)
            XCTAssertEqual(try ReaderTheme.decodeCustom(try XCTUnwrap(defaults.string(forKey: "customThemes"))), [])
        }
    }

    func testInvalidImportedPalettesAndInvalidSaveDoNotReplaceSavedColors() throws {
        try withDefaults { defaults in
            let saved = ReaderTheme.makeCustom(name: "Saved", text: 0, background: 0xffffff, link: 0x123456)
            try ReaderTheme.saveCustom(saved, defaults: defaults)
            let invalid = [
                ReaderTheme(id: "light", name: "Invalid preset ID", text: 0, background: 0xffffff, link: 0),
                ReaderTheme(id: "custom-", name: "Missing identity", text: 0, background: 0xffffff, link: 0),
                ReaderTheme(id: "custom-blank", name: " \n", text: 0, background: 0xffffff, link: 0),
                ReaderTheme(id: saved.id, name: "Invalid color", text: 0x1000000, background: 0xffffff, link: 0)
            ]
            for theme in invalid {
                XCTAssertThrowsError(try ReaderTheme.saveCustom(theme, defaults: defaults))
                XCTAssertEqual(ReaderTheme.custom(defaults: defaults), [saved])
            }
            let duplicate = String(decoding: try JSONEncoder().encode([saved, saved]), as: UTF8.self)
            XCTAssertThrowsError(try ReaderTheme.decodeCustom(duplicate))
            XCTAssertThrowsError(try ReaderTheme.decodeCustom("invalid JSON"))
            defaults.set("invalid JSON", forKey: "customThemes")
            XCTAssertThrowsError(try ReaderTheme.saveCustom(saved, defaults: defaults))
            XCTAssertThrowsError(try ReaderTheme.deleteCustom(id: saved.id, defaults: defaults))
            XCTAssertEqual(defaults.string(forKey: "customThemes"), "invalid JSON")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "Sumra.ReaderThemeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
#endif
