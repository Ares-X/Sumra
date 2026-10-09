#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFSigningTests: XCTestCase {
    func testTrustedListParsesNamespacedCertificatesAndRetainsCacheOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-eutl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("eutl.json"), certificate = Data([1, 2, 3, 4])
        let lotl = Data("""
        <ts:List xmlns:ts="urn:etsi:tsl" xmlns:ds="urn:xml:dsig">
          <ds:X509Certificate>AQID BA==</ds:X509Certificate>
          <ts:TSLLocation>https://fixture.invalid/national.xml?version=2</ts:TSLLocation>
          <ts:TSLLocation>https://fixture.invalid/copy.pdf</ts:TSLLocation>
        </ts:List>
        """.utf8)
        let national = Data("<List><X509Certificate>AQIDBA==</X509Certificate><X509Certificate>BQY=</X509Certificate></List>".utf8)
        let update = try await ReaderCertificateList.update(at: cache) { url in
            if url == ReaderCertificateList.lotlURL { return lotl }
            guard url.path == "/national.xml" else { throw ReadError("Unexpected URL") }
            return national
        }
        XCTAssertTrue(update.failures.isEmpty)
        XCTAssertEqual(update.snapshot.nationalLists, 1)
        XCTAssertEqual(update.snapshot.fingerprints.count, 2, "Shared certificates occur only once")
        XCTAssertTrue(update.snapshot.contains(certificate))
        XCTAssertFalse(update.snapshot.contains(Data([4, 3, 2, 1])))
        XCTAssertEqual(try ReaderCertificateList.read(from: cache)?.fingerprints, update.snapshot.fingerprints)
        let saved = try Data(contentsOf: cache)
        do {
            _ = try await ReaderCertificateList.update(at: cache) { _ in throw ReadError("Offline fixture") }
            XCTFail("A failed explicit update must report the download failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Offline fixture")) }
        XCTAssertEqual(try Data(contentsOf: cache), saved)
        XCTAssertThrowsError(try ReaderCertificateList.parse(Data("<broken>".utf8)))
    }

    func testTrustedListReportsSkippedNationalListAndKeepsAvailableEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-eutl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let lotl = Data("<List><X509Certificate>AQID</X509Certificate><TSLLocation>https://fixture.invalid/tsl.xtsl</TSLLocation></List>".utf8)
        let update = try await ReaderCertificateList.update(at: directory.appendingPathComponent("eutl.json")) { url in
            if url == ReaderCertificateList.lotlURL { return lotl }
            throw ReadError("National list unavailable")
        }
        XCTAssertEqual(update.snapshot.nationalLists, 0)
        XCTAssertTrue(update.snapshot.contains(Data([1, 2, 3])))
        XCTAssertEqual(update.failures.count, 1)
        XCTAssertTrue(update.failures[0].contains("National list unavailable"))
    }

    func testSignedCopyIncludesLiveEditsWithoutChangingTheReaderOrOriginal() throws {
        let directory = try directory(), source = try fixture(in: directory), identity = try identity(in: directory)
        let original = try Data(contentsOf: source), file = try NativeFile(source, engine: .mupdf)
        let unsigned = try XCTUnwrap(file.pdfSignatureInfo().unsignedFields.first)
        XCTAssertEqual(unsigned.name, "Approval"); XCTAssertEqual(unsigned.page, 0)
        let unsignedWidget = try XCTUnwrap(file.pdfAnnotations(0).first { $0.fieldName == "Approval" })
        XCTAssertTrue(unsignedWidget.isUnsignedSignature); XCTAssertTrue(unsignedWidget.isEmptyFormField)
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        try file.pdfSetEditing(true)
        _ = try file.pdfCreateAnnotation(page: 0, type: "Text", bounds: CGRect(x: 30, y: 40, width: 20, height: 20), edits: [.contents("Unsaved note")])
        let before = try XCTUnwrap(file.pdfInfo()), destination = directory.appendingPathComponent("signed.pdf")
        let bounds = CGRect(x: 60, y: 80, width: 160, height: 40)
        try file.pdfSignCopy(to: destination, sourceURL: source, password: "", identity: .pkcs12(identity, password: "fixture"),
            fieldName: "Approval", page: 0, bounds: bounds)
        let result = try NativeFile(destination, engine: .mupdf), signatures = try result.pdfSignatureInfo()
        let signed = try XCTUnwrap(signatures.signatures.first)
        XCTAssertEqual(signatures.signatures.count, 1)
        XCTAssertEqual(signed.name, "Approval"); XCTAssertTrue(signed.isSigned)
        XCTAssertEqual(signed.pending, false); XCTAssertEqual(signed.digestValid, true)
        let annotations = try result.pdfAnnotations(0)
        let signedWidget = try XCTUnwrap(annotations.first { $0.fieldName == "Approval" })
        XCTAssertEqual(signedWidget.isSigned, true); XCTAssertFalse(signedWidget.isEmptyFormField)
        XCTAssertTrue(annotations.contains { $0.contents == "Unsaved note" })
        XCTAssertEqual(try XCTUnwrap(annotations.first { $0.fieldName == "Approval" }).bounds, bounds,
                       "The GUI selection is already in Fitz coordinates, including crop, rotation, and UserUnit")
        XCTAssertTrue(try Data(contentsOf: destination).starts(with: original))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try file.pdfSignatureInfo().unsignedFields.count, 1)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).dirty, before.dirty)
        try file.pdfUndo(redo: false)
        XCTAssertFalse(try file.pdfAnnotations(0).contains { $0.contents == "Unsaved note" })
    }

    func testSignedCopyKeepsImmutableSourceAfterExternalInPlaceOverwrite() throws {
        let directory = try directory(), source = try fixture(in: directory), identity = try identity(in: directory)
        let original = try Data(contentsOf: source), file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        let writer = try FileHandle(forWritingTo: source), replacement = Data("External bytes".utf8)
        try writer.truncate(atOffset: 0); try writer.write(contentsOf: replacement); try writer.close()
        let destination = directory.appendingPathComponent("signed-original.pdf")
        try file.pdfSignCopy(to: destination, sourceURL: source, password: "", identity: .pkcs12(identity, password: "fixture"),
            fieldName: "Approval", page: 0, bounds: .zero)
        let signed = try NativeFile(destination, engine: .mupdf)
        XCTAssertEqual(try signed.pdfSignatureInfo().signatures.first?.digestValid, true)
        XCTAssertTrue(try Data(contentsOf: destination).starts(with: original))
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        XCTAssertEqual(try file.pdfSignatureInfo().unsignedFields.count, 1)
    }

    func testSecondSignatureKeepsEarlierSignedBytesAndIncludesLaterEdits() throws {
        let directory = try directory(), source = try fixture(in: directory), identity = try identity(in: directory)
        let first = directory.appendingPathComponent("first.pdf"), second = directory.appendingPathComponent("second.pdf")
        let original = try NativeFile(source, engine: .mupdf)
        try original.pdfSetEditing(true)
        try original.pdfSignCopy(to: first, sourceURL: source, password: "", identity: .pkcs12(identity, password: "fixture"), fieldName: "Approval", page: 0, bounds: .zero)
        let firstBytes = try Data(contentsOf: first), live = try NativeFile(first, engine: .mupdf)
        try live.pdfSetEditing(true)
        _ = try live.pdfCreateAnnotation(page: 0, type: "Text", bounds: CGRect(x: 20, y: 20, width: 20, height: 20), edits: [.contents("Later edit")])
        XCTAssertEqual(try live.pdfSignatureInfo().signatures.first?.digestValid, true)
        try live.pdfSignCopy(to: second, sourceURL: first, password: "", identity: .pkcs12(identity, password: "fixture"), fieldName: "Second", page: 0, bounds: .zero)
        let completed = try NativeFile(second, engine: .mupdf), fields = try completed.pdfSignatureInfo().signatures
        XCTAssertEqual(fields.map(\.name).sorted(), ["Approval", "Second"])
        XCTAssertTrue(fields.allSatisfy { $0.isSigned && $0.pending == false && $0.digestValid == true })
        XCTAssertEqual(fields.first { $0.name == "Approval" }?.changedSinceSigning, true)
        XCTAssertEqual(fields.first { $0.name == "Second" }?.changedSinceSigning, false)
        XCTAssertTrue(try completed.pdfAnnotations(0).contains { $0.contents == "Later edit" })
        XCTAssertTrue(try Data(contentsOf: second).starts(with: firstBytes))
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try live.pdfSignatureInfo().signatures.count, 1)
        XCTAssertTrue(try XCTUnwrap(live.pdfInfo()).dirty)
    }

    func testLockedFailedIdentityAndFailedOutputLeaveLiveStateAndDestinationIntact() throws {
        let directory = try directory(), source = try fixture(in: directory), identity = try identity(in: directory)
        let file = try NativeFile(source, engine: .mupdf), destination = directory.appendingPathComponent("existing.pdf")
        let preserved = Data("existing output".utf8), sourceBytes = try Data(contentsOf: source)
        try preserved.write(to: destination)
        func sign(_ output: URL, password: String = "fixture") throws {
            try file.pdfSignCopy(to: output, sourceURL: source, password: "", identity: .pkcs12(identity, password: password), fieldName: "Approval", page: 0, bounds: .zero)
        }
        XCTAssertThrowsError(try sign(destination))
        try file.pdfSetEditing(true)
        _ = try file.pdfCreateAnnotation(page: 0, type: "Text", bounds: CGRect(x: 20, y: 20, width: 20, height: 20), edits: [.contents("Keep this edit")])
        let before = try XCTUnwrap(file.pdfInfo())
        XCTAssertThrowsError(try sign(destination, password: "incorrect"))
        XCTAssertThrowsError(try sign(directory.appendingPathComponent("missing-directory/output.pdf")))
        XCTAssertThrowsError(try sign(source))
        XCTAssertEqual(try Data(contentsOf: destination), preserved)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoSteps, before.undoSteps)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).dirty, before.dirty)
        XCTAssertEqual(try file.pdfSignatureInfo().unsignedFields.count, 1)
        XCTAssertTrue(try file.pdfAnnotations(0).contains { $0.contents == "Keep this edit" })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".Sumra-PDF-") })
        try sign(destination)
        XCTAssertEqual(try NativeFile(destination, engine: .mupdf).pdfSignatureInfo().signatures.first?.digestValid, true)
    }

    func testFormPermissionAllowsSigningWithoutAnOwnerPasswordAndKeepsEncryption() throws {
        let directory = try directory(), source = try fixture(in: directory), identity = try identity(in: directory)
        let encrypted = directory.appendingPathComponent("encrypted.pdf"), destination = directory.appendingPathComponent("signed-encrypted.pdf")
        // The existing API uses the PDFKit permission ordering: fill forms is bit 7.
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: 1 << 7)
        let file = try NativeFile(encrypted, engine: .mupdf, password: "reader")
        let permissions = try XCTUnwrap(file.pdfInfo())
        XCTAssertFalse(permissions.ownerAuthenticated); XCTAssertTrue(permissions.permissions.form)
        XCTAssertFalse(permissions.permissions.edit); XCTAssertFalse(permissions.permissions.annotate)
        try file.pdfSetEditing(true)
        try file.pdfSignCopy(to: destination, sourceURL: encrypted, password: "reader", identity: .pkcs12(identity, password: "fixture"), fieldName: "Approval", page: 0, bounds: .zero)
        XCTAssertThrowsError(try NativeFile(destination, engine: .mupdf))
        let result = try NativeFile(destination, engine: .mupdf, password: "reader")
        XCTAssertEqual(try result.pdfSignatureInfo().signatures.first?.digestValid, true)
        XCTAssertFalse(try XCTUnwrap(result.pdfInfo()).permissions.edit)
        let restricted = directory.appendingPathComponent("no-form-permission.pdf")
        try NativePDFTools.encrypt(source: source, destination: restricted, ownerPassword: "owner", userPassword: "reader", permissions: 0)
        XCTAssertThrowsError(try NativePDFTools.sign(source: restricted, destination: directory.appendingPathComponent("forbidden.pdf"),
            identity: .pkcs12(identity, password: "fixture"), fieldName: "Approval", documentPassword: "reader"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden.pdf").path))
    }

    private func directory() throws -> URL {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else { throw XCTSkip("Build MuPDF before native signing tests") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-live-signing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func fixture(in directory: URL) throws -> URL {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 820] /CropBox [30 40 570 760] /Rotate 90 /UserUnit 2 /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [60 80 220 120] /F 4 /P 3 0 R /Lock << /Action /Include /Fields [] >> /DA (/Helv 0 Tf 0 g) >>",
            "<< /Fields [4 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = directory.appendingPathComponent("source.pdf"); try bytes.write(to: url); return url
    }
    private func identity(in directory: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { throw XCTSkip("System OpenSSL is unavailable") }
        func run(_ arguments: [String]) throws {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ReadError(String(decoding: data, as: UTF8.self)) }
        }
        let key = directory.appendingPathComponent("key.pem"), certificate = directory.appendingPathComponent("certificate.pem"), identity = directory.appendingPathComponent("identity.p12")
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1", "-subj", "/CN=Sumra Live Signing Test", "-keyout", key.path, "-out", certificate.path])
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", certificate.path, "-out", identity.path, "-passout", "pass:fixture"])
        return identity
    }
}
#endif
