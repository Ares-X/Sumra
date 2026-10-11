#if os(macOS)
import AppKit

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
#endif
