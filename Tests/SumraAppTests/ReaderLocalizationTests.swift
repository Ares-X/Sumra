#if os(macOS)
import XCTest
@testable import Sumra

final class ReaderLocalizationTests: XCTestCase {
    func testSystemLanguageFallsBackToEnglishOnlyAfterSupportedPreferences() {
        XCTAssertEqual(ReaderLocalization.preferredLanguage([]), "en")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["zz-ZZ"]), "en")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["zz-ZZ", "fr-FR"]), "fr")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["zh-TW", "en-US"]), "zh-Hant")
        XCTAssertEqual(ReaderLocalization.preferredLanguage(["pt-BR", "pt-PT"]), "pt-BR")
    }
}
#endif
