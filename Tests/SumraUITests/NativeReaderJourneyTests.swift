import XCTest
import AppKit

/// Runs against an already-running candidate; never relaunches or terminates Sumra.
final class NativeReaderJourneyTests: XCTestCase {
    private var app: XCUIApplication!
    private var candidateBundle: Bundle!
    private var interfaceBundle: Bundle!
    private var fixtureDirectory: URL?
    private var ownedTitles: [String] = []
    private var ownsHome = false
    private var ownedFullscreenRequested = false
    private var fullscreenBaseline: CGRect?
    private var ownedFullscreenTitle: String?
    private var restoreChromeSettings = false
    private var floatingEnabledByTest = false
    private var unexpectedInterruption = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Stop without answering unexpected dialogs") { [weak self] _ in
            self?.unexpectedInterruption = true
            XCTFail("Unexpected UI interruption: leave the dialog untouched and stop this test; owned fixtures require scoped cleanup")
            return true
        }
        let environment = ProcessInfo.processInfo.environment
        let appPath = try XCTUnwrap(environment["SUMRA_GUI_APP_PATH"], "Set SUMRA_GUI_APP_PATH to the candidate .app")
        candidateBundle = try XCTUnwrap(Bundle(path: appPath))
        let localizationRoot = try XCTUnwrap(candidateBundle.resourceURL).appendingPathComponent("Localizations")
        let languages = try FileManager.default.contentsOfDirectory(at: localizationRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }
        let bundleIdentifier = try XCTUnwrap(candidateBundle.bundleIdentifier)
        let selected = environment["SUMRA_GUI_LANGUAGE"] ?? UserDefaults(suiteName: bundleIdentifier)?.string(forKey: "language") ?? "system"
        let language = languages.contains(selected) ? selected : (Bundle.preferredLocalizations(from: languages, forPreferences: Locale.preferredLanguages + ["en"]).first ?? "en")
        interfaceBundle = try XCTUnwrap(Bundle(url: localizationRoot.appendingPathComponent(language + ".lproj")))
        print("GUI acceptance language: preference=\(selected), effective=\(language), New Tab=\(interfaceBundle.localizedString(forKey: "New Tab", value: "New Tab", table: nil))")
        app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        guard app.state == .runningForeground || app.state == .runningBackground else {
            throw XCTSkip("Start the candidate yourself; this test only attaches to a running app")
        }
        let systemDialogs = XCUIApplication(bundleIdentifier: "com.apple.coreservices.uiagent")
        guard systemDialogs.state == .notRunning || systemDialogs.dialogs.count == 0 else {
            throw XCTSkip("Existing system dialogs are outside this test; no foreground or input actions were attempted")
        }
        app.activate()
        XCTAssertTrue(waitUntil {
            NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL == URL(fileURLWithPath: appPath).standardizedFileURL
        }, "Environment: candidate must actually be the foreground application")
        guard app.dialogs.count == 0, app.sheets.count == 0 else {
            throw XCTSkip("An existing dialog belongs to the user")
        }
        let home = app.windows.matching(NSPredicate(format: "title == %@", "Sumra"))
        guard home.count == 0 || environment["SUMRA_GUI_OWNS_INITIAL_HOME"] == "1" else {
            throw XCTSkip("Existing Home is not test-owned; close it or declare SUMRA_GUI_OWNS_INITIAL_HOME=1")
        }
        if home.count == 0 {
            openHomeFromFileMenu()
            XCTAssertTrue(home.firstMatch.waitForExistence(timeout: 5), "File > New Window must create a Home window")
        }
        ownsHome = true

    }

    override func tearDownWithError() throws {
        guard let app else { return }
        continueAfterFailure = true
        guard !unexpectedInterruption else {
            XCTFail("UI cleanup stopped after an unexpected interruption; retain owned fixtures and leave unrelated dialogs untouched")
            return
        }
        // Dismiss only a panel opened by this test, then close its unique fixture tabs.
        if fixtureDirectory != nil, app.dialogs.count > 0 || app.sheets.count > 0 {
            let panel = openPanel
            guard !panel.textFields["PathTextField"].exists else {
                XCTFail("Go to Folder is still active; fixtures retained at \(fixtureDirectory?.path ?? "unknown")")
                return
            }
            let cancel = panel.buttons["Cancel"]
            guard cancel.waitForExistence(timeout: 5), cancel.isEnabled else {
                XCTFail("Cannot cancel the test Open panel; fixtures retained at \(fixtureDirectory?.path ?? "unknown")")
                return
            }
            cancel.click()
            guard waitUntil({ !panel.exists }) else {
                XCTFail("Test Open panel remained after Cancel; fixtures retained at \(fixtureDirectory?.path ?? "unknown")")
                return
            }
        }
        if restoreChromeSettings { restoreNativeAutoChrome() }
        for title in ownedTitles.reversed() {
            let window = fixtureWindow(title)
            if window.exists {
                window.click()
                if ownedFullscreenRequested, title == (ownedFullscreenTitle ?? ownedTitles.first), let baseline = fullscreenBaseline {
                    let normalSize = abs(window.frame.width - baseline.width) <= 3 && abs(window.frame.height - baseline.height) <= 3
                    if !normalSize {
                        window.typeKey("f", modifierFlags: [.command, .control])
                        guard waitUntil({
                            abs(window.frame.width - baseline.width) <= 3 && abs(window.frame.height - baseline.height) <= 3
                        }) else {
                            XCTFail("Cannot restore normal size for \(title); fixtures retained at \(fixtureDirectory?.path ?? "unknown")")
                            return
                        }
                    }
                    ownedFullscreenRequested = false
                }
                window.typeKey("w", modifierFlags: .command)
                _ = waitUntil { !self.fixtureWindow(title).exists }
            }
        }
        guard !ownedTitles.contains(where: { fixtureWindow($0).exists }) else {
            XCTFail("A test document is still open; fixtures retained at \(fixtureDirectory?.path ?? "unknown")")
            return
        }
        if let fixtureDirectory, !ownedTitles.isEmpty {
            let home = app.windows.matching(NSPredicate(format: "title == %@", "Sumra")).firstMatch
            if !home.exists { openHomeFromFileMenu() }
            guard home.waitForExistence(timeout: 5) else {
                XCTFail("Cannot open owned Home to forget test history; fixtures retained at \(fixtureDirectory.path)")
                return
            }
            ownsHome = true
            let search = home.textFields[localized("Search files")]
            guard search.waitForExistence(timeout: 5) else {
                XCTFail("Owned Home search unavailable; fixtures retained at \(fixtureDirectory.path)")
                return
            }
            search.click()
            search.typeKey("a", modifierFlags: .command)
            search.typeText(fixtureDirectory.lastPathComponent)
            for title in ownedTitles {
                let card = home.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
                if card.exists {
                    card.rightClick()
                    let forget = app.menuItems[localized("Forget")]
                    guard forget.waitForExistence(timeout: 5) else {
                        app.typeKey(.escape, modifierFlags: [])
                        XCTFail("Forget action unavailable for \(title); fixtures retained at \(fixtureDirectory.path)")
                        return
                    }
                    forget.click()
                    guard waitUntil({ !card.exists }) else {
                        XCTFail("Recent item remains for \(title); fixtures retained at \(fixtureDirectory.path)")
                        return
                    }
                }
            }
        }
        if ownsHome {
            let home = app.windows.matching(NSPredicate(format: "title == %@", "Sumra")).firstMatch
            if home.exists {
                let close = home.buttons[XCUIIdentifierCloseWindow]
                XCTAssertTrue(close.waitForExistence(timeout: 5))
                XCTAssertTrue(close.isHittable)
                close.click()
                guard waitUntil({ !home.exists }) else {
                    XCTFail("Test-owned Home did not close; fixtures retained at \(fixtureDirectory?.path ?? "unknown")")
                    return
                }
            }
        }
        if let fixtureDirectory { try FileManager.default.removeItem(at: fixtureDirectory) }
    }

    func testOpenCancelAddCloseAndContentsHover() throws {
        let fixtures = try openFixturePair()
        let original = fixtures.original
        let second = fixtures.tab
        let initialWindowCount = app.windows.count
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        let newTab = original.buttons[localized("New Tab")]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5), "New Tab must be exposed as a native button")
        newTab.hover()
        XCTAssertTrue(newTab.isHittable, "Real pointer hover must leave New Tab usable")
        newTab.click()
        XCTAssertTrue(openPanel.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !self.openPanel.exists })
        XCTAssertTrue(original.exists, "Cancel must retain the original document")
        XCTAssertEqual(app.windows.count, initialWindowCount, "Cancel must not create a Home or blank window")

        original.typeKey("t", modifierFlags: .command)
        try chooseFile(second)
        let added = fixtureWindow(second.lastPathComponent)
        XCTAssertTrue(added.waitForExistence(timeout: 10))
        capturePhase("native-tab-added", window: added)
        added.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { !self.fixtureWindow(second.lastPathComponent).exists })
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Closing the new tab must restore the original")
        XCTAssertEqual(app.windows.count, initialWindowCount, "Closing the tab must not introduce a Home window")
        capturePhase("native-tab-closed", window: original)

        original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        let contents = original.buttons[localized("Toggle Contents")]
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        contents.hover()
        let closeSidebar = original.buttons[localized("Close Sidebar")]
        if !closeSidebar.exists { contents.click() }
        XCTAssertTrue(closeSidebar.waitForExistence(timeout: 5), "Contents sidebar must render native controls")
        XCTAssertTrue(original.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Find your place")).firstMatch.waitForExistence(timeout: 10), "The demo outline must render its chapter")
        capturePhase("contents-toolbar-hovered", window: original)
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).hover()
        XCTAssertTrue(waitUntil { !newTab.isHittable }, "This phase requires the candidate's existing automatic toolbar mode: body hover must hide the toolbar")
        capturePhase("contents-toolbar-hidden", window: original)
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        XCTAssertTrue(waitUntil { contents.isHittable }, "Top-edge hover must reveal Contents again")
        contents.hover()
        capturePhase("contents-toolbar-revealed", window: original)
    }

    func testFullscreenTabRoundTrip() throws {
        let fixtures = try openFixturePair()
        let original = fixtures.original
        let baseline = original.frame
        fullscreenBaseline = baseline
        capturePhase("fullscreen-before", window: original)
        ownedFullscreenRequested = true
        original.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil {
            original.frame.width > baseline.width + 100 && original.frame.height > baseline.height + 100
        }, "Fullscreen keyboard entry must materially expand the owned window")
        capturePhase("fullscreen-entered", window: original)
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        let newTab = original.buttons[localized("New Tab")]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        newTab.hover()
        XCTAssertTrue(newTab.isHittable, "Fullscreen hover must expose a usable New Tab control")
        original.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(openPanel.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !self.openPanel.exists })
        XCTAssertTrue(original.exists, "Fullscreen tab cancellation must preserve the original")
        capturePhase("fullscreen-tab-cancelled", window: original)
        original.typeKey("t", modifierFlags: .command)
        try chooseFile(fixtures.tab)
        let added = fixtureWindow(fixtures.tab.lastPathComponent)
        XCTAssertTrue(added.waitForExistence(timeout: 10))
        capturePhase("fullscreen-tab-added", window: added)
        added.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { !self.fixtureWindow(fixtures.tab.lastPathComponent).exists })
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil {
            abs(original.frame.width - baseline.width) <= 3 && abs(original.frame.height - baseline.height) <= 3
        }, "Leaving fullscreen must restore the original window size")
        XCTAssertEqual(original.frame.minX, baseline.minX, accuracy: 3)
        XCTAssertEqual(original.frame.minY, baseline.minY, accuracy: 3)
        ownedFullscreenRequested = false
        capturePhase("fullscreen-returned", window: original)
    }

    func testNativeResizeAndTitlebarDrag() throws {
        let original = try openFixturePair().original
        let baseline = original.frame
        capturePhase("resize-before", window: original)
        let corner = original.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.15, thenDragTo: corner.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(waitUntil { original.frame.width > baseline.width + 80 }, "A native border drag must actually widen the window")
        capturePhase("resize-wide", window: original)
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        let newTab = original.buttons[localized("New Tab")]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        newTab.hover()
        XCTAssertTrue(newTab.isHittable, "Widened-window hover must leave controls usable")
        let wide = original.frame
        let restoreCorner = original.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        restoreCorner.click(forDuration: 0.15, thenDragTo: restoreCorner.withOffset(CGVector(dx: baseline.width - wide.width, dy: baseline.height - wide.height)))
        XCTAssertTrue(waitUntil { abs(original.frame.width - baseline.width) <= 3 }, "A native border drag must restore the window width")
        capturePhase("resize-narrow-restored", window: original)

        let beforeDrag = original.frame
        let documentTitlebar = original.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01))
        documentTitlebar.hover()
        capturePhase("titlebar-before-drag", window: original)
        documentTitlebar.click(forDuration: 0.15, thenDragTo: documentTitlebar.withOffset(CGVector(dx: 60, dy: 40)))
        XCTAssertTrue(waitUntil {
            abs(original.frame.minX - beforeDrag.minX) > 20 || abs(original.frame.minY - beforeDrag.minY) > 20
        }, "Dragging the document titlebar must actually move the window")
        capturePhase("titlebar-moved", window: original)
        let moved = original.frame
        let returnTitlebar = original.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01))
        returnTitlebar.click(forDuration: 0.15, thenDragTo: returnTitlebar.withOffset(CGVector(dx: beforeDrag.minX - moved.minX, dy: beforeDrag.minY - moved.minY)))
        XCTAssertTrue(waitUntil {
            abs(original.frame.minX - baseline.minX) <= 3 && abs(original.frame.minY - baseline.minY) <= 3
        }, "The final native drag must restore the original window position")
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        newTab.hover()
        XCTAssertTrue(newTab.isHittable, "Restored-window hover must leave controls usable")
        capturePhase("titlebar-restored", window: original)
    }

    func testNativeTabAndOverviewEntries() throws {
        try exerciseNativeTabEntries(fullscreen: false)
    }

    func testFullscreenNativeTabAndOverviewEntries() throws {
        try exerciseNativeTabEntries(fullscreen: true)
    }

    func testAIAndPaletteLayout() throws {
        let original = try openFixturePair().original
        let closeContents = original.buttons[localized("Close Sidebar")]
        if !closeContents.exists {
            app.menuBars.menuBarItems["View"].click()
            // SumraCommands places the toggle before the same-titled submenu.
            let contentsCommand = app.menuItems.matching(identifier: localized("Contents")).firstMatch
            XCTAssertTrue(contentsCommand.waitForExistence(timeout: 5))
            XCTAssertTrue(contentsCommand.isEnabled)
            contentsCommand.click()
        }
        XCTAssertTrue(closeContents.waitForExistence(timeout: 5), "The native View Contents command must open the sidebar")
        XCTAssertTrue(original.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Find your place")).firstMatch.waitForExistence(timeout: 10), "The opened contents sidebar must expose the public fixture outline")
        toggleAISidebar()
        let question = original.textViews[localized("Question about the document")]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        let send = original.buttons[localized("Send")]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let initialAIWindow = original.frame
        let corner = original.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.15, thenDragTo: corner.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(waitUntil { original.frame.width > initialAIWindow.width + 80 }, "AI layout test must actually widen its owned window")
        let beforeAIWidth = question.frame.width
        let expandAI = try aiDividerCoordinate(in: original, beside: question)
        expandAI.click(forDuration: 0.15, thenDragTo: expandAI.withOffset(CGVector(dx: -120, dy: 0)))
        XCTAssertTrue(waitUntil { question.frame.width > beforeAIWidth + 10 }, "Dragging the native AI divider must actually widen the input")
        let expandedAIWidth = question.frame.width
        let shrinkAI = try aiDividerCoordinate(in: original, beside: question)
        shrinkAI.click(forDuration: 0.15, thenDragTo: shrinkAI.withOffset(CGVector(dx: 400, dy: 0)))
        XCTAssertTrue(waitUntil { question.frame.width < expandedAIWidth - 10 }, "Dragging the AI divider toward its boundary must actually narrow the input")
        let minimumAIWidth = question.frame.width
        let boundaryDrag = try aiDividerCoordinate(in: original, beside: question)
        boundaryDrag.click(forDuration: 0.15, thenDragTo: boundaryDrag.withOffset(CGVector(dx: 80, dy: 0)))
        XCTAssertEqual(question.frame.width, minimumAIWidth, accuracy: 3, "A further native drag must confirm the minimum-width boundary")
        assertAIControlsInside(original, question: question, send: send, phase: "ai-minimum-sidebar")
        let wideWindow = original.frame
        let shrinkWindow = original.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        shrinkWindow.click(forDuration: 0.15, thenDragTo: shrinkWindow.withOffset(CGVector(dx: initialAIWindow.width - wideWindow.width, dy: 0)))
        XCTAssertTrue(waitUntil { original.frame.width < wideWindow.width - 80 }, "The AI layout test must actually narrow its owned window")
        assertAIControlsInside(original, question: question, send: send, phase: "ai-narrow-window")
        toggleAISidebar()
        XCTAssertTrue(waitUntil { !question.exists })
        toggleAISidebar()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        assertAIControlsInside(original, question: question, send: send, phase: "ai-reopened")
        toggleAISidebar()
        XCTAssertTrue(waitUntil { !question.exists })

        original.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).hover()
        XCTAssertTrue(waitUntil { !original.buttons[self.localized("New Tab")].isHittable }, "Palette dialog coverage requires the candidate's existing automatic toolbar mode")
        original.typeKey("p", modifierFlags: [.command, .shift])
        let search = app.textFields[localized("Search")]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("> " + localized("Go to Page…").replacingOccurrences(of: "…", with: ""))
        let command = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", localized("Go to Page…"), ",")).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(command.frame.width, 300, "The palette must expose the full command row")
        capturePhase("palette-before-blank-click", window: original)
        command.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).click()
        let goToPage = app.dialogs.firstMatch
        XCTAssertTrue(goToPage.waitForExistence(timeout: 5), "Clicking the command row's right blank area must open Page input")
        XCTAssertTrue(goToPage.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", localized("Go to Page…"))).firstMatch.exists)
        XCTAssertTrue(goToPage.textFields.firstMatch.exists)
        capturePhase("palette-page-input", window: original)
        let cancel = goToPage.buttons[localized("Cancel")]
        XCTAssertTrue(cancel.exists)
        cancel.click()
        XCTAssertTrue(waitUntil { !goToPage.exists })
    }

    func testFloatingHoverPressedAndCenteredFullscreen() throws {
        let fixtures = try openFixturePair()
        fixtures.original.typeKey("t", modifierFlags: .command)
        try chooseFile(fixtures.tab)
        let window = fixtureWindow(fixtures.tab.lastPathComponent)
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        captureChromeMode("fullscreen-floating-initial-mode")
        let screen = try XCTUnwrap(NSScreen.main).frame
        let start = window.frame
        let target = CGPoint(x: screen.midX - start.width / 2, y: screen.height / 2 - start.height / 2)
        let titlebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01))
        titlebar.click(forDuration: 0.15, thenDragTo: titlebar.withOffset(CGVector(dx: target.x - start.minX, dy: target.y - start.minY)))
        XCTAssertTrue(waitUntil { abs(window.frame.minX - target.x) <= 4 && abs(window.frame.minY - target.y) <= 4 }, "The owned window must actually be centered before fullscreen entry")
        restoreChromeSettings = true
        toggleFloatingControls()
        floatingEnabledByTest = true
        let navigation = window.descendants(matching: .any).matching(identifier: "floating-navigation").firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        XCTAssertTrue(waitUntil { !navigation.exists }, "Floating Auto Hide must hide controls over the body")
        capturePhase("fullscreen-floating-body", window: window)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01)).hover()
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        let open = navigation.buttons[localized("Open Document")]
        try hoverHoldAndCancel(open, in: window, phase: "open")
        for (identifier, phase) in [(XCUIIdentifierCloseWindow, "close"), (XCUIIdentifierMinimizeWindow, "minimize"), (XCUIIdentifierFullScreenWindow, "fullscreen")] {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01)).hover()
            XCTAssertTrue(navigation.waitForExistence(timeout: 5))
            try hoverHoldAndCancel(navigation.buttons[identifier], in: window, phase: phase)
        }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)).hover()
        let progress = window.sliders[localized("Reading Progress")]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(progress.isHittable)
        print("GUI floating progress window=\(window.frame), slider=\(progress.frame)")
        capturePhase("fullscreen-floating-progress", window: window)
        fullscreenBaseline = window.frame
        ownedFullscreenTitle = fixtures.tab.lastPathComponent
        ownedFullscreenRequested = true
        capturePhase("fullscreen-floating-entry-request", window: window)
        window.typeKey("f", modifierFlags: [.command, .control])
        let baseline = try XCTUnwrap(fullscreenBaseline)
        XCTAssertTrue(waitUntil { window.frame.width > baseline.width + 100 && window.frame.height > baseline.height + 100 })
        capturePhase("fullscreen-floating-entered", window: window)
        window.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil { abs(window.frame.width - baseline.width) <= 3 && abs(window.frame.height - baseline.height) <= 3 })
        ownedFullscreenRequested = false
        capturePhase("fullscreen-floating-returned", window: window)
        restoreNativeAutoChrome()
    }

    private func hoverHoldAndCancel(_ button: XCUIElement, in window: XCUIElement, phase: String) throws {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.hover()
        XCTAssertTrue(button.isHittable)
        capturePhase("fullscreen-floating-" + phase + "-hover", window: window)
        let before = window.frame
        print("GUI phase floating-\(phase)-pressed-begin epoch=\(Date().timeIntervalSince1970)")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(forDuration: 0.45, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        print("GUI phase floating-\(phase)-pressed-cancelled epoch=\(Date().timeIntervalSince1970)")
        XCTAssertTrue(window.exists, "A cancelled press must not close the owned window")
        XCTAssertTrue(window.isHittable, "A cancelled press must not minimize the owned window")
        XCTAssertEqual(window.frame, before, "A cancelled press must not toggle fullscreen or move the window")
    }

    private func toggleFloatingControls() {
        app.menuBars.menuBarItems["View"].click()
        let command = app.menuItems[localized("Floating Reading Controls")]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
    }

    private func setToolbarDisplay(_ key: String) {
        app.menuBars.menuBarItems["View"].click()
        let picker = app.menuItems[localized("Toolbar Display")]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.hover()
        let command = picker.menuItems[localized(key)]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
    }

    private func restoreNativeAutoChrome() {
        if floatingEnabledByTest {
            toggleFloatingControls()
            floatingEnabledByTest = false
        }
        setToolbarDisplay("Auto Hide")
        restoreChromeSettings = false
    }

    private func captureChromeMode(_ name: String) {
        app.menuBars.menuBarItems["View"].click()
        let picker = app.menuItems[localized("Toolbar Display")]
        picker.hover()
        XCTAssertTrue(picker.menuItems[localized("Auto Hide")].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testEPUBSpreadResize() throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["SUMRA_GUI_FIXTURE_PATH"])
        guard URL(fileURLWithPath: fixture).pathExtension.lowercased() == "epub" else {
            throw XCTSkip("EPUB coverage requires --fixture build/feedback-68-69-20261030/originals/latest-C.epub; the default Markdown fixture does not exercise this journey")
        }
        let original = try openFixturePair().original
        epubLayoutCommand("Single Page").click()
        epubLayoutCommand("Two Pages").click()
        toggleEPUBCover(expected: false)
        app.menuBars.menuBarItems["View"].click()
        app.menuItems[localized("Zoom")].hover()
        let fitPage = app.menuItems[localized("Fit Page")]
        XCTAssertTrue(fitPage.waitForExistence(timeout: 5))
        fitPage.click()
        original.typeKey(.home, modifierFlags: .command)
        let baseline = original.frame
        capturePhase("resize-epub-before", window: original)
        let corner = original.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.15, thenDragTo: corner.withOffset(CGVector(dx: 180, dy: 100)))
        XCTAssertTrue(waitUntil { original.frame.width > baseline.width + 80 && original.frame.height > baseline.height + 40 }, "The EPUB window border drag must actually expand both dimensions")
        capturePhase("resize-epub-wide", window: original)
        let expanded = original.frame
        let restore = original.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        restore.click(forDuration: 0.15, thenDragTo: restore.withOffset(CGVector(dx: baseline.width - expanded.width, dy: baseline.height - expanded.height)))
        XCTAssertTrue(waitUntil { abs(original.frame.width - baseline.width) <= 3 && abs(original.frame.height - baseline.height) <= 3 }, "The EPUB border drag must restore the original window dimensions")
        capturePhase("resize-epub-restored", window: original)
        toggleEPUBCover(expected: true)
        original.typeKey(.home, modifierFlags: .command)
        capturePhase("resize-epub-cover-alone", window: original)
    }

    private func epubLayoutCommand(_ key: String) -> XCUIElement {
        app.menuBars.menuBarItems["View"].click()
        let layout = app.menuItems[localized("Page Layout")]
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        layout.hover()
        let command = app.menuItems[localized(key)]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.isEnabled)
        return command
    }

    // XCTest does not expose AppKit's menu checkmark in value/isSelected.
    // Configuration is deliberately witnessed by the native-menu screenshots;
    // visual review must confirm initial ON, OFF during resize, then restored ON.
    private func toggleEPUBCover(expected: Bool) {
        let command = epubLayoutCommand("Cover on Its Own")
        if !expected {
            let initial = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            initial.name = "resize-epub-cover-initial-menu"
            initial.lifetime = .keepAlways
            add(initial)
        }
        command.click()
        _ = epubLayoutCommand("Cover on Its Own")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = expected ? "resize-epub-cover-on-menu" : "resize-epub-cover-off-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("GUI EPUB Cover toggled; expected native checkmark \(expected ? "ON" : "OFF"); menu screenshot requires visual confirmation")
        app.typeKey(.escape, modifierFlags: [])
    }

    private func aiDividerCoordinate(in window: XCUIElement, beside question: XCUIElement) throws -> XCUICoordinate {
        let questionFrame = question.frame
        let frames = window.splitters.allElementsBoundByAccessibilityElement.map { $0.frame }
        let adjacent = frames.filter {
            $0.width > 0 && $0.height > 0 && $0.midX < questionFrame.minX && $0.minY <= questionFrame.midY && $0.maxY >= questionFrame.midY
        }.min { abs($0.midX - questionFrame.minX) < abs($1.midX - questionFrame.minX) }
        let dividerFrame = try XCTUnwrap(adjacent, "A current native divider must border the AI input's left pane edge")
        let windowFrame = window.frame
        print("GUI AI divider frame=\(dividerFrame), question=\(questionFrame)")
        return window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: dividerFrame.midX - windowFrame.minX, dy: questionFrame.midY - windowFrame.minY))
    }

    private func assertAIControlsInside(_ window: XCUIElement, question: XCUIElement, send: XCUIElement, phase: String) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)).hover()
        let progress = window.sliders[localized("Reading Progress")]
        XCTAssertTrue(waitUntil { progress.exists && progress.isHittable && progress.frame.height > 0 }, "Bottom-edge hover must reveal the actual reading-progress control")
        let translate = window.buttons[localized("Translate Selection")]
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        print("GUI AI footer geometry phase=\(phase), slider=\(progress.frame), translate=\(translate.frame), send=\(send.frame), question=\(question.frame)")
        capturePhase(phase, window: window)
        XCTAssertGreaterThan(question.frame.width, 0)
        XCTAssertGreaterThan(question.frame.height, 0)
        XCTAssertGreaterThan(send.frame.width, 0)
        XCTAssertGreaterThan(send.frame.height, 0)
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(question.frame), "The entire AI input must remain inside the visible window")
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(send.frame), "The entire Send control must remain inside the visible window")
        XCTAssertLessThanOrEqual(translate.frame.maxY, progress.frame.minY + 1, "Translate Selection must remain above the visible footer's progress row")
        XCTAssertLessThanOrEqual(send.frame.maxY, progress.frame.minY + 1, "Send must remain above the visible footer's progress row")
    }

    private func toggleAISidebar() {
        app.menuBars.menuBarItems["View"].click()
        let command = app.menuItems[localized("Ask AI…")]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
    }

    private func openHomeFromFileMenu() {
        app.menuBars.menuBarItems["File"].click()
        let command = app.menuItems["New Sumra Window"]
        XCTAssertTrue(command.waitForExistence(timeout: 5), "File must expose the native New Sumra Window command")
        XCTAssertTrue(command.isEnabled)
        command.click()
    }

    private func exerciseNativeTabEntries(fullscreen: Bool) throws {
        let fixtures = try openFixturePair()
        let original = fixtures.original
        let baseline = original.frame
        if fullscreen {
            fullscreenBaseline = baseline
            capturePhase("native-tab-entries-fullscreen-before", window: original)
            ownedFullscreenRequested = true
            original.typeKey("f", modifierFlags: [.command, .control])
            XCTAssertTrue(waitUntil {
                original.frame.width > baseline.width + 100 && original.frame.height > baseline.height + 100
            }, "Fullscreen keyboard entry must materially expand the owned window")
            capturePhase("native-tab-entries-fullscreen-entered", window: original)
        }
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        let nativePlus = original.tabGroups.firstMatch.buttons["new tab"]
        if !nativePlus.isHittable {
            nativeViewCommand("toggleTabBar:").click()
            XCTAssertTrue(waitUntil { nativePlus.isHittable }, "The native tab-bar command must reveal its plus button")
        }
        for overview in [false, true] {
            let cancelPlus = nativeEntryButton(in: original, overview: overview)
            cancelPlus.hover()
            XCTAssertTrue(cancelPlus.isHittable)
            cancelPlus.click()
            XCTAssertTrue(openPanel.waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitUntil { !self.openPanel.exists })
            XCTAssertTrue(original.exists, "Cancelling a native entry must preserve the original document")

            let addPlus = nativeEntryButton(in: original, overview: overview)
            addPlus.click()
            try chooseFile(fixtures.tab)
            let added = fixtureWindow(fixtures.tab.lastPathComponent)
            XCTAssertTrue(added.waitForExistence(timeout: 10))
            capturePhase(overview ? "native-tab-overview-added" : "native-tab-bar-added", window: added)
            added.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitUntil { !self.fixtureWindow(fixtures.tab.lastPathComponent).exists })
            XCTAssertTrue(original.waitForExistence(timeout: 5), "Closing the added native tab must restore the original")
        }
        if fullscreen {
            original.typeKey("f", modifierFlags: [.command, .control])
            XCTAssertTrue(waitUntil {
                abs(original.frame.width - baseline.width) <= 3 && abs(original.frame.height - baseline.height) <= 3
            }, "Leaving fullscreen must restore the original window size")
            XCTAssertEqual(original.frame.minX, baseline.minX, accuracy: 3)
            XCTAssertEqual(original.frame.minY, baseline.minY, accuracy: 3)
            ownedFullscreenRequested = false
            capturePhase("native-tab-entries-fullscreen-returned", window: original)
        }
    }

    private func nativeEntryButton(in window: XCUIElement, overview: Bool) -> XCUIElement {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).hover()
        if overview {
            nativeViewCommand("toggleTabOverview:").click()
            let allTabs = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "All Tabs")).firstMatch
            XCTAssertTrue(allTabs.waitForExistence(timeout: 5), "Native overview must expose All Tabs")
            let plus = allTabs.buttons["New Tab"]
            XCTAssertTrue(plus.waitForExistence(timeout: 5))
            return plus
        }
        let tabBar = window.tabGroups.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        let plus = tabBar.buttons["new tab"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        return plus
    }

    private func nativeViewCommand(_ identifier: String) -> XCUIElement {
        let viewMenu = app.menuBars.menuBarItems["View"]
        viewMenu.click()
        let command = app.menuItems.matching(identifier: identifier).firstMatch
        let exists = command.waitForExistence(timeout: 5)
        if !exists {
            print("GUI native View menu missing \(identifier):\n\(viewMenu.debugDescription)")
        }
        XCTAssertTrue(exists, "The native View menu must expose command \(identifier)")
        XCTAssertTrue(command.isEnabled, "The owned window must enable native command \(identifier)")
        return command
    }

    private func openFixturePair() throws -> (original: XCUIElement, tab: URL) {
        let sourcePath = try XCTUnwrap(ProcessInfo.processInfo.environment["SUMRA_GUI_FIXTURE_PATH"], "Set SUMRA_GUI_FIXTURE_PATH to docs/demos/Reading-Notes.md")
        let token = "Sumra-GUI-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        fixtureDirectory = directory
        let sourceExtension = URL(fileURLWithPath: sourcePath).pathExtension
        let first = directory.appendingPathComponent(token + "-original." + sourceExtension)
        let second = directory.appendingPathComponent(token + "-tab." + sourceExtension)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: first)
        try FileManager.default.copyItem(at: first, to: second)
        ownedTitles = [first.lastPathComponent, second.lastPathComponent]
        let home = app.windows.matching(NSPredicate(format: "title == %@", "Sumra")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { home.frame.width > 0 && home.frame.height > 0 })
        let openDocument = home.buttons[localized("Open Document…")]
        XCTAssertTrue(openDocument.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { openDocument.isHittable })
        openDocument.click()
        try chooseFile(first)
        let original = fixtureWindow(first.lastPathComponent)
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { original.frame.width > 0 && original.frame.height > 0 })
        return (original, second)
    }

    private func capturePhase(_ name: String, window: XCUIElement) {
        print("GUI phase \(name) epoch=\(Date().timeIntervalSince1970) uptime=\(ProcessInfo.processInfo.systemUptime) frame=\(window.frame)")
        XCTContext.runActivity(named: name) { activity in
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
    }

    private func localized(_ key: String) -> String {
        interfaceBundle.localizedString(forKey: key, value: key, table: nil)
    }

    private func fixtureWindow(_ title: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS %@", title)).firstMatch
    }

    private var openPanel: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.dialog.rawValue)).firstMatch
    }

    private func chooseFile(_ url: URL) throws {
        let panel = openPanel
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Native Open panel did not appear")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = panel.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5), "Go to Folder path field did not appear")
        path.typeText(url.path)
        path.typeKey(.return, modifierFlags: [])
        let open = panel.buttons["Open"]
        XCTAssertTrue(waitUntil { !path.exists && open.exists && open.isEnabled && open.isHittable }, "Go to Folder must finish and enable the native Open button")
        open.click()
        XCTAssertTrue(waitUntil { !panel.exists }, "Native Open panel did not finish after Open")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 5) == .completed
    }
}

/// Attaches to the explicitly prepared public PDF; never opens or closes documents.
final class NativeFixedPDFChromeAcceptanceTests: XCTestCase {
    func testOpenPDFChromeHoverAndFullscreenRoundTrip() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Preserve unexpected dialogs") { _ in
            XCTFail("Unexpected dialog; leave it untouched")
            return true
        }
        let environment = ProcessInfo.processInfo.environment
        let appPath = try XCTUnwrap(environment["SUMRA_GUI_APP_PATH"])
        let title = try XCTUnwrap(environment["SUMRA_GUI_WINDOW_TITLE"])
        let app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        guard app.state == .runningForeground || app.state == .runningBackground else {
            throw XCTSkip("Prepare the running candidate and public PDF before this test")
        }
        guard app.dialogs.count == 0, app.sheets.count == 0 else {
            throw XCTSkip("Existing dialogs are outside this acceptance run")
        }
        app.activate()
        XCTAssertTrue(waitFor { NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL == URL(fileURLWithPath: appPath).standardizedFileURL })
        let window = app.windows.matching(NSPredicate(format: "title == %@", title)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        func mode(_ name: String) {
            app.menuBars.menuBarItems["View"].click()
            let submenu = app.menuBars.menuItems["工具栏显示方式"]
            submenu.hover()
            submenu.menuItems[name].click()
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "fixed-pdf-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        if environment["SUMRA_GUI_START_FULLSCREEN"] == "1" {
            let fullFrame = window.frame
            window.typeKey("f", modifierFlags: [.command, .control])
            XCTAssertTrue(waitFor { window.frame.height < fullFrame.height - 10 }, "Prepared fullscreen must actually exit")
        }
        mode("始终显示")
        let normalFrame = window.frame
        mode("自动隐藏")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let open = window.toolbars.buttons["打开文档"].firstMatch
        XCTAssertTrue(waitFor { !open.isHittable }, "Body hover must dismiss native auto chrome")
        capture("normal-body")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.006)).hover()
        XCTAssertTrue(waitFor { open.isHittable }, "Top hover must reveal usable native chrome")
        capture("normal-top-hover")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(waitFor { !open.isHittable })
        XCTAssertEqual(window.frame, normalFrame, "Hover must preserve the window frame")
        window.typeKey("f", modifierFlags: [.command, .control])
        app.activate()
        XCTAssertTrue(waitFor { window.frame.height > normalFrame.height + 10 })
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(waitFor { !open.isHittable })
        capture("fullscreen-body")
        window.typeKey("f", modifierFlags: [.command, .control])
        app.activate()
        XCTAssertTrue(waitFor { abs(window.frame.height - normalFrame.height) < 4 && abs(window.frame.width - normalFrame.width) < 4 })
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(waitFor { !open.isHittable })
        capture("returned-body")
    }

    private func waitFor(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 5) == .completed
    }
}
