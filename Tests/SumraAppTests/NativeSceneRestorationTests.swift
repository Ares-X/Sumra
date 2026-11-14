#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

/// Real scene identity, tab assembly and document loading only. Offscreen
/// windows do not establish fullscreen or macOS Space restoration acceptance.
@MainActor
final class NativeSceneRestorationTests: XCTestCase {
    func testSessionKeepsMountedSceneIdentityAndCurrentReadingPosition() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.document("current.txt")
        var payload = WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.1))
        payload.tabIdentifier = "Scene-Identity-" + UUID().uuidString
        let scene = fixture.mount(payload)
        try await fixture.waitUntil("The real document scene did not load") {
            scene.state?.document?.url == url && scene.state?.busy == false
        }
        let state = try XCTUnwrap(scene.state)
        XCTAssertEqual(state.zoom, 1.1)
        state.zoom = 1.8
        let current = try XCTUnwrap(state.filePosition)
        XCTAssertNotEqual(current.zoom, payload.position?.zoom)

        ReaderWindows.saveSession([state])
        let session = ReaderWindows.saved("session")
        XCTAssertEqual(session.count, 1)
        let saved = try XCTUnwrap(session.first)
        XCTAssertEqual(saved.id, scene.payload.value.id,
                       "The application session and macOS scene must identify the same reader window")
        XCTAssertEqual(saved.path, url.path)
        XCTAssertEqual(saved.position, current,
                       "Reusing scene identity must still snapshot the live reading position")
    }

    func testNativeScenesUseLatestSessionAndKeepBackgroundDocumentDormantUntilSelected() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let urls = try ["background.txt", "active.txt"].map(fixture.document)
        let groupIdentifier = "Scene-Restore-" + UUID().uuidString
        var saved = urls.enumerated().map {
            WindowPayload(path: $0.element.path, position: ReadingPosition(page: 0, zoom: $0.offset == 0 ? 1.7 : 1.5))
        }
        for index in saved.indices { saved[index].tabIdentifier = groupIdentifier }
        saved[1].selected = true
        saved[1].active = true

        // macOS retains an earlier Codable scene value. Its UUID survives, but
        // transient `restoring` does not; its position/group/selection may be old.
        var native = saved
        for index in native.indices {
            native[index].position = ReadingPosition(page: 0, zoom: 1.1)
            native[index].tabIdentifier = "Old-Scene-" + UUID().uuidString
            native[index].selected = index == 0
            native[index].active = index == 0
            native[index].restoring = true
        }
        native = try JSONDecoder().decode([WindowPayload].self, from: JSONEncoder().encode(native))
        XCTAssertTrue(native.allSatisfy { !$0.restoring })
        XCTAssertEqual(native.map(\.id), saved.map(\.id))
        SumraApp.restoring = ReaderWindows.prepareRestoration(saved)
        XCTAssertEqual(SumraApp.restoring.first?.id, saved[1].id)

        let active = fixture.mount(native[1])
        try await fixture.waitUntil("The active native scene did not load") {
            active.state?.document?.url == urls[1] && active.state?.busy == false
        }
        XCTAssertTrue(ReaderWindows.isRestoringWindows, "The remaining native scene is still pending")
        // Simulate the startup default-window requests having been consumed.
        // A later native scene still needs the restoration owner's latest data.
        SumraApp.restoring = []
        let background = fixture.mount(native[0])
        try await fixture.waitUntil("Native scene restoration did not finish") {
            !ReaderWindows.isRestoringWindows && background.state != nil
        }
        let backgroundState = try XCTUnwrap(background.state)
        let activeState = try XCTUnwrap(active.state)
        let group = try XCTUnwrap(active.window.tabGroup)
        XCTAssertEqual(group.windows, [background.window, active.window])
        XCTAssertTrue(group.selectedWindow === active.window)
        XCTAssertEqual(background.window.tabbingIdentifier, groupIdentifier)
        XCTAssertEqual(active.window.tabbingIdentifier, groupIdentifier)
        XCTAssertEqual(activeState.zoom, 1.5, "The latest application position wins over the stale native scene")
        XCTAssertEqual(backgroundState.restoredPayload?.position, saved[0].position)
        XCTAssertNil(backgroundState.document)
        XCTAssertFalse(backgroundState.busy)
        XCTAssertEqual(backgroundState.generation, 0)

        // Deliver the mounted HostView's real activation observer without
        // ordering a host desktop window or entering a native Space.
        group.selectedWindow = background.window
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: background.window)
        try await fixture.waitUntil("Selecting the background tab did not load its saved document") {
            backgroundState.document?.url == urls[0] && !backgroundState.busy
        }
        XCTAssertEqual(backgroundState.zoom, 1.7)
        XCTAssertEqual(group.windows, [background.window, active.window])
        XCTAssertTrue(group.selectedWindow === background.window)
        XCTAssertTrue(backgroundState.window === background.window)
        XCTAssertTrue(activeState.window === active.window)
    }

    func testNativeScenePlacementWaitsForSystemRestorationToFinish() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let urls = try ["background.txt", "active.txt"].map(fixture.document)
        let identifier = "System-Restore-" + UUID().uuidString
        var saved = urls.map { WindowPayload(path: $0.path, position: ReadingPosition(page: 0, zoom: 1.5)) }
        for index in saved.indices { saved[index].tabIdentifier = identifier }
        saved[1].selected = true
        saved[1].active = true
        let requests = ReaderWindows.prepareRestoration(saved)
        ReaderWindows.isRestoringNativeWindows = true
        fixture.application.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
        let active = fixture.mount(requests[0])
        let background = fixture.mount(requests[1])
        try await fixture.waitUntil("The native delegates did not attach") {
            background.state != nil && active.state != nil
        }
        await Task.yield()
        let activeState = try XCTUnwrap(active.state)
        let backgroundState = try XCTUnwrap(background.state)
        XCTAssertTrue(ReaderWindows.isRestoringNativeWindows)
        XCTAssertTrue(ReaderWindows.isRestoringWindows)
        XCTAssertNil(activeState.document)
        XCTAssertFalse(activeState.busy)
        XCTAssertEqual(activeState.generation, 0)
        XCTAssertEqual(active.window.tabGroup?.windows ?? [active.window], [active.window],
                       "The app must leave native tab-stack assembly to macOS until its restoration notification")
        XCTAssertEqual(background.window.tabGroup?.windows ?? [background.window], [background.window])
        XCTAssertNil(backgroundState.document)
        XCTAssertFalse(backgroundState.busy)
        XCTAssertEqual(backgroundState.generation, 0)

        // Exercise the application notification and deferred native placement.
        // This checks the handoff boundary without simulating fullscreen/Spaces.
        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        try await fixture.waitUntil("System restoration completion did not assemble the pending scenes") {
            !ReaderWindows.isRestoringNativeWindows && !ReaderWindows.isRestoringWindows &&
                active.window.tabGroup?.windows == [background.window, active.window] &&
                activeState.document?.url == urls[1] && !activeState.busy
        }
        let group = try XCTUnwrap(active.window.tabGroup)
        XCTAssertTrue(group.selectedWindow === active.window)
        XCTAssertEqual(activeState.document?.url, urls[1])
        XCTAssertFalse(activeState.busy)
        XCTAssertEqual(activeState.zoom, 1.5)
        XCTAssertNil(backgroundState.document)
        XCTAssertFalse(backgroundState.busy)
        XCTAssertEqual(backgroundState.generation, 0)
    }

    func testLateNativeBindingIdentitiesReplaceDefaultScenesForTheSameDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.document("same-document.txt")
        let identifier = "Late-Native-Identity-" + UUID().uuidString
        var saved = [WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.7)),
                     WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.5))]
        for index in saved.indices { saved[index].tabIdentifier = identifier }
        saved[1].selected = true
        saved[1].active = true
        SumraApp.restoring = ReaderWindows.prepareRestoration(saved)
        ReaderWindows.isRestoringNativeWindows = true
        fixture.application.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
        let first = fixture.mount(SumraApp.defaultWindowPayload())
        let second = fixture.mount(SumraApp.defaultWindowPayload())
        XCTAssertEqual(first.payload.value.id, saved[1].id)
        XCTAssertEqual(second.payload.value.id, saved[0].id)
        try await fixture.waitUntil("The provisional native scene delegates did not attach") {
            first.state != nil && second.state != nil
        }
        await Task.yield()
        for scene in [first, second] {
            XCTAssertNil(scene.state?.document)
            XCTAssertFalse(try XCTUnwrap(scene.state).busy)
            XCTAssertEqual(scene.state?.generation, 0)
        }

        // AppKit's real native group already owns these windows and their order.
        // No fullscreen state or Space is synthesized by this offscreen fixture.
        first.window.addTabbedWindow(second.window, ordered: .above)
        let group = try XCTUnwrap(first.window.tabGroup)
        XCTAssertEqual(group.windows, [first.window, second.window])
        var native = saved
        for index in native.indices { native[index].position = ReadingPosition(page: 0, zoom: 1.1) }
        native = try JSONDecoder().decode([WindowPayload].self, from: JSONEncoder().encode(native))
        XCTAssertTrue(native.allSatisfy { !$0.restoring })

        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        // Native restoration delivers the real bindings after the notification.
        // Keep the path unchanged to exercise identity, rather than a path-task restart.
        first.payload.value = native[0]
        second.payload.value = native[1]
        first.host.layoutSubtreeIfNeeded()
        second.host.layoutSubtreeIfNeeded()
        try await fixture.waitUntil("The final native scene identities did not finish restoration") {
            !ReaderWindows.isRestoringWindows &&
                (first.window.delegate as? ReaderCloseGuard)?.restorationID == saved[0].id &&
                (second.window.delegate as? ReaderCloseGuard)?.restorationID == saved[1].id &&
                second.state?.document?.url == url && second.state?.busy == false
        }
        let background = try XCTUnwrap(first.state)
        let active = try XCTUnwrap(second.state)
        XCTAssertEqual(first.payload.value.id, saved[0].id)
        XCTAssertEqual(second.payload.value.id, saved[1].id)
        XCTAssertEqual(group.windows, [first.window, second.window])
        XCTAssertTrue(group.selectedWindow === second.window)
        XCTAssertTrue(background.window === first.window)
        XCTAssertTrue(active.window === second.window)
        XCTAssertEqual(active.zoom, 1.5)
        XCTAssertEqual(background.restoredPayload?.position, saved[0].position)
        XCTAssertNil(background.document)
        XCTAssertFalse(background.busy)
        XCTAssertEqual(background.generation, 0)
    }

    func testLegacyNativeIdentitiesArrivingAfterRestorationReplaceTheUnrelatedSavedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.document("late-legacy.txt")
        let identifier = "Late-Legacy-Identity-" + UUID().uuidString
        var saved = [WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.7)),
                     WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.5))]
        for index in saved.indices { saved[index].tabIdentifier = identifier }
        saved[1].selected = true
        saved[1].active = true
        SumraApp.restoring = ReaderWindows.prepareRestoration(saved)
        ReaderWindows.isRestoringNativeWindows = true
        fixture.application.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
        let first = fixture.mount(SumraApp.defaultWindowPayload())
        let second = fixture.mount(SumraApp.defaultWindowPayload())
        try await fixture.waitUntil("The provisional legacy scene delegates did not attach") {
            first.state != nil && second.state != nil
        }
        await Task.yield()
        for scene in [first, second] {
            XCTAssertNil(scene.state?.document)
            XCTAssertEqual(scene.state?.generation, 0)
        }
        first.window.addTabbedWindow(second.window, ordered: .above)
        let group = try XCTUnwrap(first.window.tabGroup)
        XCTAssertEqual(group.windows, [first.window, second.window])
        var opened = [WindowPayload]()
        fixture.application.installWindowOpener { opened.append($0) }
        fixture.application.finishLaunching()
        await Task.yield()
        XCTAssertTrue(opened.isEmpty)

        // Old releases saved UUIDs unrelated to either real native scene.
        // Both native values arrive after the system's completion notification.
        var native = [WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.1)),
                      WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.2))]
        for index in native.indices { native[index].tabIdentifier = identifier }
        native = try JSONDecoder().decode([WindowPayload].self, from: JSONEncoder().encode(native))
        XCTAssertTrue(native.allSatisfy { !$0.restoring })
        XCTAssertTrue(Set(native.map(\.id)).isDisjoint(with: Set(saved.map(\.id))))
        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        first.payload.value = native[0]
        second.payload.value = native[1]
        first.host.layoutSubtreeIfNeeded()
        second.host.layoutSubtreeIfNeeded()
        try await fixture.waitUntil("Late legacy scene identities left the unrelated application session pending") {
            !ReaderWindows.isRestoringWindows &&
                (first.window.delegate as? ReaderCloseGuard)?.restorationID == native[0].id &&
                (second.window.delegate as? ReaderCloseGuard)?.restorationID == native[1].id &&
                first.state?.document?.url == url && first.state?.busy == false &&
                second.state?.document?.url == url && second.state?.busy == false
        }
        XCTAssertTrue(opened.isEmpty, "Late legacy scenes must not duplicate windows from the unrelated saved session")
        XCTAssertTrue(SumraApp.restoring.isEmpty)
        XCTAssertEqual(first.payload.value.id, native[0].id)
        XCTAssertEqual(second.payload.value.id, native[1].id)
        XCTAssertEqual(first.state?.zoom, 1.1)
        XCTAssertEqual(second.state?.zoom, 1.2)
        XCTAssertEqual(group.windows, [first.window, second.window])
        XCTAssertTrue(first.state?.window === first.window)
        XCTAssertTrue(second.state?.window === second.window)
    }

    func testOrdinaryWindowAfterStartupPreservesLaterManualTabRestoration() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        ReaderWindows.isRestoringNativeWindows = true
        fixture.application.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        XCTAssertFalse(ReaderWindows.isRestoringNativeWindows)
        XCTAssertFalse(ReaderWindows.isRestoringWindows)

        let urls = try ["manual-background.txt", "manual-active.txt"].map(fixture.document)
        let identifier = "Manual-Restore-" + UUID().uuidString
        var saved = urls.map { WindowPayload(path: $0.path, position: ReadingPosition(page: 0, zoom: 1.6)) }
        for index in saved.indices { saved[index].tabIdentifier = identifier }
        saved[1].selected = true
        saved[1].active = true
        let requests = ReaderWindows.prepareRestoration(saved)
        XCTAssertTrue(SumraApp.restoring.isEmpty, "Manual restoration is independent of the startup plan")

        let ordinaryURL = try fixture.document("ordinary-after-startup.txt")
        var ordinaryPayload = WindowPayload(path: ordinaryURL.path)
        ordinaryPayload.tabIdentifier = "Ordinary-" + UUID().uuidString
        let ordinary = fixture.mount(ordinaryPayload)
        try await fixture.waitUntil("The ordinary post-startup document did not load") {
            ordinary.state?.document?.url == ordinaryURL && ordinary.state?.busy == false
        }
        XCTAssertTrue(ReaderWindows.isRestoringWindows,
                      "A later ordinary scene must not discard a manual tab-restoration queue")
        for request in requests {
            XCTAssertEqual(ReaderWindows.pendingRestoration(for: request.id)?.id, request.id)
        }

        let active = fixture.mount(requests[0])
        let background = fixture.mount(requests[1])
        try await fixture.waitUntil("The manual tab group did not finish restoring after an ordinary window opened") {
            !ReaderWindows.isRestoringWindows && active.state?.document?.url == urls[1] && active.state?.busy == false &&
                active.window.tabGroup?.windows == [background.window, active.window]
        }
        XCTAssertTrue(active.window.tabGroup?.selectedWindow === active.window)
        XCTAssertEqual(active.state?.zoom, 1.6)
        XCTAssertNil(background.state?.document)
        XCTAssertEqual(background.state?.generation, 0)
        XCTAssertEqual(ordinary.state?.document?.url, ordinaryURL)
        XCTAssertEqual(ordinary.window.tabGroup?.windows ?? [ordinary.window], [ordinary.window])
    }

    func testDefaultWindowRequestsIssueSavedIdentitiesOnceAndPreserveTheRestorationPlan() {
        let restoring = SumraApp.restoring
        defer { SumraApp.restoring = restoring }
        let saved = [WindowPayload(path: "/saved-first.txt"), WindowPayload(path: "/saved-second.txt")]
        SumraApp.restoring = saved
        let first = SumraApp.defaultWindowPayload()
        let second = SumraApp.defaultWindowPayload()
        XCTAssertEqual([first.id, second.id], saved.map(\.id))
        XCTAssertEqual(SumraApp.restoring.map(\.id), saved.map(\.id),
                       "Default-value evaluation must preserve requests until actual startup scenes are known")

        let firstHome = SumraApp.defaultWindowPayload()
        let secondHome = SumraApp.defaultWindowPayload()
        XCTAssertNil(firstHome.path)
        XCTAssertNil(secondHome.path)
        XCTAssertEqual(Set([first.id, second.id, firstHome.id, secondHome.id]).count, 4,
                       "Every default scene request must receive a unique identity after issuing the saved windows")
    }

    func testEvaluatedDefaultWithoutMountedSceneRemainsPendingForStartupDelivery() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let urls = try ["first.txt", "second.txt"].map(fixture.document)
        let requests = ReaderWindows.prepareRestoration(urls.map { WindowPayload(path: $0.path) })
        SumraApp.restoring = requests
        let evaluated = SumraApp.defaultWindowPayload()
        XCTAssertEqual(evaluated.id, requests[0].id)
        // SwiftUI may evaluate a default without mounting its ReaderWindow.
        // Only an actually recorded scene can remove this request from delivery.
        ReaderWindows.isRestoringNativeWindows = true
        fixture.application.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
        var opened = [WindowPayload]()
        fixture.application.installWindowOpener { opened.append($0) }
        fixture.application.finishLaunching()
        await Task.yield()
        XCTAssertTrue(opened.isEmpty)

        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        try await fixture.waitUntil("The evaluated but unmounted default request was lost during startup") {
            opened.count == requests.count
        }
        XCTAssertEqual(opened.map(\.id), requests.map(\.id))
        XCTAssertEqual(Set(opened.map(\.id)).count, requests.count)
        XCTAssertTrue(SumraApp.restoring.isEmpty)
        fixture.application.finishLaunching()
        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        await Task.yield()
        XCTAssertEqual(opened.map(\.id), requests.map(\.id), "Unmounted defaults must be delivered once")
    }

    func testOldNativeSceneIdentityKeepsItsDocumentWithoutDuplicatingTheSavedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.document("old-native.txt")
        let saved = WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.7))
        SumraApp.restoring = ReaderWindows.prepareRestoration([saved])
        ReaderWindows.isRestoringNativeWindows = true
        fixture.application.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
        var opened = [WindowPayload]()
        fixture.application.installWindowOpener { opened.append($0) }
        fixture.application.finishLaunching()

        // Old releases saved unrelated UUIDs. Matching this path must not map
        // the native scene onto a different saved window or open a duplicate.
        let native = WindowPayload(path: url.path, position: ReadingPosition(page: 0, zoom: 1.1))
        XCTAssertNotEqual(native.id, saved.id)
        let scene = fixture.mount(native)
        try await fixture.waitUntil("The old native scene did not load its own document") {
            scene.state?.document?.url == url && scene.state?.busy == false
        }
        let state = try XCTUnwrap(scene.state)
        let documentID = try XCTUnwrap(state.document?.id)
        let generation = state.generation
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(ReaderWindows.isRestoringWindows)

        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        try await fixture.waitUntil("The old unmatched application session remained pending") {
            !ReaderWindows.isRestoringNativeWindows && !ReaderWindows.isRestoringWindows && SumraApp.restoring.isEmpty
        }
        await Task.yield()
        XCTAssertTrue(opened.isEmpty, "The native reader takes precedence over stale application-session identities")
        XCTAssertEqual(state.document?.id, documentID)
        XCTAssertEqual(state.document?.url, url)
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.zoom, 1.1)
        XCTAssertEqual(scene.payload.value.id, native.id)
    }

    func testStartupCallbackOrdersCreateOnlyUnseenSavedScenesOnce() async throws {
        let orders: [[StartupEvent]] = [
            [.nativeRestoration, .windowOpener, .launch], [.nativeRestoration, .launch, .windowOpener],
            [.windowOpener, .nativeRestoration, .launch], [.windowOpener, .launch, .nativeRestoration],
            [.launch, .nativeRestoration, .windowOpener], [.launch, .windowOpener, .nativeRestoration]
        ]
        for order in orders {
            let fixture = try Fixture()
            defer { fixture.close() }
            let urls = try ["first.txt", "active.txt", "last.txt"].map(fixture.document)
            let identifier = "Startup-Order-" + UUID().uuidString
            var saved = urls.map { WindowPayload(path: $0.path, position: ReadingPosition(page: 0, zoom: 1.5)) }
            for index in saved.indices { saved[index].tabIdentifier = identifier }
            saved[1].selected = true
            saved[1].active = true
            let requests = ReaderWindows.prepareRestoration(saved)
            SumraApp.restoring = requests
            ReaderWindows.isRestoringNativeWindows = true
            fixture.application.applicationWillFinishLaunching(
                Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
            let active = fixture.mount(requests[0])
            try await fixture.waitUntil("The already-present startup scene did not attach") {
                active.state != nil
            }
            await Task.yield()
            XCTAssertNil(active.state?.document)
            XCTAssertFalse(try XCTUnwrap(active.state).busy)
            XCTAssertEqual(active.state?.generation, 0)
            var opened = [WindowPayload]()
            for (index, event) in order.enumerated() {
                switch event {
                case .nativeRestoration:
                    NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
                case .windowOpener:
                    fixture.application.installWindowOpener { [weak fixture] payload in
                        opened.append(payload)
                        fixture?.mount(payload)
                    }
                case .launch:
                    fixture.application.finishLaunching()
                }
                // Opener registration schedules its handoff on the main actor.
                await Task.yield()
                if index < order.count - 1 {
                    XCTAssertTrue(opened.isEmpty, "Startup opened a scene before all callbacks arrived: \(order)")
                }
            }
            try await fixture.waitUntil("Startup did not hand off the two unseen saved scenes: \(order)") {
                opened.count == 2 && !ReaderWindows.isRestoringWindows &&
                    active.state?.document?.url == urls[1] && active.state?.busy == false
            }
            let expected = requests.filter { $0.id != requests[0].id }
            XCTAssertEqual(opened.map(\.id), expected.map(\.id))
            XCTAssertEqual(Set(opened.map(\.id)).count, 2)
            XCTAssertTrue(SumraApp.restoring.isEmpty)
            XCTAssertEqual(active.state?.document?.url, urls[1])

            fixture.application.finishLaunching()
            NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
            await Task.yield()
            XCTAssertEqual(opened.map(\.id), expected.map(\.id), "Repeated callbacks must not hand off saved windows again")
        }
    }

    func testFinderOpenWaitsForNativeRestorationBeforeHandingOffItsFile() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.document("finder.txt")
        ReaderWindows.isRestoringNativeWindows = true
        fixture.application.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp))
        var opened = [WindowPayload]()
        fixture.application.installWindowOpener { opened.append($0) }
        fixture.application.finishLaunching()
        fixture.application.application(NSApp, open: [url])
        await Task.yield()
        XCTAssertTrue(opened.isEmpty, "Finder must not create a document scene during native window restoration")
        XCTAssertTrue(ReaderWindows.isRestoringNativeWindows)

        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        try await fixture.waitUntil("The queued Finder file was not handed off after native restoration") {
            opened.count == 1
        }
        XCTAssertFalse(ReaderWindows.isRestoringNativeWindows)
        XCTAssertEqual(opened.first?.path, url.path)
        fixture.application.finishLaunching()
        NotificationCenter.default.post(name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        await Task.yield()
        XCTAssertEqual(opened.count, 1, "The queued Finder request must be consumed once")
    }

    private enum StartupEvent {
        case nativeRestoration, windowOpener, launch
    }

    @MainActor private final class Window: NSWindow {
        override func makeKeyAndOrderFront(_ sender: Any?) {
            // WindowServer focus and fullscreen behavior belong to GUI acceptance.
        }
    }

    @MainActor private final class PayloadStore: ObservableObject {
        @Published var value: WindowPayload
        init(_ value: WindowPayload) { self.value = value }
    }

    @MainActor private struct SceneRoot: View {
        @ObservedObject var store: PayloadStore
        let application: ReaderApplicationDelegate

        var body: some View {
            ReaderScene(payload: $store.value, application: application)
        }
    }

    @MainActor private final class Scene {
        let payload: PayloadStore
        let window: Window
        let host: NSHostingView<SceneRoot>
        var state: ReaderState? { (window.delegate as? ReaderCloseGuard)?.state }

        init(_ request: WindowPayload, application: ReaderApplicationDelegate) {
            let store = PayloadStore(request)
            payload = store
            host = NSHostingView(rootView: SceneRoot(store: store, application: application))
            window = Window(contentRect: CGRect(x: 2400, y: 100, width: 800, height: 600),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = host
        }
    }

    @MainActor private final class Fixture {
        let application: ReaderApplicationDelegate
        private let directory: TemporaryDirectory
        private let arguments: [String: Any]
        private let previous: [(String, Any?)]
        private let recent: [URL]
        private let capture: (() -> Void)?
        private let restoring: [WindowPayload]
        private let restoringNativeWindows: Bool
        private let terminating: Bool
        private let automaticTabbing: Bool
        private var scenes = [Scene]()

        init() throws {
            _ = NSApplication.shared
            // Private pending-window state has no snapshot API. Never replace
            // another test's in-flight restoration; this fixture owns an empty queue.
            guard !ReaderWindows.isRestoringWindows, !ReaderWindows.isRestoringNativeWindows else {
                throw XCTSkip("Another native window restoration is already pending")
            }
            directory = try TemporaryDirectory()
            let defaults = UserDefaults.standard
            arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            previous = ["session", "documentOpenHistory", "closedDocuments"].map { ($0, defaults.object(forKey: $0)) }
            recent = NSDocumentController.shared.recentDocumentURLs
            capture = ScreenshotHotkey.capture
            restoring = SumraApp.restoring
            restoringNativeWindows = ReaderWindows.isRestoringNativeWindows
            terminating = ReaderWindows.isTerminating
            automaticTabbing = NSWindow.allowsAutomaticWindowTabbing
            var overrides = arguments.merging([
                "disableHistory": false, "disableReadingState": true, "disableTabs": false,
                "restoreSession": true, "showContentsOnOpen": false,
                "documentOpenHistory": Data("{}".utf8), "pinnedDocuments": [String](),
                "pageAspectLayout": false, "automaticLayout": false,
                "immersiveControls": false, "toolbarDisplayMode": "shown"
            ]) { _, fixture in fixture }
            overrides.removeValue(forKey: "session")
            defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
            SumraApp.restoring = []
            ReaderWindows.isRestoringNativeWindows = false
            ReaderWindows.isTerminating = false
            NSWindow.allowsAutomaticWindowTabbing = true
            application = ReaderApplicationDelegate()
        }

        func document(_ name: String) throws -> URL {
            let url = directory.url.appendingPathComponent(name)
            try ("Real scene restoration fixture: " + name).write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        @discardableResult func mount(_ payload: WindowPayload) -> Scene {
            let scene = Scene(payload, application: application)
            scenes.append(scene)
            return scene
        }

        func waitUntil(_ message: String, _ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                for scene in scenes { scene.host.layoutSubtreeIfNeeded() }
                if condition() { return }
                let errors = scenes.compactMap { $0.state?.error }
                if !errors.isEmpty {
                    XCTFail("\(message): \(errors.joined(separator: "; "))", line: line)
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            XCTFail(message, line: line)
            throw CancellationError()
        }

        func close() {
            _ = ReaderWindows.prepareRestoration([])
            for scene in scenes {
                if let state = scene.state, !state.isWindowClosed {
                    state.createWindow = nil
                    state.windowClosed()
                }
                scene.window.makeFirstResponder(nil)
                scene.window.contentView = nil
                scene.window.delegate = nil
                scene.window.orderOut(nil)
                scene.window.close()
            }
            scenes.removeAll()
            ReaderWindows.finishNativeRestoration()
            application.removeTabResponder()
            NotificationCenter.default.removeObserver(application)
            ReaderFiles.setRecent(recent)
            ScreenshotHotkey.capture = capture
            SumraApp.restoring = restoring
            ReaderWindows.isRestoringNativeWindows = restoringNativeWindows
            ReaderWindows.isTerminating = terminating
            NSWindow.allowsAutomaticWindowTabbing = automaticTabbing
            let defaults = UserDefaults.standard
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            for (key, value) in previous { defaults.set(value, forKey: key) }
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
