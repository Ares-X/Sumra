#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class SavedTabGroupBehaviorTests: XCTestCase {
    func testRestoreAvailabilityRequiresAUsableSavedGroupWithoutChangingStatus() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in ReaderWindows.savedTabGroupKeys { arguments[key] = Data("[]".utf8) }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        fixture.state.status = "Keep the current message"
        XCTAssertFalse(ReaderMenuCommand.restoreTabGroup.enabled(fixture.state))
        fixture.state.restoreTabGroup()
        XCTAssertEqual(fixture.state.status, "Keep the current message")
        let key = "tabGroup:test-" + UUID().uuidString
        arguments[key] = try JSONEncoder().encode(fixture.saved)
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertTrue(ReaderMenuCommand.restoreTabGroup.enabled(fixture.state))
    }

    func testRestoreNewTabAppendsToCurrentNativeGroupAndKeepsPositions() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = fixture.state.document?.id
        var created = [WindowPayload]()
        ReaderWindows.restoreTabGroup(fixture.saved, in: fixture.state, behavior: .newTab) { created.append($0) }
        XCTAssertEqual(fixture.state.document?.id, original)
        XCTAssertEqual(created.map(\.path), fixture.saved.map(\.path))
        XCTAssertTrue(created.allSatisfy { $0.tabWith == fixture.window.windowNumber })
        XCTAssertTrue(created.allSatisfy { $0.tabIdentifier == fixture.window.tabbingIdentifier && $0.restoring })
        XCTAssertEqual(created.map { $0.position?.zoom }, fixture.saved.map { $0.position?.zoom })
    }

    func testRestoreNewWindowCreatesOneSeparateGroup() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var created = [WindowPayload]()
        ReaderWindows.restoreTabGroup(fixture.saved, in: fixture.state, behavior: .newWindow) { created.append($0) }
        XCTAssertEqual(created.map(\.path), fixture.saved.map(\.path))
        XCTAssertTrue(created.allSatisfy { $0.tabWith == nil })
        XCTAssertEqual(Set(created.compactMap(\.tabIdentifier)).count, 1)
        XCTAssertNotEqual(created.first?.tabIdentifier, fixture.window.tabbingIdentifier)
    }

    func testRestoredTabsKeepExistingNativeSiblingsAheadOfAppendedGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let sibling = NSWindow(contentRect: fixture.window.frame, styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        sibling.isReleasedWhenClosed = false; sibling.alphaValue = 0; sibling.ignoresMouseEvents = true
        sibling.tabbingIdentifier = fixture.window.tabbingIdentifier
        fixture.window.addTabbedWindow(sibling, ordered: .above)
        var created = [WindowPayload]()
        ReaderWindows.restoreTabGroup(fixture.saved, in: fixture.state, behavior: .newTab) { created.append($0) }
        var windows = [NSWindow](), hosts = [WindowTabs.HostView](), states = [ReaderState]()
        defer {
            for host in hosts { host.removeFromSuperview() }
            for state in states { state.windowClosed() }
            for window in windows { window.close() }
            sibling.close()
        }
        for payload in created {
            let state = ReaderState(recordsHistory: false, restoring: payload)
            let window = NSWindow(contentRect: fixture.window.frame, styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            let host = WindowTabs.HostView()
            host.state = state; host.tabWith = payload.tabWith
            host.groupIdentifier = payload.tabIdentifier; host.openingPath = payload.path
            host.onWindowReady = { ReaderWindows.restoredWindowReady(window, payload: payload) }
            states.append(state); windows.append(window); hosts.append(host)
            window.contentView?.addSubview(host)
        }
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fixture.window.tabGroup?.windows, [fixture.window, sibling] + windows)
        XCTAssertTrue(fixture.window.tabGroup?.selectedWindow === windows[0])
    }

    func testRestoreReplaceCurrentReusesFirstDocumentAndAddsTheRestAsTabs() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var created = [WindowPayload]()
        ReaderWindows.restoreTabGroup(fixture.saved, in: fixture.state, behavior: .replaceCurrent) { created.append($0) }
        let deadline = Date().addingTimeInterval(5)
        while fixture.state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(fixture.state.error)
        XCTAssertEqual(fixture.state.document?.url.path, fixture.saved[0].path)
        XCTAssertEqual(fixture.state.tabColor, fixture.saved[0].tabColor)
        XCTAssertEqual(created.map(\.path), [fixture.saved[1].path])
        XCTAssertEqual(created.first?.tabWith, fixture.window.windowNumber)
    }

    func testSavedGroupReplacementCancelCreatesNoOtherTabs() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let reading = try nativePDFReadingFixture()
        fixture.state.document = reading
        let pages = try XCTUnwrap(fixture.state.nativePDF)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                               edits: [.contents("Keep this change")])
        try await fixture.state.nativePDFDidChange(pages)
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated { NSApp.stopModal(withCode: .alertThirdButtonReturn) }
        }
        var created = [WindowPayload]()
        ReaderWindows.restoreTabGroup(fixture.saved, in: fixture.state, behavior: .replaceCurrent) { created.append($0) }
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(fixture.state.document?.id, reading.id)
        XCTAssertTrue(fixture.state.modified)
        withExtendedLifetime(reading) {}
    }

    func testReusedSavedFirstTabRejectsAReplacementAfterItsBookmarkedOriginalWasDeleted() async throws {
        for behavior in [DocumentOpenBehavior.replaceCurrent, .newWindow] {
            let fixture = try Fixture(recordsHistory: true)
            defer { fixture.close() }
            if behavior == .newWindow { fixture.state.document = nil }
            let previousDocument = fixture.state.document?.id
            var payload = fixture.saved[0]
            payload.recordsHistory = true
            let original = URL(fileURLWithPath: try XCTUnwrap(payload.path))
            let moved = fixture.directory.url.appendingPathComponent("deleted-original.txt")
            payload.fileBookmark = try XCTUnwrap(DocumentFileIdentity.bookmark(for: original))
            try FileManager.default.moveItem(at: original, to: moved)
            try "Unrelated replacement".write(to: original, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: moved)
            var created = [WindowPayload]()
            ReaderWindows.restoreTabGroup([payload], in: fixture.state, behavior: behavior) { created.append($0) }
            fixture.window.orderOut(nil)
            try await waitUntilIdle(fixture.state)
            XCTAssertTrue(created.isEmpty, "Both replace and Home reuse keep the existing native window")
            XCTAssertEqual(fixture.state.document?.id, previousDocument,
                           "The replacement at the old pathname must never receive the saved book's position")
            XCTAssertEqual(fixture.state.missingFile, original)
            XCTAssertEqual(fixture.state.restoredPayload?.position?.zoom, payload.position?.zoom)
            XCTAssertNotNil(fixture.state.error)
        }
    }

    func testReusedSavedFirstTabFollowsMovedIdentityAndMigratesItsSavedAssociations() async throws {
        for behavior in [DocumentOpenBehavior.replaceCurrent, .newWindow] {
            let fixture = try Fixture(recordsHistory: true)
            defer { fixture.close() }
            if behavior == .newWindow { fixture.state.document = nil }
            var payload = fixture.saved[0]
            payload.recordsHistory = true
            let original = URL(fileURLWithPath: try XCTUnwrap(payload.path))
            let moved = fixture.directory.url.appendingPathComponent("moved-original.txt")
            payload.fileBookmark = try XCTUnwrap(DocumentFileIdentity.bookmark(for: original))
            let defaults = UserDefaults.standard
            let groupKey = "tabGroup:saved-identity-" + UUID().uuidString
            let keys = ["position:" + original.path, "position:" + moved.path, "pinnedDocuments", "bookmarks"]
                + defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("tabGroup:") }
            let previous = keys.map { defaults.object(forKey: $0) }
            defer {
                defaults.removeObject(forKey: groupKey)
                for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            }
            defaults.set(try JSONEncoder().encode(payload.position), forKey: "position:" + original.path)
            defaults.set([original.path], forKey: "pinnedDocuments")
            let mark = ReaderBookmark(title: "Saved book", path: original.path, position: try XCTUnwrap(payload.position),
                                      fileBookmark: payload.fileBookmark)
            defaults.set(try JSONEncoder().encode([mark]), forKey: "bookmarks")
            ReaderWindows.save([payload], key: groupKey)
            try FileManager.default.moveItem(at: original, to: moved)
            try "Unrelated replacement".write(to: original, atomically: true, encoding: .utf8)
            var created = [WindowPayload]()
            ReaderWindows.restoreTabGroup([payload], in: fixture.state, behavior: behavior) { created.append($0) }
            fixture.window.orderOut(nil)
            try await waitUntilIdle(fixture.state)
            XCTAssertTrue(created.isEmpty)
            XCTAssertNil(fixture.state.error)
            XCTAssertEqual(fixture.state.document?.url, moved)
            if case .text(let text) = fixture.state.document?.content { XCTAssertEqual(text, "Saved group book 0") }
            else { XCTFail("Expected the bookmarked original text") }
            XCTAssertEqual(fixture.state.zoom, payload.position?.zoom)
            XCTAssertNil(defaults.object(forKey: "position:" + original.path))
            let position = try JSONDecoder().decode(ReadingPosition.self,
                from: XCTUnwrap(defaults.data(forKey: "position:" + moved.path)))
            XCTAssertEqual(position, payload.position)
            XCTAssertEqual(ReaderFiles.pinned, [moved.path])
            let marks = try JSONDecoder().decode([ReaderBookmark].self, from: XCTUnwrap(defaults.data(forKey: "bookmarks")))
            XCTAssertEqual(marks.first?.path, moved.path)
            XCTAssertEqual(ReaderWindows.saved(groupKey).first?.path, moved.path)
        }
    }

    private func waitUntilIdle(_ state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        while state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
    }

    func testNativeShowTabBarMenuIsDisabledForFloatingChromeAndEnabledForNormalChrome() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        menu.addItem(item)
        let application = ReaderApplicationDelegate()
        fixture.state.immersiveControls = true
        application.routeNativeTabMenu(menu, for: fixture.window)
        XCTAssertTrue(item.target === fixture.closeGuard)
        XCTAssertFalse(item.isEnabled)
        fixture.state.immersiveControls = false
        menu.update()
        XCTAssertTrue(item.isEnabled)
    }

    func testNativeTabActionTargetsDocumentFirstResponderBeforeExistingWindowControllerAndRestoresChain() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let controller = DefaultTabController(window: fixture.window)
        fixture.window.nextResponder = controller
        let host = WindowTabs.HostView()
        host.state = fixture.state; host.openingPath = fixture.state.document?.url.path
        fixture.window.contentView?.addSubview(host)
        defer { host.removeFromSuperview() }
        let action = #selector(NSResponder.newWindowForTab(_:))
        let installed = try XCTUnwrap(fixture.window.delegate as? ReaderCloseGuard)
        XCTAssertTrue(fixture.window.nextResponder === installed)
        XCTAssertTrue(installed.nextResponder === controller, "Keep SwiftUI's original controller after the reader action owner")
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.makeFirstResponder(fixture.window)
        let target = NSApp.target(forAction: action, to: nil, from: fixture.window) as AnyObject?
        XCTAssertTrue(target === installed, "The native + must reach the document-first picker before the default scene creator")
        XCTAssertEqual(controller.newTabRequests, 0)
        host.removeFromSuperview()
        XCTAssertTrue(fixture.window.nextResponder === controller, "Detach restores only the responder link owned by this host")
        withExtendedLifetime(controller) {}
    }

    @MainActor private final class DefaultTabController: NSWindowController {
        var newTabRequests = 0
        override func newWindowForTab(_ sender: Any?) { newTabRequests += 1 }
    }

    func testNativeOverviewActionFindsApplicationResponderAndReleaseRestoresItsOriginalLink() throws {
        _ = NSApplication.shared
        let previous = NSApp.nextResponder
        weak var weakApplication: ReaderApplicationDelegate?
        defer {
            weakApplication?.removeTabResponder()
            NSApp.nextResponder = previous
        }
        // Drain the complete Objective-C interaction transaction before
        // checking lifetime, including installation and responder getters.
        autoreleasepool {
            var application: ReaderApplicationDelegate? = ReaderApplicationDelegate()
            weakApplication = application
            let picker = OverviewWindow(contentRect: CGRect(x: 2200, y: 100, width: 640, height: 480),
                                        styleMask: .borderless, backing: .buffered, defer: false)
            picker.isReleasedWhenClosed = false; picker.alphaValue = 0; picker.ignoresMouseEvents = true
            defer { picker.close() }
            application?.installTabResponder()
            XCTAssertTrue(NSApp.nextResponder === application)
            XCTAssertTrue(application?.nextResponder === previous)
            XCTAssertNil(picker.delegate); XCTAssertNil(picker.windowController); XCTAssertNil(picker.nextResponder)
            picker.makeKeyAndOrderFront(nil)
            picker.makeFirstResponder(picker)
            XCTAssertTrue((NSApp.target(forAction: #selector(NSResponder.newWindowForTab(_:)), to: nil, from: picker) as AnyObject?) === application,
                          "The native overview window has no document controller or delegate; its + needs the app responder")
            application = nil
        }
        XCTAssertNil(weakApplication)
        XCTAssertTrue(NSApp.nextResponder === previous, "Deinitializing the action owner must restore its unretained responder link")
    }

    @MainActor private final class OverviewWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func testNewTabUsesSelectedOverviewDocumentAndDismissesOverviewAfterChooserCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let sibling = NSWindow(contentRect: fixture.window.frame, styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        sibling.isReleasedWhenClosed = false; sibling.alphaValue = 0; sibling.ignoresMouseEvents = true
        sibling.tabbingIdentifier = fixture.window.tabbingIdentifier
        fixture.window.addTabbedWindow(sibling, ordered: .above)
        let group = try XCTUnwrap(fixture.window.tabGroup)
        defer { group.isOverviewVisible = false; sibling.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        group.selectedWindow = fixture.window
        // Complete fixture setup without depending on an unhosted XCTest
        // process owning the native picker as its key window.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                group.isOverviewVisible = true
            }, completionHandler: { continuation.resume() })
        }
        XCTAssertTrue(group.isOverviewVisible)
        XCTAssertTrue(ReaderWindows.newTabState === fixture.state,
                      "Overview ownership follows the native group's selected document")
        var requests = 0, created = [WindowPayload]()
        fixture.state.createWindow = { created.append($0) }
        ReaderMenuCommand.newTab.run(fixture.state, choose: { receive in
            XCTAssertFalse(group.isOverviewVisible, "The document owns its sheet after overview closes")
            requests += 1
            receive([])
        })
        let closingDeadline = Date().addingTimeInterval(3)
        while group.isOverviewVisible || requests == 0, Date() < closingDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(group.isOverviewVisible, "The native overview dismissal must finish after the chooser request")
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(created.isEmpty, "Cancelling the chooser must keep the two existing tabs")
        XCTAssertEqual(group.windows, [fixture.window, sibling])
    }

    func testDuplicateGroupNameCanCancelOrRenameWithoutOverwriting() throws {
        let fixture = try Fixture(recordsHistory: true)
        defer { fixture.close() }
        let name = "duplicate-" + UUID().uuidString, renamed = "renamed-" + UUID().uuidString
        let key = "tabGroup:" + name, renamedKey = "tabGroup:" + renamed
        ReaderWindows.save(fixture.saved, key: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: renamedKey)
        }
        let original = UserDefaults.standard.data(forKey: key)
        respondToDialogs([
            { window in
                (window?.initialFirstResponder as? NSTextField)?.stringValue = name
                return .alertFirstButtonReturn
            },
            { _ in .alertThirdButtonReturn }
        ]) { fixture.state.saveTabGroup() }
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
        respondToDialogs([
            { window in
                (window?.initialFirstResponder as? NSTextField)?.stringValue = name
                return .alertFirstButtonReturn
            },
            { _ in .alertSecondButtonReturn },
            { window in
                (window?.initialFirstResponder as? NSTextField)?.stringValue = renamed
                return .alertFirstButtonReturn
            }
        ]) { fixture.state.saveTabGroup() }
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
        XCTAssertEqual(ReaderWindows.saved(renamedKey).map(\.path), [fixture.state.document?.url.path])
    }

    func testDuplicateGroupNameReplaceSavesCurrentPayloadAndPreservesOtherGroups() throws {
        let fixture = try Fixture(recordsHistory: true)
        defer { fixture.close() }
        let name = "replace-" + UUID().uuidString
        let key = "tabGroup:" + name, otherKey = "tabGroup:" + name + "-other"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: otherKey)
        }
        ReaderWindows.save(fixture.saved, key: key)
        ReaderWindows.save([fixture.saved[1]], key: otherKey)
        let original = try XCTUnwrap(UserDefaults.standard.data(forKey: key))
        let otherOriginal = try XCTUnwrap(UserDefaults.standard.data(forKey: otherKey))
        fixture.state.zoom = 1.75
        fixture.state.tabColor = 0x123456
        let currentPath = try XCTUnwrap(fixture.state.document?.url.path)
        let currentPosition = try XCTUnwrap(fixture.state.filePosition)
        var answeredDialogs = 0
        respondToDialogs([
            { window in
                answeredDialogs += 1
                let field = window?.initialFirstResponder as? NSTextField
                XCTAssertNotNil(field)
                field?.stringValue = name
                return .alertFirstButtonReturn
            },
            { _ in
                answeredDialogs += 1
                return .alertFirstButtonReturn
            }
        ]) { fixture.state.saveTabGroup() }
        XCTAssertEqual(answeredDialogs, 2, "Saving an existing name must ask before replacing its group")
        XCTAssertNotEqual(UserDefaults.standard.data(forKey: key), original)
        let replacement = ReaderWindows.saved(key)
        XCTAssertEqual(replacement.count, 1)
        XCTAssertEqual(replacement.first?.path, currentPath)
        XCTAssertEqual(replacement.first?.position, currentPosition)
        XCTAssertEqual(replacement.first?.tabColor, 0x123456)
        XCTAssertEqual(replacement.first?.selected, true)
        XCTAssertEqual(replacement.first?.active, true)
        XCTAssertEqual(UserDefaults.standard.data(forKey: otherKey), otherOriginal)
    }

    private func respondToDialogs(_ responses: [(NSWindow?) -> NSApplication.ModalResponse],
                                  perform action: () -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var index = 0
        var lastAnsweredWindow: NSWindow?
        func answer(_ response: NSApplication.ModalResponse) {
            NSApp.stopModal(withCode: response)
            // stopModal returns control after AppKit processes the next event.
            // An observer runs before waiting, so supply that event explicitly.
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
            NSApp.postEvent(event, atStart: true)
        }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, window !== lastAnsweredWindow,
                      index < responses.count else { return }
                // A stopped modal may iterate again before runModal returns.
                // Consume another answer only after the actual modal changes.
                lastAnsweredWindow = window
                let response = responses[index](window)
                index += 1
                answer(response)
            }
        }!
        let mode = CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode)
        let timeout = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTFail("Timed out answering saved-group dialogs (answered \(index) of \(responses.count))", file: file, line: line)
                answer(.alertThirdButtonReturn)
            }
        }
        RunLoop.main.add(timeout, forMode: .modalPanel)
        defer {
            timeout.invalidate()
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, mode)
            CFRunLoopObserverInvalidate(observer)
        }
        action()
        XCTAssertEqual(index, responses.count, "Every expected saved-group dialog must be shown", file: file, line: line)
    }

    @MainActor private final class Fixture {
        let directory: TemporaryDirectory
        let state: ReaderState
        let window: NSWindow
        let closeGuard: ReaderCloseGuard
        let saved: [WindowPayload]
        private let arguments: [String: Any]
        private let history: [(String, Any?)]
        private let recentURLs: [URL]

        init(recordsHistory: Bool = false) throws {
            _ = NSApplication.shared
            history = ["documentOpenHistory", "closedDocuments", "session"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
            recentURLs = NSDocumentController.shared.recentDocumentURLs
            arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(arguments.merging([
                "disableTabs": false, "disableHistory": !recordsHistory, "disableReadingState": true
            ]) { _, fixture in fixture }, forName: UserDefaults.argumentDomain)
            directory = try TemporaryDirectory()
            let savedDirectory = directory.url
            saved = try (0..<2).map { index in
                let url = savedDirectory.appendingPathComponent("saved-\(index).txt")
                try "Saved group book \(index)".write(to: url, atomically: true, encoding: .utf8)
                var payload = WindowPayload(path: url.path, position: .init(page: 0, zoom: 1.2 + Double(index)))
                payload.selected = index == 0; payload.active = index == 0; payload.tabColor = 0x654321
                return payload
            }
            state = ReaderState(recordsHistory: recordsHistory)
            state.document = ReadingDocument(url: directory.url.appendingPathComponent("current.txt"), content: .text("Current"))
            state.createWindow = { _ in }
            window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            window.tabbingIdentifier = "saved-group-current-" + UUID().uuidString
            state.window = window
            closeGuard = ReaderCloseGuard(state: state, previous: nil)
            window.delegate = closeGuard
        }

        func close() {
            _ = ReaderWindows.prepareRestoration([])
            state.windowClosed(); window.delegate = nil; window.close()
            ReaderFiles.setRecent(recentURLs)
            for (key, value) in history { UserDefaults.standard.set(value, forKey: key) }
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
