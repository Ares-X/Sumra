#if os(macOS)
import SwiftUI
import AppKit

/// Chrome is an overlay: its opacity never changes the reader's proposed size.
@MainActor struct ReaderFloatingControls: View {
    @ObservedObject var state: ReaderState
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    private var visible: Bool {
        state.toolbarDisplayMode == .hidden ? state.toolbarHoverVisible : state.toolbarShown
    }
    private var opacity: Double {
        state.toolbarDisplayMode == .shown ? 1 : state.toolbarHoverOpacity
    }

    static let height: CGFloat = 36
    static let topInset: CGFloat = 16
    private static let compactWidth: CGFloat = 680

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < Self.compactWidth
            Group {
                if state.toolbarDisplayMode == .hidden {
                    HStack(spacing: 0) {
                        ReaderFloatingWindowButtons().frame(width: 54, height: 20)
                            .padding(.horizontal, 10).frame(height: Self.height)
                            .modifier(ReaderFloatingSurface(palette: state.palette))
                            .accessibilityElement(children: .contain).accessibilityIdentifier("floating-window-controls")
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(alignment: compact ? .center : .top, spacing: 0) {
                        navigation(compact: compact).fixedSize()
                            .accessibilityElement(children: .contain).accessibilityIdentifier("floating-navigation")
                        Spacer(minLength: compact ? 8 : 12)
                        documents(compact: compact).frame(minWidth: 0, maxWidth: 360)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("floating-documents")
                        Spacer(minLength: compact ? 8 : 12)
                        tools(compact: compact).fixedSize()
                            .accessibilityElement(children: .contain).accessibilityIdentifier("floating-tools")
                    }
                    .padding(.horizontal, compact ? 10 : 0)
                    .modifier(ReaderFloatingSurface(palette: state.palette, enabled: compact))
                }
            }
            .frame(height: Self.height)
            .padding(.horizontal, 16).padding(.top, Self.topInset)
        }
        .frame(height: Self.height + Self.topInset, alignment: .top)
        .font(.system(size: 12))
        .buttonStyle(ReaderFloatingButtonStyle())
        .foregroundStyle(Color(nsColor: ReaderTheme.color(state.palette.text)))
        .opacity(opacity)
        .offset(y: reducedMotion ? 0 : (visible ? 0 : -3))
        .animation(reducedMotion ? nil : ReaderMotion.reveal, value: visible)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }

    private func navigation(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            ReaderFloatingWindowButtons().frame(width: 54, height: 20)
            Divider().frame(height: 14)
            Button(action: open) { Image(systemName: "folder").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .help(L("Open Document")).accessibilityLabel(L("Open Document"))
            command(.contents, "sidebar.left")
        }
        .padding(.horizontal, compact ? 0 : 10).frame(height: 36)
        .modifier(ReaderFloatingSurface(palette: state.palette, enabled: !compact))
    }

    private func documents(compact: Bool) -> some View {
        ReaderDocumentTabs(state: state)
            .padding(.horizontal, compact ? 6 : 8).frame(height: Self.height)
            .modifier(ReaderFloatingSurface(palette: state.palette, enabled: !compact))
    }

    private func tools(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            command(.find, "magnifyingglass")
            Button(action: state.editTypography) { Image(systemName: "textformat").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .help(L("Reading Settings")).accessibilityLabel(L("Reading Settings")).disabled(!state.hasDocument)
            Menu {
                ReaderCommandMenuItems(state: state, commands: [.zoomOut, .zoomIn, .actual, .fitPage, .fitWidth, .customZoom])
            } label: { Text(state.zoomLabel).monospacedDigit() }
            .menuStyle(.borderlessButton).fixedSize().disabled(!state.hasDocument)
            .accessibilityLabel(L("Zoom"))
            Menu {
                ReaderCommandMenuItems(state: state, commands: [.previous, .next, .goToPage, .paged, .continuous, .twoPages, .coverOnItsOwn, .rightToLeft, .print])
                Divider()
                ReaderToolbarDisplayPicker()
                ReaderProgressDisplayPicker()
                ReaderImmersiveControlsToggle()
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("More"))
        }
        .padding(.horizontal, compact ? 0 : 10).frame(height: 36)
        .modifier(ReaderFloatingSurface(palette: state.palette, enabled: !compact))
    }

    private func command(_ command: ReaderMenuCommand, _ symbol: String) -> some View {
        Button { command.run(state) } label: { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .disabled(!command.enabled(state)).help(command.title).accessibilityLabel(command.title)
    }

}

/// Home is a separate launch surface, with a fixed header in its layout.
@MainActor struct ReaderHomeHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            ReaderFloatingWindowButtons().frame(width: 54, height: 20)
            Spacer(minLength: 0)
        }
        .frame(height: 28).padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ReaderHomeDragRegion())
        .accessibilityElement(children: .contain).accessibilityIdentifier("home-header")
    }
}

/// The empty home titlebar remains draggable without adding document commands.
private struct ReaderHomeDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// The native document window group is the only tab model.
@MainActor struct ReaderDocumentTabs: View {
    @ObservedObject var state: ReaderState
    @State private var tabs: [Tab] = []

    private struct Tab: Equatable, Identifiable {
        let id: Int
        let title: String
        let color: NSColor?
    }

    var body: some View {
        Group {
            if tabs.count <= 1 {
                HStack(spacing: 6) {
                    if let color = tabs.first?.color {
                        Circle().fill(Color(nsColor: color)).frame(width: 7, height: 7)
                    }
                    documentTitle
                    closeButton(state.window)
                    command(.newTab, "plus")
                }
            } else { tabStrip }
        }
        .font(.system(size: 12)).buttonStyle(ReaderFloatingButtonStyle())
        .foregroundStyle(Color(nsColor: ReaderTheme.color(state.palette.text)))
        .onAppear(perform: updateTabs)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { _ in updateTabs() }
    }

    private var documentTitle: some View {
        Text(state.document?.url.lastPathComponent ?? "Sumra")
            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(tabs) { tab in
                                HStack(spacing: 6) {
                                    Button { selectTab(tab.id) } label: {
                                        HStack(spacing: 6) {
                                            if let color = tab.color {
                                                Circle().fill(Color(nsColor: color)).frame(width: 7, height: 7)
                                            }
                                            Text(tab.title).lineLimit(1).truncationMode(.middle)
                                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(tab.title).accessibilityLabel(tab.title)
                                    .accessibilityValue(tab.id == state.window?.windowNumber ? L("Selected") : "")
                                    closeButton(window(tab.id), title: tab.title)
                                }
                                .padding(.horizontal, 8)
                                .frame(width: max(120, (geometry.size.width - CGFloat(tabs.count - 1) * 4) / CGFloat(tabs.count)), height: 28)
                                .background(Color(nsColor: ReaderTheme.color(state.palette.text))
                                    .opacity(tab.id == state.window?.windowNumber ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5))
                                .id(tab.id)
                                .contextMenu {
                                    Button(L("Close Tab")) { window(tab.id)?.performClose(nil) }
                                    Button(L("Move Tab to New Window")) { window(tab.id)?.moveTabToNewWindow(nil) }
                                }
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(state.window?.windowNumber, anchor: .center) }
                    .onChange(of: tabs) { _ in proxy.scrollTo(state.window?.windowNumber, anchor: .center) }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                        if notification.object as? NSWindow === state.window {
                            proxy.scrollTo(state.window?.windowNumber, anchor: .center)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
                        if notification.object as? NSWindow === state.window {
                            proxy.scrollTo(state.window?.windowNumber, anchor: .center)
                        }
                    }
                }
            }.frame(height: 28)
            command(.newTab, "plus")
        }
    }

    private func closeButton(_ window: NSWindow?, title: String? = nil) -> some View {
        Button { window?.performClose(nil) } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .help(L("Close Tab"))
        .accessibilityLabel(L("Close Tab") + ": " + (title ?? state.document?.url.lastPathComponent ?? ""))
    }

    private func command(_ command: ReaderMenuCommand, _ symbol: String) -> some View {
        Button { command.run(state) } label: { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .disabled(!command.enabled(state)).help(command.title).accessibilityLabel(command.title)
    }
    private func selectTab(_ number: Int) {
        guard let window = window(number) else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    private func window(_ number: Int) -> NSWindow? {
        (state.window?.tabGroup?.windows ?? [state.window].compactMap { $0 }).first { $0.windowNumber == number }
    }
    private func updateTabs() {
        let current = (state.window?.tabGroup?.windows ?? [state.window].compactMap { $0 }).map {
            Tab(id: $0.windowNumber, title: $0.title,
                color: ($0.tab.accessoryView?.layer?.backgroundColor).flatMap { NSColor(cgColor: $0) })
        }
        if current != tabs { tabs = current }
    }
}


/// The floating surfaces use a visible, consistent pointer and press affordance.
struct ReaderFloatingButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        FloatingButton(configuration: configuration, enabled: enabled)
    }
    private struct FloatingButton: View {
        let configuration: ButtonStyleConfiguration
        let enabled: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.16 : hovered ? 0.08 : 0) : 0),
                            in: RoundedRectangle(cornerRadius: 4))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

struct ReaderFloatingSurface: ViewModifier {
    let palette: ReaderTheme
    var enabled = true
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content
            .background(Color(nsColor: ReaderTheme.color(palette.background)), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: ReaderTheme.color(palette.text)).opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
        } else { content }
    }
}

/// Use AppKit's real window buttons and dispatch to the existing document window.
@MainActor struct ReaderFloatingWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> Buttons { Buttons() }
    func updateNSView(_ view: Buttons, context: Context) { view.updateButtons() }
    static func dismantleNSView(_ view: Buttons, coordinator: ()) { view.stopObservingWindow() }
    final class Buttons: NSView {
        var readerWindow: NSWindow? { window }
        override var mouseDownCanMoveWindow: Bool { false }
        private weak var observedWindow: NSWindow?
        private weak var hoveredButton: NSButton? {
            didSet { if hoveredButton !== oldValue { needsDisplay = true } }
        }
        private var pointerTracking: NSTrackingArea?
        override init(frame: NSRect) {
            super.init(frame: frame)
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable])!
                // Leave room for the hover ring within the 54-point group.
                button.frame.origin = NSPoint(x: 2 + index * 18, y: 3)
                button.tag = Int(type.rawValue)
                button.setAccessibilityElement(true)
                button.setAccessibilityRole(.button)
                let subrole: NSAccessibility.Subrole
                switch type {
                case .closeButton: subrole = .closeButton
                case .miniaturizeButton: subrole = .minimizeButton
                default: subrole = .fullScreenButton
                }
                button.setAccessibilitySubrole(subrole)
                button.setAccessibilityLabel(NSAccessibility.Role.button.description(with: subrole))
                addSubview(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateButtons()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            let tracking = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(tracking)
            pointerTracking = tracking
        }
        override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
        override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
        override func mouseExited(with event: NSEvent) { hoveredButton = nil }
        private func updateHover(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            hoveredButton = subviews.compactMap { $0 as? NSButton }.first {
                $0.isEnabled && $0.hitTest(point) === $0
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if let button = hoveredButton, button.isEnabled {
                NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                let ring = NSBezierPath(ovalIn: button.frame.insetBy(dx: -1.5, dy: -1.5))
                ring.lineWidth = 1
                ring.stroke()
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
        func stopObservingWindow() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            hoveredButton = nil
        }
        @objc func updateButtons() {
            if observedWindow !== window {
                stopObservingWindow()
                observedWindow = window
                if let window {
                    for name in [NSWindow.didUpdateNotification, NSWindow.didEnterFullScreenNotification,
                                 NSWindow.didExitFullScreenNotification] {
                        NotificationCenter.default.addObserver(self, selector: #selector(updateButtons), name: name, object: window)
                    }
                }
            }
            let capabilities = readerWindow?.styleMask ?? []
            for button in subviews.compactMap({ $0 as? NSButton }) {
                // Keep the action supplied by AppKit's standard button. In
                // particular, the green button owns its system modifier and
                // fullscreen behavior instead of a second action here.
                button.target = readerWindow
                let enabled: Bool
                switch NSWindow.ButtonType(rawValue: UInt(button.tag))! {
                case .closeButton: enabled = capabilities.contains(.closable) && readerWindow?.attachedSheet == nil
                case .miniaturizeButton:
                    enabled = capabilities.contains(.miniaturizable) && !capabilities.contains(.fullScreen)
                default: enabled = capabilities.contains(.resizable) || capabilities.contains(.fullScreen)
                }
                if button.isEnabled != enabled { button.isEnabled = enabled }
            }
            if hoveredButton?.isEnabled == false { hoveredButton = nil }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
#endif
