#if os(macOS)
import XCTest
@testable import Sumra

final class ReaderLocalizationTests: XCTestCase {
    func testBundledCatalogsCoverManagedInterfaceInventory() {
        for language in ReaderLocalization.languages where language != "system" {
            XCTAssertFalse(ReaderLocalization.isPartial(language), "The completed interface inventory must ship for \(language)")
        }
    }

    func testRetiredLanguagePreferencesUseSystemAndAreNotOffered() {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "language")
        defer { defaults.set(previous, forKey: "language") }
        let choices = Set(ReaderLocalization.languages)
        XCTAssertTrue(choices.isDisjoint(with: ReaderLocalization.retiredLanguages))
        for retired in ReaderLocalization.retiredLanguages {
            defaults.set(retired, forKey: "language")
            XCTAssertEqual(ReaderLocalization.selection(retired), "system")
            XCTAssertEqual(ReaderLocalization.language, ReaderLocalization.preferredLanguage(Locale.preferredLanguages))
        }
    }

    func testExplicitLocaleUsesLocalizedCoreControlsAndEnglishForUnknownText() {
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

    func testExplicitLanguageChangesRemainLiveAfterResolvingSystemFallback() {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "language")
        defer { defaults.set(previous, forKey: "language") }
        defaults.set("system", forKey: "language")
        let systemLanguage = ReaderLocalization.preferredLanguage(Locale.preferredLanguages)
        XCTAssertEqual(ReaderLocalization.language, systemLanguage)
        for language in ["fr", "ja", "ar", "en"] {
            defaults.set(language, forKey: "language")
            XCTAssertEqual(ReaderLocalization.language, language)
        }
        defaults.set("system", forKey: "language")
        XCTAssertEqual(ReaderLocalization.language, systemLanguage)
        defaults.set("unsupported-test-language", forKey: "language")
        XCTAssertEqual(ReaderLocalization.language, systemLanguage)
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
