#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import SumraCore

@MainActor class ReaderReadingSettingsPanel: NSPanel {
    private var motionRevision = 0
    private var dismissing = false
    static func show(for state: ReaderState) {
        guard let parent = state.window else { return }
        if let panel = parent.childWindows?.first(where: { $0 is ReaderReadingSettingsPanel }) as? ReaderReadingSettingsPanel {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.makeKeyAndOrderFront(nil)
            panel.reveal()
            return
        }
        let panel = ReaderReadingSettingsPanel(contentRect: CGRect(x: 0, y: 0, width: 430, height: 620),
                                               styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L("Reading Settings")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.contentMinSize = NSSize(width: 410, height: 420)
        panel.contentView = NSHostingView(rootView: ReaderReadingSettings(state: state).modifier(ReaderLanguage()))
        panel.setFrameTopLeftPoint(NSPoint(x: parent.frame.maxX - 450, y: parent.frame.maxY - 65))
        panel.attach(to: parent)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.reveal()
    }

    func attach(to parent: NSWindow) {
        parent.addChildWindow(self, ordered: .above)
        NotificationCenter.default.addObserver(self, selector: #selector(parentClosed), name: NSWindow.willCloseNotification, object: parent)
    }

    func reveal() {
        motionRevision += 1
        dismissing = false
        ignoresMouseEvents = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
    }

    @objc private func parentClosed(_ notification: Notification) { closeImmediately() }

    override func close() {
        dismiss(reducedMotion: ReaderMotion.reducedMotion)
    }

    func dismiss(reducedMotion: Bool) {
        guard !dismissing else { return }
        dismissing = true
        ignoresMouseEvents = true
        motionRevision += 1
        let revision = motionRevision
        if reducedMotion { closeImmediately(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ReaderMotion.dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.motionRevision == revision else { return }
                self.closeImmediately()
            }
        }
    }

    private func closeImmediately() {
        motionRevision += 1
        NotificationCenter.default.removeObserver(self)
        parent?.removeChildWindow(self)
        contentView = nil
        super.close()
    }
}

@MainActor struct ReaderReadingSettings: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    @AppStorage("customThemes") private var customThemes = "[]"
    @AppStorage("preservePageTurnPosition") private var preservePageTurnPosition = false
    @AppStorage("keepZoomOnLinks") private var keepZoomOnLinks = false
    @State private var advanced = false
    @State private var cssDraft = ""
    @State private var marginsDraft = ""
    @State private var error = ""

    private var typographyAvailable: Bool { state.isText || state.isBrowser || state.reflowable }

    var body: some View {
        let _ = language
        let _ = customThemes
        Form {
            Section(L("Current Document")) {
                if let document = state.document { Text(document.url.lastPathComponent).font(.headline) }
                Button(L("Custom Document Colors…"), action: state.configureDocumentColors)
                Text(L("Layout and custom colors affect only this document."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Section {
                Toggle(isOn: Binding(get: { state.typographyForAll }, set: { value in
                    state.typographyForAll = value; state.applyTypography()
                })) {
                    Text(L("Apply to All and Save Defaults"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(state.typographyForAll
                     ? L("Typography, CSS, content margins and control clearance apply to all open documents and replace saved settings when documents reopen.")
                     : L("Only this document. Earlier changes to other documents and defaults are kept."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state.typographyForAll {
                    Text(L("Turning this off keeps changes already applied."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if typographyAvailable {
                Section(L("Typography")) {
                    LabeledContent(L("Font")) {
                        ReaderFontNamePicker(selection: typography(\.font, overrideDocumentStyles: true))
                            .frame(minWidth: 180, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                    }
                    ReaderNumericSetting(label: L("Font size"), value: typography(\.fontSize, overrideDocumentStyles: true),
                                         range: 10...36, step: 1, unit: "pt")
                    ReaderNumericSetting(label: L("Line height"), value: typography(\.lineHeight, overrideDocumentStyles: true),
                                         range: 1...2.4, step: 0.1, unit: "×")
                    Toggle(L("Use document styles"), isOn: typography(\.useDocumentCSS))
                    DisclosureGroup(L("Advanced Typography and CSS"), isExpanded: $advanced) {
                        ReaderCSSDraftEditor(text: $cssDraft).frame(height: 135)
                        Button(L("Apply CSS"), action: applyAdvanced)
                    }
                }
            }
            Section(L("Content margins")) {
                Picker(L("Margins"), selection: Binding(get: { state.marginPreset }, set: { preset in
                    if let preset { state.applyMarginPreset(preset) }
                    else { state.selectCustomMargins() }
                })) {
                    Text(L("Custom")).tag(nil as ReaderMarginPreset?)
                    ForEach(ReaderMarginPreset.allCases) { preset in Text(preset.title).tag(Optional(preset)) }
                }
                ReaderMarginsControls(margins: Binding(get: { state.contentMargins }, set: state.setCustomMargins),
                                      fallback: state.margin, enabled: state.marginPreset == nil)
                if typographyAvailable {
                    TextField(L("Margins: top right bottom left (pt)"), text: $marginsDraft)
                        .disabled(state.marginPreset != nil).onSubmit(applyMargins)
                    Text(L("Leave margins blank to use the document default."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Apply Margins"), action: applyMargins).disabled(state.marginPreset != nil)
                    if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            Section(L("Control clearance")) {
                ReaderControlMarginsControls(
                    top: Binding(get: { state.controlTopMargin }, set: { state.setControlMargins(top: $0, bottom: state.controlBottomMargin) }),
                    bottom: Binding(get: { state.controlBottomMargin }, set: { state.setControlMargins(top: state.controlTopMargin, bottom: $0) }))
            }
            Section(L("All Reading Windows")) {
                Picker(L("Theme"), selection: Binding(get: { state.theme }, set: { value in
                    state.setTheme(value)
                })) {
                    ForEach(ReaderTheme.choices(selected: state.theme)) { theme in Text(theme.displayName).tag(theme.id) }
                }
                Button(L("Choose Theme…"), action: state.chooseTheme)
                Text(L("Theme changes all reading windows and replaces custom document colors and dividers."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Navigation")) {
                Text(L("Navigation applies to all reading windows."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $preservePageTurnPosition) {
                    Text(L("Keep scroll position when turning pages")).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $keepZoomOnLinks) {
                    Text(L("Keep current zoom when following links")).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .id(state.document?.id)
        .formStyle(.grouped)
        .onAppear(perform: resetDrafts)
        .onChange(of: language) { _ in
            state.window?.childWindows?.first(where: { $0 is ReaderReadingSettingsPanel })?.title = L("Reading Settings")
        }
        .onChange(of: state.document?.id) { _ in
            resetDrafts(); advanced = false
        }
        .onChange(of: state.pageMargins) { _ in resetMarginsDraft() }
        .onChange(of: state.marginPreset) { _ in resetMarginsDraft() }
        .onChange(of: state.userCSS) { cssDraft = $0 }
    }

    private var marginValues: String {
        state.contentMargins.map { $0.values.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: " ") } ?? ""
    }

    private func resetDrafts() {
        cssDraft = state.userCSS
        resetMarginsDraft()
    }

    private func resetMarginsDraft() {
        marginsDraft = marginValues
        error = ""
    }

    private func typography<Value>(_ path: ReferenceWritableKeyPath<ReaderState, Value>, overrideDocumentStyles: Bool = false) -> Binding<Value> {
        Binding(get: { state[keyPath: path] }, set: { value in
            state.captureReflowPosition(); state[keyPath: path] = value
            state.applyTypography(overrideDocumentStyles: overrideDocumentStyles)
        })
    }

    private func applyMargins() {
        let value = marginsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, PageMargins(cssValues: value) == nil {
            error = L("Margins must contain 1, 2 or 4 values between 0 and 200.")
            return
        }
        state.setCustomMargins(value.isEmpty ? nil : PageMargins(cssValues: value))
        error = ""
    }

    private func applyAdvanced() {
        state.captureReflowPosition()
        state.userCSS = cssDraft
        state.applyTypography()
    }
}

// Commit typing on Return or focus loss, preserving the in-progress draft while
// the document continues showing the last accepted value.
@MainActor struct ReaderNumericField: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(value: $value, range: range) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        field.toolTip = "\(range.lowerBound.formatted())–\(range.upperBound.formatted())"
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.value = $value
        field.setAccessibilityLabel(label)
        if field.currentEditor() == nil { field.stringValue = Coordinator.string(value) }
        field.isEnabled = context.environment.isEnabled
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<Double>
        let range: ClosedRange<Double>
        init(value: Binding<Double>, range: ClosedRange<Double>) { self.value = value; self.range = range }
        static func string(_ value: Double) -> String {
            let text = value == value.rounded() ? String(Int(value)) : String(value)
            return text.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            if let number = Double(text), number.isFinite, range.contains(number) {
                value.wrappedValue = number
                field.stringValue = Self.string(number)
            } else {
                NSSound.beep()
                field.stringValue = Self.string(value.wrappedValue)
            }
        }
    }
}

@MainActor struct ReaderNumericSetting: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: $value, in: range, step: step).accessibilityLabel(label)
            ReaderNumericField(value: $value, range: range, label: "\(label) (\(unit))")
                .frame(width: 58)
            Text(unit).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
        }
    }
}

@MainActor struct ReaderMarginsControls: View {
    @Binding var margins: PageMargins?
    let fallback: Double
    let enabled: Bool

    var body: some View {
        if !enabled {
            Text(L("Choose Custom in Margins to edit individual values."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(0..<4, id: \.self) { index in
            ReaderNumericSetting(label: [L("Top margin"), L("Right margin"), L("Bottom margin"), L("Left margin")][index],
                                 value: side(index), range: PageMargins.supportedRange, step: 1, unit: "pt")
                .disabled(!enabled)
        }
    }
    private func side(_ index: Int) -> Binding<Double> {
        Binding(get: { (margins?.values ?? Array(repeating: fallback, count: 4))[index] }, set: { value in
            var values = margins?.values ?? Array(repeating: fallback, count: 4)
            values[index] = value
            margins = PageMargins(cssValues: values)
        })
    }
}

@MainActor struct ReaderControlMarginsControls: View {
    @Binding var top: Double
    @Binding var bottom: Double

    var body: some View {
        ReaderNumericSetting(label: L("Top clearance"), value: $top,
                             range: PageMargins.supportedRange, step: 1, unit: "pt")
        ReaderNumericSetting(label: L("Bottom clearance"), value: $bottom,
                             range: PageMargins.supportedRange, step: 1, unit: "pt")
        Text(L("Space reserved from the window edge for floating controls. Set to 0 to allow overlap. Content margins are counted once; hidden controls reserve no space."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor struct ReaderCSSDraftEditor: NSViewRepresentable {
    @Binding var text: String
    var label = L("Advanced Typography and CSS")

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.setAccessibilityLabel(label)
        editor.delegate = context.coordinator
        editor.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        let editor = scroll.documentView as! NSTextView
        editor.setAccessibilityLabel(label)
        if editor.string != text { editor.string = text }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
// NSComboBox keeps the installed-font list and accepts supplemental family names
// that macOS can resolve but does not expose in availableFontFamilies.
@MainActor struct ReaderFontNamePicker: NSViewRepresentable {
    @Binding var selection: String
    var label = L("Font")

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.isEditable = true
        combo.completes = true
        combo.addItems(withObjectValues: ["system", "serif", "sans-serif", "monospace"])
        combo.setAccessibilityLabel(label)
        combo.delegate = context.coordinator
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.selection = $selection
        combo.setAccessibilityLabel(label)
        if combo.currentEditor() == nil { combo.stringValue = selection }
    }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var selection: Binding<String>
        private var fontsLoaded = false
        init(selection: Binding<String>) { self.selection = selection }
        func comboBoxWillPopUp(_ notification: Notification) { loadFonts(notification.object as? NSComboBox) }
        func controlTextDidBeginEditing(_ notification: Notification) { loadFonts(notification.object as? NSComboBox) }
        private func loadFonts(_ combo: NSComboBox?) {
            guard let combo, !fontsLoaded else { return }
            fontsLoaded = true
            combo.addItems(withObjectValues: ReaderFontPicker.families)
        }
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
