#if os(macOS)
import AppKit
import ImageIO
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFOutputTests: XCTestCase {
    func testFinderLockedPDFAllowsReadingEditingCopiesAndPrintWithoutChangingSource() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("locked.pdf"), copy = directory.url.appendingPathComponent("copy.pdf")
        let original = readOnlyFixture(secondPageText: "LOCKED ORIGINAL")
        try original.write(to: source)
        XCTAssertEqual(chflags(source.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(source.path, 0) }
        let expected = try XCTUnwrap(NativeFile.FileCheckpoint(source))
        let pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
            bounds: CGRect(x: 10, y: 20, width: 40, height: 30), edits: [.contents("Locked input edit")])
        try await pages.pdfSaveCopy(to: copy)
        let recovered = try NativeFile(copy, engine: .mupdf)
        XCTAssertEqual(try recovered.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines), "LOCKED ORIGINAL")
        XCTAssertTrue(try recovered.pdfAnnotations(0).contains { $0.contents == "Locked input edit" })
        let prepared = try await pages.preparePDFPrint(to: directory.url.appendingPathComponent("print.pdf"), password: "")
        XCTAssertEqual(try prepared.file.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines), "LOCKED ORIGINAL")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(NativeFile.FileVersion(source), expected.version)
    }

    func testDirectNativePDFRecoversImmutableInputAfterUnlinkAndInPlaceWrite() throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for name in ["direct.pdf", "misnamed.markdown"] {
            let source = directory.url.appendingPathComponent(name), output = directory.url.appendingPathComponent(name + "-copy.pdf")
            let bytes = readOnlyFixture(padding: 1_048_576, secondPageText: "UNLOADED OLD", secondPagePadding: 1_048_576)
            try bytes.write(to: source)
            let writer = try FileHandle(forUpdating: source)
            defer { try? writer.close() }
            let file = try NativeFile(source, engine: .mupdf)
            try file.pdfSetEditing(true)
            let annotation = try file.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 40, height: 30),
                                                         edits: [.contents("Keep local edit")])
            let before = try file.pdfInfo()
            try FileManager.default.removeItem(at: source)
            let offset = try XCTUnwrap(bytes.range(of: Data("UNLOADED OLD".utf8))).lowerBound + "UNLOADED ".utf8.count
            try writer.seek(toOffset: UInt64(offset)); try writer.write(contentsOf: Data("NEW".utf8))
            let sentinel = Data("Keep existing output".utf8)
            try sentinel.write(to: output)
            XCTAssertEqual(try file.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines), "UNLOADED OLD")
            _ = try file.pdfWrite(to: output)
            XCTAssertEqual(PDFDocument(url: output)?.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "UNLOADED OLD")
            XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.annotations.first?.contents, "Keep local edit")
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == annotation }?.contents, "Keep local edit")
            let after = try file.pdfInfo()
            XCTAssertEqual(after?.dirty, true)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps)
        }
    }

    func testImmutablePDFStreamRecoversCopyAndPrintAfterPathAndRetainedInodeChanges() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), files = FileManager.default
        defer { withExtendedLifetime(directory) {} }
        for (name, unlink, truncate, restoreTime, ownSave) in [
            ("replacement-write", false, false, false, false),
            ("unlink-write", true, false, false, false),
            ("replacement-truncate", false, true, false, false),
            ("unlink-restored-mtime", true, false, true, false),
            ("own-save-old-write", false, false, false, true)
        ] {
            let source = directory.url.appendingPathComponent(name + ".pdf")
            let copy = directory.url.appendingPathComponent(name + "-copy.pdf")
            let snapshot = directory.url.appendingPathComponent(name + "-print.pdf")
            let bytes = readOnlyFixture(padding: 1_048_576, secondPageText: "UNLOADED OLD", secondPagePadding: 1_048_576)
            try bytes.write(to: source)
            let writer = try FileHandle(forUpdating: source)
            defer { try? writer.close() }
            let original = try XCTUnwrap(NativeFile.FileVersion(descriptor: writer.fileDescriptor))
            let pages = try Pages(source, format: .pdf)
            try await pages.pdfSetEditing(true)
            let annotation = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
                bounds: CGRect(x: 10, y: 20, width: 40, height: 30), edits: [.contents("Keep local edit")])
            if ownSave { try await pages.pdfSave(to: source) }
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Keep local edit")])
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Future edit")])
            try await pages.pdfUndo()
            let before = try await pages.pdfInfo(), annotations = try await pages.pdfAnnotations(0)
            if !ownSave {
                if unlink { try files.removeItem(at: source) }
                else { try readOnlyFixture(firstPageText: "External replacement").write(to: source, options: .atomic) }
            }
            let pathBytes = try? Data(contentsOf: source), pathVersion = NativeFile.FileVersion(source)
            let offset = try XCTUnwrap(bytes.range(of: Data("UNLOADED OLD".utf8))).lowerBound + "UNLOADED ".utf8.count
            if truncate { try writer.truncate(atOffset: UInt64(offset)) }
            else {
                try writer.seek(toOffset: UInt64(offset))
                try writer.write(contentsOf: Data("NEW".utf8))
                if restoreTime {
                    var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                                 timespec(tv_sec: original.modifiedSeconds, tv_nsec: original.modifiedNanoseconds)]
                    XCTAssertEqual(futimens(writer.fileDescriptor, &times), 0, name)
                    let changed = try XCTUnwrap(NativeFile.FileVersion(descriptor: writer.fileDescriptor))
                    XCTAssertTrue(original.matchesContentMetadata(changed), name)
                    XCTAssertNotEqual(original, changed, name)
                }
            }
            let sentinel = Data("Keep existing output".utf8)
            try sentinel.write(to: copy); try sentinel.write(to: snapshot)
            let originalText = try await pages.text(1)
            XCTAssertEqual(originalText.trimmingCharacters(in: .whitespacesAndNewlines), "UNLOADED OLD", name)
            try await pages.pdfSaveCopy(to: copy)
            let copied = try XCTUnwrap(PDFDocument(url: copy))
            XCTAssertEqual(copied.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "UNLOADED OLD", name)
            XCTAssertEqual(copied.page(at: 0)?.annotations.first?.contents, "Keep local edit", name)
            let prepared = try await pages.preparePDFPrint(to: snapshot, password: "")
            XCTAssertEqual(try prepared.file.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines), "UNLOADED OLD", name)
            XCTAssertEqual(try prepared.file.pdfAnnotations(0).first { $0.id == annotation }?.contents, "Keep local edit", name)
            XCTAssertEqual(try? Data(contentsOf: source), pathBytes, name)
            XCTAssertEqual(NativeFile.FileVersion(source), pathVersion, name)
            let after = try await pages.pdfInfo(), retained = try await pages.pdfAnnotations(0)
            XCTAssertEqual(after?.dirty, true, name)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition, name)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps, name)
            XCTAssertEqual(after?.redoTitle, before?.redoTitle, name)
            XCTAssertEqual(retained.map(\.contents), annotations.map(\.contents), name)
            try await pages.pdfUndo(redo: true)
            let redone = try await pages.pdfAnnotations(0)
            XCTAssertEqual(redone.first { $0.id == annotation }?.contents, "Future edit", name)
        }
    }

    func testUnchangedRetainedPDFStreamRecoversUnloadedPagesAfterReplacementOrUnlink() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for unlink in [false, true] {
            let source = directory.url.appendingPathComponent(unlink ? "unlinked.pdf" : "replaced.pdf")
            let output = directory.url.appendingPathComponent(unlink ? "unlinked-copy.pdf" : "replaced-copy.pdf")
            try readOnlyFixture(padding: 1_048_576, secondPageText: "UNLOADED OLD", secondPagePadding: 1_048_576).write(to: source)
            let pages = try Pages(source, format: .pdf)
            try await pages.pdfSetEditing(true)
            _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
                bounds: CGRect(x: 10, y: 20, width: 40, height: 30), edits: [.contents("Keep local edit")])
            if unlink { try FileManager.default.removeItem(at: source) }
            else { try readOnlyFixture(firstPageText: "External replacement").write(to: source, options: .atomic) }
            try await pages.pdfSaveCopy(to: output)
            let saved = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(saved.pageCount, 2)
            XCTAssertEqual(saved.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "UNLOADED OLD")
            XCTAssertEqual(saved.page(at: 0)?.annotations.first?.contents, "Keep local edit")
            let info = try await pages.pdfInfo()
            XCTAssertEqual(info?.dirty, true)
        }
    }

    func testOrdinarySaveAcceptsMetadataChangesBeforeFirstAndAfterOwnSaves() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for ownSaves in [0, 2] {
            let source = directory.url.appendingPathComponent("metadata-\(ownSaves).pdf")
            try readOnlyFixture(firstPageText: "OLD", withForm: true).write(to: source)
            let pages = try Pages(source, format: .pdf)
            try await pages.pdfSetEditing(true)
            let annotation = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
                bounds: CGRect(x: 10, y: 20, width: 40, height: 30), edits: [.contents("Initial local edit")])
            let fields = try await pages.pdfAnnotations(0)
            let field = try XCTUnwrap(fields.first { $0.fieldName == "input" }).id
            for index in 0..<ownSaves {
                try await pages.pdfSetWidgetValue(page: 0, id: field, value: "Saved \(index)")
                try await pages.pdfSave(to: source)
            }
            try await pages.pdfSetWidgetValue(page: 0, id: field, value: "Keep local field")
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Keep local edit")])
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Future edit")])
            try await pages.pdfUndo()
            let before = try await pages.pdfInfo(), original = try Data(contentsOf: source)
            let version = try XCTUnwrap(NativeFile.FileVersion(source)), metadata = Data("benign metadata".utf8)
            let result = source.path.withCString { path in
                metadata.withUnsafeBytes { setxattr(path, "com.sumra.test-metadata", $0.baseAddress, $0.count, 0, 0) }
            }
            XCTAssertEqual(result, 0)
            let changed = try XCTUnwrap(NativeFile.FileVersion(source))
            XCTAssertNotEqual(changed, version)
            XCTAssertTrue(version.matchesContentMetadata(changed))
            XCTAssertEqual(try Data(contentsOf: source), original)
            try await pages.pdfSave(to: source)
            let after = try await pages.pdfInfo(), saved = try NativeFile(source, engine: .mupdf)
            XCTAssertEqual(after?.dirty, false)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps)
            XCTAssertEqual(try saved.pdfAnnotations(0).first { $0.id == field }?.value, "Keep local field")
            XCTAssertEqual(try saved.pdfAnnotations(0).first { $0.id == annotation }?.contents, "Keep local edit")
            try await pages.pdfUndo(redo: true)
            let redone = try await pages.pdfAnnotations(0)
            XCTAssertEqual(redone.first { $0.id == annotation }?.contents, "Future edit")
            try await pages.pdfSave(to: source)
            let savedAgain = try NativeFile(source, engine: .mupdf)
            XCTAssertEqual(try savedAgain.pdfAnnotations(0).first { $0.id == annotation }?.contents, "Future edit")
        }
    }

    func testRestoredModificationTimeCannotHideChangedBytesBeforeFirstOrAfterOwnSaves() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for ownSaves in [0, 2] {
            let source = directory.url.appendingPathComponent("restored-mtime-\(ownSaves).pdf")
            let copy = directory.url.appendingPathComponent("restored-mtime-\(ownSaves)-copy.pdf")
            try readOnlyFixture(firstPageText: "OLD", padding: 10_000, withForm: true).write(to: source)
            let pages = try Pages(source, format: .pdf)
            try await pages.pdfSetEditing(true)
            let annotation = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
                bounds: CGRect(x: 10, y: 20, width: 40, height: 30), edits: [.contents("Initial local edit")])
            let fields = try await pages.pdfAnnotations(0)
            let field = try XCTUnwrap(fields.first { $0.fieldName == "input" }).id
            for index in 0..<ownSaves {
                try await pages.pdfSetWidgetValue(page: 0, id: field, value: "Saved \(index)")
                try await pages.pdfSave(to: source)
            }
            try await pages.pdfSetWidgetValue(page: 0, id: field, value: "Keep local field")
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Keep local edit")])
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Future edit")])
            try await pages.pdfUndo()
            let before = try await pages.pdfInfo(), annotations = try await pages.pdfAnnotations(0)
            let version = try XCTUnwrap(NativeFile.FileVersion(source))
            var replacement = try Data(contentsOf: source)
            let text = try XCTUnwrap(replacement.range(of: Data("OLD".utf8)))
            replacement.replaceSubrange(text, with: Data("NEW".utf8))
            let writer = try FileHandle(forWritingTo: source)
            try writer.write(contentsOf: replacement); try writer.close()
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                         timespec(tv_sec: version.modifiedSeconds, tv_nsec: version.modifiedNanoseconds)]
            XCTAssertEqual(source.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }, 0)
            let changed = try XCTUnwrap(NativeFile.FileVersion(source))
            XCTAssertNotEqual(changed, version)
            XCTAssertTrue(version.matchesContentMetadata(changed))
            do { try await pages.pdfSave(to: source); XCTFail("Changed bytes must not be overwritten") }
            catch {}
            XCTAssertEqual(try Data(contentsOf: source), replacement)
            let after = try await pages.pdfInfo(), retained = try await pages.pdfAnnotations(0)
            XCTAssertEqual(after?.dirty, true)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps)
            XCTAssertEqual(after?.redoTitle, before?.redoTitle)
            XCTAssertEqual(retained.map(\.contents), annotations.map(\.contents))
            XCTAssertEqual(retained.map(\.value), annotations.map(\.value))
            try await pages.pdfSaveCopy(to: copy)
            let recovered = try NativeFile(copy, engine: .mupdf)
            XCTAssertEqual(try recovered.text(0)?.trimmingCharacters(in: .whitespacesAndNewlines), "OLD")
            XCTAssertEqual(try recovered.pdfAnnotations(0).first { $0.id == field }?.value, "Keep local field")
            XCTAssertEqual(try recovered.pdfAnnotations(0).first { $0.id == annotation }?.contents, "Keep local edit")
            try await pages.pdfUndo(redo: true)
            let redone = try await pages.pdfAnnotations(0)
            XCTAssertEqual(redone.first { $0.id == annotation }?.contents, "Future edit")
            XCTAssertEqual(try Data(contentsOf: source), replacement)
        }
    }

    func testOrdinarySaveRejectsExternalChangesAndPreservesCopyRecoveryAfterOwnSaves() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), files = FileManager.default
        defer { withExtendedLifetime(directory) {} }
        for (name, ownSaves, inPlace, sameLength) in [
            ("first-replacement", 0, false, false), ("replacement-after-save", 2, false, false),
            ("same-length-after-save", 2, true, true), ("changed-length-after-save", 2, true, false)
        ] {
            let source = directory.url.appendingPathComponent(name + ".pdf")
            let copy = directory.url.appendingPathComponent(name + "-copy.pdf")
            try readOnlyFixture(firstPageText: "OLD", padding: 10_000, withForm: true).write(to: source)
            let pages = try Pages(source, format: .pdf)
            try await pages.pdfSetEditing(true)
            let annotation = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
                bounds: CGRect(x: 10, y: 20, width: 40, height: 30), edits: [.contents("Initial local edit")])
            let fields = try await pages.pdfAnnotations(0)
            let field = try XCTUnwrap(fields.first { $0.fieldName == "input" }).id
            for index in 0..<ownSaves {
                try await pages.pdfSetWidgetValue(page: 0, id: field, value: "Saved \(index)")
                try await pages.pdfSave(to: source)
                let info = try await pages.pdfInfo()
                XCTAssertEqual(info?.dirty, false, name)
                let saved = try NativeFile(source, engine: .mupdf)
                XCTAssertEqual(try saved.pdfAnnotations(0).first { $0.id == field }?.value, "Saved \(index)")
            }
            try await pages.pdfSetWidgetValue(page: 0, id: field, value: "Unsaved field value")
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Keep local edit")])
            try await pages.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Future edit")])
            try await pages.pdfUndo()
            let before = try await pages.pdfInfo(), annotations = try await pages.pdfAnnotations(0)
            var replacement = readOnlyFixture(firstPageText: "EXTERNAL NEW", padding: sameLength ? 0 : 20_000, withForm: true)
            if sameLength {
                let length = try Data(contentsOf: source).count
                XCTAssertLessThan(replacement.count, length)
                replacement.append(Data(repeating: 32, count: length - replacement.count))
            }
            let originalInode = try files.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
            if inPlace {
                let writer = try FileHandle(forWritingTo: source)
                try writer.truncate(atOffset: 0); try writer.write(contentsOf: replacement); try writer.close()
                try files.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: source.path)
                XCTAssertEqual(try files.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber, originalInode)
            } else { try replacement.write(to: source, options: .atomic) }

            do { try await pages.pdfSave(to: source); XCTFail("Ordinary Save must retain the external file: " + name) }
            catch {}
            XCTAssertEqual(try Data(contentsOf: source), replacement, name)
            let after = try await pages.pdfInfo(), retained = try await pages.pdfAnnotations(0)
            XCTAssertEqual(after?.dirty, true, name)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition, name)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps, name)
            XCTAssertEqual(after?.undoTitle, before?.undoTitle, name)
            XCTAssertEqual(after?.redoTitle, before?.redoTitle, name)
            XCTAssertEqual(retained.map(\.id), annotations.map(\.id), name)
            XCTAssertEqual(retained.map(\.contents), annotations.map(\.contents), name)
            XCTAssertEqual(retained.map(\.value), annotations.map(\.value), name)

            try await pages.pdfSaveCopy(to: copy)
            XCTAssertEqual(try Data(contentsOf: source), replacement, name)
            let recovered = try NativeFile(copy, engine: .mupdf)
            XCTAssertEqual(try recovered.text(0)?.trimmingCharacters(in: .whitespacesAndNewlines), "OLD")
            let copied = try recovered.pdfAnnotations(0)
            XCTAssertEqual(copied.first { $0.id == field }?.value, "Unsaved field value")
            XCTAssertEqual(copied.first { $0.id == annotation }?.contents, "Keep local edit")
            let copiedInfo = try await pages.pdfInfo()
            XCTAssertEqual(copiedInfo?.dirty, true, name)
            XCTAssertEqual(copiedInfo?.undoPosition, before?.undoPosition, name)
            XCTAssertEqual(copiedInfo?.undoSteps, before?.undoSteps, name)
            try await pages.pdfUndo(redo: true)
            let redone = try await pages.pdfAnnotations(0)
            XCTAssertEqual(redone.first { $0.id == annotation }?.contents, "Future edit", name)
            try await pages.pdfUndo()
            let undone = try await pages.pdfAnnotations(0)
            XCTAssertEqual(undone.first { $0.id == annotation }?.contents, "Keep local edit", name)
            XCTAssertEqual(try Data(contentsOf: source), replacement, name)
        }
    }

    func testInPlaceSourceChangesKeepImmutablePagesAndCopiesWhileOrdinarySaveRefuses() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for (index, replacementText) in ["NEW", "NEW WITH CHANGED LENGTH AND XREF OFFSETS"].enumerated() {
            let source = directory.url.appendingPathComponent("source-\(index).pdf")
            let output = directory.url.appendingPathComponent("existing-\(index).pdf")
            let original = readOnlyFixture(firstPageText: "OLD", padding: 10_000)
            let replacement = readOnlyFixture(firstPageText: replacementText, padding: 10_000)
            try original.write(to: source)
            let pages = try Pages(source, format: .pdf)
            try await pages.pdfSetEditing(true)
            _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 40, height: 30),
                edits: [.contents("Keep the local edit")])
            let before = try await pages.pdfInfo(), sentinel = Data("Keep existing output".utf8)
            try sentinel.write(to: output)
            let writer = try FileHandle(forWritingTo: source)
            try writer.truncate(atOffset: 0); try writer.write(contentsOf: replacement); try writer.close()
            // Make the equal-length case deterministic on filesystems whose
            // timestamps cannot distinguish two writes in the same clock tick.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: source.path)

            let retainedText = try await pages.text(0)
            XCTAssertEqual(retainedText.trimmingCharacters(in: .whitespacesAndNewlines), "OLD")
            try await pages.pdfSaveCopy(to: output)
            let recovered = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(try recovered.text(0)?.trimmingCharacters(in: .whitespacesAndNewlines), "OLD")
            XCTAssertTrue(try recovered.pdfAnnotations(0).contains { $0.contents == "Keep the local edit" })
            let copiedBytes = try Data(contentsOf: output)
            do { try await pages.pdfSave(to: source); XCTFail("Ordinary Save must preserve the external version") }
            catch { XCTAssertTrue(error.localizedDescription.contains("changed outside Sumra")) }
            do {
                try await pages.pdfSignCopy(to: output, password: "",
                    identity: .pkcs12(directory.url.appendingPathComponent("missing.p12"), password: ""),
                    fieldName: "Approval", page: 0, bounds: .zero)
                XCTFail("A missing signing identity must fail without changing output or the live journal")
            } catch { XCTAssertFalse(error.localizedDescription.contains("modified outside Sumra"), error.localizedDescription) }
            XCTAssertEqual(try Data(contentsOf: source), replacement)
            XCTAssertEqual(try Data(contentsOf: output), copiedBytes)
            let after = try await pages.pdfInfo(), annotations = try await pages.pdfAnnotations(0)
            XCTAssertEqual(after?.dirty, true)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps)
            XCTAssertTrue(annotations.contains { $0.contents == "Keep the local edit" })
        }
    }

    func testSaveCopyRetainsTheOpenedPDFAndEditsAfterReplacementOrUnlink() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), files = FileManager.default
        defer { withExtendedLifetime(directory) {} }
        for replace in [true, false] {
            let source = directory.url.appendingPathComponent(replace ? "replaced.pdf" : "unlinked.pdf")
            let output = directory.url.appendingPathComponent(replace ? "replaced-copy.pdf" : "unlinked-copy.pdf")
            try readOnlyFixture(firstPageText: "OLD", padding: 10_000).write(to: source)
            let pages = try Pages(source, format: .pdf)
            try await pages.pdfSetEditing(true)
            _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 40, height: 30),
                edits: [.contents("Recovered local edit")])
            let before = try await pages.pdfInfo()
            let replacement = readOnlyFixture(firstPageText: "NEW WITH CHANGED LENGTH AND XREF OFFSETS", padding: 10_000)
            if replace { try replacement.write(to: source, options: .atomic) }
            else { try files.removeItem(at: source) }

            try await pages.pdfSaveCopy(to: output)

            let recovered = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(try recovered.text(0)?.trimmingCharacters(in: .whitespacesAndNewlines), "OLD")
            XCTAssertTrue(try recovered.pdfAnnotations(0).contains { $0.contents == "Recovered local edit" })
            let after = try await pages.pdfInfo()
            XCTAssertEqual(after?.dirty, true)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps)
            if replace { XCTAssertEqual(try Data(contentsOf: source), replacement) }
            else { XCTAssertFalse(files.fileExists(atPath: source.path)) }
        }
    }

    func testOrdinarySaveThroughSymlinkUpdatesEncryptedTargetAndKeepsAlias() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), files = FileManager.default
        let targetDirectory = directory.url.appendingPathComponent("target", isDirectory: true)
        let aliasDirectory = directory.url.appendingPathComponent("aliases", isDirectory: true)
        try files.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try files.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        let plain = directory.url.appendingPathComponent("plain.pdf")
        let source = targetDirectory.appendingPathComponent("source.pdf"), alias = aliasDirectory.appendingPathComponent("opened.pdf")
        try fixture(sizes: [100]).write(to: plain)
        try NativePDFTools.encrypt(source: plain, destination: source, ownerPassword: "owner", userPassword: "reader", permissions: 16)
        try files.createSymbolicLink(atPath: alias.path, withDestinationPath: "../target/source.pdf")
        let original = try Data(contentsOf: source), permissions = try storedPermissions(source, password: "reader")
        let pages = try Pages(alias, format: .pdf, password: "owner")
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 40, height: 30),
            edits: [.contents("Saved through alias")])
        do { try await pages.pdfSaveCopy(to: source); XCTFail("Save a Copy must protect the target of the opened alias") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        let unsaved = try await pages.pdfInfo()
        XCTAssertEqual(unsaved?.dirty, true)

        try await pages.pdfSave(to: alias)

        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: alias.path), "../target/source.pdf")
        XCTAssertNotEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: alias), try Data(contentsOf: source))
        let reopened = try NativeFile(source, engine: .mupdf, password: "owner")
        XCTAssertEqual(try reopened.pdfAnnotations(0).first?.contents, "Saved through alias")
        let protected = try XCTUnwrap(CGPDFDocument(alias as CFURL))
        XCTAssertTrue(protected.isEncrypted)
        XCTAssertTrue(protected.unlockWithPassword("reader"))
        XCTAssertEqual(try storedPermissions(source, password: "reader"), permissions)
        let saved = try await pages.pdfInfo()
        XCTAssertEqual(saved?.dirty, false)
        XCTAssertTrue(try files.contentsOfDirectory(atPath: targetDirectory.path).allSatisfy { !$0.hasPrefix(".Sumra-save-") })
        XCTAssertTrue(try files.contentsOfDirectory(atPath: aliasDirectory.path).allSatisfy { !$0.hasPrefix(".Sumra-save-") })
        withExtendedLifetime(directory) {}
    }

    func testRewriteToolsUseUnsavedAnnotationsWithoutChangingTheLiveJournal() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.pdf")
        try fixture(sizes: [100]).write(to: source)
        let original = try Data(contentsOf: source), pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "FreeText", bounds: CGRect(x: 10, y: 20, width: 80, height: 30),
            edits: [.contents("Unsaved text")])
        let before = try await pages.pdfInfo(), snapshot = directory.url.appendingPathComponent("current.pdf")
        try await pages.pdfSaveCopy(to: snapshot)
        for operation in [PDFAdvancedOperation.compress, .decompress, .flatten, .bake] {
            let output = directory.url.appendingPathComponent(operation.rawValue + ".pdf")
            try NativePDFOutput.write(snapshot: snapshot, password: "", operation: .transform(operation), to: output,
                originalSources: [source])
            let result = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(result.count, 1)
            if operation == .flatten || operation == .bake {
                XCTAssertTrue(try result.pdfAnnotations(0).isEmpty)
                XCTAssertTrue(try result.text(0)?.contains("Unsaved text") == true, "Baking must retain the current annotation's visible content")
            } else { XCTAssertEqual(try result.pdfAnnotations(0).first?.contents, "Unsaved text") }
        }
        let after = try await pages.pdfInfo(), annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(after?.undoPosition, before?.undoPosition)
        XCTAssertEqual(after?.undoSteps, before?.undoSteps)
        XCTAssertEqual(after?.dirty, true)
        XCTAssertEqual(annotations.first?.contents, "Unsaved text")
        XCTAssertEqual(try Data(contentsOf: source), original)
        withExtendedLifetime(directory) {}
    }

    func testPasswordToolsRequireTheOwnerAndKeepPermissionsOnEncryptedOutput() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), plain = directory.url.appendingPathComponent("plain.pdf")
        let source = directory.url.appendingPathComponent("source.pdf"), output = directory.url.appendingPathComponent("encrypted.pdf")
        try fixture(sizes: [100]).write(to: plain)
        try NativePDFTools.encrypt(source: plain, destination: source, ownerPassword: "owner", userPassword: "reader", permissions: 16)
        let original = try Data(contentsOf: source), pages = try Pages(source, format: .pdf, password: "reader")
        let snapshot = directory.url.appendingPathComponent("current.pdf")
        try await pages.pdfSaveCopy(to: snapshot)
        let sentinel = Data("Keep existing output on failure".utf8)
        try sentinel.write(to: output)
        XCTAssertThrowsError(try NativePDFOutput.write(snapshot: snapshot, password: "reader", operation: .decrypt,
            to: output, originalSources: [source]))
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        for password in ["reader", "incorrect"] {
            XCTAssertThrowsError(try NativePDFOutput.write(snapshot: snapshot, password: password, operation: .encrypt(owner: "new owner", user: "new reader"),
                to: output, originalSources: [source]))
            XCTAssertEqual(try Data(contentsOf: output), sentinel)
        }
        try NativePDFOutput.write(snapshot: snapshot, password: "owner", operation: .encrypt(owner: "new owner", user: "new reader"),
            to: output, originalSources: [source])
        let protected = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertTrue(protected.isEncrypted)
        XCTAssertTrue(protected.unlockWithPassword("new reader"))
        XCTAssertEqual(try storedPermissions(output, password: "new reader"), try storedPermissions(source, password: "reader"))
        XCTAssertEqual(try storedPermissions(output, password: "new reader"), -3888)
        let decrypted = directory.url.appendingPathComponent("decrypted.pdf")
        try NativePDFOutput.write(snapshot: output, password: "new owner", operation: .decrypt,
            to: decrypted, originalSources: [source, output])
        XCTAssertFalse(try XCTUnwrap(CGPDFDocument(decrypted as CFURL)).isEncrypted)
        XCTAssertEqual(try Data(contentsOf: source), original)
        withExtendedLifetime(directory) {}
    }

    func testRedactionOutputAppliesCurrentMarksWithoutApplyingThemToTheOpenDocument() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.pdf")
        try fixture(sizes: [100]).write(to: source)
        let original = try Data(contentsOf: source), pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Redact", bounds: CGRect(x: 2, y: 2, width: 18, height: 18))
        let before = try await pages.pdfInfo(), snapshot = directory.url.appendingPathComponent("current.pdf")
        let output = directory.url.appendingPathComponent("redacted.pdf")
        try await pages.pdfSaveCopy(to: snapshot)
        try NativePDFOutput.write(snapshot: snapshot, password: "", operation: .transform(.redact), to: output,
            originalSources: [source])
        XCTAssertFalse(try NativeFile(output, engine: .mupdf).pdfAnnotations(0).contains { $0.type == "Redact" })
        let after = try await pages.pdfInfo(), annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(after?.undoPosition, before?.undoPosition)
        XCTAssertEqual(after?.dirty, true)
        XCTAssertTrue(annotations.contains { $0.type == "Redact" })
        XCTAssertEqual(try Data(contentsOf: source), original)
        withExtendedLifetime(directory) {}
    }

    func testDeleteUsesTheComplementOfTheCurrentUnsavedDocument() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.pdf")
        try fixture(sizes: [100, 200, 300]).write(to: source)
        let original = try Data(contentsOf: source), pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        let annotation = try await pages.pdfCreateAnnotation(page: 2, type: "Square", bounds: CGRect(x: 20, y: 20, width: 40, height: 40),
            edits: [.contents("Unsaved annotation")])
        let before = try await pages.pdfInfo()
        let snapshot = directory.url.appendingPathComponent("current.pdf"), output = directory.url.appendingPathComponent("deleted.pdf")
        try await pages.pdfSaveCopy(to: snapshot)
        try NativePDFOutput.write(snapshot: snapshot, password: "", operation: .delete([1, 1], count: 3), to: output,
            originalSources: [source])
        let result = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(try result.bounds(0)?.width, 100)
        XCTAssertEqual(try result.bounds(1)?.width, 300)
        XCTAssertEqual(try result.pdfAnnotations(1).first?.contents, "Unsaved annotation")
        let after = try await pages.pdfInfo(), annotations = try await pages.pdfAnnotations(2)
        XCTAssertEqual(after?.undoPosition, before?.undoPosition)
        XCTAssertEqual(after?.undoSteps, before?.undoSteps)
        XCTAssertEqual(after?.dirty, true)
        XCTAssertEqual(annotations.first?.id, annotation)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let saved = try Data(contentsOf: output)
        XCTAssertThrowsError(try NativePDFOutput.write(snapshot: snapshot, password: "", operation: .delete([0, 1, 2], count: 3),
            to: output, originalSources: [source]))
        XCTAssertEqual(try Data(contentsOf: output), saved)
        withExtendedLifetime(directory) {}
    }

    func testExtractProtectsTheActualOriginalAndRetainsEncryption() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), plain = directory.url.appendingPathComponent("plain.pdf")
        let source = directory.url.appendingPathComponent("protected.pdf"), alias = directory.url.appendingPathComponent("alias.pdf")
        try fixture(sizes: [100, 200]).write(to: plain)
        try NativePDFTools.encrypt(source: plain, destination: source, ownerPassword: "owner", userPassword: "reader", permissions: 255)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let original = try Data(contentsOf: source), pages = try Pages(source, format: .pdf, password: "reader")
        let snapshot = directory.url.appendingPathComponent("current.pdf"), output = directory.url.appendingPathComponent("extracted.pdf")
        try await pages.pdfSaveCopy(to: snapshot)
        XCTAssertThrowsError(try NativePDFOutput.write(snapshot: snapshot, password: "reader", operation: .extract([1], annotationsOnly: false),
            to: alias, originalSources: [source]))
        XCTAssertEqual(try Data(contentsOf: source), original)
        try NativePDFOutput.write(snapshot: snapshot, password: "reader", operation: .extract([1], annotationsOnly: false),
            to: output, originalSources: [source])
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertTrue(pdf.isEncrypted)
        XCTAssertFalse(pdf.isUnlocked)
        XCTAssertTrue(pdf.unlockWithPassword("reader"))
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(try storedPermissions(output, password: "reader"), try storedPermissions(source, password: "reader"))
        withExtendedLifetime(directory) {}
    }

    func testMergeUsesCurrentPagesAndProducesTheUpstreamUnencryptedCopy() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), plain = directory.url.appendingPathComponent("plain.pdf")
        let source = directory.url.appendingPathComponent("protected.pdf"), other = directory.url.appendingPathComponent("other.pdf")
        try fixture(sizes: [100, 200]).write(to: plain)
        try fixture(sizes: [300]).write(to: other)
        try NativePDFTools.encrypt(source: plain, destination: source, ownerPassword: "owner", userPassword: "reader", permissions: 255)
        let pages = try Pages(source, format: .pdf, password: "owner")
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 20, y: 20, width: 40, height: 40),
            edits: [.contents("Not grafted by pdfmerge")])
        let before = try await pages.pdfInfo(), original = try Data(contentsOf: source)
        let snapshot = directory.url.appendingPathComponent("current.pdf"), output = directory.url.appendingPathComponent("merged.pdf")
        try await pages.pdfSaveCopy(to: snapshot)
        try NativePDFOutput.write(snapshot: snapshot, password: "owner", operation: .merge([(other, "")]), to: output,
            originalSources: [source, other])
        let result = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(try result.bounds(2)?.width, 300)
        XCTAssertTrue(try result.pdfAnnotations(0).isEmpty, "The upstream merge policy does not preserve annotations")
        XCTAssertFalse(try XCTUnwrap(CGPDFDocument(output as CFURL)).isEncrypted)
        let after = try await pages.pdfInfo()
        XCTAssertEqual(after?.undoPosition, before?.undoPosition)
        XCTAssertEqual(after?.dirty, true)
        XCTAssertEqual(try Data(contentsOf: source), original)
        withExtendedLifetime(directory) {}
    }

    func testTextOutlineAndXMPExportsReadTheLiveDocumentWithoutChangingIt() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("read-only.pdf")
        let bytes = readOnlyFixture()
        try bytes.write(to: source)
        let pages = try Pages(source, format: .pdf), output = directory.url.appendingPathComponent("text.txt")
        try await pages.pdfExportText([1, 0], to: output)
        let text = try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\n\u{000C}\n")
        XCTAssertEqual(text.count, 2)
        XCTAssertEqual(text[0].trimmingCharacters(in: .whitespacesAndNewlines), "Second")
        XCTAssertEqual(text[1].trimmingCharacters(in: .whitespacesAndNewlines), "First")
        let outline = try await pages.pdfOutline(), xmp = try await pages.pdfXMP()
        XCTAssertEqual(outline.map(\.title), ["First", "Nested", "Website", "Remote"])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 0, 0])
        XCTAssertEqual(outline[0].page, 0); XCTAssertEqual(outline[1].page, 1)
        XCTAssertEqual(outline[0].x, 12); XCTAssertEqual(outline[0].y, 72)
        XCTAssertEqual(outline[0].zoom, 1.5)
        XCTAssertEqual(outline[2].url, "https://example.com/")
        XCTAssertEqual(outline[3].page, 2); XCTAssertEqual(outline[3].x, 5); XCTAssertEqual(outline[3].y, 66)
        XCTAssertEqual(outline[3].zoom, 2)
        XCTAssertEqual(outline[3].url, directory.url.appendingPathComponent("remote.pdf").absoluteString)
        XCTAssertEqual(xmp, Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8))
        let state = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(state).dirty)
        XCTAssertEqual(state?.undoPosition, 0)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let saved = try Data(contentsOf: output)
        do { try await pages.pdfExportText([0, 2], to: output); XCTFail("Invalid selections must not replace existing output") }
        catch { XCTAssertEqual(try Data(contentsOf: output), saved) }
        let alias = directory.url.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        do { try await pages.pdfExportText([0], to: alias); XCTFail("Export must not overwrite the original through an alias") }
        catch { XCTAssertEqual(try Data(contentsOf: source), bytes) }
        withExtendedLifetime(directory) {}
    }

    func testOutlineExportKeepsPDFCoordinatesForNamedDestinationsOnRotatedCroppedPages() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("rotated.pdf")
        try readOnlyFixture(rotatedNamedDestination: true).write(to: source)
        let pages = try Pages(source, format: .pdf), outline = try await pages.pdfOutline()
        XCTAssertEqual(outline[0].page, 0)
        XCTAssertEqual(outline[0].x, 12); XCTAssertEqual(outline[0].y, 72); XCTAssertEqual(outline[0].zoom, 1.5)
        let info = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(info).dirty)
        withExtendedLifetime(directory) {}
    }

    func testImageExportIncludesUnsavedAnnotationsAndRestoresHiddenDisplay() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.pdf")
        let bytes = try fixture(sizes: [100]); try bytes.write(to: source)
        let pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 20, y: 20, width: 50, height: 50),
            edits: [.color(SIMD3(1, 0, 0), interior: true)])
        try await pages.pdfSetAnnotationsVisible(false)
        let before = try await pages.pdfInfo()
        let data = try await pages.pdfRenderedImage(page: 0, dpi: 144, type: .png, rotation: 0)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 200)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0, 144, accuracy: 0.1)
        XCTAssertGreaterThan(redPixels(image), 8_000, "The exported page must include the current unsaved annotation")
        let hidden = try await pages.image(0, width: 201)
        XCTAssertEqual(redPixels(hidden), 0, "Export must restore the display's hidden-annotation state, including its next render")
        let after = try await pages.pdfInfo()
        XCTAssertEqual(after?.undoPosition, before?.undoPosition); XCTAssertEqual(after?.undoSteps, before?.undoSteps)
        XCTAssertEqual(after?.dirty, true)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        withExtendedLifetime(directory) {}
    }

    func testImageExportPreservesRequestedPixelsBeyondTheDisplayWidthLimit() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("wide.pdf")
        let bytes = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 1000, height: 1)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        try (bytes as Data).write(to: source)
        let pages = try Pages(source, format: .pdf)
        let data = try await pages.pdfRenderedImage(page: 0, dpi: 1224, type: .png, rotation: 90)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 17); XCTAssertEqual(image.height, 17_000)
        do { _ = try await pages.pdfRenderedImage(page: 0, dpi: .infinity, type: .png, rotation: 0); XCTFail("Invalid DPI must fail") }
        catch {}
        withExtendedLifetime(directory) {}
    }

    func testReadOnlyExportsHonorCopyPermissionWithoutReplacingOutput() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory(), plain = directory.url.appendingPathComponent("plain.pdf")
        let source = directory.url.appendingPathComponent("protected.pdf"), output = directory.url.appendingPathComponent("existing.txt")
        try readOnlyFixture().write(to: plain)
        try NativePDFTools.encrypt(source: plain, destination: source, ownerPassword: "owner", userPassword: "reader", permissions: 4)
        let pages = try Pages(source, format: .pdf, password: "reader"), sentinel = Data("Existing output".utf8)
        try sentinel.write(to: output)
        do { try await pages.pdfExportText([0], to: output); XCTFail("Restricted text extraction must fail") }
        catch { XCTAssertEqual(try Data(contentsOf: output), sentinel) }
        do { _ = try await pages.pdfRenderedImage(page: 0, dpi: 72, type: .png, rotation: 0); XCTFail("Restricted image extraction must fail") }
        catch {}
        withExtendedLifetime(directory) {}
    }

    private func redPixels(_ image: CGImage) -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 200 && bytes[$0 + 1] < 50 && bytes[$0 + 2] < 50 }.count
        }
    }

    private func readOnlyFixture(rotatedNamedDestination: Bool = false, firstPageText: String = "First", padding: Int = 0, withForm: Bool = false,
                                 secondPageText: String = "Second", secondPagePadding: Int = 0) -> Data {
        func stream(_ value: String, dictionary: String = "") -> String { "<< /Length \(value.utf8.count) \(dictionary) >>\nstream\n" + value + "\nendstream" }
        let names = rotatedNamedDestination ? "/Names << /Dests << /Names [(chapter) [3 0 R /XYZ 12 72 1.5]] >> >>" : ""
        let pageBox = rotatedNamedDestination ? "/MediaBox [10 20 130 180] /CropBox [15 30 120 150] /Rotate 90" : "/MediaBox [0 0 100 100]"
        let destination = rotatedNamedDestination ? "(chapter)" : "[3 0 R /XYZ 12 72 1.5]"
        let form = withForm ? "/AcroForm << /Fields [14 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >>" : ""
        let annotations = withForm ? "/Annots [14 0 R]" : ""
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 8 0 R /Metadata 12 0 R \(names) \(form) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R \(pageBox) /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R \(annotations) >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream(String(repeating: " ", count: padding) + "BT /F1 12 Tf 10 50 Td (\(firstPageText)) Tj ET"),
            stream(String(repeating: " ", count: secondPagePadding) + "BT /F1 12 Tf 10 50 Td (\(secondPageText)) Tj ET"),
            "<< /Type /Outlines /First 9 0 R /Last 13 0 R /Count 4 >>",
            "<< /Title (First) /Parent 8 0 R /Dest \(destination) /First 10 0 R /Last 10 0 R /Count 1 /Next 11 0 R >>",
            "<< /Title (Nested) /Parent 9 0 R /Dest [4 0 R /Fit] >>",
            "<< /Title (Website) /Parent 8 0 R /Prev 9 0 R /Next 13 0 R /A << /S /URI /URI (https://example.com/) >> >>",
            stream(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#, dictionary: "/Type /Metadata /Subtype /XML"),
            "<< /Title (Remote) /Parent 8 0 R /Prev 11 0 R /A << /S /GoToR /F (remote.pdf) /D [2 /XYZ 5 66 2] >> >>"
        ]
        if withForm { objects.append("<< /Type /Annot /Subtype /Widget /FT /Tx /T (input) /V (Initial) /Rect [10 10 80 30] /P 3 0 R >>") }
        var result = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(result.count); result.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = result.count
        result.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }

    private func storedPermissions(_ source: URL, password: String) throws -> Int32 {
        let pdf = try XCTUnwrap(CGPDFDocument(source as CFURL))
        XCTAssertTrue(pdf.isEncrypted)
        XCTAssertTrue(pdf.unlockWithPassword(password))
        // Scope this plaintext Encrypt dictionary inspection to the generated
        // AES-256 fixtures; CoreGraphics normalizes effective access flags.
        let bytes = try Data(contentsOf: source)
        let text = String(decoding: bytes.map { UInt16($0) }, as: UTF16.self) as NSString
        let expression = try NSRegularExpression(pattern: #"/Filter\s*/Standard\b[^<>]*?/P\s+(-?\d+)\b"#)
        let match = try XCTUnwrap(expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)).last)
        return try XCTUnwrap(Int32(text.substring(with: match.range(at: 1))))
    }

    private func requireMuPDF() throws {
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("MuPDF engine is required") }
    }

    private func fixture(sizes: [CGFloat]) throws -> Data {
        let bytes = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: nil, nil))
        for size in sizes {
            var box = CGRect(x: 0, y: 0, width: size, height: size)
            let data = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }
}
#endif
