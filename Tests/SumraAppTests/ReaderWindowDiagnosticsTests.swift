#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import Sumra

@MainActor
final class ReaderWindowDiagnosticsTests: XCTestCase {
    func testDisabledRecordingDoesNotEvaluateFieldsOrCreateItsDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let recorder = fixture.makeRecorder()
        var evaluations = 0
        func fields() -> [String: Any] {
            evaluations += 1
            return ["count": evaluations]
        }

        XCTAssertFalse(recorder.enabled)
        recorder.startAtLaunch()
        recorder.observeApplication()
        XCTAssertNil(recorder.record("disabled.event", fields: fields()))
        recorder.snapshot("disabled.snapshot")
        recorder.finishAtTermination()

        XCTAssertEqual(evaluations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertFalse(fixture.defaults.bool(forKey: ReaderWindowDiagnostics.preferenceKey))
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.export(to: fixture.root.appendingPathComponent("empty.zip")) { continuation.resume(with: $0) }
            }
            XCTFail("Disabled recording with no retained sessions must report no records")
        } catch ReaderDiagnosticLog.ExportError.noRecords { }
        XCTAssertNil(recorder.lastError, "An empty report is not a recording IO failure")
        XCTAssertFalse(recorder.isExporting)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testWindowSnapshotsAvoidLazyTabGettersAndExportNoWindowText() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: ReaderWindowDiagnostics.preferenceKey)
        let secretTitle = "Private title " + UUID().uuidString
        let secretFilename = "Private-document-" + UUID().uuidString + ".pdf"
        let secretIdentifier = "Private tab group " + UUID().uuidString
        let secretPreference = "Private preference " + UUID().uuidString
        fixture.defaults.set(secretPreference, forKey: "documentOpenBehavior")
        let recorder = fixture.makeRecorder()
        recorder.startAtLaunch()

        _ = NSApplication.shared
        let window = GetterSpyWindow(contentRect: NSRect(x: 2400, y: 100, width: 640, height: 480),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.title = secretTitle
        window.representedURL = URL(fileURLWithPath: "/private/" + secretFilename)
        window.tabbingIdentifier = secretIdentifier
        // AppKit construction/configuration is outside the diagnostic read boundary.
        window.resetReadCounts()

        XCTAssertNotNil(recorder.record("test.window", window: window, fields: ["origin": "duplicate"]))
        recorder.snapshot("test.applicationSnapshot")
        XCTAssertEqual(window.tabGroupReads, 0, "Diagnostics must not create a native tab group while observing a window")
        XCTAssertEqual(window.identifierReads, 0, "Diagnostics must not initialize AppKit's default tab identifier")

        let report = try await export(recorder, fixture: fixture)
        let files = try FileManager.default.contentsOfDirectory(at: report, includingPropertiesForKeys: nil)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        for secret in [secretTitle, secretFilename, secretIdentifier, secretPreference] {
            XCTAssertFalse(text.contains(secret), "A window's user-controlled text must not enter its report")
        }
        let records = try readRecords(in: report)
        let event = try XCTUnwrap(records.first { $0["event"] as? String == "test.window" })
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        XCTAssertEqual(data["origin"] as? String, "duplicate")
        let capturedWindow = try XCTUnwrap(data["window"] as? [String: Any])
        XCTAssertNotNil(capturedWindow["id"] as? String)
        XCTAssertEqual((capturedWindow["cachedGroup"] as? [String: Any])?["observation"] as? String,
                       "not_observed")
    }

    func testObserversRetainRepeatedFullscreenNotificationCycles() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 2400, y: 100, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        fixture.defaults.set(true, forKey: ReaderWindowDiagnostics.preferenceKey)
        let recorder = fixture.makeRecorder()
        recorder.startAtLaunch()
        recorder.observeApplication()
        let cycle: [Notification.Name] = [NSWindow.willEnterFullScreenNotification,
                                          NSWindow.didEnterFullScreenNotification,
                                          NSWindow.willExitFullScreenNotification,
                                          NSWindow.didExitFullScreenNotification]
        // Exercise notification recording with unchanged public window state.
        // These controlled notifications do not enter fullscreen or prove Spaces.
        for _ in 0..<2 {
            for name in cycle { NotificationCenter.default.post(name: name, object: window) }
        }
        recorder.setEnabled(false)
        let report = try await export(recorder, fixture: fixture)
        let names = cycle.map(\.rawValue)
        let recorded = try readRecords(in: report).compactMap { $0["event"] as? String }
            .filter { names.contains($0) }
        XCTAssertEqual(recorded, names + names, "Recurring lifecycle transitions must not be deduplicated by their unchanged state")
    }

    func testNormalTerminationPreservesOptInAndNextLaunchRetainsBothSessionsForDisabledExport() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: ReaderWindowDiagnostics.preferenceKey)
        let first = fixture.makeRecorder()
        first.startAtLaunch()
        first.record("test.firstLaunch")
        first.finishAtTermination()
        XCTAssertTrue(fixture.defaults.bool(forKey: ReaderWindowDiagnostics.preferenceKey))

        let second = fixture.makeRecorder()
        XCTAssertTrue(second.enabled)
        second.startAtLaunch()
        second.record("test.secondLaunch")
        second.setEnabled(false)
        second.finishAtTermination()
        // Read the originals before export supplies its own writer-queue barrier.
        let retained = try readRecords(in: fixture.directory)
        let stopped = try XCTUnwrap(retained.first { $0["event"] as? String == "capture.disabled" })
        let stoppedCapture = try XCTUnwrap(stopped["capture"] as? String)
        let stoppedSequence = try XCTUnwrap(stopped["sequence"] as? Int)
        XCTAssertEqual(retained.filter { $0["capture"] as? String == stoppedCapture }.last?["event"] as? String,
                       "capture.disabled", "Immediate termination after stop must flush the closing record")
        XCTAssertFalse(second.enabled)
        XCTAssertFalse(fixture.defaults.bool(forKey: ReaderWindowDiagnostics.preferenceKey))
        let report = try await export(second, fixture: fixture)

        let files = try FileManager.default.contentsOfDirectory(at: report, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "jsonl" }.count, 2)
        let records = try readRecords(in: report)
        let events = records.compactMap { $0["event"] as? String }
        XCTAssertEqual(events.filter { $0 == "capture.started" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "process.endedNormally" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "capture.disabled" }.count, 1)
        let firstCapture = try XCTUnwrap(records.first { $0["event"] as? String == "test.firstLaunch" }?["capture"] as? String)
        let secondCapture = try XCTUnwrap(records.first { $0["event"] as? String == "test.secondLaunch" }?["capture"] as? String)
        XCTAssertNotEqual(firstCapture, secondCapture)
        XCTAssertEqual(secondCapture, stoppedCapture)
        let firstProcess = try XCTUnwrap(records.first { $0["event"] as? String == "test.firstLaunch" }?["process"] as? String)
        let secondProcess = try XCTUnwrap(records.first { $0["event"] as? String == "test.secondLaunch" }?["process"] as? String)
        XCTAssertNotEqual(firstProcess, secondProcess, "Separate recorder lifetimes must retain their own process identity")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report.appendingPathComponent("report.json"))) as? [String: Any])
        XCTAssertEqual(metadata["recordingEnabled"] as? Bool, false)
        XCTAssertEqual(metadata["loggingIncomplete"] as? Bool, false)
        XCTAssertEqual(metadata["sequenceCapture"] as? String, secondCapture)
        XCTAssertEqual(metadata["lastSuccessfulSequence"] as? Int, stoppedSequence)
        XCTAssertEqual(metadata["lastEnqueuedSequence"] as? Int, stoppedSequence)
    }

    func testDirectoryCreationFailurePublishesAnErrorAndPreservesTheBlockingFile() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = Data("existing file must survive".utf8)
        try original.write(to: fixture.directory)
        fixture.defaults.set(true, forKey: ReaderWindowDiagnostics.preferenceKey)
        let recorder = fixture.makeRecorder()
        let failed = expectation(description: "Recording IO failure becomes visible")
        let observation = recorder.$lastError.compactMap { $0 }.prefix(1).sink { _ in failed.fulfill() }
        defer { observation.cancel() }

        recorder.startAtLaunch()
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertFalse(try XCTUnwrap(recorder.lastError).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.directory), original)
    }

    func testImmediateTerminationWaitsForHistoricalReportExportWhileRecordingIsOff() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let previousLog = ReaderDiagnosticLog(directory: fixture.directory) { error in
            XCTFail("Unable to prepare the retained capture: \(error)")
        }
        defer { previousLog.closeAndWait() }
        previousLog.start(fileID: UUID())
        previousLog.append(["sequence": 1, "event": "test.retainedCapture"])
        previousLog.closeAndWait()

        let recorder = fixture.makeRecorder()
        recorder.startAtLaunch()
        XCTAssertFalse(recorder.enabled)
        let archive = fixture.root.appendingPathComponent("historical-report.zip")
        let exported = expectation(description: "Historical export completion reaches the caller")
        var result: Result<Void, Error>?
        recorder.export(to: archive) {
            result = $0
            exported.fulfill()
        }
        recorder.finishAtTermination()

        // Check before yielding to the asynchronous completion. Quit must wait
        // even though this process never started a capture or enqueued a record.
        let delivered = FileManager.default.fileExists(atPath: archive.path)
        XCTAssertTrue(delivered)
        if delivered {
            let archiveData = try Data(contentsOf: archive)
            XCTAssertTrue(archiveData.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .contains { $0.hasPrefix(".sumra-report-") })
        await fulfillment(of: [exported], timeout: 5)
        try XCTUnwrap(result).get()
        XCTAssertFalse(recorder.isExporting)
        XCTAssertNil(recorder.lastError)
    }

    private func export(_ recorder: ReaderWindowDiagnostics, fixture: Fixture) async throws -> URL {
        let archive = fixture.root.appendingPathComponent("report.zip")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.export(to: archive) { continuation.resume(with: $0) }
        }
        XCTAssertFalse(recorder.isExporting)
        let destination = fixture.root.appendingPathComponent("unpacked", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return destination.appendingPathComponent("Sumra-Window-Diagnostics", isDirectory: true)
    }

    private func readRecords(in directory: URL) throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        return try files.flatMap { file in
            try Data(contentsOf: file).split(separator: 0x0a).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }
    }

    @MainActor private final class GetterSpyWindow: NSWindow {
        private(set) var tabGroupReads = 0
        private(set) var identifierReads = 0
        override var tabGroup: NSWindowTabGroup? {
            tabGroupReads += 1
            return super.tabGroup
        }
        override var tabbingIdentifier: NSWindow.TabbingIdentifier {
            get { identifierReads += 1; return super.tabbingIdentifier }
            set { super.tabbingIdentifier = newValue }
        }
        func resetReadCounts() { tabGroupReads = 0; identifierReads = 0 }
    }

    @MainActor private final class Fixture {
        let root: URL
        let directory: URL
        let defaults: UserDefaults
        private let suite: String
        private var recorders: [ReaderWindowDiagnostics] = []

        init() throws {
            suite = "SumraWindowDiagnosticsTests-" + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            directory = root.appendingPathComponent("recordings")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func makeRecorder() -> ReaderWindowDiagnostics {
            let recorder = ReaderWindowDiagnostics(directory: directory, defaults: defaults)
            recorders.append(recorder)
            return recorder
        }

        func close() {
            for recorder in recorders { recorder.finishAtTermination() }
            recorders.removeAll()
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Unable to remove owned diagnostic test directory: \(error)") }
        }
    }
}
#endif
