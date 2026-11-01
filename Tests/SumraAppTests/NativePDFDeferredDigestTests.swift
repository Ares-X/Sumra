#if os(macOS)
import CryptoKit
import Darwin
import XCTest
@testable import Sumra

final class NativePDFDeferredDigestTests: XCTestCase {
    func testCloneCaptureDefersHashAndCannotAdoptAChangedPrivateInput() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        let original = Data("Original PDF bytes".utf8), replacement = Data("Modified PDF bytes".utf8)
        try original.write(to: source)
        try requireClone(source, in: directory.url)
        let captured = try NativeFile.PDFSource(source)
        // The unchanged original needs no content comparison at opening.
        XCTAssertTrue(try captured.sourceCheckpoint.matches(source))
        XCTAssertEqual(chmod(captured.url.path, 0o600), 0)
        let writer = try FileHandle(forWritingTo: captured.url)
        try writer.write(contentsOf: replacement); try writer.close()
        restoreModificationTime(captured.checkpoint.version, at: captured.url)
        // With an eager digest this would return the old hash. A deferred hash
        // must instead refuse the changed baseline before it reads any bytes.
        XCTAssertThrowsError(try captured.checkpoint.digest) {
            XCTAssertTrue($0.localizedDescription.contains("modified outside Sumra"))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDeferredCheckpointRetainsItsSnapshotAndAcceptsOnlyMetadataChanges() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf"), original = Data("Original PDF bytes".utf8)
        try original.write(to: source)
        try requireClone(source, in: directory.url)
        var captured: NativeFile.PDFSource? = try NativeFile.PDFSource(source)
        var checkpoint = captured?.sourceCheckpoint
        let input = try XCTUnwrap(captured?.url), temporary = input.deletingLastPathComponent()
        captured = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        let metadata = Data("Finder metadata".utf8)
        XCTAssertEqual(source.path.withCString { path in
            metadata.withUnsafeBytes { setxattr(path, "com.sumra.test-metadata", $0.baseAddress, $0.count, 0, 0) }
        }, 0)
        XCTAssertTrue(try XCTUnwrap(checkpoint).matches(source))
        XCTAssertEqual(try checkpoint?.digest, SHA256.hash(data: original))
        checkpoint = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testDeferredDigestRejectsRestoredMtimeWritesThroughSymlink() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf"), alias = directory.url.appendingPathComponent("alias.pdf")
        let original = Data("Original PDF bytes".utf8), replacement = Data("Modified PDF bytes".utf8)
        try original.write(to: source)
        try requireClone(source, in: directory.url)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let captured = try NativeFile.PDFSource(alias)
        let writer = try FileHandle(forWritingTo: source)
        try writer.write(contentsOf: replacement); try writer.close()
        restoreModificationTime(captured.sourceCheckpoint.version, at: source)
        XCTAssertFalse(try captured.sourceCheckpoint.matches(alias))
        XCTAssertEqual(try captured.checkpoint.digest, SHA256.hash(data: original))
        XCTAssertEqual(try Data(contentsOf: captured.url), original)
    }

    func testConcurrentCheckpointConsumersShareTheCapturedDigest() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf"), original = Data(repeating: 0x61, count: 3 * 1_048_576 + 17)
        try original.write(to: source)
        try requireClone(source, in: directory.url)
        let captured = try NativeFile.PDFSource(source), expected = SHA256.hash(data: original)
        let lock = NSLock()
        var values = [SHA256.Digest](), failures = [Error]()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                let value = try (index.isMultiple(of: 2) ? captured.checkpoint : captured.sourceCheckpoint).digest
                lock.lock(); values.append(value); lock.unlock()
            } catch { lock.lock(); failures.append(error); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(values.count, 8)
        XCTAssertTrue(values.allSatisfy { $0 == expected })
    }

    // Opt in with an existing valid PDF. Modes can run in fresh test processes
    // so their process-wide RSS high-water marks are comparable. These measure
    // real decoding pipelines, not GUI paint or cold-cache disk reads.
    func testNativeOpeningBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SUMRA_PDF_OPEN_BENCHMARK_FILE"] else {
            throw XCTSkip("Set SUMRA_PDF_OPEN_BENCHMARK_FILE to a valid PDF for native opening measurements")
        }
        let mode = environment["SUMRA_PDF_OPEN_BENCHMARK_MODE"] ?? "all"
        XCTAssertTrue(["all", "native", "reader", "home", "digest"].contains(mode), "Unknown benchmark mode")
        let source = URL(fileURLWithPath: path)
        let size = try XCTUnwrap(NativeFile.FileVersion(source)).size
        func report(_ pipeline: String, run: Int, started: UInt64, opened: UInt64, rendered: UInt64) {
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            print("ISSUE59_\(pipeline) run=\(run) bytes=\(size) open_ms=\(Double(opened - started) / 1e6) first_bitmap_ms=\(Double(rendered - started) / 1e6) max_rss_bytes=\(usage.ru_maxrss)")
        }
        if mode == "all" || mode == "native" {
            for run in 1...3 {
                let started = DispatchTime.now().uptimeNanoseconds
                let file = try NativeFile(source, engine: .mupdf)
                let opened = DispatchTime.now().uptimeNanoseconds
                let image = try file.image(0, width: 800)
                let rendered = DispatchTime.now().uptimeNanoseconds
                XCTAssertGreaterThan(file.count, 0)
                XCTAssertEqual(image.width, 800)
                report("NATIVE", run: run, started: started, opened: opened, rendered: rendered)
                withExtendedLifetime(file) {}
            }
        }
        if mode == "all" || mode == "reader" {
            for run in 1...3 {
                let started = DispatchTime.now().uptimeNanoseconds
                let document = try ReadingDocument.open(source)
                let opened = DispatchTime.now().uptimeNanoseconds
                guard case .pages(let pages) = document.content else { XCTFail("Benchmark input is not a PDF"); return }
                let image = try await pages.image(0, width: 800)
                let rendered = DispatchTime.now().uptimeNanoseconds
                XCTAssertEqual(image.width, 800)
                report("READER", run: run, started: started, opened: opened, rendered: rendered)
                withExtendedLifetime(document) {}
            }
        }
        if mode == "all" || mode == "home" {
            for run in 1...3 {
                let started = DispatchTime.now().uptimeNanoseconds
                let image = try await ReadingDocument.thumbnail(source, size: CGSize(width: 160, height: 208))
                let rendered = DispatchTime.now().uptimeNanoseconds
                XCTAssertNotNil(image)
                report("HOME", run: run, started: started, opened: started, rendered: rendered)
            }
        }
        if mode == "all" || mode == "digest" {
            var expected: SHA256.Digest?
            for run in 1...3 {
                try autoreleasepool {
                    // With the unlocked APFS fixture, each fresh snapshot takes
                    // the clone path and this is its deferred first demand.
                    // The source-copy path already hashes during capture; use
                    // the existing pdf-source-clone/copy marks to distinguish it.
                    let captured = try NativeFile.PDFSource(source)
                    var before = rusage(), after = rusage()
                    XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
                    let started = DispatchTime.now().uptimeNanoseconds
                    let value = try captured.checkpoint.digest
                    let finished = DispatchTime.now().uptimeNanoseconds
                    XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
                    if let expected { XCTAssertEqual(value, expected) }
                    else { expected = value }
                    let hash = value.map { String(format: "%02x", $0) }.joined()
                    print("ISSUE59_DIGEST run=\(run) bytes=\(size) digest_ms=\(Double(finished - started) / 1e6) baseline_max_rss_bytes=\(before.ru_maxrss) max_rss_bytes=\(after.ru_maxrss) peak_increase_bytes=\(after.ru_maxrss - before.ru_maxrss) sha256=\(hash)")
                    withExtendedLifetime(captured) {}
                }
            }
        }
    }

    private func requireClone(_ source: URL, in directory: URL) throws {
        let probe = directory.appendingPathComponent("clone-probe")
        let result = clonefile(source.path, probe.path, 0)
        if result == 0 { try FileManager.default.removeItem(at: probe); return }
        let failure = errno
        if failure == ENOTSUP || failure == EXDEV { throw XCTSkip("This test requires a cloning filesystem") }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    private func restoreModificationTime(_ version: NativeFile.FileVersion, at url: URL) {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: version.modifiedSeconds, tv_nsec: version.modifiedNanoseconds)]
        XCTAssertEqual(url.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }, 0)
    }
}
#endif
