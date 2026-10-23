#if os(macOS)
import AppKit
import SwiftUI
import SumraCore

@MainActor final class ReaderReadingSettingsPanel: NSPanel {
    static func show(for state: ReaderState) {
        guard let parent = state.window else { return }
        if let panel = parent.childWindows?.first(where: { $0 is ReaderReadingSettingsPanel }) {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = ReaderReadingSettingsPanel(contentRect: CGRect(x: 0, y: 0, width: 430, height: 620),
                                               styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L("Reading Settings")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.tabbingMode = .disallowed
        panel.contentMinSize = NSSize(width: 410, height: 420)
        panel.contentView = NSHostingView(rootView: ReaderReadingSettings(state: state).modifier(ReaderLanguage()))
        panel.setFrameTopLeftPoint(NSPoint(x: parent.frame.maxX - 450, y: parent.frame.maxY - 65))
        parent.addChildWindow(panel, ordered: .above)
        NotificationCenter.default.addObserver(panel, selector: #selector(parentClosed), name: NSWindow.willCloseNotification, object: parent)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func parentClosed(_ notification: Notification) { close() }

    override func close() {
        NotificationCenter.default.removeObserver(self)
        parent?.removeChildWindow(self)
        contentView = nil
        super.close()
    }
}

@MainActor struct ReaderReadingSettings: View {
    @ObservedObject var state: ReaderState
    @AppStorage("customThemes") private var customThemes = "[]"
    @AppStorage("preservePageTurnPosition") private var preservePageTurnPosition = false
    @AppStorage("keepZoomOnLinks") private var keepZoomOnLinks = false
    @State private var advanced = false
    @State private var cssDraft = ""
    @State private var marginsDraft = ""
    @State private var error = ""

    private var typographyAvailable: Bool { state.isText || state.isBrowser || state.reflowable }

    var body: some View {
        let _ = customThemes
        Form {
            Section {
                Text(L("Changes appear in your document immediately.")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Theme"), selection: Binding(get: { state.theme }, set: { value in
                    state.captureReflowPosition(); state.setTheme(value)
                })) {
                    Text(L("System")).tag("system")
                    ForEach(ReaderTheme.all) { theme in Text(theme.displayName).tag(theme.id) }
                }
                if state.supportsPagination {
                    Picker(L("Layout"), selection: Binding(
                        get: { state.spread ? ReaderMenuCommand.twoPages : state.flow == "continuous" ? .continuous : .paged },
                        set: { command in if command != .twoPages || !state.spread { command.run(state) } })) {
                        Text(L("Paged")).tag(ReaderMenuCommand.paged)
                        Text(L("Continuous")).tag(ReaderMenuCommand.continuous)
                        Text(L("Two Pages")).tag(ReaderMenuCommand.twoPages)
                    }
                    Toggle(L("Right-to-left"), isOn: Binding(get: { state.rtl }, set: { _ in ReaderMenuCommand.rightToLeft.run(state) }))
                    if state.isFixed {
                        Toggle(L("Cover on its own"), isOn: Binding(get: { state.cover }, set: { _ in ReaderMenuCommand.coverOnItsOwn.run(state) }))
                    }
                }
            }
            if typographyAvailable {
                Section(L("Typography")) {
                    LabeledContent(L("Font")) {
                        ReaderFontNamePicker(selection: typography(\.font, overrideDocumentStyles: true))
                            .frame(minWidth: 180, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                    }
                    LabeledContent(L("Font size")) {
                        Slider(value: typography(\.fontSize, overrideDocumentStyles: true), in: 10...36, step: 1)
                        Text("\(Int(state.fontSize)) pt").monospacedDigit().frame(width: 44)
                    }
                    LabeledContent(L("Line height")) {
                        Slider(value: typography(\.lineHeight, overrideDocumentStyles: true), in: 1...2.4, step: 0.1)
                        Text(state.lineHeight, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 30)
                    }
                    LabeledContent(L("Margins")) {
                        Slider(value: Binding(get: { state.margin }, set: { value in
                            state.captureReflowPosition()
                            state.margin = value; state.pageMargins = PageMargins(cssValues: [value]); state.applyTypography()
                        }), in: 0...96, step: 8)
                        Text("\(Int(state.margin))").monospacedDigit().frame(width: 30)
                    }
                    Toggle(L("Use document styles"), isOn: typography(\.useDocumentCSS))
                    Toggle(L("Use Changes as Defaults"), isOn: Binding(get: { state.typographyForAll }, set: { value in
                        state.typographyForAll = value; state.applyTypography()
                    }))
                    DisclosureGroup(L("Advanced Typography and CSS"), isExpanded: $advanced) {
                        TextField(L("Margins: top right bottom left"), text: $marginsDraft)
                        Text(L("Leave margins blank to use the document default.")).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $cssDraft).font(.system(.body, design: .monospaced)).frame(height: 135)
                        Button(L("Apply Margins and CSS"), action: applyAdvanced)
                        if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
                    }
                }
            }
            Section(L("Navigation")) {
                Toggle(L("Keep scroll position when turning pages"), isOn: $preservePageTurnPosition)
                Toggle(L("Keep current zoom when following links"), isOn: $keepZoomOnLinks)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cssDraft = state.userCSS
            marginsDraft = state.pageMargins.map { "\($0.top) \($0.right) \($0.bottom) \($0.left)" } ?? ""
        }
    }

    private func typography<Value>(_ path: ReferenceWritableKeyPath<ReaderState, Value>, overrideDocumentStyles: Bool = false) -> Binding<Value> {
        Binding(get: { state[keyPath: path] }, set: { value in
            state.captureReflowPosition(); state[keyPath: path] = value
            state.applyTypography(overrideDocumentStyles: overrideDocumentStyles)
        })
    }

    private func applyAdvanced() {
        let value = marginsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, PageMargins(cssValues: value) == nil {
            error = L("Margins must contain 1, 2 or 4 values between 0 and 200.")
            return
        }
        state.captureReflowPosition()
        state.pageMargins = value.isEmpty ? nil : PageMargins(cssValues: value)
        state.userCSS = cssDraft
        state.applyTypography()
        error = ""
    }
}
// NSComboBox keeps the installed-font list and accepts supplemental family names
// that macOS can resolve but does not expose in availableFontFamilies.
@MainActor struct ReaderFontNamePicker: NSViewRepresentable {
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.isEditable = true
        combo.completes = true
        combo.addItems(withObjectValues: ["system", "serif", "sans-serif", "monospace"] + ReaderFontPicker.families)
        combo.setAccessibilityLabel(L("Font"))
        combo.delegate = context.coordinator
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.selection = $selection
        if combo.currentEditor() == nil { combo.stringValue = selection }
    }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox,
                  let family = combo.objectValueOfSelectedItem as? String else { return }
            selection.wrappedValue = family
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let family = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            selection.wrappedValue = family.isEmpty ? "system" : family
        }
    }
}
#endif
