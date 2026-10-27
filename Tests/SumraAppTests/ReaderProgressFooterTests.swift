#if os(macOS)
import AppKit
import Combine
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderProgressFooterTests: XCTestCase {
    @MainActor
    func testNaturalContinuousFooterTracksScrollAndSeeksWithinAndAcrossChapters() async throws {
        _ = NSApplication.shared
        for chapterCount in [1, 20] {
            let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("continuous-progress.md")
            let paragraphs = (0..<300).map { "Paragraph \($0): Continuous progress follows the visible passage within this chapter.\n\n" }.joined()
            let content = (0..<chapterCount).map { (chapterCount > 1 ? "# Chapter \($0)\n\n" : "") + paragraphs }.joined(separator: "\n")
            try content.write(to: input, atomically: true, encoding: .utf8)
            let pages = try Pages(input, format: .markdown, deferReflowLayout: true), state = ReaderState(recordsHistory: false)
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 20, font: "serif", theme: "light",
                                         pageSize: CGSize(width: 700, height: 0))
            _ = try await pages.bounds(PageLocation(page: 0))
            state.document = ReadingDocument(url: input, content: .pages(pages))
            state.reflowable = true; state.searchable = true; state.flow = "continuous"; state.fit = "width"
            state.automaticLayout = false; state.spread = false; state.rotation = 0; state.zoom = 1
            state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 20
            state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
            state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
            state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
            state.applyChapterLayout(await pages.chapterLayout)
            let reader = NSHostingView(rootView: RasterReader(state: state, pages: pages))
            let footer = NSHostingView(rootView: ReaderProgressFooter(state: state))
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 430))
            reader.frame = CGRect(x: 0, y: 30, width: 700, height: 400)
            footer.frame = CGRect(x: 0, y: 0, width: 700, height: 30)
            container.addSubview(reader); container.addSubview(footer)
            let window = NSWindow(contentRect: container.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = container
            let defaults = UserDefaults.standard, previousFlow = defaults.object(forKey: "flow")
            defer {
                state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
                if let previousFlow { defaults.set(previousFlow, forKey: "flow") } else { defaults.removeObject(forKey: "flow") }
                withExtendedLifetime(directory) {}
            }
            func slider(in view: NSView) -> ReaderProgressSliderControl? {
                if let slider = view as? ReaderProgressSliderControl { return slider }
                return view.subviews.lazy.compactMap { slider(in: $0) }.first
            }
            func paint() {
                container.layoutSubtreeIfNeeded()
                if let bitmap = reader.bitmapImageRepForCachingDisplay(in: reader.bounds) { reader.cacheDisplay(in: reader.bounds, to: bitmap) }
            }
            func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    paint()
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline && state.error == nil
                XCTFail(state.error ?? "Continuous progress did not settle: \(state.location.scrollFraction as Any), footer=\(slider(in: footer)?.doubleValue as Any), reader=\(reader.frame), canvas=\(state.readerScrollView?.documentView?.bounds as Any), count=\(state.count), command=\(state.command.action)", line: line)
                throw CancellationError()
            }
            try await waitFor {
                state.location.scrollFraction != nil &&
                    (state.readerScrollView?.documentView?.bounds.height ?? 0) > 10_000
            }
            state.send(.none)
            try await waitFor { state.command.action == .none }
            let control = try XCTUnwrap(slider(in: footer)), scroll = try XCTUnwrap(state.readerScrollView)
            let initialTable = await pages.chapterLayout
            if chapterCount == 1 { XCTAssertEqual(state.count, 1) }
            else {
                XCTAssertGreaterThan(initialTable.chapterCount, 3)
                XCTAssertFalse(initialTable.complete)
                XCTAssertTrue(state.readingProgress.percentage().hasPrefix("≈"))
            }
            try await waitFor { control.isEnabled }
            let canvas = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(canvas.bounds.height, 10_000)
            func fraction() -> Double {
                Double((scroll.contentView.bounds.minY - canvas.bounds.minY) / (canvas.bounds.height - scroll.contentView.bounds.height))
            }
            var readerPublications = 0
            let observation = state.objectWillChange.sink { readerPublications += 1 }
            defer { observation.cancel() }
            for value in [0.25, 0.75] {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: canvas.bounds.minY + (canvas.bounds.height - scroll.contentView.bounds.height) * value))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await waitFor { abs(control.doubleValue - value) < 0.001 }
                XCTAssertEqual(state.readingProgress.value, fraction(), accuracy: 0.001)
            }
            if chapterCount == 1 {
                XCTAssertEqual(readerPublications, 0, "Within-chapter pixel scrolling must update only the footer's progress owner")
            }
            for value in [0.0, 0.5, 1.0] {
                let revision = state.command.revision
                control.began?(); control.changed?(value)
                paint()
                XCTAssertEqual(state.command.revision, revision, "Dragging previews without navigating")
                control.ended?()
                state.send(.none)
                try await waitFor { state.command.action == .none && abs(fraction() - value) < 0.001 && abs(control.doubleValue - value) < 0.001 }
            }
            let previous = fraction()
            XCTAssertTrue(control.accessibilityPerformDecrement())
            state.send(.none)
            try await waitFor { state.command.action == .none && fraction() < previous }
            for (keyCode, expected) in [(UInt16(115), 0.0), (UInt16(119), 1.0)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
                control.keyDown(with: event)
                state.send(.none)
                try await waitFor { state.command.action == .none && abs(fraction() - expected) < 0.001 }
            }
            var restored = state.currentPosition
            restored.scrollFraction = 0
            state.send(.preservePosition(restored)); state.send(.none)
            try await waitFor { state.command.action == .none && abs(fraction() - 1) < 0.001 }
            if chapterCount > 1 {
                let table = await pages.chapterLayout
                XCTAssertFalse(table.complete, "Continuous seeking must not paginate the entire book")
                XCTAssertFalse(table.isLaidOut(2), "A chapter outside the visited canvas regions remains lazy")
            }
            state.setFlow("paged"); state.send(.none)
            try await waitFor {
                !state.continuousReflow && (state.chapterLayout?.pageCount(state.pageLocation(state.page).chapter) ?? 0) > 1
            }
            if chapterCount == 1 {
                XCTAssertEqual(state.readingProgress.value, Double(state.page) / Double(state.count - 1), accuracy: 0.001)
                XCTAssertEqual(state.readingProgress.action(at: 0.5), .page(Int((Double(state.count - 1) * 0.5).rounded())))
            } else {
                XCTAssertTrue(state.readingProgress.percentage().hasPrefix("≈"), "Unresolved finite chapter counts keep their approximate semantics")
            }
            XCTAssertNil(state.error)
        }
    }

    func testFixedPageSeekUsesPhysicalIndexesAtBothEndsAndMiddle() {
        let progress = ReaderProgress(position: .pages(0, 11))
        XCTAssertEqual(progress.value, 0)
        XCTAssertNil(progress.action(at: 0), "Seeking the current page must not navigate again")
        XCTAssertEqual(progress.action(at: 0.5), .page(5))
        XCTAssertEqual(progress.action(at: 1), .page(10))
        XCTAssertEqual(ReaderProgress(position: .pages(10, 11)).percentage(), "100%")
        XCTAssertTrue(progress.label(at: 0.5).contains("6 / 11"))
    }

    func testSourceLinesAndBrowserFilesKeepTheirCountSemantics() {
        let lines = ReaderProgress(position: .lines(499, 1000))
        XCTAssertTrue(lines.label().contains("Line:"))
        XCTAssertEqual(lines.action(at: 1), .page(999))
        let file = ReaderProgress(position: .file(4, 20, 0.25))
        XCTAssertEqual(file.value, 0.25)
        XCTAssertTrue(file.label().contains("File:"))
        XCTAssertTrue(file.label().contains("5 / 20"))
        XCTAssertEqual(file.action(at: 0.75), .progress(0.75))
        XCTAssertFalse(ReaderProgress(position: .file(0, 2, nil)).enabled)
    }

    func testPartialChapterSeekDoesNotTreatPlaceholderPagesAsExactTotal() throws {
        var table = ChapterTable(chapters: 4)
        table.setPageCount(chapter: 0, count: 10)
        let progress = ReaderProgress(position: .chapters(table, .init(chapter: 0, page: 5)))
        XCTAssertFalse(table.complete)
        XCTAssertTrue(progress.percentage().hasPrefix("≈"))
        XCTAssertEqual(progress.action(at: 0), .progress(0))
        XCTAssertEqual(progress.action(at: 0.5), .progress(0.5))
        XCTAssertEqual(progress.action(at: 1), .progress(1))
        XCTAssertTrue(progress.label(at: 0.5).contains("— / —"))
        XCTAssertEqual(table.totalPages, 13, "Preview must leave unseen chapter counts unresolved")
    }

    func testSeekWithinCurrentPositionDoesNotNavigate() {
        let page = ReaderProgress(position: .pages(5, 11))
        XCTAssertNil(page.action(at: 0.5))
        XCTAssertNil(page.action(at: 0.54), "Different slider coordinates can still target the same page")
        XCTAssertEqual(page.action(at: 0.56), .page(6))
        XCTAssertNil(ReaderProgress(position: .lines(5, 11)).action(at: 0.5))
        XCTAssertNil(ReaderProgress(position: .file(0, 1, 0.5)).action(at: 0.5))
        var table = ChapterTable(chapters: 4)
        table.setPageCount(chapter: 2, count: 11)
        let chapter = ReaderProgress(position: .chapters(table, .init(chapter: 2, page: 5)))
        XCTAssertNil(chapter.action(at: 0.625))
        XCTAssertNil(chapter.action(at: 0.626))
        XCTAssertEqual(chapter.action(at: 0.65), .progress(0.65))
        XCTAssertEqual(chapter.action(at: 0.25), .progress(0.25), "An unseen chapter must still resolve on navigation")
        let pending = ReaderProgress(position: .chapters(table, .init(chapter: 1, page: 0)))
        XCTAssertEqual(pending.action(at: 0.375), .progress(0.375), "Placeholder page counts cannot prove a seek is unchanged")
    }

    func testPreviewPercentageMatchesTheDestinationPageAfterRelease() {
        let progress = ReaderProgress(position: .pages(0, 8))
        XCTAssertTrue(progress.label(at: 0.5).contains("5 / 8"))
        XCTAssertEqual(progress.percentage(at: 0.5), ReaderProgress(position: .pages(4, 8)).percentage())
        XCTAssertEqual(progress.percentage(at: 1), "100%")
        var table = ChapterTable(chapters: 4)
        table.setPageCount(chapter: 2, count: 3)
        let chapter = ReaderProgress(position: .chapters(table, .init(chapter: 0, page: 0)))
        XCTAssertEqual(chapter.percentage(at: 0.6), ReaderProgress(position: .chapters(table, .init(chapter: 2, page: 1))).percentage())
        XCTAssertEqual(ReaderProgress(position: .file(0, 1, 0)).percentage(at: 0.6), "60%", "Browser scroll progress stays continuous")
    }

    @MainActor
    func testUnchangedSliderInputLeavesNavigationHistoryAndCommandsAlone() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(pageCount: 11); state.count = 11
        state.page = 5
        let host = NSHostingView(rootView: ReaderProgressFooter(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: ReaderProgressFooter.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func slider(in view: NSView) -> ReaderProgressSliderControl? {
            if let slider = view as? ReaderProgressSliderControl { return slider }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }
        func settle() async throws {
            try await Task.sleep(nanoseconds: 10_000_000)
            host.layoutSubtreeIfNeeded()
        }
        try await settle()
        let control = try XCTUnwrap(slider(in: host))
        let revision = state.command.revision
        control.began?(); try await settle()
        control.changed?(0.54); try await settle()
        control.ended?(); try await settle()
        XCTAssertEqual(state.command.revision, revision)
        XCTAssertFalse(state.canNavigateBack)
        control.changed?(0.5); try await settle()
        XCTAssertEqual(state.command.revision, revision)
        XCTAssertFalse(state.canNavigateBack)
        control.changed?(0.6); try await settle()
        XCTAssertEqual(state.command.revision, revision + 1)
        XCTAssertTrue(state.canNavigateBack)
    }

    @MainActor
    func testNativeChapterSeekAndEndLeaveOtherChaptersUnpaginated() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("seek.md")
        let content = (0..<6).map { chapter in
            "# Chapter \(chapter)\n\n" + String(repeating: "A paragraph in this chapter stays readable.\n\n", count: 100)
        }.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let pages = try Pages(url, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", pageSize: CGSize(width: 420, height: 595))
        let table = await pages.chapterLayout
        XCTAssertGreaterThan(table.chapterCount, 3)
        let progress = ReaderProgress(position: .chapters(table, .init(chapter: 0, page: 0)))
        guard case .progress(let target) = progress.action(at: 0.6) else { return XCTFail("Expected chapter seek") }
        let restored = try await pages.progressPosition(target)
        let middle = try XCTUnwrap(restored.anchor.flatMap(ChapterTable.bookmarkLocation)).location
        XCTAssertEqual(middle.chapter, table.chapterCount / 2)
        var updated = await pages.chapterLayout
        XCTAssertEqual(middle.page, Int(((0.6 * Double(table.chapterCount) - Double(middle.chapter)) * Double(updated.pageCount(middle.chapter) - 1)).rounded()))
        XCTAssertGreaterThan(middle.page, 0)
        XCTAssertTrue(updated.isLaidOut(middle.chapter))
        XCTAssertFalse(updated.complete)
        XCTAssertFalse(updated.isLaidOut(1))
        XCTAssertEqual(progress.action(at: 1), .progress(1))
        let ending = try await pages.progressPosition(1)
        updated = await pages.chapterLayout
        let last = try XCTUnwrap(ending.anchor.flatMap(ChapterTable.bookmarkLocation)).location
        XCTAssertEqual(last.chapter, table.chapterCount - 1)
        XCTAssertEqual(last.page, updated.pageCount(last.chapter) - 1)
        XCTAssertFalse(updated.isLaidOut(1))
        XCTAssertFalse(updated.complete)
        withExtendedLifetime(directory) {}
    }

    @MainActor
    func testStateUsesExactNativeTotalOnlyWhenChapterTableIsComplete() throws {
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        state.document = try nativePDFReadingFixture(pageCount: 4)
        state.reflowable = true
        var table = ChapterTable(chapters: 2)
        table.setPageCount(chapter: 0, count: 3)
        state.chapterLayout = table; state.count = 4
        XCTAssertTrue(state.readingProgress.percentage().hasPrefix("≈"))
        table.setPageCount(chapter: 1, count: 5)
        state.chapterLayout = table; state.count = 8; state.page = 7
        XCTAssertEqual(state.readingProgress.percentage(), "100%")
        XCTAssertEqual(state.readingProgress.action(at: 0.5), .page(4))
    }

    @MainActor
    func testDragPreviewsWithoutCommandsAndCancelsWhenDocumentChanges() throws {
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        state.document = try nativePDFReadingFixture(pageCount: 11); state.count = 11
        let revision = state.command.revision
        var drag = ReaderProgressDrag(document: state.document?.id, value: 0)
        for value in [0.1, 0.2, 0.5, 0.8] { drag.value = value }
        XCTAssertEqual(state.command.revision, revision)
        XCTAssertEqual(drag.action(in: state), .page(8))
        state.browserProgress = 0.8
        state.document = try nativePDFReadingFixture(pageCount: 2); state.count = 2
        XCTAssertNil(state.browserProgress, "A newly opened document must not display the previous document's progress")
        XCTAssertNil(drag.action(in: state))
        XCTAssertEqual(state.command.revision, revision)
    }

    @MainActor
    func testNativeSliderKeyboardAndAccessibilityChangePosition() throws {
        _ = NSApplication.shared
        let slider = ReaderProgressSliderControl(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.target = slider; slider.action = #selector(ReaderProgressSliderControl.changedValue)
        slider.step = 0.1
        var changes: [Double] = []
        slider.changed = { changes.append($0) }
        slider.accessibilityPerformIncrement()
        XCTAssertGreaterThan(slider.doubleValue, 0.5)
        XCTAssertEqual(changes.last, slider.doubleValue)
        let forward = slider.doubleValue
        slider.accessibilityPerformDecrement()
        XCTAssertLessThan(slider.doubleValue, forward)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{f703}",
            charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
        let previous = slider.doubleValue
        slider.keyDown(with: event)
        XCTAssertGreaterThan(slider.doubleValue, previous)
        XCTAssertEqual(changes.last, slider.doubleValue)
        slider.isEnabled = false
        let disabled = slider.doubleValue
        XCTAssertFalse(slider.accessibilityPerformIncrement())
        XCTAssertFalse(slider.accessibilityPerformDecrement())
        slider.keyDown(with: event)
        XCTAssertEqual(slider.doubleValue, disabled)
    }

    @MainActor
    func testSliderFrameStaysFixedAcrossPageChangesAndDragPreviews() async throws {
        _ = NSApplication.shared
        func slider(in view: NSView) -> ReaderProgressSliderControl? {
            if let slider = view as? ReaderProgressSliderControl { return slider }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }
        for width: CGFloat in [560, 1000] {
            let state = ReaderState(recordsHistory: false)
            state.document = try nativePDFReadingFixture(pageCount: 12); state.count = 12
            let host = NSHostingView(rootView: ReaderProgressFooter(state: state))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: ReaderProgressFooter.height),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer {
                state.windowClosed(); window.contentView = nil; window.close()
            }
            func settle() async throws {
                try await Task.sleep(nanoseconds: 10_000_000)
                host.layoutSubtreeIfNeeded()
            }
            try await settle()
            let control = try XCTUnwrap(slider(in: host))
            let original = control.convert(control.bounds, to: host)
            XCTAssertGreaterThan(original.width, 80)
            func assertFrame(line: UInt = #line) {
                let current = control.convert(control.bounds, to: host)
                XCTAssertEqual(current.minX, original.minX, accuracy: 0.01, "width=\(width)", line: line)
                XCTAssertEqual(current.width, original.width, accuracy: 0.01, "width=\(width)", line: line)
                XCTAssertEqual(current.minY, original.minY, accuracy: 0.01, line: line)
                XCTAssertEqual(current.height, original.height, accuracy: 0.01, line: line)
            }
            for page in [0, 6, 11] {
                state.page = page
                try await settle(); assertFrame()
            }
            control.focused?(true)
            try await settle(); assertFrame()
            let revision = state.command.revision
            control.began?()
            try await settle()
            for value in [0.0, 0.5, 1.0, 0.0] {
                control.changed?(value)
                try await settle(); assertFrame()
                XCTAssertEqual(state.command.revision, revision, "Preview must not navigate")
            }
            control.ended?()
            try await settle(); assertFrame()
            XCTAssertEqual(state.command.revision, revision + 1, "Release commits once")
        }
    }

    @MainActor
    func testFooterAlwaysReservesTheSameCompactHeight() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        state.document = try nativePDFReadingFixture(pageCount: 3); state.count = 3
        let host = NSHostingView(rootView: ReaderProgressFooter(state: state))
        host.frame = CGRect(x: 0, y: 0, width: 700, height: ReaderProgressFooter.height)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        state.page = 2
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, size.height)
        XCTAssertEqual(size.height, 30)
    }
}
#endif
