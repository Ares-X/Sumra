#if os(macOS)
import AppKit
import Combine
import PDFKit
import XCTest
@testable import Sumra

@MainActor
final class NativePDFFormEditorTests: XCTestCase {
    private struct Rejected: Error {}

    func testMultilineDraftUndoRedoCommitsOnlyTheFinalText() async throws {
        _ = NSApplication.shared
        let host = FormHostView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let original = "First line\nSecond line", replacement = "Edited first\nEdited second"
        var values = [String]()
        let editor = NativePDFFormEditor(widget: widget(flags: 1 << 12, value: original), host: host, frame: fieldFrame,
            commitValue: { values.append($0) }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
        defer { editor.cancel() }
        let input = try XCTUnwrap((host.subviews.first as? NSScrollView)?.documentView as? NSTextView)
        let history = try XCTUnwrap(input.undoManager)
        history.groupsByEvent = false
        history.beginUndoGrouping()
        input.insertText(replacement, replacementRange: input.selectedRange())
        history.endUndoGrouping()
        XCTAssertEqual(input.string, replacement)
        XCTAssertTrue(history.canUndo)
        history.undo()
        XCTAssertEqual(input.string, original)
        XCTAssertTrue(history.canRedo)
        history.redo()
        XCTAssertEqual(input.string, replacement)
        XCTAssertTrue(values.isEmpty, "Draft undo must not submit a PDF field change")
        try await editor.commit()
        XCTAssertEqual(values, [replacement])
    }

    func testFormHighlightRecognizesOffWhitespaceAndUnsignedSignature() {
        for type in [2, 5] {
            XCTAssertTrue(widget(type: type, value: "Off").isEmptyFormField)
            XCTAssertFalse(widget(type: type, value: "Yes").isEmptyFormField)
        }
        for type in [3, 4, 7] {
            XCTAssertTrue(widget(type: type, value: " \t\n").isEmptyFormField)
            XCTAssertFalse(widget(type: type, value: "0").isEmptyFormField)
        }
        var signature = widget(type: 6, value: "")
        XCTAssertFalse(signature.isUnsignedSignature, "An unknown signature state must not offer replacement")
        signature.isSigned = false
        XCTAssertTrue(signature.isUnsignedSignature); XCTAssertTrue(signature.isEmptyFormField)
        signature.isSigned = true
        XCTAssertFalse(signature.isUnsignedSignature); XCTAssertFalse(signature.isEmptyFormField)
        XCTAssertFalse(widget(type: 1, value: "").isEmptyFormField, "Pushbuttons are not empty input fields")
        XCTAssertFalse(widget(value: "", readOnly: true).isEmptyFormField)
        for flags in [1, 2, 32] { XCTAssertFalse(widget(value: "", annotationFlags: flags).isEmptyFormField) }
    }

    func testTextCommitAndCancelUseTheCurrentInputOnce() async throws {
        _ = NSApplication.shared
        let host = FormHostView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        var values = [String](), closes = 0
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { values.append($0) }, didClose: { closes += 1 }, advance: { _ in }, failure: { XCTFail("\($0)") })
        defer { editor.cancel() }
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === input)
        XCTAssertTrue(field.isEnabled, "Opening the field must not submit its original value")
        XCTAssertEqual(input.selectedRange(), NSRange(location: 0, length: "initial".utf16.count))
        input.insertText("edited", replacementRange: input.selectedRange())
        try await editor.commit()
        try await editor.commit()
        editor.cancel()
        XCTAssertEqual(values, ["edited"])
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(host.subviews.isEmpty)
        XCTAssertTrue(window.firstResponder === host, "Committed input must return document commands to its host")

        let cancelled = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { values.append($0) }, didClose: { closes += 1 }, advance: { _ in }, failure: { XCTFail("\($0)") })
        (host.subviews.first as? NSTextField)?.stringValue = "discarded"
        cancelled.cancel()
        try await cancelled.commit()
        XCTAssertEqual(values, ["edited"])
        XCTAssertEqual(closes, 2)
        XCTAssertTrue(window.firstResponder === host, "Cancelling input must return document commands to its host")
    }

    func testAsyncBlurCommitPreservesFocusOnAnotherControl() async throws {
        _ = NSApplication.shared
        let host = FormHostView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let started = expectation(description: "Blur submitted the input")
        let closed = expectation(description: "The pending submission closed the editor")
        var release: CheckedContinuation<Void, Never>?
        var values = [String]()
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { value in
                values.append(value)
                await withCheckedContinuation { release = $0; started.fulfill() }
            }, didClose: { closed.fulfill() }, advance: { _ in XCTFail("Blur must not advance fields") },
            failure: { XCTFail("\($0)") })
        defer { release?.resume(); editor.cancel() }
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        input.insertText("edited", replacementRange: input.selectedRange())
        let other = NSTextField(frame: CGRect(x: 20, y: 150, width: 200, height: 28))
        host.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(other))
        await fulfillment(of: [started], timeout: 2)
        let otherInput = try XCTUnwrap(other.currentEditor())
        XCTAssertTrue(window.firstResponder === otherInput)
        release?.resume(); release = nil
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(values, ["edited"], "Real focus loss must submit the value only once")
        XCTAssertNil(field.superview)
        XCTAssertTrue(other.currentEditor() === otherInput)
        XCTAssertTrue(window.firstResponder === otherInput, "Async close must preserve the user's new input focus")
    }

    func testUnchangedTextBlurClosesWithoutSubmitting() async throws {
        _ = NSApplication.shared
        let host = FormHostView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let closed = expectation(description: "Unchanged input closed on blur")
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { _ in XCTFail("Unchanged input must not create a PDF edit") },
            didClose: { closed.fulfill() }, advance: { _ in XCTFail("Blur must not advance fields") }, failure: { XCTFail("\($0)") })
        defer { editor.cancel() }
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        let other = NSTextField(frame: CGRect(x: 20, y: 150, width: 200, height: 28))
        host.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(other))
        let otherInput = try XCTUnwrap(other.currentEditor())
        await fulfillment(of: [closed], timeout: 2)
        try await editor.commit()
        XCTAssertNil(field.superview)
        XCTAssertTrue(window.firstResponder === otherInput)
    }

    func testUnchangedTextAndChoiceTabCloseBeforeAdvancingWithoutSubmitting() async throws {
        let options: [PDFAnnotationSnapshot.Choice] = [.init(label: "First choice", value: "one"), .init(label: "Second choice", value: "two")]
        for (type, flags) in [(7, 0), (3, 0), (4, 0), (3, (1 << 17) | (1 << 18))] {
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
            let advanced = expectation(description: "Unchanged input advanced to the next field")
            var events = [String]()
            let editor = NativePDFFormEditor(widget: widget(type: type, flags: flags, value: "one", options: options), host: host, frame: fieldFrame,
                commitValue: { _ in XCTFail("Unchanged input must not create a PDF edit") },
                didClose: { events.append("closed") }, advance: { backwards in
                    events.append(backwards ? "previous" : "next"); advanced.fulfill()
                }, failure: { XCTFail("\($0)") })
            let control = try XCTUnwrap((host.subviews.first as? NSControl) ?? ((host.subviews.first as? NSScrollView)?.documentView as? NSControl))
            XCTAssertTrue(editor.control(control, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
            await fulfillment(of: [advanced], timeout: 2)
            try await editor.commit()
            XCTAssertEqual(events, ["closed", "next"])
            XCTAssertTrue(host.subviews.isEmpty)
        }
    }

    func testValidationFailureRetainsInputAndDoesNotRetryOnErrorAlertBlur() async throws {
        _ = NSApplication.shared
        let host = FormHostView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        var attempts = [String](), closes = 0
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { value in attempts.append(value); if value == "invalid" { throw Rejected() } },
            didClose: { closes += 1 }, advance: { _ in }, failure: { _ in XCTFail("Explicit commit propagates its error") })
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "invalid"
        do { try await editor.commit(); XCTFail("Validation must reject the input") }
        catch { XCTAssertTrue(error is Rejected) }
        XCTAssertEqual(field.stringValue, "invalid")
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(field.superview === host)
        let restoredInput = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(window.firstResponder === restoredInput, "Rejected input must remain editable and focused")
        XCTAssertEqual(closes, 0)
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        await Task.yield()
        XCTAssertEqual(attempts, ["invalid"])
        field.stringValue = "valid"
        try await editor.commit()
        XCTAssertEqual(attempts, ["invalid", "valid"])
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(window.firstResponder === host)
    }

    func testChoiceDisplaysLabelsButCommitsExportValueAndBlurCancels() async throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        var values = [String]()
        let options: [PDFAnnotationSnapshot.Choice] = [.init(label: "First choice", value: "one"), .init(label: "Second choice", value: "two")]
        let editor = NativePDFFormEditor(widget: widget(type: 4, value: "one", options: options), host: host, frame: fieldFrame,
            commitValue: { values.append($0) }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
        let scroll = try XCTUnwrap(host.subviews.first as? NSScrollView)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertEqual(table.selectedRow, 0)
        let label = editor.tableView(table, viewFor: table.tableColumns.first, row: 1) as? NSTextField
        XCTAssertEqual(label?.stringValue, "Second choice")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        editor.updateFrame(fieldFrame.applying(CGAffineTransform(scaleX: 1.5, y: 1.5)))
        XCTAssertEqual(table.selectedRow, 1, "Resizing an open choice field must preserve the pending choice")
        let resizedLabel = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField)
        XCTAssertEqual(resizedLabel.font?.pointSize, table.rowHeight - 6)
        try await editor.commit()
        XCTAssertEqual(values, ["two"])

        let cancelled = NativePDFFormEditor(widget: widget(type: 3, value: "one", options: options), host: host, frame: fieldFrame,
            commitValue: { values.append($0) }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
        let otherTable = try XCTUnwrap((host.subviews.first as? NSScrollView)?.documentView as? NSTableView)
        XCTAssertTrue(otherTable.resignFirstResponder())
        try await cancelled.commit()
        XCTAssertEqual(values, ["two"])
        XCTAssertTrue(host.subviews.isEmpty)
    }

    func testEditableComboPreservesTypedValuesAndChosenExports() async throws {
        _ = NSApplication.shared
        let host = FormHostView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let options: [PDFAnnotationSnapshot.Choice] = [.init(label: "First choice", value: "one"), .init(label: "Second choice", value: "two")]
        for (original, typed) in [("one", nil), ("First choice", nil), ("one", "Other typed"), ("one", "Second choice")] as [(String, String?)] {
            var values = [String]()
            let editor = NativePDFFormEditor(widget: widget(type: 3, flags: (1 << 17) | (1 << 18), value: original, options: options), host: host, frame: fieldFrame,
                commitValue: { values.append($0) }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
            defer { editor.cancel() }
            let combo = try XCTUnwrap(host.subviews.first as? NSComboBox)
            XCTAssertEqual(combo.stringValue, original == "one" ? "First choice" : original)
            if let typed {
                let input = try XCTUnwrap(combo.currentEditor() as? NSTextView)
                input.insertText(typed, replacementRange: input.selectedRange())
            }
            try await editor.commit()
            XCTAssertEqual(values, typed.map { [$0] } ?? [], "Typed text must remain literal even when it equals an option label; unchanged values must not create edits")
        }
        var values = [String]()
        let selected = NativePDFFormEditor(widget: widget(type: 3, flags: (1 << 17) | (1 << 18), value: "one", options: options), host: host, frame: fieldFrame,
            commitValue: { values.append($0) }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
        defer { selected.cancel() }
        let combo = try XCTUnwrap(host.subviews.first as? NSComboBox)
        combo.selectItem(at: 1)
        XCTAssertEqual(combo.stringValue, "Second choice")
        selected.updateFrame(fieldFrame.applying(CGAffineTransform(scaleX: 1.5, y: 1.5)))
        try await selected.commit()
        XCTAssertEqual(values, ["two"], "Choosing a displayed option commits its export value")
    }

    func testEditableComboValidationKeepsTheDraftAndAllowsCorrection() async throws {
        _ = NSApplication.shared
        let host = FormHostView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        var attempts = [String](), closes = 0
        let editor = NativePDFFormEditor(widget: widget(type: 3, flags: (1 << 17) | (1 << 18), value: "custom"), host: host, frame: fieldFrame,
            commitValue: { value in attempts.append(value); if value == "invalid" { throw Rejected() } },
            didClose: { closes += 1 }, advance: { _ in }, failure: { XCTFail("\($0)") })
        defer { editor.cancel() }
        let combo = try XCTUnwrap(host.subviews.first as? NSComboBox)
        let input = try XCTUnwrap(combo.currentEditor() as? NSTextView)
        input.insertText("invalid", replacementRange: input.selectedRange())
        do { try await editor.commit(); XCTFail("Validation must reject the custom input") }
        catch { XCTAssertTrue(error is Rejected) }
        XCTAssertEqual(combo.stringValue, "invalid")
        XCTAssertTrue(combo.isEnabled); XCTAssertTrue(combo.superview === host)
        XCTAssertTrue(window.firstResponder === combo.currentEditor())
        XCTAssertEqual(closes, 0)
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: combo))
        await Task.yield()
        XCTAssertEqual(attempts, ["invalid"], "An alert-related blur must not retry rejected input")
        let corrected = try XCTUnwrap(combo.currentEditor() as? NSTextView)
        corrected.insertText("corrected", replacementRange: NSRange(location: 0, length: corrected.string.utf16.count))
        try await editor.commit()
        XCTAssertEqual(attempts, ["invalid", "corrected"])
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(window.firstResponder === host)
    }

    func testPasswordAndMultilineControlsKeepTheirNativeBehavior() async throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let secure = NativePDFFormEditor(widget: widget(flags: 1 << 13), host: host, frame: fieldFrame,
            commitValue: { _ in }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
        XCTAssertTrue(host.subviews.first is NSSecureTextField)
        secure.cancel()

        var value: String?
        let multiline = NativePDFFormEditor(widget: widget(flags: 1 << 12), host: host, frame: fieldFrame,
            commitValue: { value = $0 }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
        let view = try XCTUnwrap((host.subviews.first as? NSScrollView)?.documentView as? NSTextView)
        XCTAssertFalse(multiline.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        view.string = "first\nsecond"
        try await multiline.commit()
        XCTAssertEqual(value, "first\nsecond")
    }

    func testTabCommitsBeforeAdvancingAndEscapeCancels() async throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let advanced = expectation(description: "Advanced after a successful commit")
        var events = [String]()
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { events.append($0) }, didClose: { events.append("closed") },
            advance: { backwards in events.append(backwards ? "previous" : "next"); advanced.fulfill() }, failure: { XCTFail("\($0)") })
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "submitted"
        XCTAssertTrue(editor.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        await fulfillment(of: [advanced], timeout: 2)
        XCTAssertEqual(events, ["submitted", "closed", "previous"])

        let cancelled = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { _ in XCTFail("Escape must not commit") }, didClose: {}, advance: { _ in XCTFail("Escape must not advance") }, failure: { XCTFail("\($0)") })
        let other = try XCTUnwrap(host.subviews.first as? NSTextField)
        XCTAssertTrue(cancelled.control(other, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(host.subviews.isEmpty)
    }

    func testConcurrentCommitCallsShareOneSubmission() async throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let started = expectation(description: "Commit started")
        var release: CheckedContinuation<Void, Never>?
        var submissions = 0, closes = 0
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { _ in
                submissions += 1
                await withCheckedContinuation { release = $0; started.fulfill() }
            }, didClose: { closes += 1 }, advance: { _ in }, failure: { XCTFail("\($0)") })
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "submitted"
        let first = Task { try await editor.commit() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await editor.commit() }
        await Task.yield()
        release?.resume()
        try await first.value; try await second.value
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(closes, 1)
    }

    func testPDFAlignmentAppliesToTextPasswordAndMultilineInput() throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let alignments: [NSTextAlignment] = [.left, .center, .right]
        for flags in [0, 1 << 13, 1 << 12] {
            for (q, expected) in alignments.enumerated() {
                let editor = NativePDFFormEditor(widget: widget(flags: flags, alignment: q), host: host, frame: fieldFrame,
                    commitValue: { _ in }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
                editor.updateFrame(fieldFrame.applying(CGAffineTransform(scaleX: 1.5, y: 1.5)))
                if let field = host.subviews.first as? NSTextField {
                    XCTAssertEqual(field.alignment, expected)
                } else {
                    let view = try XCTUnwrap((host.subviews.first as? NSScrollView)?.documentView as? NSTextView)
                    XCTAssertEqual(view.alignment, expected)
                }
                editor.cancel()
            }
        }
    }

    func testSingleLineAndPasswordInputLimitsInsertionAndReplacement() throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        for flags in [0, 1 << 13] {
            let editor = NativePDFFormEditor(widget: widget(flags: flags, value: "ab", maxLength: 3), host: host, frame: fieldFrame,
                commitValue: { _ in }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
            let field = try XCTUnwrap(host.subviews.first as? NSTextField)
            let formatter = try XCTUnwrap(field.formatter)
            func accepts(_ replacement: String, original: String, selected: NSRange) -> Bool {
                var proposed = (original as NSString).replacingCharacters(in: selected, with: replacement) as NSString
                var selection = NSRange(location: selected.location + replacement.utf16.count, length: 0)
                return formatter.isPartialStringValid(&proposed, proposedSelectedRange: &selection,
                    originalString: original, originalSelectedRange: selected, errorDescription: nil)
            }
            XCTAssertTrue(accepts("c", original: "ab", selected: NSRange(location: 2, length: 0)))
            XCTAssertFalse(accepts("pasted text", original: "ab", selected: NSRange(location: 1, length: 1)))
            XCTAssertTrue(accepts("😀", original: "abc", selected: NSRange(location: 1, length: 2)))
            XCTAssertFalse(accepts("😀", original: "ab", selected: NSRange(location: 2, length: 0)))
            XCTAssertTrue(accepts("", original: "long source", selected: NSRange(location: 0, length: 1)))
            XCTAssertEqual(field.stringValue, "ab", "Input validation must not rewrite the loaded value")
            editor.cancel()
        }
    }

    func testMultilineInputLimitPreservesMarkedTextAndRejectsOversizedPaste() throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let editor = NativePDFFormEditor(widget: widget(flags: 1 << 12, value: "", maxLength: 2), host: host, frame: fieldFrame,
            commitValue: { _ in }, didClose: {}, advance: { _ in }, failure: { XCTFail("\($0)") })
        let view = try XCTUnwrap((host.subviews.first as? NSScrollView)?.documentView as? NSTextView)
        view.insertText("pasted text", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "")
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.string, "nihao", "The MaxLen limit must not truncate an IME's in-progress composition")
        XCTAssertFalse(editor.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "你好")
        XCTAssertFalse(view.hasMarkedText())

        view.setMarkedText("nihaoma", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: 0, length: 2))
        XCTAssertEqual(view.string, "nihaoma")
        view.unmarkText() // An IME can end composition without insertText, e.g. on blur.
        XCTAssertEqual(view.string, "你好")
        XCTAssertFalse(view.hasMarkedText())
        view.setMarkedText("nihaoma", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: 0, length: 2))
        view.insertText("你好吗", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "你好", "An oversized IME commit must preserve the previous accepted value too")
        XCTAssertFalse(view.hasMarkedText())
        editor.cancel()
    }

    func testLayoutChangeWaitsForAcceptedInputAndIgnoresReplacedDocument() async throws {
        struct Rejected: Error {}
        let defaults = UserDefaults.standard, previousFlow = UserDefaults.standard.object(forKey: "flow")
        defer {
            if let previousFlow { defaults.set(previousFlow, forKey: "flow") }
            else { defaults.removeObject(forKey: "flow") }
        }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/form-original.pdf"), content: .text(""))
        state.flow = "paged"
        defer { state.windowClosed() }
        var values = [String]()
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { value in
                values.append(value)
                if value == "invalid" { throw Rejected() }
            }, didClose: { state.nativePDFFormEditor = nil }, advance: { _ in }, failure: { XCTFail("\($0)") })
        state.nativePDFFormEditor = editor
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "invalid"
        let rejected = expectation(description: "Layout change reports rejected form input")
        let errorSubscription = state.$error.compactMap { $0 }.prefix(1).sink { _ in rejected.fulfill() }
        state.setFlow("continuous")
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(state.flow, "paged")
        XCTAssertEqual(field.stringValue, "invalid")
        XCTAssertTrue(field.superview === host)

        field.stringValue = "valid"
        let changed = expectation(description: "Accepted input permits the requested layout")
        let flowSubscription = state.$flow.filter { $0 == "continuous" }.prefix(1).sink { _ in changed.fulfill() }
        state.setFlow("continuous")
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(state.flow, "continuous")
        XCTAssertEqual(values, ["invalid", "valid"])
        XCTAssertTrue(host.subviews.isEmpty)
        withExtendedLifetime((errorSubscription, flowSubscription)) {}

        state.flow = "paged"
        let started = expectation(description: "A second input submission is pending")
        var release: CheckedContinuation<Void, Never>?
        let pending = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { _ in await withCheckedContinuation { release = $0; started.fulfill() } },
            didClose: { state.nativePDFFormEditor = nil }, advance: { _ in }, failure: { XCTFail("\($0)") })
        state.nativePDFFormEditor = pending
        let pendingField = try XCTUnwrap(host.subviews.first as? NSTextField)
        pendingField.stringValue = "pending layout input"
        state.setFlow("continuous")
        await fulfillment(of: [started], timeout: 2)
        let replacement = ReadingDocument(url: URL(fileURLWithPath: "/form-replacement.pdf"), content: .text(""))
        let replace = Task {
            state.document = replacement
            release?.resume()
        }
        // Await the same pending operation before allowing the test to finish.
        // Replacing the document cancels the control, not the already submitted edit.
        try await pending.commit()
        await replace.value
        await Task.yield()
        XCTAssertEqual(state.document?.id, replacement.id)
        XCTAssertEqual(state.flow, "paged")
        XCTAssertTrue(host.subviews.isEmpty)
    }

    @MainActor
    func testCloseWaitsForValidationAndKeepsRejectedInput() async throws {
        _ = NSApplication.shared
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let state = ReaderState(recordsHistory: false)
        let reading = ReadingDocument(url: URL(fileURLWithPath: "/form-close.pdf"), content: .text(""))
        state.document = reading
        defer { state.windowClosed() }
        var values = [String]()
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { value in
                values.append(value)
                if value == "invalid" { throw Rejected() }
            }, didClose: { state.nativePDFFormEditor = nil }, advance: { _ in }, failure: { XCTFail("\($0)") })
        state.nativePDFFormEditor = editor
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "invalid"
        let rejected = await state.confirmClose()
        XCTAssertFalse(rejected)
        XCTAssertEqual(state.document?.id, reading.id)
        XCTAssertTrue(field.superview === host)
        XCTAssertEqual(field.stringValue, "invalid")
        XCTAssertNotNil(state.error)
        field.stringValue = "valid"
        let accepted = await state.confirmClose()
        XCTAssertTrue(accepted)
        XCTAssertEqual(values, ["invalid", "valid"])
        XCTAssertTrue(host.subviews.isEmpty)
    }

    @MainActor
    func testPendingCloseCannotApproveAReplacementDocument() async throws {
        _ = NSApplication.shared
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/form-original.pdf"), content: .text(""))
        defer { state.windowClosed() }
        let started = expectation(description: "Close waits for the field submission")
        var release: CheckedContinuation<Void, Never>?
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { _ in await withCheckedContinuation { release = $0; started.fulfill() } },
            didClose: { state.nativePDFFormEditor = nil }, advance: { _ in }, failure: { XCTFail("\($0)") })
        state.nativePDFFormEditor = editor
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "pending close input"
        let closing = Task { await state.confirmClose() }
        await fulfillment(of: [started], timeout: 2)
        let duplicate = await state.confirmClose()
        XCTAssertFalse(duplicate, "A second close request must not create another approval")
        let replacement = ReadingDocument(url: URL(fileURLWithPath: "/form-replacement.pdf"), content: .text(""))
        state.document = replacement
        release?.resume()
        let approved = await closing.value
        XCTAssertFalse(approved)
        XCTAssertEqual(state.document?.id, replacement.id)
        XCTAssertTrue(host.subviews.isEmpty)
    }

    @MainActor
    func testSavePreservesTheChosenPDFEditingState() async throws {
        _ = NSApplication.shared
        for editingEnabled in [true, false] {
            let temporary = try TemporaryDirectory()
            let url = temporary.url.appendingPathComponent("save-editing.pdf")
            let pdf = PDFDocument(), page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            pdf.insert(page, at: 0)
            try XCTUnwrap(pdf.dataRepresentation()).write(to: url)
            let state = ReaderState(recordsHistory: false)
            let pages = try Pages(url, format: .pdf)
            let reading = ReadingDocument(url: url, content: .pages(pages))
            state.document = reading
            defer { state.windowClosed(); withExtendedLifetime(temporary) {} }

            let unlocked = expectation(description: "Explicitly unlocked PDF editing")
            let unlock = state.$pdfEditingEnabled.filter { $0 }.prefix(1).sink { _ in unlocked.fulfill() }
            state.setPDFEditingEnabled(true)
            await fulfillment(of: [unlocked], timeout: 2)
            _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 30, height: 40), edits: [.contents("saved annotation")])
            try await state.nativePDFDidChange(pages)

            var lock: AnyCancellable?
            if !editingEnabled {
                let locked = expectation(description: "User locked PDF editing before saving")
                lock = state.$pdfEditingEnabled.filter { !$0 }.prefix(1).sink { _ in locked.fulfill() }
                state.setPDFEditingEnabled(false)
                await fulfillment(of: [locked], timeout: 2)
            }

            let loaded = expectation(description: "Save reloaded the PDF with its chosen editing state")
            let reload = Publishers.CombineLatest3(state.$document, state.$busy, state.$pdfEditingEnabled)
                .filter { document, busy, enabled in document?.id != reading.id && !busy && enabled == editingEnabled }
                .prefix(1).sink { _ in loaded.fulfill() }
            state.savePDF()
            await fulfillment(of: [loaded], timeout: 5)
            XCTAssertNil(state.error)
            XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.first?.contents, "saved annotation")
            XCTAssertEqual(state.canEditPDF, editingEnabled)

            let reloaded = try XCTUnwrap(state.nativePDF)
            let annotations = try await reloaded.pdfAnnotations(0)
            let annotation = try XCTUnwrap(annotations.first)
            if editingEnabled {
                try await reloaded.pdfEditAnnotation(page: 0, id: annotation.id, edits: [.contents("continued editing")])
                try await state.nativePDFDidChange(reloaded)
                let edited = try await reloaded.pdfAnnotations(0)
                XCTAssertEqual(edited.first?.contents, "continued editing")
                XCTAssertTrue(state.modified)
            } else {
                do {
                    try await reloaded.pdfEditAnnotation(page: 0, id: annotation.id, edits: [.contents("must stay locked")])
                    XCTFail("Saving a locked PDF must not permit native edits")
                } catch {}
            }
            withExtendedLifetime((unlock, lock, reload)) {}
        }
    }

    @MainActor
    func testCloseTakesOverAnInFlightSaveWithoutACompetingReload() async throws {
        _ = NSApplication.shared
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appendingPathComponent("save-close.pdf")
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        pdf.insert(page, at: 0)
        try XCTUnwrap(pdf.dataRepresentation()).write(to: url)
        let state = ReaderState(recordsHistory: false)
        let pages = try Pages(url, format: .pdf)
        let reading = ReadingDocument(url: url, content: .pages(pages))
        state.document = reading
        defer { state.windowClosed(); withExtendedLifetime(temporary) {} }
        let generation = state.generation
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 30, height: 40), edits: [.contents("pending save")])
        try await state.nativePDFDidChange(pages)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let entered = expectation(description: "Save is waiting for the native field")
        var release: CheckedContinuation<Void, Never>?
        let editor = NativePDFFormEditor(widget: widget(), host: host, frame: fieldFrame,
            commitValue: { _ in await withCheckedContinuation { release = $0; entered.fulfill() } },
            didClose: { state.nativePDFFormEditor = nil }, advance: { _ in }, failure: { XCTFail("\($0)") })
        state.nativePDFFormEditor = editor
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "pending save input"
        let reloaded = expectation(description: "Save must not replace a document already approved for close")
        reloaded.isInverted = true
        let document = state.$document.compactMap { $0 }.filter { $0.id != reading.id }.sink { _ in reloaded.fulfill() }
        state.savePDF()
        await fulfillment(of: [entered], timeout: 2)
        let waiting = expectation(description: "Close has joined the pending save")
        let closing = Task {
            await withCheckedContinuation { continuation in
                state.confirmClose { continuation.resume(returning: $0) }
                waiting.fulfill()
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        release?.resume()
        let allowed = await closing.value
        XCTAssertTrue(allowed)
        await fulfillment(of: [reloaded], timeout: 0.1)
        XCTAssertEqual(state.generation, generation)
        XCTAssertFalse(state.modified)
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.first?.contents, "pending save")
        withExtendedLifetime(document) {}
    }

    private var fieldFrame: CGRect { CGRect(x: 20, y: 40, width: 160, height: 28) }
    private func widget(type: Int = 7, flags: Int = 0, value: String = "initial", options: [PDFAnnotationSnapshot.Choice] = [],
                        alignment: Int = 0, maxLength: Int = 0, readOnly: Bool = false, annotationFlags: Int = 0) -> PDFAnnotationSnapshot {
        .init(id: 7, type: "Widget", contents: "", author: "", icon: "", flags: annotationFlags,
              rect: [20, 40, 160, 28], color: [], interiorColor: [], opacity: 1, borderWidth: 1,
              borderStyle: 0, alignment: Int32(alignment), dash: [], font: "Helv", fontSize: 12, textColor: [0, 0, 0],
              line: [], vertices: [], lineEnds: [], quads: [], ink: [],
              fieldName: "field", fieldLabel: "Field", value: value, fieldType: type,
              fieldFlags: flags, maxLength: maxLength, readOnly: readOnly, options: options)
    }
}

@MainActor
private final class FormHostView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
#endif
