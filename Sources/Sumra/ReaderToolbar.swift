#if os(macOS)
import SwiftUI
import AppKit
import SumraCore

enum ReaderToolbarDisplayMode: String, CaseIterable {
    case shown, auto, hidden

    var title: String {
        switch self {
        case .shown: return L("Always Show")
        case .auto: return L("Auto Hide")
        case .hidden: return L("Always Hide")
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let value = defaults.string(forKey: "toolbarDisplayMode"), let mode = Self(rawValue: value) { return mode }
        // Migrate the previous local hover preference once; visibility itself
        // was window-local and did not survive relaunch.
        let mode: Self = defaults.bool(forKey: "revealHiddenToolbar") ? .auto : .shown
        defaults.set(mode.rawValue, forKey: "toolbarDisplayMode")
        defaults.removeObject(forKey: "revealHiddenToolbar")
        return mode
    }

    @MainActor func apply(to reader: ReaderState? = nil) {
        UserDefaults.standard.set(rawValue, forKey: "toolbarDisplayMode")
        reader?.toolbarDisplayMode = self
        for state in ReaderWindows.states where state !== reader { state.toolbarDisplayMode = self }
    }
}

struct ReaderToolbarDisplayPicker: View {
    @AppStorage("toolbarDisplayMode") private var mode = ReaderToolbarDisplayMode.load()

    var body: some View {
        Picker(L("Toolbar Display"), selection: Binding(get: { mode }, set: { $0.apply() })) {
            ForEach(ReaderToolbarDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

struct ReaderImmersiveControlsToggle: View {
    @AppStorage("immersiveControls") private var enabled = false
    var body: some View {
        Toggle(L("Floating Reading Controls"), isOn: Binding(get: { enabled }, set: { value in
            enabled = value
            for reader in ReaderWindows.states { reader.immersiveControls = value }
        }))
    }
}

/// Menu selection belongs to the command; native toggles draw the checkmark
/// without inheriting the toolbar label's icon-only presentation.
@MainActor struct ReaderCommandMenuItems: View {
    @ObservedObject var state: ReaderState
    let commands: [ReaderMenuCommand]
    var body: some View {
        ForEach(commands) { command in
            Group {
                if let checked = command.checked(state) {
                    Toggle(command.title, isOn: Binding(get: { checked }, set: { _ in command.run(state) }))
                } else {
                    Button(command.title) { command.run(state) }
                }
            }.disabled(!command.enabled(state))
        }
        .labelStyle(.titleAndIcon)
    }
}

// SwiftUI owns toolbar items and requested visibility. AppKit enforces Always
// Hide, preserves window geometry, and tracks native fullscreen/hover chrome.
struct ReaderToolbarAppearance: ViewModifier {
    var shown: Bool
    var hidesNativeTitle: Bool
    var permanentlyHidden = false
    var background: NSColor
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            // navigationTitle owns the native title item. Remove that item
            // with the hidden tools so SwiftUI cannot restore a title laid
            // out while the native window buttons were hidden.
            content.toolbar(removing: hidesNativeTitle || !shown ? .title : nil)
                .windowToolbarFullScreenVisibility(hidesNativeTitle || permanentlyHidden ? .automatic : .visible)
                .toolbarBackground(Color(nsColor: background), for: .windowToolbar)
                .toolbarBackground(shown ? .visible : .hidden, for: .windowToolbar)
        } else {
            content
                .toolbarBackground(Color(nsColor: background), for: .windowToolbar)
                .toolbarBackground(shown ? .visible : .hidden, for: .windowToolbar)
        }
    }
}

@MainActor struct ReaderToolbarWindow: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    var reducedMotion = ReaderMotion.reducedMotion
    @Binding var fullscreenMenuInset: CGFloat
    var nativeTopClearance: Binding<CGFloat> = .constant(0)

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.state = state; view.reducedMotion = reducedMotion
        view.fullscreenMenuInset = $fullscreenMenuInset
        view.nativeTopClearance = nativeTopClearance
        view.updateChrome()
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    @MainActor final class Host: NSView {
        private static let hoverEntryDepth: CGFloat = 48
        private static let hoverRetentionDepth: CGFloat = 96
        private static let chromeOwners = NSMapTable<NSView, Host>.weakToWeakObjects()
        weak var state: ReaderState?
        var reducedMotion = ReaderMotion.reducedMotion
        var fullscreenMenuInset: Binding<CGFloat>?
        var nativeTopClearance: Binding<CGFloat>?
        private var reservedNativeHeight: CGFloat = 0
        private var reservedMenuHeight: CGFloat = 0
        private weak var parent: NSWindow?
        private var monitor: Any?
        private var tracking: NSTrackingArea?
        private var observedDocumentID: UUID?
        private weak var observedToolbar: NSToolbar?
        private var toolbarObservation: NSKeyValueObservation?
        private var permanentlyHiddenToolbar: (toolbar: NSToolbar, visible: Bool)?
        private var visibilityFrame: NSRect?
        private var hoverDismiss: Task<Void, Never>?
        private var menuTracking = false
        private var originalButtonAppearance: [NSWindow.ButtonType: (button: NSButton, hidden: Bool, alpha: CGFloat)] = [:]
        private weak var toolbarWindow: NSWindow?
        private weak var toolbarContent: NSView?
        private var originalToolbarChrome: (contentAlpha: CGFloat, ignoresMouse: Bool, background: NSColor, opaque: Bool, shadow: Bool)?
        private var toolbarOpacity: CGFloat?
        private weak var nativeControlsContainer: NSView?
        private var titlebarViews: [(view: NSView, alpha: CGFloat, hidden: Bool, layered: Bool, background: CGColor?)] = []
        private var accessoryOpacity: CGFloat?
        private weak var accessoryContentOwner: NSView?
        private var original: (fullSize: Bool, transparent: Bool, title: NSWindow.TitleVisibility,
                               separator: NSTitlebarSeparatorStyle, background: NSColor, mouseMoved: Bool)?

        // Temporary native chrome leaves the book beneath its titlebar. Keep
        // that band draggable instead of passing its empty space to text.
        private var nativeTitlebarRect: NSRect {
            guard let parent, let state,
                  !state.usesCustomChrome, !state.presentation,
                  !parent.styleMask.contains(.fullScreen),
                  let titlebar = originalButtonAppearance[.closeButton]?.button.superview else { return .zero }
            return convert(titlebar.bounds, from: titlebar)
        }
        private var titlebarDragRect: NSRect { state?.toolbarOverlaysContent == true ? nativeTitlebarRect.intersection(bounds) : .zero }
        override func hitTest(_ point: NSPoint) -> NSView? {
            titlebarDragRect.contains(convert(point, from: superview)) ? self : nil
        }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if !handleMouseDown(event) { super.mouseDown(with: event) }
        }
        override func resetCursorRects() {
            let rect = titlebarDragRect
            if !rect.isEmpty { addCursorRect(rect, cursor: .arrow) }
        }

        private var cursorDragRect = NSRect.zero
        private var cursorToolbarShown = false
        private weak var cursorToolbarView: NSView?
        private var toolbarCursorTracking: NSTrackingArea?
        override func layout() {
            super.layout()
            updateDragCursor()
        }
        private func updateDragCursor() {
            let rect = titlebarDragRect
            let shown = state?.toolbarShown == true
            if cursorDragRect != rect || cursorToolbarShown != shown {
                cursorDragRect = rect
                cursorToolbarShown = shown
                window?.invalidateCursorRects(for: self)
                if let cursorToolbarView { window?.invalidateCursorRects(for: cursorToolbarView) }
            }
        }
        private func trackToolbarCursor(in view: NSView?) {
            guard cursorToolbarView !== view else { return }
            if let toolbarCursorTracking { cursorToolbarView?.removeTrackingArea(toolbarCursorTracking) }
            cursorToolbarView = view; toolbarCursorTracking = nil
            if let view {
                let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
                view.addTrackingArea(area); toolbarCursorTracking = area
            }
        }
        override func cursorUpdate(with event: NSEvent) {
            if event.window === parent, isTitlebarDragPoint(event.locationInWindow) { NSCursor.arrow.set() }
        }

        private func isTitlebarDragPoint(_ point: NSPoint) -> Bool {
            guard let parent, nativeTitlebarRect.contains(convert(point, from: nil)),
                  let root = parent.contentView?.superview,
                  let hit = root.hitTest(root.convert(point, from: nil)), hit.mouseDownCanMoveWindow else { return false }
            // Native tab backgrounds can report draggable input. Their
            // titlebar accessory still owns every hit in its view subtree.
            if parent.titlebarAccessoryViewControllers.contains(where: {
                hit === $0.view || hit.isDescendant(of: $0.view)
            }) { return false }
            // SwiftUI toolbar item hosts can report mouseDownCanMoveWindow even
            // for buttons. Their public item views keep all of their own input.
            return !(parent.toolbar?.items ?? []).contains { item in
                guard let view = item.view, view.window === parent, !view.isHiddenOrHasHiddenAncestor else { return false }
                return view.convert(view.bounds, to: nil).contains(point)
            }
        }
        func handleMouseDown(_ event: NSEvent) -> Bool {
            if event.type == .leftMouseDown, let parent, event.window === parent,
               nativeTitlebarRect.contains(convert(event.locationInWindow, from: nil)), !parent.isKeyWindow {
                parent.makeKeyAndOrderFront(nil)
            }
            guard event.type == .leftMouseDown, event.clickCount == 1, !event.modifierFlags.contains(.command),
                  let parent, event.window === parent,
                  isTitlebarDragPoint(event.locationInWindow) else { return false }
            // The visible native toolbar is above the document overlay. Route
            // its empty title area to AppKit using the original mouse-down.
            parent.performDrag(with: event)
            return true
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            detach()
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            parent = window
            original = (window.styleMask.contains(.fullSizeContentView), window.titlebarAppearsTransparent,
                        window.titleVisibility, window.titlebarSeparatorStyle, window.backgroundColor,
                        window.acceptsMouseMovedEvents)
            window.acceptsMouseMovedEvents = true
            if let content = window.contentView {
                let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
                content.addTrackingArea(area); tracking = area
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
                if event.type == .leftMouseDown {
                    if self?.handleMouseDown(event) == true { return nil }
                } else { self?.handleMouseMoved(event) }
                return event
            }
            for name in [NSWindow.willCloseNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didUpdateNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: nil)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged), name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged), name: NSMenu.didEndTrackingNotification, object: nil)
            updateChrome()
        }

        private var readerHasKeyFocus: Bool {
            guard let parent else { return false }
            return parent.isKeyWindow || parent.childWindows?.contains(where: {
                $0 is ReaderReadingSettingsPanel && $0.isKeyWindow
            }) == true
        }
        private var hidesNativeToolbar: Bool {
            guard let state else { return false }
            return state.hasDocument && !state.usesCustomChrome && state.toolbarDisplayMode == .hidden
        }

        func handleMouseMoved(_ event: NSEvent) {
            guard let parent, readerHasKeyFocus else { return }
            let point: NSPoint
            if let source = event.window {
                guard source === parent || source.parent === parent else { return }
                // Fullscreen chrome can receive moves in its child window.
                point = source === parent ? event.locationInWindow
                    : parent.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
            } else {
                // AppKit mouse-moved events without a window use screen coordinates.
                point = parent.convertPoint(fromScreen: event.locationInWindow)
            }
            pointerMoved(to: point)
            if isTitlebarDragPoint(point) { NSCursor.arrow.set() }
        }

        func updateChrome() {
            updateChrome(revealingNativeControls: parent?.styleMask.contains(.fullScreen) == true && NSMenu.menuBarVisible())
        }

        func updateChrome(revealingNativeControls systemChrome: Bool) {
            guard let parent, let original, let state else { return }
            // SwiftUI can attach this host before AppKit installs native
            // window controls. Capture each control when it becomes available.
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton, .documentIconButton] {
                guard originalButtonAppearance[type] == nil else { continue }
                guard var button = parent.standardWindowButton(type) else { continue }
                if button.superview is ReaderFloatingWindowButtons.Buttons {
                    // A new tab can mount the floating factory before this
                    // host. AppKit then returns that factory from its standard
                    // lookup while the real controls remain in the titlebar.
                    // Both controls carry the same action supplied by AppKit;
                    // native titlebar buttons need not expose an AX subrole.
                    guard let action = button.action, let content = parent.contentView else { continue }
                    func nativeButton(in view: NSView) -> NSButton? {
                        if view === content { return nil }
                        if let button = view as? NSButton, button.action == action { return button }
                        return view.subviews.lazy.compactMap { nativeButton(in: $0) }.first
                    }
                    guard let native = content.superview.flatMap({ nativeButton(in: $0) }) else { continue }
                    button = native
                }
                originalButtonAppearance[type] = (button, button.isHidden, button.alphaValue)
            }
            if observedDocumentID != state.document?.id {
                observedDocumentID = state.document?.id
                // Opening or replacing a book need not produce a key-window
                // notification or a mouse move. Sample after SwiftUI commits
                // the new reading controls, outside its view update.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let parent = self.parent, parent.isKeyWindow else { return }
                    self.pointerMoved(to: parent.mouseLocationOutsideOfEventStream)
                }
            }
            // Fullscreen's toolbar companion moves below the revealed menu.
            // Reserve that native menu height throughout fullscreen so revealing
            // either surface cannot cover or move the reading content.
            let menuHeight = parent.styleMask.contains(.fullScreen) && !state.usesCustomChrome ? NSApp.mainMenu?.menuBarHeight ?? 0 : 0
            if reservedMenuHeight != menuHeight {
                reservedMenuHeight = menuHeight
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.fullscreenMenuInset?.wrappedValue = self.reservedMenuHeight
                }
            }
            // Fullscreen native tabs share their companion chrome. Only the
            // selected document may write that surface's current appearance.
            if let selected = parent.tabGroup?.selectedWindow, selected !== parent { return }
            if !state.toolbarHoverVisible {
                hoverDismiss?.cancel(); hoverDismiss = nil
            }
            if observedToolbar !== parent.toolbar {
                toolbarObservation?.invalidate()
                toolbarObservation = nil; visibilityFrame = nil
                observedToolbar = parent.toolbar
                if let toolbar = parent.toolbar {
                    toolbarObservation = toolbar.observe(\.isVisible, options: [.prior]) { [weak self] toolbar, change in
                        MainActor.assumeIsolated {
                            guard let self, let parent = self.parent else { return }
                            if change.isPrior { self.visibilityFrame = parent.frame }
                            else if let frame = self.visibilityFrame {
                                self.visibilityFrame = nil
                                if parent.frame != frame { parent.setFrame(frame, display: false) }
                            }
                            if !change.isPrior, self.hidesNativeToolbar, toolbar.isVisible { toolbar.isVisible = false }
                        }
                    }
                }
            }
            // Temporary hover controls overlay the book. Its viewport must not
            // reflow every time the pointer enters or leaves the toolbar.
            let hidden = state.toolbarOverlaysContent || state.usesCustomChrome
            let readerHidden = state.usesCustomChrome || (state.hasDocument && !state.toolbarShown)
            let readerOpacity: CGFloat = readerHidden ? 0 : hidden ? state.toolbarHoverOpacity : 1
            let frame = parent.frame
            let permanentlyHidden = hidesNativeToolbar
            if let saved = permanentlyHiddenToolbar, !permanentlyHidden || saved.toolbar !== parent.toolbar {
                permanentlyHiddenToolbar = nil
                saved.toolbar.isVisible = saved.visible
            }
            if permanentlyHidden, let toolbar = parent.toolbar {
                if permanentlyHiddenToolbar == nil { permanentlyHiddenToolbar = (toolbar, toolbar.isVisible) }
                if toolbar.isVisible { toolbar.isVisible = false }
            }
            // Preserve the frame around native visibility and titlebar changes.
            let fullSize = hidden || original.fullSize
            if parent.styleMask.contains(.fullSizeContentView) != fullSize {
                if fullSize { parent.styleMask.insert(.fullSizeContentView) }
                else { parent.styleMask.remove(.fullSizeContentView) }
            }
            let transparent = hidden || original.transparent
            let separator: NSTitlebarSeparatorStyle = hidden ? .none : original.separator
            let background = state.hasDocument ? ReaderTheme.color(state.palette.background) : original.background
            if parent.titlebarAppearsTransparent != transparent { parent.titlebarAppearsTransparent = transparent }
            if parent.titlebarSeparatorStyle != separator { parent.titlebarSeparatorStyle = separator }
            if parent.backgroundColor != background { parent.backgroundColor = background }
            // AppKit owns native fullscreen button opacity and document-icon
            // visibility. Restoring their windowed values paints them over
            // the title before the system reveals its menu.
            let nativeFullscreen = parent.styleMask.contains(.fullScreen)
            for (type, appearance) in originalButtonAppearance {
                if nativeFullscreen, type == .documentIconButton { continue }
                let hideButton = appearance.hidden || (!state.usesCustomChrome && readerHidden && !systemChrome && !state.toolbarHoverVisible)
                // Fullscreen can change standardWindowButton to the mounted
                // factory buttons. Native appearance belongs to the exact
                // controls captured here, never to that later lookup result.
                let button = appearance.button
                if button.isHidden != hideButton { button.isHidden = hideButton }
                if !nativeFullscreen, button.alphaValue != appearance.alpha { button.alphaValue = appearance.alpha }
            }
            // Older systems lack SwiftUI's title-item removal policy. Their
            // unified title reserves space from the visible native buttons.
            if #unavailable(macOS 15) {
                let title: NSWindow.TitleVisibility = readerHidden ? .hidden : .visible
                if parent.titleVisibility != title { parent.titleVisibility = title }
            }
            // Native menu reveal restores traffic lights and their companion,
            // while the reader tools and tabs retain their own visibility.
            let revealWindowButtons = !state.usesCustomChrome && (systemChrome || (state.toolbarDisplayMode == .hidden && state.toolbarHoverVisible))
            updateToolbarWindow(opacity: revealWindowButtons ? 1 : readerOpacity)
            updateTitlebarViews(opacity: readerOpacity, hidden: readerHidden,
                                opacityOwner: revealWindowButtons ? nil : toolbarContent)
            updateDragCursor()
            if parent.frame != frame { parent.setFrame(frame, display: false) }
            if !state.usesCustomChrome, let content = parent.contentView {
                let height = max(content.safeAreaInsets.top, content.bounds.maxY - content.convert(parent.contentLayoutRect, from: nil).maxY)
                if reservedNativeHeight != height {
                    reservedNativeHeight = height
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.nativeTopClearance?.wrappedValue = self.reservedNativeHeight
                    }
                }
            }
        }

        private func updateTitlebarViews(opacity: CGFloat, hidden readerHidden: Bool, opacityOwner: NSView?) {
            guard let parent, let state else { return }
            let accessories = parent.styleMask.contains(.titled) ? parent.titlebarAccessoryViewControllers.map(\.view) : []
            var views = accessories
            let readerContent = parent.contentView
            // A standard button's own alpha is part of AppKit's command
            // validation: alpha zero disables performClose and minimization.
            // Hide its native container instead, leaving the real controls
            // operational for menus and the floating factory buttons.
            // Fullscreen can register a factory button in the document as
            // standardWindowButton. Keep the discovered native owner through
            // that lookup change; content controls never belong to this owner.
            if let readerContent,
               let controls = originalButtonAppearance[.closeButton]?.button.superview,
               !(controls is ReaderFloatingWindowButtons.Buttons),
               !controls.isDescendant(of: readerContent) { nativeControlsContainer = controls }
            if state.usesCustomChrome, let nativeControlsContainer,
               !views.contains(where: { $0 === nativeControlsContainer }) { views.append(nativeControlsContainer) }
            func nativeToolbar(in view: NSView) -> NSView? {
                // Native window chrome lives outside the document's subtree.
                if view === readerContent { return nil }
                if view.accessibilityRole() == .toolbar { return view }
                return view.subviews.lazy.compactMap { nativeToolbar(in: $0) }.first
            }
            // Fade the native toolbar owner, including AppKit's overflow
            // control. Keep its installed layout and the native tab height.
            let toolbar = (toolbarContent ?? readerContent?.superview).flatMap { nativeToolbar(in: $0) }
            trackToolbarCursor(in: toolbar)
            if let toolbar { views.append(toolbar) }
            let removed = titlebarViews.filter { entry in !views.contains { $0 === entry.view } }
            for entry in removed where Self.chromeOwners.object(forKey: entry.view) === self {
                entry.view.alphaValue = entry.alpha
                entry.view.isHidden = entry.hidden
                entry.view.layer?.backgroundColor = entry.background
                entry.view.wantsLayer = entry.layered
                Self.chromeOwners.removeObject(forKey: entry.view)
            }
            titlebarViews.removeAll { entry in !views.contains { $0 === entry.view } }
            var added = false
            for view in views where Self.chromeOwners.object(forKey: view) !== self {
                let previous = Self.chromeOwners.object(forKey: view)?.titlebarViews.first { $0.view === view }
                    ?? titlebarViews.first { $0.view === view }
                    ?? (view, view.alphaValue, view.isHidden, view.wantsLayer, view.layer?.backgroundColor)
                titlebarViews.removeAll { $0.view === view }
                titlebarViews.append(previous)
                Self.chromeOwners.setObject(self, forKey: view)
                added = true
            }
            let background = ReaderTheme.color(state.palette.background).cgColor
            for entry in titlebarViews {
                // Native tab material must not expose text through the revealed
                // controls. Paint only the accessory's own public bounds.
                if accessories.contains(where: { $0 === entry.view }) {
                    if !entry.view.wantsLayer { entry.view.wantsLayer = true }
                    if entry.view.layer?.backgroundColor != background { entry.view.layer?.backgroundColor = background }
                }
                let fadesHere = opacityOwner.map { !entry.view.isDescendant(of: $0) } ?? true
                let hidden = entry.hidden || (fadesHere && readerHidden)
                if entry.view.isHidden != hidden { entry.view.isHidden = hidden }
            }
            if accessoryOpacity != opacity || accessoryContentOwner !== opacityOwner || added {
                let animate = accessoryOpacity != nil && !reducedMotion && !added && state.toolbarDisplayMode != .hidden
                accessoryOpacity = opacity
                accessoryContentOwner = opacityOwner
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = animate ? (opacity > 0 ? ReaderMotion.revealDuration : ReaderMotion.dismissDuration) : 0
                    context.timingFunction = opacity > 0 ? ReaderMotion.timingFunction : CAMediaTimingFunction(name: .easeOut)
                    for entry in titlebarViews {
                        let fadesHere = opacityOwner.map { !entry.view.isDescendant(of: $0) } ?? true
                        entry.view.animator().alphaValue = entry.alpha * (fadesHere ? opacity : 1)
                    }
                }
            }
        }

        private func updateToolbarWindow(opacity: CGFloat) {
            guard let parent else { return }
            // AppKit moves this native window control into its fullscreen
            // chrome, independently of the user's toolbar item customization.
            let button = parent.standardWindowButton(.closeButton)
            let factoryControl = button?.superview is ReaderFloatingWindowButtons.Buttons
            // The factory can become the standard lookup before AppKit creates
            // the fullscreen companion. Follow the original native container
            // into that window so its first appearance is hidden as well.
            let owner = factoryControl ? nativeControlsContainer?.window : button?.window
            // A tab created in fullscreen can mount its floating factory after
            // native controls have already left the document frame. Its native
            // accessory still identifies that tab's own fullscreen companion.
            let accessories = parent.styleMask.contains([.titled, .fullScreen])
                ? parent.titlebarAccessoryViewControllers.map { $0.view.window } : []
            let owners = [owner] + accessories
            let detached: NSWindow?
            if let owner = owners.compactMap({ $0 }).first(where: { $0 !== parent && !($0.delegate is ReaderCloseGuard) }) {
                detached = owner
            } else if state?.usesCustomChrome == true, parent.styleMask.contains(.fullScreen) {
                // Keep this host's identified companion while AppKit swaps
                // its standard-button lookup during the fullscreen transition.
                detached = toolbarWindow
            } else { detached = nil }
            let content = detached?.contentView
            let ownershipChanged = content.map { Self.chromeOwners.object(forKey: $0) !== self } ?? false
            if toolbarWindow !== detached || toolbarContent !== content || ownershipChanged {
                let previous = content.flatMap { Self.chromeOwners.object(forKey: $0)?.originalToolbarChrome }
                restoreToolbarWindow()
                toolbarWindow = detached; toolbarContent = content
                if let detached, let content {
                    originalToolbarChrome = previous ?? (content.alphaValue, detached.ignoresMouseEvents, detached.backgroundColor, detached.isOpaque, detached.hasShadow)
                    Self.chromeOwners.setObject(self, forKey: content)
                }
            }
            guard let toolbarWindow, let toolbarContent, let originalToolbarChrome else { return }
            // Hiding only the content leaves the companion's opaque window
            // backing visible during fullscreen transitions.
            let custom = state?.usesCustomChrome == true || state?.toolbarDisplayMode == .hidden
            toolbarWindow.backgroundColor = custom ? .clear : originalToolbarChrome.background
            toolbarWindow.isOpaque = custom ? false : originalToolbarChrome.opaque
            toolbarWindow.hasShadow = custom ? false : originalToolbarChrome.shadow
            let ignoresMouse = opacity == 0 || originalToolbarChrome.ignoresMouse
            if toolbarWindow.ignoresMouseEvents != ignoresMouse { toolbarWindow.ignoresMouseEvents = ignoresMouse }
            if toolbarOpacity != opacity {
                let animate = toolbarOpacity != nil && !reducedMotion && state?.toolbarDisplayMode != .hidden
                toolbarOpacity = opacity
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = animate ? (opacity > 0 ? ReaderMotion.revealDuration : ReaderMotion.dismissDuration) : 0
                    context.timingFunction = opacity > 0 ? ReaderMotion.timingFunction : CAMediaTimingFunction(name: .easeOut)
                    // AppKit's fullscreen companion owns the window alpha.
                    // Its content includes every native toolbar background.
                    toolbarContent.animator().alphaValue = opacity
                }
            }
        }

        private func restoreToolbarWindow() {
            if let toolbarWindow, let toolbarContent, let originalToolbarChrome,
               Self.chromeOwners.object(forKey: toolbarContent) === self {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    toolbarContent.animator().alphaValue = originalToolbarChrome.contentAlpha
                }
                toolbarWindow.ignoresMouseEvents = originalToolbarChrome.ignoresMouse
                toolbarWindow.backgroundColor = originalToolbarChrome.background
                toolbarWindow.isOpaque = originalToolbarChrome.opaque
                toolbarWindow.hasShadow = originalToolbarChrome.shadow
                Self.chromeOwners.removeObject(forKey: toolbarContent)
            }
            toolbarWindow = nil; toolbarContent = nil; originalToolbarChrome = nil; toolbarOpacity = nil
        }

        func pointerMoved(to point: NSPoint) {
            guard let parent, let state else { return }
            let tracksWindowButtons = state.toolbarDisplayMode == .hidden
            guard !state.presentation, state.hasDocument,
                  state.toolbarDisplayMode == .auto || tracksWindowButtons else {
                setHoverVisible(false, immediately: true)
                return
            }
            // Native tabs extend below the toolbar. Include their full measured
            // height when a tab closes under a stationary pointer, even after
            // the surviving reader resets its hover state on activation.
            let windowTop = parent.frame.height
            let entryDepth: CGFloat = state.usesFloatingChrome ? 76 : max(Self.hoverEntryDepth, reservedNativeHeight)
            let retentionDepth = max(Self.hoverRetentionDepth, entryDepth)
            let bottom = windowTop - (state.toolbarHoverVisible ? retentionDepth : entryDepth)
            var upper = windowTop
            if parent.styleMask.contains(.fullScreen), let screen = parent.screen {
                // Native fullscreen menu/titlebar controls can occupy the
                // screen strip above the document window's visible frame.
                upper = parent.convertPoint(fromScreen: NSPoint(x: parent.frame.midX, y: screen.frame.maxY)).y
            }
            let overChrome = point.x >= 0 && point.x <= parent.frame.width && point.y >= bottom && point.y <= upper
            let editing = state.toolbarHoverVisible && state.pageInputField?.currentEditor() != nil
            let shown = overChrome || editing || (menuTracking && state.toolbarHoverVisible)
            setHoverVisible(shown)
        }

        private func setHoverVisible(_ shown: Bool, immediately: Bool = false) {
            guard let state else { return }
            if shown {
                hoverDismiss?.cancel(); hoverDismiss = nil
                if !state.toolbarHoverVisible { state.toolbarHoverVisible = true }
                if state.toolbarHoverOpacity != 1 {
                    withAnimation(reducedMotion || state.toolbarDisplayMode == .hidden ? nil : ReaderMotion.reveal) { state.toolbarHoverOpacity = 1 }
                }
            } else if immediately || reducedMotion || state.toolbarDisplayMode == .hidden {
                hoverDismiss?.cancel(); hoverDismiss = nil
                if state.toolbarHoverOpacity != 0 { state.toolbarHoverOpacity = 0 }
                if state.toolbarHoverVisible { state.toolbarHoverVisible = false }
            } else if state.toolbarHoverVisible, hoverDismiss == nil {
                // A brief exit grace keeps near-edge movement calm. Re-entry
                // cancels this task and reverses opacity from its current value.
                hoverDismiss = Task { [weak self, weak state] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(ReaderMotion.hoverDismissDelay * 1_000_000_000))
                        try Task.checkCancellation()
                        guard let self, let state else { return }
                        withAnimation(ReaderMotion.dismiss) { state.toolbarHoverOpacity = 0 }
                        try await Task.sleep(nanoseconds: UInt64(ReaderMotion.dismissDuration * 1_000_000_000))
                        try Task.checkCancellation()
                        state.toolbarHoverVisible = false
                        self.hoverDismiss = nil
                    } catch { /* Task.sleep throws when re-entry or teardown cancels dismissal. */ }
                }
            }
        }

        override func mouseExited(with event: NSEvent) {
            if let parent { pointerMoved(to: parent.convertPoint(fromScreen: NSEvent.mouseLocation)) }
        }
        @objc private func menuChanged(_ notification: Notification) {
            guard let parent, readerHasKeyFocus else { return }
            menuTracking = notification.name == NSMenu.didBeginTrackingNotification
            if menuTracking, state?.toolbarHoverVisible == true {
                setHoverVisible(true)
            } else if !menuTracking {
                pointerMoved(to: parent.mouseLocationOutsideOfEventStream)
            }
        }
        @objc private func windowChanged(_ notification: Notification) {
            if notification.name == NSWindow.didBecomeKeyNotification || notification.name == NSWindow.didResignKeyNotification {
                guard let changed = notification.object as? NSWindow,
                      changed === parent || (changed is ReaderReadingSettingsPanel && changed.parent === parent) else { return }
                if notification.name == NSWindow.didResignKeyNotification, changed === parent,
                   parent?.childWindows?.contains(where: { $0 is ReaderReadingSettingsPanel }) != true {
                    menuTracking = false
                    setHoverVisible(false, immediately: true); updateChrome()
                    return
                }
                if notification.name == NSWindow.didBecomeKeyNotification, changed === parent, let parent {
                    pointerMoved(to: parent.mouseLocationOutsideOfEventStream)
                    updateChrome()
                }
                // Opening a settings panel transfers key focus synchronously.
                // Sample after that transfer, keeping the controls under the
                // stationary pointer instead of hiding and immediately revealing.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let parent = self.parent else { return }
                    if self.readerHasKeyFocus { self.pointerMoved(to: parent.mouseLocationOutsideOfEventStream) }
                    else {
                        self.menuTracking = false
                        self.setHoverVisible(false, immediately: true)
                    }
                    self.updateChrome()
                }
                return
            }
            if notification.name == NSWindow.willCloseNotification { detach() }
            // SwiftUI may install its NSToolbar after this background view attaches.
            else if notification.name == NSWindow.didUpdateNotification || notification.name == NSWindow.didResizeNotification { updateChrome() }
            else {
                menuTracking = false
                setHoverVisible(false, immediately: true); updateChrome()
            }
        }

        func detach() {
            // Dismantling runs inside SwiftUI's view update. Cancel work here;
            // focus/window notifications own observable visibility changes.
            hoverDismiss?.cancel(); hoverDismiss = nil
            trackToolbarCursor(in: nil)
            menuTracking = false
            observedDocumentID = nil
            NotificationCenter.default.removeObserver(self)
            toolbarObservation?.invalidate(); toolbarObservation = nil
            observedToolbar = nil; visibilityFrame = nil
            restoreToolbarWindow()
            for entry in titlebarViews where Self.chromeOwners.object(forKey: entry.view) === self {
                entry.view.alphaValue = entry.alpha
                entry.view.isHidden = entry.hidden
                entry.view.layer?.backgroundColor = entry.background
                entry.view.wantsLayer = entry.layered
                Self.chromeOwners.removeObject(forKey: entry.view)
            }
            titlebarViews.removeAll(); nativeControlsContainer = nil
            accessoryOpacity = nil; accessoryContentOwner = nil
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let tracking { parent?.contentView?.removeTrackingArea(tracking) }; tracking = nil
            if let parent, let original {
                let frame = parent.frame
                if let saved = permanentlyHiddenToolbar {
                    permanentlyHiddenToolbar = nil
                    saved.toolbar.isVisible = saved.visible
                }
                if original.fullSize { parent.styleMask.insert(.fullSizeContentView) }
                else { parent.styleMask.remove(.fullSizeContentView) }
                parent.titlebarAppearsTransparent = original.transparent
                parent.titleVisibility = original.title
                parent.titlebarSeparatorStyle = original.separator
                parent.backgroundColor = original.background
                parent.acceptsMouseMovedEvents = original.mouseMoved
                let fullscreen = parent.styleMask.contains(.fullScreen)
                for (type, appearance) in originalButtonAppearance {
                    if !fullscreen || type != .documentIconButton { appearance.button.isHidden = appearance.hidden }
                    if !fullscreen { appearance.button.alphaValue = appearance.alpha }
                }
                if parent.frame != frame { parent.setFrame(frame, display: false) }
            }
            parent = nil; original = nil; originalButtonAppearance.removeAll()
        }
    }
}

// AppKit owns the actual toolbar field editor, including programmatic focus.
@MainActor struct ReaderPageInput: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    let finished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: state.pageLabel)
        field.alignment = .center; field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        state.pageInputField = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        state.pageInputField = field
        field.isEnabled = state.count > 0
        field.toolTip = state.positionLabel
        field.setAccessibilityLabel(L("Go to Page"))
        if let editor = field.currentEditor() as? NSTextView {
            // Focus alone must not freeze the page label; actual input owns its draft.
            guard !context.coordinator.hasDraft, !editor.hasMarkedText(), editor.string != state.pageLabel else { return }
            let selection = editor.selectedRange()
            let selectedAll = selection == NSRange(location: 0, length: (editor.string as NSString).length)
            field.stringValue = state.pageLabel
            editor.string = state.pageLabel
            let length = (editor.string as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(selectedAll ? NSRange(location: 0, length: length)
                : NSRange(location: location, length: min(selection.length, length - location)))
        } else { field.stringValue = state.pageLabel }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.abortEditing()
        if coordinator.parent.state.pageInputField === field { coordinator.parent.state.pageInputField = nil }
        field.delegate = nil
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReaderPageInput
        var hasDraft = false
        init(_ parent: ReaderPageInput) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { hasDraft = false }
        func controlTextDidChange(_ notification: Notification) { hasDraft = true }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.state.go(textView.string) }
            else if selector != #selector(NSResponder.cancelOperation(_:)) { return false }
            parent.finished()
            return true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            hasDraft = false
            (notification.object as? NSTextField)?.stringValue = parent.state.pageLabel
        }
    }
}

/// A toolbar entry refers to an existing command owner. It introduces no new
/// executable command syntax. Like Sumatra, an SVG takes precedence over text.
struct ReaderToolbarButton: Codable, Equatable {
    var command: String?
    var external: String?
    var custom: String?
    var text: String?
    var symbol: String?
    var svg: String?

    @MainActor static func read(_ json: String) throws -> [Self] {
        let entries = try JSONDecoder().decode([Self].self, from: Data(json.utf8))
        guard entries.count <= 127 else { throw ReadError("The toolbar supports up to 127 custom buttons") }
        for entry in entries {
            guard [entry.command, entry.external, entry.custom].compactMap({ $0 }).count == 1 else { throw ReadError("Each toolbar button needs exactly one command, external or custom reference") }
            if let command = entry.command, ReaderMenuCommand(rawValue: command) == nil { throw ReadError("Unknown toolbar command: \(command)") }
            if let external = entry.external, external.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ReadError("External toolbar commands need a name") }
            if let custom = entry.custom, custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ReadError("Custom toolbar commands need a name") }
            if let symbol = entry.symbol, !symbol.isEmpty, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
                throw ReadError("Unknown system symbol: \(symbol)")
            }
        }
        return entries
    }
}

@MainActor struct ReaderToolbarButtons: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    let open: () -> Void
    @AppStorage("toolbarButtons") private var configuration = "[]"
    @AppStorage("externalCommands") private var externalCommands = "[]"
    @AppStorage("customCommands") private var customCommands = "[]"

    var body: some View {
        let _ = language
        let external = (try? ExternalReaderCommand.read(externalCommands)) ?? []
        let custom = (try? ReaderConfiguredCommand.read(customCommands)) ?? []
        if let entries = try? ReaderToolbarButton.read(configuration) {
            HStack(spacing: 10) {
                if entries.isEmpty { Text(L("Custom Buttons")).foregroundStyle(.secondary) }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    let command = entry.command.flatMap(ReaderMenuCommand.init(rawValue:))
                    let externalCommand = external.first { $0.name == entry.external }
                    let customCommand = custom.first { $0.name == entry.custom }
                    let label = entry.text.flatMap { $0.isEmpty ? nil : $0 } ?? command?.title ?? entry.external ?? entry.custom ?? ""
                    Button {
                        if let command { if command == .open { open() } else { command.run(state) } }
                        else if let externalCommand { externalCommand.run(state) }
                        else { customCommand?.run(state) }
                    } label: {
                        if let svg = entry.svg, !svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ReaderToolbarSVG(source: svg)
                        } else if let symbol = entry.symbol, !symbol.isEmpty { Image(systemName: symbol) }
                        else { Text(label) }
                    }
                    .disabled(!(command?.enabled(state) ?? externalCommand?.enabled(state) ?? customCommand?.enabled(state) ?? false))
                    .foregroundStyle(command?.checked(state) == true ? Color.accentColor : Color.primary)
                    .help(label)
                    .accessibilityLabel(label)
                    .accessibilityValue(command?.checked(state) == true ? L("On") : "")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Custom Buttons"))
        } else {
            Image(systemName: "exclamationmark.triangle").help(L("Invalid toolbar configuration. Open Settings → Toolbar."))
        }
    }
}

@MainActor private struct ReaderToolbarSVG: View {
    let source: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var error = ""
    private var content: String { source.replacingOccurrences(of: "currentColor", with: scheme == .dark ? "#ffffff" : "#000000") }
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: scale).resizable().frame(width: 20, height: 20) }
            else { Image(systemName: "exclamationmark.triangle").help(error) }
        }
        .task(id: content + "\(scale)") {
            let content = content, size = max(1, Int((20 * scale).rounded(.up)))
            image = nil; error = ""
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ReaderToolbarSVGRenderer.render(content, size: size) }.value
                guard !Task.isCancelled else { return }; image = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

enum ReaderToolbarSVGRenderer {
    private typealias Render = @convention(c) (UnsafePointer<UInt8>, Int, Int32, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
    private static let renderer: Result<Render, Error> = Result {
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard let library = dlopen(url.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load MuPDF for SVG icons: \(dlerror().map { String(cString: $0) } ?? "unknown loader error")")
        }
        guard let symbol = dlsym(library, "lf_svg_icon") else { dlclose(library); throw ReadError("The MuPDF engine does not support toolbar SVG icons") }
        // This process-wide function pointer keeps its one library handle alive.
        return unsafeBitCast(symbol, to: Render.self)
    }

    static func render(_ source: String, size: Int = 40) throws -> CGImage {
        guard (1...256).contains(size), !source.isEmpty else { throw ReadError("Invalid SVG icon dimensions") }
        let render = try renderer.get(), bytes = Array(source.utf8)
        var error = [CChar](repeating: 0, count: 512)
        guard let pointer = render(bytes, bytes.count, Int32(size), &error) else {
            throw ReadError(error.first == 0 ? "Cannot render SVG icon" : String(cString: error))
        }
        let data = Data(bytesNoCopy: pointer, count: size * size * 4, deallocator: .free)
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ReadError("Cannot create SVG icon image") }
        return image
    }
}

@MainActor struct ReaderToolbarSettings: View {
    @AppStorage("language") private var language = "system"
    @AppStorage("toolbarButtons") private var configuration = "[]"
    @AppStorage("externalCommands") private var externalCommands = "[]"
    @AppStorage("customCommands") private var customCommands = "[]"
    @State private var draft = ""
    @State private var error = ""
    @State private var saving = false
    @State private var advanced = false
    @State private var query = ""

    var body: some View {
        let _ = language
        VStack(alignment: .leading) {
            ReaderToolbarDisplayPicker()
            ReaderProgressDisplayPicker()
            ReaderImmersiveControlsToggle()
            Text(L("In Auto Hide mode, move the pointer to the top of the window to reveal the toolbar.")).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(L("Custom Toolbar Buttons")).font(.headline)
            Text(L("Add commands, choose their icons and arrange them below. Drag the Custom Buttons group in Customize Toolbar to move or hide it.")).font(.caption).foregroundStyle(.secondary)
            TextField(L("Find a command to add"), text: $query)
            Menu(L("Add Command")) {
                ForEach(ReaderMenuCommand.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }) { command in Button(command.title) { add(.init(command: command.rawValue)) } }
                if let custom = try? ReaderConfiguredCommand.read(customCommands), !custom.isEmpty {
                    Divider()
                    ForEach(custom) { command in Button(command.name) { add(.init(custom: command.name)) } }
                }
                if let external = try? ExternalReaderCommand.read(externalCommands), !external.isEmpty {
                    Divider()
                    ForEach(external) { command in Button(command.name) { add(.init(external: command.name)) } }
                }
            }
            Toggle(L("Edit advanced JSON"), isOn: $advanced)
            if advanced {
                TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(minHeight: 200)
                Text("[{\"command\":\"print\",\"symbol\":\"printer\"},{\"external\":\"Preview\",\"text\":\"Preview\"}]").font(.caption).textSelection(.enabled)
            } else if let entries = try? ReaderToolbarButton.read(draft) {
                List(Array(entries.enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.command.flatMap(ReaderMenuCommand.init(rawValue:))?.title ?? entry.external ?? entry.custom ?? "")
                            Spacer()
                            Button { edit { $0.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).help(L("Move Up"))
                            Button { edit { $0.swapAt(index, index + 1) } } label: { Image(systemName: "arrow.down") }
                                .disabled(index == entries.count - 1).help(L("Move Down"))
                            Button { edit { $0.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                                .help(L("Remove"))
                        }
                        HStack {
                            TextField(L("Button label (optional)"), text: Binding(
                                get: { entry.text ?? "" },
                                set: { value in edit { $0[index].text = value.isEmpty ? nil : value } }))
                            Menu {
                                Button(L("Text label")) { edit { $0[index].symbol = nil; $0[index].svg = nil } }
                                ForEach(Self.symbols, id: \.self) { symbol in
                                    Button { edit { $0[index].symbol = symbol; $0[index].svg = nil } } label: { Label(symbol, systemImage: symbol) }
                                }
                            } label: {
                                if let symbol = entry.symbol, !symbol.isEmpty { Label(L("Icon"), systemImage: symbol) }
                                else { Text(L(entry.svg?.isEmpty == false ? "SVG icon" : "Choose Icon")) }
                            }.frame(width: 135)
                        }
                    }.padding(.vertical, 3)
                }
                .buttonStyle(.borderless)
                if entries.isEmpty { Text(L("No extra buttons. Choose Add Command to begin.")).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(L("The toolbar JSON could not be read. Open the advanced editor to correct it.")).font(.caption).foregroundStyle(.red)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            Button(L("Save")) { save() }.disabled(saving)
        }.padding().onAppear { draft = configuration }
    }

    private static let symbols = ["doc", "folder", "printer", "magnifyingglass", "bookmark", "book", "list.bullet", "textformat", "sun.max", "moon", "arrow.left", "arrow.right", "arrow.up", "arrow.down", "arrow.clockwise", "square.and.arrow.up", "speaker.wave.2", "highlighter", "pencil", "gearshape"]

    private func add(_ button: ReaderToolbarButton) { edit { $0.append(button) } }

    private func edit(_ action: (inout [ReaderToolbarButton]) -> Void) {
        do {
            var entries = try ReaderToolbarButton.read(draft)
            action(&entries)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            draft = String(decoding: try encoder.encode(entries), as: UTF8.self); error = ""
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            let entries = try ReaderToolbarButton.read(draft), external = try ExternalReaderCommand.read(externalCommands), custom = try ReaderConfiguredCommand.read(customCommands)
            for entry in entries {
                if let name = entry.external, !external.contains(where: { $0.name == name }) { throw ReadError("Unknown external command: \(name)") }
                if let name = entry.custom, !custom.contains(where: { $0.name == name }) { throw ReadError("Unknown custom command: \(name)") }
            }
            let value = draft, icons = entries.compactMap(\.svg).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            saving = true
            Task {
                defer { saving = false }
                do {
                    try await Task.detached { for svg in icons { _ = try ReaderToolbarSVGRenderer.render(svg.replacingOccurrences(of: "currentColor", with: "#000000")) } }.value
                    configuration = value; error = ""
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
#endif
