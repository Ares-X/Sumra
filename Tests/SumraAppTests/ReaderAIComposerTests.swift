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

    func testCompletedConversationSurvivesSidebarAndPresentationAndResumesSession() async throws {
        let fixture = try ComposerFixture()
        defer { fixture.close() }
        try await fixture.mount()
        try fixture.enter("First synthetic question")
        try await fixture.press("Send")
        try await fixture.wait { fixture.started }
        try fixture.release()
        try await fixture.wait { !fixture.state.aiModel.busy && fixture.finished }
        let messages = fixture.state.aiModel.messages
        XCTAssertEqual(fixture.state.aiModel.sessionID, ComposerFixture.sessionID)

        try await fixture.press("Close Sidebar")
        try await fixture.wait { fixture.editor == nil }
        ReaderMenuCommand.ai.run(fixture.state)
        try await fixture.mount()
        XCTAssertEqual(fixture.state.aiModel.messages, messages)
        XCTAssertTrue(fixture.texts.contains("Fixture answer: Lumen Harbor."))

        fixture.state.presentation = true
        try await fixture.wait { fixture.editor == nil }
        fixture.state.presentation = false
        try await fixture.mount()
        XCTAssertEqual(fixture.state.aiModel.messages, messages)
        XCTAssertEqual(fixture.state.aiModel.sessionID, ComposerFixture.sessionID)
        let other = ReaderState(recordsHistory: false)
        other.document = fixture.state.document
        XCTAssertTrue(other.aiModel.messages.isEmpty)
        XCTAssertNil(other.aiModel.sessionID)
        other.windowClosed()

        try fixture.reset(mode: "success")
        try fixture.enter("Continue the synthetic conversation")
        try await fixture.press("Send")
        try await fixture.wait { fixture.started }
        let arguments = try String(contentsOf: fixture.temporary.url.appendingPathComponent("arguments"))
        XCTAssertTrue(arguments.contains("resume"))
        XCTAssertTrue(arguments.contains(ComposerFixture.sessionID))
        try fixture.release()
        try await fixture.wait { fixture.finished && !fixture.state.aiModel.busy }
        XCTAssertEqual(fixture.state.aiModel.messages.count, 4)
        try await fixture.press("New Conversation")
        try await fixture.wait { fixture.state.aiModel.messages.isEmpty }
        XCTAssertNil(fixture.state.aiModel.sessionID)

        let revision = fixture.state.aiModel.begin(question: "Outgoing document")
        fixture.state.aiModel.receive("Outgoing answer", sessionID: ComposerFixture.sessionID, revision: revision)
        fixture.state.aiModel.cancel()
        try await fixture.press("Close Sidebar")
        try await fixture.wait { fixture.editor == nil }
        fixture.state.document = ReadingDocument(url: fixture.temporary.url.appendingPathComponent("Other.txt"), content: .text("Other document"))
        XCTAssertTrue(fixture.state.aiModel.messages.isEmpty)
        XCTAssertNil(fixture.state.aiModel.sessionID)
        let closing = fixture.state.aiModel.begin(question: "Closing document")
        fixture.state.aiModel.receive("Partial closing answer", revision: closing)
        fixture.state.windowClosed()
        XCTAssertTrue(fixture.state.aiModel.messages.isEmpty)
        XCTAssertFalse(fixture.state.aiModel.busy)
    }

    func testClosingRunningSidebarCancelsCLIAndRetainsPartialReply() async throws {
        let fixture = try ComposerFixture()
        defer { fixture.close() }
        try fixture.reset(mode: "stream")
        try await fixture.mount()
        try fixture.enter("Stream a synthetic answer")
        try await fixture.press("Send")
        try await fixture.wait { fixture.state.aiModel.messages.last?.text.contains("Stream stage 1") == true }
        let messages = fixture.state.aiModel.messages
        try await fixture.press("Close Sidebar")
        try await fixture.wait { fixture.editor == nil && !fixture.running && !fixture.state.aiModel.busy }
        XCTAssertEqual(fixture.state.aiModel.messages, messages)
        XCTAssertEqual(fixture.state.aiModel.sessionID, ComposerFixture.sessionID)
        ReaderMenuCommand.ai.run(fixture.state)
        try await fixture.mount()
        XCTAssertEqual(fixture.state.aiModel.messages, messages)
        XCTAssertTrue(fixture.texts.contains("Incomplete reply"))
        XCTAssertFalse(fixture.hasProgress)
    }

    func testStreamingFollowsBottomUntilReaderScrollsAwayAndResumesAtBottomOrSend() async throws {
        let fixture = try ComposerFixture()
        defer { fixture.close() }
        try fixture.reset(mode: "stream")
        try await fixture.mount()
        try fixture.enter("Stream a long synthetic answer")
        try await fixture.press("Send")
        try await fixture.wait { fixture.state.aiModel.messages.last?.text.contains("Stream stage 1") == true && fixture.isAtBottom }
        let scroll = try XCTUnwrap(fixture.conversationScroll)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
        XCTAssertEqual(fixture.editor?.enclosingScrollView?.frame.height ?? 0, 85, accuracy: 3)
        fixture.scrollConversation(toBottom: false)
        let readingOrigin = scroll.contentView.bounds.origin.y
        XCTAssertFalse(fixture.isAtBottom)
        try fixture.advance(2)
        try await fixture.wait { fixture.state.aiModel.messages.last?.text.contains("Stream stage 2") == true }
        try await fixture.settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, readingOrigin, accuracy: 1)
        try fixture.advance(3)
        try await fixture.wait { fixture.state.aiModel.messages.last?.text.contains("Stream stage 3") == true }
        try await fixture.settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, readingOrigin, accuracy: 1)

        fixture.scrollConversation(toBottom: true)
        XCTAssertTrue(fixture.isAtBottom)
        try fixture.advance(4)
        try await fixture.wait { fixture.state.aiModel.messages.last?.text.contains("Stream stage 4") == true && fixture.isAtBottom }
        try fixture.release()
        try await fixture.wait { !fixture.state.aiModel.busy && fixture.finished }
        fixture.scrollConversation(toBottom: false)
        XCTAssertFalse(fixture.isAtBottom)
        try fixture.reset(mode: "stream")
        try fixture.enter("A new send restores follow")
        try await fixture.press("Send")
        try await fixture.wait { fixture.state.aiModel.messages.last?.text.contains("Stream stage 1") == true && fixture.isAtBottom }
        try await fixture.press("Cancel")
        try await fixture.wait { !fixture.running }
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
    static let sessionID = "A6BE1460-30C5-4C40-8CB1-EB17DD4A9001"
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
        let streamEvents = try (1...4).map { stage -> String in
            let text = (1...(stage * 12)).map { "Synthetic paragraph \($0). The amber telescope remains in Lumen Harbor. This text is only a scrolling fixture." }.joined(separator: "\n\n") + "\nStream stage \(stage)"
            let data = try JSONSerialization.data(withJSONObject: ["type": "item.updated", "item": ["type": "agent_message", "text": text]])
            return String(decoding: data, as: UTF8.self)
        }
        let streamingScript = streamEvents.enumerated().map { index, event in
            let wait = index == 0 ? "" : "while [ ! -e step\(index + 1) ]; do /bin/sleep 0.02; done\n"
            return wait + "printf '%s\\n' '" + event + "'"
        }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        case " $* " in *" mcp list "*) printf '[]'; exit 0;; esac
        printf '%s' "$$" > fixture.pid
        printf '%s\\n' "$@" > arguments
        /bin/cat > request.json
        : > started
        trap 'exit 0' TERM INT
        printf '%s\\n' '{"type":"thread.started","thread_id":"\(Self.sessionID)"}'
        if [ "$(/bin/cat mode)" = stream ]; then
        \(streamingScript)
        fi
        while [ ! -e release ]; do /bin/sleep 0.02; done
        if [ "$(/bin/cat mode)" = fail ]; then
          printf '%s\\n' 'Synthetic provider failure' >&2
          exit 42
        fi
        if [ "$(/bin/cat mode)" != stream ]; then
          printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Fixture answer: Lumen Harbor."}}'
        fi
        printf '%s\\n' '{"type":"turn.completed"}'
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
    var conversationScroll: NSScrollView? {
        views(host).compactMap { $0 as? NSScrollView }.first { $0 !== editor?.enclosingScrollView }
    }
    var isAtBottom: Bool {
        guard let scroll = conversationScroll, let document = scroll.documentView else { return false }
        let visible = scroll.documentVisibleRect
        return (document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY) <= 1
    }
    func scrollConversation(toBottom: Bool) {
        guard let scroll = conversationScroll, let document = scroll.documentView else { return }
        let high = max(document.bounds.minY, document.bounds.maxY - scroll.documentVisibleRect.height)
        let y = toBottom == document.isFlipped ? high : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func advance(_ stage: Int) throws { try Data().write(to: temporary.url.appendingPathComponent("step\(stage)")) }
    func settle() async throws {
        // Allow deferred SwiftUI layout after a known fixture event, then assert
        // the native viewport remains at the reader's chosen location.
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
    }
    func release() throws { try Data().write(to: temporary.url.appendingPathComponent("release")) }
    func reset(mode: String) throws {
        for marker in ["started", "finished", "release", "step2", "step3", "step4"] where exists(marker) {
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
    var body: some View { if state.showAI && !state.presentation { ReaderAISidebar(state: state) } }
}
#endif
