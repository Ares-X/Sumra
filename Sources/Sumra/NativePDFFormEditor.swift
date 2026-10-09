#if os(macOS)
import AppKit

// Adapted from SumatraPDF FormFields.cpp (GPL-3.0): one native control floats
// over the active field. MuPDF owns
// validation, calculations and the committed value; this object owns only input.
@MainActor
final class NativePDFFormEditor: NSObject, NSComboBoxDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let widget: PDFAnnotationSnapshot
    private weak var host: NSView?
    private let commitValue: (String) async throws -> Void
    private let didClose: () -> Void
    private let advance: (Bool) -> Void
    private let failure: (Error) -> Void
    private let container: NSView
    private var field: NSTextField?
    private var textView: FormTextView?
    private var table: FormChoiceView?
    private var commitTask: Task<Void, Error>?
    private var completed: Bool?
    private var validationFailed = false
    private var comboExportValue: String?
    private var isChoice: Bool { table != nil }

    init(widget: PDFAnnotationSnapshot, host: NSView, frame: CGRect,
         commitValue: @escaping (String) async throws -> Void,
         didClose: @escaping () -> Void, advance: @escaping (Bool) -> Void,
         failure: @escaping (Error) -> Void) {
        self.widget = widget; self.host = host; self.commitValue = commitValue
        self.didClose = didClose; self.advance = advance; self.failure = failure
        let flags = widget.fieldFlags ?? 0
        if widget.fieldType == 3 && flags & (1 << 18) != 0 {
            let input = FormComboBox()
            input.addItems(withObjectValues: widget.options?.map(FormComboOption.init) ?? [])
            input.completes = false
            field = input; container = input
        } else if widget.fieldType == 3 || widget.fieldType == 4 {
            let scroll = NSScrollView()
            let list = FormChoiceView()
            let column = NSTableColumn(identifier: .init("value"))
            list.addTableColumn(column); list.headerView = nil
            list.allowsEmptySelection = true; list.allowsMultipleSelection = false
            list.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            scroll.documentView = list; scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
            table = list; container = scroll
        } else if flags & (1 << 13) != 0 {
            let input = NSSecureTextField(); field = input; container = input
        } else if flags & (1 << 12) != 0 {
            let scroll = NSScrollView()
            let input = FormTextView()
            input.isRichText = false; input.importsGraphics = false
            input.allowsUndo = true
            input.isHorizontallyResizable = false; input.isVerticallyResizable = true
            input.autoresizingMask = [.width]
            input.textContainer?.widthTracksTextView = true
            input.textContainerInset = NSSize(width: 2, height: 2)
            scroll.documentView = input; scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
            textView = input; container = scroll
        } else {
            let input = NSTextField(); field = input; container = input
        }
        super.init()
        field?.stringValue = widget.value ?? ""
        if let combo = field as? NSComboBox,
           let index = widget.options?.firstIndex(where: { $0.value == widget.value }) {
            combo.selectItem(at: index)
            comboExportValue = widget.options?[index].value
        }
        let alignment: NSTextAlignment = widget.alignment == 1 ? .center : widget.alignment == 2 ? .right : .left
        field?.alignment = alignment
        if let maximum = widget.maxLength, maximum > 0 {
            // EM_SETLIMITTEXT in FormFields.cpp. A formatter keeps the standard
            // field editor (including secure input and IME composition) intact.
            field?.formatter = FormTextLengthFormatter(maximum: maximum)
            textView?.maximumLength = maximum
        }
        field?.setAccessibilityLabel(widget.fieldLabel ?? widget.fieldName ?? "")
        textView?.delegate = self; textView?.string = widget.value ?? ""
        textView?.alignment = alignment
        textView?.setAccessibilityLabel(widget.fieldLabel ?? widget.fieldName ?? "")
        textView?.didResign = { [weak self] in self?.lostFocus() }
        if let table {
            table.dataSource = self; table.delegate = self; table.target = self
            table.action = #selector(choose); table.command = { [weak self] in self?.command($0) ?? false }
            table.didResign = { [weak self] in self?.lostFocus() }
            table.setAccessibilityLabel(widget.fieldLabel ?? widget.fieldName ?? "")
            table.reloadData()
            if let index = widget.options?.firstIndex(where: { $0.value == widget.value }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        host.addSubview(container)
        updateFrame(frame)
        // selectText also takes focus. Focusing first would end that edit
        // session and submit the field while this editor is still opening.
        if let field { field.selectText(nil) }
        else { focus() }
        // NSComboBox can end an edit while opening its field editor. Only
        // observe input after initial focus has been established.
        field?.delegate = self
        if let textView { textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count)) }
    }

    func updateFrame(_ frame: CGRect) {
        guard completed == nil else { return }
        let height = widget.bounds.height
        let size = max(8, widget.fontSize > 0 && height > 0 ? CGFloat(widget.fontSize) * frame.height / height : frame.height * 0.7)
        let font = NSFont.systemFont(ofSize: size)
        field?.font = font; textView?.font = font
        if let table, let host {
            table.rowHeight = size + 6
            let count = min(widget.options?.count ?? 0, 8)
            let listHeight = CGFloat(max(1, count)) * (table.rowHeight + table.intercellSpacing.height) + 4
            let visible = host.visibleRect
            let width = min(max(frame.width, 120), visible.width)
            let below = host.isFlipped ? frame.maxY : frame.minY - listHeight
            let above = host.isFlipped ? frame.minY - listHeight : frame.maxY
            let y = below >= visible.minY && below + listHeight <= visible.maxY ? below : above
            container.frame = CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                                     y: min(max(y, visible.minY), max(visible.minY, visible.maxY - listHeight)),
                                     width: width, height: min(listHeight, visible.height))
            table.frame.size.width = (container as? NSScrollView)?.contentSize.width ?? width
            table.tableColumns.first?.width = table.frame.width
            let selection = table.selectedRowIndexes
            table.reloadData() // Reconfigure visible cells for the new font size.
            table.selectRowIndexes(selection, byExtendingSelection: false)
            if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        } else {
            container.frame = frame
            if let textView, let scroll = container as? NSScrollView {
                textView.frame.size.width = scroll.contentSize.width
                textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }

    private func beginCommit() -> Task<Void, Error>? {
        guard completed == nil else { return nil }
        if let commitTask { return commitTask }
        let value: String
        if let table {
            guard let options = widget.options, options.indices.contains(table.selectedRow) else { cancel(); return nil }
            value = options[table.selectedRow].value
        } else if let combo = field as? NSComboBox {
            value = comboExportValue ?? combo.stringValue
        } else { value = field?.stringValue ?? textView?.string ?? "" }
        let operation = Task {
            do {
                if value != (widget.value ?? "") { try await commitValue(value) }
                commitTask = nil
                close(committed: true)
            } catch {
                commitTask = nil
                validationFailed = true
                if completed == nil { setEditable(true); focus() }
                throw error
            }
        }
        commitTask = operation
        // Disabling NSTextField ends its field-editor session. Return document
        // commands to the page before that loses the input's focus ownership.
        // commitTask already prevents this focus change from submitting twice.
        returnFocusToHost()
        setEditable(false)
        return operation
    }

    func commit() async throws {
        if let operation = beginCommit() { try await operation.value }
    }

    func cancel() { close(committed: false) }

    private func close(committed: Bool) {
        guard completed == nil else { return }
        completed = committed // before focus changes can deliver another blur
        field?.delegate = nil; textView?.delegate = nil
        textView?.didResign = nil; table?.didResign = nil
        returnFocusToHost()
        container.removeFromSuperview()
        didClose()
    }

    private func returnFocusToHost() {
        if let window = host?.window,
           window.firstResponder === field?.currentEditor() || window.firstResponder === textView || window.firstResponder === table {
            window.makeFirstResponder(host)
        }
    }

    private func setEditable(_ enabled: Bool) {
        field?.isEnabled = enabled; textView?.isEditable = enabled
        table?.isEnabled = enabled
    }

    private func focus() {
        if let field { host?.window?.makeFirstResponder(field) }
        else if let textView { host?.window?.makeFirstResponder(textView) }
        else if let table { host?.window?.makeFirstResponder(table) }
    }

    private func requestCommit(backwards: Bool? = nil) {
        guard completed == nil, commitTask == nil, let operation = beginCommit() else { return }
        Task {
            do {
                try await operation.value
                if completed == true, let backwards { advance(backwards) }
            } catch {
                if completed == nil { failure(error) }
            }
        }
    }

    private func lostFocus() {
        guard completed == nil, commitTask == nil else { return }
        if isChoice { cancel() }
        // Presenting the validation error can itself move focus. Do not submit
        // the rejected value again until the user edits it or explicitly retries.
        else if !validationFailed { requestCommit() }
    }

    @objc private func choose() { requestCommit() }

    private func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        case #selector(NSResponder.insertTab(_:)): requestCommit(backwards: false); return true
        case #selector(NSResponder.insertBacktab(_:)): requestCommit(backwards: true); return true
        case #selector(NSResponder.insertNewline(_:)):
            if textView == nil { requestCommit(); return true }
            return false
        default: return false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        textView.hasMarkedText() ? false : command(commandSelector)
    }
    func controlTextDidEndEditing(_ notification: Notification) { lostFocus() }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object is NSComboBox { comboExportValue = nil }
        validationFailed = false
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // Keep the chosen export while AppKit finishes its text edit. The
        // selection notification arrives before the displayed string changes.
        if let option = (notification.object as? NSComboBox)?.objectValueOfSelectedItem as? FormComboOption {
            comboExportValue = option.choice.value
            validationFailed = false
        }
    }
    func textDidChange(_ notification: Notification) { validationFailed = false }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        textView.hasMarkedText() ? false : command(commandSelector)
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let input = textView as? FormTextView, !input.updatingMarkedText,
              input.maximumLength > 0, let replacementString else { return true }
        let count = textView.string.utf16.count
        let length = count - affectedCharRange.length + replacementString.utf16.count
        // Like the native edit control, permit reducing an already overlong
        // source value; MaxLen restricts user insertion, not loading its /V.
        return length <= input.maximumLength || length <= count
    }
    func numberOfRows(in tableView: NSTableView) -> Int { widget.options?.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let options = widget.options, options.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("choice")
        let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? NSTextField(labelWithString: "")
        label.identifier = identifier; label.stringValue = options[row].label
        label.font = NSFont.systemFont(ofSize: tableView.rowHeight - 6)
        return label
    }
}

// Distinct objects keep typed labels from automatically selecting an export.
private final class FormComboOption: NSObject, NSCopying {
    let choice: PDFAnnotationSnapshot.Choice
    init(_ choice: PDFAnnotationSnapshot.Choice) { self.choice = choice; super.init() }
    override var description: String { choice.label }
    func copy(with zone: NSZone? = nil) -> Any { self }
}

// The standard combo bezel can be translucent. Cover the PDF appearance while
// editing so the committed text cannot show through the user's draft.
private final class FormComboBox: NSComboBox {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}

@MainActor
private final class FormTextView: NSTextView {
    var didResign: (() -> Void)?
    var maximumLength = 0
    private(set) var updatingMarkedText = false
    private var beforeComposition: (text: String, selection: NSRange)?
    private var insertingText = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if maximumLength > 0, !hasMarkedText() { beforeComposition = (self.string, self.selectedRange()) }
        updatingMarkedText = true
        defer { updatingMarkedText = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        // AppKit can remove the marked range while unmarking. Check the
        // composition before that happens, or an oversized replacement would
        // erase the previous field value instead of restoring it.
        let rejected: (text: String, selection: NSRange)?
        if !insertingText, !updatingMarkedText, maximumLength > 0,
           let original = beforeComposition, string.utf16.count > maximumLength,
           string.utf16.count > original.text.utf16.count { rejected = original }
        else { rejected = nil }
        super.unmarkText()
        if let rejected {
            string = rejected.text
            setSelectedRange(rejected.selection)
            beforeComposition = nil
        } else if !insertingText { finishComposition() }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        insertingText = true
        defer { insertingText = false; finishComposition() }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    private func finishComposition() {
        guard !updatingMarkedText, !hasMarkedText() else { return }
        // Ending composition on focus loss need not insert text again. Reject
        // an oversized committed composition only after the IME has finished.
        if maximumLength > 0, let original = beforeComposition,
           string.utf16.count > maximumLength, string.utf16.count > original.text.utf16.count {
            string = original.text
            setSelectedRange(original.selection)
        }
        beforeComposition = nil
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { didResign?() }
        return result
    }
}

private final class FormTextLengthFormatter: Formatter {
    private let maximum: Int
    init(maximum: Int) { self.maximum = maximum; super.init() }
    required init?(coder: NSCoder) { nil }
    override func string(for obj: Any?) -> String? { obj as? String }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }
    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
                                      proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
                                      originalString origString: String, originalSelectedRange origSelRange: NSRange,
                                      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let count = partialStringPtr.pointee.length
        return count <= maximum || count <= origString.utf16.count
    }
}

@MainActor
private final class FormChoiceView: NSTableView {
    var command: ((Selector) -> Bool)?
    var didResign: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let selector: Selector?
        switch event.keyCode {
        case 53: selector = #selector(NSResponder.cancelOperation(_:))
        case 48: selector = event.modifierFlags.contains(.shift) ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:))
        case 36, 76: selector = #selector(NSResponder.insertNewline(_:))
        default: selector = nil
        }
        if let selector, command?(selector) == true { return }
        super.keyDown(with: event)
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { didResign?() }
        return result
    }
}
#endif
