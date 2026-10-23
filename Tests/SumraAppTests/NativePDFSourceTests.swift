#if os(macOS)
import CryptoKit
import Darwin
import XCTest
@testable import Sumra

final class NativePDFSourceTests: XCTestCase {
    func testNonPDFClassificationCannotOpenReplacedPDFOrInitializeItsScripts() throws {
        let libraryURL = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { throw XCTSkip("Build MuPDF before source tests") }
        let library = try XCTUnwrap(dlopen(libraryURL.path, RTLD_LOCAL | RTLD_NOW))
        defer { dlclose(library) }
        typealias Recognize = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
        let recognize = unsafeBitCast(try XCTUnwrap(dlsym(library, "lf_pdf_source")), to: Recognize.self)
        let open = unsafeBitCast(try XCTUnwrap(dlsym(library, "lf_open_classified")), to: NativeFile.OpenClassified.self)
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("changing.html")
        try Data("<html><body>Original HTML</body></html>".utf8).write(to: source)
        var error = [CChar](repeating: 0, count: 512), needsPassword: Int32 = 0
        XCTAssertEqual(recognize(source.path, &error), 0)
        let pdf = Data("%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
        try pdf.write(to: source, options: .atomic)
        XCTAssertNil(open(source.path, nil, &needsPassword, &error, 0))
        XCTAssertTrue(String(cString: error).contains("changed while opening"))
        XCTAssertEqual(needsPassword, 0)
        XCTAssertEqual(try Data(contentsOf: source), pdf)
    }

    func testSnapshotPreservesBytesAndRemovesItsPrivateDirectoryAtFinalRelease() throws {
        let sourceDirectory = try TemporaryDirectory()
        defer { withExtendedLifetime(sourceDirectory) {} }
        let source = sourceDirectory.url.appendingPathComponent("source.pdf")
        let original = Data("Original PDF bytes".utf8)
        try original.write(to: source)
        let expectedVersion = try XCTUnwrap(NativeFile.FileVersion(source))
        var snapshot: NativeFile.PDFSource? = try NativeFile.PDFSource(source)
        let input = try XCTUnwrap(snapshot?.url), directory = input.deletingLastPathComponent()
        XCTAssertNotEqual(NativeFile.FileVersion(input)?.inode, expectedVersion.inode)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: input.path)[.posixPermissions] as? NSNumber, 0o400)
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: 0); try writer.write(contentsOf: Data("External replacement".utf8)); try writer.close()
        XCTAssertEqual(try Data(contentsOf: input), original)
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("External replacement".utf8))
    }

    func testSnapshotCapturesSourceWithExistingFinderMetadata() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        let original = Data("Original PDF bytes".utf8)
        try original.write(to: source)
        let expectedVersion = try XCTUnwrap(NativeFile.FileVersion(source))
        let metadata = Data("benign metadata".utf8)
        XCTAssertEqual(source.path.withCString { path in
            metadata.withUnsafeBytes { setxattr(path, "com.sumra.test-metadata", $0.baseAddress, $0.count, 0, 0) }
        }, 0)
        let changed = try XCTUnwrap(NativeFile.FileVersion(source))
        XCTAssertNotEqual(changed, expectedVersion)
        XCTAssertTrue(expectedVersion.matchesContentMetadata(changed))
        let snapshot = try NativeFile.PDFSource(source)
        XCTAssertEqual(try Data(contentsOf: snapshot.url), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testSnapshotUsesCurrentCapturedBytesAfterEarlierWriteWithRestoredModificationTime() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        let original = Data("Original PDF bytes".utf8), replacement = Data("Modified PDF bytes".utf8)
        XCTAssertEqual(original.count, replacement.count)
        try original.write(to: source)
        let before = try XCTUnwrap(NativeFile.FileVersion(source))
        let writer = try FileHandle(forWritingTo: source)
        try writer.write(contentsOf: replacement); try writer.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: before.modifiedSeconds, tv_nsec: before.modifiedNanoseconds)]
        XCTAssertEqual(source.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }, 0)
        let snapshot = try NativeFile.PDFSource(source)
        XCTAssertEqual(try Data(contentsOf: snapshot.url), replacement)
        XCTAssertEqual(snapshot.checkpoint.digest, SHA256.hash(data: replacement))
        XCTAssertEqual(snapshot.sourceCheckpoint.version, NativeFile.FileVersion(source))
        XCTAssertTrue(try snapshot.sourceCheckpoint.matches(source))
    }

    func testCapturedCheckpointRejectsLaterWritesEvenWhenModificationTimeIsRestored() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        let original = Data("Original PDF bytes".utf8), replacement = Data("Modified PDF bytes".utf8)
        try original.write(to: source)
        let snapshot = try NativeFile.PDFSource(source), expected = snapshot.sourceCheckpoint
        let writer = try FileHandle(forWritingTo: source)
        try writer.write(contentsOf: replacement); try writer.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: expected.version.modifiedSeconds, tv_nsec: expected.version.modifiedNanoseconds)]
        XCTAssertEqual(source.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }, 0)
        XCTAssertFalse(try expected.matches(source))
        XCTAssertEqual(try Data(contentsOf: snapshot.url), original)
    }

    func testCapturedCheckpointRejectsReplacementPathWhileSnapshotRetainsItsBytes() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        let original = Data("Original PDF bytes".utf8)
        try original.write(to: source)
        let snapshot = try NativeFile.PDFSource(source)
        try Data("Replaced PDF bytes".utf8).write(to: source, options: .atomic)
        XCTAssertFalse(try snapshot.sourceCheckpoint.matches(source))
        XCTAssertEqual(try Data(contentsOf: snapshot.url), original)
    }

    func testSnapshotOpensFinderLockedSourceWithoutChangingOrLeakingIt() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("locked.pdf")
        let original = Data(repeating: 0x61, count: 2 * 1_048_576 + 17)
        try original.write(to: source)
        XCTAssertEqual(chflags(source.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(source.path, 0) }
        let expectedVersion = try XCTUnwrap(NativeFile.FileVersion(source))
        var snapshot: NativeFile.PDFSource? = try NativeFile.PDFSource(source)
        let input = try XCTUnwrap(snapshot?.url)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(snapshot?.checkpoint.digest, SHA256.hash(data: original))
        XCTAssertEqual(NativeFile.FileVersion(source), expectedVersion)
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.deletingLastPathComponent().path))
    }
}
#endif
