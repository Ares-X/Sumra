#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class NativeTabMenuLifecycleTests: XCTestCase {
    func testMountedViewMenuRoutesTabBarInsertedAfterTrackingBegan() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        XCTAssertTrue(NSApp.keyWindow === fixture.window)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: fixture.mainMenu)

        // AppKit adds native tab commands while preparing the View submenu,
        // after tracking has already begun on the main menu.
        let item = fixture.addTabBarItem()
        XCTAssertTrue(item.target === fixture.closeGuard)
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.title, L("Show Tab Bar"))
        XCTAssertEqual(fixture.unrelatedCommand.validations, 0,
                       "Inserting the native item must not revalidate other menu commands")
    }

    func testMountedViewMenuRoutesReplacementAndNativeEnabledStateChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        XCTAssertTrue(NSApp.keyWindow === fixture.window)
        let oldItem = fixture.addTabBarItem()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: fixture.mainMenu)
        fixture.viewMenu.removeItem(oldItem)

        let replacement = fixture.addTabBarItem()
        XCTAssertTrue(replacement.target === fixture.closeGuard)
        XCTAssertFalse(replacement.isEnabled)
        XCTAssertEqual(replacement.title, L("Show Tab Bar"))

        // Resetting target alone is not an NSMenu appearance notification.
        // The native menu's subsequent title/enabled update must reroute it.
        replacement.target = nil
        replacement.title = "Hide Tab Bar"
        replacement.isEnabled = true
        XCTAssertTrue(replacement.target === fixture.closeGuard)
        XCTAssertFalse(replacement.isEnabled)
        XCTAssertEqual(replacement.title, L("Show Tab Bar"), "A native title rewrite must not override shared-strip state")

        fixture.state.immersiveControls = false
        fixture.viewMenu.update()
        XCTAssertTrue(replacement.isEnabled, "Normal single-tab chrome retains the shared tab-bar command")
        fixture.state.immersiveControls = true
        fixture.viewMenu.update()
        XCTAssertFalse(replacement.isEnabled, "Validation reads current reader chrome after a mode change")
    }

    func testRoutedTabBarTitleFollowsStandaloneChoiceAndCannotHideMultipleTabs() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.state.immersiveControls = false
        let item = fixture.addTabBarItem()
        let nativeWindows = fixture.window.tabGroup?.windows ?? [fixture.window]
        XCTAssertEqual(item.title, L("Show Tab Bar")); XCTAssertTrue(item.isEnabled)

        fixture.closeGuard.toggleTabBar(nil)
        fixture.application.routeNativeTabMenu(fixture.mainMenu, for: fixture.window)
        XCTAssertTrue(fixture.state.normalTabBarShown)
        XCTAssertEqual(item.title, L("Hide Tab Bar")); XCTAssertTrue(item.isEnabled)
        fixture.closeGuard.toggleTabBar(nil)
        fixture.application.routeNativeTabMenu(fixture.mainMenu, for: fixture.window)
        XCTAssertFalse(fixture.state.normalTabBarShown)
        XCTAssertEqual(item.title, L("Show Tab Bar")); XCTAssertTrue(item.isEnabled)

        // NativeTabHostTests exercises publication from real native membership.
        // Here the routed menu consumes that published count independently of
        // AppKit's native tab accessory visibility or its proposed item title.
        fixture.state.tabCount = 2
        fixture.application.routeNativeTabMenu(fixture.mainMenu, for: fixture.window)
        XCTAssertTrue(fixture.state.normalTabBarShown)
        XCTAssertEqual(item.title, L("Hide Tab Bar")); XCTAssertFalse(item.isEnabled)
        fixture.state.tabCount = 1
        fixture.application.routeNativeTabMenu(fixture.mainMenu, for: fixture.window)
        XCTAssertEqual(item.title, L("Show Tab Bar")); XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(fixture.window.tabGroup?.windows ?? [fixture.window], nativeWindows,
            "Changing shared-caption visibility must not mutate native membership")
    }

    @MainActor private final class UnrelatedCommand: NSObject, NSUserInterfaceValidations {
        var validations = 0
        @objc func run(_ sender: Any?) {}
        func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            validations += 1
            return true
        }
    }

    @MainActor private final class Fixture {
        let state = ReaderState(recordsHistory: false)
        let window: NSWindow
        let closeGuard: ReaderCloseGuard
        let application = ReaderApplicationDelegate()
        let mainMenu = NSMenu(title: "Main")
        let viewMenu = NSMenu(title: "View")
        let unrelatedCommand = UnrelatedCommand()
        let directory: TemporaryDirectory
        private let previousMenu: NSMenu?
        private let previousPolicy: NSApplication.ActivationPolicy
        private let previousApplication: NSRunningApplication?

        init() async throws {
            _ = NSApplication.shared
            directory = try TemporaryDirectory()
            let url = directory.url.appendingPathComponent("reader.txt")
            try "Reader".write(to: url, atomically: true, encoding: .utf8)
            state.document = try ReadingDocument.open(url)
            previousMenu = NSApp.mainMenu
            previousPolicy = NSApp.activationPolicy()
            previousApplication = NSWorkspace.shared.frontmostApplication
            window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            closeGuard = ReaderCloseGuard(state: state, previous: nil)
            window.delegate = closeGuard
            state.window = window
            state.immersiveControls = true
            let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            viewItem.submenu = viewMenu
            mainMenu.addItem(viewItem)
            let unrelatedItem = NSMenuItem(title: "Unrelated", action: #selector(UnrelatedCommand.run(_:)), keyEquivalent: "")
            unrelatedItem.target = unrelatedCommand
            viewMenu.addItem(unrelatedItem)
            NSApp.mainMenu = mainMenu
            application.installNativeTabMenuRouting()
            do { try await focusWindow() }
            catch { close(); throw error }
            unrelatedCommand.validations = 0
        }

        private func focusWindow() async throws {
            XCTAssertTrue(NSApp.setActivationPolicy(.regular))
            // Stopping NSApp.run() disrupts later SwiftUI mounts in this XCTest
            // process. Pump native activation events without starting that loop.
            NSApp.finishLaunching()
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let deadline = Date().addingTimeInterval(3)
            while NSApp.keyWindow !== window, Date() < deadline {
                while let event = NSApp.nextEvent(matching: .any, until: .distantPast,
                                                  inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                NSApp.updateWindows()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            print("Native tab menu focus: active=\(NSApp.isActive), keyIsReader=\(NSApp.keyWindow === window)")
            _ = try XCTUnwrap(NSApp.keyWindow === window ? true : nil, "AppKit must establish the real reader as key")
        }

        func addTabBarItem() -> NSMenuItem {
            let item = NSMenuItem(title: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
            viewMenu.addItem(item)
            return item
        }

        func close() {
            NotificationCenter.default.removeObserver(application)
            state.windowClosed()
            window.delegate = nil
            window.close()
            NSApp.mainMenu = previousMenu
            NSApp.setActivationPolicy(previousPolicy)
            previousApplication?.activate(options: [])
        }
    }
}
#endif
