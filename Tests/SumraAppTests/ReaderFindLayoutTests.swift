#if os(macOS)
import AppKit
import Combine
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderFindLayoutTests: XCTestCase {
    func testFindStatusChangesKeepNativeReadingGeometryAndLayout() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("Find-status.fb2")
        let paragraphs = (0..<80).map { "<p>Paragraph \($0) keeps the reading geometry while search status changes.</p>" }.joined()
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section>\(paragraphs)</section></body></FictionBook>"
            .write(to: input, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let saved = ["flow", "spread", "cover", "findFloating"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: "findFloating")
        let document = try ReadingDocument.open(input, deferReflowLayout: true)
        guard case .pages(let pages) = document.content else { return XCTFail("Expected native book") }
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.flow = "paged"; state.toolbarDisplayMode = .shown
        state.showContents = false; state.showAI = false; state.showFindPanel()
        state.spread = false; state.cover = false; state.automaticLayout = false
        state.font = "serif"; state.fontSize = 17; state.margin = 32
        state.freePan = false; state.fit = "page"; state.zoom = 1; state.scrollbarMode = "hidden"
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        var observedViewports = [CGSize]()
        func settle() async throws {
            let deadline = Date().addingTimeInterval(10)
            var stableSince: Date?
            var previousRevision = -1
            repeat {
                host.layoutSubtreeIfNeeded()
                if let size = state.readerScrollView?.contentView.safeAreaRect.size,
                   observedViewports.last != size { observedViewports.append(size) }
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                let ready = RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages,
                    location: state.pageLocation(state.page)) && state.pendingReflowPosition == nil &&
                    state.currentPosition.nativePassage != nil
                if ready, previousRevision == state.renderRevision {
                    if let stableSince, Date().timeIntervalSince(stableSince) >= 0.15 { return }
                    if stableSince == nil { stableSince = Date() }
                } else { stableSince = nil }
                previousRevision = state.renderRevision
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Find status geometry did not settle")
        }
        try await settle()
        let scroll = try XCTUnwrap(state.readerScrollView)
        let frame = scroll.convert(scroll.bounds, to: nil)
        let viewport = scroll.contentView.safeAreaRect.size
        let layoutRevision = await pages.layoutRevision
        let renderRevision = state.renderRevision
        for status in ["Searching… 0 matches", "", "1 / 25"] {
            observedViewports = []
            state.status = status
            try await settle()
            XCTAssertEqual(scroll.convert(scroll.bounds, to: nil), frame, "Find status: \(status)")
            XCTAssertEqual(scroll.contentView.safeAreaRect.size, viewport, "Find status: \(status)")
            let currentLayoutRevision = await pages.layoutRevision
            print("Find status geometry: status=\(status.debugDescription), viewports=\(observedViewports), layout=\(layoutRevision)→\(currentLayoutRevision)")
            XCTAssertTrue(observedViewports.allSatisfy { $0 == viewport }, "Find status must retain its viewport throughout the update: \(observedViewports)")
            XCTAssertEqual(currentLayoutRevision, layoutRevision, "Search status must not paginate the book again")
            XCTAssertEqual(state.renderRevision, renderRevision, "Search status must not replace the reading surface")
        }
        XCTAssertNil(state.error)
        XCTAssertFalse(window.isVisible, "The geometry regression must not display or activate its test window")
    }
    func testFindNextWithClosedFindChangesStatusGeometryOncePerSession() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("Closed-find.fb2")
        let paragraphs = (0..<40).map { "<p>Paragraph \($0) includes needle for finding the next occurrence after closing Find.</p>" }.joined()
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section>\(paragraphs)</section></body></FictionBook>"
            .write(to: input, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let saved = ["flow", "spread", "cover", "findFloating"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: "findFloating")
        let document = try ReadingDocument.open(input, deferReflowLayout: true)
        guard case .pages(let pages) = document.content else { return XCTFail("Expected native book") }
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.flow = "paged"; state.toolbarDisplayMode = .shown
        state.showContents = false; state.showAI = false; state.showFindPanel()
        state.spread = false; state.cover = false; state.automaticLayout = false
        state.font = "serif"; state.fontSize = 17; state.margin = 32
        state.freePan = false; state.fit = "page"; state.zoom = 1; state.scrollbarMode = "hidden"
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        var observedViewports = [CGSize]()
        var observedStatuses = [String]()
        func settle(_ condition: () -> Bool = { true }) async throws {
            let deadline = Date().addingTimeInterval(10)
            var stableSince: Date?
            var previousRevision = -1
            repeat {
                host.layoutSubtreeIfNeeded()
                if let size = state.readerScrollView?.contentView.safeAreaRect.size,
                   observedViewports.last != size { observedViewports.append(size) }
                if observedStatuses.last != state.status { observedStatuses.append(state.status) }
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                let ready = RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages,
                    location: state.pageLocation(state.page)) && state.pendingReflowPosition == nil &&
                    state.currentPosition.nativePassage != nil && condition()
                if ready, previousRevision == state.renderRevision {
                    if let stableSince, Date().timeIntervalSince(stableSince) >= 0.15 { return }
                    if stableSince == nil { stableSince = Date() }
                } else { stableSince = nil }
                previousRevision = state.renderRevision
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Closed Find navigation did not settle")
        }
        try await settle()
        state.updateFindQuery("needle"); state.findNext()
        try await settle { state.searchResults.count == 40 && !state.searchCounting && state.selectedSearchTarget != nil }
        state.closeFind()
        try await settle { !state.showFind && state.searchResults.isEmpty && state.status.isEmpty }
        XCTAssertEqual(state.findQuery, "needle", "Closing Find retains the query for Cmd-G/F3")
        XCTAssertFalse(state.searchSessionActive, "Closing Find ends the session and reclaims its status area")
        let viewport = try XCTUnwrap(state.readerScrollView).contentView.safeAreaRect.size
        let layoutRevision = await pages.layoutRevision
        var commands = [ReaderAction]()
        let observation = state.$command.dropFirst().sink { commands.append($0.action) }
        defer { observation.cancel() }
        observedViewports = []; observedStatuses = []
        state.findNext()
        try await settle { state.searchResults.count == 40 && !state.searchCounting && state.selectedSearchTarget != nil }
        let currentLayoutRevision = await pages.layoutRevision
        let styles = commands.filter { if case .style = $0 { return true }; return false }.count
        print("Closed Find next: viewports=\(observedViewports), statuses=\(observedStatuses), layout=\(layoutRevision)→\(currentLayoutRevision), styleCommands=\(styles)")
        XCTAssertFalse(state.showFind, "Find Next must preserve the closed Find UI")
        let finalViewport = try XCTUnwrap(state.readerScrollView).contentView.safeAreaRect.size
        XCTAssertTrue(state.searchSessionActive)
        XCTAssertLessThan(finalViewport.height, viewport.height, "Starting a closed-Find session presents its status area")
        var transitions = [viewport]
        for size in observedViewports where transitions.last != size { transitions.append(size) }
        XCTAssertEqual(transitions, [viewport, finalViewport], "The new status area must appear once without clear/reflow oscillation")
        XCTAssertEqual(currentLayoutRevision, layoutRevision + 1, "Only the new session status area may repaginate")
        XCTAssertEqual(styles, 1, "The new session geometry needs one style command")
        let completedRevision = currentLayoutRevision
        for status in ["", "Searching… 40 matches", "1 / 40"] {
            observedViewports = []
            state.status = status
            try await settle()
            XCTAssertTrue(observedViewports.allSatisfy { $0 == finalViewport })
            let revision = await pages.layoutRevision
            XCTAssertEqual(revision, completedRevision, "An active session keeps its geometry across status updates")
        }
        state.closeFind()
        try await settle { !state.searchSessionActive && state.status.isEmpty && state.searchResults.isEmpty }
        XCTAssertEqual(try XCTUnwrap(state.readerScrollView).contentView.safeAreaRect.size, viewport,
            "Escape/Close Find must reclaim the status area despite its retained query")
        XCTAssertNil(state.error)
        XCTAssertFalse(window.isVisible)
    }
}
#endif
