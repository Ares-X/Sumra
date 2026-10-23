#if os(macOS)
import AppKit
import SwiftUI

// A nonactivating child panel preserves the reader's first responder and selection.
@MainActor struct ReaderSelectionToolbar: NSViewRepresentable {
    @ObservedObject var state: ReaderState

    static func actions(for state: ReaderState) -> [ReaderMenuCommand] {
        guard state.hasTextSelection else { return [] }
        return [.copy, .speakSelection, .translateGoogle, .highlight].filter { $0.enabled(state) }
    }

    static func frame(selection: CGRect, visible: CGRect, size: CGSize) -> CGRect? {
        let anchor = selection.intersection(visible)
        guard !anchor.isNull, !anchor.isEmpty else { return nil }
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let above = anchor.maxY + 7
        let y = above + size.height <= visible.maxY ? above : max(visible.minY, anchor.minY - size.height - 7)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return host
    }
    func updateNSView(_ view: Host, context: Context) { context.coordinator.update() }
    static func dismantleNSView(_ view: Host, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Host: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?(window) }
    }

    @MainActor final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor final class Coordinator: NSObject {
        private weak var state: ReaderState?
        private weak var parent: NSWindow?
        private var panel: Panel?
        private var monitor: Any?
        private var positioning: Task<Void, Never>?
        private var dragging = false
        private var dismissed = false

        init(state: ReaderState) { self.state = state }

        func attach(_ window: NSWindow?) {
            if parent === window { return }
            detach(); parent = window
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .scrollWheel]) { [weak self] event in
                self?.event(event)
                return event
            }
            update()
        }

        @objc private func windowChanged(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification { detach() }
            else { update() }
        }

        private func event(_ event: NSEvent) {
            guard event.window === parent else { return }
            switch event.type {
            case .leftMouseDown:
                dragging = true; dismissed = false; hide()
            case .leftMouseUp:
                dragging = false; dismissed = false; update()
            case .keyDown:
                if event.keyCode == 53 { dismissed = true }
                hide()
            case .keyUp:
                if event.keyCode != 53 { dismissed = false; update() }
            case .scrollWheel:
                hide(); update()
            default: break
            }
        }

        func update() {
            positioning?.cancel()
            guard let state, let parent, parent.isKeyWindow, !dragging, !dismissed,
                  !state.presentation, !ReaderWindows.isTyping(in: parent, state: state), !Self.actions(for: state).isEmpty else { hide(); return }
            let documentID = state.document?.id
            positioning = Task { [weak self, weak state, weak parent] in
                // The reader receives the event first and owns its selection update.
                await Task.yield()
                guard let self, let state, let parent, !Task.isCancelled else { return }
                let box = await state.selectionScreenBounds?()
                guard !Task.isCancelled else { return }
                guard let box, state.document?.id == documentID, parent.isKeyWindow,
                      !ReaderWindows.isTyping(in: parent, state: state),
                      let content = parent.contentView else { self.hide(); return }
                let visible = parent.convertToScreen(content.convert(content.bounds, to: nil))
                self.show(state: state, parent: parent, selection: box, visible: visible)
            }
        }

        private func show(state: ReaderState, parent: NSWindow, selection: CGRect, visible: CGRect) {
            let actions = Self.actions(for: state)
            guard !actions.isEmpty else { hide(); return }
            if panel == nil {
                let created = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                created.isReleasedWhenClosed = false
                created.isOpaque = false
                created.backgroundColor = .clear
                created.hasShadow = true
                created.hidesOnDeactivate = true
                created.tabbingMode = .disallowed
                parent.addChildWindow(created, ordered: .above)
                panel = created
            }
            let view = NSHostingView(rootView: SelectionActions(state: state, commands: actions, performed: { [weak self] in self?.dismissed = true; self?.hide() }).modifier(ReaderLanguage()))
            let size = view.fittingSize
            guard let frame = ReaderSelectionToolbar.frame(selection: selection, visible: visible, size: size) else { hide(); return }
            panel?.contentView = view
            panel?.appearance = parent.effectiveAppearance
            panel?.setFrame(frame, display: true)
            panel?.orderFront(nil)
        }

        private static func actions(for state: ReaderState) -> [ReaderMenuCommand] { ReaderSelectionToolbar.actions(for: state) }

        private func hide() { panel?.orderOut(nil) }

        func detach() {
            positioning?.cancel(); positioning = nil
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            NotificationCenter.default.removeObserver(self)
            if let panel { parent?.removeChildWindow(panel); panel.close() }
            panel = nil; parent = nil
        }
    }
}

@MainActor private struct SelectionActions: View {
    @ObservedObject var state: ReaderState
    let commands: [ReaderMenuCommand]
    var performed: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(commands) { command in
                Button {
                    if command == .translateGoogle { state.translateSelection() }
                    else { command.run(state) }
                    performed()
                } label: {
                    switch command {
                    case .copy: Label(L("Copy"), systemImage: "doc.on.doc")
                    case .speakSelection: Label(L("Read"), systemImage: "speaker.wave.2")
                    case .translateGoogle: Label(L("Translate"), systemImage: "character.bubble")
                    default: Label(L("Highlight"), systemImage: "highlighter")
                    }
                }.buttonStyle(.borderless).padding(.horizontal, 9).padding(.vertical, 8)
            }
        }
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
