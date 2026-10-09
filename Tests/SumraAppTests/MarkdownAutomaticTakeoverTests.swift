#if os(macOS)
import XCTest
@testable import Sumra

@MainActor
final class MarkdownAutomaticTakeoverTests: XCTestCase {
    func testFirstAutomaticTakeoverRetainsCurrentReadingSettingsWithoutBrowserCoordinates() {
        let current = currentSettings()
        let destination = ReaderState.markdownRendererDestination(.paged, saved: .init(), readingSettings: current)
        XCTAssertEqual(destination.zoom, 6)
        XCTAssertEqual(destination.fit, "width")
        XCTAssertEqual(destination.flow, "continuous")
        XCTAssertEqual(destination.font, "serif")
        XCTAssertEqual(destination.fontSize, 19)
        XCTAssertEqual(destination.lineHeight, 2)
        XCTAssertEqual(destination.margin, 48)
        XCTAssertEqual(destination.theme, "dark")
        XCTAssertEqual(destination.userCSS, "p { text-align: left; }")
        XCTAssertEqual(destination.useDocumentCSS, false)
        XCTAssertEqual(destination.automaticLayout, false)
        XCTAssertEqual(destination.scrollbarMode, "shown")
        XCTAssertEqual(destination.page, 0)
        XCTAssertNil(destination.x)
        XCTAssertNil(destination.y)
        XCTAssertNil(destination.anchor)
        XCTAssertNil(destination.markdownPassage)
        let state = ReaderState(recordsHistory: false)
        state.zoom = 1; state.fit = "page"; state.flow = "paged"
        state.apply(destination)
        XCTAssertEqual(state.zoom, 6)
        XCTAssertEqual(state.fit, "width")
        XCTAssertEqual(state.fontSize, 19)
        XCTAssertEqual(state.lineHeight, 2)
        XCTAssertEqual(state.theme, "dark")
    }

    func testAutomaticTakeoverKeepsSavedNativeLocationButUsesCurrentSettings() {
        let native = NativePassage(source: .init(node: 7, offset: 3, part: 0), offsetX: 2, offsetY: 4,
                                   sourceRevision: "owned-source", styleSignature: "owned-style")
        let saved = ReadingPosition(page: 42, pageCount: 100, x: 12, y: 34, anchor: "native-location", nativePassage: native,
                                    markdownRenderer: .paged, zoom: 1.25, fit: "page", fontSize: 15, theme: "light")
        let destination = ReaderState.markdownRendererDestination(.paged, saved: saved, readingSettings: currentSettings())
        XCTAssertEqual(destination.page, 42)
        XCTAssertEqual(destination.pageCount, 100)
        XCTAssertEqual(destination.x, 12)
        XCTAssertEqual(destination.y, 34)
        XCTAssertEqual(destination.anchor, "native-location")
        XCTAssertEqual(destination.nativePassage, native)
        XCTAssertEqual(destination.zoom, 6)
        XCTAssertEqual(destination.fontSize, 19)
        XCTAssertEqual(destination.theme, "dark")
    }

    func testExplicitSwitchRetainsSavedModesIndependentSettings() {
        let saved = ReadingPosition(page: 42, x: 12, y: 34, markdownRenderer: .paged, zoom: 1.25, fit: "page", fontSize: 15, theme: "light")
        let destination = ReaderState.markdownRendererDestination(.paged, saved: saved)
        XCTAssertEqual(destination, saved)
    }

    private func currentSettings() -> ReadingPosition {
        ReadingPosition(page: 0, x: 0, y: 230, anchor: "browser-url",
            markdownPassage: .init(path: [0], offset: 3, top: 12, text: "Generated heading", end: false),
            markdownRenderer: .compatible, zoom: 6, fit: "width", flow: "continuous", font: "serif", fontSize: 19,
            lineHeight: 2, margin: 48, theme: "dark", userCSS: "p { text-align: left; }", useDocumentCSS: false,
            automaticLayout: false, scrollbarMode: "shown")
    }
}
#endif
