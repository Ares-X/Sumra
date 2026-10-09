import Foundation
import XCTest
@testable import SumraCore

final class ChapterTableTests: XCTestCase {
    func testGrowingEarlierChaptersOnlyChangesFlatPageNumbers() throws {
        var table = ChapterTable(chapters: 3)
        XCTAssertEqual(table.totalPages, 3)
        XCTAssertFalse(table.complete)
        XCTAssertEqual((0..<3).compactMap { table.location(page: $0) },
                       (0..<3).map { PageLocation(chapter: $0, page: 0) })

        table.setPageCount(chapter: 2, count: 3)
        let location = PageLocation(chapter: 2, page: 1), snapshot = table
        XCTAssertEqual(snapshot.page(for: location), 3)
        XCTAssertFalse(snapshot.isLaidOut(0))
        XCTAssertFalse(snapshot.isLaidOut(1))
        XCTAssertTrue(snapshot.isLaidOut(2))
        table.setPageCount(chapter: 0, count: 4)
        XCTAssertEqual(table.page(for: location), 6)
        XCTAssertEqual(table.location(page: 6), location)
        XCTAssertEqual(snapshot.page(for: location), 3, "Published snapshots must remain stable while the owner lays out other chapters")
        XCTAssertGreaterThan(table.generation, snapshot.generation)

        table.setPageCount(chapter: 1, count: 2)
        XCTAssertTrue(table.complete)
        XCTAssertEqual(table.totalPages, 9)
        for page in 0..<table.totalPages {
            XCTAssertEqual(table.page(for: try XCTUnwrap(table.location(page: page))), page)
        }
        XCTAssertNil(table.location(page: -1))
        XCTAssertNil(table.location(page: table.totalPages))
        XCTAssertNil(table.page(for: .init(chapter: 3, page: 0)))
    }

    func testBookmarksRestoreOneBasedProgressWithinTheirChapter() throws {
        var old = ChapterTable(chapters: 3)
        old.setPageCount(chapter: 0, count: 7)
        old.setPageCount(chapter: 1, count: 10)
        old.setPageCount(chapter: 2, count: 2)
        let anchor = old.bookmark(.init(chapter: 1, page: 3))
        XCTAssertEqual(anchor, "1:3:10")
        let saved = try XCTUnwrap(ChapterTable.bookmarkLocation(anchor))
        var reflowed = ChapterTable(chapters: 3)
        reflowed.setPageCount(chapter: 0, count: 40)
        reflowed.setPageCount(chapter: 1, count: 20)
        XCTAssertEqual(reflowed.restored(saved.location, savedCount: saved.count), .init(chapter: 1, page: 7))
        XCTAssertEqual(reflowed.page(for: reflowed.restored(saved.location, savedCount: saved.count)), 47)
        reflowed.setPageCount(chapter: 1, count: 3)
        XCTAssertEqual(reflowed.restored(.init(chapter: 1, page: 8), savedCount: 10), .init(chapter: 1, page: 2))

        let legacy = try XCTUnwrap(ChapterTable.bookmarkLocation("1:1"))
        XCTAssertEqual(legacy.count, 0)
        XCTAssertEqual(reflowed.restored(legacy.location, savedCount: legacy.count), legacy.location)
        for malformed in ["", "1", "-1:0", "1:-1", "1:2:-3", "chapter:0", "1:2:count"] {
            XCTAssertNil(ChapterTable.bookmarkLocation(malformed), malformed)
        }
    }

    func testResetInvalidatesTheLayoutWithoutChangingChapterIdentity() {
        var table = ChapterTable(chapters: 2)
        table.setPageCount(chapter: 0, count: 4)
        table.setPageCount(chapter: 1, count: 6)
        let priorGeneration = table.generation
        table.reset()
        XCTAssertEqual(table.chapterCount, 2)
        XCTAssertEqual(table.totalPages, 2)
        XCTAssertFalse(table.complete)
        XCTAssertFalse(table.isLaidOut(0))
        XCTAssertFalse(table.isLaidOut(1))
        XCTAssertGreaterThan(table.generation, priorGeneration)
        table.setPageCount(chapter: 0, count: 1)
        table.setPageCount(chapter: 1, count: 1)
        XCTAssertTrue(table.complete, "A laid-out one-page chapter must differ from its unresolved placeholder")
    }

    func testUnlaidOutBookmarkDoesNotScaleItsPlaceholderToTheLastPage() throws {
        var table = ChapterTable(chapters: 2)
        let saved = try XCTUnwrap(ChapterTable.bookmarkLocation(table.bookmark(.init(chapter: 1, page: 0))))
        XCTAssertEqual(saved.count, 0, "A placeholder is not a measured chapter page count")
        table.setPageCount(chapter: 1, count: 12)
        XCTAssertEqual(table.restored(saved.location, savedCount: saved.count), .init(chapter: 1, page: 0))
    }

    func testFixedPagesHaveOneCompleteChapterAndLocationsSurviveCoding() throws {
        let table = ChapterTable(pages: 12), location = PageLocation(chapter: 0, page: 11)
        XCTAssertTrue(table.complete)
        XCTAssertEqual(table.chapterCount, 1)
        XCTAssertEqual(table.location(page: 11), location)
        XCTAssertEqual(table.page(for: location), 11)
        XCTAssertEqual(try JSONDecoder().decode(PageLocation.self, from: JSONEncoder().encode(location)), location)
        XCTAssertLessThan(PageLocation(chapter: 0, page: 11), PageLocation(chapter: 1, page: 0))
    }
}
