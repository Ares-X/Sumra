#if os(macOS)
import AppKit
import Darwin
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class PDFReloadTests: XCTestCase {
    private func pdf(_ contents: String, padding: Int = 0) -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 30 40 50] /Contents (\(contents)) >>"
        ]
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        if padding > 0 {
            data.append(0x25)
            data.append(Data(repeating: 0x20, count: padding))
            data.append(0x0a)
        }
        let xref = data.count
        data.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func requireMuPDF() throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("Build MuPDF before reload tests")
        }
    }

    // Finder locking forces PDFSource's real streaming-copy path. Observe the
    // writable private snapshot descriptor, then replace the source while that
    // copy is active. This exercises the version boundary without a product hook.
    private func replaceDuringCapture(_ source: URL, with replacement: Data) -> Task<Void, Error> {
        Task.detached {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                try Task.checkCancellation()
                for descriptor: Int32 in 0..<1024 where fcntl(descriptor, F_GETFL) & O_ACCMODE == O_WRONLY {
                    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    guard fcntl(descriptor, F_GETPATH, &path) == 0,
                          String(cString: path).hasSuffix("/input.pdf") else { continue }
                    guard chflags(source.path, 0) == 0 else { throw POSIXError(.EIO) }
                    try replacement.write(to: source, options: .atomic)
                    return
                }
                usleep(100)
            }
            throw ReadError("Did not observe the PDF snapshot copy")
        }
    }

    private func prepareCapture(_ url: URL) throws {
        try pdf("being compiled", padding: 64 * 1_048_576).write(to: url, options: .atomic)
        XCTAssertEqual(chflags(url.path, UInt32(UF_IMMUTABLE)), 0)
    }

    @MainActor
    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for PDF reload")
    }

    @MainActor
    func testAtomicReplacementDuringReloadRecoversLatestPDFAndKeepsOldDocument() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("compiled.pdf")
        try pdf("original").write(to: url)
        let state = ReaderState(recordsHistory: false)
        defer { _ = chflags(url.path, 0); state.windowClosed(); withExtendedLifetime(directory) {} }
        state.openWithoutHistory(url)
        try await wait { !state.busy }
        let original = try XCTUnwrap(state.document)
        state.location = ReadingPosition(page: 0, x: 9, y: 35)
        state.zoom = 1.5
        state.fit = "custom"
        state.recordNavigation()
        let position = state.currentPosition
        try prepareCapture(url)
        let replacement = replaceDuringCapture(url, with: pdf("final compiler output"))
        defer { replacement.cancel() }
        state.reload()
        try await replacement.value
        try await wait { !state.busy }
        XCTAssertNil(state.error, "A source change during capture should wait for the next compiler output")
        XCTAssertEqual(state.document?.id, original.id, "Keep the old PDF readable during debounce")
        XCTAssertEqual(state.currentPosition, position)
        try await wait { state.document?.id != original.id && !state.busy }
        guard case .pages(let pages) = state.document?.content else { return XCTFail("Expected native PDF") }
        let annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.first?.contents, "final compiler output")
        XCTAssertEqual(state.currentPosition, position)
        XCTAssertFalse(state.recordsDocumentHistory)
        XCTAssertNil(state.error)
    }

    func testSnapshotReportsTypedSourceChangeDuringAtomicReplacement() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("capturing.pdf")
        defer { _ = chflags(url.path, 0); withExtendedLifetime(directory) {} }
        try prepareCapture(url)
        let replacement = replaceDuringCapture(url, with: pdf("new source"))
        defer { replacement.cancel() }
        do {
            _ = try await Task.detached { try NativeFile.PDFSource(url) }.value
            XCTFail("A replacement during copying must reject the superseded source")
        } catch { XCTAssertTrue(error is NativeFile.PDFSourceChanged, "Unexpected error: \(error)") }
        try await replacement.value
        let final = try NativeFile.PDFSource(url)
        XCTAssertEqual(try Data(contentsOf: final.url), pdf("new source"))
    }

    @MainActor
    func testInitialOpeningPreservesExplicitPositionAndHistoryAcrossRepeatedReplacements() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("initial.pdf")
        let state = ReaderState(recordsHistory: true)
        defer { _ = chflags(url.path, 0); state.windowClosed(); withExtendedLifetime(directory) {} }
        let position = ReadingPosition(page: 0, x: 11, y: 37, zoom: 1.75, fit: "custom", pdfCoordinateSpace: "fitz")
        try prepareCapture(url)
        let first = replaceDuringCapture(url, with: pdf("intermediate output"))
        defer { first.cancel() }
        state.openWithoutHistory(url, at: position)
        try await first.value
        try await wait { !state.busy }
        XCTAssertNil(state.document)
        XCTAssertNil(state.error)
        let firstGeneration = state.generation

        try prepareCapture(url)
        let second = replaceDuringCapture(url, with: pdf("final output"))
        defer { second.cancel() }
        try await second.value
        try await wait { !state.busy && state.generation > firstGeneration }
        XCTAssertNil(state.document)
        XCTAssertNil(state.error)
        try await wait { state.document != nil && !state.busy }
        guard case .pages(let pages) = state.document?.content else { return XCTFail("Expected PDF") }
        let annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.first?.contents, "final output")
        XCTAssertEqual(state.currentPosition.x, position.x)
        XCTAssertEqual(state.currentPosition.y, position.y)
        XCTAssertEqual(state.zoom, position.zoom)
        XCTAssertFalse(state.recordsDocumentHistory)
    }

    @MainActor
    func testDelayedRetryCannotResurrectAClosedDocumentOrReplaceANewOpening() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for openAnother in [false, true] {
            let url = directory.url.appendingPathComponent(openAnother ? "new-opening.pdf" : "closing.pdf")
            let other = directory.url.appendingPathComponent("other.txt")
            try Data("A different document".utf8).write(to: other)
            let state = ReaderState(recordsHistory: false)
            defer { _ = chflags(url.path, 0); state.windowClosed() }
            try prepareCapture(url)
            let replacement = replaceDuringCapture(url, with: pdf("compiled output"))
            defer { replacement.cancel() }
            state.openWithoutHistory(url)
            try await replacement.value
            try await wait { !state.busy }
            XCTAssertNil(state.error)
            if openAnother {
                state.openWithoutHistory(other)
                try await wait { state.document?.url == other && !state.busy }
            } else { state.windowClosed() }
            let generation = state.generation
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(state.generation, generation)
            XCTAssertEqual(state.document?.url, openAnother ? other : nil)
            XCTAssertNil(state.error)
        }
    }

    @MainActor
    func testDeletionDuringDebounceKeepsTheDisplayedPDFAndReportsMissingFile() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("deleted.pdf")
        try pdf("displayed").write(to: url)
        let state = ReaderState(recordsHistory: false)
        defer { _ = chflags(url.path, 0); state.windowClosed(); withExtendedLifetime(directory) {} }
        state.openWithoutHistory(url)
        try await wait { !state.busy }
        let original = state.document?.id
        try prepareCapture(url)
        let replacement = replaceDuringCapture(url, with: pdf("output before deletion"))
        defer { replacement.cancel() }
        state.reload()
        try await replacement.value
        try await wait { !state.busy }
        try FileManager.default.removeItem(at: url)
        try await wait { state.missingFile != nil }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(state.document?.id, original)
        XCTAssertEqual(state.missingFile, url)
        XCTAssertFalse(state.busy)
    }

    @MainActor
    func testEditsMadeWhileWaitingPreventAutomaticReplacement() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("edited.pdf")
        try pdf("displayed").write(to: url)
        let state = ReaderState(recordsHistory: false)
        defer { _ = chflags(url.path, 0); state.modified = false; state.windowClosed(); withExtendedLifetime(directory) {} }
        state.openWithoutHistory(url)
        try await wait { !state.busy }
        let original = state.document?.id
        guard case .pages(let pages) = state.document?.content else { return XCTFail("Expected PDF") }
        try await pages.pdfSetEditing(true)
        let annotations = try await pages.pdfAnnotations(0)
        let annotation = try XCTUnwrap(annotations.first)
        try prepareCapture(url)
        let replacement = replaceDuringCapture(url, with: pdf("external output"))
        defer { replacement.cancel() }
        state.reload()
        try await replacement.value
        try await wait { !state.busy }
        try await pages.pdfEditAnnotation(page: 0, id: annotation.id, edits: [.contents("local unsaved edit")])
        try await state.nativePDFDidChange(pages)
        let generation = state.generation
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.document?.id, original)
        XCTAssertTrue(state.modified)
        let retainedAnnotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(retainedAnnotations.first?.contents, "local unsaved edit")
        XCTAssertEqual(state.status, "File changed on disk; unsaved edits remain open")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testMalformedPDFReportsItsErrorWithoutRetryingAndPasswordErrorsStayDistinct() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("malformed.pdf")
        try Data("%PDF-1.7\nnot a PDF document".utf8).write(to: url)
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed(); withExtendedLifetime(directory) {} }
        state.openWithoutHistory(url)
        try await wait { !state.busy }
        XCTAssertNotNil(state.error)
        let generation = state.generation
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(state.generation, generation)

        let encrypted = directory.url.appendingPathComponent("encrypted.pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        try XCTUnwrap(document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"]))
            .write(to: encrypted)
        XCTAssertThrowsError(try ReadingDocument.open(encrypted)) { error in
            XCTAssertTrue(error is PasswordRequired)
            XCTAssertFalse(error is NativeFile.PDFSourceChanged)
        }
        XCTAssertNoThrow(try ReadingDocument.open(encrypted, password: "reader"))

        let unreadable = directory.url.appendingPathComponent("unreadable.pdf")
        try pdf("permission denied").write(to: unreadable)
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        defer { _ = chmod(unreadable.path, 0o600) }
        XCTAssertThrowsError(try ReadingDocument.open(unreadable)) { XCTAssertFalse($0 is NativeFile.PDFSourceChanged) }
    }
}
#endif
