import Foundation
import XCTest

/// Provides only an eight-second native XCTest screen-recording interval.
/// External, separately authorized controls own every action visible in it.
/// A passing result says nothing about Sumra behavior or visual acceptance.
final class PassiveScreenRecordingTests: XCTestCase {
    func testRecordEightSecondsWithoutUIInteraction() throws {
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SUMRA_PASSIVE_CAPTURE_READY_PATH"],
            "Provide a unique task-owned ready marker path via TEST_RUNNER_SUMRA_PASSIVE_CAPTURE_READY_PATH"
        )
        let marker = URL(fileURLWithPath: path)
        let ready = "passive-recording-ready; duration=8s; product-acceptance=NOT_ASSESSED\n"
        // Do not overwrite another run's marker or create/remove its directory.
        try Data(ready.utf8).write(to: marker, options: .withoutOverwriting)
        print("PASSIVE_RECORDING_READY: eight-second wait; no application or UI interaction")
        Thread.sleep(forTimeInterval: 8)
        print("PASSIVE_RECORDING_FINISHED: product acceptance NOT_ASSESSED")
    }
}
