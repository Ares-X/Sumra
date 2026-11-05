#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns wheel input for the horizontal tab viewport. The hosted SwiftUI
/// buttons retain selection, close, context-menu and accessibility behavior.
struct ReaderTabScrollView<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    let selectedRange: CGRect
    let selectionRevision: Int
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ scroll: Host, context: Context) {
        scroll.host.rootView = AnyView(content
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.layoutDirection, context.environment.layoutDirection))
        if scroll.contentWidth != contentWidth || scroll.selectedRange != selectedRange || scroll.selectionRevision != selectionRevision {
            scroll.revealSelection = true
        }
        scroll.contentWidth = contentWidth
        scroll.selectedRange = selectedRange
        scroll.selectionRevision = selectionRevision
        scroll.needsLayout = true
    }

    final class Host: NSScrollView {
        let host = ContentHost(rootView: AnyView(EmptyView()))
        var contentWidth: CGFloat = 0
        var selectedRange = CGRect.zero
        var selectionRevision = 0
        var revealSelection = true
        private var viewportSize = CGSize.zero

        init() {
            super.init(frame: .zero)
            drawsBackground = false
            contentView.drawsBackground = false
            borderType = .noBorder
            horizontalScrollElasticity = .none
            verticalScrollElasticity = .none
            automaticallyAdjustsContentInsets = false
            host.sizingOptions = []
            documentView = host
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            let viewport = contentView.bounds.size
            host.setFrameSize(CGSize(width: contentWidth, height: viewport.height))
            if viewportSize != viewport { revealSelection = true; viewportSize = viewport }
            if revealSelection, viewport.width > 0 {
                revealSelection = false
                host.scrollToVisible(selectedRange)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            // Horizontal gestures and their momentum keep their native delta;
            // an ordinary vertical wheel follows the same horizontal viewport.
            let axisDelta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            let delta = axisDelta * (event.hasPreciseScrollingDeltas ? 1 : 28)
            var bounds = contentView.bounds
            bounds.origin.x -= delta
            contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
            reflectScrolledClipView(contentView)
        }
    }

    final class ContentHost: NSHostingView<AnyView> {
        // This is window chrome, already positioned by ReaderFloatingLayout.
        // Inheriting the window titlebar's safe area would move these controls
        // out of their 28-point viewport. NSView owns this inset on macOS 13+.
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    }
}
#endif
