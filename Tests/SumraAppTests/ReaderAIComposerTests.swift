#if os(macOS)
import AppKit
import ApplicationServices
import Darwin
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderAIComposerTests: XCTestCase {
    func testClosingAndReopeningKeepsDraftOnlyForCurrentDocumentAndWindow() async throws {
        let fixture = try ComposerFixture()
        defer { fixture.close() }
        try await fixture.mount()
        fixture.state.aiProvider = .claude
        try await fixture.wait { fixture.displaysProvider(.claude) }
        try fixture.enter("Unsent draft 中文")
        try await fixture.press("Close Sidebar")
        try await fixture.wait { !fixture.state.showAI && fixture.editor == nil }
        ReaderMenuCommand.ai.run(fixture.state)
        try await fixture.mount()
        XCTAssertEqual(fixture.editor?.string, "Unsent draft 中文")
        XCTAssertTrue(fixture.displaysProvider(.claude), "Reopening a draft must retain the CLI that will receive it")

        let other = ReaderState(recordsHistory: false)
        XCTAssertEqual(other.aiProvider, .codex)
        other.document = fixture.state.document
        let otherHost = NSHostingView(rootView: ReaderAISidebar(state: other))
        let otherWindow = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 380, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false; otherWindow.contentView = otherHost
        defer { other.windowClosed(); otherWindow.contentView = nil; otherWindow.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        var otherEditor: NSTextView?
        try await fixture.wait {
            otherHost.layoutSubtreeIfNeeded()
            otherEditor = views(otherHost).compactMap { $0 as? NSTextView }.first { $0.isEditable }
            return otherEditor != nil
        }
        XCTAssertEqual(otherEditor?.string, "", "A new reader window must not inherit another window's draft")
        try XCTUnwrap(otherEditor).insertText("Other window", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(fixture.editor?.string, "Unsent draft 中文")

        fixture.state.document = ReadingDocument(url: fixture.temporary.url.appendingPathComponent("Other.txt"), content: .text("Other document"))
        try await fixture.wait { fixture.editor?.string == "" }
        XCTAssertEqual(other.aiQuestion, "Other window")
        try fixture.enter("Second document draft")
        try await fixture.press("Close Sidebar")
        try await fixture.wait { !fixture.state.showAI && fixture.editor == nil }
        fixture.state.document = ReadingDocument(url: fixture.temporary.url.appendingPathComponent("Third.txt"), content: .text("Third document"))
        ReaderMenuCommand.ai.run(fixture.state)
        try await fixture.mount()
        XCTAssertEqual(fixture.editor?.string, "", "Replacing a document while the sidebar is hidden must clear its draft")
        XCTAssertFalse(fixture.window.isKeyWindow)
        XCTAssertFalse(otherWindow.isVisible)
    }

    /// The CLI is a local fixture. No provider, account or network is used by this test.
    func testMountedComposerClearsAcceptedQuestionAndPreservesNextDraft() async throws {
        let fixture = try ComposerFixture()
        defer { fixture.close() }
        let question = "Which fictional harbor contains the amber telescope?"
        let draft = String(repeating: "A separate next question 中文. ", count: 24)
        try await fixture.mount()
        try fixture.enter(question)
        try await fixture.press("Send")
        try await fixture.wait { fixture.started && fixture.editor?.string == "" }
        XCTAssertFalse(fixture.finished, "The accepted question clears before the blocked CLI returns")
        XCTAssertTrue(fixture.texts.contains(question), "The submitted question remains in the transcript")
        XCTAssertTrue(fixture.hasProgress, "A blocked CLI must visibly report progress")
        try fixture.enter(draft)
        XCTAssertEqual(fixture.editor?.string, draft)
        try fixture.release()
        try await fixture.wait { fixture.texts.contains("Fixture answer: Lumen Harbor.") && fixture.hasButton("Send") }
        XCTAssertEqual(fixture.editor?.string, draft, "Completion must preserve a new draft typed during the request")
        XCTAssertFalse(fixture.texts.contains("…"), "Completed replies must not leave an empty assistant placeholder")
        XCTAssertFalse(fixture.hasProgress)
        XCTAssertEqual(fixture.editor?.enclosingScrollView?.frame.height ?? 0, 85, accuracy: 3,
            "A long draft scrolls inside the composer instead of enlarging the sidebar")
        XCTAssertFalse(fixture.window.isKeyWindow, "The isolated fixture never takes the user's focus")
    }

    func testMountedCancelAndFailedReplyDoNotLeavePermanentPlaceholder() async throws {
        let fixture = try ComposerFixture()
        defer { fixture.close() }
        try await fixture.mount()
        try fixture.enter("Cancel this synthetic question.")
        try await fixture.press("Send")
        try await fixture.wait { fixture.started && fixture.hasButton("Cancel") }
        try fixture.enter("Keep this next draft")
        try await fixture.press("Cancel")
        try await fixture.wait { fixture.hasButton("Send") && !fixture.hasProgress && !fixture.running }
        XCTAssertEqual(fixture.editor?.string, "Keep this next draft")
        XCTAssertFalse(fixture.texts.contains("…"), "Cancelling before the first token removes the empty assistant")

        try fixture.reset(mode: "fail")
        try fixture.enter("Fail this synthetic question.")
        try await fixture.press("Send")
        try await fixture.wait { fixture.started }
        try fixture.release()
        try await fixture.wait { fixture.hasButton("Send") && fixture.texts.contains(where: { $0.contains("Synthetic provider failure") }) }
        XCTAssertFalse(fixture.texts.contains("…"), "A failed CLI must not leave an empty assistant")
        XCTAssertFalse(fixture.hasProgress)
    }
}

@MainActor
private final class ComposerFixture {
    let temporary: TemporaryDirectory
    let state: ReaderState
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private let previousPath: String?
    private let defaults: UserDefaults
    private let defaultsName: String
    private var closed = false

    init() throws {
        temporary = try TemporaryDirectory()
        defaultsName = "Sumra.AIComposerTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set("en", forKey: "language")
        previousPath = getenv("PATH").map { String(cString: $0) }
        let tool = temporary.url.appendingPathComponent("codex")
        // The process receives only synthetic input. Its own PID is recorded for
        // ownership-safe cancellation/cleanup; no shared provider process is touched.
        let script = """
        #!/bin/sh
        case " $* " in *" mcp list "*) printf '[]'; exit 0;; esac
        printf '%s' "$$" > fixture.pid
        /bin/cat > request.json
        : > started
        trap 'exit 0' TERM INT
        while [ ! -e release ]; do /bin/sleep 0.02; done
        if [ "$(/bin/cat mode)" = fail ]; then
          printf '%s\\n' 'Synthetic provider failure' >&2
          exit 42
        fi
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Fixture answer: Lumen Harbor."}}' '{"type":"turn.completed"}'
        : > finished
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        try "success".write(to: temporary.url.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        setenv("PATH", temporary.url.path + ":/usr/bin:/bin", 1)
        _ = NSApplication.shared
        NSApp.finishLaunching()
        state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: temporary.url.appendingPathComponent("Synthetic.txt"),
            content: .text("The amber telescope is kept in Lumen Harbor. This is a fictional document for an isolated UI test."))
        state.showAI = true
        host = NSHostingView(rootView: AnyView(ComposerHost(state: state).defaultAppStorage(defaults)))
        window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 380, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = defaultsName
        window.contentView = host
        window.orderBack(nil)
    }

    var started: Bool { exists("started") }
    var finished: Bool { exists("finished") }
    var running: Bool {
        guard let value = try? String(contentsOf: temporary.url.appendingPathComponent("fixture.pid")),
              let pid = Int32(value) else { return false }
        return kill(pid, 0) == 0
    }
    var editor: NSTextView? { views(host).compactMap { $0 as? NSTextView }.first { $0.isEditable } }
    var elements: [AXUIElement] {
        let app = AXUIElementCreateApplication(getpid())
        guard let target = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
            attribute($0, kAXTitleAttribute) as? String == window.title
        }) else { return [] }
        func flatten(_ value: AXUIElement) -> [AXUIElement] {
            [value] + (attribute(value, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(flatten)
        }
        return flatten(target)
    }
    var texts: [String] {
        elements.filter { attribute($0, kAXRoleAttribute) as? String == kAXStaticTextRole }
            .compactMap { attribute($0, kAXValueAttribute) as? String ?? attribute($0, kAXDescriptionAttribute) as? String }
    }
    func displaysProvider(_ provider: ReaderAIProvider) -> Bool {
        elements.contains { element in
            attribute(element, kAXRoleAttribute) as? String == kAXPopUpButtonRole &&
            attribute(element, kAXValueAttribute) as? String == provider.rawValue
        }
    }
    var hasProgress: Bool {
        texts.contains(String(format: L("Waiting for %@…"), "Codex"))
    }
    func hasButton(_ label: String) -> Bool { button(label) != nil }
    func button(_ label: String) -> AXUIElement? {
        elements.first { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
            (attribute($0, kAXTitleAttribute) as? String == label || attribute($0, kAXDescriptionAttribute) as? String == label ||
             attribute($0, kAXHelpAttribute) as? String == label) }
    }
    func press(_ label: String) async throws {
        try await wait {
            guard let control = self.button(label) else { return false }
            return (self.attribute(control, kAXEnabledAttribute) as? NSNumber)?.boolValue == true
        }
        let control = try XCTUnwrap(button(label), "Missing mounted \(label) control; text=\(texts)")
        XCTAssertEqual(AXUIElementPerformAction(control, kAXPressAction as CFString), .success)
    }
    func enter(_ text: String) throws {
        let editor = try XCTUnwrap(editor)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }
    func mount() async throws { try await wait { self.editor != nil && self.hasButton("Send") } }
    func release() throws { try Data().write(to: temporary.url.appendingPathComponent("release")) }
    func reset(mode: String) throws {
        for marker in ["started", "finished", "release"] where exists(marker) {
            try FileManager.default.removeItem(at: temporary.url.appendingPathComponent(marker))
        }
        try mode.write(to: temporary.url.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTFail("Mounted composer did not settle; text=\(texts), editor=\(editor?.string ?? "<missing>")")
        throw NSError(domain: "ReaderAIComposerTests", code: 1)
    }
    func close() {
        guard !closed else { return }; closed = true
        try? release()
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        state.windowClosed()
        window.orderOut(nil); window.contentView = nil; window.close()
        if let previousPath { setenv("PATH", previousPath, 1) } else { unsetenv("PATH") }
        defaults.removePersistentDomain(forName: defaultsName)
    }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: temporary.url.appendingPathComponent(name).path) }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func attribute(_ value: AXUIElement, _ key: String) -> CFTypeRef? {
        var output: CFTypeRef?
        AXUIElementCopyAttributeValue(value, key as CFString, &output)
        return output
    }
}

private struct ComposerHost: View {
    @ObservedObject var state: ReaderState
    var body: some View { if state.showAI { ReaderAISidebar(state: state) } }
}
#endif
