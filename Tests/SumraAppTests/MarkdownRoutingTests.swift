#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import Sumra

final class MarkdownRoutingTests: XCTestCase {
    @MainActor
    func testMarkupSiblingDecisionUsesInspectedTypeAndSharedPolicy() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.md")
        let large = directory.url.appendingPathComponent("large.md")
        let paged = directory.url.appendingPathComponent("paged.md")
        let compatible = directory.url.appendingPathComponent("compatible.md")
        let html = directory.url.appendingPathComponent("page.html")
        let chm = directory.url.appendingPathComponent("book.chm")
        let disguised = directory.url.appendingPathComponent("disguised.md")
        for url in [source, paged, compatible] {
            try "# Sibling\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try "# Large\n".write(to: large, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(MarkdownRenderer.largeDocumentThreshold))
        try handle.close()
        try "<h1>HTML</h1>".write(to: html, atomically: true, encoding: .utf8)
        try Data("ITSF".utf8).write(to: chm)
        let pdf = PDFDocument(), page = PDFPage()
        pdf.insert(page, at: 0)
        try XCTUnwrap(pdf.dataRepresentation()).write(to: disguised)

        let defaults = UserDefaults.standard
        let priorFixed = defaults.object(forKey: "useFixedPageUI")
        let pagedKey = MarkdownRenderer.preferenceKey(for: paged)
        let compatibleKey = MarkdownRenderer.preferenceKey(for: compatible)
        let priorPaged = defaults.object(forKey: pagedKey)
        let priorCompatible = defaults.object(forKey: compatibleKey)
        defer {
            defaults.set(priorFixed, forKey: "useFixedPageUI")
            defaults.set(priorPaged, forKey: pagedKey)
            defaults.set(priorCompatible, forKey: compatibleKey)
        }
        defaults.set(false, forKey: "useFixedPageUI")
        defaults.set(MarkdownRenderer.paged.rawValue, forKey: pagedKey)
        defaults.set(MarkdownRenderer.compatible.rawValue, forKey: compatibleKey)
        let state = ReaderState(recordsHistory: false)
        state.document = try ReadingDocument.open(source)
        XCTAssertTrue(state.shouldOpenMarkupSibling(large))
        XCTAssertTrue(state.shouldOpenMarkupSibling(paged))
        XCTAssertTrue(state.shouldOpenMarkupSibling(disguised))
        XCTAssertFalse(state.shouldOpenMarkupSibling(compatible))
        XCTAssertFalse(state.shouldOpenMarkupSibling(source))
        XCTAssertFalse(state.shouldOpenMarkupSibling(html))
        XCTAssertFalse(state.shouldOpenMarkupSibling(chm))

        var displayed = try XCTUnwrap(state.document)
        displayed.retargetSource(to: paged)
        XCTAssertEqual(displayed.markdownPreference, .paged,
                       "Retargeting must not rewrite the sibling's saved preference")
        XCTAssertEqual(displayed.markdownRenderer, .compatible,
                       "A still-mounted browser must report its actual renderer")
    }

    @MainActor
    func testInspectedMarkdownUsesSizeAndPreferenceWhileDisguisedPDFStaysPDF() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let small = directory.url.appendingPathComponent("small.md")
        try "# Small\n\nA short document.\n".write(to: small, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let preferenceKey = MarkdownRenderer.preferenceKey(for: small)
        let priorPreference = defaults.object(forKey: preferenceKey)
        let priorFixed = defaults.object(forKey: "useFixedPageUI")
        defer {
            defaults.set(priorPreference, forKey: preferenceKey)
            defaults.set(priorFixed, forKey: "useFixedPageUI")
        }
        defaults.removeObject(forKey: preferenceKey)
        defaults.set(false, forKey: "useFixedPageUI")

        let automatic = try ReadingDocument.open(small)
        XCTAssertEqual(automatic.markdownPreference, .automatic)
        XCTAssertEqual(automatic.markdownRenderer, .compatible)
        guard case .browser = automatic.content else { return XCTFail("Small Markdown should use the browser") }

        defaults.set(MarkdownRenderer.paged.rawValue, forKey: preferenceKey)
        let chosen = try ReadingDocument.open(small, deferReflowLayout: true)
        XCTAssertEqual(chosen.markdownRenderer, .paged)
        guard case .pages = chosen.content else { return XCTFail("Paged preference should use MuPDF") }
        let explicit = try ReadingDocument.open(small, markdownRenderer: .compatible)
        XCTAssertEqual(explicit.markdownRenderer, .compatible)
        defaults.removeObject(forKey: preferenceKey)
        defaults.set(true, forKey: "useFixedPageUI")
        XCTAssertEqual(try ReadingDocument.open(small, deferReflowLayout: true).markdownRenderer, .paged)
        defaults.set(false, forKey: "useFixedPageUI")

        let html = directory.url.appendingPathComponent("page.html")
        try "<h1>HTML</h1>".write(to: html, atomically: true, encoding: .utf8)
        let openedHTML = try ReadingDocument.open(html, markdownRenderer: .paged)
        XCTAssertNil(openedHTML.markdownRenderer)
        guard case .browser = openedHTML.content else { return XCTFail("HTML routing should stay unchanged") }

        let large = directory.url.appendingPathComponent("large.md")
        try Data("# Large\n".utf8).write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(MarkdownRenderer.largeDocumentThreshold + 1))
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: large), .paged)
        try handle.truncate(atOffset: UInt64(MarkdownRenderer.largeDocumentThreshold))
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: large), .paged)
        try handle.truncate(atOffset: UInt64(MarkdownRenderer.largeDocumentThreshold - 1))
        try handle.close()
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: large), .compatible)

        let disguised = directory.url.appendingPathComponent("disguised.md")
        let pdf = PDFDocument(), page = PDFPage()
        pdf.insert(page, at: 0)
        try XCTUnwrap(pdf.dataRepresentation()).write(to: disguised)
        let openedPDF = try ReadingDocument.open(disguised, markdownRenderer: .compatible)
        XCTAssertNil(openedPDF.markdownRenderer)
        guard case .pages(let pages) = openedPDF.content else { return XCTFail("PDF signature should win") }
        XCTAssertTrue(pages.isPDF)
    }

    @MainActor
    func testRendererSwitchRestoresEachModesOwnPosition() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("positions.md")
        try "# Positions\n\nOne paragraph.\n".write(to: url, atomically: true, encoding: .utf8)
        let preferenceKey = MarkdownRenderer.preferenceKey(for: url)
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        let previousFixed = UserDefaults.standard.object(forKey: "useFixedPageUI")
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        UserDefaults.standard.set(false, forKey: "useFixedPageUI")
        defer {
            UserDefaults.standard.set(previous, forKey: preferenceKey)
            UserDefaults.standard.set(previousFixed, forKey: "useFixedPageUI")
        }
        let state = ReaderState(recordsHistory: false)
        defer { state.close() }
        state.openWithoutHistory(url)
        try await waitForLoad(state)
        XCTAssertEqual(state.document?.markdownRenderer, .compatible)
        let passage = MarkdownPassage(path: [0], offset: 3, top: 12, text: "Positions", end: false)
        state.updatePosition(.init(page: 0, x: 0, y: 230, markdownPassage: passage))

        state.setMarkdownRenderer(.paged)
        try await waitForLoad(state)
        XCTAssertTrue(state.isNativeMarkdown)
        XCTAssertNil(state.currentPosition.markdownPassage)
        XCTAssertEqual(state.rasterZoom, 1)
        state.setZoom(1.25)
        XCTAssertEqual(state.zoom, 1.25)
        XCTAssertEqual(state.fit, "page")
        XCTAssertEqual(state.zoomLabel, "125%")
        state.updatePosition(.init(page: 2, x: 12, y: 34))

        state.setMarkdownRenderer(.compatible)
        try await waitForLoad(state)
        XCTAssertEqual(state.currentPosition.markdownPassage, passage)
        XCTAssertEqual(state.currentPosition.y, 230)
        XCTAssertFalse(state.isNativeMarkdown)

        state.setMarkdownRenderer(.paged)
        try await waitForLoad(state)
        XCTAssertEqual(state.currentPosition.page, 2)
        XCTAssertNil(state.currentPosition.markdownPassage)
        XCTAssertEqual(state.document?.markdownPreference, .paged)
        XCTAssertFalse(state.escalateMarkdownLayoutLimit())
    }

    @MainActor
    func testAutomaticLayoutLimitEscalatesWithoutSavingPagedPreference() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("limit.md")
        try "# Limit\n".write(to: url, atomically: true, encoding: .utf8)
        let key = MarkdownRenderer.preferenceKey(for: url)
        let hintKey = MarkdownRenderer.layoutHintKey(for: url)
        let previous = UserDefaults.standard.object(forKey: key)
        let previousHint = UserDefaults.standard.object(forKey: hintKey)
        let previousFixed = UserDefaults.standard.object(forKey: "useFixedPageUI")
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: hintKey)
        UserDefaults.standard.set(false, forKey: "useFixedPageUI")
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            UserDefaults.standard.set(previousHint, forKey: hintKey)
            UserDefaults.standard.set(previousFixed, forKey: "useFixedPageUI")
        }
        let state = ReaderState(recordsHistory: false)
        defer { state.close() }
        state.openWithoutHistory(url)
        try await waitForLoad(state)
        XCTAssertEqual(state.document?.markdownPreference, .automatic)
        let browserPassage = MarkdownPassage(path: [0], offset: 2, top: 8, text: "Limit", end: false)
        state.updatePosition(.init(page: 0, x: 0, y: 140, markdownPassage: browserPassage))
        XCTAssertTrue(state.escalateMarkdownLayoutLimit())
        try await waitForLoad(state)
        XCTAssertTrue(state.isNativeMarkdown)
        XCTAssertEqual(state.currentPosition.page, 0)
        XCTAssertNil(state.currentPosition.markdownPassage)
        XCTAssertEqual(state.document?.markdownPreference, .automatic)
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
        XCTAssertFalse(state.escalateMarkdownLayoutLimit())
        XCTAssertEqual(try ReadingDocument.open(url, deferReflowLayout: true).markdownRenderer, .paged,
                       "Reopening the same version should honor the observed layout limit")
        XCTAssertEqual(try ReadingDocument.open(url, markdownRenderer: .compatible).markdownRenderer, .compatible,
                       "An explicit compatibility choice overrides the automatic hint")
        state.updatePosition(.init(page: 2, x: 20, y: 36))
        state.reload()
        try await waitForLoad(state)
        XCTAssertTrue(state.isNativeMarkdown)
        XCTAssertEqual(state.currentPosition.page, 2)

        try Data("# Replaced source\n".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(try ReadingDocument.open(url).markdownRenderer, .compatible,
                       "A new inode or timestamp invalidates the old layout observation")
        state.reload()
        try await waitForRenderer(state, .compatible)
        XCTAssertFalse(state.isNativeMarkdown)
        XCTAssertEqual(state.currentPosition.markdownPassage, browserPassage)
        XCTAssertEqual(state.currentPosition.y, 140)
    }

    @MainActor
    func testAutomaticDenseMarkdownRoutesBeforeBrowserLoading() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("dense.md")
        let source = directory.url.appendingPathComponent("ordinary.md")
        try "# Ordinary\n\nA short paragraph.\n".write(to: source, atomically: true, encoding: .utf8)
        let dense = Data(String(repeating: "Short paragraph.\n\n", count: 150_000).utf8)
        XCTAssertLessThan(dense.count, MarkdownRenderer.largeDocumentThreshold)
        try dense.write(to: url)
        let priorFixed = UserDefaults.standard.object(forKey: "useFixedPageUI")
        defer { UserDefaults.standard.set(priorFixed, forKey: "useFixedPageUI") }
        UserDefaults.standard.set(false, forKey: "useFixedPageUI")
        let opened = try ReadingDocument.open(url, deferReflowLayout: true)
        XCTAssertEqual(opened.markdownPreference, .automatic)
        XCTAssertEqual(opened.markdownRenderer, .paged)
        guard case .pages = opened.content else { return XCTFail("Dense Markdown must avoid first browser loading") }
        XCTAssertNil(UserDefaults.standard.string(forKey: MarkdownRenderer.layoutHintKey(for: url)),
                     "Source-density routing is not a persisted browser layout observation")
        XCTAssertEqual(try ReadingDocument.open(url, markdownRenderer: .compatible).markdownRenderer, .compatible)
        let state = ReaderState(recordsHistory: false)
        state.document = try ReadingDocument.open(source)
        XCTAssertTrue(state.shouldOpenMarkupSibling(url))
        try "# Edited\n\nA short paragraph.\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .compatible)
        XCTAssertFalse(state.shouldOpenMarkupSibling(url))
    }

    func testAutomaticDensityHandlesLineEndingsWhitespaceAndChunkBoundaries() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("density.md")
        for ending in ["\n", "\r\n", "\r"] {
            let separator = ending + " \t" + ending
            let below = String(repeating: "p" + separator, count: MarkdownRenderer.denseSourceRunThreshold - 1)
            try Data(below.utf8).write(to: url, options: .atomic)
            XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .compatible, ending.debugDescription)
            try Data((below + "last").utf8).write(to: url, options: .atomic)
            XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .paged, ending.debugDescription)
            XCTAssertEqual(try MarkdownRenderer.compatible.effective(for: url), .compatible)
        }
        // The CR/LF pair crosses a 64 KiB read boundary; it is one line ending.
        let prefix = String(repeating: "x", count: 65_535) + "\r\n"
        let followingLines = String(repeating: "p\r\n", count: 150_000)
        try Data((prefix + followingLines).utf8).write(to: url, options: .atomic)
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .compatible,
                       "Soft line breaks inside one source run must not create density")
        let blocks = String(repeating: "p\r\n\r\n", count: MarkdownRenderer.denseSourceRunThreshold - 1)
        try Data((prefix + "\r\n" + blocks).utf8).write(to: url, options: .atomic)
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .paged)
    }

    @MainActor
    func testAutomaticLayoutHintSurvivesFinderMetadataChanges() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("metadata.md")
        let data = Data("# Metadata\n\nUnchanged document.\n".utf8)
        try data.write(to: url)
        let hintKey = MarkdownRenderer.layoutHintKey(for: url)
        defer { UserDefaults.standard.removeObject(forKey: hintKey) }
        let original = try XCTUnwrap(NativeFile.FileVersion(url))
        let signature = try XCTUnwrap(MarkdownRenderer.sourceSignature(for: url))
        XCTAssertTrue(MarkdownRenderer.rememberLayoutLimit(for: url, openedSignature: signature))
        let metadata = Array("last opened".utf8)
        XCTAssertEqual(metadata.withUnsafeBytes {
            setxattr(url.path, "com.sumra.test.markdown-metadata", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let changed = try XCTUnwrap(NativeFile.FileVersion(url))
        XCTAssertNotEqual(original, changed)
        XCTAssertTrue(original.matchesContentMetadata(changed))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(MarkdownRenderer.sourceSignature(for: url), signature)
        XCTAssertEqual(try ReadingDocument.open(url, deferReflowLayout: true).markdownRenderer, .paged)
        XCTAssertEqual(try ReadingDocument.open(url, markdownRenderer: .compatible).markdownRenderer, .compatible)
        XCTAssertEqual(UserDefaults.standard.string(forKey: hintKey), signature)
    }

    @MainActor
    func testAutomaticLayoutHintRejectsContentEditsAndReplacedFiles() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("edited.md")
        let originalData = Data("# Before\n".utf8)
        let editedData = Data("# Edited\n".utf8)
        XCTAssertEqual(originalData.count, editedData.count)
        try originalData.write(to: url)
        let hintKey = MarkdownRenderer.layoutHintKey(for: url)
        defer { UserDefaults.standard.removeObject(forKey: hintKey) }
        let original = try XCTUnwrap(NativeFile.FileVersion(url))
        let signature = try XCTUnwrap(MarkdownRenderer.sourceSignature(for: url))
        XCTAssertTrue(MarkdownRenderer.rememberLayoutLimit(for: url, openedSignature: signature))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: editedData)
        try handle.close()
        let edited = try XCTUnwrap(NativeFile.FileVersion(url))
        XCTAssertEqual(edited.inode, original.inode)
        XCTAssertEqual(edited.size, original.size)
        XCTAssertNotEqual(MarkdownRenderer.sourceSignature(for: url), signature)
        XCTAssertFalse(MarkdownRenderer.rememberLayoutLimit(for: url, openedSignature: signature))
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .compatible)
        XCTAssertNil(UserDefaults.standard.string(forKey: hintKey))

        let editedSignature = try XCTUnwrap(MarkdownRenderer.sourceSignature(for: url))
        XCTAssertTrue(MarkdownRenderer.rememberLayoutLimit(for: url, openedSignature: editedSignature))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try editedData.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])],
                                             ofItemAtPath: url.path)
        XCTAssertNotEqual(try XCTUnwrap(NativeFile.FileVersion(url)).inode, edited.inode)
        XCTAssertNotEqual(MarkdownRenderer.sourceSignature(for: url), editedSignature)
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .compatible)
        XCTAssertNil(UserDefaults.standard.string(forKey: hintKey))
    }

    @MainActor
    private func waitForLoad(_ state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if !state.busy, state.document != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "Markdown load timed out")
    }

    @MainActor
    private func waitForRenderer(_ state: ReaderState, _ renderer: MarkdownRenderer) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if !state.busy, state.document?.markdownRenderer == renderer { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "Markdown renderer did not change")
    }
}
#endif
