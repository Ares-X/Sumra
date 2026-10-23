#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class ReaderAppearanceControlsTests: XCTestCase {
    func testThemeDialogDisplaysClickableChoicesAndAppliesSelection() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let defaults = UserDefaults.standard
        let keys = ["theme", "lastLightTheme"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        state.theme = "light"
        inspectModal { content in
            let picker = try XCTUnwrap(self.descendants(content, of: NSPopUpButton.self).first)
            self.assertClickable(picker, in: content)
            XCTAssertEqual(picker.numberOfItems, ReaderTheme.all.count)
            picker.selectItem(at: 2)
        }
        ReaderMenuCommand.setTheme.run(state)
        XCTAssertEqual(state.theme, "light-warm")
    }

    func testDocumentColorWellsAreClickableAndApplyPureWhitePaper() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        inspectModal { content in
            let wells = self.descendants(content, of: NSColorWell.self)
            XCTAssertEqual(wells.count, 2)
            for well in wells { self.assertClickable(well, in: content) }
            try XCTUnwrap(wells.first).color = .black
            try XCTUnwrap(wells.last).color = .white
        }
        state.configureDocumentColors()
        XCTAssertEqual(state.palette.text, 0x000000)
        XCTAssertEqual(state.palette.background, 0xffffff)
        XCTAssertEqual(state.documentColors, "smart")

        inspectModal(response: .alertSecondButtonReturn) { _ in }
        state.configureDocumentColors()
        XCTAssertNil(state.customTextColor)
        XCTAssertNil(state.customBackgroundColor)
    }

    func testTypographyDialogCanSelectInstalledIowanFamily() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.typographyForAll = false
        inspectModal { content in
            let fonts = try XCTUnwrap(self.descendants(content, of: NSComboBox.self).first)
            self.assertClickable(fonts, in: content)
            XCTAssertTrue(fonts.objectValues.contains { ($0 as? String) == "Georgia" },
                          "Available installed families must appear in the list")
            // macOS may hide a supplemental family from its available-font list
            // while still resolving it by name. The editable field supports it.
            fonts.stringValue = "Iowan Old Style"
        }
        state.editTypography()
        XCTAssertEqual(state.font, "Iowan Old Style")
    }

    func testCancelKeepsThemeColorsAndFont() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.theme = "light"; state.font = "serif"
        state.customTextColor = 0x123456; state.customBackgroundColor = 0xffffff
        inspectModal(response: .alertSecondButtonReturn) { content in
            self.descendants(content, of: NSPopUpButton.self).first?.selectItem(at: 3)
        }
        ReaderMenuCommand.setTheme.run(state)
        XCTAssertEqual(state.theme, "light")
        inspectModal(response: .alertThirdButtonReturn) { content in
            for well in self.descendants(content, of: NSColorWell.self) { well.color = .red }
        }
        state.configureDocumentColors()
        XCTAssertEqual(state.customTextColor, 0x123456)
        XCTAssertEqual(state.customBackgroundColor, 0xffffff)
        inspectModal(response: .alertSecondButtonReturn) { content in
            self.descendants(content, of: NSComboBox.self).first?.stringValue = "Iowan Old Style"
        }
        state.editTypography()
        XCTAssertEqual(state.font, "serif")
    }

    private func inspectModal(response: NSApplication.ModalResponse = .alertFirstButtonReturn,
                              _ inspect: @escaping (NSView) throws -> Void) {
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                defer { NSApp.stopModal(withCode: response) }
                do {
                    let content = try XCTUnwrap(NSApp.modalWindow?.contentView)
                    content.layoutSubtreeIfNeeded()
                    try inspect(content)
                } catch { XCTFail("Dialog inspection failed: \(error)") }
            }
        }
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }

    private func assertClickable(_ view: NSView, in content: NSView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(view.bounds.width, 100, file: file, line: line)
        XCTAssertGreaterThanOrEqual(view.bounds.height, 22, file: file, line: line)
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: content)
        let hit = content.hitTest(center)
        XCTAssertTrue(hit === view || hit?.isDescendant(of: view) == true,
                      "The control must receive clicks inside the alert", file: file, line: line)
    }
}
#endif
