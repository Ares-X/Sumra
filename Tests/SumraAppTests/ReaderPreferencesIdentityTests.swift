#if os(macOS)
import XCTest
@testable import Sumra

@MainActor
final class ReaderPreferencesIdentityTests: XCTestCase {
    func testMigrationPreservesUserDataAndNewChoicesWithoutChangingOldDomain() throws {
        try withDomains { defaults, previousDomain, domain in
            let bytes = Data([0, 1, 127, 128, 255])
            let previous: [String: Any] = [
                "language": "zh-Hans", "theme": "old-theme", "fontSize": 21,
                "documentOpenHistory": bytes, "bookmarks": bytes,
                "position:/private/book.pdf": bytes, "bookmark:/private/book.pdf": bytes,
                "pinnedDocuments": ["/private/book.pdf"], "session": bytes,
                "SUEnableAutomaticChecks": false, "checkForUpdates": false,
                "SUFeedURL": "https://old.example/appcast.xml", "SUPublicEDKey": "old-key",
                "SUHasLaunchedBefore": true, "SULastCheckTime": Date(), "lastUpdateCheck": Date()
            ]
            defaults.setPersistentDomain(previous, forName: previousDomain)
            defaults.setPersistentDomain(["theme": "new-theme", "SUEnableAutomaticChecks": true], forName: domain)

            ReaderPreferences.migrateIdentity(defaults: defaults, previousDomain: previousDomain, domain: domain)

            let migrated = try XCTUnwrap(defaults.persistentDomain(forName: domain))
            XCTAssertEqual(migrated["language"] as? String, "zh-Hans")
            XCTAssertEqual(migrated["theme"] as? String, "new-theme")
            XCTAssertEqual(migrated["fontSize"] as? Int, 21)
            for key in ["documentOpenHistory", "bookmarks", "position:/private/book.pdf", "bookmark:/private/book.pdf", "session"] {
                XCTAssertEqual(migrated[key] as? Data, bytes, key)
            }
            XCTAssertEqual(migrated["pinnedDocuments"] as? [String], ["/private/book.pdf"])
            XCTAssertEqual(migrated["SUEnableAutomaticChecks"] as? Bool, true)
            XCTAssertEqual(migrated["checkForUpdates"] as? Bool, false)
            for key in ["SUFeedURL", "SUPublicEDKey", "SUHasLaunchedBefore", "SULastCheckTime", "lastUpdateCheck"] {
                XCTAssertNil(migrated[key], key)
            }
            XCTAssertEqual(defaults.persistentDomain(forName: previousDomain) as NSDictionary?, previous as NSDictionary)

            defaults.setPersistentDomain(["language": "fr", "fontSize": 99, "newOldKey": "later"], forName: previousDomain)
            ReaderPreferences.migrateIdentity(defaults: defaults, previousDomain: previousDomain, domain: domain)
            XCTAssertEqual(defaults.persistentDomain(forName: domain) as NSDictionary?, migrated as NSDictionary)
        }
    }

    func testAutomaticCheckChoiceMigratesWithoutSparkleRuntimeState() throws {
        try withDomains { defaults, previousDomain, domain in
            defaults.setPersistentDomain(["SUEnableAutomaticChecks": false, "SUHasLaunchedBefore": true], forName: previousDomain)
            ReaderPreferences.migrateIdentity(defaults: defaults, previousDomain: previousDomain, domain: domain)
            let migrated = try XCTUnwrap(defaults.persistentDomain(forName: domain))
            XCTAssertEqual(migrated["SUEnableAutomaticChecks"] as? Bool, false)
            XCTAssertNil(migrated["SUHasLaunchedBefore"])
        }
    }

    func testEmptyOldDomainIsMarkedCompleteBeforeOldDataAppears() throws {
        try withDomains { defaults, previousDomain, domain in
            ReaderPreferences.migrateIdentity(defaults: defaults, previousDomain: previousDomain, domain: domain)
            let migrated = try XCTUnwrap(defaults.persistentDomain(forName: domain))
            XCTAssertFalse(migrated.isEmpty)
            XCTAssertNil(defaults.persistentDomain(forName: previousDomain))
            defaults.setPersistentDomain(["language": "fr"], forName: previousDomain)
            ReaderPreferences.migrateIdentity(defaults: defaults, previousDomain: previousDomain, domain: domain)
            XCTAssertEqual(defaults.persistentDomain(forName: domain) as NSDictionary?, migrated as NSDictionary)
        }
    }

    private func withDomains(_ body: (UserDefaults, String, String) throws -> Void) throws {
        let nonce = "ReaderPreferencesIdentityTests-" + UUID().uuidString
        let previousDomain = nonce + ".previous", domain = nonce + ".current"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: previousDomain)
            defaults.removePersistentDomain(forName: domain)
        }
        try body(defaults, previousDomain, domain)
    }
}
#endif
