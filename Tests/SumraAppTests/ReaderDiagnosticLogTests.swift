#if os(macOS)
import Foundation
import XCTest
@testable import Sumra

final class ReaderDiagnosticLogTests: XCTestCase {
    private final class Failures {
        private let lock = NSLock()
        private var values: [Error] = []
        func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; values.append(error) }
        var errors: [Error] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SumraDiagnosticLogTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func inventory(_ log: ReaderDiagnosticLog) async throws -> (count: Int, bytes: Int64) {
        try await withCheckedThrowingContinuation { continuation in
            log.inventory { continuation.resume(with: $0) }
        }
    }

    private func export(_ log: ReaderDiagnosticLog, to url: URL, metadata: [String: Any] = [:]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            log.exportReport(to: url, metadata: metadata) { continuation.resume(with: $0) }
        }
    }

    private func unpack(_ archive: URL, into directory: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return directory.appendingPathComponent("Vira Reader-Window-Diagnostics")
    }

    func testConstructionAndEmptyInventoryDoNotCreateFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("logs")
        let failures = Failures()
        let log = ReaderDiagnosticLog(directory: directory, onFailure: failures.append)
        defer { log.closeAndWait() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let result = try await inventory(log)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        do {
            try await export(log, to: root.appendingPathComponent("empty.zip"))
            XCTFail("An empty report must be distinguishable from a successful export")
        } catch ReaderDiagnosticLog.ExportError.noRecords { }
        XCTAssertTrue(failures.errors.isEmpty, "No records is an export result, not a recording failure")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testQueuedRecordsRemainFIFOAcrossStopAndRestart() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("logs")
        let failures = Failures()
        let log = ReaderDiagnosticLog(directory: directory, onFailure: failures.append)
        defer { log.closeAndWait() }
        let first = UUID(), second = UUID()
        log.start(fileID: first)
        for sequence in 1...100 { log.append(["sequence": sequence, "event": "test"]) }
        log.stop()
        log.start(fileID: second)
        log.append(["sequence": 1, "event": "restart"])
        log.closeAndWait()
        let firstData = try Data(contentsOf: directory.appendingPathComponent(first.uuidString + ".jsonl"))
        XCTAssertEqual(firstData.last, 0x0a)
        let records = try firstData.split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(records.compactMap { $0["sequence"] as? Int }, Array(1...100))
        let secondData = try Data(contentsOf: directory.appendingPathComponent(second.uuidString + ".jsonl"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: secondData) as? NSDictionary,
                       ["sequence": 1, "event": "restart"] as NSDictionary)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(first.uuidString + ".jsonl").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertTrue(failures.errors.isEmpty)
    }

    func testExportIncludesAllSessionsAndVerbatimCrashTailButExcludesUnownedEntries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let oldID = UUID(), activeID = UUID()
        let oldName = oldID.uuidString + ".jsonl"
        let crashData = Data("{\"sequence\":1}\n{\"sequence\":2,\"unfinished\":".utf8)
        try crashData.write(to: directory.appendingPathComponent(oldName))
        try Data("private unrelated data".utf8).write(to: directory.appendingPathComponent("notes.jsonl"))
        let outside = root.appendingPathComponent("outside.jsonl")
        try Data("outside data".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(UUID().uuidString + ".jsonl"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(UUID().uuidString + ".jsonl"), withIntermediateDirectories: false)
        let failures = Failures()
        let log = ReaderDiagnosticLog(directory: directory, onFailure: failures.append)
        defer { log.closeAndWait() }
        log.start(fileID: activeID)
        log.append(["sequence": 1, "event": "snapshot"])
        let archive = root.appendingPathComponent("report.zip")
        try await export(log, to: archive, metadata: ["schemaVersion": 1, "captureID": activeID.uuidString])
        log.append(["sequence": 2, "event": "after-export"])
        log.closeAndWait()
        let result = try await inventory(log)
        let activeName = activeID.uuidString + ".jsonl"
        let activeData = try Data(contentsOf: directory.appendingPathComponent(activeName))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.bytes, Int64(crashData.count + activeData.count))
        let report = try unpack(archive, into: root.appendingPathComponent("unpacked"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: report.path)), Set([oldName, activeName, "report.json"]))
        XCTAssertEqual(try Data(contentsOf: report.appendingPathComponent(oldName)), crashData)
        let exportedActive = try Data(contentsOf: report.appendingPathComponent(activeName))
        XCTAssertEqual(exportedActive.split(separator: 0x0a).count, 1)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report.appendingPathComponent("report.json"))) as? [String: Any])
        XCTAssertEqual(metadata["captureID"] as? String, activeID.uuidString)
        XCTAssertEqual(metadata["schemaVersion"] as? Int, 1)
        XCTAssertEqual(metadata["loggingIncomplete"] as? Bool, false)
        XCTAssertEqual(metadata["lastSuccessfulSequence"] as? Int, 1)
        XCTAssertTrue(failures.errors.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".sumra-report-") })
    }

    func testWriteFailureIsVisibleAndReportRetainsIncompleteStateAfterRestart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("logs")
        let failures = Failures()
        let log = ReaderDiagnosticLog(directory: directory, onFailure: failures.append)
        defer { log.closeAndWait() }
        let first = UUID()
        log.start(fileID: first)
        log.append(["sequence": 1])
        log.append(["sequence": 2, "invalid": Double.nan])
        log.append(["sequence": 3])
        log.closeAndWait()
        XCTAssertFalse(failures.errors.isEmpty)
        let firstData = try Data(contentsOf: directory.appendingPathComponent(first.uuidString + ".jsonl"))
        XCTAssertEqual(firstData.split(separator: 0x0a).count, 1)
        let archive = root.appendingPathComponent("incomplete.zip")
        try await export(log, to: archive)
        let report = try unpack(archive, into: root.appendingPathComponent("unpacked"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report.appendingPathComponent("report.json"))) as? [String: Any])
        XCTAssertEqual(metadata["loggingIncomplete"] as? Bool, true)
        XCTAssertEqual(metadata["lastSuccessfulSequence"] as? Int, 1)
        let error = try XCTUnwrap(metadata["loggingError"] as? [String: Any])
        XCTAssertEqual(Set(error.keys), Set(["domain", "code"]))
        let second = UUID()
        log.start(fileID: second)
        log.append(["sequence": 1])
        log.closeAndWait()
        XCTAssertFalse(try Data(contentsOf: directory.appendingPathComponent(second.uuidString + ".jsonl")).isEmpty)
        let secondArchive = root.appendingPathComponent("restarted.zip")
        try await export(log, to: secondArchive)
        let restarted = try unpack(secondArchive, into: root.appendingPathComponent("restarted"))
        let restartedMetadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: restarted.appendingPathComponent("report.json"))) as? [String: Any])
        XCTAssertEqual(restartedMetadata["loggingIncomplete"] as? Bool, true)
    }

    func testCreateAndExportFailuresPreserveEvidenceAndExistingDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("logs")
        let failures = Failures()
        let log = ReaderDiagnosticLog(directory: directory, onFailure: failures.append)
        defer { log.closeAndWait() }
        let id = UUID()
        log.start(fileID: id)
        log.append(["sequence": 1])
        log.closeAndWait()
        let source = directory.appendingPathComponent(id.uuidString + ".jsonl")
        let original = try Data(contentsOf: source)
        log.start(fileID: id) // Exclusive creation must never truncate an earlier session.
        log.append(["sequence": 2])
        log.closeAndWait()
        XCTAssertFalse(failures.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let destination = root.appendingPathComponent("report.zip")
        let oldDestination = Data("previous report".utf8)
        try oldDestination.write(to: destination)
        let previousFailureCount = failures.errors.count
        do {
            try await export(log, to: destination, metadata: ["invalid": Double.nan])
            XCTFail("Invalid report metadata must fail visibly")
        } catch { }
        XCTAssertEqual(failures.errors.count, previousFailureCount, "Export errors do not indicate broken recording")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: destination), oldDestination)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".sumra-report-") })
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let blockedLog = ReaderDiagnosticLog(directory: blocked, onFailure: failures.append)
        do {
            _ = try await inventory(blockedLog)
            XCTFail("A non-directory inventory must return its error")
        } catch { }
        XCTAssertEqual(failures.errors.count, previousFailureCount, "Inventory errors do not indicate broken recording")
        blockedLog.start(fileID: UUID())
        blockedLog.closeAndWait()
        XCTAssertEqual(try Data(contentsOf: blocked), Data("keep".utf8))
        XCTAssertGreaterThan(failures.errors.count, previousFailureCount)
    }
}
#endif
