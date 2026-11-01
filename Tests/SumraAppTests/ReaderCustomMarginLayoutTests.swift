#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderCustomMarginLayoutTests: XCTestCase {
    func testSelectingCustomKeepsContentGeometryAndChromePolicyForEveryPreset() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.typographyForAll = false
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/custom-margin-layout.txt"), content: .text("Text"))
        state.immersiveControls = false
        state.toolbarDisplayMode = .auto
        state.setControlMargins(top: 73, bottom: 39)
        for preset in ReaderMarginPreset.allCases {
            state.applyMarginPreset(preset)
            let margins = state.contentMargins
            let extends = state.extendsReadingUnderChrome
            XCTAssertTrue(extends, "Temporary native chrome must not add a titlebar-sized gap to any page margin")
            XCTAssertEqual(state.controlTopMargin, 73)
            XCTAssertEqual(state.controlBottomMargin, 39)

            state.selectCustomMargins()
            XCTAssertNil(state.marginPreset, "The picker must retain explicit Custom intent")
            XCTAssertEqual(state.contentMargins, margins, "Selecting Custom must not move the text")
            XCTAssertEqual(state.controlTopMargin, 73, "Content margin choices must preserve independent toolbar spacing")
            XCTAssertEqual(state.controlBottomMargin, 39, "Content margin choices must preserve independent progress spacing")
            XCTAssertEqual(state.extendsReadingUnderChrome, extends, "Changing picker intent must not reclaim or reserve window space")

            state.setCustomMargins(preset.margins(reflow: true))
            XCTAssertNil(state.marginPreset)
            XCTAssertEqual(state.controlTopMargin, 73)
            XCTAssertEqual(state.controlBottomMargin, 39)
            XCTAssertEqual(state.extendsReadingUnderChrome, extends)
        }
        state.setCustomMargins(PageMargins(cssValues: [9, 17, 25, 33]))
        XCTAssertEqual(state.controlTopMargin, 73)
        XCTAssertEqual(state.controlBottomMargin, 39)
        let margins = state.contentMargins
        let selection = state.marginPresetSelection
        state.setControlMargins(top: 0, bottom: 61)
        XCTAssertEqual(state.contentMargins, margins)
        XCTAssertEqual(state.marginPresetSelection, selection)
        XCTAssertTrue(state.extendsReadingUnderChrome, "Custom page margins also remain independent of temporary native chrome")
        state.toolbarDisplayMode = .shown
        XCTAssertFalse(state.extendsReadingUnderChrome, "Always Show retains the native toolbar's reserved area")
    }
}
#endif
