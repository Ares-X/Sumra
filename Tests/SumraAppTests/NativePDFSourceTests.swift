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
        let expected = try XCTUnwrap(NativeFile.FileCheckpoint(source))
        var snapshot: NativeFile.PDFSource? = try NativeFile.PDFSource(source, expected: expected)
        let input = try XCTUnwrap(snapshot?.url), directory = input.deletingLastPathComponent()
        XCTAssertNotEqual(NativeFile.FileVersion(input)?.inode, expected.version.inode)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: input.path)[.posixPermissions] as? NSNumber, 0o400)
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: 0); try writer.write(contentsOf: Data("External replacement".utf8)); try writer.close()
        XCTAssertEqual(try Data(contentsOf: input), original)
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("External replacement".utf8))
    }

    func testSnapshotRejectsDifferentBytesEvenWithTheExpectedSourceMetadata() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        try Data("Current PDF bytes".utf8).write(to: source)
        let checkpoint = try XCTUnwrap(NativeFile.FileCheckpoint(source))
        let different = NativeFile.FileCheckpoint(version: checkpoint.version, digest: SHA256.hash(data: Data("Earlier bytes".utf8)))
        XCTAssertThrowsError(try NativeFile.PDFSource(source, expected: different)) {
            XCTAssertTrue($0.localizedDescription.contains("changed while opening"))
        }
        XCTAssertTrue(try checkpoint.matches(source))
    }

    func testSnapshotOpensFinderLockedSourceWithoutChangingOrLeakingIt() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("locked.pdf")
        let original = Data("Locked PDF bytes".utf8)
        try original.write(to: source)
        XCTAssertEqual(chflags(source.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(source.path, 0) }
        let expected = try XCTUnwrap(NativeFile.FileCheckpoint(source))
        var snapshot: NativeFile.PDFSource? = try NativeFile.PDFSource(source, expected: expected)
        let input = try XCTUnwrap(snapshot?.url)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(NativeFile.FileVersion(source), expected.version)
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.deletingLastPathComponent().path))
    }
}
#endif
