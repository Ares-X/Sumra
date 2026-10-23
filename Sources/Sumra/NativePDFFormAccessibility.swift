#if os(macOS)
import AppKit

// The page keeps one real input control for the active field. These virtual
// controls make the other painted fields discoverable and activate that same
// input path; committed values and permissions remain with the native owner.
@MainActor
@objcMembers
final class NativePDFFormAccessibilityElement: NSObject, @preconcurrency NSAccessibilityButton {
    weak var host: NSView?
    var widget: PDFAnnotationSnapshot
    var transform = CGAffineTransform.identity
    var enabled = false
    private var focused = false
    private let activate: (PDFAnnotationSnapshot) -> Bool

    init(widget: PDFAnnotationSnapshot, host: NSView, activate: @escaping (PDFAnnotationSnapshot) -> Bool) {
        self.widget = widget; self.host = host; self.activate = activate
    }

    func accessibilityParent() -> Any? { host }
    func accessibilityRole() -> NSAccessibility.Role? {
        switch widget.fieldType {
        case 2: return .checkBox
        case 5: return .radioButton
        default: return .button
        }
    }
    func isAccessibilityElement() -> Bool {
        guard let host, host.window != nil, !host.isHiddenOrHasHiddenAncestor else { return false }
        return host.visibleRect.intersects(widget.bounds.applying(transform))
    }
    func accessibilityLabel() -> String? {
        [widget.fieldLabel, widget.fieldName].compactMap { $0 }.first { !$0.isEmpty } ?? L("Form Field")
    }
    @objc func accessibilityValue() -> Any? {
        // A password field must not publish its stored clear-text PDF value.
        guard widget.fieldType != 7 || (widget.fieldFlags ?? 0) & (1 << 13) == 0 else { return nil }
        if widget.fieldType == 2 || widget.fieldType == 5 {
            return NSNumber(value: widget.value != nil && widget.value != "" && widget.value != "Off")
        }
        if let indices = widget.selectedIndices, !indices.isEmpty, let options = widget.options {
            return indices.map { options[$0].label }.joined(separator: ", ")
        }
        return widget.value ?? ""
    }
    func accessibilityFrame() -> NSRect {
        guard let host, let window = host.window else { return .zero }
        return window.convertToScreen(host.convert(widget.bounds.applying(transform), to: nil))
    }
    func isAccessibilityEnabled() -> Bool { enabled }
    func isAccessibilityFocused() -> Bool { focused }
    func setAccessibilityFocused(_ focused: Bool) { self.focused = focused }
    func accessibilityPerformPress() -> Bool { enabled && isAccessibilityElement() && activate(widget) }
}
#endif
