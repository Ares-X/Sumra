#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class NativeMarkdownBookmarkMigrationTests: XCTestCase {
    func testOpeningMigratesPersistedBookmarksBeforeSortingTogglingAndPreviousNextNavigation() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let source = directory.url.resolvingSymlinksInPath().appendingPathComponent("Bookmarks.md")
        let original = Data("# Collection\n\n## First\n\nalpha\n\n## Last\n\ngamma\n\n## End\n\ndelta\n".utf8)
        try original.write(to: source)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "bookmarks")
        let state = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed(); defaults.set(previous, forKey: "bookmarks")
            withExtendedLifetime(directory) {}
        }
        var oldPosition = ReadingPosition(page: 2, x: 0, y: 0, anchor: "2:0:1", markdownRenderer: .paged,
            zoom: 1.2, flow: "continuous", font: "serif", fontSize: 22, lineHeight: 1.8, margin: 32,
            userCSS: "p{word-spacing:2px;}", useDocumentCSS: true, automaticLayout: false)
        oldPosition.preferenceRevisions = ["fontSize": 7]
        let gamma = ReaderBookmark(title: "Saved gamma title", path: source.path, position: oldPosition,
            fileBookmark: DocumentFileIdentity.bookmark(for: source))
        let delta = ReaderBookmark(title: "Current delta", path: source.path,
            position: .init(page: 2, anchor: "md2:2:0:1", markdownRenderer: .paged))
        let unrelated = ReaderBookmark(title: "Unrelated", path: source.deletingLastPathComponent().appendingPathComponent("Other.md").path,
            position: .init(page: 8, anchor: "8:0:1"))
        state.bookmarks = [delta, gamma, unrelated]
        defaults.set(try JSONEncoder().encode(state.bookmarks), forKey: "bookmarks")
        let opening = ReadingPosition(anchor: "md2:0:0:1", markdownRenderer: .paged, zoom: 1.1,
            fontSize: 17, userCSS: "p{word-spacing:1px;}")
        state.openWithoutHistory(source, at: opening)
        try await waitUntilIdle(state)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.location.anchor, opening.anchor)
        XCTAssertEqual(state.fontSize, opening.fontSize)
        XCTAssertEqual(state.userCSS, opening.userCSS)
        XCTAssertEqual(state.zoom, opening.zoom)
        let migrated = try XCTUnwrap(state.bookmarks.first { $0.id == gamma.id })
        XCTAssertTrue(migrated.position.anchor?.hasPrefix("md2:") == true)
        XCTAssertEqual(ChapterTable.bookmarkLocation(try XCTUnwrap(migrated.position.anchor))?.location.chapter, 1)
        XCTAssertEqual(state.sortedBookmarks.filter { $0.path == source.path }.map(\.id), [gamma.id, delta.id])
        // A failing pre-migration run must not open the Add Bookmark modal.
        guard migrated.position.anchor?.hasPrefix("md2:") == true else { return }
        XCTAssertEqual(migrated.id, gamma.id); XCTAssertEqual(migrated.title, gamma.title)
        XCTAssertEqual(migrated.fileBookmark, gamma.fileBookmark)
        var preferences = migrated.position
        preferences.page = oldPosition.page; preferences.x = oldPosition.x; preferences.y = oldPosition.y
        preferences.anchor = oldPosition.anchor; preferences.nativePassage = oldPosition.nativePassage
        XCTAssertEqual(preferences, oldPosition)
        XCTAssertEqual(state.bookmarks.first { $0.id == unrelated.id }?.position, unrelated.position)
        let persisted = try JSONDecoder().decode([ReaderBookmark].self, from: XCTUnwrap(defaults.data(forKey: "bookmarks")))
        XCTAssertEqual(persisted.first { $0.id == gamma.id }?.position, migrated.position)
        guard case .pages(let pages) = try XCTUnwrap(state.document).content else { return XCTFail("Expected native Markdown") }
        let layout = await pages.chapterLayout
        _ = state.applyChapterLayout(layout); state.reflowable = true
        let displayed = try await pages.restore(migrated.position)
        state.updatePosition(displayed)
        state.moveBookmark(1)
        XCTAssertEqual(state.location.anchor, delta.position.anchor)
        state.moveBookmark(-1)
        XCTAssertEqual(state.location.anchor, migrated.position.anchor)
        state.updatePosition(displayed)
        state.toggleBookmark()
        XCTAssertEqual(state.bookmarks.map(\.id), [delta.id, unrelated.id], "Toggle removes the original bookmark rather than creating a duplicate")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMergedPageBookmarksKeepDistinctSourceIdentityAndTheirOwnSavedParsingStyle() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let source = directory.url.resolvingSymlinksInPath().appendingPathComponent("Sources.md")
        try "# Collection\n\n## First\n\nalpha\n\n## Last\n\ngamma\n".write(to: source, atomically: true, encoding: .utf8)
        let file = try NativeFile(source, engine: .mupdf)
        let css = "p{word-spacing:3px;}"
        _ = try file.relayout(fontSize: 19, lineHeight: 2, font: "serif", theme: "light", userCSS: css)
        func oldPassage(_ word: String, node: UInt32) throws -> ReadingPosition {
            let source = try XCTUnwrap(file.markdownDocumentMatches(word, options: .init(), startPage: 0).first?.source)
            let current = try XCTUnwrap(file.position(for: source)?.nativePassage)
            let old = NativePassage(source: .init(node: node, offset: 0, part: 0, chapter: 1), offsetX: 0, offsetY: 0,
                sourceRevision: current.sourceRevision, styleSignature: current.styleSignature, chapter: 1)
            return ReadingPosition(page: 1, anchor: "1:0:1", nativePassage: old, markdownRenderer: .paged,
                zoom: 1, font: "serif", fontSize: 19, lineHeight: 2, margin: 32, userCSS: css, useDocumentCSS: true)
        }
        let heading = ReaderBookmark(title: "Heading", path: source.path, position: try oldPassage("First", node: 1))
        let body = ReaderBookmark(title: "Body", path: source.path, position: try oldPassage("alpha", node: 2))
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "bookmarks")
        let state = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed(); defaults.set(previous, forKey: "bookmarks")
            withExtendedLifetime(directory) {}
        }
        state.bookmarks = [body, heading]
        state.openWithoutHistory(source, at: .init(markdownRenderer: .paged))
        try await waitUntilIdle(state)
        XCTAssertNil(state.error)
        let migratedHeading = try XCTUnwrap(state.bookmarks.first { $0.id == heading.id })
        let migratedBody = try XCTUnwrap(state.bookmarks.first { $0.id == body.id })
        XCTAssertEqual(migratedHeading.position.nativePassage?.markdownSections, 2)
        XCTAssertEqual(migratedBody.position.nativePassage?.markdownSections, 2)
        XCTAssertEqual(migratedHeading.position.page, migratedBody.position.page)
        XCTAssertEqual(migratedHeading.position.nativePassage?.source.chapter, 0)
        XCTAssertNotEqual(migratedHeading.position.nativePassage?.source, migratedBody.position.nativePassage?.source)
        XCTAssertEqual(state.sortedBookmarks.map(\.id), [heading.id, body.id])
        guard migratedHeading.position.nativePassage?.markdownSections == 2,
              migratedBody.position.nativePassage?.markdownSections == 2 else { return }
        guard case .pages(let pages) = try XCTUnwrap(state.document).content else { return XCTFail("Expected native Markdown") }
        _ = state.applyChapterLayout(await pages.chapterLayout); state.reflowable = true
        let displayed = try await pages.restore(migratedHeading.position)
        state.updatePosition(displayed)
        state.moveBookmark(1)
        XCTAssertEqual(state.location.nativePassage?.source, migratedBody.position.nativePassage?.source)
        state.moveBookmark(1)
        XCTAssertEqual(state.location.nativePassage?.source, migratedHeading.position.nativePassage?.source)
        state.moveBookmark(-1)
        XCTAssertEqual(state.location.nativePassage?.source, migratedBody.position.nativePassage?.source)
        state.updatePosition(displayed)
        state.toggleBookmark()
        XCTAssertEqual(state.bookmarks.map(\.id), [body.id], "A different glyph on the same new page must remain bookmarked")
    }

    func testSingleLegacyBookmarkIsImportedInCurrentCoordinatesAndCompatibleRecordsRemainUnchanged() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let source = directory.url.resolvingSymlinksInPath().appendingPathComponent("Import.md")
        try "# Collection\n\n## First\n\nalpha\n\n## Last\n\ngamma\n".write(to: source, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "bookmarks")
        let key = "bookmark:" + source.path, oldLegacy = defaults.object(forKey: key)
        let state = ReaderState(recordsHistory: false)
        defer {
            state.windowClosed(); defaults.set(previous, forKey: "bookmarks"); defaults.set(oldLegacy, forKey: key)
            withExtendedLifetime(directory) {}
        }
        state.bookmarks = []
        defaults.set(try JSONEncoder().encode(ReadingPosition(page: 2, anchor: "2:0:1")), forKey: key)
        state.openWithoutHistory(source, at: .init(markdownRenderer: .paged))
        try await waitUntilIdle(state)
        let imported = try XCTUnwrap(state.bookmarks.first)
        XCTAssertEqual(ChapterTable.bookmarkLocation(try XCTUnwrap(imported.position.anchor))?.location.chapter, 1)
        XCTAssertTrue(imported.position.anchor?.hasPrefix("md2:") == true)
        XCTAssertNil(defaults.object(forKey: key))
        guard case .pages(let pages) = try XCTUnwrap(state.document).content else { return XCTFail("Expected native Markdown") }
        let compatible = ReadingPosition(page: 2, anchor: "2:0:1", markdownRenderer: .compatible)
        let unchanged = try await pages.migratedMarkdownBookmarks([compatible], fontSize: 17, lineHeight: 1.6, margin: 32,
            font: "system", theme: "light", userCSS: "", useDocumentCSS: true, pageMargins: nil, textZoom: 1)
        XCTAssertEqual(unchanged, [compatible])
    }

    private func waitUntilIdle(_ state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        while state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
    }
}
#endif
