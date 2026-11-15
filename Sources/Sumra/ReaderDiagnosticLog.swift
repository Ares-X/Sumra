#if os(macOS)
import Darwin
import Foundation

/// Owns diagnostic files. No filesystem work is performed until an operation is queued.
final class ReaderDiagnosticLog {
    enum ExportError: Error {
        case noRecords
        case archiveFailed(Int32)
        case cleanupFailed(export: Error, cleanup: Error)
    }

    private let directory: URL
    private let onFailure: (Error) -> Void
    private let queue = DispatchQueue(label: "Sumra.ReaderDiagnosticLog", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private var handle: FileHandle?
    private var loggingFailure: Error?
    private var lastSuccessfulSequence: Int?

    init(directory: URL, onFailure: @escaping (Error) -> Void) {
        self.directory = directory
        self.onFailure = onFailure
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(fileID: UUID) {
        queue.async {
            self.closeCurrent()
            self.lastSuccessfulSequence = nil
            do {
                try self.prepareDirectory()
                let file = self.directory.appendingPathComponent(fileID.uuidString + ".jsonl")
                self.handle = try Self.openExclusive(file)
            } catch { self.recordFailure(error) }
        }
    }

    func append(_ record: [String: Any]) {
        queue.async {
            guard let handle = self.handle else { return }
            do {
                var data = try Self.encode(record, options: [.sortedKeys])
                data.append(0x0a)
                try handle.write(contentsOf: data)
                self.lastSuccessfulSequence = record["sequence"] as? Int
            } catch {
                self.recordFailure(error)
                self.closeCurrent()
            }
        }
    }

    func stop() {
        queue.async { self.closeCurrent() }
    }

    /// The failure callback runs on the IO queue and must not synchronously wait for the main actor.
    func closeAndWait() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeCurrent()
        } else {
            queue.sync { self.closeCurrent() }
        }
    }

    func inventory(completion: @escaping (Result<(count: Int, bytes: Int64), Error>) -> Void) {
        queue.async {
            do {
                let files = try self.logFiles()
                var bytes: Int64 = 0
                for file in files {
                    bytes += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
                completion(.success((files.count, bytes)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func exportReport(to destination: URL, metadata: [String: Any],
                      completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            // Sharing the writer's queue makes this an exact prefix of all queued records.
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".sumra-report-" + UUID().uuidString, isDirectory: true)
            var temporaryCreated = false
            var result: Result<Void, Error>
            do {
                if let handle = self.handle {
                    do { try handle.synchronize() }
                    catch {
                        self.recordFailure(error)
                        self.closeCurrent()
                        throw error
                    }
                }
                let files = try self.logFiles()
                guard !files.isEmpty else { throw ExportError.noRecords }
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                temporaryCreated = true
                let report = temporary.appendingPathComponent("Sumra-Window-Diagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: report, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                for file in files {
                    try Self.copyLog(file, to: report.appendingPathComponent(file.lastPathComponent))
                }
                var summary = metadata
                summary["loggingIncomplete"] = self.loggingFailure != nil
                summary["lastSuccessfulSequence"] = self.lastSuccessfulSequence.map { $0 as Any } ?? NSNull()
                if let error = self.loggingFailure {
                    summary["loggingError"] = Self.safeError(error)
                } else {
                    summary.removeValue(forKey: "loggingError")
                }
                let summaryFile = try Self.openExclusive(report.appendingPathComponent("report.json"))
                do {
                    let data = try Self.encode(summary, options: [.sortedKeys, .prettyPrinted])
                    try summaryFile.write(contentsOf: data)
                    try summaryFile.synchronize()
                    try summaryFile.close()
                } catch {
                    try? summaryFile.close()
                    throw error
                }
                let archive = temporary.appendingPathComponent("report.zip")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", report.path, archive.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw ExportError.archiveFailed(process.terminationStatus)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
                // Both paths are on the destination volume. rename replaces an old file only
                // after the complete ZIP exists and leaves it untouched if delivery fails.
                guard Darwin.rename(archive.path, destination.path) == 0 else { throw Self.posixError() }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            if temporaryCreated {
                do { try FileManager.default.removeItem(at: temporary) }
                catch {
                    switch result {
                    case .success: result = .failure(error)
                    case .failure(let exportError):
                        result = .failure(ExportError.cleanupFailed(export: exportError, cleanup: error))
                    }
                }
            }
            completion(result)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try validateDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func validateDirectory() throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }
    }

    private func logFiles() throws -> [URL] {
        do { try validateDirectory() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        return try files.filter { file in
            guard file.pathExtension == "jsonl",
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { return false }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func closeCurrent() {
        guard let handle else { return }
        self.handle = nil
        do { try handle.synchronize() }
        catch { recordFailure(error) }
        do { try handle.close() }
        catch { recordFailure(error) }
    }

    private func recordFailure(_ error: Error) {
        loggingFailure = error
        onFailure(error)
    }

    private static func openExclusive(_ file: URL) throws -> FileHandle {
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func copyLog(_ source: URL, to destination: URL) throws {
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let output = try openExclusive(destination)
        do {
            while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
    }

    private static func encode(_ object: [String: Any], options: JSONSerialization.WritingOptions) throws -> Data {
        // Foundation raises an Objective-C exception for values such as NaN.
        // Validate at the encoder boundary so a bad record is a visible logging failure.
        guard JSONSerialization.isValidJSONObject(object) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 3840)
        }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    static func safeError(_ error: Error) -> [String: Any] {
        let error = error as NSError
        var result: [String: Any] = ["domain": error.domain, "code": error.code]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            result["underlying"] = ["domain": underlying.domain, "code": underlying.code]
        }
        return result
    }
}
#endif
