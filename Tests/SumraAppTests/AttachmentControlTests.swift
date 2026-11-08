#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class AttachmentControlTests: XCTestCase {
    func testAttachmentControlsFitNamesAndRespectAvailableWidth() {
        let short = PDFAttachmentControls.popup(titles: ["note.txt"], availableWidth: 420)
        let longName = String(repeating: "long-name-", count: 30) + ".pdf"
        let long = PDFAttachmentControls.popup(titles: ["note.txt", longName], availableWidth: 420)
        let label = PDFAttachmentControls.label(name: longName, availableWidth: 420)
        XCTAssertLessThan(short.frame.width, long.frame.width)
        XCTAssertEqual(long.frame.width, 420)
        XCTAssertEqual(label.frame.width, 420)
        XCTAssertEqual(long.cell?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(long.item(at: 1)?.toolTip, longName)
        XCTAssertEqual(label.toolTip, longName)
        long.selectItem(at: 1)
        (long as? PDFAttachmentPopup)?.updateAttachmentToolTip()
        XCTAssertEqual(long.toolTip, longName)
    }
}
#endif
