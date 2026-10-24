#if os(macOS)
import XCTest
import AppKit
import SumraCore
@testable import Sumra

@MainActor
final class ReaderPreferencesTests: XCTestCase {
    private let typographyKeys = ["font", "fontSize", "lineHeight", "margin", "pageMargins", "userCSS", "useDocumentCSS", "language"]

    func testRetiredLanguageExportAndImportUseSystemWithoutRejectingOtherSettings() throws {
        try preservingTypography {
            let defaults = UserDefaults.standard
            defaults.set("sat", forKey: "language")
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderPreferences.data(matching: "language")) as? [String: String])
            XCTAssertEqual(exported["language"], "system")
            XCTAssertEqual(defaults.string(forKey: "language"), "sat", "Export must not mutate saved preferences")
            try ReaderPreferences.apply(Data("{\"language\":\"sat\",\"margin\":120}".utf8))
            XCTAssertEqual(defaults.string(forKey: "language"), "system")
            XCTAssertEqual(defaults.double(forKey: "margin"), 120)
            XCTAssertThrowsError(try ReaderPreferences.apply(Data("{\"language\":\"not-a-supported-language\",\"margin\":80}".utf8)))
            XCTAssertEqual(defaults.double(forKey: "margin"), 120)
        }
    }

    func testSavedUniformMarginsAbove96RoundTripThroughPublicSettings() throws {
        try preservingTypography {
            let state = ReaderState(recordsHistory: false)
            state.typographyForAll = true
            state.margin = 120
            state.pageMargins = PageMargins(cssValues: [120])
            state.applyTypography()

            let exported = try ReaderPreferences.data(matching: "margin")
            UserDefaults.standard.removeObject(forKey: "margin")
            UserDefaults.standard.removeObject(forKey: "pageMargins")
            try ReaderPreferences.apply(exported)

            let restored = ReaderState(recordsHistory: false)
            XCTAssertEqual(restored.margin, 120)
            XCTAssertEqual(restored.pageMargins?.values, [120, 120, 120, 120])
        }
    }

    func testAsymmetricDefaultsExportAsEditablePointsAndRestoreInFreshReader() throws {
        try preservingTypography {
            let state = ReaderState(recordsHistory: false)
            state.typographyForAll = true
            state.pageMargins = PageMargins(cssValues: "10 20 30 40")
            state.applyTypography()

            let exported = try ReaderPreferences.data(matching: "margin")
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let text = try XCTUnwrap(values["pageMargins"] as? String)
            XCTAssertEqual(PageMargins(cssValues: text)?.values, [10, 20, 30, 40])
            UserDefaults.standard.removeObject(forKey: "pageMargins")
            try ReaderPreferences.apply(exported)

            let restored = ReaderState(recordsHistory: false)
            XCTAssertEqual(restored.pageMargins?.values, [10, 20, 30, 40])
            let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: "pageMargins"))
            XCTAssertEqual(try JSONDecoder().decode(PageMargins.self, from: saved).values, [10, 20, 30, 40])
        }
    }

    func testInvalidMarginImportLeavesAllPreferencesUnchanged() throws {
        try preservingTypography {
            let defaults = UserDefaults.standard
            let savedMargins = try JSONEncoder().encode(XCTUnwrap(PageMargins(cssValues: "10 20 30 40")))
            defaults.set(savedMargins, forKey: "pageMargins")
            defaults.set(32.0, forKey: "margin")
            defaults.set("serif", forKey: "font")
            for invalid in ["1 2 3", "1 nope", "201", "-1", "nan"] {
                let incoming = try JSONSerialization.data(withJSONObject: ["font": "Georgia", "margin": 80, "pageMargins": invalid])
                XCTAssertThrowsError(try ReaderPreferences.apply(incoming), invalid)
                XCTAssertEqual(defaults.string(forKey: "font"), "serif")
                XCTAssertEqual(defaults.double(forKey: "margin"), 32)
                XCTAssertEqual(defaults.data(forKey: "pageMargins"), savedMargins)
            }
            let invalidScalar = try JSONSerialization.data(withJSONObject: ["margin": 201, "pageMargins": "20"])
            XCTAssertThrowsError(try ReaderPreferences.apply(invalidScalar))
            XCTAssertEqual(defaults.double(forKey: "margin"), 32)
            XCTAssertEqual(defaults.data(forKey: "pageMargins"), savedMargins)
        }
    }

    func testOldExportsPreserveMarginsAndBlankPublicValueClearsThem() throws {
        try preservingTypography {
            let defaults = UserDefaults.standard
            let savedMargins = try JSONEncoder().encode(XCTUnwrap(PageMargins(cssValues: "10 20")))
            defaults.set(savedMargins, forKey: "pageMargins")
            try ReaderPreferences.apply(Data("{\"margin\":40}".utf8))
            XCTAssertEqual(defaults.data(forKey: "pageMargins"), savedMargins)

            try ReaderPreferences.apply(Data("{\"pageMargins\":\"  \"}".utf8))
            XCTAssertNil(defaults.object(forKey: "pageMargins"))
            XCTAssertNil(ReaderState(recordsHistory: false).pageMargins)
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderPreferences.data(matching: "pageMargins")) as? [String: String])
            XCTAssertEqual(exported["pageMargins"], "")

            defaults.set(savedMargins, forKey: "pageMargins")
            try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: exported))
            XCTAssertNil(defaults.object(forKey: "pageMargins"), "An export without an override must clear the destination override")
        }
    }

    private func preservingTypography(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let saved = typographyKeys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        try body()
    }
}
#endif
