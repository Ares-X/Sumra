#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import Sumra

@MainActor
final class NativePDFClipboardTests: XCTestCase {
    func testCopyWorksWithEditingLockedButCutAndPasteRequireUnlocking() async throws {
        let directory = try TemporaryDirectory()
        let (state, pages, _) = try await fixture(directory, name: "locked")
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; state.windowClosed(); withExtendedLifetime(directory) {} }
        XCTAssertFalse(state.canEditPDF)
        let consumed = try await NativePDFAnnotations.perform("copy", preset: nil, selection: [:], state: state, pages: pages)
        XCTAssertFalse(consumed); XCTAssertTrue(ReaderMenuCommand.copyAnnotation.enabled(state))
        XCTAssertFalse(ReaderMenuCommand.cutAnnotation.enabled(state)); XCTAssertFalse(ReaderMenuCommand.pasteAnnotation.enabled(state))
        let clipboard = try XCTUnwrap(NativePDFClipboard.current)
        let creation = clipboard.creation(page: 0, at: CGPoint(x: 80, y: 90))
        XCTAssertEqual(creation.bounds, CGRect(x: 80, y: 90, width: 60, height: 40))
        let before = try await pages.pdfInfo()
        try await clipboard.paste(state: state, pages: pages, page: 0, at: .zero)
        let after = try await pages.pdfInfo()
        XCTAssertEqual(before?.undoPosition, after?.undoPosition)
        let cut = try await NativePDFClipboard.copy(state: state, pages: pages, cut: true)
        XCTAssertFalse(cut); XCTAssertTrue(NativePDFClipboard.current === clipboard)
    }

    func testFailedCutPasteRetainsTheSourceAndSuccessfulMoveUndoesInOneStep() async throws {
        let directory = try TemporaryDirectory()
        let (state, pages, original) = try await fixture(directory, name: "move")
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; state.windowClosed(); withExtendedLifetime(directory) {} }
        try await unlock(state)
        let before = try await pages.pdfInfo()
        let copied = try await NativePDFClipboard.copy(state: state, pages: pages, cut: true)
        XCTAssertTrue(copied)
        let clipboard = try XCTUnwrap(NativePDFClipboard.current)
        let cutAnnotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(cutAnnotations.map(\.id), [original], "Cut must not remove anything before paste")
        do {
            try await clipboard.paste(state: state, pages: pages, page: 99, at: .zero)
            XCTFail("A missing page must reject paste")
        } catch {}
        let failed = try await pages.pdfAnnotations(0), failedInfo = try await pages.pdfInfo()
        XCTAssertEqual(failed.map(\.id), [original]); XCTAssertEqual(failedInfo?.undoPosition, before?.undoPosition)
        try await clipboard.paste(state: state, pages: pages, page: 0, at: CGPoint(x: 80, y: 90))
        let moved = try await pages.pdfAnnotations(0), movedInfo = try await pages.pdfInfo()
        XCTAssertEqual(moved.count, 1); XCTAssertNotEqual(moved.first?.id, original)
        XCTAssertEqual(moved.first?.contents, "Source annotation")
        XCTAssertEqual(moved.first?.copyBounds, CGRect(x: 80, y: 90, width: 60, height: 40))
        XCTAssertEqual(movedInfo?.undoPosition, (before?.undoPosition ?? 0) + 1)
        try await state.changeNativePDFHistory(redo: false)
        let undone = try await pages.pdfAnnotations(0)
        XCTAssertEqual(undone.map(\.id), [original])
        try await clipboard.paste(state: state, pages: pages, page: 0, at: CGPoint(x: 120, y: 130))
        let repeated = try await pages.pdfAnnotations(0)
        XCTAssertEqual(repeated.count, 2, "A pending cut is consumed only once, even after Undo")
        XCTAssertTrue(repeated.contains { $0.id == original })
    }

    func testCrossDocumentCutRemovesTheOriginalOnlyAfterTheCopyLands() async throws {
        let directory = try TemporaryDirectory()
        let (source, sourcePages, original) = try await fixture(directory, name: "source")
        let (target, targetPages, _) = try await fixture(directory, name: "target")
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; source.windowClosed(); target.windowClosed(); withExtendedLifetime(directory) {} }
        try await unlock(source); try await unlock(target)
        let copied = try await NativePDFClipboard.copy(state: source, pages: sourcePages, cut: true)
        XCTAssertTrue(copied)
        try await XCTUnwrap(NativePDFClipboard.current).paste(state: target, pages: targetPages, page: 0, at: CGPoint(x: 100, y: 110))
        let remaining = try await sourcePages.pdfAnnotations(0), pasted = try await targetPages.pdfAnnotations(0)
        XCTAssertFalse(remaining.contains { $0.id == original }); XCTAssertEqual(pasted.count, 2)
        XCTAssertNil(source.nativePDFSelection); XCTAssertNotNil(target.nativePDFSelection)
        try await source.changeNativePDFHistory(redo: false)
        let restored = try await sourcePages.pdfAnnotations(0)
        XCTAssertTrue(restored.contains { $0.id == original })
        let stillPasted = try await targetPages.pdfAnnotations(0)
        XCTAssertEqual(stillPasted, pasted, "Undo in the source must not undo the other document's paste")
    }

    func testCrossDocumentDeletionFailurePublishesDestinationForUndoCopyAndCloseDecisions() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let (source, sourcePages, original) = try await fixture(directory, name: "failed-delete-source")
        let (target, targetPages, targetOriginal) = try await fixture(directory, name: "failed-delete-target")
        let previous = NativePDFClipboard.current
        defer {
            NativePDFClipboard.current = previous
            source.windowClosed(); target.windowClosed(); withExtendedLifetime(directory) {}
        }
        try await unlock(source); try await unlock(target)
        let sourceURL = try XCTUnwrap(source.document?.url), targetURL = try XCTUnwrap(target.document?.url)
        // Commit the fixture annotations so an already-dirty model cannot hide
        // a missing publication of the paste's own mutation.
        try await sourcePages.pdfSave(to: sourceURL); try await source.nativePDFDidChange(sourcePages)
        try await targetPages.pdfSave(to: targetURL); try await target.nativePDFDidChange(targetPages)
        let sourceBytes = try Data(contentsOf: sourceURL), targetBytes = try Data(contentsOf: targetURL)
        let sourceBefore = try await sourcePages.pdfInfo(), targetBefore = try await targetPages.pdfInfo()
        let renderBefore = target.renderRevision
        XCTAssertFalse(source.modified); XCTAssertFalse(target.modified)
        XCTAssertEqual(sourceBefore?.dirty, false); XCTAssertEqual(targetBefore?.dirty, false)
        let copied = try await NativePDFClipboard.copy(state: source, pages: sourcePages, cut: true)
        XCTAssertTrue(copied)
        let clipboard = try XCTUnwrap(NativePDFClipboard.current)

        // Test-injected native failure: lock the real MuPDF edit owner without
        // changing ReaderState. Its conditional delete still finds the original
        // snapshot, then the native deletion throws. This is not a GUI race.
        try await sourcePages.pdfSetEditing(false)
        XCTAssertTrue(source.canEditPDF)
        do {
            try await clipboard.paste(state: target, pages: targetPages, page: 0, at: CGPoint(x: 100, y: 110))
            XCTFail("The native source deletion must reject editing")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Annotation pasted, but the original could not be removed: "))
            let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            XCTAssertNotNil(cause)
            if let cause {
                XCTAssertFalse(cause.localizedDescription.isEmpty)
                XCTAssertTrue(error.localizedDescription.hasSuffix(cause.localizedDescription))
            }
        }
        let remaining = try await sourcePages.pdfAnnotations(0), pasted = try await targetPages.pdfAnnotations(0)
        let sourceAfter = try await sourcePages.pdfInfo(), targetAfter = try await targetPages.pdfInfo()
        XCTAssertEqual(remaining.map(\.id), [original]); XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(sourceAfter?.undoPosition, sourceBefore?.undoPosition)
        XCTAssertEqual(sourceAfter?.dirty, false); XCTAssertFalse(source.modified)
        XCTAssertEqual(targetAfter?.undoPosition, (targetBefore?.undoPosition ?? 0) + 1)
        XCTAssertEqual(targetAfter?.dirty, true); XCTAssertEqual(target.nativePDFInfo?.dirty, true)
        XCTAssertTrue(target.modified); XCTAssertGreaterThan(target.renderRevision, renderBefore)
        guard case .annotation(let page, let selected) = target.nativePDFSelection else { return XCTFail("The pasted annotation must be selected") }
        XCTAssertEqual(page, 0); XCTAssertNotEqual(selected.id, targetOriginal)
        XCTAssertTrue(pasted.contains { $0.id == selected.id })
        let sourceCloses = await source.confirmClose()
        XCTAssertTrue(sourceCloses, "The unchanged source must not require a save")

        // Check close directly after the failed source deletion, before Undo
        // or Redo could publish the previously missed destination mutation.
        // Guard first so a broken test cannot leave a queued modal response.
        guard target.modified else { return XCTFail("Close decisions require the actual destination mutation") }
        let prompts = expectation(description: "The dirty destination asks before closing")
        prompts.expectedFulfillmentCount = 2
        for (response, expected) in [(NSApplication.ModalResponse.alertThirdButtonReturn, false), (.alertSecondButtonReturn, true)] {
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated {
                    prompts.fulfill()
                    NSApplication.shared.stopModal(withCode: response)
                }
            }
            let allowed = await target.confirmClose()
            XCTAssertEqual(allowed, expected)
            XCTAssertTrue(target.modified, "Cancel and Discard close approvals must not save the live PDF")
            XCTAssertEqual(try Data(contentsOf: targetURL), targetBytes)
        }
        await fulfillment(of: [prompts], timeout: 1)

        try await target.changeNativePDFHistory(redo: false)
        let undone = try await targetPages.pdfAnnotations(0)
        XCTAssertEqual(undone.map(\.id), [targetOriginal]); XCTAssertFalse(target.modified)
        try await target.changeNativePDFHistory(redo: true)
        let redone = try await targetPages.pdfAnnotations(0), unchangedSource = try await sourcePages.pdfAnnotations(0)
        XCTAssertEqual(redone, pasted); XCTAssertTrue(target.modified)
        XCTAssertEqual(unchangedSource, remaining)
        let copyURL = directory.url.appendingPathComponent("failed-delete-copy.pdf")
        try await XCTUnwrap(target.document).saveCopy(to: copyURL)
        let savedCopy = try NativeFile(copyURL, engine: .mupdf)
        XCTAssertEqual(try savedCopy.pdfAnnotations(0).count, 2)
        XCTAssertTrue(target.modified, "Save a Copy must keep the opened destination dirty")
        let afterCopy = try await targetPages.pdfInfo()
        XCTAssertEqual(afterCopy?.dirty, true)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: targetURL), targetBytes)

        guard target.modified else { return XCTFail("Save on close must see the restored paste") }
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated { NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn) }
        }
        let savedClose = await target.confirmClose()
        XCTAssertTrue(savedClose); XCTAssertFalse(target.modified)
        let savedTarget = try NativeFile(targetURL, engine: .mupdf), savedSource = try NativeFile(sourceURL, engine: .mupdf)
        XCTAssertEqual(try savedTarget.pdfAnnotations(0).count, 2)
        XCTAssertEqual(try savedSource.pdfAnnotations(0).map(\.id), [original])
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testReplacingTheCutSourceDoesNotDeleteAnAnnotationInTheReplacement() async throws {
        let directory = try TemporaryDirectory()
        let (source, pages, original) = try await fixture(directory, name: "old")
        let (replacement, newPages, newOriginal) = try await fixture(directory, name: "new")
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; source.windowClosed(); replacement.windowClosed(); withExtendedLifetime(directory) {} }
        try await unlock(source)
        let copied = try await NativePDFClipboard.copy(state: source, pages: pages, cut: true)
        XCTAssertTrue(copied)
        source.document = replacement.document
        source.nativePDFInfo = try await newPages.pdfInfo()
        try await unlock(source)
        try await XCTUnwrap(NativePDFClipboard.current).paste(state: source, pages: newPages, page: 0, at: CGPoint(x: 100, y: 110))
        let oldAnnotations = try await pages.pdfAnnotations(0), newAnnotations = try await newPages.pdfAnnotations(0)
        XCTAssertEqual(oldAnnotations.map(\.id), [original])
        XCTAssertEqual(newAnnotations.count, 2); XCTAssertTrue(newAnnotations.contains { $0.id == newOriginal })
    }

    func testSameDocumentPasteKeepsChangesMadeAfterCutAndUndoesOnlyTheCopy() async throws {
        let directory = try TemporaryDirectory()
        let (state, pages, original) = try await fixture(directory, name: "changed-cut")
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; state.windowClosed(); withExtendedLifetime(directory) {} }
        try await unlock(state)
        let copied = try await NativePDFClipboard.copy(state: state, pages: pages, cut: true)
        XCTAssertTrue(copied)
        try await pages.pdfEditAnnotation(page: 0, id: original, edits: [.contents("Later edit"), .move(CGSize(width: 10, height: 20))])
        try await state.nativePDFDidChange(pages)
        let beforePaste = try await pages.pdfInfo()
        try await XCTUnwrap(NativePDFClipboard.current).paste(state: state, pages: pages, page: 0, at: CGPoint(x: 100, y: 110))
        let pasted = try await pages.pdfAnnotations(0)
        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(pasted.first { $0.id == original }?.contents, "Later edit")
        XCTAssertEqual(pasted.first { $0.id == original }?.copyBounds, CGRect(x: 30, y: 50, width: 60, height: 40))
        XCTAssertEqual(pasted.first { $0.id != original }?.contents, "Source annotation")
        let afterPaste = try await pages.pdfInfo()
        XCTAssertEqual(afterPaste?.undoPosition, (beforePaste?.undoPosition ?? 0) + 1)
        try await state.changeNativePDFHistory(redo: false)
        let undone = try await pages.pdfAnnotations(0)
        XCTAssertEqual(undone.map(\.id), [original])
        XCTAssertEqual(undone.first?.contents, "Later edit")
        try await state.changeNativePDFHistory(redo: true)
        let redone = try await pages.pdfAnnotations(0)
        XCTAssertEqual(redone.count, 2)
        XCTAssertEqual(redone.first { $0.id == original }?.contents, "Later edit")
        XCTAssertEqual(state.status, L("Annotation pasted as a copy"))
    }

    func testCrossDocumentPasteKeepsChangesMadeAfterCutWithoutChangingSourceHistory() async throws {
        let directory = try TemporaryDirectory()
        let (source, sourcePages, original) = try await fixture(directory, name: "changed-source")
        let (target, targetPages, _) = try await fixture(directory, name: "changed-target")
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; source.windowClosed(); target.windowClosed(); withExtendedLifetime(directory) {} }
        try await unlock(source); try await unlock(target)
        let copied = try await NativePDFClipboard.copy(state: source, pages: sourcePages, cut: true)
        XCTAssertTrue(copied)
        try await sourcePages.pdfEditAnnotation(page: 0, id: original, edits: [.contents("Later edit")])
        try await source.nativePDFDidChange(sourcePages)
        let beforePaste = try await sourcePages.pdfInfo()
        try await XCTUnwrap(NativePDFClipboard.current).paste(state: target, pages: targetPages, page: 0, at: CGPoint(x: 100, y: 110))
        let remaining = try await sourcePages.pdfAnnotations(0), pasted = try await targetPages.pdfAnnotations(0)
        XCTAssertEqual(remaining.map(\.id), [original])
        XCTAssertEqual(remaining.first?.contents, "Later edit")
        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(pasted.filter { $0.contents == "Source annotation" }.count, 2)
        let afterPaste = try await sourcePages.pdfInfo()
        XCTAssertEqual(afterPaste?.undoPosition, beforePaste?.undoPosition)
        XCTAssertNotNil(source.nativePDFSelection)
        XCTAssertEqual(target.status, L("Annotation pasted as a copy"))
    }

    func testCutDoesNotRemoveStampArtworkReplacedAfterCopying() async throws {
        let directory = try TemporaryDirectory(), blue = directory.url.appendingPathComponent("blue.png"), red = directory.url.appendingPathComponent("red.png")
        try stampImage(blue, red: false); try stampImage(red, red: true)
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; withExtendedLifetime(directory) {} }
        for originalImage in [nil, blue] as [URL?] {
            let (state, pages, square) = try await fixture(directory, name: originalImage == nil ? "standard-stamp" : "image-stamp")
            defer { state.windowClosed() }
            try await unlock(state)
            try await pages.pdfDeleteAnnotation(page: 0, id: square)
            let edits: [PDFAnnotationEdit] = originalImage.map { [.stampImage($0)] } ?? [.icon("Draft")]
            let stamp = try await pages.pdfCreateAnnotation(page: 0, type: "Stamp", bounds: CGRect(x: 20, y: 30, width: 60, height: 40), edits: edits)
            try await NativePDFAnnotations.refresh(page: 0, id: stamp, state: state, pages: pages)
            let copied = try await NativePDFClipboard.copy(state: state, pages: pages, cut: true)
            XCTAssertTrue(copied)
            let initial = try await pages.pdfAnnotations(0)
            try await pages.pdfEditAnnotation(page: 0, id: stamp, edits: [.stampImage(red)])
            try await state.nativePDFDidChange(pages)
            let changed = try await pages.pdfAnnotations(0), changedImage = try await pages.pdfStampImage(page: 0, id: stamp)
            if originalImage != nil { XCTAssertEqual(changed, initial, "Bitmap replacement must exercise the appearance outside the value snapshot") }
            XCTAssertNotNil(changedImage)
            try await XCTUnwrap(NativePDFClipboard.current).paste(state: state, pages: pages, page: 0, at: CGPoint(x: 100, y: 110))
            let pasted = try await pages.pdfAnnotations(0), remainingImage = try await pages.pdfStampImage(page: 0, id: stamp)
            XCTAssertEqual(pasted.count, 2)
            XCTAssertTrue(pasted.contains { $0.id == stamp })
            XCTAssertEqual(remainingImage, changedImage)
            try await state.changeNativePDFHistory(redo: false)
            let undone = try await pages.pdfAnnotations(0), undoneImage = try await pages.pdfStampImage(page: 0, id: stamp)
            XCTAssertEqual(undone.map(\.id), [stamp]); XCTAssertEqual(undoneImage, changedImage)
        }
    }

    func testConditionalCutDeletionChecksTheCurrentSourceWithinItsActorTurn() async throws {
        let directory = try TemporaryDirectory()
        let (state, pages, original) = try await fixture(directory, name: "conditional-delete")
        defer { state.windowClosed(); withExtendedLifetime(directory) {} }
        try await unlock(state)
        let annotations = try await pages.pdfAnnotations(0)
        let snapshot = try XCTUnwrap(annotations.first)
        try await pages.pdfEditAnnotation(page: 0, id: original, edits: [.author("Later author")])
        let beforeDelete = try await pages.pdfInfo()
        let removed = try await pages.pdfDeleteAnnotation(page: 0, matching: snapshot, stampImage: nil)
        XCTAssertFalse(removed)
        let remaining = try await pages.pdfAnnotations(0), afterDelete = try await pages.pdfInfo()
        XCTAssertEqual(remaining.first?.author, "Later author")
        XCTAssertEqual(afterDelete?.undoPosition, beforeDelete?.undoPosition)
        let current = try XCTUnwrap(remaining.first)
        let deleted = try await pages.pdfDeleteAnnotation(page: 0, matching: current, stampImage: nil)
        XCTAssertTrue(deleted)
        let empty = try await pages.pdfAnnotations(0)
        XCTAssertTrue(empty.isEmpty)
    }

    func testUnchangedImageStampStillMovesAndUndoesInOneStep() async throws {
        let directory = try TemporaryDirectory(), image = directory.url.appendingPathComponent("unchanged.png")
        try stampImage(image, red: false)
        let (state, pages, square) = try await fixture(directory, name: "unchanged-stamp")
        let previous = NativePDFClipboard.current
        defer { NativePDFClipboard.current = previous; state.windowClosed(); withExtendedLifetime(directory) {} }
        try await unlock(state)
        try await pages.pdfDeleteAnnotation(page: 0, id: square)
        let stamp = try await pages.pdfCreateAnnotation(page: 0, type: "Stamp", bounds: CGRect(x: 20, y: 30, width: 60, height: 40), edits: [.stampImage(image)])
        try await NativePDFAnnotations.refresh(page: 0, id: stamp, state: state, pages: pages)
        let originalImage = try await pages.pdfStampImage(page: 0, id: stamp), beforePaste = try await pages.pdfInfo()
        let copied = try await NativePDFClipboard.copy(state: state, pages: pages, cut: true)
        XCTAssertTrue(copied)
        try await XCTUnwrap(NativePDFClipboard.current).paste(state: state, pages: pages, page: 0, at: CGPoint(x: 100, y: 110))
        let moved = try await pages.pdfAnnotations(0), afterPaste = try await pages.pdfInfo()
        XCTAssertEqual(moved.count, 1)
        let movedStamp = try XCTUnwrap(moved.first)
        XCTAssertNotEqual(movedStamp.id, stamp)
        let movedImage = try await pages.pdfStampImage(page: 0, id: movedStamp.id)
        XCTAssertEqual(movedImage, originalImage)
        XCTAssertEqual(afterPaste?.undoPosition, (beforePaste?.undoPosition ?? 0) + 1)
        XCTAssertEqual(state.status, L("Annotation pasted"))
        try await state.changeNativePDFHistory(redo: false)
        let undone = try await pages.pdfAnnotations(0), restoredImage = try await pages.pdfStampImage(page: 0, id: stamp)
        XCTAssertEqual(undone.map(\.id), [stamp]); XCTAssertEqual(restoredImage, originalImage)
    }

    func testTwoWindowsPastingTheSameCutDeleteTheSourceOnce() async throws {
        let directory = try TemporaryDirectory()
        let (source, sourcePages, _) = try await fixture(directory, name: "source")
        let (first, firstPages, _) = try await fixture(directory, name: "first")
        let (second, secondPages, _) = try await fixture(directory, name: "second")
        let previous = NativePDFClipboard.current
        defer {
            NativePDFClipboard.current = previous
            source.windowClosed(); first.windowClosed(); second.windowClosed(); withExtendedLifetime(directory) {}
        }
        try await unlock(source); try await unlock(first); try await unlock(second)
        let copied = try await NativePDFClipboard.copy(state: source, pages: sourcePages, cut: true)
        XCTAssertTrue(copied)
        let clipboard = try XCTUnwrap(NativePDFClipboard.current)
        let one = Task { try await clipboard.paste(state: first, pages: firstPages, page: 0, at: CGPoint(x: 100, y: 110)) }
        let two = Task { try await clipboard.paste(state: second, pages: secondPages, page: 0, at: CGPoint(x: 100, y: 110)) }
        try await one.value; try await two.value
        let remaining = try await sourcePages.pdfAnnotations(0)
        let firstAnnotations = try await firstPages.pdfAnnotations(0), secondAnnotations = try await secondPages.pdfAnnotations(0)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(firstAnnotations.count, 2); XCTAssertEqual(secondAnnotations.count, 2)
    }

    private func unlock(_ state: ReaderState) async throws {
        let changed = expectation(description: "Editing unlocked")
        let observation = state.$pdfEditingEnabled.dropFirst().first().sink { _ in changed.fulfill() }
        state.setPDFEditingEnabled(true)
        await fulfillment(of: [changed], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertNil(state.error); XCTAssertTrue(state.canEditPDF)
    }

    private func stampImage(_ url: URL, red: Bool) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in stride(from: 0, to: 8 * 8 * 4, by: 4) {
            pixels[index] = red ? 255 : 0; pixels[index + 1] = 0; pixels[index + 2] = red ? 0 : 255; pixels[index + 3] = 255
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func fixture(_ directory: TemporaryDirectory, name: String) async throws -> (ReaderState, Pages, Int32) {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else { throw XCTSkip("MuPDF engine is required") }
        let source = directory.url.appendingPathComponent(name + ".pdf")
        let bytes = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        try (bytes as Data).write(to: source)
        let pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        let id = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 20, y: 30, width: 60, height: 40),
            edits: [.contents("Source annotation"), .border(width: 8, style: 0, dash: [])])
        try await pages.pdfSetEditing(false)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: source, content: .pages(pages)); state.count = 1
        state.nativePDFInfo = try await pages.pdfInfo()
        let annotations = try await pages.pdfAnnotations(0)
        let annotation = try XCTUnwrap(annotations.first)
        state.nativePDFSelection = .annotation(page: 0, annotation)
        return (state, pages, id)
    }
}
#endif
