#if os(macOS)
import XCTest
@testable import Sumra

final class ReaderLocalizationTests: XCTestCase {
    func testBundledCoverageRecognizesSourceAndCompletedChineseCatalog() {
        XCTAssertFalse(ReaderLocalization.isPartial("en"), "Missing coverage data must not make the source language appear incomplete")
        XCTAssertFalse(ReaderLocalization.isPartial("zh-Hans"), "The completed source-key inventory must ship with the app")
    }

    func testPartialLocaleUsesLocalizedCoreControlsAndEnglishForUnknownText() {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "language")
        defer { defaults.set(previous, forKey: "language") }
        defaults.set("fr", forKey: "language")
        XCTAssertEqual(ReaderLocalization.language, "fr")
        for key in ["Theme name", "Customize…", "Delete Theme", "Partial translation"] {
            XCTAssertNotEqual(ReaderLocalization.string(key), key, "Core controls need a real translation")
        }
        let absent = "An unrecognized test-only label"
        XCTAssertEqual(ReaderLocalization.string(absent), absent)
    }

    func testSystemLanguageFallsBackToEnglishOnlyAfterSupportedPreferences() {
        XCTAssertEqual(ReaderLocalization.preferredLanguage([]), "en")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["zz-ZZ"]), "en")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["zz-ZZ", "fr-FR"]), "fr")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["zh-TW", "en-US"]), "zh-Hant")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["pt-BR", "pt-PT"]), "pt-BR")
    }
}
#endif
