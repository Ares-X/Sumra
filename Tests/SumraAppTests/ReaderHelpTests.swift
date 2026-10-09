#if os(macOS)
import XCTest
@testable import Sumra

@MainActor
final class ReaderHelpTests: XCTestCase {
    func testUpdatePreferenceMigrationPreservesOptOutAndRemovesObsoleteSchedule() throws {
        let suite = "SumraUpdateTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "checkForUpdates")
        defaults.set(Date(), forKey: "lastUpdateCheck")
        defaults.set("prerelease", forKey: "updateChannel")

        ReaderHelp.migrateUpdatePreferences(defaults: defaults)

        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "checkForUpdates"))
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheck"))
        XCTAssertEqual(defaults.string(forKey: "updateChannel"), "prerelease")
    }

    func testMigrationDoesNotOverrideASparklePreferenceOrOptInNewUsers() throws {
        let suite = "SumraUpdateTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ReaderHelp.migrateUpdatePreferences(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "SUEnableAutomaticChecks"))

        defaults.set(true, forKey: "checkForUpdates")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        ReaderHelp.migrateUpdatePreferences(defaults: defaults)
        ReaderHelp.migrateUpdatePreferences(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "checkForUpdates"))
    }
    func testUpdateSettingDefaultsAndRepeatedTogglesRoundTripThroughPublicJSONKey() throws {
        let defaults = UserDefaults.standard
        let keys = ["checkForUpdates", "SUEnableAutomaticChecks", "lastUpdateCheck"]
        let original = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in original {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: "checkForUpdates")
        defaults.removeObject(forKey: "SUEnableAutomaticChecks")
        XCTAssertTrue(ReaderPreferences.boolean(for: "checkForUpdates"))
        let initial = try ReaderPreferences.data(matching: "checkForUpdates")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: initial) as? [String: Bool]), ["checkForUpdates": true])
        XCTAssertNil(defaults.object(forKey: "SUEnableAutomaticChecks"), "Reading the default must not persist an opt-in")

        // Exercise the same public-key read/invert/import path as the palette.
        for expected in [false, true, false] {
            let change = try JSONSerialization.data(withJSONObject: ["checkForUpdates": !ReaderPreferences.boolean(for: "checkForUpdates")])
            try ReaderPreferences.apply(change)
            XCTAssertEqual(ReaderHelp.automaticUpdateChecks, expected)
            XCTAssertEqual(ReaderPreferences.boolean(for: "checkForUpdates"), expected)
            XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, expected)
            let exported = try ReaderPreferences.data(matching: "checkForUpdates")
            XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Bool]), ["checkForUpdates": expected])
            XCTAssertNil(defaults.object(forKey: "checkForUpdates"))
        }
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderPreferences.data()) as? [String: Any])
        XCTAssertNil(all["SUEnableAutomaticChecks"], "The advanced-settings contract keeps its existing public key")
    }
}
#endif
