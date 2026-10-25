#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

// Reader chrome moves; the document's layout and reading position do not.
enum ReaderMotion {
    static let revealDuration: TimeInterval = 0.18
    static let dismissDuration: TimeInterval = 0.12
    static let hoverDismissDelay: TimeInterval = 0.14
    static let reveal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: revealDuration)
    static let dismiss = Animation.easeOut(duration: dismissDuration)
    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    }
    static var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// Pane layout settles once; only its chrome fades into the finished geometry.
struct ReaderChromeEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var appeared = false
    func body(content: Content) -> some View {
        content
            .opacity(appeared || reducedMotion ? 1 : 0)
            .onAppear { withAnimation(reducedMotion ? nil : ReaderMotion.reveal) { appeared = true } }
            .transaction { if reducedMotion { $0.animation = nil } }
    }
}
#endif
