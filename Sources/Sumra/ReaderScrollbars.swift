#if os(macOS)
import AppKit
import SwiftUI

@MainActor
enum ReaderScrollbars {
    private static func scrollerStyle(_ mode: String) -> NSScroller.Style {
        mode == "hidden" ? .overlay : mode == "shown" ? .legacy : NSScroller.preferredScrollerStyle
    }

    static func initialReadingViewport(in frame: CGSize, mode: String, continuous: Bool = true) -> CGSize {
        // Reserve the vertical bar before laying out a scrolling book. Waiting
        // for its tall canvas to reveal a legacy bar would reflow it twice.
        NSScrollView.contentSize(forFrameSize: frame,
            horizontalScrollerClass: mode == "shown" ? NSScroller.self : nil,
            verticalScrollerClass: mode == "shown" || continuous && mode != "hidden" ? NSScroller.self : nil,
            borderType: .noBorder, controlSize: .regular, scrollerStyle: scrollerStyle(mode))
    }

    static func clearControls(in scroll: NSScrollView, above top: CGFloat, below bottom: CGFloat) {
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if !NSEdgeInsetsEqual(scroll.scrollerInsets, insets) { scroll.scrollerInsets = insets }
    }

    /// The system owns scrolling, dragging and overlay timing. These settings
    /// affect the document's scroll view only, including when bars are hidden.
    static func apply(to scroll: NSScrollView?, mode: String, horizontal: Bool = true, vertical: Bool = true, autohide: Bool? = nil) {
        guard let scroll else { return }
        let hidden = mode == "hidden", shown = mode == "shown"
        let horizontal = horizontal && !hidden, vertical = vertical && !hidden
        let style = scrollerStyle(mode)
        // Scroller-style changes retile the scroll view; set visibility last.
        let autohide = autohide ?? !shown
        if scroll.autohidesScrollers != autohide { scroll.autohidesScrollers = autohide }
        if scroll.scrollerStyle != style { scroll.scrollerStyle = style }
        if scroll.hasHorizontalScroller != horizontal { scroll.hasHorizontalScroller = horizontal }
        if scroll.hasVerticalScroller != vertical { scroll.hasVerticalScroller = vertical }
    }
}

/// Shorten the native scrollbar tracks where reading controls can appear.
/// The document and clip view keep their full reading area beneath the chrome.
@MainActor struct ReaderScrollbarClearance: NSViewRepresentable {
    let state: ReaderState
    let top: CGFloat
    let bottom: CGFloat

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.state = state; view.top = top; view.bottom = bottom
        view.updateScrollbars()
        // The document representable may mount its scroll view after this
        // background has updated in the same SwiftUI transaction.
        DispatchQueue.main.async { [weak view] in view?.updateScrollbars() }
    }

    final class Host: NSView {
        weak var state: ReaderState?
        var top: CGFloat = 0, bottom: CGFloat = 0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); updateScrollbars() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateScrollbars() }

        func updateScrollbars() {
            guard let scroll = state?.readerScrollView, scroll.window === window, window != nil else { return }
            let frame = convert(scroll.bounds, from: scroll)
            ReaderScrollbars.clearControls(in: scroll,
                above: max(0, bounds.minY + top - frame.minY),
                below: max(0, frame.maxY - (bounds.maxY - bottom)))
        }
    }
}
#endif
