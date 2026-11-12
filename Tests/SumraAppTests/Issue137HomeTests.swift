#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class Issue137HomeTests: XCTestCase {
    @MainActor
    func testBrowsedFolderAppearsImmediatelyAndKeepsBrowsingIntentAcrossRename() throws {
        try withIsolatedHistory {
            let directory = try TemporaryDirectory()
            let folder = directory.url.appendingPathComponent("Browse", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let first = Date()
            ReaderFiles.recordBrowse(folder, recordsHistory: true, at: first)
            XCTAssertEqual(ReaderFiles.recent, [folder])
            XCTAssertTrue(ReaderFiles.opensInFolderBrowser(folder))
            let alias = directory.url.appendingPathComponent("Alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
            XCTAssertTrue(ReaderFiles.opensInFolderBrowser(alias))
            let moved = directory.url.appendingPathComponent("Renamed", isDirectory: true)
            try FileManager.default.moveItem(at: folder, to: moved)
            ReaderFiles.migrate(folder, to: moved, recordsHistory: true)
            XCTAssertEqual(ReaderFiles.recent, [moved])
            XCTAssertTrue(ReaderFiles.opensInFolderBrowser(moved))
            ReaderFiles.forget(moved)
            XCTAssertTrue(ReaderFiles.recent.isEmpty)
            XCTAssertFalse(ReaderFiles.opensInFolderBrowser(moved))
            withExtendedLifetime(directory) {}
        }
    }

    @MainActor
    func testImageReadingOverridesBrowseAndLaterBrowsingPreservesReaderAndPosition() throws {
        try withIsolatedHistory {
            let directory = try TemporaryDirectory()
            let folder = directory.url
            // The directory reader enumerates image pages without loading their bytes.
            try Data().write(to: folder.appendingPathComponent("Page.png"))
            ReaderFiles.recordBrowse(folder, recordsHistory: true)
            XCTAssertTrue(ReaderFiles.opensInFolderBrowser(folder))
            let document = ReadingDocument(url: folder, content: .pages(try Pages(folder, format: .comic)))
            ReaderFiles.recordOpen(document, recordsHistory: true)
            XCTAssertFalse(ReaderFiles.opensInFolderBrowser(folder))
            let key = "position:" + folder.path
            defer { UserDefaults.standard.removeObject(forKey: key) }
            let position = try JSONEncoder().encode(ReadingPosition(page: 2))
            UserDefaults.standard.set(position, forKey: key)
            ReaderFiles.recordBrowse(folder, recordsHistory: true)
            XCTAssertFalse(ReaderFiles.opensInFolderBrowser(folder))
            XCTAssertEqual(UserDefaults.standard.data(forKey: key), position)
            XCTAssertEqual(ReaderFiles.recent, [folder])
            withExtendedLifetime(directory) {}
        }
    }

    @MainActor
    func testLegacyImageFolderHistoryKeepsReaderDestination() throws {
        try withIsolatedHistory {
            let directory = try TemporaryDirectory()
            let record: [String: Any] = ["count": 1, "lastOpened": Date().timeIntervalSinceReferenceDate]
            let data = try JSONSerialization.data(withJSONObject: [directory.url.path: record])
            UserDefaults.standard.set(data, forKey: "documentOpenHistory")
            XCTAssertEqual(ReaderFiles.recent, [directory.url])
            XCTAssertFalse(ReaderFiles.opensInFolderBrowser(directory.url))
            ReaderFiles.recordBrowse(directory.url, recordsHistory: true)
            XCTAssertFalse(ReaderFiles.opensInFolderBrowser(directory.url))
            withExtendedLifetime(directory) {}
        }
    }

    @MainActor
    func testBrowsingHonorsHistoryPolicy() throws {
        try withIsolatedHistory {
            let directory = try TemporaryDirectory()
            ReaderFiles.recordBrowse(directory.url, recordsHistory: false)
            UserDefaults.standard.set(true, forKey: "disableHistory")
            ReaderFiles.recordBrowse(directory.url, recordsHistory: true)
            XCTAssertTrue(ReaderFiles.recent.isEmpty)
            XCTAssertNil(UserDefaults.standard.data(forKey: "documentOpenHistory"))
            withExtendedLifetime(directory) {}
        }
    }

    @MainActor
    func testEmptyImageFolderErrorNamesSupportedTypesFromImageOwnerAndUsesSelectedLanguage() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        try Data("not an image".utf8).write(to: directory.url.appendingPathComponent("Note.txt"))
        let defaults = UserDefaults.standard, language = defaults.object(forKey: "language")
        defer { defaults.set(language, forKey: "language") }
        let key = "No supported images found in this folder. Supported image types: %@"
        XCTAssertTrue(Format.comicImageExtensions.contains("svg"))
        XCTAssertTrue(Format.comicImageExtensions.contains("heic"))
        XCTAssertFalse(Format.comicImageExtensions.contains("pdf"))
        for selected in ["en", "zh-Hans"] {
            defaults.set(selected, forKey: "language")
            let expected = String(format: L(key), Format.comicImageExtensions.map { $0.uppercased() }.joined(separator: ", "))
            XCTAssertThrowsError(try Pages(directory.url, format: .comic)) { error in
                XCTAssertEqual(error.localizedDescription, expected)
            }
        }
    }

    @MainActor
    func testRecentMenuAndPaletteRoutingRequestsFolderBrowserWithoutLoadingImages() throws {
        try withIsolatedHistory {
            let directory = try TemporaryDirectory()
            try Data("A document folder".utf8).write(to: directory.url.appendingPathComponent("Note.txt"))
            ReaderFiles.recordBrowse(directory.url, recordsHistory: true)
            let state = ReaderState(recordsHistory: false)
            defer { state.windowClosed() }
            let document = ReadingDocument(url: directory.url.appendingPathComponent("Current.txt"), content: .text("Keep reading"))
            state.document = document
            // Both Open Recent and the palette invoke this owner after choosing a URL.
            ReaderFiles.openRecent(directory.url, in: state) { _ in XCTFail("An existing reader should present its browser sheet") }
            XCTAssertTrue(state.showFiles)
            XCTAssertEqual(state.fileBrowserFolder, directory.url)
            XCTAssertEqual(state.document?.id, document.id)
            XCTAssertNil(state.error)
            XCTAssertFalse(state.busy)
            ReaderFiles.openRecent(directory.url, in: state, recordsHistory: false) { _ in XCTFail("No new window expected") }
            XCTAssertEqual(state.fileBrowserRecordsHistory, false)
            withExtendedLifetime(directory) {}
        }
    }

    @MainActor
    func testFolderContextWindowsAndTabsCarryTransientBrowseIntentAndPrivacy() throws {
        try withIsolatedHistory {
            let directory = try TemporaryDirectory()
            ReaderFiles.recordBrowse(directory.url, recordsHistory: true)
            let state = ReaderState(recordsHistory: false)
            defer { state.windowClosed() }
            for behavior in [DocumentOpenBehavior.newWindow, .newTab] {
                var requests = [WindowPayload]()
                ReaderFiles.openRecent(directory.url, in: state, recordsHistory: false, behavior: behavior) { requests.append($0) }
                let request = try XCTUnwrap(requests.first)
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(request.browserFolder, directory.url)
                XCTAssertNil(request.path, "A browsing folder must not be passed to the image reader")
                XCTAssertEqual(request.recordsHistory, false)
                let restored = try JSONDecoder().decode(WindowPayload.self, from: JSONEncoder().encode(request))
                XCTAssertNil(restored.browserFolder, "Transient browser requests must not become restored documents")
            }
            var firstWindow: WindowPayload?
            ReaderFiles.openRecent(directory.url, in: nil) { firstWindow = $0 }
            XCTAssertEqual(firstWindow?.browserFolder, directory.url)
            XCTAssertNil(firstWindow?.path)
            // Folders reached from another directory browse even if previously read as pages.
            ReaderFiles.recordOpen(ReadingDocument(url: directory.url, content: .text("Legacy reader")), recordsHistory: true)
            ReaderFiles.openRecent(directory.url, in: state, browseFolder: true) { _ in XCTFail("Expected the folder browser") }
            XCTAssertEqual(state.fileBrowserFolder, directory.url)
            withExtendedLifetime(directory) {}
        }
    }

    @MainActor
    private func withIsolatedHistory(_ body: () throws -> Void) throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["documentOpenHistory", "pinnedDocuments", "closedDocuments", "disableHistory"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        defer {
            ReaderFiles.setRecent(recent)
            for (key, value) in previous { defaults.set(value, forKey: key) }
        }
        ReaderFiles.clearHistory()
        defaults.removeObject(forKey: "pinnedDocuments")
        defaults.set(false, forKey: "disableHistory")
        try body()
    }
}
#endif
