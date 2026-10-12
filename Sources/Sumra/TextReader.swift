#if os(macOS)
import SwiftUI
import SumraCore

@MainActor struct TextReader: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    static func isAtEnd(in view: NSView?) -> Bool {
        guard let reader = (view as? MarginTextView)?.reader else { return false }
        return reader.isAtEnd(reader.facingView ?? reader.view)
    }
    static func canGoBackward(in view: NSView?) -> Bool? {
        guard let view = view as? MarginTextView, let reader = view.reader, reader.indexed,
              let clip = view.enclosingScrollView?.contentView, clip.bounds.height > 0 else { return nil }
        return reader.hasPreviousViewport()
    }
    func makeNSView(context: Context) -> TextReaderHost {
        let content = text
        let host = TextReaderHost()
        let scroll = TextPageScrollView()
        let view = MarginTextView(usingTextLayoutManager: true)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view; scroll.hasVerticalScroller = true
        let c = context.coordinator
        host.reader = c; host.addSubview(scroll); c.host = host
        host.leading = scroll
        view.isEditable = false
        view.isSelectable = true
        view.usesFindBar = true
        view.delegate = c
        c.view = view
        view.reader = c
        if let viewport = view.textLayoutManager?.textViewportLayoutController, let delegate = viewport.delegate {
            let observer = TextViewportObserver(delegate: delegate) { [weak c] in c?.viewportDidLayout() }
            c.viewportObserver = observer
            viewport.delegate = observer
        }
        view.textLayoutManager?.renderingAttributesValidator = { [weak c] manager, fragment in
            c?.applyHighlights(manager, in: fragment.rangeInElement)
        }
        state.selectionScreenBounds = { [weak c] in
            guard let c, c.isCurrent, let view = c.selectionView, let window = view.window,
                  let box = c.selectionBounds() else { return nil }
            return window.convertToScreen(view.convert(box, to: nil))
        }
        state.readerScrollView = scroll
        state.readerFocusView = view
        // Configure insertion attributes while storage is empty.
        c.style()
        view.string = content
        let scan = Task.detached(priority: .utility) { () -> ([Int], [DetectedChapter]) in
            ChapterDetector.index(content)
        }
        c.scanTask = scan
        Task { @MainActor in
            guard c.isCurrent else { return }
            state.outlineBusy = true
            let result = await scan.value
            guard c.isCurrent, !scan.isCancelled, !result.0.isEmpty else { return }
            c.lines = result.0
            c.indexed = true
            state.count = result.0.count
            state.page = min(state.page, result.0.count - 1)
            c.restore(c.pendingPosition ?? c.initialPosition)
            state.outline = result.1.map {
                .init(title: $0.title, target: String($0.line), depth: $0.depth, page: $0.line)
            }
            state.outlineBusy = false
        }
        return host
    }
    func updateNSView(_ host: TextReaderHost, context: Context) {
        let c = context.coordinator
        guard c.isCurrent else { return }
        ReaderScrollbars.apply(to: host.leading, mode: state.scrollbarMode, horizontal: false)
        ReaderScrollbars.apply(to: host.trailing, mode: state.scrollbarMode, horizontal: false, vertical: false)
        c.style()
        guard c.command != state.command.revision else { return }
        c.command = state.command.revision
        let revision = state.command.revision
        var acknowledge = true
        defer { if acknowledge { state.didHandleCommand(revision) } }
        switch state.command.action {
        case .page(let page):
            acknowledge = false; c.restore(.init(page: page)) { state.didHandleCommand(revision) }
        case .href(let target):
            acknowledge = false; c.go(target) { state.didHandleCommand(revision) }
        case .restore(let position):
            acknowledge = false; c.restore(position) { state.didHandleCommand(revision) }
        case .style, .zoom, .fit:
            acknowledge = false; c.completeStyle { state.didHandleCommand(revision) }
        case .find(let query, let backwards, let options, let fromSelection, _):
            DispatchQueue.main.async { [weak c] in c?.find(query, backwards: backwards, options: options ?? .init(), fromSelection: fromSelection) }
        case .toc:
            DispatchQueue.main.async { [weak c] in c?.find("") }
        case .turnPages(let count, _): c.turn(count)
        case .scroll(let direction, let amount, let count): c.scroll(direction, amount: amount, count: count)
        case .print:
            if let view = c.view {
                _ = NSPrintOperation(view: view, printInfo: state.printInfo).run()
            }
        case .copy: c.selectionView?.copy(nil)
        case .selectAll: c.selectionView?.selectAll(nil)
        case .selectCurrentPage:
            if let range = c.visibleRange() { c.view?.setSelectedRange(range) }
        case .speechHighlight(let location, let length): c.highlightSpeech(NSRange(location: location, length: length))
        case .readAloud, .readAloudFromTop, .readAloudFromCursor, .readAloudSelection:
            if let v = c.selectionView {
                let string = v.string as NSString, selection = v.selectedRange()
                let action = state.command.action
                if action == .readAloudSelection, selection.length == 0 { state.status = L("Select text to read aloud"); break }
                let selected = action == .readAloudSelection || action == .readAloud && selection.length > 0
                let cursor = action == .readAloudFromCursor || action == .readAloud && state.keyboardTextSelection
                let start = selected || cursor ? selection.location : c.visibleRange()?.location ?? 0
                let range = selected ? selection : NSRange(location: start, length: string.length-start)
                state.readText(string.substring(with: range), startOffset: start)
            }
        case .exportPDF:
            acknowledge = false
            c.exportPDF { state.didHandleCommand(revision) }
        default: break
        }
    }
    static func dismantleNSView(_ v: TextReaderHost, coordinator: Coordinator) {
        if coordinator.state.readerScrollView === v.leading { coordinator.state.readerScrollView = nil }
        if coordinator.state.readerFocusView === coordinator.view { coordinator.state.readerFocusView = nil }
        coordinator.active = false
        coordinator.scanTask?.cancel()
        coordinator.cancelFind()
        coordinator.cancelRestoration()
        if let viewport = coordinator.view?.textLayoutManager?.textViewportLayoutController,
           viewport.delegate === coordinator.viewportObserver {
            viewport.delegate = coordinator.viewportObserver?.original
        }
        coordinator.viewportObserver = nil
        if let manager = coordinator.secondary?.textLayoutManager {
            manager.textViewportLayoutController.delegate = coordinator.secondaryObserver?.original
            coordinator.view?.textContentStorage?.removeTextLayoutManager(manager)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let state: ReaderState
        let documentID: UUID?
        let initialPosition: ReadingPosition
        weak var view: NSTextView?
        fileprivate weak var host: TextReaderHost?
        fileprivate weak var secondary: NSTextView?
        private weak var selectedView: NSTextView?
        fileprivate var secondaryObserver: TextViewportObserver?
        private var updatingFacing = false
        private var wheelTurned = false
        private var previousTurns: [Int: ReadingPosition] = [:]
        var facingView: NSTextView? { state.spread && !state.presentation && secondary?.isHidden == false ? secondary : nil }
        var selectionView: NSTextView? { selectedView ?? view }
        fileprivate var viewportObserver: TextViewportObserver?
        var active = true, indexed = false, lines = [0], command: Int?, styleKey = ""
        var scanTask: Task<([Int], [DetectedChapter]), Never>?
        var query = ""
        var searchOptions = TextSearchOptions()
        var searchTask: Task<Void, Never>?
        private var searchGeneration = 0
        var results: [NSRange] = []
        private(set) var hit = -1
        private var restoring = false
        private var positionReport: (ReadingPosition, Int)?
        private var speechRange: NSRange?
        private var restoreCompletion: (() -> Void)?
        var pendingPosition: ReadingPosition?
        init(_ s: ReaderState) {
            state = s
            documentID = s.document?.id
            initialPosition = s.currentPosition
        }
        var isCurrent: Bool { active && state.document?.id == documentID }
        func positionBeforeResize() -> ReadingPosition? {
            guard isCurrent, indexed, !restoring else { return nil }
            return pendingPosition ?? visiblePosition() ?? positionReport?.0 ?? state.currentPosition
        }
        func textRange(_ range: NSRange) -> NSTextRange? {
            guard let content = view?.textContentStorage, let storage = content.textStorage,
                  range.location >= 0, range.length >= 0, range.location <= storage.length,
                  range.length <= storage.length - range.location,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }
        func selectionBounds() -> CGRect? {
            guard let view = selectionView, let manager = view.textLayoutManager, view.selectedRange().length > 0,
                  let range = textRange(view.selectedRange()) else { return nil }
            var box = CGRect.null
            manager.enumerateTextSegments(in: range, type: .selection, options: .rangeNotRequired) { _, rect, _, _ in
                box = box.union(rect); return true
            }
            return box.isNull ? nil : box.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        }
        func visibleRange() -> NSRange? {
            let lines = visibleLines() + (facingView.map { visibleLines(in: $0) } ?? [])
            guard let first = lines.first, let last = lines.last else { return nil }
            return NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        }
        func highlightSpeech(_ range: NSRange) {
            guard let view, let manager = view.textLayoutManager else { return }
            let old = speechRange.flatMap { textRange($0) }
            let current = range.length > 0 ? textRange(range) : nil
            speechRange = current == nil ? nil : range
            if let old { applyHighlights(manager, in: old) }
            if let current { applyHighlights(manager, in: current) }
            view.needsDisplay = true
            if let secondary, let manager = secondary.textLayoutManager {
                if let old { applyHighlights(manager, in: old) }
                if let current { applyHighlights(manager, in: current) }
                secondary.needsDisplay = true
            }
            if state.speechFollow, current != nil { view.scrollRangeToVisible(range) }
        }
        func applyHighlights(_ manager: NSTextLayoutManager, in range: NSTextRange) {
            guard let content = view?.textContentStorage else { return }
            manager.removeRenderingAttribute(.backgroundColor, for: range)
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            // Only inspect matches intersecting the changed or rendered range.
            var lo = 0, hi = results.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(results[mid]) <= start { lo = mid + 1 } else { hi = mid }
            }
            for index in lo..<results.count {
                guard results[index].location < end else { break }
                if let range = textRange(results[index])?.intersection(range) {
                    let color = index == hit ? NSColor.systemOrange.withAlphaComponent(0.5) : NSColor.systemYellow.withAlphaComponent(0.35)
                    manager.addRenderingAttribute(.backgroundColor, value: color, for: range)
                }
            }
            if let speechRange, let range = textRange(speechRange)?.intersection(range) {
                manager.addRenderingAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.5), for: range)
            }
        }
        func style() {
            guard let v = view, let storage = v.textContentStorage?.textStorage else { return }
            let key =
                "\(state.font)|\(state.fontSize)|\(state.lineHeight)|\(state.margin)|\(state.pageMargins?.css ?? "")|\(state.theme)|\(state.resolvedTheme)|\(state.palette.text)|\(state.palette.background)|\(state.zoom)|\(state.flow)|\(state.spread)|\(state.rtl)|\(state.presentation)"
            if key == styleKey { return }
            styleKey = key
            let size = state.fontSize * state.zoom
            let base = NSFont.systemFont(ofSize: size)
            let font: NSFont
            switch state.font {
            case "monospace": font = .monospacedSystemFont(ofSize: size, weight: .regular)
            case "serif":
                font =
                    base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
                    ?? base
            case "system", "sans-serif": font = base
            default: font = NSFont(name: state.font, size: size) ?? base
            }
            let inset: NSSize, padding: CGFloat
            if let margins = state.pageMargins {
                inset = NSSize(width: (margins.left + margins.right)/2, height: (margins.top + margins.bottom)/2)
                padding = 0
            } else {
                inset = NSSize(width: state.margin, height: max(16, state.margin / 2))
                padding = 5
            }
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = state.lineHeight
            // The displayed first character may use a CJK fallback font.
            // Typing attributes retain the requested font, including in read-only text.
            let fontChanged = (v.typingAttributes[.font] as? NSFont) != font
            let paragraphChanged = v.defaultParagraphStyle != p
            let foreground = ReaderTheme.color(state.palette.text)
            let foregroundChanged = v.textColor != foreground
            let marginsChanged = (v as? MarginTextView)?.pageMargins != state.pageMargins
            let layoutChanged = fontChanged || paragraphChanged || marginsChanged
                || v.textContainerInset != inset || v.textContainer?.lineFragmentPadding != padding
            let layoutModeChanged = host?.showsFacing != (state.spread && !state.presentation)
            if layoutChanged || layoutModeChanged { previousTurns.removeAll() }
            // TextKit invalidates viewport estimates when stored foreground attributes change, too.
            let position = indexed && (layoutChanged || layoutModeChanged || foregroundChanged) ? pendingPosition ?? state.currentPosition : nil
            if state.spread && !state.presentation { makeFacingView() }
            if layoutModeChanged || host?.reversesPages != state.rtl {
                if selectedView === secondary, let secondary { v.setSelectedRange(secondary.selectedRange()); selectedView = v }
                restoring = true
                host?.showsFacing = state.spread && !state.presentation
                host?.reversesPages = state.rtl
                host?.needsLayout = true; host?.layoutSubtreeIfNeeded()
                restoring = false
            }
            if fontChanged || paragraphChanged || foregroundChanged {
                // Consolidate attribute fixing and layout notification for this style update.
                storage.beginEditing()
                if fontChanged { v.font = font }
                if paragraphChanged {
                    v.defaultParagraphStyle = p
                    v.typingAttributes[.paragraphStyle] = p
                    storage.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: storage.length))
                }
                if foregroundChanged { v.textColor = foreground }
                storage.endEditing()
            }
            if marginsChanged { (v as? MarginTextView)?.pageMargins = state.pageMargins }
            if v.textContainerInset != inset { v.textContainerInset = inset }
            if v.textContainer?.lineFragmentPadding != padding { v.textContainer?.lineFragmentPadding = padding }
            let background = ReaderTheme.color(state.palette.background)
            if v.backgroundColor != background { v.backgroundColor = background }
            host?.paperColor = background
            v.enclosingScrollView?.backgroundColor = background
            if let secondary {
                secondary.typingAttributes = v.typingAttributes
                secondary.defaultParagraphStyle = p
                secondary.textContainerInset = inset
                secondary.textContainer?.lineFragmentPadding = padding
                (secondary as? MarginTextView)?.pageMargins = state.pageMargins
                secondary.backgroundColor = background
                secondary.enclosingScrollView?.backgroundColor = background
            }
            for scroll in [host?.leading, host?.trailing].compactMap({ $0 as? TextPageScrollView }) where scroll.pageHeight != nil {
                scroll.pageHeight = nil; scroll.tile()
            }
            if let position { restore(position) }
            else { updateFacingPage() }
        }
        private func makeFacingView() {
            guard secondary == nil, let host, let content = view?.textContentStorage else { return }
            let manager = NSTextLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            manager.textContainer = container
            content.addTextLayoutManager(manager)
            let second = MarginTextView(frame: .zero, textContainer: container)
            second.isEditable = false; second.isSelectable = true; second.usesFindBar = true
            second.isVerticallyResizable = true; second.isHorizontallyResizable = false
            second.autoresizingMask = [.width]
            second.minSize = .zero
            second.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
            second.delegate = self; second.reader = self; secondary = second
            let scroll = TextPageScrollView(); scroll.documentView = second
            host.trailing = scroll; host.addSubview(scroll)
            if let delegate = manager.textViewportLayoutController.delegate {
                let observer = TextViewportObserver(delegate: delegate) { [weak self] in self?.scrolled() }
                secondaryObserver = observer; manager.textViewportLayoutController.delegate = observer
            }
            manager.renderingAttributesValidator = { [weak self] manager, fragment in
                self?.applyHighlights(manager, in: fragment.rangeInElement)
            }
        }
        private func nextPageCharacter(in view: NSTextView) -> Int? {
            visibleLines(in: view).last.map { NSMaxRange($0.range) }
        }
        fileprivate func hasPreviousViewport() -> Bool {
            guard let view, let first = visibleLines().first else { return false }
            return first.range.location > 0 || view.visibleRect.minY > first.rect.minY + view.textContainerOrigin.y + 0.5
        }
        fileprivate func viewportSizeChanged() { previousTurns.removeAll() }
        private func previousPageCharacter(before character: Int) -> Int {
            guard let view, let manager = view.textLayoutManager,
                  let start = textRange(NSRange(location: max(0, character - 1), length: 0))?.location,
                  let current = line(at: character),
                  let scroll = view.enclosingScrollView as? TextPageScrollView else { return 0 }
            let height = scroll.availableHeight - 2 * view.textContainerInset.height
            var first = character
            manager.enumerateTextLayoutFragments(from: start, options: [.reverse, .ensuresLayout]) { fragment in
                for line in self.lineRecords(fragment).reversed() where line.range.location < character {
                    if current.rect.minY - line.rect.minY > height + 0.5 { return false }
                    first = line.range.location
                }
                return first > 0
            }
            return first
        }
        fileprivate func isAtEnd(_ view: NSTextView?) -> Bool {
            guard let view else { return false }
            if state.flow == "paged" || state.spread,
               let length = view.textContentStorage?.textStorage?.length,
               let last = visibleLines(in: view).last {
                return NSMaxRange(last.range) == length
            }
            return ReaderScroll.isAtTextEnd(view)
        }
        private func fitPageViewport(_ view: NSTextView) {
            guard state.flow == "paged" || state.spread,
                  let scroll = view.enclosingScrollView as? TextPageScrollView,
                  scroll.availableHeight > 0 else { return }
            let origin = view.textContainerOrigin.y
            let top = view.visibleRect.minY - origin
            let bottom = top + scroll.availableHeight - view.textContainerInset.height
            guard let last = visibleLines(in: view).last(where: { $0.rect.maxY <= bottom + 0.5 }) else { return }
            let height = last.rect.maxY - top
            guard height > 0, abs(height - scroll.contentView.bounds.height) > 0.5 else { return }
            scroll.pageHeight = height
            scroll.tile()
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        private func updateFacingPage() {
            guard !updatingFacing, !restoring, host?.resizing != true, let view else { return }
            updatingFacing = true
            defer { updatingFacing = false }
            fitPageViewport(view)
            guard state.spread, !state.presentation, let second = secondary,
                  let clip = second.enclosingScrollView?.contentView, clip.bounds.width > 0, clip.bounds.height > 0,
                  let character = nextPageCharacter(in: view) else { return }
            second.isHidden = isAtEnd(view)
            guard !second.isHidden else { return }
            (second.enclosingScrollView as? TextPageScrollView)?.pageHeight = nil
            second.enclosingScrollView?.tile()
            scrollToCharacter(character, in: second)
            fitPageViewport(second)
        }
        private func scrollToCharacter(_ character: Int, in view: NSTextView) {
            guard let manager = view.textLayoutManager, let storage = view.textContentStorage?.textStorage,
                  let range = textRange(NSRange(location: character, length: 0)),
                  let clip = view.enclosingScrollView?.contentView else { return }
            let wasUpdating = updatingFacing; updatingFacing = true
            defer { updatingFacing = wasUpdating }
            if let scroll = view.enclosingScrollView as? TextPageScrollView, scroll.pageHeight != nil {
                scroll.pageHeight = nil; scroll.tile()
            }
            manager.ensureLayout(for: range)
            view.scrollRangeToVisible(NSRange(location: character, length: character < storage.length ? 1 : 0))
            manager.textViewportLayoutController.layoutViewport()
            if let line = line(at: character, in: view) {
                let proposed = NSRect(origin: NSPoint(x: 0, y: max(0, line.rect.minY + view.textContainerOrigin.y)), size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
                view.enclosingScrollView?.reflectScrolledClipView(clip)
                manager.textViewportLayoutController.layoutViewport()
            }
            fitPageViewport(view)
        }
        func turn(_ count: Int) {
            guard indexed, let view else { return }
            cancelRestoration()
            for _ in 0..<abs(count) {
                if count > 0 {
                    let before = visiblePosition()
                    let last = facingView ?? view
                    guard !isAtEnd(last), let character = nextPageCharacter(in: last),
                          character > (visibleLines().first?.range.location ?? -1) else { break }
                    scrollToCharacter(character, in: view)
                    view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                    updateFacingPage()
                    if let before, let after = visiblePosition(), let anchor = Int(after.anchor ?? "") {
                        previousTurns[anchor] = before
                    }
                } else {
                    guard hasPreviousViewport(), let current = visiblePosition(), let anchor = Int(current.anchor ?? "") else { break }
                    if let previous = previousTurns[anchor] { restore(previous) }
                    else {
                        var character = visibleLines().first?.range.location ?? 0
                        for _ in 0..<(state.spread && !state.presentation ? 2 : 1) {
                            character = previousPageCharacter(before: character)
                        }
                        scrollToCharacter(character, in: view)
                    }
                }
                view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                updateFacingPage()
            }
            scrolled()
        }
        func scroll(_ direction: ReaderScrollDirection, amount: ReaderScrollAmount, count: Int) {
            let horizontal = direction == .left || direction == .right
            if horizontal {
                let forward = (direction == .right) != state.rtl
                turn(forward ? count : -count)
            } else if state.flow == "paged", amount == .page {
                turn(direction == .down ? count : -count)
            } else {
                _ = ReaderScroll.perform(in: view?.enclosingScrollView, direction: direction, amount: amount, count: count)
                view?.textLayoutManager?.textViewportLayoutController.layoutViewport()
                updateFacingPage()
            }
        }
        func scrollWheel(_ event: NSEvent) -> Bool {
            guard state.flow == "paged" else { return false }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) ||
                (event.phase.isEmpty && event.momentumPhase.isEmpty) { wheelTurned = false }
            if !event.momentumPhase.isEmpty || wheelTurned { return true }
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return true }
            let forward = horizontal ? (delta < 0) != state.rtl : delta < 0
            turn(forward ? 1 : -1)
            wheelTurned = !event.phase.isEmpty
            return true
        }
        func completeStyle(_ completion: @escaping () -> Void) {
            if pendingPosition != nil { restoreCompletion = completion }
            else { completion() }
        }
        func cancelRestoration() {
            pendingPosition = nil
            restoreCompletion = nil
            positionReport = nil
        }
        func go(_ target: String, completion: (() -> Void)? = nil) {
            if let line = Int(target) { restore(.init(page: line), completion: completion); return }
            defer { completion?() }
            let parts = target.split(separator: ":")
            guard parts.count == 3, parts[0] == "text", let start = Int(parts[1]), let length = Int(parts[2]),
                  let v = view, start >= 0, length >= 0, start <= v.string.utf16.count,
                  length <= v.string.utf16.count - start else { return }
            let range = NSRange(location: start, length: length)
            if let index = results.firstIndex(of: range) { select(index) }
        }

        // Like Sumatra's ScrollState, store a document coordinate, not a viewport pixel.
        // For text the UTF-16 character anchor survives font and window reflow.
        func restore(_ position: ReadingPosition, completion: (() -> Void)? = nil) {
            if let completion { restoreCompletion = completion }
            pendingPosition = position
            guard indexed else { return }
            guard isCurrent, let v = view, let storage = v.textContentStorage?.textStorage else {
                let done = restoreCompletion; restoreCompletion = nil; pendingPosition = nil; done?(); return
            }
            let line = max(0, min(position.page, lines.count - 1))
            let character = max(0, min(Int(position.anchor ?? "") ?? lines[line], storage.length))
            pendingPosition?.anchor = String(character)
            restoring = true
            if let scroll = v.enclosingScrollView as? TextPageScrollView, scroll.pageHeight != nil {
                scroll.pageHeight = nil; scroll.tile()
            }
            v.layoutSubtreeIfNeeded()
            if let manager = v.textLayoutManager,
               let range = textRange(NSRange(location: character, length: 0)),
               let clip = v.enclosingScrollView?.contentView {
                let viewport = manager.textViewportLayoutController
                manager.ensureLayout(for: range)
                v.scrollRangeToVisible(NSRange(location: character, length: character < storage.length ? 1 : 0))
                viewport.layoutViewport()
                if let line = self.line(at: character) {
                    let offset = position.y.flatMap { $0.isFinite ? $0 : nil } ?? 0
                    let x = position.x.flatMap { $0.isFinite ? $0 : nil } ?? 0
                    let proposed = NSRect(origin: NSPoint(x: x, y: max(0, line.rect.minY + v.textContainerOrigin.y + offset)), size: clip.bounds.size)
                    clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
                    v.enclosingScrollView?.reflectScrolledClipView(clip)
                    viewport.layoutViewport()
                }
            }
            restoring = false
            viewportDidLayout()
        }

        func viewportDidLayout() {
            guard isCurrent, indexed, !restoring else { return }
            if let position = pendingPosition {
                guard let v = view, let manager = v.textLayoutManager, let content = v.textContentStorage,
                      let storage = content.textStorage, let character = Int(position.anchor ?? ""),
                      let target = textRange(NSRange(location: character, length: 0)) else { return }
                if storage.length > 0 {
                    guard let viewport = manager.textViewportLayoutController.viewportRange,
                          viewport.contains(target.location)
                            || character == storage.length && viewport.endLocation.compare(target.location) == .orderedSame else { return }
                }
                pendingPosition = nil
                let done = restoreCompletion; restoreCompletion = nil
                scrolled()
                done?()
            } else { scrolled() }
            updateFacingPage()
        }

        private func lineRecords(_ fragment: NSTextLayoutFragment) -> [(range: NSRange, rect: CGRect)] {
            guard fragment.state == .layoutAvailable, let content = view?.textContentStorage else { return [] }
            let origin = fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location
            let start = content.offset(from: content.documentRange.location, to: origin)
            return fragment.textLineFragments.map {
                let range = NSRange(location: start + $0.characterRange.location, length: $0.characterRange.length)
                return (range, $0.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY))
            }
        }

        private func visibleLines(in target: NSTextView? = nil) -> [(range: NSRange, rect: CGRect)] {
            guard let view = target ?? view, let manager = view.textLayoutManager,
                  let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
            let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
            var result: [(range: NSRange, rect: CGRect)] = []
            manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedDescending else { return false }
                result += self.lineRecords(fragment).filter { $0.rect.maxY > visible.minY + 0.5 && $0.rect.minY < visible.maxY - 0.5 }
                return fragment.layoutFragmentFrame.maxY < visible.maxY
            }
            return result
        }

        private func line(at character: Int, in target: NSTextView? = nil) -> (range: NSRange, rect: CGRect)? {
            let view = target ?? view
            let end = view?.textContentStorage?.textStorage?.length
            let preceding = character == end ? max(0, character - 1) : character
            guard let manager = view?.textLayoutManager, let location = textRange(NSRange(location: preceding, length: 0))?.location else { return nil }
            var result: (range: NSRange, rect: CGRect)?
            manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
                let lines = self.lineRecords(fragment)
                result = lines.first { NSLocationInRange(character, $0.range) || $0.range.location == character && $0.range.length == 0 }
                if result == nil, character == view?.textContentStorage?.textStorage?.length {
                    result = lines.last { NSMaxRange($0.range) == character }
                }
                return false
            }
            return result
        }

        func cancelFind() {
            searchGeneration &+= 1; searchTask?.cancel(); searchTask = nil
            query = ""; results = []; hit = -1
            if let view, let manager = view.textLayoutManager, let range = view.textContentStorage?.documentRange {
                applyHighlights(manager, in: range)
                view.needsDisplay = true
                if let second = secondary, let manager = second.textLayoutManager {
                    applyHighlights(manager, in: range); second.needsDisplay = true
                }
            }
            if isCurrent { state.searchResults = []; state.status = "" }
        }
        func find(_ q: String, backwards: Bool = false, options: TextSearchOptions = .init(), fromSelection: Bool = false) {
            guard isCurrent, let v = view else { return }
            let selection = fromSelection ? (selectionView ?? v).selectedRange() : NSRange(location: visibleRange()?.location ?? 0, length: 0)
            if q == query, options == searchOptions, !results.isEmpty {
                if !fromSelection, results.indices.contains(hit) {
                    select((hit + (backwards ? -1 : 1) + results.count) % results.count)
                } else { select(backwards: backwards, after: selection) }
                return
            }
            cancelFind()
            guard !q.isEmpty else { return }
            query = q; searchOptions = options
            let content = v.string, generation = searchGeneration
            state.status = L("Searching…")
            searchTask = Task { [weak self] in
                let scan = Task.detached(priority: .userInitiated) {
                    let matches = try options.ranges(in: content, query: q)
                    let source = content as NSString
                    let items = try matches.map { range in
                        try Task.checkCancellation()
                        return ContentsItem(title: TextSearchOptions.snippet(in: source, range: range), target: "text:\(range.location):\(range.length)")
                    }
                    return (matches, items)
                }
                do {
                    let (matches, items) = try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
                    guard let self, self.isCurrent, !Task.isCancelled, self.searchGeneration == generation else { return }
                    self.searchTask = nil; self.results = matches
                    self.state.searchResults = items
                    if let range = self.view?.textContentStorage?.documentRange {
                        self.view?.textLayoutManager?.invalidateRenderingAttributes(for: range)
                        self.secondary?.textLayoutManager?.invalidateRenderingAttributes(for: range)
                    }
                    if let manager = self.view?.textLayoutManager, let viewport = manager.textViewportLayoutController.viewportRange {
                        self.applyHighlights(manager, in: viewport)
                    }
                    self.select(backwards: backwards, after: selection)
                } catch {
                    if let self, self.isCurrent, !Task.isCancelled, self.searchGeneration == generation { self.state.error = error.localizedDescription }
                }
            }
        }
        private func select(backwards: Bool, after selection: NSRange) {
            guard isCurrent, view != nil else { return }
            guard !results.isEmpty else {
                state.status = L("No matches")
                return
            }
            let index = backwards ?
                results.lastIndex(where: { $0.location < selection.location }) ?? results.count - 1 :
                results.firstIndex(where: { $0.location >= NSMaxRange(selection) }) ?? 0
            select(index)
        }
        private func select(_ index: Int) {
            guard isCurrent, let v = view, results.indices.contains(index) else { return }
            let old = results.indices.contains(hit) ? textRange(results[hit]) : nil
            hit = index
            if let manager = v.textLayoutManager {
                if let old { applyHighlights(manager, in: old) }
                if let range = textRange(results[index]) { applyHighlights(manager, in: range) }
            }
            if !indexed { pendingPosition = .init(anchor: String(results[index].location)) }
            v.scrollRangeToVisible(results[index])
            v.textLayoutManager?.textViewportLayoutController.layoutViewport()
            updateFacingPage()
            v.needsDisplay = true
            state.selectedSearchTarget = "text:\(results[index].location):\(results[index].length)"
            state.status = String(format: L("%d of %d matches"), index + 1, results.count)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            selectedView = notification.object as? NSTextView
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent, let v = self.selectionView else { return }
                self.state.selectedText = (v.string as NSString).substring(with: v.selectedRange())
                self.state.hasSelection = v.selectedRange().length > 0
            }
        }

        static func lineIndex(_ character: Int, offsets: [Int]) -> Int {
            var lo = 0
            var hi = offsets.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if offsets[mid] <= character { lo = mid + 1 } else { hi = mid }
            }
            return max(0, lo - 1)
        }

        private func visiblePosition() -> ReadingPosition? {
            guard let view, let line = visibleLines().first else { return nil }
            var character = line.range.location
            var y = Double(view.visibleRect.minY - line.rect.minY - view.textContainerOrigin.y)
            if ReaderScroll.isAtTextEnd(view), let clip = view.enclosingScrollView?.contentView,
               let end = view.textContentStorage?.textStorage?.length {
                var preceding = clip.bounds
                preceding.origin.y += view.isFlipped ? -1 : 1
                // A fitting book still begins at its first character. Preserve
                // an end preference only after scrolling past that beginning.
                if abs(clip.constrainBoundsRect(preceding).minY - clip.bounds.minY) > 0.5 {
                    character = end; y = 0
                }
            }
            return ReadingPosition(
                page: Self.lineIndex(line.range.location, offsets: lines), x: Double(view.visibleRect.minX),
                y: y, anchor: String(character))
        }

        func scrolled() {
            guard isCurrent, indexed, !restoring, !updatingFacing, host?.resizing != true, pendingPosition == nil,
                  let position = visiblePosition() else { return }
            let scheduled = positionReport != nil
            positionReport = (position, state.command.revision)
            guard !scheduled else { return }
            // Coalesce geometry notifications outside SwiftUI's view update.
            // A queued old position must not undo a newer navigation command.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let report = self.positionReport
                self.positionReport = nil
                guard self.isCurrent, let (position, revision) = report,
                      revision == self.state.command.revision else { return }
                self.state.updatePosition(position)
            }
        }

        func exportPDF(completion: @escaping () -> Void = {}) {
            guard isCurrent, let view else { completion(); return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (state.document?.url.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf"
            panel.begin { [weak self, weak view] response in
                defer { completion() }
                guard response == .OK, let self, self.isCurrent, let view, let url = panel.url,
                      let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
                guard self.state.document.map({ !PDFTools.sameFile(url, $0.url) }) == true else {
                    self.state.error = "Choose a different location for Export PDF."
                    return
                }
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                let operation = NSPrintOperation(view: view, printInfo: info)
                operation.showsPrintPanel = false
                operation.run()
            }
        }
    }
}

@MainActor final class TextReaderHost: NSView {
    weak var reader: TextReader.Coordinator?
    var leading: NSScrollView?
    var trailing: NSScrollView?
    var showsFacing = false
    var reversesPages = false
    private(set) var resizing = false
    private var resizePosition: (ReadingPosition, Int)?
    var paperColor = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { paperColor.setFill(); dirtyRect.fill() }
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        if let reader, let position = reader.positionBeforeResize() {
            resizePosition = (position, reader.state.command.revision)
        }
        resizing = true
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizing = false
        let position = resizePosition
        resizePosition = nil
        if let reader, let (position, revision) = position, revision == reader.state.command.revision {
            reader.restore(position)
        } else { reader?.viewportDidLayout() }
    }
    override func layout() {
        super.layout()
        let width = showsFacing ? bounds.width / 2 : bounds.width
        let reverse = showsFacing && reversesPages
        let sizeChanged = leading?.frame.size != NSSize(width: width, height: bounds.height)
        let position = sizeChanged && !resizing ? reader?.positionBeforeResize() : nil
        if sizeChanged {
            reader?.viewportSizeChanged()
            (leading as? TextPageScrollView)?.pageHeight = nil
            (trailing as? TextPageScrollView)?.pageHeight = nil
        }
        leading?.frame = NSRect(x: reverse ? width : 0, y: 0, width: width, height: bounds.height)
        leading?.tile()
        trailing?.isHidden = !showsFacing
        trailing?.frame = NSRect(x: reverse ? 0 : width, y: 0, width: leading?.contentView.frame.width ?? width, height: bounds.height)
        trailing?.tile()
        if let position { reader?.restore(position) }
    }
}

// Keep both native text containers equally wide. A paged viewport ends at a
// complete line; the remaining paper is ordinary scroll-view background.
@MainActor private final class TextPageScrollView: NSScrollView {
    var pageHeight: CGFloat?
    private(set) var availableHeight: CGFloat = 0
    override func tile() {
        super.tile()
        var frame = contentView.frame
        availableHeight = frame.height
        if let pageHeight {
            let height = min(pageHeight, frame.height)
            if !isFlipped { frame.origin.y += frame.height - height }
            frame.size.height = height
        }
        contentView.frame = frame
    }
}

// NSTextView owns layout and sizing; its inset supplies the total whitespace,
// while this origin places asymmetric whitespace on the requested sides.
private final class MarginTextView: NSTextView {
    weak var reader: TextReader.Coordinator?
    var pageMargins: PageMargins? { didSet { invalidateTextContainerOrigin(); needsDisplay = true } }
    override var textContainerOrigin: NSPoint {
        pageMargins.map { NSPoint(x: $0.left, y: $0.top) } ?? super.textContainerOrigin
    }
    override func keyDown(with event: NSEvent) {
        if let reader, !reader.state.keyboardTextSelection,
           event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
           event.keyCode == 123 || event.keyCode == 124 {
            reader.scroll(event.keyCode == 123 ? .left : .right, amount: .line, count: 1)
            return
        }
        super.keyDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        if reader?.scrollWheel(event) == true { return }
        if reader?.secondary === self { reader?.view?.enclosingScrollView?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

// Observe the public viewport protocol while keeping NSTextView's rendering,
// layout scheduling and optional delegate behavior with its original owner.
@MainActor fileprivate final class TextViewportObserver: NSObject, @preconcurrency NSTextViewportLayoutControllerDelegate {
    weak var original: NSTextViewportLayoutControllerDelegate?
    private let didLayout: () -> Void
    init(delegate: NSTextViewportLayoutControllerDelegate, didLayout: @escaping () -> Void) {
        original = delegate; self.didLayout = didLayout
    }
    func viewportBounds(for controller: NSTextViewportLayoutController) -> CGRect {
        original?.viewportBounds(for: controller) ?? .zero
    }
    func textViewportLayoutController(_ controller: NSTextViewportLayoutController, configureRenderingSurfaceFor fragment: NSTextLayoutFragment) {
        original?.textViewportLayoutController(controller, configureRenderingSurfaceFor: fragment)
    }
    func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        original?.textViewportLayoutControllerDidLayout?(controller)
        didLayout()
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
#endif
