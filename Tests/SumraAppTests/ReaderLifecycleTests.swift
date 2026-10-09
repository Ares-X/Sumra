#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class ReaderLifecycleTests: XCTestCase {
    @MainActor
    func testDelayedFilePickerCreatesWindowsAfterItsReaderClosed() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableHistory")
        defaults.set(true, forKey: "disableHistory")
        defer { defaults.set(previous, forKey: "disableHistory") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let urls = ["First.txt", "Second.txt"].map { directory.url.appendingPathComponent($0) }
        for url in urls { try "Delayed picker fixture".write(to: url, atomically: true, encoding: .utf8) }
        for recordsHistory in [true, false] {
            let state = ReaderState(recordsHistory: false)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 400),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            state.window = window
            defer { state.windowClosed(); window.close() }
            var created = [WindowPayload]()
            let receive: ([URL]) -> Void = { selected in
                ReaderWindows.open(selected, in: state, recordsHistory: recordsHistory) { created.append($0) }
            }
            // The picker holds this reader even after its native close callback.
            state.windowClosed()
            let selected = recordsHistory ? urls : Array(urls.prefix(1))
            receive(selected)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(created.map(\.path), selected.map(\.path))
            XCTAssertTrue(created.allSatisfy { $0.recordsHistory == (recordsHistory ? nil : false) })
            XCTAssertNil(state.document, "A delayed picker must not load into a reader with no window")
            XCTAssertFalse(state.busy)
        }
        var created = [WindowPayload]()
        ReaderWindows.open(urls, in: nil) { created.append($0) }
        XCTAssertEqual(created.map(\.path), urls.map(\.path))
    }

    @MainActor
    func testFilePickerReusesLiveWindowAndCancellationKeepsItsDocument() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableHistory")
        let history = defaults.object(forKey: "documentOpenHistory")
        let recent = NSDocumentController.shared.recentDocumentURLs
        defaults.set(true, forKey: "disableHistory")
        defer {
            ReaderFiles.setRecent(recent)
            defaults.set(history, forKey: "documentOpenHistory")
            defaults.set(previous, forKey: "disableHistory")
        }
        let directory = try TemporaryDirectory()
        let urls = ["First.txt", "Second.txt"].map { directory.url.appendingPathComponent($0) }
        for url in urls { try "Live picker fixture".write(to: url, atomically: true, encoding: .utf8) }
        let state = ReaderState(recordsHistory: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window
        defer { state.windowClosed(); window.close(); withExtendedLifetime(directory) {} }
        var created = [WindowPayload]()
        ReaderWindows.open(urls, in: state) { created.append($0) }
        let deadline = Date().addingTimeInterval(3)
        while state.document == nil, state.error == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state.document?.url, urls.first)
        XCTAssertEqual(created.map(\.path), [urls[1].path])
        XCTAssertNil(created.first?.recordsHistory, "New ordinary windows must honor the app's history preference")
        let id = state.document?.id
        ReaderWindows.open([], in: state) { created.append($0) }
        XCTAssertEqual(state.document?.id, id)
        XCTAssertEqual(created.count, 1)
        defaults.set(false, forKey: "disableHistory")
        ReaderWindows.open([urls[1]], in: state, recordsHistory: false) { created.append($0) }
        let privateDeadline = Date().addingTimeInterval(3)
        while state.document?.url != urls[1], state.error == nil, Date() < privateDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state.document?.url, urls[1])
        XCTAssertFalse(state.recordsDocumentHistory)
        XCTAssertEqual(created.count, 1)
    }

    @MainActor
    func testFinderOpenWaitsForReaderWindowAndDoesNotReuseAClosedWindow() async throws {
        let app = NSApplication.shared
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableHistory")
        defaults.set(true, forKey: "disableHistory")
        defer { defaults.set(previous, forKey: "disableHistory") }
        let directory = try TemporaryDirectory(), url = directory.url.appendingPathComponent("opening.txt")
        try "Finder opening fixture".write(to: url, atomically: true, encoding: .utf8)
        for windowFirst in [false, true] {
            let delegate = ReaderApplicationDelegate(), state = ReaderState(recordsHistory: false)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 400),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { state.windowClosed(); window.close(); withExtendedLifetime(directory) {} }
            var created = [WindowPayload]()
            delegate.application(app, open: [url])
            if windowFirst { state.window = window }
            else { state.createWindow = { created.append($0) } }
            delegate.connect(state, canReuse: true)
            XCTAssertTrue(created.isEmpty, "The initial Home must be ready before pending files are dispatched")
            XCTAssertNil(state.document)
            state.window = window
            state.createWindow = { created.append($0) }
            delegate.connect(state, canReuse: true)
            let deadline = Date().addingTimeInterval(3)
            while state.document == nil, state.error == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(state.document?.url, url)
            XCTAssertTrue(created.isEmpty, "Opening the initial file must reuse Home, not leave another empty tab")
            // Register an empty reader, then deliver another file after its
            // close notification but before AppKit detaches the content view.
            state.windowClosed()
            state.window = window
            delegate.connect(state, canReuse: true)
            state.windowClosed()
            delegate.application(app, open: [url])
            XCTAssertEqual(created.map(\.path), [url.path], "A closed window must not consume a new file request")
        }
    }

    @MainActor
    func testCloseGuardKeepsForwardedWindowDelegateAliveUntilDetached() throws {
        _ = NSApplication.shared
        final class Delegate: NSObject, NSWindowDelegate {
            var resizes = 0
            func windowDidResize(_ notification: Notification) { resizes += 1 }
            func windowShouldClose(_ sender: NSWindow) -> Bool { false }
        }
        weak var observed: Delegate?
        weak var observedWindow: NSWindow?
        weak var observedProxy: ReaderCloseGuard?
        try autoreleasepool {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            observedWindow = window
            defer { window.delegate = nil; window.close() }
            var original: Delegate? = Delegate()
            observed = original
            var proxy: ReaderCloseGuard? = ReaderCloseGuard(state: nil, previous: original)
            observedProxy = proxy
            window.delegate = proxy
            original = nil
            // NSWindow registers delegate notification methods when assigning it.
            // Their forwarding target must survive even if its old owner releases it.
            _ = try XCTUnwrap(observed)
            window.setContentSize(NSSize(width: 340, height: 240))
            XCTAssertGreaterThan(observed?.resizes ?? 0, 0)
            XCTAssertEqual(proxy?.windowShouldClose(window), false)
            window.delegate = proxy?.previous
            proxy = nil
        }
        XCTAssertNil(observed, "Detaching the close guard must release its previous delegate")
        XCTAssertNil(observedProxy)
        XCTAssertNil(observedWindow)
    }

    @MainActor
    func testCloseCommandUsesWindowApprovalAndAlsoClosesAnEmptyWindow() {
        _ = NSApplication.shared
        final class CloseDelegate: NSObject, NSWindowDelegate {
            var allow = false, requests = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return allow }
        }
        let state = ReaderState(recordsHistory: false), approval = CloseDelegate()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = approval
        state.window = window
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/close-window.txt"), content: .text("Keep until approved"))
        window.orderFront(nil)
        defer { window.delegate = nil; window.close(); state.windowClosed() }
        let documentID = state.document?.id
        ReaderMenuCommand.close.run(state)
        XCTAssertEqual(approval.requests, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(state.document?.id, documentID, "A rejected window close must not clear its document")
        approval.allow = true
        ReaderMenuCommand.close.run(state)
        XCTAssertEqual(approval.requests, 2)
        XCTAssertFalse(window.isVisible)

        state.document = nil
        window.orderFront(nil)
        XCTAssertTrue(ReaderMenuCommand.close.enabled(state), "Home windows still need a Close command")
        ReaderMenuCommand.close.run(state)
        XCTAssertEqual(approval.requests, 3)
        XCTAssertFalse(window.isVisible)
    }

    private func requireMuPDF() throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF engine must be built before native integration tests")
        }
    }

    @MainActor
    func testDiscardDialogsDoNotActOnAReplacementDocument() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        func document(_ name: String) throws -> ReadingDocument {
            let pdf = PDFDocument(), page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            pdf.insert(page, at: 0)
            let url = directory.url.appendingPathComponent(name + ".pdf")
            try XCTUnwrap(pdf.dataRepresentation()).write(to: url)
            return try ReadingDocument.open(url)
        }
        let original = try document("Original"), replacement = try document("Replacement")
        let bytes = try Data(contentsOf: replacement.url)
        let state = ReaderState(recordsHistory: false)
        let replaceDocument: @MainActor @Sendable () -> Void = { state.document = replacement }
        defer { state.modified = false; state.windowClosed() }
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn] {
            state.document = original; state.modified = true
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated {
                    replaceDocument()
                    NSApplication.shared.stopModal(withCode: response)
                }
            }
            let allowed = await state.confirmClose()
            XCTAssertFalse(allowed)
            XCTAssertEqual(state.document?.id, replacement.id)
            XCTAssertTrue(state.modified)
            XCTAssertEqual(try Data(contentsOf: replacement.url), bytes)
        }
        state.document = original; state.modified = true
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                replaceDocument()
                NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
            }
        }
        state.discardChanges()
        XCTAssertEqual(state.document?.id, replacement.id)
        XCTAssertTrue(state.modified)
        XCTAssertFalse(state.busy, "An old confirmation must not start reloading its previous document")
    }

    @MainActor
    func testNativeCloseSaveWritesCurrentDocumentWithoutStartingAReload() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableReadingState")
        defaults.set(true, forKey: "disableReadingState")
        defer { defaults.set(previous, forKey: "disableReadingState"); withExtendedLifetime(directory) {} }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 60, height: 40), forType: .square, withProperties: nil)
        annotation.contents = "original"; page.addAnnotation(annotation); pdf.insert(page, at: 0)
        let bytes = try XCTUnwrap(pdf.dataRepresentation())
        for suffix in ["pdf", "ai", "txt", "p7m"] {
            let source = directory.url.appendingPathComponent("native-close." + suffix)
            try bytes.write(to: source)
            let reading = try ReadingDocument.open(source)
            guard case .pages(let pages) = reading.content, pages.isPDF else { return XCTFail("Expected direct PDF: " + suffix) }
            try await pages.pdfSetEditing(true)
            let annotations = try await pages.pdfAnnotations(0)
            let id = try XCTUnwrap(annotations.first).id
            try await pages.pdfEditAnnotation(page: 0, id: id, edits: [.contents("saved from the live document")])
            let state = ReaderState(recordsHistory: false)
            state.document = reading
            defer { state.windowClosed() }
            XCTAssertTrue(state.canSave, "Direct PDF content must allow in-place Save regardless of its extension: " + suffix)
            guard state.canSave else { continue }
            try await state.nativePDFDidChange(pages)
            let generation = state.generation
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated { NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn) }
            }
            let allowed = await state.confirmClose()
            XCTAssertTrue(allowed)
            XCTAssertFalse(state.modified)
            XCTAssertFalse(state.busy)
            XCTAssertEqual(state.document?.id, reading.id)
            XCTAssertEqual(state.generation, generation, "Close approval must not start a competing reload")
            let reopened = try NativeFile(source, engine: .mupdf)
            XCTAssertEqual(try reopened.pdfAnnotations(0).first?.contents, "saved from the live document")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).contains { $0.hasPrefix(".Sumra-save-") })
        }
    }

    @MainActor
    func testHomeHistoryRanksFrequencyAgesCountsAndKeepsPinsFirst() throws {
        try withIsolatedFileHistory {
            let directory = try TemporaryDirectory()
            let a = directory.url.appendingPathComponent("Alpha.txt"), b = directory.url.appendingPathComponent("Zulu.txt")
            try Data("Alpha".utf8).write(to: a)
            try Data("Zulu".utf8).write(to: b)
            let first = ReadingDocument(url: a, content: .text("Alpha")), second = ReadingDocument(url: b, content: .text("Zulu"))
            let date = Date(timeIntervalSinceReferenceDate: 1_200 * 604_800 + 120)
            for _ in 0..<4 { ReaderFiles.recordOpen(first, recordsHistory: true, at: date) }
            ReaderFiles.recordOpen(second, recordsHistory: true, at: date.addingTimeInterval(1))
            XCTAssertEqual(ReaderFiles.recent, [b, a])
            XCTAssertEqual(ReaderFiles.ordered(frequentlyRead: true, at: date), [a, b])
            // Frequent documents remain available after dropping out of the OS recent menu.
            ReaderFiles.setRecent([b])
            XCTAssertEqual(ReaderFiles.ordered(frequentlyRead: true, at: date), [a, b])
            ReaderFiles.pin(a)
            ReaderFiles.pin(b)
            XCTAssertEqual(ReaderFiles.recent, [a, b], "Pinned names use natural alphabetical order")
            ReaderFiles.pin(a)
            XCTAssertEqual(ReaderFiles.ordered(frequentlyRead: true, at: date), [b, a])
            ReaderFiles.pin(b)
            let later = date.addingTimeInterval(3 * 604_800)
            ReaderFiles.recordOpen(second, recordsHistory: true, at: later)
            XCTAssertEqual(ReaderFiles.ordered(frequentlyRead: true, at: later), [b, a], "Old frequency must age out")

            let renamed = directory.url.appendingPathComponent("Renamed.txt")
            try FileManager.default.moveItem(at: b, to: renamed)
            ReaderFiles.replaceHistory(b, with: renamed)
            XCTAssertEqual(ReaderFiles.ordered(frequentlyRead: true, at: later), [renamed, a])
            ReaderFiles.forget(renamed)
            XCTAssertEqual(ReaderFiles.recent, [a])
            ReaderFiles.recordOpen(ReadingDocument(url: renamed, content: .text("Zulu")), recordsHistory: true, at: later)
            ReaderFiles.pin(renamed)
            try FileManager.default.removeItem(at: renamed)
            ReaderFiles.removeMissing()
            XCTAssertEqual(ReaderFiles.recent, [a])
            XCTAssertFalse(ReaderFiles.pinned.contains(renamed.path))
            ReaderFiles.pin(a)
            ReaderWindows.save([WindowPayload(path: a.path)], key: "closedDocuments")
            ReaderFiles.clearHistory()
            XCTAssertEqual(ReaderFiles.recent, [a], "Clear history preserves an explicitly pinned document")
            XCTAssertTrue(ReaderWindows.saved("closedDocuments").isEmpty)
            ReaderFiles.pin(a)
            XCTAssertTrue(ReaderFiles.recent.isEmpty, "Cleared frequency records must not repopulate history")
        }
    }

    @MainActor
    func testOpenHistoryOmitsPrivateDisabledAndTemporarySources() throws {
        try withIsolatedFileHistory {
            let directory = try TemporaryDirectory(), url = directory.url.appendingPathComponent("Source.txt")
            try Data("Source".utf8).write(to: url)
            let document = ReadingDocument(url: url, content: .text("Source"))
            ReaderFiles.recordOpen(document, recordsHistory: false)
            UserDefaults.standard.set(true, forKey: "disableHistory")
            ReaderFiles.recordOpen(document, recordsHistory: true)
            UserDefaults.standard.set(false, forKey: "disableHistory")
            var temporary = document
            temporary.sourceTemporary = directory
            ReaderFiles.recordOpen(temporary, recordsHistory: true)
            XCTAssertTrue(ReaderFiles.recent.isEmpty)
            XCTAssertTrue(NSDocumentController.shared.recentDocumentURLs.isEmpty)
            XCTAssertNil(UserDefaults.standard.data(forKey: "documentOpenHistory"))
            // An internal conversion directory is not a temporary input document.
            let converted = ReadingDocument(url: url, content: .text("Source"), temporary: directory)
            ReaderFiles.recordOpen(converted, recordsHistory: true)
            XCTAssertEqual(ReaderFiles.recent, [url])
        }
    }

    @MainActor
    func testHistoryTreatsSymlinkAliasesAsOneFileWithoutChangingItsOpenedPath() throws {
        try withIsolatedFileHistory {
            let directory = try TemporaryDirectory(), files = directory.url.appendingPathComponent("Files")
            let link = directory.url.appendingPathComponent("Alias")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files)
            let source = files.appendingPathComponent("Book.txt"), alias = link.appendingPathComponent("Book.txt")
            let other = files.appendingPathComponent("Other.txt")
            try Data("Book".utf8).write(to: source)
            try Data("Other".utf8).write(to: other)
            let date = Date(timeIntervalSinceReferenceDate: 1_200 * 604_800 + 120)
            for url in [source, alias, other, other] {
                ReaderFiles.recordOpen(ReadingDocument(url: url, content: .text("Book")), recordsHistory: true, at: date)
            }
            ReaderFiles.recordOpen(ReadingDocument(url: alias, content: .text("Book")), recordsHistory: true, at: date)
            ReaderFiles.setRecent([other, source.resolvingSymlinksInPath()])
            let recent = ReaderFiles.recent
            XCTAssertEqual(recent.count, 2)
            XCTAssertEqual(Set(recent), Set([other, alias]), "Keep the opened alias used by reading-position storage")
            XCTAssertEqual(ReaderFiles.ordered(frequentlyRead: true, at: date), [alias, other], "All three opens of the same file contribute to frequency")

            ReaderFiles.pin(source)
            XCTAssertTrue(ReaderFiles.isPinned(alias))
            XCTAssertEqual(ReaderFiles.recent, [alias, other])
            ReaderFiles.pin(alias)
            XCTAssertTrue(ReaderFiles.pinned.isEmpty, "Pinning either alias toggles the same pin")
            ReaderFiles.pin(source)
            ReaderWindows.save([WindowPayload(path: source.path), WindowPayload(path: alias.path)], key: "closedDocuments")
            let renamed = files.appendingPathComponent("Renamed.txt")
            try FileManager.default.moveItem(at: source, to: renamed)
            ReaderFiles.replaceHistory(source, with: renamed)
            XCTAssertEqual(ReaderFiles.recent, [renamed, other])
            XCTAssertEqual(ReaderWindows.saved("closedDocuments").map(\.path), [renamed.path, renamed.path])

            let renamedAlias = link.appendingPathComponent("Renamed.txt")
            let positionKey = "position:" + renamed.path
            UserDefaults.standard.set(Data([1]), forKey: positionKey)
            defer { UserDefaults.standard.removeObject(forKey: positionKey) }
            ReaderFiles.forget(renamedAlias)
            XCTAssertEqual(ReaderFiles.recent, [other])
            XCTAssertTrue(ReaderFiles.pinned.isEmpty)
            XCTAssertTrue(ReaderWindows.saved("closedDocuments").isEmpty)
            XCTAssertNil(UserDefaults.standard.data(forKey: positionKey))
        }
    }

    @MainActor
    private func withIsolatedFileHistory(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard, recent = NSDocumentController.shared.recentDocumentURLs
        let keys = ["documentOpenHistory", "pinnedDocuments", "closedDocuments", "disableHistory"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            ReaderFiles.setRecent(recent)
            for (key, value) in previous { defaults.set(value, forKey: key) }
        }
        ReaderFiles.clearHistory()
        defaults.removeObject(forKey: "pinnedDocuments")
        defaults.set(false, forKey: "disableHistory")
        try body()
    }

    @MainActor
    func testTerminationKeepsSessionWindowsOutOfClosedDocumentHistory() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "closedDocuments")
        let historyDisabled = defaults.object(forKey: "disableHistory")
        let terminating = ReaderWindows.isTerminating
        defer {
            defaults.set(previous, forKey: "closedDocuments")
            defaults.set(historyDisabled, forKey: "disableHistory")
            ReaderWindows.isTerminating = terminating
        }
        defaults.removeObject(forKey: "closedDocuments")
        defaults.set(false, forKey: "disableHistory")
        let state = ReaderState()
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/books/restored.txt"), content: .text("Restored"))
        ReaderWindows.isTerminating = true
        ReaderWindows.rememberClosed(state)
        XCTAssertTrue(ReaderWindows.saved("closedDocuments").isEmpty)
        ReaderWindows.isTerminating = false
        ReaderWindows.rememberClosed(state)
        XCTAssertEqual(ReaderWindows.saved("closedDocuments").map(\.path), ["/books/restored.txt"])
    }

    @MainActor
    func testPostScriptEPSPJLAndGzipUseConverterAndReleaseTemporaryPDF() async throws {
        try requireMuPDF()
        guard ["/opt/homebrew/bin/gs", "/usr/local/bin/gs", "/usr/bin/gs"].contains(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Install Ghostscript before PostScript integration tests")
        }
        let directory = try TemporaryDirectory()
        let postscript = "%!PS-Adobe-3.0\n%%BoundingBox: 0 0 300 200\n/Helvetica findfont 18 scalefont setfont\n20 100 moveto (Sumra PostScript acceptance) show\nshowpage\n"
        for suffix in ["ps", "eps", "pjl", "ps.gz", "pdf"] {
            let source = directory.url.appendingPathComponent("reading." + suffix)
            let data = Data((suffix == "pjl" ? "\u{1B}%-12345X@PJL ENTER LANGUAGE = POSTSCRIPT\r\n" + postscript : postscript).utf8)
            if suffix == "ps.gz" {
                let plain = directory.url.appendingPathComponent("gzip-source.ps")
                try data.write(to: plain)
                XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
                let output = try FileHandle(forWritingTo: source)
                let gzip = Process(); gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                gzip.arguments = ["-c", plain.path]; gzip.standardOutput = output
                try gzip.run(); gzip.waitUntilExit(); try output.close()
                XCTAssertEqual(gzip.terminationStatus, 0)
            } else { try data.write(to: source) }
            let original = try Data(contentsOf: source)
            var reading: ReadingDocument? = try ReadingDocument.open(source)
            let temporary = try XCTUnwrap(reading?.temporary?.url)
            guard case .pages(let pdf) = reading?.content, pdf.isPDF else { return XCTFail("Expected converted PDF for \(suffix)") }
            let count = await pdf.count, text = try await pdf.text(0)
            let separateSource = reading!.hasSeparatePDFSource
            XCTAssertTrue(separateSource, suffix)
            let state = ReaderState(recordsHistory: false)
            state.document = reading
            XCTAssertFalse(state.canSave, "Converted content must not overwrite the original PostScript, even when named .pdf")
            state.document = nil
            state.windowClosed()
            XCTAssertEqual(count, 1)
            XCTAssertTrue(text.contains("Sumra PostScript acceptance"), suffix)
            try await pdf.pdfSetEditing(true)
            _ = try await pdf.pdfCreateAnnotation(page: 0, type: "Text", bounds: CGRect(x: 30, y: 40, width: 20, height: 20),
                                                 edits: [.contents("Converted PDF edit")])
            let originalCopy = directory.url.appendingPathComponent("original-copy." + suffix)
            let pdfCopy = directory.url.appendingPathComponent("converted-copy-" + suffix + ".pdf")
            try await reading!.saveCopy(to: originalCopy, originalFile: true)
            try await reading!.saveCopy(to: pdfCopy)
            XCTAssertEqual(try Data(contentsOf: originalCopy), original, suffix)
            let saved = try XCTUnwrap(PDFDocument(url: pdfCopy))
            XCTAssertTrue(saved.string?.contains("Sumra PostScript acceptance") == true, suffix)
            XCTAssertTrue(saved.page(at: 0)?.annotations.contains { $0.contents == "Converted PDF edit" } == true, suffix)
            let info = try await pdf.pdfInfo()
            XCTAssertEqual(info?.dirty, true, suffix)
            XCTAssertEqual(try Data(contentsOf: source), original)
            reading = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        }
        let broken = directory.url.appendingPathComponent("broken.ps")
        try Data("%!PS\nSumraUndefinedOperator\n".utf8).write(to: broken)
        XCTAssertThrowsError(try ReadingDocument.open(broken)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Ghostscript"))
        }
    }

    func testSaveSourceCopyAfterUnlinkPreservesOriginalBytes() throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("removed.txt")
        let original = Data(String(repeating: "Retained original bytes 世界\n", count: 50_000).utf8)
        try original.write(to: source)
        let reading = try ReadingDocument.open(source)
        try FileManager.default.removeItem(at: source)
        let copy = directory.url.appendingPathComponent("copy.txt")
        try reading.copySource(to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testOriginalFileCopyUsesCurrentPathAndKeepsTargetsOnFailure() async throws {
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.txt")
        defer { withExtendedLifetime(directory) {} }
        let original = Data("Opened original 世界\n".utf8), replacement = Data("Current source path 世界\n".utf8)
        try original.write(to: source)
        let reading = try ReadingDocument.open(source)
        let output = directory.url.appendingPathComponent("copy.txt")
        try Data("Existing destination".utf8).write(to: output)
        let sourceLink = directory.url.appendingPathComponent("source-link.txt")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        let linkedReading = try ReadingDocument.open(sourceLink)
        let independentCopy = directory.url.appendingPathComponent("independent-copy.txt")
        try await linkedReading.saveCopy(to: independentCopy)
        XCTAssertFalse(try independentCopy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
                       "Saving a source link must create an independent file, not another link to the source")
        try replacement.write(to: source, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: independentCopy), original)
        try await reading.saveCopy(to: output)
        XCTAssertEqual(try Data(contentsOf: output), replacement)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        let alias = directory.url.appendingPathComponent("alias.txt")
        try FileManager.default.linkItem(at: source, to: alias)
        do { try await reading.saveCopy(to: alias); XCTFail("A source alias cannot be overwritten") }
        catch { XCTAssertTrue(error.localizedDescription.contains("different location"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        try FileManager.default.removeItem(at: source)
        try await reading.saveCopy(to: output)
        XCTAssertEqual(try Data(contentsOf: output), original, "Only an absent source path uses the retained file")
        let targetFolder = directory.url.appendingPathComponent("existing-target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: false)
        let sentinel = targetFolder.appendingPathComponent("sentinel.txt")
        try replacement.write(to: sentinel)
        do { try await reading.saveCopy(to: targetFolder); XCTFail("A directory cannot be replaced by a file copy") }
        catch { XCTAssertTrue(error.localizedDescription.contains("directory"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: sentinel), replacement)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: source)
        try replacement.write(to: output)
        do { try await reading.saveCopy(to: output); XCTFail("A broken source path must report its read failure") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(try Data(contentsOf: output), replacement)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let sourceChild = source.appendingPathComponent("keep.txt")
        try original.write(to: sourceChild)
        do { try await reading.saveCopy(to: output); XCTFail("A replaced source directory must never be copied recursively") }
        catch { XCTAssertTrue(error.localizedDescription.contains("directory"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: output), replacement)
        XCTAssertEqual(try Data(contentsOf: sourceChild), original)
        let leftovers = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.hasPrefix(".Sumra-copy-") })
    }

    @MainActor
    func testPrintReplicaCopyPreservesContainerOrEditedPDF() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 200), for: .mediaBox)
        pdf.insert(page, at: 0)
        let bytes = try XCTUnwrap(pdf.dataRepresentation())
        var mop = Data("%MOP".utf8)
        for value in [1, 1, 20, bytes.count] {
            var word = UInt32(value).bigEndian
            withUnsafeBytes(of: &word) { mop.append(contentsOf: $0) }
        }
        mop.append(bytes)
        // A valid BOOKMOBI record table and version-4 Print Replica payload.
        var header = Data(repeating: 0, count: 16 + 228)
        func put(_ value: Int, at offset: Int, size: Int, in data: inout Data) {
            for index in 0..<size { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (size - index - 1))) }
        }
        put(1, at: 0, size: 2, in: &header); put(mop.count, at: 4, size: 4, in: &header)
        put(1, at: 8, size: 2, in: &header); put(4096, at: 10, size: 2, in: &header)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(228, at: 20, size: 4, in: &header); put(8, at: 24, size: 4, in: &header)
        put(4, at: 16 + 88, size: 4, in: &header)
        var container = Data(repeating: 0, count: 96)
        container.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
        put(2, at: 76, size: 2, in: &container)
        put(96, at: 78, size: 4, in: &container); put(96 + header.count, at: 86, size: 4, in: &container)
        container.append(header); container.append(mop)
        for (suffix, title) in [("azw4", ""), ("mobi", ""), ("mobi", "%PDF-1.7 guide"), ("prc", ""), ("azw", ""), ("azw3", "")] {
            var original = container
            if !title.isEmpty { original.replaceSubrange(0..<title.utf8.count, with: Data(title.utf8)) }
            let source = directory.url.appendingPathComponent("replica." + suffix)
            try original.write(to: source)
            let reading = try ReadingDocument.open(source)
            guard case .pages(let pages) = reading.content, pages.isPDF else { return XCTFail("Expected embedded PDF") }
            let separateSource = reading.hasSeparatePDFSource
            XCTAssertTrue(separateSource, suffix)
            let state = ReaderState(recordsHistory: false)
            state.document = reading
            XCTAssertFalse(state.canSave, "Save must preserve the Print Replica container")
            state.document = nil
            state.windowClosed()
            try await pages.pdfSetEditing(true)
            _ = try await pages.pdfCreateAnnotation(page: 0, type: "Text", bounds: CGRect(x: 30, y: 40, width: 20, height: 20),
                                                  edits: [.contents("Replica edit")])
            let before = try await pages.pdfInfo()
            let originalCopy = directory.url.appendingPathComponent("original." + suffix)
            let pdfCopy = directory.url.appendingPathComponent("replica-" + suffix + ".pdf")
            try await reading.saveCopy(to: originalCopy, originalFile: true)
            try await reading.saveCopy(to: pdfCopy)
            XCTAssertEqual(try Data(contentsOf: originalCopy), original, suffix)
            let saved = try XCTUnwrap(PDFDocument(url: pdfCopy))
            XCTAssertEqual(saved.pageCount, 1, suffix)
            XCTAssertEqual(saved.page(at: 0)?.annotations.first?.contents, "Replica edit", suffix)
            XCTAssertEqual(try Data(contentsOf: source), original, suffix)
            let after = try await pages.pdfInfo()
            XCTAssertEqual(after?.dirty, true, suffix)
            XCTAssertEqual(after?.undoPosition, before?.undoPosition, suffix)
            XCTAssertEqual(after?.undoSteps, before?.undoSteps, suffix)
        }
    }

    func testMarkupFileSwitchRetainsCurrentBytesAndEarlierSaveCopySnapshot() throws {
        let directory = try TemporaryDirectory()
        let a = directory.url.appendingPathComponent("A.md"), b = directory.url.appendingPathComponent("B.md")
        let aBytes = Data("# Original A\n".utf8), bBytes = Data("# Displayed B 世界\n".utf8)
        try aBytes.write(to: a); try bBytes.write(to: b)
        var reading = ReadingDocument(url: a, content: .browser(try MarkupSource(a)))
        let earlierSaveCopy = reading
        reading.retargetSource(to: b)
        XCTAssertEqual(reading.id, earlierSaveCopy.id)
        XCTAssertEqual(reading.url, b)
        try FileManager.default.removeItem(at: a); try FileManager.default.removeItem(at: b)
        let aCopy = directory.url.appendingPathComponent("A-copy.md"), bCopy = directory.url.appendingPathComponent("B-copy.md")
        try earlierSaveCopy.copySource(to: aCopy); try reading.copySource(to: bCopy)
        XCTAssertEqual(try Data(contentsOf: aCopy), aBytes)
        XCTAssertEqual(try Data(contentsOf: bCopy), bBytes)

        reading.retargetSource(to: directory.url.appendingPathComponent("missing.md"))
        let unavailableCopy = directory.url.appendingPathComponent("missing-copy.md")
        XCTAssertThrowsError(try reading.copySource(to: unavailableCopy), "An unavailable current file must never copy the previous file's bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailableCopy.path))
    }

    @MainActor
    func testMarkupFileSwitchSeparatesRestoredPositionsAndMovesTheFileWatcher() async throws {
        let directory = try TemporaryDirectory(), folder = directory.url.resolvingSymlinksInPath()
        let a = folder.appendingPathComponent("A.md"), b = folder.appendingPathComponent("B.md")
        try Data("# A\n".utf8).write(to: a); try Data("# B\n".utf8).write(to: b)
        let defaults = UserDefaults.standard, keys = ["disableReadingState", "useFixedPageUI", "disableHistory", "documentOpenHistory"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        let state = ReaderState()
        defer {
            state.windowClosed()
            ReaderFiles.setRecent(recent)
            for (key, value) in previous { defaults.set(value, forKey: key) }
            for url in [a, b] { defaults.removeObject(forKey: "position:" + url.path) }
        }
        defaults.set(false, forKey: "disableReadingState"); defaults.set(false, forKey: "useFixedPageUI")
        defaults.set(false, forKey: "disableHistory")
        state.open(a)
        try await waitUntilIdle(state)
        XCTAssertNil(state.error)
        guard case .browser(let source as MarkupSource) = state.document?.content else { return XCTFail("Expected opened browser source") }
        state.count = source.pages.count
        let originalID = try XCTUnwrap(state.document?.id)
        let from = ReadingPosition(page: 0, x: 4, y: 50, anchor: source.pages[0].absoluteString)
        let target = ReadingPosition(page: 1, x: 9, y: 90, anchor: source.pages[1].absoluteString)
        state.updatePosition(from)
        state.restore(target)
        let savedA = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: "position:" + a.path)))
        XCTAssertEqual(savedA.y, from.y)
        XCTAssertNil(state.filePosition)
        state.persist() // A close or another action can persist before WebKit is ready.
        let pendingA = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: "position:" + a.path)))
        XCTAssertEqual(pendingA, savedA)
        let lastTarget = ReadingPosition(page: 1, x: 12, y: 190, anchor: target.anchor)
        state.restore(lastTarget)
        XCTAssertNil(state.filePosition)
        state.persist()
        state.didDisplayMarkupFile(b)
        XCTAssertEqual(state.document?.url, b)
        XCTAssertEqual(state.document?.id, originalID, "Switching source files must preserve the browser owner")
        let unchangedA = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: "position:" + a.path)))
        XCTAssertEqual(unchangedA, savedA, "Restoring B must not write its coordinates under A")
        state.persist()
        let savedB = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: "position:" + b.path)))
        XCTAssertNil(savedB.anchor)
        XCTAssertEqual(savedB.page, 0)
        XCTAssertNil(savedB.pageCount)
        XCTAssertEqual(savedB.x, lastTarget.x)
        XCTAssertEqual(savedB.y, lastTarget.y)

        try Data("# Changed A\n".utf8).write(to: a)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(state.document?.id, originalID, "The previous file must no longer trigger a reload")
        XCTAssertEqual(state.status, "")
        try Data("# Changed B\n".utf8).write(to: b)
        let deadline = Date().addingTimeInterval(3)
        while state.document?.id == originalID, Date() < deadline, state.error == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(state.error)
        XCTAssertNotEqual(state.document?.id, originalID, "The currently displayed file must trigger the existing reload owner")
        XCTAssertEqual(state.document?.url, b)
        XCTAssertNil(state.currentPosition.anchor, "Reloaded source positions must not retain the previous model's virtual URL")
        XCTAssertEqual(state.currentPosition.y, lastTarget.y)
    }

    @MainActor
    func testNestedMarkupFilePositionRestoresWithinTheNewSourceRoot() async throws {
        let directory = try TemporaryDirectory(), root = directory.url.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("A.md"), b = folder.appendingPathComponent("B.md")
        for url in [a, folder.appendingPathComponent("A.md"), b] { try Data("# Topic\n".utf8).write(to: url) }
        let defaults = UserDefaults.standard, keys = ["disableReadingState", "useFixedPageUI"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        let state = ReaderState(), source = try MarkupSource(a)
        defer {
            state.windowClosed()
            for (key, value) in previous { defaults.set(value, forKey: key) }
            for url in [a, b] { defaults.removeObject(forKey: "position:" + url.path) }
        }
        defaults.set(false, forKey: "disableReadingState"); defaults.set(false, forKey: "useFixedPageUI")
        state.document = ReadingDocument(url: a, content: .browser(source)); state.count = source.pages.count
        let index = try XCTUnwrap(source.pages.firstIndex { (try? source.fileURL($0)) == b })
        state.didDisplayMarkupFile(b)
        state.updatePosition(.init(page: index, x: 7, y: 400, anchor: source.pages[index].absoluteString))
        state.zoom = 1.25; state.fit = "custom"
        let saved = try XCTUnwrap(state.filePosition)
        XCTAssertNil(saved.anchor); XCTAssertEqual(saved.page, 0); XCTAssertNil(saved.pageCount)
        XCTAssertEqual(saved.x, 7); XCTAssertEqual(saved.y, 400); XCTAssertEqual(saved.zoom, 1.25)
        XCTAssertEqual(state.currentPosition.anchor, source.pages[index].absoluteString, "In-session history keeps its source-root target")

        state.openBookmark(.init(title: "Nested topic", path: b.path, position: saved))
        XCTAssertEqual(state.currentPosition.page, index)
        XCTAssertEqual(state.currentPosition.anchor, source.pages[index].absoluteString)
        XCTAssertEqual(state.currentPosition.y, 400)
        state.reload()
        try await waitUntilIdle(state)
        XCTAssertNil(state.error)
        guard case .browser(let reopened as MarkupSource) = state.document?.content else { return XCTFail("Expected reloaded browser source") }
        XCTAssertEqual(reopened.root, folder)
        XCTAssertEqual(try reopened.fileURL(reopened.startURL), b)
        XCTAssertNil(state.currentPosition.anchor)
        XCTAssertEqual(state.currentPosition.page, 0)
        XCTAssertEqual(state.currentPosition.x, 7); XCTAssertEqual(state.currentPosition.y, 400)
        XCTAssertEqual(state.zoom, 1.25)
        // The browser chooses the opened file, which need not be the first sibling.
        let reopenedIndex = try XCTUnwrap(reopened.pageIndex(reopened.startURL))
        XCTAssertGreaterThan(reopenedIndex, 0)
        state.count = reopened.pages.count
        var displayed = state.currentPosition
        displayed.page = reopenedIndex; displayed.anchor = reopened.startURL.absoluteString
        state.updatePosition(displayed)
        XCTAssertEqual(try XCTUnwrap(state.filePosition), saved)

        let identity = state.document?.id, beforeFailure = state.currentPosition
        try FileManager.default.removeItem(at: b)
        state.reload()
        try await waitUntilIdle(state)
        XCTAssertNotNil(state.error)
        XCTAssertEqual(state.document?.id, identity)
        XCTAssertEqual(state.currentPosition, beforeFailure, "A failed reload must keep the displayed document's coordinates")
    }

    @MainActor
    func testMarkupBookmarkCommandsUseCurrentFileOffsets() throws {
        let directory = try TemporaryDirectory(), root = directory.url.resolvingSymlinksInPath()
        let a = root.appendingPathComponent("A.md"), b = root.appendingPathComponent("B.md")
        try Data("# A\n".utf8).write(to: a); try Data("# B\n".utf8).write(to: b)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "bookmarks")
        let state = ReaderState(), source = try MarkupSource(a)
        defer {
            state.windowClosed(); defaults.set(previous, forKey: "bookmarks")
            for url in [a, b] { defaults.removeObject(forKey: "position:" + url.path) }
        }
        state.document = ReadingDocument(url: a, content: .browser(source)); state.count = source.pages.count
        let index = try XCTUnwrap(source.pageIndex(source.pages[1]))
        state.didDisplayMarkupFile(b)
        state.updatePosition(.init(page: index, x: 0, y: 200, anchor: source.pages[index].absoluteString))
        let current = try XCTUnwrap(state.filePosition)
        var earlier = current, later = current
        earlier.y = 100; later.y = 300
        let first = ReaderBookmark(title: "Earlier", path: b.path, position: earlier)
        let middle = ReaderBookmark(title: "Current", path: b.path, position: current)
        let last = ReaderBookmark(title: "Later", path: b.path, position: later)
        state.bookmarks = [last, middle, first]; state.bookmarksByName = false
        XCTAssertEqual(state.sortedBookmarks.map(\.id), [first.id, middle.id, last.id])
        state.toggleBookmark()
        XCTAssertEqual(state.bookmarks.map(\.id), [last.id, first.id], "Toggle must remove the existing file position, not open Add Bookmark")
        state.moveBookmark(1)
        XCTAssertEqual(state.currentPosition.y, 300)
        XCTAssertEqual(state.currentPosition.page, index)
        XCTAssertEqual(state.currentPosition.anchor, source.pages[index].absoluteString)
        state.moveBookmark(-1)
        XCTAssertEqual(state.currentPosition.y, 100)
        state.moveBookmark(-1)
        XCTAssertEqual(state.currentPosition.y, 300, "Previous wraps within this file's saved positions")
    }

    @MainActor
    func testMarkdownBookmarksUsePassagesAndRetainLegacyOrdering() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), file = directory.url.resolvingSymlinksInPath().appendingPathComponent("Book.md")
        try Data("# Book\n\nText\n".utf8).write(to: file)
        let defaults = UserDefaults.standard, oldBookmarks = defaults.object(forKey: "bookmarks"), oldFormats = defaults.object(forKey: "formatDefaults")
        let state = ReaderState(), source = try MarkupSource(file)
        defer {
            state.windowClosed(); defaults.set(oldBookmarks, forKey: "bookmarks"); defaults.set(oldFormats, forKey: "formatDefaults")
            defaults.removeObject(forKey: "position:" + file.path)
        }
        state.document = ReadingDocument(url: file, content: .browser(source)); state.count = source.pages.count
        let early = MarkdownPassage(path: [2, 0], offset: 5, top: 15, text: "Earlier", end: false)
        let middle = MarkdownPassage(path: [4, 0], offset: 2, top: 15, text: "Middle", end: false)
        let end = MarkdownPassage(path: [], offset: 0, top: 0, text: "", end: true)
        let a = ReaderBookmark(title: "Earlier", path: file.path, position: .init(x: 0, y: 300, markdownPassage: early))
        let b = ReaderBookmark(title: "Middle", path: file.path, position: .init(x: 0, y: 100, markdownPassage: middle))
        let c = ReaderBookmark(title: "End", path: file.path, position: .init(x: 0, y: 0, markdownPassage: end))
        state.bookmarks = [c, b, a]; state.bookmarksByName = false
        XCTAssertEqual(state.sortedBookmarks.map(\.id), [a.id, b.id, c.id], "Reflowed pixel offsets cannot reverse semantic document order")
        var changedMiddle = middle; changedMiddle.top = 23
        state.updatePosition(.init(x: 0, y: 900, anchor: source.startURL.absoluteString, markdownPassage: changedMiddle))
        state.toggleBookmark()
        XCTAssertEqual(state.bookmarks.map(\.id), [c.id, a.id], "The same passage toggles despite changed pixel and viewport offsets")
        state.bookmarks = [c, b, a]
        state.moveBookmark(1); XCTAssertEqual(state.currentPosition.markdownPassage, end)
        state.moveBookmark(-1); XCTAssertEqual(state.currentPosition.markdownPassage, middle)
        state.moveBookmark(-1); XCTAssertEqual(state.currentPosition.markdownPassage, early)
        state.moveBookmark(-1); XCTAssertEqual(state.currentPosition.markdownPassage, end, "Previous wraps in semantic document order")
        var changedEnd = end; changedEnd.path = [100, 0]; changedEnd.offset = 99; changedEnd.top = 42
        state.updatePosition(.init(x: 0, y: 1000, anchor: source.startURL.absoluteString, markdownPassage: changedEnd))
        state.toggleBookmark(); XCTAssertEqual(state.bookmarks.map(\.id), [b.id, a.id], "End identity survives changes to the viewport-top caret")
        let legacy = ReaderBookmark(title: "Legacy", path: file.path, position: .init(x: 0, y: 50))
        state.bookmarks = [a, legacy, b, c]
        XCTAssertEqual(state.sortedBookmarks.map(\.id), [c.id, legacy.id, b.id, a.id], "One legacy bookmark selects coordinate ordering for the entire file")
        state.updatePosition(.init(x: 0, y: 100, anchor: source.startURL.absoluteString, markdownPassage: middle))
        state.moveBookmark(1); XCTAssertEqual(state.currentPosition.markdownPassage, early)
        state.moveBookmark(-1); XCTAssertEqual(state.currentPosition.markdownPassage, middle)
        state.saveFormatDefaults()
        let formats = try JSONDecoder().decode([String: ReadingPosition].self, from: Data(try XCTUnwrap(defaults.string(forKey: "formatDefaults")).utf8))
        XCTAssertNil(try XCTUnwrap(formats[Format.markdown.rawValue]).markdownPassage, "Format defaults must not contain one file's passage")
    }

    func testTemporaryInputSurvivesDuplicatePayloadUntilLastOwnerCloses() throws {
        var directory: TemporaryDirectory? = try TemporaryDirectory()
        let root = try XCTUnwrap(directory?.url), file = root.appendingPathComponent("attachment.txt")
        try Data("embedded text".utf8).write(to: file)
        var reading: ReadingDocument? = .init(url: file, content: .text("embedded text"))
        reading?.sourceTemporary = directory
        var duplicate: WindowPayload? = .init(path: file.path, temporary: directory, recordsHistory: false)
        directory = nil
        XCTAssertNotNil(reading?.sourceTemporary)
        reading = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(duplicate?.temporary?.url, root)
        duplicate = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testTemporarySceneCopiesReleaseTheirPendingLeaseAfterDocumentHandoff() throws {
        var directory: TemporaryDirectory? = try TemporaryDirectory()
        let root = try XCTUnwrap(directory?.url), file = root.appendingPathComponent("attachment.txt")
        try Data("embedded text".utf8).write(to: file)
        var originalRequest: WindowPayload? = .init(path: file.path, temporary: directory, recordsHistory: false)
        var sceneValue = try XCTUnwrap(originalRequest)
        // A second window request owns a separate pending handoff for the same file.
        var duplicateRequest: WindowPayload? = .init(path: file.path, temporary: directory, recordsHistory: false)
        var reading: ReadingDocument? = .init(url: file, content: .text("embedded text"))
        reading?.sourceTemporary = sceneValue.temporary
        directory = nil
        sceneValue.temporary = nil
        XCTAssertNil(originalRequest?.temporary, "Copies of the same scene request must release their pending lease together")
        XCTAssertNotNil(duplicateRequest?.temporary, "Another window's pending input must stay readable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        duplicateRequest = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The loaded document still owns its input")
        reading = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "An inactive retained scene value must not keep temporary files")
        originalRequest = nil
    }

    func testWindowRestorationOmitsPrivateAndTemporaryPaths() throws {
        let directory = try TemporaryDirectory()
        for payload in [WindowPayload(path: "/private/document.pdf", position: .init(page: 8), recordsHistory: false),
                        WindowPayload(path: directory.url.appendingPathComponent("clipboard.png").path, temporary: directory)] {
            let data = try JSONEncoder().encode(payload)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(values["path"])
            XCTAssertNil(values["position"])
            XCTAssertNil(try JSONDecoder().decode(WindowPayload.self, from: data).path)
        }
        let regular = WindowPayload(path: "/books/book.pdf", position: .init(page: 8))
        let restored = try JSONDecoder().decode(WindowPayload.self, from: JSONEncoder().encode(regular))
        XCTAssertEqual(restored.path, regular.path)
        XCTAssertEqual(restored.position?.page, 8)
    }

    func testCompressedFB2UsesExtractedXMLWithoutReplacingArchive() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before compressed FB2 integration tests") }
        let directory = try TemporaryDirectory()
        let xml = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Archive Fixture</book-title><lang>en</lang></title-info></description><body><section><title><p>Chapter One</p></title><p>Compressed FB2 retained text.</p></section></body></FictionBook>
        """.utf8)
        try xml.write(to: directory.url.appendingPathComponent("story.fb2"))
        let archive = directory.url.appendingPathComponent("story.fb2z")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory.url
        process.arguments = ["-q", archive.path, "story.fb2"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let original = try Data(contentsOf: archive)
        let reading = try ReadingDocument.open(archive)
        guard case .pages(let pages) = reading.content else { return XCTFail("FB2 should use the existing MuPDF renderer") }
        XCTAssertNotNil(reading.temporary)
        let text = try await pages.text(0)
        XCTAssertTrue(text.contains("Compressed FB2 retained text"))
        XCTAssertEqual(try Data(contentsOf: archive), original)
        withExtendedLifetime(reading) {}
    }
    private func fixture(_ text: String, extension ext: String = "txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sumra-test-" + UUID().uuidString + "." + ext)
        try Data(text.utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            for prefix in ["position:", "bookmark:"] {
                UserDefaults.standard.removeObject(forKey: prefix + url.standardizedFileURL.path)
            }
        }
        return url
    }

    @MainActor
    private func waitUntilIdle(_ state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        while state.busy, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.busy, "Document loading did not finish")
    }

    func testSameURLProducesNewDocumentIdentityAndContent() throws {
        let url = try fixture("old")
        let old = try ReadingDocument.open(url)
        try Data("new".utf8).write(to: url, options: .atomic)
        let new = try ReadingDocument.open(url)
        XCTAssertEqual(old.url, new.url)
        XCTAssertNotEqual(old.id, new.id)
        guard case .text(let content) = new.content else { return XCTFail("Expected text") }
        XCTAssertEqual(content, "new")
    }

    func testMalformedPDFIsRejectedBeforeReplacingTheReader() throws {
        try requireMuPDF()
        let url = try fixture("%PDF-1.7\nnot a PDF document", extension: "pdf")
        XCTAssertThrowsError(try ReadingDocument.open(url))
    }

    @MainActor
    func testPDFContentContainsTheParsedDocument() async throws {
        try requireMuPDF()
        let url = try fixture("", extension: "pdf")
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        pdf.insert(page, at: 0)
        try XCTUnwrap(pdf.dataRepresentation()).write(to: url)
        let opened = try ReadingDocument.open(url)
        guard case .pages(let parsed) = opened.content, parsed.isPDF else { return XCTFail("Expected native PDF") }
        let info = try await parsed.pdfInfo(), bounds = try await parsed.bounds(0)
        XCTAssertEqual(info?.pageCount, 1)
        XCTAssertEqual(bounds.size, CGSize(width: 300, height: 400))
        XCTAssertEqual(info?.editingEnabled, false)
        XCTAssertEqual(opened.settingsFormat, "pdf")
    }

    @MainActor
    func testReloadReplacesContentButKeepsReadingSettings() async throws {
        let url = try fixture("one\ntwo\nthree")
        let state = ReaderState()
        defer { state.close() }
        state.open(url)
        try await waitUntilIdle(state)
        let old = try XCTUnwrap(state.document)
        state.page = 1
        state.zoom = 1.75
        state.fit = "custom"
        state.rotation = 90
        state.fontSize = 23
        state.recordNavigation()
        state.presentation = true
        state.presentationBlank = "black"
        state.laserPointer = true
        state.findQuery = "two"
        state.selectedText = "two"
        state.hasSelection = true
        try Data("one\nchanged\nthree".utf8).write(to: url, options: .atomic)
        state.reload()
        try await waitUntilIdle(state)
        let new = try XCTUnwrap(state.document)
        XCTAssertNotEqual(new.id, old.id)
        guard case .text(let content) = new.content else { return XCTFail("Expected text") }
        XCTAssertEqual(content, "one\nchanged\nthree")
        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.zoom, 1.75)
        XCTAssertEqual(state.fit, "custom")
        XCTAssertEqual(state.rotation, 90)
        XCTAssertEqual(state.fontSize, 23)
        XCTAssertTrue(state.canNavigateBack)
        XCTAssertTrue(state.presentation)
        XCTAssertEqual(state.presentationBlank, "black")
        XCTAssertTrue(state.laserPointer)
        XCTAssertTrue(state.findQuery.isEmpty)
        XCTAssertTrue(state.selectedText.isEmpty)
        XCTAssertFalse(state.hasSelection)
        XCTAssertEqual(state.command.action, .none)
    }

    @MainActor
    func testFileWatchFollowsAtomicReplacementsWithoutDiscardingPDFEdits() async throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("watched.pdf")
        func bytes(_ contents: String) throws -> Data {
            let pdf = PDFDocument(), page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 60, height: 40), forType: .square, withProperties: nil)
            annotation.contents = contents
            page.addAnnotation(annotation); pdf.insert(page, at: 0)
            return try XCTUnwrap(pdf.dataRepresentation())
        }
        try bytes("opened baseline").write(to: url)
        let state = ReaderState(recordsHistory: false)
        defer { state.modified = false; state.windowClosed(); withExtendedLifetime(directory) {} }
        state.openWithoutHistory(url)
        try await waitUntilIdle(state)
        let original = try XCTUnwrap(state.document)
        guard case .pages(let pages) = original.content, pages.isPDF else { return XCTFail("Expected native PDF") }
        state.setPDFEditingEnabled(true)
        try await waitUntilIdle(state)
        let annotations = try await pages.pdfAnnotations(0)
        let annotation = try XCTUnwrap(annotations.first)
        try await pages.pdfEditAnnotation(page: 0, id: annotation.id, edits: [.contents("local edit")])
        try await state.nativePDFDidChange(pages)
        XCTAssertTrue(state.modified)

        // Each atomic write replaces the watched inode. The open document must
        // keep its edits while observation follows the current pathname.
        for contents in ["first external replacement", "second external replacement"] {
            state.status = "waiting for replacement"
            try bytes(contents).write(to: url, options: .atomic)
            let deadline = Date().addingTimeInterval(3)
            while state.status == "waiting for replacement", Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(state.status, "File changed on disk; unsaved edits remain open")
            XCTAssertEqual(state.document?.id, original.id)
            XCTAssertTrue(state.modified)
            let current = try await pages.pdfAnnotations(0)
            XCTAssertEqual(current.first?.contents, "local edit")
        }

        try await state.changeNativePDFHistory(redo: false)
        XCTAssertFalse(state.modified)
        try bytes("latest external version").write(to: url, options: .atomic)
        let deadline = Date().addingTimeInterval(3)
        while state.document?.id == original.id, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(state.document?.id, original.id, "After Undo, the next disk change must reload the current file")
        try await waitUntilIdle(state)
        guard case .pages(let reloaded) = state.document?.content else { return XCTFail("Expected reloaded PDF") }
        let latest = try await reloaded.pdfAnnotations(0)
        XCTAssertEqual(latest.first?.contents, "latest external version")
        XCTAssertFalse(state.modified)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testReplacementClearsOldSelectionAndCommandsButKeepsPresentationMode() async throws {
        let first = try fixture("first document")
        let second = try fixture("second document")
        let state = ReaderState()
        defer { state.close() }
        state.openWithoutHistory(first)
        try await waitUntilIdle(state)
        state.recordNavigation()
        state.presentation = true
        state.presentationBlank = "white"
        state.laserPointer = true
        state.findQuery = "first"
        state.selectedText = "first document"
        state.hasSelection = true
        state.send(.copy)
        state.send(.turnPages(1))
        state.didHandleCommand(state.command.revision)

        state.openWithoutHistory(second, at: .init(page: 3, zoom: 1.5, fit: "custom"))
        try await waitUntilIdle(state)
        XCTAssertEqual(state.document?.url, second)
        XCTAssertEqual(state.page, 3)
        XCTAssertEqual(state.zoom, 1.5)
        XCTAssertFalse(state.canNavigateBack)
        XCTAssertTrue(state.presentation)
        XCTAssertEqual(state.presentationBlank, "white")
        XCTAssertTrue(state.laserPointer)
        XCTAssertTrue(state.findQuery.isEmpty)
        XCTAssertTrue(state.selectedText.isEmpty)
        XCTAssertFalse(state.hasSelection)
        XCTAssertEqual(state.command.action, .none)
        state.send(.selectAll)
        XCTAssertEqual(state.command.action, .selectAll, "Old acknowledgements must not strand the new reader's commands")
    }

    @MainActor
    func testClosingDocumentOrWindowReleasesDocumentInteractionState() async throws {
        let url = try fixture("selected document text")
        for closeWindow in [false, true] {
            let state = ReaderState()
            state.openWithoutHistory(url)
            try await waitUntilIdle(state)
            state.recordNavigation()
            state.presentation = true
            state.presentationBlank = "black"
            state.laserPointer = true
            state.findQuery = "selected"
            state.showFind = true
            state.showFitContentArea = true
            state.selectedText = "selected document text"
            state.hasSelection = true
            state.searchResults = [.init(title: "Match", target: "0")]
            state.logicalPageLabel = "old page"
            state.selectionScreenBounds = { CGRect(x: 10, y: 20, width: 30, height: 40) }
            state.browserTemporary = try TemporaryDirectory()
            let temporary = try XCTUnwrap(state.browserTemporary?.url)
            state.send(.copy)
            state.send(.turnPages(1))
            state.didHandleCommand(state.command.revision)

            if closeWindow { state.windowClosed() } else { state.close() }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            XCTAssertNil(state.document)
            XCTAssertTrue(state.findQuery.isEmpty)
            XCTAssertFalse(state.showFind)
            XCTAssertFalse(state.showFitContentArea)
            XCTAssertTrue(state.selectedText.isEmpty)
            XCTAssertFalse(state.hasSelection)
            XCTAssertTrue(state.searchResults.isEmpty)
            XCTAssertNil(state.logicalPageLabel)
            XCTAssertNil(state.selectionScreenBounds)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            XCTAssertEqual(state.command.action, .none)
            XCTAssertEqual(state.presentation, closeWindow)
            XCTAssertEqual(state.presentationBlank, closeWindow ? "black" : nil)
            XCTAssertEqual(state.laserPointer, closeWindow)
            XCTAssertEqual(state.canNavigateBack, closeWindow)
        }
    }

    @MainActor
    func testFailedReloadKeepsOldDocumentAndPosition() async throws {
        let url = try fixture("still readable")
        let state = ReaderState()
        defer { state.close() }
        state.open(url)
        try await waitUntilIdle(state)
        let old = try XCTUnwrap(state.document)
        state.page = 4
        state.findQuery = "still"
        state.selectedText = "still readable"
        state.hasSelection = true
        try FileManager.default.removeItem(at: url)
        state.reload()
        try await waitUntilIdle(state)
        XCTAssertEqual(state.document?.id, old.id)
        XCTAssertEqual(state.page, 4)
        XCTAssertEqual(state.findQuery, "still")
        XCTAssertEqual(state.selectedText, "still readable")
        XCTAssertTrue(state.hasSelection)
        XCTAssertNotNil(state.error)
        state.close()
        XCTAssertNil(state.error)
        XCTAssertEqual(state.page, 0)
    }

    @MainActor
    func testOpeningFailureDoesNotStrandAcknowledgedCommands() async throws {
        let url = try fixture("still readable")
        let state = ReaderState()
        defer { state.close() }
        state.open(url)
        try await waitUntilIdle(state)
        let documentID = state.document?.id
        state.send(.selectAll)
        state.send(.copy)
        state.didHandleCommand(state.command.revision)
        state.open(url.appendingPathExtension("missing"))
        try await waitUntilIdle(state)
        XCTAssertEqual(state.document?.id, documentID)
        XCTAssertEqual(state.command.action, .copy)
        state.didHandleCommand(state.command.revision)
        state.send(.print)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(state.command.action, .print)
    }

    @MainActor
    func testFailedReplacementKeepsCurrentPDFReloadPassword() async throws {
        try requireMuPDF()
        let url = try fixture("", extension: "pdf")
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        let bytes = try XCTUnwrap(pdf.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"]))
        try bytes.write(to: url)
        let state = ReaderState()
        defer { state.close() }
        XCTAssertThrowsError(try ReadingDocument.open(url)) { XCTAssertTrue($0 is PasswordRequired) }
        state.document = try ReadingDocument.open(url, password: "reader")
        state.rememberPassword("reader")
        let original = try XCTUnwrap(state.document)
        guard case .pages(let opened) = original.content, opened.isPDF else { return XCTFail("Expected native PDF") }
        let openedInfo = try await opened.pdfInfo()
        XCTAssertEqual(openedInfo?.pageCount, 1)
        XCTAssertEqual(openedInfo?.ownerAuthenticated, false)
        state.open(url.appendingPathExtension("missing"))
        try await waitUntilIdle(state)
        XCTAssertEqual(state.document?.id, original.id)
        state.reload()
        try await waitUntilIdle(state)
        guard case .pages(let reloaded) = state.document?.content, reloaded.isPDF else { return XCTFail("Expected reloaded native PDF") }
        let reloadedInfo = try await reloaded.pdfInfo()
        XCTAssertEqual(reloadedInfo?.pageCount, 1)
        XCTAssertEqual(reloadedInfo?.ownerAuthenticated, false)
    }

    @MainActor
    func testPageCommandsRespectBothDocumentEdges() {
        let state = ReaderState()
        XCTAssertFalse(state.canGoBackward)
        XCTAssertFalse(state.canGoForward)
        state.count = 3
        XCTAssertFalse(state.canGoBackward)
        XCTAssertTrue(state.canGoForward)
        state.page = 2
        XCTAssertTrue(state.canGoBackward)
        XCTAssertFalse(state.canGoForward)
    }

    @MainActor
    func testPDFContentsPreserveHierarchyAndGoToActions() async throws {
        let pdf = PDFDocument()
        let page = PDFPage()
        pdf.insert(page, at: 0)
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        let root = PDFOutline()
        let part = PDFOutline()
        part.label = "Part"
        let chapter = PDFOutline()
        chapter.label = "Chapter"
        chapter.action = PDFActionGoTo(destination: PDFDestination(page: page, at: .zero))
        part.insertChild(chapter, at: 0)
        root.insertChild(part, at: 0)
        pdf.outlineRoot = root
        let reading = try nativePDFReadingFixture(pdf)
        guard case .pages(let pages) = reading.content else { return XCTFail("Expected native PDF") }
        let contents = try await pages.prepare().outline
        XCTAssertEqual(contents.map(\.title), ["Part", "Chapter"])
        XCTAssertEqual(contents.first?.target, "")
        let destination = try await pages.resolve(contents[1].target)
        XCTAssertEqual(destination?.page, 0)
        XCTAssertEqual(destination?.x, 0)
        XCTAssertEqual(destination?.y, 792)
        XCTAssertEqual(contents.map(\.depth), [0, 1])
    }

    @MainActor
    func testTextReaderRestoresZoomAndClearsOldFindStatus() async {
        _ = NSApplication.shared
        let state = ReaderState()
        state.zoom = 1.75
        state.font = "monospace"
        state.fontSize = 20
        let coordinator = TextReader.Coordinator(state)
        let view = NSTextView()
        view.string = "first second"
        coordinator.view = view
        coordinator.style()
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(state.zoom, 1.75)
        XCTAssertEqual(view.font?.pointSize, 35)
        coordinator.find("absent")
        await coordinator.searchTask?.value
        XCTAssertEqual(state.status, "No matches")
        coordinator.find("second")
        await coordinator.searchTask?.value
        XCTAssertEqual(state.status, "1 of 1 matches")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertEqual(state.selectedSearchTarget, "text:6:6")
    }
}
#endif
