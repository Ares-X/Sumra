#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeMarkdownReflowScrollTests: XCTestCase {
    func testThemeAndViewportChangesKeepContinuousPassage() async throws {
        let defaults = UserDefaults.standard
        let previousTheme = defaults.object(forKey: "theme")
        defer { defaults.set(previousTheme, forKey: "theme") }
        try await withReader(flow: "continuous") { state, pages, host in
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            for (theme, width) in [("dark", 600.0), ("light-warm", 900.0), ("light", 600.0)] {
                let revision = state.renderRevision
                state.setTheme(theme)
                host.window?.setContentSize(CGSize(width: width, height: 700))
                try await self.wait(host, state: state) {
                    state.renderRevision > revision && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page))
                }
                try await self.settle(host)
                XCTAssertEqual(state.currentPosition.nativePassage?.source, original.source)
                XCTAssertGreaterThan(try XCTUnwrap(state.currentPosition.y), 1000)
            }
        }
    }

    func testInitialNaturalRestoreUsesVisiblePassageAtMarginsAndLineBoundaries() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("InitialViewport.md")
        try (0..<80).map { "Visible paragraph \($0): 中文 English text wraps across its reading line.\n\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let viewport = CGSize(width: 620, height: 160)
        for boundary in [0, 1, 2] {
            let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                         pageSize: CGSize(width: viewport.width, height: 0))
            let words = try await pages.words(0)
            let first = try XCTUnwrap(words.first { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) })
            let later = try XCTUnwrap(words.first { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace)
                && $0.bounds.minY > first.bounds.maxY })
            let y: Double = boundary == 0 ? 0 : Double(later.bounds.minY + (boundary == 2 ? later.bounds.height / 2 : 0))
            if boundary == 0 {
                XCTAssertGreaterThan(first.bounds.minY, 0, "This case begins above text in the top margin")
                XCTAssertLessThan(first.bounds.minY, viewport.height)
            }
            let fullPage = try await pages.position(page: 0, x: 0, y: y)
            let expected = try XCTUnwrap(fullPage.nativePassage)
            let initial = try await pages.restore(.init(page: 0, x: 0, y: y), viewport: viewport)
            XCTAssertEqual(initial.nativePassage?.source, expected.source,
                           "Visible text must select the same source at a margin, line top or partially visible line")
            XCTAssertEqual(initial.x, 0)
            XCTAssertEqual(try XCTUnwrap(initial.y), y, accuracy: 0.001)
            for zoom in [1.5, 1.0] {
                _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", textZoom: zoom)
                let restored = try await pages.restore(initial, viewport: viewport)
                XCTAssertEqual(restored.nativePassage?.source, expected.source,
                               "Initial viewport capture must remain the source owner after typography reflow")
            }
        }
    }

    func testInitialNaturalRestoreKeepsPixelsWhenViewportContainsOnlyArtworkOrBlankPaper() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 640,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for offset in stride(from: 0, to: 64 * 640, by: 4) {
            pixels[offset] = 90; pixels[offset + 1] = 120; pixels[offset + 2] = 180; pixels[offset + 3] = 255
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.url.appendingPathComponent("artwork.png"))
        let viewport = CGSize(width: 620, height: 120)
        for artwork in [false, true] {
            let input = directory.url.appendingPathComponent(artwork ? "Artwork.md" : "Blank.md")
            let body = "Text after the authored area.\n\n" + String(repeating: "Further body text.\n\n", count: 40)
            try ((artwork ? "![](artwork.png)\n\n" : "") + body)
                .write(to: input, atomically: true, encoding: .utf8)
            let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
            let css = artwork ? "img { width: 400pt; height: 640pt; }" : "body { padding-top: 640pt; }"
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                         userCSS: css, pageSize: CGSize(width: viewport.width, height: 0))
            let words = try await pages.words(0)
            let first = try XCTUnwrap(words.first { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) })
            XCTAssertGreaterThan(first.bounds.minY, viewport.height, "The complete initial viewport must precede body text")
            let restored = try await pages.restore(.init(page: 0, x: 0, y: 10), viewport: viewport)
            XCTAssertNil(restored.nativePassage, "An initial artwork or blank viewport must not acquire distant body text")
            XCTAssertEqual(restored.page, 0)
            XCTAssertEqual(restored.x, 0)
            XCTAssertEqual(restored.y, 10)
            let reported = try await pages.position(page: 0, x: 0, y: 10, viewport: viewport)
            XCTAssertNil(reported.nativePassage)
            XCTAssertEqual(reported.x, restored.x)
            XCTAssertEqual(reported.y, restored.y)
        }
    }

    func testFittingPageRoundtripRetainsPassageAfterScrollReports() async throws {
        try await withReader(flow: "paged") { state, pages, host in
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            let originalPage = state.page
            let originalText = try await pages.text(originalPage)
            let initialWords = try await pages.words(originalPage)
            XCTAssertTrue(initialWords.contains { $0.source == original.source },
                          "The captured viewport passage must belong to the finite page being displayed")
            for zoom in [1.5, 1.0] {
                let revision = state.renderRevision
                if zoom == 1 { state.setActualSize() } else { state.setZoom(zoom) }
                try await self.wait(host, state: state) {
                    state.renderRevision > revision && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page))
                }
                try await self.settle(host)
                XCTAssertEqual(state.currentPosition.nativePassage?.source, original.source,
                               "A clamped programmatic scroll report must retain the restored source glyph at zoom \(zoom)")
                let restored = await pages.layoutPosition
                let words = try await pages.words(restored.page)
                XCTAssertTrue(words.contains { $0.source == original.source }, "The model's restored source page must contain the exact glyph")
            }
            XCTAssertEqual(state.page, originalPage, "Returning to the original typography must return to its source page")
            let returnedText = try await pages.text(state.page)
            XCTAssertEqual(returnedText, originalText)
            state.navigate(.page(originalPage + 2))
            try await self.wait(host, state: state) { state.page == originalPage + 2 && state.currentPosition.nativePassage != nil }
            XCTAssertNotEqual(state.currentPosition.nativePassage?.source, original.source,
                              "Explicit page navigation must replace the reflow passage")
        }
    }

    func testContinuousFindPassageSurvivesExtremeZoomRoundtrip() async throws {
        try await withReader(flow: "continuous") { state, pages, host in
            let text = try await pages.text(state.page)
            let line = try XCTUnwrap(text.split(separator: "\n").first)
            let query = try XCTUnwrap(line.split(separator: " ").last).description
            state.send(.find(query))
            try await self.wait(host, state: state) {
                state.selectedSearchTarget != nil && state.currentPosition.nativePassage != nil &&
                    !state.searchCounting && state.searchResults.count == 1
            }
            try await self.settle(host)
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            let originalMatch = try XCTUnwrap(RasterReader.highlightedMatch(in: state.readerFocusView))
            XCTAssertEqual(state.searchCountText, "1 / 1")
            let foundWords = try await pages.words(state.page)
            XCTAssertTrue(foundWords.contains { $0.source == original.source && !$0.text.allSatisfy(\.isWhitespace) })
            for zoom in [6.0, 1.0] {
                let revision = state.renderRevision
                if zoom == 1 { state.setActualSize() } else { state.setZoom(zoom) }
                try await self.wait(host, state: state) {
                    state.renderRevision > revision && !state.searchCounting && state.searchResults.count == 1 &&
                        RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)) &&
                        RasterReader.highlightedMatch(in: state.readerFocusView)?.rects.isEmpty == false
                }
                try await self.settle(host)
                let highlighted = try XCTUnwrap(RasterReader.highlightedMatch(in: state.readerFocusView))
                XCTAssertEqual(highlighted.source, originalMatch.source)
                XCTAssertEqual(state.searchCountText, "1 / 1")
                let refreshed = try await pages.markdownDocumentMatches(query, options: .init(),
                    startPage: state.page, after: originalMatch.source, inclusive: true)
                XCTAssertEqual(highlighted, refreshed.first, "The canvas must paint the current layout's match geometry")
                XCTAssertEqual(state.currentPosition.nativePassage?.source, original.source,
                               "Find's reading passage must survive continuous \(zoom) typography reflow")
                let restored = await pages.layoutPosition
                let words = try await pages.words(restored.page)
                XCTAssertTrue(words.contains { $0.source == original.source })
            }
        }
    }

    func testWholeBookCountKeepsSelectedMatchFromLaterChapter() async throws {
        let text = "# Preface\n\n" + String(repeating: "Opening paragraph long enough to scroll.\n\n", count: 80) +
            "## Search marker\n\nSearch marker in the body.\n\n## Ending\n\n" + String(repeating: "Closing paragraph.\n\n", count: 30)
        try await withReader(flow: "continuous", text: text) { state, pages, host in
            state.navigate(.page(1))
            try await self.wait(host, state: state) { state.pageLocation(state.page).chapter == 1 }
            try await self.settle(host)
            state.send(.find("Search marker"))
            try await self.wait(host, state: state) { !state.searchCounting && state.searchResults.count == 2 }
            try await self.settle(host)
            let first = try XCTUnwrap(RasterReader.highlightedMatch(in: state.readerFocusView))
            XCTAssertEqual(first.source?.chapter, 1)
            XCTAssertEqual(state.searchCountText, "1 / 2")
            state.send(.find("Search marker"))
            try await self.wait(host, state: state) {
                RasterReader.highlightedMatch(in: state.readerFocusView)?.source != first.source
            }
            XCTAssertEqual(state.searchCountText, "2 / 2")
            state.send(.find("Search marker", backwards: true))
            try await self.wait(host, state: state) {
                RasterReader.highlightedMatch(in: state.readerFocusView)?.source == first.source
            }
            XCTAssertEqual(state.searchCountText, "1 / 2")
        }
    }

    func testReflowRetainsSecondOccurrenceOnSamePageAndFindAdvancesFromIt() async throws {
        try await withReader(flow: "continuous") { state, pages, host in
            let query = "Boundary"
            let expected = try await pages.markdownDocumentMatches(query, options: .init(),
                startPage: state.page, maximum: 3)
            XCTAssertEqual(expected.count, 3)
            guard expected.count == 3 else { return }
            XCTAssertEqual(expected[0].page, expected[1].page)
            state.send(.find(query))
            try await self.wait(host, state: state) { !state.searchCounting && state.searchResults.count == 400 }
            try await self.settle(host)
            state.send(.find(query))
            try await self.wait(host, state: state) {
                RasterReader.highlightedMatch(in: state.readerFocusView)?.source == expected[1].source
            }
            try await self.settle(host)
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            let revision = state.renderRevision
            state.setZoom(1.5)
            try await self.wait(host, state: state) {
                state.renderRevision > revision && !state.searchCounting && state.searchResults.count == 400 &&
                    RasterReader.highlightedMatch(in: state.readerFocusView)?.source == expected[1].source &&
                    RasterReader.highlightedMatch(in: state.readerFocusView)?.rects.isEmpty == false
            }
            try await self.settle(host)
            XCTAssertEqual(state.currentPosition.nativePassage?.source, original.source)
            let highlighted = try XCTUnwrap(RasterReader.highlightedMatch(in: state.readerFocusView))
            XCTAssertEqual(state.selectedSearchTarget, "raster-search:\(highlighted.page):\(highlighted.index)")
            XCTAssertTrue(state.searchResults.contains { $0.target == state.selectedSearchTarget })
            state.send(.find(query))
            try await self.wait(host, state: state) {
                RasterReader.highlightedMatch(in: state.readerFocusView)?.source == expected[2].source
            }
        }
    }

    func testReflowRetainsOccurrenceBeyondCountCap() async throws {
        try await withReader(flow: "continuous", text: String(repeating: "hit ", count: 1006)) { state, pages, host in
            let count = await pages.count
            state.navigate(.page(count - 1))
            try await self.wait(host, state: state) { state.page == count - 1 && state.currentPosition.nativePassage != nil }
            try await self.settle(host)
            let ending = try await pages.markdownDocumentMatches("hit", options: .init(),
                startPage: count - 1, backwards: true)
            let expected = try XCTUnwrap(ending.first)
            state.send(.find("hit", backwards: true))
            try await self.wait(host, state: state) {
                !state.searchCounting && state.searchCountCapped && state.searchResults.count == 999 &&
                    self.highlightedMatch(state)?.source == expected.source
            }
            try await self.settle(host)
            XCTAssertFalse(state.searchResults.contains { $0.target == state.selectedSearchTarget },
                           "The selected occurrence must actually lie beyond the capped result list")
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            let revision = state.renderRevision
            state.setZoom(1.5)
            try await self.wait(host, state: state) {
                state.renderRevision > revision && !state.searchCounting && state.searchCountCapped &&
                    state.searchResults.count == 999 &&
                    self.highlightedMatch(state)?.source == expected.source &&
                    self.highlightedMatch(state)?.rects.isEmpty == false
            }
            try await self.settle(host)
            XCTAssertEqual(state.currentPosition.nativePassage?.source, original.source)
            let refreshed = try await pages.markdownDocumentMatches("hit", options: .init(),
                startPage: state.page, after: expected.source, inclusive: true)
            XCTAssertEqual(self.highlightedMatch(state), refreshed.first,
                           "The mounted selected canvas must use refreshed geometry outside the counting list")
            XCTAssertFalse(state.searchResults.contains { $0.target == state.selectedSearchTarget })
            let next = try await pages.markdownDocumentMatches("hit", options: .init(),
                startPage: state.page, after: expected.source, backwards: true)
            state.send(.find("hit", backwards: true))
            try await self.wait(host, state: state) {
                self.highlightedMatch(state)?.source == next.first?.source
            }
            XCTAssertNotEqual(next.first?.source, expected.source)
        }
    }

    func testNewQueryAndUserScrollTakePrecedenceOverSearchRefresh() async throws {
        try await withReader(flow: "continuous") { state, pages, host in
            state.send(.find("Boundary"))
            try await self.wait(host, state: state) { !state.searchCounting && state.searchResults.count == 400 }
            try await self.settle(host)
            let revision = state.renderRevision
            state.setZoom(1.5)
            try await self.wait(host, state: state) { state.renderRevision > revision }
            // Replace the query while its previous layout's refresh can still
            // be publishing; the unique new occurrence owns the selection.
            state.send(.find("000399"))
            try await self.wait(host, state: state) {
                !state.searchCounting && state.searchResults.count == 1 &&
                    RasterReader.highlightedMatch(in: state.readerFocusView)?.context.contains("000399") == true
            }
            try await self.settle(host)
            let found = try XCTUnwrap(state.currentPosition.nativePassage)
            XCTAssertEqual(state.searchCountText, "1 / 1")
            state.scroll(.up, amount: .halfPage)
            try await self.settle(host)
            let moved = try XCTUnwrap(state.currentPosition.nativePassage)
            XCTAssertNotEqual(moved.source, found.source)
            let nextRevision = state.renderRevision
            state.setActualSize()
            try await self.wait(host, state: state) {
                state.renderRevision > nextRevision && !state.searchCounting && state.searchResults.count == 1
            }
            try await self.settle(host)
            XCTAssertEqual(state.currentPosition.nativePassage?.source, moved.source,
                           "Refreshing a selected match must not navigate back to it after user scrolling")
            XCTAssertEqual(state.searchCountText, "1 / 1")
        }
    }

    func testContinuousReflowRetainsPassageUntilUserScrolls() async throws {
        try await withReader(flow: "continuous") { state, pages, host in
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            let revision = state.renderRevision
            state.setZoom(1.5)
            try await self.wait(host, state: state) { state.renderRevision > revision }
            try await self.settle(host)
            XCTAssertEqual(state.currentPosition.nativePassage?.source, original.source)
            let scroll = try XCTUnwrap(state.readerScrollView)
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            var bounds = scroll.contentView.bounds
            bounds.origin.y += 250
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            try await self.settle(host)
            let moved = try XCTUnwrap(state.currentPosition.nativePassage)
            XCTAssertNotEqual(moved.source, original.source, "Real live scroll must capture the newly read glyph")
            let nextRevision = state.renderRevision
            state.setActualSize()
            try await self.wait(host, state: state) { state.renderRevision > nextRevision }
            try await self.settle(host)
            XCTAssertEqual(state.currentPosition.nativePassage?.source, moved.source,
                           "The next reflow must retain the user's new passage")
            state.scroll(.down, amount: .halfPage)
            try await self.settle(host)
            let keyboardMoved = try XCTUnwrap(state.currentPosition.nativePassage)
            XCTAssertNotEqual(keyboardMoved.source, moved.source, "Keyboard scrolling must release the restored passage")
            // AppKit needs a current, window-owned event; a discrete mouse
            // wheel has no trackpad phase or momentum.
            let wheelWindow = try XCTUnwrap(scroll.window)
            let wheelPoint = scroll.contentView.convert(CGPoint(x: scroll.contentView.bounds.midX,
                                                                 y: scroll.contentView.bounds.midY), to: nil)
            let wheelSeed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: wheelPoint,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: wheelWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let wheel = try XCTUnwrap(wheelSeed.cgEvent?.copy())
            wheel.type = .scrollWheel
            wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            wheel.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -200)
            wheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -200)
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
            try await self.settle(host)
            XCTAssertNotEqual(state.currentPosition.nativePassage?.source, keyboardMoved.source,
                              "A native wheel event must capture the newly read glyph")
            state.freePan = true
            try await self.settle(host)
            let beforePan = try XCTUnwrap(state.currentPosition.nativePassage)
            let canvas = try XCTUnwrap(state.readerFocusView), window = try XCTUnwrap(canvas.window)
            let start = canvas.convert(CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY), to: nil)
            func panEvent(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x, y: y), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try panEvent(.leftMouseDown, y: start.y))
            // A user can pause between starting a pan and moving. Its eventual
            // motion must release any passage captured during that pause.
            try await self.settle(host)
            canvas.mouseDragged(with: try panEvent(.leftMouseDragged, y: start.y - 200))
            canvas.mouseUp(with: try panEvent(.leftMouseUp, y: start.y - 200))
            try await self.settle(host)
            XCTAssertNotEqual(state.currentPosition.nativePassage?.source, beforePan.source,
                              "A delayed physical pan must capture the newly read glyph")
        }
    }

    func testSelectionAutoscrollCapturesMovedViewportForNextReflow() async throws {
        try await withReader(flow: "continuous", fit: "actual", viewportHeight: 300) { state, pages, host in
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            let scroll = try XCTUnwrap(state.readerScrollView)
            let canvas = try XCTUnwrap(state.readerFocusView)
            let window = try XCTUnwrap(canvas.window)
            let clip = scroll.contentView
            let before = clip.bounds.origin
            let start = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try event(.leftMouseDown, point: start))
            for _ in 0..<12 {
                let outside = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.maxY + 40), to: nil)
                canvas.mouseDragged(with: try event(.leftMouseDragged, point: outside))
                try await self.settle(host)
                if clip.bounds.minY - before.y > 100 { break }
            }
            let end = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.maxY + 40), to: nil)
            canvas.mouseUp(with: try event(.leftMouseUp, point: end))
            try await self.settle(host)
            XCTAssertGreaterThan(clip.bounds.minY - before.y, 100, "Selection dragging must actually autoscroll")
            XCTAssertTrue(state.hasSelection)
            try await self.assertMovedPassageSurvivesReflow(state, pages: pages, host: host, original: original)
        }
    }

    func testCaretMovementCapturesViewportOnlyWhenItScrolls() async throws {
        try await withReader(flow: "continuous", fit: "actual", viewportHeight: 300) { state, pages, host in
            // Start inside a page so a visible caret step must preserve a
            // viewport passage that differs from the page's first glyph.
            state.scroll(.down, amount: .halfPage)
            try await self.settle(host)
            let original = try XCTUnwrap(state.currentPosition.nativePassage)
            let scroll = try XCTUnwrap(state.readerScrollView)
            let canvas = try XCTUnwrap(state.readerFocusView)
            let window = try XCTUnwrap(canvas.window)
            let words = try await pages.words(state.page)
            let pageBounds = try await pages.bounds(state.page)
            let transform = RasterLayout.transform(bounds: pageBounds, size: canvas.bounds.size, rotation: state.rotation)
            let visible = canvas.visibleRect
            let word = try XCTUnwrap(words.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                visible.insetBy(dx: 20, dy: 30).contains($0.bounds.applying(transform)) })
            let box = word.bounds.applying(transform)
            let point = canvas.convert(CGPoint(x: box.midX, y: box.midY), to: nil)
            func click(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try click(.leftMouseDown)); canvas.mouseUp(with: try click(.leftMouseUp))
            state.keyboardTextSelection = true
            func key(_ code: UInt16, characters: String) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            }
            let before = scroll.contentView.bounds.origin
            canvas.keyDown(with: try key(124, characters: "\u{F703}"))
            try await self.settle(host)
            XCTAssertEqual(scroll.contentView.bounds.origin, before, "A visible caret step must leave the viewport in place")
            XCTAssertEqual(state.currentPosition.nativePassage, original, "A visible caret must retain the viewport passage")
            state.discardNativePassage()
            XCTAssertNil(state.currentPosition.nativePassage)
            canvas.keyDown(with: try key(124, characters: "\u{F703}"))
            try await self.settle(host)
            XCTAssertEqual(scroll.contentView.bounds.origin, before)
            XCTAssertEqual(state.currentPosition.nativePassage, original,
                           "A caret step before debounced capture must retain the actual viewport")
            for _ in 0..<24 {
                try XCTUnwrap(state.readerFocusView).keyDown(with: try key(125, characters: "\u{F701}"))
                try await self.settle(host)
            }
            XCTAssertGreaterThan(scroll.contentView.bounds.minY - before.y, 0.5, "Moving the caret beyond the viewport must scroll it")
            try await self.assertMovedPassageSurvivesReflow(state, pages: pages, host: host, original: original)
        }
    }

    private func assertMovedPassageSurvivesReflow(_ state: ReaderState, pages: Pages, host: NSView,
                                                original: NativePassage) async throws {
        let moved = try XCTUnwrap(state.currentPosition.nativePassage)
        let actual = try await pages.capturePassage(state.currentPosition, theme: state.resolvedTheme, userCSS: state.effectiveUserCSS)
        XCTAssertEqual(moved, actual, "The retained passage must describe the actual viewport after user movement")
        XCTAssertNotEqual(moved.source, original.source)
        let revision = state.renderRevision
        state.setZoom(1.5)
        try await wait(host, state: state) { state.renderRevision > revision }
        try await settle(host)
        XCTAssertEqual(state.currentPosition.nativePassage?.source, moved.source, "Reflow must preserve the newly read glyph")
    }

    private func withReader(flow: String, fit: String = "page", viewportHeight: CGFloat = 800, text: String? = nil,
                            body: (ReaderState, Pages, NSView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("Boundary.md")
        try (text ?? (0..<400).map { "Boundary paragraph \(String(format: "%06d", $0)).\n\n" }.joined())
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32; state.font = "system"; state.theme = "light"
        state.zoom = 1; state.fit = fit; state.flow = flow; state.spread = false; state.cover = false
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.automaticLayout = false
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                     userCSS: state.effectiveUserCSS, pageSize: CGSize(width: 900, height: flow == "continuous" ? 0 : viewportHeight))
        state.reflowable = true; state.count = await pages.count; state.chapterLayout = await pages.chapterLayout
        if flow == "continuous" {
            let bounds = try await pages.bounds(0)
            state.updatePosition(try await pages.position(page: 0, y: Double(bounds.height / 2)))
        } else {
            let target = state.count / 2
            state.updatePosition(.init(page: target))
        }
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: viewportHeight), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        try await wait(host, state: state) {
            RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)) && state.currentPosition.nativePassage != nil
        }
        try await settle(host)
        try await body(state, pages, host)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<30 { paintViewport(host); try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func paintViewport(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
    }

    private func highlightedMatch(_ state: ReaderState) -> RasterMatch? {
        // At the document end the focus canvas can be the preceding page;
        // inspect the mounted selected canvas in the whole continuous viewport.
        func match(in view: NSView) -> RasterMatch? {
            if let selected = RasterReader.highlightedMatch(in: view) { return selected }
            return view.subviews.lazy.compactMap { match(in: $0) }.first
        }
        return state.readerScrollView?.documentView.flatMap { match(in: $0) }
    }

    private func wait(_ host: NSView, state: ReaderState, file: StaticString = #filePath, line: UInt = #line,
                      until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), state.error == nil, Date() < deadline {
            paintViewport(host); try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(state.error, file: file, line: line)
        XCTAssertTrue(predicate(), "Timed out waiting for mounted Markdown reader; page=\(state.page), target=\(state.selectedSearchTarget ?? "nil"), count=\(state.searchCountText), capped=\(state.searchCountCapped)", file: file, line: line)
    }
}
#endif
