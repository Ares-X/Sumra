#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderAppearanceControlsTests: XCTestCase {
    func testDocumentColorWellOpensTheSystemColorPanelAndClosesWithDialog() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        var wells: [NSColorWell] = []
        inspectModal(response: .alertThirdButtonReturn) { content in
            wells = self.descendants(content, of: NSColorWell.self)
            let well = try XCTUnwrap(wells.last)
            well.activate(true)
            let panel = NSColorPanel.shared
            XCTAssertTrue(well.isActive)
            XCTAssertTrue(panel.isVisible, "The color panel must open while the document-color dialog is modal")
            XCTAssertTrue(panel.worksWhenModal, "The color panel must accept input during the alert's modal session")
        }
        state.configureDocumentColors()
        XCTAssertFalse(NSColorPanel.shared.isVisible)
        XCTAssertTrue(wells.allSatisfy { !$0.isActive })
    }

    func testColorPanelSwitchesExclusiveWellsWithoutChangingOtherInputs() {
        _ = NSApplication.shared
        let editor = ReaderThemeEditorView(theme: ReaderTheme.builtins[0])
        defer { editor.closeColorPanel() }
        editor.text.well.activate(true)
        editor.paper.well.activate(true)
        XCTAssertFalse(editor.text.well.isActive)
        XCTAssertTrue(editor.paper.well.isActive)
        XCTAssertEqual(ReaderTheme.rgb(NSColorPanel.shared.color), editor.paper.value)
        editor.paper.well.color = .white
        editor.paper.well.sendAction(editor.paper.well.action, to: editor.paper.well.target)
        XCTAssertEqual(editor.paper.value, 0xffffff)
        editor.link.well.activate(true)
        XCTAssertFalse(editor.paper.well.isActive)
        XCTAssertEqual(ReaderTheme.rgb(NSColorPanel.shared.color), editor.link.value)
        XCTAssertEqual(editor.paper.value, 0xffffff)
        XCTAssertEqual(editor.preview.theme.background, 0xffffff)
    }

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
            picker.selectItem(at: try XCTUnwrap(ReaderTheme.all.firstIndex { $0.id == "light-warm" }))
        }
        ReaderMenuCommand.setTheme.run(state)
        XCTAssertEqual(state.theme, "light-warm")
    }

    func testDocumentColorEditorAppliesPreviewsAndPersistsAllThreeColors() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["theme", "lastLightTheme"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        let state = ReaderState(recordsHistory: false)
        inspectModal { content in
            let editor = try XCTUnwrap(self.descendants(content, of: ReaderThemeEditorView.self).first)
            XCTAssertNil(editor.name.superview, "Document colors have no saved theme name")
            for input in [editor.text, editor.paper, editor.link] { self.assertClickable(input.well, in: content) }
            for (input, hex) in [(editor.text, "#000000"), (editor.paper, "#FFFFFF"), (editor.link, "#123456")] {
                input.hex.stringValue = hex
                input.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            }
            XCTAssertEqual(editor.preview.theme.link, 0x123456)
            editor.paper.well.activate(true)
        }
        state.configureDocumentColors()
        XCTAssertEqual(state.palette.text, 0x000000)
        XCTAssertEqual(state.palette.background, 0xffffff)
        XCTAssertEqual(state.palette.link, 0x123456)
        XCTAssertEqual(state.documentColors, "smart")
        XCTAssertFalse(NSColorPanel.shared.isVisible)
        let position = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(state.currentPosition))
        let restored = ReaderState(recordsHistory: false)
        restored.apply(position)
        XCTAssertEqual(restored.palette.link, 0x123456)
        XCTAssertEqual(restored.customTextColor, 0x000000)
        XCTAssertEqual(restored.customBackgroundColor, 0xffffff)

        inspectModal(response: .alertSecondButtonReturn) { _ in }
        state.configureDocumentColors()
        XCTAssertNil(state.customTextColor)
        XCTAssertNil(state.customBackgroundColor)
        XCTAssertNil(state.customLinkColor)
        restored.setTheme("light")
        XCTAssertNil(restored.customLinkColor)
    }

    func testTypographyPanelSelectsInstalledAndSupplementalFontsLive() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/font-controls.txt"), content: .text("First paragraph\n\nSecond paragraph"))
        state.typographyForAll = false
        state.font = "serif"; state.page = 1; state.count = 3
        state.location.anchor = "paragraph-17"
        state.reflowable = true
        let before = state.currentPosition
        let parent = appearanceWindow(state: state)
        defer { parent.close(); state.windowClosed() }
        state.editTypography()
        XCTAssertNil(NSApp.modalWindow, "Live typography must not start a modal session")
        let panel = try XCTUnwrap(parent.childWindows?.compactMap { $0 as? ReaderReadingSettingsPanel }.first)
        let content = try XCTUnwrap(panel.contentView)
        var fonts: NSComboBox?
        for _ in 0..<100 {
            content.layoutSubtreeIfNeeded()
            fonts = descendants(content, of: NSComboBox.self).first
            if let fonts, fonts.bounds.width >= 100, fonts.bounds.height >= 22 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let combo = try XCTUnwrap(fonts)
        assertClickable(combo, in: content)
        XCTAssertTrue(combo.isEditable)
        XCTAssertTrue(combo.objectValues.contains { ($0 as? String) == "Georgia" })
        let delegate = try XCTUnwrap(combo.delegate as? ReaderFontNamePicker.Coordinator)
        combo.selectItem(withObjectValue: "Georgia")
        delegate.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: combo))
        XCTAssertEqual(state.font, "Georgia")
        XCTAssertEqual(state.pendingReflowPosition?.anchor, before.anchor)
        XCTAssertEqual(state.pendingReflowPosition?.font, "serif", "Capture the original paragraph before applying the font")
        state.pendingReflowPosition = nil
        combo.stringValue = "Iowan Old Style"
        delegate.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: combo))
        XCTAssertEqual(state.font, "Iowan Old Style", "Supplemental family names remain editable even when omitted from the installed-family menu")
        XCTAssertEqual(state.pendingReflowPosition?.anchor, before.anchor)
        XCTAssertEqual(state.pendingReflowPosition?.font, "Georgia")
        panel.close()
        XCTAssertEqual(state.font, "Iowan Old Style", "Closing the live panel retains its applied changes")
    }

    func testCancelKeepsThemeColorsAndClosingUntouchedTypographyPanelKeepsFont() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.theme = "light"; state.font = "serif"
        state.customTextColor = 0x123456; state.customBackgroundColor = 0xffffff; state.customLinkColor = 0xabcdef
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
        XCTAssertEqual(state.customLinkColor, 0xabcdef)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/unchanged-font.txt"), content: .text("Unchanged paragraph"))
        let parent = appearanceWindow(state: state)
        defer { parent.close(); state.windowClosed() }

        state.editTypography()
        XCTAssertNil(NSApp.modalWindow)
        let panel = try XCTUnwrap(parent.childWindows?.compactMap { $0 as? ReaderReadingSettingsPanel }.first)
        panel.close()
        XCTAssertEqual(state.font, "serif")
    }

    func testCustomThemeCanBeSavedEditedAndDeletedThroughTheDialog() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["customThemes", "customCommands", "theme", "lastLightTheme", "lastDarkTheme"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.removeObject(forKey: "customThemes")
        defaults.removeObject(forKey: "customCommands")
        let state = ReaderState(recordsHistory: false)
        state.customBackgroundColor = 0x123456
        inspectModal { content in
            let editor = try XCTUnwrap(self.descendants(content, of: ReaderThemeEditorView.self).first)
            editor.name.stringValue = "My Paper"
            editor.text.hex.stringValue = "#112233"
            editor.paper.hex.stringValue = "#FFFFFF"
            editor.link.hex.stringValue = "#3366CC"
            XCTAssertTrue(editor.isValid)
        }
        state.editTheme(ReaderTheme.builtins[0])
        let theme = try XCTUnwrap(ReaderTheme.resolve(state.theme))
        XCTAssertTrue(theme.isCustom)
        XCTAssertEqual(theme.name, "My Paper")
        XCTAssertEqual(theme.text, 0x112233); XCTAssertEqual(theme.background, 0xffffff); XCTAssertEqual(theme.link, 0x3366cc)
        XCTAssertNil(state.customBackgroundColor, "Selecting a complete theme must reveal its palette")
        inspectModal { content in
            let editor = try XCTUnwrap(self.descendants(content, of: ReaderThemeEditorView.self).first)
            editor.name.stringValue = "Edited Paper"; editor.paper.hex.stringValue = "#EFE8DD"
        }
        state.editTheme(theme)
        XCTAssertEqual(state.theme, theme.id)
        XCTAssertEqual(ReaderTheme.custom().count, 1)
        let edited = try XCTUnwrap(ReaderTheme.resolve(theme.id))
        XCTAssertEqual(edited.name, "Edited Paper"); XCTAssertEqual(state.palette.background, 0xefe8dd)
        inspectModal(response: .alertThirdButtonReturn) { _ in }
        state.editTheme(edited)
        XCTAssertEqual(state.theme, "light"); XCTAssertTrue(ReaderTheme.custom().isEmpty)
        XCTAssertNotEqual(defaults.string(forKey: "lastLightTheme"), theme.id)
    }

    func testCustomThemePreviewFollowsColorInputAndRejectsIncompleteRGB() {
        let editor = ReaderThemeEditorView(theme: ReaderTheme.builtins[0])
        editor.paper.hex.stringValue = "#FFF"
        editor.paper.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(editor.isValid)
        editor.paper.hex.stringValue = "#F1E4CE"
        editor.paper.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(editor.isValid)
        XCTAssertEqual(editor.preview.theme.background, 0xf1e4ce)
        XCTAssertEqual(ReaderTheme.rgb(editor.paper.well.color), 0xf1e4ce)
    }

    func testAdvancedSettingsImportRestoresCustomPaletteAndRetiredThemeIDs() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["customThemes", "customCommands", "theme", "lastDarkTheme", "lastLightTheme"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        let palette = ReaderTheme.makeCustom(name: "Imported Paper", text: 0x222222, background: 0xffffff, link: 0x0055aa)
        let json = String(decoding: try JSONEncoder().encode([palette]), as: UTF8.self)
        defaults.removeObject(forKey: "customThemes")
        let commands = "[{\"name\":\"My theme\",\"command\":\"setTheme\",\"arguments\":{\"theme\":\"\(palette.id)\"}}]"
        try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: ["theme": palette.id, "customThemes": json, "customCommands": commands]))
        XCTAssertEqual(ReaderTheme.resolve(palette.id), palette)
        XCTAssertEqual(try ReaderConfiguredCommand.read(commands).count, 1)
        XCTAssertThrowsError(try ReaderTheme.deleteCustom(id: palette.id))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderPreferences.data()) as? [String: Any])
        XCTAssertEqual(exported["customThemes"] as? String, json)
        XCTAssertThrowsError(try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: ["theme": palette.id, "customThemes": "[]"])))
        XCTAssertEqual(ReaderTheme.resolve(palette.id), palette)
        try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: ["theme": "solarized-dark"]))
        XCTAssertEqual(defaults.string(forKey: "theme"), "solarized-dark")
        XCTAssertEqual(try ReaderConfiguredCommand.read("[{\"name\":\"Old theme\",\"command\":\"setTheme\",\"arguments\":{\"theme\":\"solarized-dark\"}}]").count, 1)
        defaults.set(palette.id, forKey: "theme"); defaults.set(palette.id, forKey: "lastLightTheme")
        try ReaderPreferences.apply(JSONSerialization.data(withJSONObject: ["customThemes": "[]", "customCommands": "[]"]))
        XCTAssertEqual(defaults.string(forKey: "theme"), "light")
        XCTAssertEqual(defaults.string(forKey: "lastLightTheme"), "light")
    }

    private func appearanceWindow(state: ReaderState) -> NSWindow {
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: Text("Typography preview").frame(width: 800, height: 700))
        state.window = parent
        return parent
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
        // AppKit hitTest receives a point in the receiver's superview coordinates.
        // A hosted SwiftUI root is flipped even when its window frame is not.
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: content.superview)
        let hit = content.hitTest(center)
        XCTAssertTrue(hit === view || hit?.isDescendant(of: view) == true,
                      "The control must receive clicks: frame=\(view.frame) visible=\(view.visibleRect) window=\(String(describing: view.window?.frame)) content=\(content.frame) contentFlipped=\(content.isFlipped) superFlipped=\(String(describing: content.superview?.isFlipped)) point=\(center) hit=\(String(describing: hit))", file: file, line: line)
    }
}
#endif
