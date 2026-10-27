#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderUndoFocusTests: XCTestCase {
    func testFloatingFindResultsUndoAndRedoTheirParentPDFWithoutEditingAnotherWindow() async throws {
        let restoreApplication = activateTestApplication()
        defer { restoreApplication() }
        let parent = try await editedWindow(), other = try await editedWindow()
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 480, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("result")))
        let panel = findPanel(parent: parent.window, content: table)
        defer { close(panel); parent.close(); other.close() }
        other.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(table))
        try focus(panel)
        XCTAssertTrue(panel.parent === parent.window)
        let commands = ReaderUndoCommands()
        commands.update()
        XCTAssertFalse(commands.isEditingText)
        XCTAssertTrue(commands.enabled(redo: false, state: parent.state))
        commands.perform(redo: false)
        try await waitFor { parent.state.nativePDFInfo?.undoPosition == 0 }
        let removed = try await parent.pages.pdfAnnotations(0)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(other.state.nativePDFInfo?.undoPosition, 1)
        XCTAssertTrue(commands.enabled(redo: true, state: parent.state))
        commands.perform(redo: true)
        try await waitFor { parent.state.nativePDFInfo?.undoPosition == 1 }
        let restored = try await parent.pages.pdfAnnotations(0)
        let unrelated = try await other.pages.pdfAnnotations(0)
        XCTAssertEqual(restored.first?.contents, "Undo focus annotation")
        XCTAssertEqual(unrelated.first?.contents, "Undo focus annotation")
        XCTAssertEqual(other.state.nativePDFInfo?.undoPosition, 1)
        XCTAssertNil(parent.state.error)
        XCTAssertNil(other.state.error)
    }

    func testFloatingFindTextEditorKeepsNativeUndoAndRedoWithoutChangingPDFHistory() async throws {
        let restoreApplication = activateTestApplication()
        defer { restoreApplication() }
        let parent = try await editedWindow()
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 480, height: 200))
        editor.isRichText = false; editor.allowsUndo = true
        let panel = findPanel(parent: parent.window, content: editor)
        defer { close(panel); parent.close() }
        XCTAssertTrue(panel.makeFirstResponder(editor))
        try focus(panel)
        editor.insertText("Find query", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        let commands = ReaderUndoCommands()
        commands.update()
        XCTAssertTrue(commands.isEditingText)
        XCTAssertTrue(commands.enabled(redo: false, state: parent.state))
        commands.perform(redo: false)
        XCTAssertEqual(editor.string, "")
        commands.update()
        XCTAssertTrue(commands.enabled(redo: true, state: parent.state))
        commands.perform(redo: true)
        XCTAssertEqual(editor.string, "Find query")
        XCTAssertEqual(parent.state.nativePDFInfo?.undoPosition, 1)
        let annotations = try await parent.pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.first?.contents, "Undo focus annotation")
        XCTAssertNil(parent.state.error)
    }

    private func editedWindow() async throws -> PDFWindow {
        let fixture = try PDFWindow()
        fixture.state.setPDFEditingEnabled(true)
        try await waitFor { fixture.state.pdfEditingEnabled && !fixture.state.busy }
        _ = try await fixture.pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 30, height: 40),
            edits: [.contents("Undo focus annotation")])
        try await fixture.state.nativePDFDidChange(fixture.pages)
        return fixture
    }

    private func activateTestApplication() -> () -> Void {
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        let previous = NSWorkspace.shared.frontmostApplication
        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.activate(ignoringOtherApps: true)
        return {
            application.setActivationPolicy(policy)
            previous?.activate(options: [])
        }
    }

    private func focus(_ panel: NSPanel) throws {
        let deadline = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                if NSApp.keyWindow === panel || Date() >= deadline {
                    NSApp.stop(nil)
                    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(wake, atStart: true)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        NSApp.run()
        timer.invalidate()
        print("Undo focus established: active=\(NSApp.isActive), canBecomeKey=\(panel.canBecomeKey), keyIsPanel=\(NSApp.keyWindow === panel)")
        _ = try XCTUnwrap(NSApp.keyWindow === panel ? true : nil, "AppKit must establish the real child panel as key")
    }

    private func findPanel(parent: NSWindow, content: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: content.frame, styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true; panel.tabbingMode = .disallowed
        panel.alphaValue = 0; panel.ignoresMouseEvents = true
        panel.contentView = content
        parent.addChildWindow(panel, ordered: .above)
        return panel
    }

    private func close(_ panel: NSPanel) {
        panel.parent?.removeChildWindow(panel)
        panel.contentView = nil; panel.close()
    }

    private func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard condition() else { XCTFail("Undo focus did not settle", line: line); throw CancellationError() }
    }

    @MainActor private final class PDFWindow {
        let state: ReaderState
        let pages: Pages
        let window: NSWindow
        private let closeGuard: ReaderCloseGuard

        init() throws {
            _ = NSApplication.shared
            state = ReaderState(recordsHistory: false)
            state.document = try nativePDFReadingFixture()
            pages = try XCTUnwrap(state.nativePDF)
            window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 640, height: 480),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
            window.alphaValue = 0; window.ignoresMouseEvents = true
            state.window = window
            closeGuard = ReaderCloseGuard(state: state, previous: nil)
            window.delegate = closeGuard
        }

        func close() {
            window.delegate = nil; window.close(); state.windowClosed()
        }
    }
}
#endif
