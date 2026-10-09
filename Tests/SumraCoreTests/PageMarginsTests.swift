import XCTest
@testable import SumraCore

final class PageMarginsTests: XCTestCase {
    func testCSSMarginOrderAndPointUnits() throws {
        XCTAssertEqual(try XCTUnwrap(PageMargins(cssValues: "24")).values, [24, 24, 24, 24])
        XCTAssertEqual(try XCTUnwrap(PageMargins(cssValues: "36 24")).values, [36, 24, 36, 24])
        let margins = try XCTUnwrap(PageMargins(cssValues: "1 2 3 4"))
        XCTAssertEqual(margins.values, [1, 2, 3, 4])
        XCTAssertEqual(margins.css, "1.0pt 2.0pt 3.0pt 4.0pt")
        XCTAssertEqual(try JSONDecoder().decode(PageMargins.self, from: JSONEncoder().encode(margins)), margins)
    }
    func testInvalidMarginsAreNotPartiallyApplied() {
        for value in ["", "1 2 3", "1 2 3 4 5", "1 nope 2", "-1", "201", "nan", "inf"] {
            XCTAssertNil(PageMargins(cssValues: value), value)
        }
        for value in ["-1", "201", "1e200"] {
            let data = Data("{\"top\":\(value),\"right\":20,\"bottom\":20,\"left\":20}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(PageMargins.self, from: data))
        }
    }
}
