#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class ReaderApplicationRestorationTests: XCTestCase {
    func testDisabledRestorationCompletesEveryNativeRequestWithoutReadingSavedState() throws {
        guard let application = ReaderAppKitApplication.shared as? ReaderAppKitApplication else {
            throw XCTSkip("Requires a fresh dedicated test host: another test already created the NSApplication singleton")
        }
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = arguments
        overrides["restoreSession"] = false
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }

        let identifiers = ["reader-AppWindow-1", "reader-AppWindow-2", "reader-AppWindow-3"]
        var completions = Array(repeating: 0, count: identifiers.count)
        for (index, identifier) in identifiers.enumerated() {
            let savedState = UnreadRestorationState()
            let handled = application.restoreWindow(withIdentifier: NSUserInterfaceItemIdentifier(identifier), state: savedState) { window, error in
                completions[index] += 1
                XCTAssertNil(window, "Disabled restoration must not recreate a saved reader")
                XCTAssertNil(error, "Skipping an unwanted saved reader is a completed request")
            }
            XCTAssertTrue(handled, "Every skipped native request must be handled so AppKit can finish restoration")
            XCTAssertEqual(completions[index], 1, "Each skipped request must complete exactly once")
            XCTAssertEqual(savedState.reads, 0, "Disabled restoration must not decode stale native window state")
        }
        XCTAssertEqual(completions, [1, 1, 1])
    }
}

private final class UnreadRestorationState: NSCoder {
    private(set) var reads = 0
    override var allowsKeyedCoding: Bool { reads += 1; return true }
    override func containsValue(forKey key: String) -> Bool { reads += 1; return false }
    override func decodeObject(forKey key: String) -> Any? { reads += 1; return nil }
    override func decodeObject() -> Any? { reads += 1; return nil }
    override func decodeValue(ofObjCType type: UnsafePointer<CChar>, at data: UnsafeMutableRawPointer, size: Int) { reads += 1 }
    override func decodeValue(ofObjCType type: UnsafePointer<CChar>, at data: UnsafeMutableRawPointer) { reads += 1 }
}
#endif
