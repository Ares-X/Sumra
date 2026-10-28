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
    var spread = false
    var cover = false
    var landscape: Set<Int> = []

    private func row(_ page: Int, _ count: Int) -> Range<Int> {
        PageRows.range(page: page, count: count, spread: spread, cover: cover, landscape: landscape)
    }
    private func sameRow(_ page: Int, _ current: Int, _ count: Int) -> Bool {
        row(page, count) == row(current, count)
    }
    private func lastPageCoordinate(_ count: Int) -> Int {
        row(count - 1, count).lowerBound
    }

    private func fraction(_ index: Int, _ count: Int) -> Double {
        let last = lastPageCoordinate(count)
        return last > 0 ? Double(row(index, count).lowerBound) / Double(last) : (spread && count > 1 ? 1 : 0)
    }
    private func chapterEnd(_ table: ChapterTable) -> Double {
        if spread, table.isLaidOut(table.chapterCount - 1),
           let last = table.location(page: lastPageCoordinate(table.totalPages)) { return table.progress(for: last) }
        return 1
    }
    private func chapterFraction(_ table: ChapterTable, _ location: PageLocation) -> Double {
        if spread, let page = table.page(for: location),
           let leading = table.location(page: row(page, table.totalPages).lowerBound) {
            let end = chapterEnd(table)
            return end > 0 ? table.progress(for: leading) / end : 0
        }
        return table.progress(for: location)
    }
    private func chapterTarget(_ table: ChapterTable, _ value: Double) -> PageLocation {
        table.location(progress: value * chapterEnd(table))
    }
    private func pageStep(_ page: Int, _ count: Int, backwards: Bool) -> Double {
        let current = row(page, count)
        let adjacent = row(backwards ? current.lowerBound - 1 : current.upperBound, count)
        return Double(abs(adjacent.lowerBound - current.lowerBound)) / Double(max(1, lastPageCoordinate(count)))
    }
    var value: Double {
        switch position {
        case .pages(let page, let count), .lines(let page, let count): return fraction(page, count)
        case .file(let file, let count, let progress): return count > 1 ? Double(file) / Double(count - 1) : progress ?? 0
        case .continuous(let progress, _): return progress ?? 0
        case .chapters(let table, let location):
            return chapterFraction(table, location)
        }
    }
    var step: Double {
        switch position {
        case .pages(let page, let count), .lines(let page, let count): return pageStep(page, count, backwards: false)
        case .file(_, let count, _): return count > 1 ? 1 / Double(count - 1) : 0.01
        case .continuous: return 0.01
        case .chapters(let table, _): return 1 / Double(table.chapterCount)
        }
    }
    var backwardStep: Double {
        switch position {
        case .pages(let page, let count), .lines(let page, let count): return pageStep(page, count, backwards: true)
        default: return step
        }
    }
    var enabled: Bool {
        switch position {
        case .pages(_, let count), .lines(_, let count): return count > 1
        case .file(_, let count, let progress): return count > 1 || progress != nil
        case .continuous(let progress, _): return progress != nil
        case .chapters(let table, _): return table.chapterCount > 1 || table.pageCount(0) > 1
        }
    }
    func label(at preview: Double? = nil) -> String {
        switch position {
        case .pages(let page, let count):
            guard count > 0 else { return "\(L("Page:")) — / —" }
            let target = preview.map { index($0, count) - 1 } ?? page
            return "\(L("Page:")) \(sameRow(target, page, count) ? page + 1 : target + 1) / \(count)"
        case .lines(let line, let count):
            guard count > 0 else { return "\(L("Line:")) — / —" }
            return "\(L("Line:")) \(preview.map { index($0, count) } ?? line + 1) / \(count)"
        case .file(let file, let count, _):
            let target = count > 1 ? preview.map { Int(($0 * Double(count - 1)).rounded()) } ?? file : file
            return "\(L("File:")) \(target + 1) / \(count)"
        case .continuous(_, let current): return ReaderProgress(position: current).label()
        case .chapters(let table, let current):
            let location = preview.flatMap { action(at: $0) == nil ? nil : chapterTarget(table, $0) } ?? current
            let count = table.isLaidOut(location.chapter) ? String(table.pageCount(location.chapter)) : "—"
            let page = preview != nil && !table.isLaidOut(location.chapter) ? "—" : String(location.page + 1)
            return chapterLabel(location.chapter + 1, table.chapterCount, page, count)
        }
    }
    private func chapterLabel(_ chapter: Int, _ chapters: Int, _ page: String, _ count: String) -> String {
        "\(L("Chapter:")) \(chapter) / \(chapters) · \(L("Page:")) \(page) / \(count)"
    }
    @MainActor var labelWidth: CGFloat {
        func width(_ label: String) -> CGFloat {
            ceil((label as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width)
        }
        switch position {
        case .continuous(_, let current): return ReaderProgress(position: current).labelWidth
        case .chapters(let table, _):
            let pages = String((0..<table.chapterCount).map { table.pageCount($0) }.max() ?? 1)
            return max(width(chapterLabel(table.chapterCount, table.chapterCount, pages, pages)),
                       width(chapterLabel(table.chapterCount, table.chapterCount, "—", "—")))
        default: return width(label(at: 1))
        }
    }
    func percentage(at preview: Double? = nil) -> String {
        var displayed = preview ?? value
        if let preview {
            switch position {
            case .pages(_, let count), .lines(_, let count):
                displayed = fraction(index(preview, count) - 1, count)
            case .chapters(let table, _):
                let target = chapterTarget(table, preview)
                if table.isLaidOut(target.chapter) {
                    displayed = chapterFraction(table, target)
                }
            case .file(_, let count, _) where count > 1:
                displayed = (preview * Double(count - 1)).rounded() / Double(count - 1)
            case .file, .continuous: break
            }
        }
        let percent = Int((displayed * 100).rounded())
        switch position {
        case .chapters, .continuous(.some(_), .chapters(_, _)): return "≈ \(percent)%"
        case .file(_, let count, nil) where count <= 1: return "—"
        case .continuous(nil, _), .pages(_, 0), .lines(_, 0): return "—"
        default: return "\(percent)%"
        }
    }
    var help: String {
        switch position {
        case .chapters: return L("Approximate progress by chapter")
        case .file(_, let count, _) where count <= 1: return L("Progress in current file")
        default: return L("Reading Progress")
        }
    }
    private func index(_ value: Double, _ count: Int) -> Int {
        let page = Int((value * Double(max(0, lastPageCoordinate(count)))).rounded())
        return row(page, count).lowerBound + 1
    }
    func action(at value: Double, includingCurrent: Bool = false) -> ReaderAction? {
        switch position {
        case .pages(let current, let count), .lines(let current, let count):
            let target = index(value, count) - 1
            return !includingCurrent && sameRow(target, current, count) ? nil : .page(target)
        case .file(let current, let count, let progress):
            if count > 1 {
                let target = Int((value * Double(count - 1)).rounded())
                return !includingCurrent && current == target ? nil : .page(target)
            }
            return !includingCurrent && progress == value ? nil : .progress(value)
        case .continuous(let current, _): return !includingCurrent && current == value ? nil : .progress(value)
        case .chapters(let table, let current):
            let target = chapterTarget(table, value)
            if !includingCurrent, table.isLaidOut(target.chapter), let page = table.page(for: target), let currentPage = table.page(for: current),
               sameRow(page, currentPage, table.totalPages) { return nil }
            return .progress(value * chapterEnd(table))
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
        return .init(position: continuousReflow ? .continuous(scrollProgress.fraction, position) : position,
                     spread: spread && isFixed && flow != "continuous" && !presentation,
                     cover: cover, landscape: landscapeAsSpread ? landscapePages : [])
    }
}

/// A drag belongs to the document where it began, even across a replacement.
struct ReaderProgressDrag {
    let id = UUID()
    let document: UUID?
    var value: Double
    let presentation: ReaderProgress
    @MainActor func action(in state: ReaderState, includingCurrent: Bool = false) -> ReaderAction? {
        guard document == state.document?.id else { return nil }
        return state.readingProgress.action(at: value, includingCurrent: includingCurrent)
    }
}

@MainActor
struct ReaderProgressFooter: View {
    static let height: CGFloat = 26
    static let floatingBottomInset: CGFloat = 6
    @ObservedObject var state: ReaderState
    @ObservedObject private var scrollProgress: ReaderScrollProgress
    @State private var hovered = false
    @State private var focused = false
    @State private var drag: ReaderProgressDrag?
    @State private var seeking: ReaderProgressDrag?
    @State private var hoverDismiss: Task<Void, Never>?
    let floating: Bool
    @AppStorage("progressDisplayMode") private var mode = ReaderToolbarDisplayMode.auto
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private var shown: Bool { mode == .shown || (mode == .auto && (hovered || focused || drag != nil || seeking != nil)) }

    init(state: ReaderState, floating: Bool = false) {
        self.state = state
        self.floating = floating
        scrollProgress = state.scrollProgress
    }

    var body: some View {
        if mode != .hidden {
            controls.onDisappear { hoverDismiss?.cancel() }
        }
    }

    private func seek(_ preview: ReaderProgressDrag) {
        // A second seek may return to the still-displayed old page while the
        // first one is in flight. It must supersede that destination too.
        guard let action = preview.action(in: state, includingCurrent: seeking != nil) else { seeking = nil; return }
        seeking = preview
        state.navigate(action) {
            if seeking?.id == preview.id { seeking = nil }
        }
    }

    private var controls: some View {
        let progress = drag?.presentation ?? seeking?.presentation ?? state.readingProgress
        let preview = drag?.value ?? seeking?.value
        let labelWidth = max(floating ? 84 : 0, progress.labelWidth)
        return HStack(spacing: 12) {
            Text(progress.percentage(at: preview))
                .frame(minWidth: floating ? 42 : 0, maxWidth: floating ? 42 : 200,
                       alignment: floating ? .leading : .trailing)
            ReaderProgressSlider(value: preview ?? progress.value, step: progress.step, backwardStep: progress.backwardStep, enabled: progress.enabled,
                accessibilityValue: progress.percentage(at: preview) + ", " + progress.label(at: preview),
                accessibilityHelp: progress.help,
                began: {
                    drag = .init(document: state.document?.id, value: seeking?.value ?? state.readingProgress.value,
                                 presentation: seeking?.presentation ?? state.readingProgress)
                },
                changed: { value in
                    if drag != nil { drag?.value = value }
                    else { seek(.init(document: state.document?.id, value: value, presentation: progress)) }
                }, ended: {
                    if let drag { seek(drag) }
                    drag = nil
                }, focused: { focused = $0 })
                .frame(minWidth: floating ? 0 : 80, maxWidth: floating ? .infinity : 320)
            Text(progress.label(at: preview)).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: floating ? labelWidth : 0, maxWidth: floating ? labelWidth : max(200, labelWidth),
                       alignment: floating ? .trailing : .leading)
                .help(progress.label(at: preview))
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(Color(nsColor: ReaderTheme.color(state.palette.text)).opacity(0.65))
        .padding(.horizontal, floating ? 12 : 20)
        .frame(maxWidth: floating ? 472 + labelWidth - 84 : max(784, 584 + labelWidth))
        .frame(height: Self.height)
        .modifier(ReaderFloatingSurface(palette: state.palette, enabled: floating))
        .opacity(shown ? 1 : 0)
        .animation(reducedMotion ? nil : (shown ? ReaderMotion.reveal : ReaderMotion.dismiss), value: shown)
        .padding(.bottom, floating ? Self.floatingBottomInset : 0)
        .padding(.horizontal, floating ? 16 : 0)
        .frame(maxWidth: .infinity)
        .frame(height: floating ? 56 : Self.height, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { inside in
            hoverDismiss?.cancel(); hoverDismiss = nil
            if inside || reducedMotion { hovered = inside }
            else {
                hoverDismiss = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(ReaderMotion.hoverDismissDelay * 1_000_000_000))
                        hovered = false
                    } catch { /* Re-entry cancels the pending dismissal. */ }
                }
            }
        }
    }
}

struct ReaderProgressDisplayPicker: View {
    @AppStorage("progressDisplayMode") private var mode = ReaderToolbarDisplayMode.auto
    var body: some View {
        Picker(L("Progress Slider Display"), selection: $mode) {
            ForEach(ReaderToolbarDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

private struct ReaderProgressSlider: NSViewRepresentable {
    let value: Double
    let step: Double
    let backwardStep: Double
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
        slider.backwardStep = backwardStep
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
    var backwardStep = 0.01
    private(set) var tracking = false

    @objc func changedValue() { changed?(doubleValue) }
    private func adjust(_ distance: Double) {
        doubleValue = min(maxValue, max(minValue, doubleValue + distance))
        sendAction(action, to: target)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.keyCode {
        case 123, 125: adjust(-backwardStep)
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
        adjust(-backwardStep); return true
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
