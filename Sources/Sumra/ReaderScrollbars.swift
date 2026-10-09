#if os(macOS)
import AppKit

@MainActor
enum ReaderScrollbars {
    /// The system owns scrolling, dragging and overlay timing. These settings
    /// affect the document's scroll view only, including when bars are hidden.
    static func apply(to scroll: NSScrollView?, mode: String, horizontal: Bool = true, vertical: Bool = true) {
        guard let scroll else { return }
        let hidden = mode == "hidden", shown = mode == "shown"
        let horizontal = horizontal && !hidden, vertical = vertical && !hidden
        let style: NSScroller.Style = hidden ? .overlay : shown ? .legacy : NSScroller.preferredScrollerStyle
        // Scroller-style changes retile the scroll view; set visibility last.
        if scroll.autohidesScrollers == shown { scroll.autohidesScrollers = !shown }
        if scroll.scrollerStyle != style { scroll.scrollerStyle = style }
        if scroll.hasHorizontalScroller != horizontal { scroll.hasHorizontalScroller = horizontal }
        if scroll.hasVerticalScroller != vertical { scroll.hasVerticalScroller = vertical }
    }
}
#endif
