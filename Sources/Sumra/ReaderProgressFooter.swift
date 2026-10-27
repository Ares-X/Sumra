#if os(macOS)
import SwiftUI
import SumraCore

/// Pixel scrolling updates the footer without rebuilding the reader surface.
@MainActor final class ReaderScrollProgress: ObservableObject {
    @Published private(set) var fraction: Double?
    func update(_ value: Double?) {
        if fraction != value { fraction = value }
    }
}

/// Counts keep their renderer's meaning: physical pages, source lines, or files.
struct ReaderProgress {
    enum Position {
        case pages(Int, Int), lines(Int, Int), file(Int, Int, Double?)
        case chapters(ChapterTable, PageLocation)
        indirect case continuous(Double?, Position)
    }
    let position: Position

    private func fraction(_ index: Int, _ count: Int) -> Double {
        count > 1 ? Double(index) / Double(count - 1) : 0
    }
    var value: Double {
        switch position {
        case .pages(let page, let count), .lines(let page, let count): return fraction(page, count)
        case .file(_, _, let progress): return progress ?? 0
        case .continuous(let progress, _): return progress ?? 0
        case .chapters(let table, let location):
            return (Double(location.chapter) + fraction(location.page, table.pageCount(location.chapter))) / Double(table.chapterCount)
        }
    }
    var step: Double {
        switch position {
        case .pages(_, let count), .lines(_, let count): return 1 / Double(max(1, count - 1))
        case .file, .continuous: return 0.01
        case .chapters(let table, _): return 1 / Double(table.chapterCount)
        }
    }
    var enabled: Bool {
        switch position {
        case .pages(_, let count), .lines(_, let count): return count > 1
        case .file(_, _, let progress): return progress != nil
        case .continuous(let progress, _): return progress != nil
        case .chapters(let table, _): return table.chapterCount > 1 || table.pageCount(0) > 1
        }
    }
    func label(at preview: Double? = nil) -> String {
        switch position {
        case .pages(let page, let count):
            guard count > 0 else { return "\(L("Page:")) — / —" }
            return "\(L("Page:")) \(preview.map { index($0, count) } ?? page + 1) / \(count)"
        case .lines(let line, let count):
            guard count > 0 else { return "\(L("Line:")) — / —" }
            return "\(L("Line:")) \(preview.map { index($0, count) } ?? line + 1) / \(count)"
        case .file(let file, let count, _): return "\(L("File:")) \(file + 1) / \(count)"
        case .continuous(_, let current): return ReaderProgress(position: current).label()
        case .chapters(let table, let current):
            let location = preview.map { chapterLocation($0, table) } ?? current
            let count = table.isLaidOut(location.chapter) ? String(table.pageCount(location.chapter)) : "—"
            let page = preview != nil && !table.isLaidOut(location.chapter) ? "—" : String(location.page + 1)
            return "\(L("Chapter:")) \(location.chapter + 1) / \(table.chapterCount) · \(L("Page:")) \(page) / \(count)"
        }
    }
    func percentage(at preview: Double? = nil) -> String {
        var displayed = preview ?? value
        if let preview {
            switch position {
            case .pages(_, let count), .lines(_, let count):
                displayed = fraction(index(preview, count) - 1, count)
            case .chapters(let table, _):
                let target = chapterLocation(preview, table)
                if table.isLaidOut(target.chapter) {
                    displayed = (Double(target.chapter) + fraction(target.page, table.pageCount(target.chapter))) / Double(table.chapterCount)
                }
            case .file, .continuous: break
            }
        }
        let percent = Int((displayed * 100).rounded())
        switch position {
        case .chapters, .continuous(.some(_), .chapters(_, _)): return "≈ \(percent)%"
        case .file(_, _, nil), .continuous(nil, _), .pages(_, 0), .lines(_, 0): return "—"
        default: return "\(percent)%"
        }
    }
    var help: String {
        switch position {
        case .chapters: return L("Approximate progress by chapter")
        case .file: return L("Progress in current file")
        default: return L("Reading Progress")
        }
    }
    private func index(_ value: Double, _ count: Int) -> Int { Int((value * Double(max(0, count - 1))).rounded()) + 1 }
    private func chapterLocation(_ value: Double, _ table: ChapterTable) -> PageLocation {
        let coordinate = value * Double(table.chapterCount)
        let chapter = min(Int(coordinate), table.chapterCount - 1)
        let local = coordinate - Double(chapter)
        return .init(chapter: chapter, page: Int((local * Double(table.pageCount(chapter) - 1)).rounded()))
    }
    func action(at value: Double) -> ReaderAction? {
        switch position {
        case .pages(let current, let count), .lines(let current, let count):
            let target = index(value, count) - 1
            return target == current ? nil : .page(target)
        case .file(_, _, let current): return current == value ? nil : .progress(value)
        case .continuous(let current, _): return current == value ? nil : .progress(value)
        case .chapters(let table, let current):
            let target = chapterLocation(value, table)
            return table.isLaidOut(target.chapter) && target == current ? nil : .progress(value)
        }
    }
}

extension ReaderState {
    var readingProgress: ReaderProgress {
        if isBrowser { return .init(position: .file(page, count, browserProgress)) }
        if isText { return .init(position: .lines(page, count)) }
        let position: ReaderProgress.Position
        if reflowable, let table = chapterLayout, !table.complete {
            let location = location.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? pageLocation(page)
            position = .chapters(table, location)
        } else { position = .pages(page, count) }
        return .init(position: continuousReflow ? .continuous(scrollProgress.fraction, position) : position)
    }
}

/// A drag belongs to the document where it began, even across a replacement.
struct ReaderProgressDrag {
    let document: UUID?
    var value: Double
    @MainActor func action(in state: ReaderState) -> ReaderAction? {
        guard document == state.document?.id else { return nil }
        return state.readingProgress.action(at: value)
    }
}

@MainActor
struct ReaderProgressFooter: View {
    static let height: CGFloat = 30
    @ObservedObject var state: ReaderState
    @ObservedObject private var scrollProgress: ReaderScrollProgress
    @State private var hovered = false
    @State private var focused = false
    @State private var drag: ReaderProgressDrag?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private var shown: Bool { hovered || focused || drag != nil }

    init(state: ReaderState) {
        self.state = state
        scrollProgress = state.scrollProgress
    }

    var body: some View {
        let progress = state.readingProgress
        HStack(spacing: 12) {
            Text(progress.percentage(at: drag?.value)).frame(width: 44, alignment: .trailing)
            ReaderProgressSlider(value: drag?.value ?? progress.value, step: progress.step, enabled: progress.enabled,
                accessibilityValue: progress.percentage(at: drag?.value) + ", " + progress.label(at: drag?.value),
                accessibilityHelp: progress.help,
                began: { drag = .init(document: state.document?.id, value: progress.value) },
                changed: { value in
                    if drag != nil { drag?.value = value }
                    else if let action = state.readingProgress.action(at: value) { state.navigate(action) }
                }, ended: {
                    if let action = drag?.action(in: state) { state.navigate(action) }
                    drag = nil
                }, focused: { focused = $0 })
                .frame(minWidth: 80, maxWidth: 320)
            Text(progress.label(at: drag?.value)).lineLimit(1)
                .frame(width: 200, alignment: .leading)
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(Color(nsColor: ReaderTheme.color(state.palette.text)).opacity(0.65))
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: shown)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct ReaderProgressSlider: NSViewRepresentable {
    let value: Double
    let step: Double
    let enabled: Bool
    let accessibilityValue: String
    let accessibilityHelp: String
    let began: () -> Void
    let changed: (Double) -> Void
    let ended: () -> Void
    let focused: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderProgressSliderControl {
        let slider = ReaderProgressSliderControl(value: value, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = slider; slider.action = #selector(ReaderProgressSliderControl.changedValue)
        slider.setAccessibilityLabel(L("Reading Progress"))
        return slider
    }
    func updateNSView(_ slider: ReaderProgressSliderControl, context: Context) {
        slider.began = began; slider.changed = changed; slider.ended = ended; slider.focused = focused
        if !slider.tracking { slider.doubleValue = value }
        slider.step = step
        slider.isEnabled = enabled
        slider.setAccessibilityValueDescription(accessibilityValue)
        slider.setAccessibilityHelp(accessibilityHelp)
    }
}

final class ReaderProgressSliderControl: NSSlider {
    var began: (() -> Void)?
    var changed: ((Double) -> Void)?
    var ended: (() -> Void)?
    var focused: ((Bool) -> Void)?
    var step = 0.01
    private(set) var tracking = false

    @objc func changedValue() { changed?(doubleValue) }
    private func adjust(_ distance: Double) {
        doubleValue = min(maxValue, max(minValue, doubleValue + distance))
        sendAction(action, to: target)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.keyCode {
        case 123, 125: adjust(-step)
        case 124, 126: adjust(step)
        case 115: doubleValue = minValue; sendAction(action, to: target)
        case 119: doubleValue = maxValue; sendAction(action, to: target)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        adjust(step); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        adjust(-step); return true
    }
    override func mouseDown(with event: NSEvent) {
        tracking = true; began?()
        super.mouseDown(with: event)
        tracking = false; ended?()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focused?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focused?(false) }
        return accepted
    }
}
#endif
