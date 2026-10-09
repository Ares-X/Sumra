import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import SumraCore

final class PageRowsTests: XCTestCase {
    func testArithmeticContinuousRowsMatchPlacedRowsAcrossSpreadsAndViewports() throws {
        let single = CGSize(width: 310, height: 470), pair = CGSize(width: 190, height: 325)
        for count in 1...9 {
            for spread in [false, true] {
                for cover in [false, true] {
                    for rtl in [false, true] {
                        for freePan in [false, true] {
                            for viewport in [CGSize(width: 250, height: 220), CGSize(width: 1100, height: 900)] {
                                let rows = PageRows.ranges(count: count, spread: spread, cover: cover)
                                var sizes = [CGSize](repeating: .zero, count: count)
                                for row in rows { for page in row { sizes[page] = row.count == 1 ? single : pair } }
                                let placed = PageRows.layout(displaySizes: sizes, viewport: viewport, page: 0,
                                    continuous: true, spread: spread, cover: cover, rtl: rtl, freePan: freePan,
                                    spacing: CGSize(width: 4, height: 4), inset: .zero)
                                let arithmetic = try XCTUnwrap(PageRows.uniformLayout(singleSize: single, pairSize: pair,
                                    count: count, viewport: viewport, spread: spread, cover: cover, rtl: rtl,
                                    freePan: freePan, spacing: CGSize(width: 4, height: 4), inset: .zero))
                                XCTAssertEqual(arithmetic.rowCount, rows.count)
                                XCTAssertEqual(arithmetic.canvas, placed.canvas)
                                for row in rows.indices {
                                    XCTAssertEqual(arithmetic.range(row: row), rows[row])
                                    let y = try XCTUnwrap(placed.pages[rows[row].lowerBound]).frame.minY
                                    XCTAssertEqual(arithmetic.row(atY: y), row)
                                    XCTAssertEqual(arithmetic.row(atY: y + sizes[rows[row].lowerBound].height / 2), row)
                                }
                                for page in 0..<count {
                                    let expected = try XCTUnwrap(placed.pages[page])
                                    let actual = try XCTUnwrap(arithmetic.placement(page: page))
                                    XCTAssertEqual(actual.frame.minX, expected.frame.minX, accuracy: 0.0001)
                                    XCTAssertEqual(actual.frame.minY, expected.frame.minY, accuracy: 0.0001)
                                    XCTAssertEqual(actual.frame.size, expected.frame.size)
                                    XCTAssertEqual(actual.scale, expected.scale)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testMillionPageArithmeticRowsKeepConstantStorageAndReachLastPage() throws {
        let count = 1_173_827
        let layout = try XCTUnwrap(PageRows.uniformLayout(singleSize: CGSize(width: 420.3, height: 595.3),
            pairSize: CGSize(width: 210.1, height: 298.1), count: count, viewport: CGSize(width: 900, height: 700),
            spread: true, cover: true, rtl: true, spacing: CGSize(width: 4, height: 4), inset: .zero))
        XCTAssertLessThan(MemoryLayout<PageRows.UniformLayout>.size, 256)
        let last = try XCTUnwrap(layout.placement(page: count - 1))
        XCTAssertTrue(last.frame.minY.isFinite)
        XCTAssertEqual(layout.range(row: layout.rowCount - 1).upperBound, count)
        XCTAssertEqual(layout.row(atY: last.frame.minY), layout.rowCount - 1)
        XCTAssertNil(layout.placement(page: count))
    }

    func testUniformContinuousPagesKeepPercentageWidthIndependentOfViewport() throws {
        let sizes = [CGSize(width: 600, height: 800), CGSize(width: 300, height: 900), CGSize(width: 1200, height: 300)]
        let layout = PageRows.layout(sizes: sizes, viewport: CGSize(width: 1000, height: 600), page: 0,
            continuous: true, spread: false, cover: false, rtl: false, zoom: 1.5)
        let placements = try layout.pages.map { try XCTUnwrap($0) }
        XCTAssertEqual(placements.map(\.scale), [1.5, 3, 0.75])
        for placement in placements { XCTAssertEqual(placement.frame.width, 900, accuracy: 0.0001) }
        XCTAssertEqual(placements.map { $0.frame.minX }, [50, 50, 50])
        XCTAssertEqual(placements.map { $0.frame.minY }, [4, 1212, 3920])
        XCTAssertEqual(layout.canvas, CGSize(width: 1000, height: 4149))
        let wider = PageRows.layout(sizes: sizes, viewport: CGSize(width: 1600, height: 600), page: 0,
            continuous: true, spread: false, cover: false, rtl: false, zoom: 1.5)
        XCTAssertEqual(wider.pages.compactMap { $0?.scale }, placements.map(\.scale))
        XCTAssertEqual(wider.pages.compactMap { $0?.frame.size }, placements.map { $0.frame.size })
    }

    func testFacingPagesUseUniformWidthAndEachRowsTallestPage() throws {
        let sizes = [CGSize(width: 600, height: 800), CGSize(width: 400, height: 500),
                     CGSize(width: 300, height: 900), CGSize(width: 500, height: 600)]
        let layout = PageRows.layout(sizes: sizes, viewport: CGSize(width: 100, height: 100), page: 0,
            continuous: true, spread: true, cover: false, rtl: false, zoom: 1)
        let placements = try layout.pages.map { try XCTUnwrap($0) }
        XCTAssertEqual(layout.rows, [0..<2, 2..<4])
        XCTAssertEqual(placements.map { $0.frame.minX }, [4, 612, 4, 612])
        XCTAssertEqual(placements.map { $0.frame.minY }, [4, 4, 812, 812])
        XCTAssertEqual(placements[0].frame.maxX, placements[2].frame.maxX)
        XCTAssertEqual(layout.canvas, CGSize(width: 1216, height: 2616))
        XCTAssertEqual(placements.map(\.scale), [1, 1.5, 2, 1.2])
    }

    func testCoverIsOnOuterColumnInContinuousBookAndCenteredWhenPaged() throws {
        let sizes = Array(repeating: CGSize(width: 300, height: 500), count: 5)
        let continuous = PageRows.layout(sizes: sizes, viewport: CGSize(width: 1000, height: 800), page: 0,
            continuous: true, spread: true, cover: true, rtl: false, zoom: 1)
        XCTAssertEqual(continuous.rows, [0..<1, 1..<3, 3..<5])
        XCTAssertEqual(try XCTUnwrap(continuous.pages[0]).frame.minX, try XCTUnwrap(continuous.pages[2]).frame.minX)
        XCTAssertEqual(try XCTUnwrap(continuous.pages[0]).frame.minY, 4)
        let cover = PageRows.layout(sizes: sizes, viewport: CGSize(width: 1000, height: 800), page: 0,
            continuous: false, spread: true, cover: true, rtl: false, zoom: 1)
        XCTAssertEqual(cover.rows, [0..<1])
        XCTAssertEqual(cover.pages.compactMap { $0 }.count, 1)
        XCTAssertEqual(try XCTUnwrap(cover.pages[0]).frame, CGRect(x: 350, y: 150, width: 300, height: 500))
        XCTAssertEqual(cover.canvas, CGSize(width: 1000, height: 800))
        let inside = PageRows.layout(sizes: sizes, viewport: CGSize(width: 1000, height: 800), page: 2,
            continuous: false, spread: true, cover: true, rtl: false, zoom: 1)
        XCTAssertEqual(inside.rows, [1..<3]); XCTAssertNil(inside.pages[0]); XCTAssertNil(inside.pages[3])
        XCTAssertEqual(try XCTUnwrap(inside.pages[1]).frame.maxX + 8, try XCTUnwrap(inside.pages[2]).frame.minX)
    }

    func testRTLOnlyMirrorsColumnPositionsNotPageOrderScaleOrVerticalGeometry() throws {
        let sizes = [CGSize(width: 400, height: 700), CGSize(width: 250, height: 400), CGSize(width: 600, height: 900)]
        for continuous in [false, true] {
            let left = PageRows.layout(sizes: sizes, viewport: CGSize(width: 1300, height: 1000), page: 1,
                continuous: continuous, spread: true, cover: true, rtl: false, zoom: 1.25)
            let right = PageRows.layout(sizes: sizes, viewport: CGSize(width: 1300, height: 1000), page: 1,
                continuous: continuous, spread: true, cover: true, rtl: true, zoom: 1.25)
            XCTAssertEqual(left.canvas, right.canvas); XCTAssertEqual(left.rows, right.rows)
            for index in sizes.indices {
                guard let a = left.pages[index] else { XCTAssertNil(right.pages[index]); continue }
                let b = try XCTUnwrap(right.pages[index])
                XCTAssertEqual(b.frame.minX, left.canvas.width - a.frame.maxX, accuracy: 0.0001)
                XCTAssertEqual(a.frame.minY, b.frame.minY); XCTAssertEqual(a.frame.size, b.frame.size)
                XCTAssertEqual(a.scale, b.scale)
            }
        }
    }

    func testRotationIsRepresentedByCallerSizesAndUniformReferenceFollowsIt() throws {
        let original = [CGSize(width: 600, height: 800), CGSize(width: 300, height: 1200)]
        let rotated = original.map { CGSize(width: $0.height, height: $0.width) }
        let layout = PageRows.layout(sizes: rotated, viewport: CGSize(width: 800, height: 600), page: 0,
            continuous: true, spread: false, cover: false, rtl: false, zoom: 1)
        XCTAssertEqual(try XCTUnwrap(layout.pages[0]).scale, 1)
        XCTAssertEqual(try XCTUnwrap(layout.pages[1]).scale, 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(layout.pages[1]).frame.size, CGSize(width: 800, height: 200))
    }

    func testSinglePageBookKeepsTwoSlotsAndZeroSpacingJoinsRows() throws {
        let book = PageRows.layout(sizes: [CGSize(width: 200, height: 300)], viewport: CGSize(width: 100, height: 100), page: 0,
            continuous: false, spread: true, cover: true, rtl: false, zoom: 1)
        XCTAssertEqual(book.canvas, CGSize(width: 416, height: 308))
        XCTAssertEqual(try XCTUnwrap(book.pages[0]).frame.minX, 108)
        let joined = PageRows.layout(sizes: [CGSize(width: 201, height: 303), CGSize(width: 402, height: 607)],
            viewport: .zero, page: 0, continuous: true, spread: false, cover: false, rtl: false,
            zoom: 1.25, spacing: .zero, inset: .zero)
        XCTAssertEqual(try XCTUnwrap(joined.pages[0]).frame.maxY, try XCTUnwrap(joined.pages[1]).frame.minY)
        XCTAssertEqual(try XCTUnwrap(joined.pages[1]).frame.maxY, joined.canvas.height)
    }

    func testDisplaySizesUseGlobalColumnsAndEachRowsTallestPage() throws {
        let sizes = [CGSize(width: 300, height: 200), CGSize(width: 200, height: 800),
                     CGSize(width: 100, height: 400), CGSize(width: 400, height: 300)]
        let layout = PageRows.layout(displaySizes: sizes, viewport: CGSize(width: 100, height: 100), page: 0,
            continuous: true, spread: true, cover: false, rtl: false)
        let pages = try layout.pages.map { try XCTUnwrap($0) }
        XCTAssertEqual(pages.map { $0.frame.size }, sizes, "Geometry must not rescale already sized pages")
        XCTAssertEqual(pages.map(\.scale), [1, 1, 1, 1])
        XCTAssertEqual(pages.map { $0.frame.minY }, [4, 4, 812, 812])
        XCTAssertEqual(pages.map { $0.frame.minX }, [4, 312, 204, 312])
        XCTAssertEqual(pages[0].frame.maxX, pages[2].frame.maxX, "Left pages align at the book spine")
        XCTAssertEqual(layout.canvas, CGSize(width: 716, height: 1216))
    }

    func testLandscapeRowsUseTheFullFacingWidthAndMirrorWithRTL() throws {
        let sizes = [CGSize(width: 300, height: 500), CGSize(width: 200, height: 600), CGSize(width: 900, height: 350),
                     CGSize(width: 250, height: 400), CGSize(width: 400, height: 450)]
        let layout = PageRows.layout(displaySizes: sizes, viewport: CGSize(width: 100, height: 100), page: 2,
            continuous: true, spread: true, cover: false, rtl: false, landscape: [2])
        let pages = try layout.pages.map { try XCTUnwrap($0) }
        XCTAssertEqual(layout.rows, [0..<2, 2..<3, 3..<5])
        XCTAssertEqual(pages.map { $0.frame.minY }, [4, 4, 612, 970, 970])
        XCTAssertEqual(pages[2].frame, CGRect(x: 4, y: 612, width: 900, height: 350))
        XCTAssertEqual(layout.canvas, CGSize(width: 908, height: 1424))
        XCTAssertEqual(pages[0].frame.maxX + 8, pages[1].frame.minX)
        let rtl = PageRows.layout(displaySizes: sizes, viewport: CGSize(width: 100, height: 100), page: 2,
            continuous: true, spread: true, cover: false, rtl: true, landscape: [2])
        XCTAssertEqual(rtl.rows, layout.rows)
        for index in sizes.indices {
            let mirrored = try XCTUnwrap(rtl.pages[index])
            XCTAssertEqual(mirrored.frame.minX, layout.canvas.width - pages[index].frame.maxX)
            XCTAssertEqual(mirrored.frame.minY, pages[index].frame.minY)
        }
        let paged = PageRows.layout(displaySizes: sizes, viewport: CGSize(width: 1000, height: 800), page: 2,
            continuous: false, spread: true, cover: false, rtl: false, landscape: [2])
        XCTAssertEqual(paged.rows, [2..<3])
        XCTAssertEqual(paged.pages.compactMap { $0 }.count, 1)
        XCTAssertEqual(try XCTUnwrap(paged.pages[2]).frame, CGRect(x: 50, y: 225, width: 900, height: 350))
    }

    func testFreePanAddsOuterScrollRoomWithoutChangingRowsOrPageSizes() throws {
        let sizes = [CGSize(width: 250, height: 500), CGSize(width: 300, height: 600), CGSize(width: 900, height: 350)]
        let viewport = CGSize(width: 1000, height: 700)
        for continuous in [false, true] {
            let fixed = PageRows.layout(displaySizes: sizes, viewport: viewport, page: 0,
                continuous: continuous, spread: true, cover: true, rtl: true, landscape: [2])
            let pan = PageRows.layout(displaySizes: sizes, viewport: viewport, page: 0,
                continuous: continuous, spread: true, cover: true, rtl: true, landscape: [2], freePan: true)
            XCTAssertEqual(pan.rows, fixed.rows)
            XCTAssertEqual(pan.canvas, CGSize(width: fixed.canvas.width + viewport.width, height: fixed.canvas.height + viewport.height))
            for index in sizes.indices {
                guard let page = fixed.pages[index] else { XCTAssertNil(pan.pages[index]); continue }
                let padded = try XCTUnwrap(pan.pages[index])
                XCTAssertEqual(padded.frame, page.frame.offsetBy(dx: viewport.width / 2, dy: viewport.height / 2))
                XCTAssertEqual(padded.scale, page.scale)
            }
        }
    }

    func testLandscapePagesOccupyTheirOwnRowsWithoutSkippingPortraits() {
        let rows = PageRows.ranges(count: 9, spread: true, landscape: [2, 5, 6])
        XCTAssertEqual(rows, [0..<2, 2..<3, 3..<5, 5..<6, 6..<7, 7..<9])
        XCTAssertEqual(PageRows.ranges(count: 6, spread: true, landscape: [3]), [0..<2, 2..<3, 3..<4, 4..<6])
        XCTAssertEqual(PageRows.ranges(count: 6, spread: true, cover: true, landscape: [2, 4]), [0..<1, 1..<2, 2..<3, 3..<4, 4..<5, 5..<6])
    }
    func testSingleAndRigidPDFRowsIgnoreImagePairing() {
        XCTAssertEqual(PageRows.ranges(count: 4, spread: false, cover: true, landscape: [0, 1, 2]), [0..<1, 1..<2, 2..<3, 3..<4])
        XCTAssertEqual(PageRows.ranges(count: 5, spread: true), [0..<2, 2..<4, 4..<5])
        XCTAssertEqual(PageRows.ranges(count: 5, spread: true, cover: true), [0..<1, 1..<3, 3..<5])
        XCTAssertEqual(PageRows.ranges(count: 0, spread: true), [])
        XCTAssertEqual(PageRows.range(page: 0, count: 6, spread: true, cover: true), 0..<1)
        XCTAssertEqual(PageRows.range(page: 2, count: 6, spread: true, cover: true), 1..<3)
        XCTAssertEqual(PageRows.range(page: 5, count: 6, spread: true, cover: true), 5..<6)
        XCTAssertEqual(PageRows.range(page: 4, count: 5, spread: true), 4..<5)
        XCTAssertEqual(PageRows.range(page: 0, count: 0, spread: true), 0..<0)
    }
    func testNavigationAndContinuousGroupingAgreeForEveryShortImageSequence() {
        for mask in 0..<256 {
            let wide = Set((0..<8).filter { mask & (1 << $0) != 0 })
            for cover in [false, true] {
                let rows = PageRows.ranges(count: 8, spread: true, cover: cover, landscape: wide)
                XCTAssertEqual(rows.flatMap(Array.init), Array(0..<8))
                for page in 0..<8 {
                    XCTAssertEqual(PageRows.range(page: page, count: 8, spread: true, cover: cover, landscape: wide), rows.first { $0.contains(page) })
                }
            }
        }
    }
}
