#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class FileIdentityTests: XCTestCase {
    func testBookmarkFollowsMovedOriginalWhenItsOldNameHasBeenReused() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let original = directory.url.appendingPathComponent("original.txt")
        let moved = directory.url.appendingPathComponent("moved.txt")
        try "Original content".write(to: original, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(DocumentFileIdentity.bookmark(for: original))
        try FileManager.default.moveItem(at: original, to: moved)
        try "Different document".write(to: original, atomically: true, encoding: .utf8)
        XCTAssertEqual(DocumentFileIdentity.resolve(bookmark), moved)
        XCTAssertEqual(ReaderFiles.resolve(original, bookmark: bookmark), moved)
    }

    func testIdentityDoesNotAdoptReplacementAfterTheOriginalWasDeleted() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let original = directory.url.appendingPathComponent("original.txt")
        let moved = directory.url.appendingPathComponent("moved.txt")
        try "Original content".write(to: original, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(DocumentFileIdentity.bookmark(for: original))
        try FileManager.default.moveItem(at: original, to: moved)
        try "Different document".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: moved)
        XCTAssertNil(DocumentFileIdentity.resolve(bookmark))
        XCTAssertNil(ReaderFiles.resolve(original, bookmark: bookmark))
    }

    func testRestorationDoesNotAttachSavedPositionToAReplacementAtTheOldName() async throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appendingPathComponent("original.txt")
        try "Original content".write(to: original, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(DocumentFileIdentity.bookmark(for: original))
        try FileManager.default.removeItem(at: original)
        try "Different document".write(to: original, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableHistory")
        defaults.set(false, forKey: "disableHistory")
        var payload = WindowPayload(path: original.path, position: ReadingPosition(page: 8))
        payload.fileBookmark = bookmark
        let state = ReaderState(restoring: payload)
        defer { state.windowClosed(); defaults.set(previous, forKey: "disableHistory"); withExtendedLifetime(directory) {} }
        state.activateRestoredDocument()
        let deadline = Date().addingTimeInterval(3)
        while state.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.document)
        XCTAssertEqual(state.missingFile, original)
        XCTAssertNotNil(state.error)
        XCTAssertEqual(state.restoredPayload?.position?.page, 8)
    }

    func testExplicitOpenUsesTheSelectedFileEvenWhenOldHistoryTracksAMovedOriginal() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let original = directory.url.appendingPathComponent("selected.txt")
        let moved = directory.url.appendingPathComponent("moved.txt")
        try "Original content".write(to: original, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let keys = ["disableHistory", "documentOpenHistory", "position:" + original.path, "position:" + moved.path, "closedDocuments"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        defaults.set(false, forKey: "disableHistory")
        ReaderFiles.recordOpen(ReadingDocument(url: original, content: .text("original")), recordsHistory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let state = ReaderState()
        defer {
            state.windowClosed(); ReaderFiles.setRecent(recent)
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        state.open(original)
        try await waitFor { state.document != nil && !state.busy }
        XCTAssertEqual(state.document?.url, moved, "A missing old pathname still follows its saved identity")
        state.close()
        // Preserve a stale old-path history entry, as a closed app can have.
        ReaderFiles.recordOpen(ReadingDocument(url: moved, content: .text("original")), recordsHistory: true)
        try FileManager.default.moveItem(at: moved, to: original)
        ReaderFiles.recordOpen(ReadingDocument(url: original, content: .text("original")), recordsHistory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        try "Replacement explicitly selected".write(to: original, atomically: true, encoding: .utf8)
        state.open(original)
        try await waitFor { state.document != nil && !state.busy }
        XCTAssertEqual(state.document?.url, original)
        if case .text(let text) = state.document?.content { XCTAssertTrue(text.contains("Replacement explicitly selected")) }
        else { XCTFail("Expected the explicitly selected text file") }
    }

    func testNativeBookmarkFollowsFinderStyleMoveAndMigratesReadingAssociations() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let original = directory.url.appendingPathComponent("original.txt")
        let moved = directory.url.appendingPathComponent("Moved/renamed.txt")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Moved document identity".write(to: original, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(DocumentFileIdentity.bookmark(for: original))
        let defaults = UserDefaults.standard
        let position = ReadingPosition(page: 4, x: 12, y: 320, zoom: 2.5)
        let keys = ["disableHistory", "bookmarks", "pinnedDocuments", "documentOpenHistory", "closedDocuments", "session", "tabGroup:identity-test",
                    "position:" + original.path, "position:" + original.path + ":markdown:paged", MarkdownRenderer.preferenceKey(for: original),
                    "position:" + moved.path, "position:" + moved.path + ":markdown:paged", MarkdownRenderer.preferenceKey(for: moved)]
        let previous = keys.map { defaults.object(forKey: $0) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        defer {
            ReaderFiles.setRecent(recent)
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        defaults.set(false, forKey: "disableHistory")
        defaults.set(try JSONEncoder().encode(position), forKey: "position:" + original.path)
        defaults.set(try JSONEncoder().encode(position), forKey: "position:" + original.path + ":markdown:paged")
        defaults.set("paged", forKey: MarkdownRenderer.preferenceKey(for: original))
        let mark = ReaderBookmark(title: "My passage", path: original.path, position: position, fileBookmark: bookmark)
        defaults.set(try JSONEncoder().encode([mark]), forKey: "bookmarks")
        defaults.set([original.path], forKey: "pinnedDocuments")
        ReaderFiles.recordOpen(ReadingDocument(url: original, content: .text("identity")), recordsHistory: true)
        var saved = WindowPayload(path: original.path, position: position)
        saved.fileBookmark = bookmark
        for key in ["closedDocuments", "session", "tabGroup:identity-test"] { ReaderWindows.save([saved], key: key) }

        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertEqual(DocumentFileIdentity.resolve(bookmark), moved)
        XCTAssertEqual(ReaderFiles.resolve(original), moved)
        ReaderFiles.migrate(original, to: moved, recordsHistory: true)
        XCTAssertNil(defaults.object(forKey: "position:" + original.path))
        XCTAssertEqual(try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: "position:" + moved.path))), position)
        XCTAssertNotNil(defaults.data(forKey: "position:" + moved.path + ":markdown:paged"))
        XCTAssertEqual(defaults.string(forKey: MarkdownRenderer.preferenceKey(for: moved)), "paged")
        let marks = try JSONDecoder().decode([ReaderBookmark].self, from: XCTUnwrap(defaults.data(forKey: "bookmarks")))
        XCTAssertEqual(marks.first?.path, moved.path)
        XCTAssertEqual(marks.first?.position, position)
        XCTAssertEqual(ReaderFiles.pinned, [moved.path])
        for key in ["closedDocuments", "session", "tabGroup:identity-test"] {
            XCTAssertEqual(ReaderWindows.saved(key).first?.path, moved.path)
            XCTAssertEqual(ReaderWindows.saved(key).first?.position, position)
        }
    }

    func testPrivateRelocationDoesNotRewriteSavedAssociations() throws {
        let defaults = UserDefaults.standard
        let source = URL(fileURLWithPath: "/private/original.pdf"), destination = URL(fileURLWithPath: "/private/relocated.pdf")
        let key = "position:" + source.path, destinationKey = "position:" + destination.path
        let previous = defaults.object(forKey: key), previousDestination = defaults.object(forKey: destinationKey)
        defer { defaults.set(previous, forKey: key); defaults.set(previousDestination, forKey: destinationKey) }
        defaults.set(Data([1, 2, 3]), forKey: key)
        ReaderFiles.migrate(source, to: destination, recordsHistory: false)
        XCTAssertEqual(defaults.data(forKey: key), Data([1, 2, 3]))
        XCTAssertEqual(defaults.object(forKey: destinationKey) as? Data, previousDestination as? Data)
        var payload = WindowPayload(path: source.path, recordsHistory: false)
        payload.fileBookmark = Data([4, 5, 6])
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(WindowPayload.self, from: encoded)
        XCTAssertNil(decoded.path)
        XCTAssertNil(decoded.fileBookmark)
    }

    func testOpenReaderFollowsExternalRenameAndRelocateKeepsItsPosition() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("watched.txt")
        let moved = directory.url.appendingPathComponent("renamed.txt")
        try "Live rename fixture".write(to: source, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed(); withExtendedLifetime(directory) {} }
        state.openWithoutHistory(source, at: ReadingPosition(page: 0, x: 18, y: 90, zoom: 2.5))
        try await waitFor { state.document != nil && !state.busy }
        try FileManager.default.moveItem(at: source, to: moved)
        try await waitFor { state.document?.url == moved && !state.busy }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.zoom, 2.5)
        XCTAssertEqual(state.currentPosition.y, 90)

        let missing = ReaderState(recordsHistory: false, restoring: WindowPayload(path: source.path, position: .init(page: 0, x: 8, y: 64, zoom: 1.75), recordsHistory: false))
        defer { missing.windowClosed() }
        missing.relocateFile(to: moved)
        try await waitFor { missing.document != nil && !missing.busy }
        XCTAssertEqual(missing.document?.url, moved)
        XCTAssertEqual(missing.currentPosition.x, 8)
        XCTAssertEqual(missing.currentPosition.y, 64)
        XCTAssertEqual(missing.zoom, 1.75)
        XCTAssertFalse(missing.recordsDocumentHistory)
    }

    func testMovedEditedPDFKeepsInPlaceSaveAndAnnotationAppearance() async throws {
        try await checkMovedPDF(withCommittedAnnotation: true)
    }

    func testMovedCleanPDFPreservesPendingFormAndRefreshesBookmarksAfterSave() async throws {
        try await checkMovedPDF(withCommittedAnnotation: false)
    }

    private func checkMovedPDF(withCommittedAnnotation: Bool) async throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("editable.pdf")
        let moved = directory.url.appendingPathComponent("renamed.pdf")
        var box = CGRect(x: 0, y: 0, width: 120, height: 160)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(box)
        context.endPDFPage(); context.closePDF()
        let formDocument = try XCTUnwrap(PDFDocument(url: source))
        let form = PDFAnnotation(bounds: CGRect(x: 5, y: 5, width: 110, height: 20), forType: .widget, withProperties: nil)
        form.widgetFieldType = .text; form.fieldName = "Draft"; form.widgetStringValue = "initial"
        try XCTUnwrap(formDocument.page(at: 0)).addAnnotation(form)
        XCTAssertTrue(formDocument.write(to: source))
        let defaults = UserDefaults.standard
        let keys = ["disableHistory", "bookmarks", "documentOpenHistory", "closedDocuments", "session", "pinnedDocuments",
                    "position:" + source.path, "position:" + moved.path, "tabGroup:save-identity-test"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        defaults.set(false, forKey: "disableHistory")
        let state = ReaderState()
        defer {
            state.windowClosed(); ReaderFiles.setRecent(recent)
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        state.open(source)
        try await waitFor { state.nativePDF != nil && !state.busy }
        let savedMark = ReaderBookmark(title: "Preserved", path: source.path, position: .init(page: 0), fileBookmark: state.fileBookmark)
        defaults.set(try JSONEncoder().encode([savedMark]), forKey: "bookmarks")
        var savedTab = WindowPayload(path: source.path, position: .init(page: 0))
        savedTab.fileBookmark = state.fileBookmark
        ReaderWindows.save([savedTab], key: "tabGroup:save-identity-test")
        let pages = try XCTUnwrap(state.nativePDF)
        try await pages.pdfSetEditing(true)
        if withCommittedAnnotation {
            _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 20, y: 20, width: 50, height: 50),
                edits: [.color(SIMD3(1, 0, 0), interior: true), .contents("Preserve this edited appearance")])
            try await state.nativePDFDidChange(pages)
        }
        state.setPDFEditingEnabled(true)
        try await waitFor { state.pdfEditingEnabled }
        let liveAnnotations = try await pages.pdfAnnotations(0)
        let widget = try XCTUnwrap(liveAnnotations.first(where: { $0.type == "Widget" }))
        let square = liveAnnotations.first(where: { $0.type == "Square" })
        if let square { state.nativePDFSelection = .annotation(page: 0, square) }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 320))
        let editor = NativePDFFormEditor(widget: widget, host: host, frame: CGRect(x: 10, y: 10, width: 220, height: 30),
            commitValue: { input in
                guard case .text(let value) = input else { XCTFail("Expected text field input"); return }
                try await pages.pdfSetWidgetValue(page: 0, id: widget.id, value: value)
                try await state.nativePDFDidChange(pages)
            }, didClose: { state.nativePDFFormEditor = nil; state.nativePDFFormPage = nil },
            advance: { _ in }, failure: { XCTFail("\($0)") })
        state.nativePDFFormEditor = editor; state.nativePDFFormPage = 0
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "Pending draft kept"
        XCTAssertEqual(state.modified, withCommittedAnnotation)
        XCTAssertTrue(state.canSave)

        try FileManager.default.moveItem(at: source, to: moved)
        try await waitFor { state.document?.url == moved && !state.busy }
        XCTAssertTrue(state.nativePDF === pages, "Moving a modified PDF must retain its live edits")
        XCTAssertFalse(try XCTUnwrap(state.document).hasSeparatePDFSource)
        XCTAssertTrue(state.canSave, "A rename cannot turn an ordinary PDF into converted container content")
        XCTAssertTrue(state.pdfEditingEnabled)
        XCTAssertEqual(state.nativePDFSelection?.id, square?.id)
        XCTAssertTrue(state.nativePDFFormEditor === editor)
        XCTAssertEqual(field.stringValue, "Pending draft kept", "A source-only retarget must preserve uncommitted native input")
        state.savePDF()
        try await waitFor { !state.modified && !state.busy && state.nativePDF !== pages }
        XCTAssertNil(state.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let updatedMark = try XCTUnwrap(JSONDecoder().decode([ReaderBookmark].self, from: XCTUnwrap(defaults.data(forKey: "bookmarks"))).first)
        XCTAssertEqual(ReaderFiles.resolve(moved, bookmark: updatedMark.fileBookmark), moved)
        let updatedTab = try XCTUnwrap(ReaderWindows.saved("tabGroup:save-identity-test").first)
        XCTAssertEqual(DocumentFileIdentity.resolve(try XCTUnwrap(updatedTab.fileBookmark)), moved)
        XCTAssertEqual(ReaderFiles.resolve(moved), moved)
        state.openBookmark(updatedMark)
        XCTAssertNil(state.missingFile)
        let saved = try Pages(moved, format: .pdf)
        let annotations = try await saved.pdfAnnotations(0)
        if withCommittedAnnotation {
            XCTAssertEqual(annotations.first(where: { $0.type == "Square" })?.contents, "Preserve this edited appearance")
        }
        XCTAssertEqual(annotations.first(where: { $0.type == "Widget" })?.value, "Pending draft kept")
        if withCommittedAnnotation {
            let image = try await saved.image(0, width: 240)
            XCTAssertGreaterThan(try redPixels(image), 8_000, "The saved PDF must render the edited annotation appearance")
        }
        withExtendedLifetime((editor, host, formDocument)) {}
    }

    private func redPixels(_ image: CGImage) throws -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 }.count
    }

    private func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "File identity operation did not finish", line: line)
    }
}
#endif
