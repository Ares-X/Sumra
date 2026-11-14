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
                    ReaderFloatingLayout(spacing: compact ? 8 : 12) {
                        navigation(compact: compact).fixedSize()
                            .accessibilityElement(children: .contain).accessibilityIdentifier("floating-navigation")
                        documents(compact: compact)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("floating-documents")
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
            Button(action: state.toggleFindPanel) { Image(systemName: "magnifyingglass").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .disabled(!state.supportsSearch).help(L("Find")).accessibilityLabel(L("Find"))
                .foregroundStyle(state.showFind ? Color.accentColor : Color.primary)
            Button(action: state.editTypography) { Text(verbatim: "Aa").frame(width: 24, height: 24).contentShape(Rectangle()) }
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

/// Measure the actual side controls before offering the middle group its space.
/// A short group stays centered; a crowded group can use the asymmetric space
/// between both sides without overlapping either of them.
private struct ReaderFloatingLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: proposal.width ?? sizes.reduce(2 * spacing) { $0 + $1.width },
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        let start = bounds.minX + left.width + spacing
        let end = bounds.maxX - right.width - spacing
        let width = min(subviews[1].sizeThatFits(.unspecified).width, max(0, end - start))
        let x = max(start, min(bounds.midX - width / 2, end - width))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(left))
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(right))
    }
}

/// Home is a separate launch surface, with a fixed header in its layout.
@MainActor struct ReaderHomeHeader: View {
    @ObservedObject var state: ReaderState
    private var visible: Bool { state.homeHeaderShown }

    var body: some View {
        HStack(spacing: 0) {
            ReaderFloatingWindowButtons().frame(width: 54, height: 20)
            if state.tabCount > 1 {
                ReaderDocumentTabs(state: state)
                    .padding(.leading, 12)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: 28).padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ReaderHomeDragRegion())
        .accessibilityElement(children: .contain).accessibilityIdentifier("home-header")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
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

/// Normal chrome uses the same document captions as floating controls while
/// leaving NSToolbar and the system window buttons in AppKit's ownership.
@MainActor struct ReaderNormalDocumentTabs: View {
    @ObservedObject var state: ReaderState
    static let height: CGFloat = 32

    var body: some View {
        ReaderDocumentTabs(state: state)
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .background(Color(nsColor: ReaderTheme.color(state.palette.background)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader-document-tabs")
            .modifier(ReaderLanguage())
    }
}

/// The normal strip belongs to AppKit's titlebar layout and input hierarchy.
@MainActor final class ReaderNormalTabsAccessory: NSTitlebarAccessoryViewController {
    final class HostingView: NSHostingView<ReaderNormalDocumentTabs> {
        var acceptsTabInput = true
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            acceptsTabInput ? super.hitTest(point) : nil
        }
    }
    let tabsView: HostingView
    init(state: ReaderState) {
        tabsView = HostingView(rootView: ReaderNormalDocumentTabs(state: state))
        super.init(nibName: nil, bundle: nil)
        tabsView.sizingOptions = []
        tabsView.frame = CGRect(x: 0, y: 0, width: 560, height: ReaderNormalDocumentTabs.height)
        view = tabsView
        layoutAttribute = .bottom
        fullScreenMinHeight = ReaderNormalDocumentTabs.height
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The native document window group is the only tab model.
@MainActor struct ReaderDocumentTabs: View {
    @ObservedObject var state: ReaderState
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var tabs: [Tab] = []
    @State private var selectionRevision = 0

    private struct Tab: Equatable, Identifiable {
        let id: Int
        let title: String
        let color: NSColor?
    }

    var body: some View {
        tabStrip
        .frame(idealWidth: preferredWidth)
        .font(.system(size: 12)).buttonStyle(ReaderFloatingButtonStyle())
        .foregroundStyle(Color(nsColor: ReaderTheme.color(state.palette.text)))
        .onAppear(perform: updateTabs)
        .onChange(of: state.tabCount) { _ in updateTabs() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { _ in updateTabs() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if notification.object as? NSWindow === state.window { selectionRevision += 1 }
        }
    }

    private var preferredWidth: CGFloat {
        let titles = tabs.isEmpty ? [state.document?.url.lastPathComponent ?? "Sumra"] : tabs.map(\.title)
        let labelWidth = titles.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width }.max() ?? 0
        // Keep long filenames readable without letting one title occupy the bar.
        let tabWidth = min(220, max(120, ceil(labelWidth) + 63))
        return CGFloat(titles.count) * tabWidth + CGFloat(titles.count - 1) * 4 + 28
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            GeometryReader { geometry in
                let tabWidth = Self.tabWidth(available: geometry.size.width, count: tabs.count)
                let selectedIndex = tabs.firstIndex { $0.id == state.window?.windowNumber } ?? 0
                let visualIndex = layoutDirection == .rightToLeft ? tabs.count - 1 - selectedIndex : selectedIndex
                ReaderTabScrollView(contentWidth: CGFloat(tabs.count) * tabWidth + CGFloat(max(0, tabs.count - 1)) * 4,
                                    selectedRange: CGRect(x: CGFloat(visualIndex) * (tabWidth + 4), y: 0, width: tabWidth, height: 28),
                                    selectionRevision: selectionRevision) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            ZStack(alignment: .trailing) {
                                HStack(spacing: 6) {
                                    if let color = tab.color {
                                        Circle().fill(Color(nsColor: color)).frame(width: 7, height: 7)
                                    }
                                    Text(tab.title).lineLimit(1).truncationMode(.middle)
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.leading, 8)
                                .padding(.trailing, 38)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .accessibilityHidden(true)
                                .overlay {
                                    ReaderTabInteraction(tabWindow: window(tab.id), title: tab.title,
                                        selected: tab.id == state.window?.windowNumber,
                                        interactive: state.hasDocument ? state.toolbarShown : state.homeHeaderShown,
                                        rightToLeft: layoutDirection == .rightToLeft)
                                        .padding(.trailing, 28)
                                }
                                closeButton(window(tab.id), title: tab.title)
                            }
                            .frame(width: tabWidth, height: 28)
                            .modifier(ReaderFloatingTabSurface(selected: tab.id == state.window?.windowNumber,
                                                               color: Color(nsColor: ReaderTheme.color(state.palette.text))))
                            .id(tab.id)

                        }
                    }
                    .font(.system(size: 12)).buttonStyle(ReaderFloatingButtonStyle())
                    .foregroundStyle(Color(nsColor: ReaderTheme.color(state.palette.text)))
                }
            }.frame(height: 28)
            command(.newTab, "plus")
        }
    }

    static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        max(120, (available - CGFloat(max(0, count - 1)) * 4) / CGFloat(max(1, count)))
    }

    private func closeButton(_ window: NSWindow?, title: String? = nil) -> some View {
        Button { if let window { ReaderWindows.close(window) } } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(ReaderFloatingCloseButtonStyle())
        .help(L("Close Tab"))
        .accessibilityLabel(L("Close Tab") + ": " + (title ?? state.document?.url.lastPathComponent ?? ""))
    }

    private func command(_ command: ReaderMenuCommand, _ symbol: String) -> some View {
        Button { command.run(state) } label: { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .disabled(!command.enabled(state)).help(command.title).accessibilityLabel(command.title)
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


/// Input stays attached to the window represented by the caption, including
/// after another tab becomes selected during a drag.
@MainActor struct ReaderTabInteraction: NSViewRepresentable {
    let tabWindow: NSWindow?
    let title: String
    let selected: Bool
    let interactive: Bool
    let rightToLeft: Bool

    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) {
        view.tabWindow = tabWindow
        view.title = title
        view.rightToLeft = rightToLeft
        view.isHidden = !interactive
        view.setAccessibilityLabel(title)
        view.setAccessibilityValue(selected ? 1 : 0)
        view.toolTip = title
    }

    final class Target: NSView, NSDraggingSource {
        static let pasteboardType = NSPasteboard.PasteboardType("app.sumra.document-tab")
        private static let targets = NSHashTable<Target>.weakObjects()
        weak var tabWindow: NSWindow?
        var title = ""
        var rightToLeft = false
        private var pressedEvent: NSEvent?
        private var dragging = false
        private var insertionBefore: Bool? { didSet { needsDisplay = true } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            registerForDraggedTypes([Self.pasteboardType])
            Self.targets.add(self)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        func select() {
            guard let tabWindow else { return }
            tabWindow.tabGroup?.selectedWindow = tabWindow
            tabWindow.makeKeyAndOrderFront(nil)
        }
        override func accessibilityPerformPress() -> Bool { select(); return tabWindow != nil }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 || event.keyCode == 36 { select() }
            else { super.keyDown(with: event) }
        }
        override func mouseDown(with event: NSEvent) {
            pressedEvent = event
            select()
        }
        override func mouseUp(with event: NSEvent) { pressedEvent = nil }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, pressedEvent != nil, let tabWindow else { return }
            pressedEvent = nil
            dragging = true
            let item = NSPasteboardItem()
            item.setString(String(tabWindow.windowNumber), forType: Self.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            (title as NSString).draw(in: bounds.insetBy(dx: 8, dy: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            image.unlockFocus()
            draggingItem.setDraggingFrame(bounds, contents: image)
            let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = false
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            // Escape cancels a drag while the mouse button is still down. A
            // tear-off is committed only after the user releases that button.
            finishDrag(at: screenPoint, operation: operation, cancelled: NSEvent.pressedMouseButtons & 1 != 0)
        }
        func finishDrag(at screenPoint: NSPoint, operation: NSDragOperation, cancelled: Bool) {
            // A cancelled session is never a detach. Drops on the strip's plus
            // button or spacing also leave the document in its current group.
            guard operation.isEmpty, !cancelled else { return }
            let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            if !Self.isOverStrip(at: screenPoint, inWindowNumber: windowNumber) {
                tabWindow?.moveTabToNewWindow(nil)
            }
        }
        static func isOverStrip(at screenPoint: NSPoint, inWindowNumber windowNumber: Int) -> Bool {
            targets.allObjects.contains { target in
                // A background strip cannot accept a drop through the window
                // actually under the pointer, including another app's window.
                guard let window = target.window, window.windowNumber == windowNumber,
                      window.isVisible, !window.isMiniaturized, !target.isHiddenOrHasHiddenAncestor,
                      let strip = target.enclosingScrollView else { return false }
                let point = strip.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                var bounds = strip.bounds
                // The plus button is 24 points wide after the 4-point HStack gap.
                if target.rightToLeft { bounds.origin.x -= 28 }
                bounds.size.width += 28
                return bounds.contains(point)
            }
        }
        private func source(_ sender: NSDraggingInfo) -> NSWindow? {
            guard let number = sender.draggingPasteboard.string(forType: Self.pasteboardType).flatMap(Int.init),
                  let source = sender.draggingSource as? Target,
                  source.tabWindow?.windowNumber == number else { return nil }
            return source.tabWindow
        }
        private func dropBefore(_ sender: NSDraggingInfo) -> Bool {
            let point = convert(sender.draggingLocation, from: nil)
            return rightToLeft ? point.x > bounds.midX : point.x < bounds.midX
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let insertionBefore else { return }
            NSColor.controlAccentColor.setFill()
            let leading = insertionBefore != rightToLeft
            NSRect(x: leading ? bounds.minX : bounds.maxX - 2, y: bounds.minY,
                   width: 2, height: bounds.height).fill()
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard source(sender) != nil else { return [] }
            insertionBefore = dropBefore(sender)
            return .move
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { insertionBefore = nil }
        override func draggingEnded(_ sender: NSDraggingInfo) { insertionBefore = nil }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard source(sender) != nil else { return [] }
            if let event = NSApp.currentEvent { autoscroll(with: event) }
            insertionBefore = dropBefore(sender)
            return .move
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { source(sender) != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let source = source(sender), let destination = tabWindow else { return false }
            let before = dropBefore(sender)
            insertionBefore = nil
            Self.move(source, relativeTo: destination, before: before)
            return true
        }

        /// Reattach siblings around the selected source rather than removing
        /// that source from its fullscreen group and creating a second Space.
        static func move(_ source: NSWindow, relativeTo destination: NSWindow, before: Bool) {
            guard source !== destination else { return }
            if let group = source.tabGroup, destination.tabGroup === group {
                let old = group.windows
                let others = old.filter { $0 !== source }
                guard let target = others.firstIndex(of: destination), let origin = old.firstIndex(of: source) else { return }
                let index = target + (before ? 0 : 1)
                guard index != origin else { return }
                group.selectedWindow = source
                if index > origin {
                    for neighbor in old[(origin + 1)...index] {
                        group.removeWindow(neighbor)
                        source.addTabbedWindow(neighbor, ordered: .below)
                    }
                } else {
                    for neighbor in old[index..<origin].reversed() {
                        group.removeWindow(neighbor)
                        source.addTabbedWindow(neighbor, ordered: .above)
                    }
                }
            } else {
                destination.addTabbedWindow(source, ordered: before ? .below : .above)
            }
            source.tabGroup?.selectedWindow = source
            source.makeKeyAndOrderFront(nil)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            let close = menu.addItem(withTitle: L("Close Tab"), action: #selector(closeTab), keyEquivalent: "")
            close.target = self
            let detach = menu.addItem(withTitle: L("Move Tab to New Window"), action: #selector(detachTab), keyEquivalent: "")
            detach.target = self
            return menu
        }
        @objc private func closeTab() { if let tabWindow { ReaderWindows.close(tabWindow) } }
        @objc private func detachTab() { tabWindow?.moveTabToNewWindow(nil) }
    }
}


/// The tab owns its hover surface, including its overlapping close target.
private struct ReaderFloatingTabSurface: ViewModifier {
    let selected: Bool
    let color: Color
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(color.opacity(hovered ? (selected ? 0.14 : 0.08) : selected ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}

private struct ReaderFloatingCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CloseButton(configuration: configuration)
    }
    private struct CloseButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.20 : hovered ? 0.14 : 0))
                        .frame(width: 18, height: 18)
                }
                .onHover { hovered = $0 }
        }
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
            // Keep native window buttons outside the shadow's compositing
            // surface so AppKit can present the green-button system menu.
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: ReaderTheme.color(palette.background)))
                    .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: ReaderTheme.color(palette.text)).opacity(0.10), lineWidth: 0.5))
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
        private var pointerInside = false
        private var pointerTracking: NSTrackingArea?
        private var modifierMonitor: Any?
        private var optionDown = false
        private var fullscreen = false
        private var nativeCloseAction: Selector?
        private let glyphs = HoverGlyphs(frame: .zero)
        override init(frame: NSRect) {
            super.init(frame: frame)
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable])!
                if type == .closeButton { nativeCloseAction = button.action }
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
            glyphs.owner = self
            glyphs.frame = bounds
            glyphs.autoresizingMask = [.width, .height]
            addSubview(glyphs)
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
            synchronizePointer()
        }
        override func mouseEntered(with event: NSEvent) {
            modifierFlagsChanged(event.modifierFlags)
            synchronizePointer()
        }
        override func mouseMoved(with event: NSEvent) {
            modifierFlagsChanged(event.modifierFlags)
            synchronizePointer()
        }
        override func mouseExited(with event: NSEvent) { synchronizePointer() }
        private func synchronizePointer() {
            // Tracking events can arrive after their area was replaced. Native
            // window controls also change context with a stationary pointer.
            guard let window, !isHiddenOrHasHiddenAncestor else {
                setPointerInside(false)
                return
            }
            setPointerInside(bounds.intersection(visibleRect).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
        private func setPointerInside(_ inside: Bool) {
            guard pointerInside != inside else { return }
            pointerInside = inside
            glyphs.needsDisplay = true
        }
        func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
            let option = flags.contains(.option)
            if optionDown != option {
                optionDown = option
                glyphs.needsDisplay = true
            }
        }
        func stopObservingWindow() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
            modifierMonitor = nil
            setPointerInside(false)
        }
        @objc private func closeWindowGroup(_ sender: NSButton) {
            (readerWindow?.delegate as? ReaderCloseGuard)?.state?.closeTabs("all")
        }
        @objc func updateButtons() {
            if observedWindow !== window {
                stopObservingWindow()
                observedWindow = window
                if let window {
                    modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                        self?.modifierFlagsChanged(event.modifierFlags)
                        return event
                    }
                    for name in [NSWindow.didUpdateNotification, NSWindow.didEnterFullScreenNotification,
                                 NSWindow.didExitFullScreenNotification] {
                        NotificationCenter.default.addObserver(self, selector: #selector(updateButtons), name: name, object: window)
                    }
                }
            }
            let capabilities = readerWindow?.styleMask ?? []
            let isFullscreen = capabilities.contains(.fullScreen)
            if fullscreen != isFullscreen { fullscreen = isFullscreen; glyphs.needsDisplay = true }
            for button in subviews.compactMap({ $0 as? NSButton }) {
                // AppKit owns the minimize and green-button modifier actions.
                // The red window control closes the whole reader group through
                // the same approval chain as Close All Tabs; each tab keeps its x.
                button.target = readerWindow
                let enabled: Bool
                switch NSWindow.ButtonType(rawValue: UInt(button.tag))! {
                case .closeButton:
                    button.action = nativeCloseAction
                    if (readerWindow?.tabGroup?.windows.count ?? 1) > 1,
                       (readerWindow?.delegate as? ReaderCloseGuard)?.state != nil {
                        button.target = self
                        button.action = #selector(closeWindowGroup(_:))
                    }
                    enabled = capabilities.contains(.closable) && readerWindow?.attachedSheet == nil
                case .miniaturizeButton:
                    enabled = capabilities.contains(.miniaturizable) && !capabilities.contains(.fullScreen)
                default: enabled = capabilities.contains(.resizable) || capabilities.contains(.fullScreen)
                }
                if button.isEnabled != enabled { button.isEnabled = enabled; glyphs.needsDisplay = true }
            }
            synchronizePointer()
        }
        // Standard factory buttons keep native rendering, hit regions and
        // pressed states. AppKit's shared titlebar hover owner isn't public;
        // draw only its familiar group symbols above the unmodified controls.
        private final class HoverGlyphs: NSView {
            weak var owner: Buttons?
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func draw(_ dirtyRect: NSRect) {
                guard let owner, owner.pointerInside else { return }
                NSColor.black.withAlphaComponent(0.7).setStroke()
                NSColor.black.withAlphaComponent(0.7).setFill()
                for button in owner.subviews.compactMap({ $0 as? NSButton }) where button.isEnabled {
                    let center = CGPoint(x: button.frame.midX, y: button.frame.midY)
                    let path = NSBezierPath()
                    path.lineWidth = 1.15
                    path.lineCapStyle = .round
                    switch NSWindow.ButtonType(rawValue: UInt(button.tag))! {
                    case .closeButton:
                        path.move(to: CGPoint(x: center.x - 2.4, y: center.y - 2.4))
                        path.line(to: CGPoint(x: center.x + 2.4, y: center.y + 2.4))
                        path.move(to: CGPoint(x: center.x - 2.4, y: center.y + 2.4))
                        path.line(to: CGPoint(x: center.x + 2.4, y: center.y - 2.4))
                        path.stroke()
                    case .miniaturizeButton:
                        path.move(to: CGPoint(x: center.x - 3, y: center.y))
                        path.line(to: CGPoint(x: center.x + 3, y: center.y))
                        path.stroke()
                    default:
                        if owner.optionDown && !owner.fullscreen {
                            path.move(to: CGPoint(x: center.x - 3, y: center.y))
                            path.line(to: CGPoint(x: center.x + 3, y: center.y))
                            path.move(to: CGPoint(x: center.x, y: center.y - 3))
                            path.line(to: CGPoint(x: center.x, y: center.y + 3))
                            path.stroke()
                        } else {
                            for direction in [CGFloat(-1), 1] {
                                let corner = (owner.fullscreen ? 0.5 : 3) * direction
                                let edge = (owner.fullscreen ? 3 : -0.5) * direction
                                path.move(to: CGPoint(x: center.x + corner, y: center.y + corner))
                                path.line(to: CGPoint(x: center.x + corner, y: center.y + edge))
                                path.line(to: CGPoint(x: center.x + edge, y: center.y + corner))
                                path.close()
                            }
                            path.fill()
                        }
                    }
                }
            }
        }
        deinit {
            NotificationCenter.default.removeObserver(self)
            if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        }
    }
}
#endif
