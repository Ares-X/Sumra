#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import SumraCore

@MainActor final class ReaderReadingSettingsPanel: NSPanel {
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

    func reveal(reducedMotion: Bool = ReaderMotion.reducedMotion) {
        motionRevision += 1
        dismissing = false
        ignoresMouseEvents = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0 : ReaderMotion.revealDuration
            context.timingFunction = ReaderMotion.timingFunction
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
    private var uniformMargin: Double? {
        guard let margins = state.pageMargins else { return state.margin }
        return margins.values.allSatisfy { $0 == margins.top } ? margins.top : nil
    }

    var body: some View {
        let _ = language
        let _ = customThemes
        Form {
            Section {
                if let document = state.document { Text(document.url.lastPathComponent).font(.headline) }
                Text(L("Changes appear in your document immediately.")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Theme"), selection: Binding(get: { state.theme }, set: { value in
                    state.setTheme(value)
                })) {
                    ForEach(ReaderTheme.choices(selected: state.theme)) { theme in Text(theme.displayName).tag(theme.id) }
                }
                HStack {
                    Button(L("Choose Theme…"), action: state.chooseTheme)
                    Spacer()
                    Button(L("Custom Document Colors…"), action: state.configureDocumentColors)
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
                        Slider(value: Binding(get: { uniformMargin ?? state.margin }, set: { value in
                            state.captureReflowPosition()
                            state.margin = value; state.pageMargins = PageMargins(cssValues: [value]); state.applyTypography()
                        }), in: PageMargins.supportedRange, step: 1)
                            .accessibilityLabel(L("Margins"))
                        Text(uniformMargin.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? L("Custom"))
                            .monospacedDigit().lineLimit(1).frame(minWidth: 50)
                    }
                    Toggle(L("Use document styles"), isOn: typography(\.useDocumentCSS))
                    Toggle(L("Use Changes as Defaults"), isOn: Binding(get: { state.typographyForAll }, set: { value in
                        state.typographyForAll = value; state.applyTypography()
                    }))
                    DisclosureGroup(L("Advanced Typography and CSS"), isExpanded: $advanced) {
                        TextField(L("Margins: top right bottom left"), text: $marginsDraft)
                            .onSubmit(applyAdvanced)
                        Text(L("Leave margins blank to use the document default.")).font(.caption).foregroundStyle(.secondary)
                        ReaderCSSDraftEditor(text: $cssDraft).frame(height: 135)
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
        .onAppear(perform: resetDrafts)
        .onChange(of: language) { _ in
            state.window?.childWindows?.first(where: { $0 is ReaderReadingSettingsPanel })?.title = L("Reading Settings")
        }
        .onChange(of: state.document?.id) { _ in
            resetDrafts(); advanced = false
        }
        .onChange(of: state.pageMargins) { _ in marginsDraft = marginValues }
        .onChange(of: state.userCSS) { cssDraft = $0 }
    }

    private var marginValues: String {
        state.pageMargins.map { $0.values.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: " ") } ?? ""
    }

    private func resetDrafts() {
        cssDraft = state.userCSS; marginsDraft = marginValues; error = ""
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
        if let uniformMargin { state.margin = uniformMargin }
        state.userCSS = cssDraft
        state.applyTypography()
        error = ""
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
        combo.addItems(withObjectValues: ["system", "serif", "sans-serif", "monospace"] + ReaderFontPicker.families)
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
