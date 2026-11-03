import Testing
import Carbon.HIToolbox
import CoreGraphics
import Foundation
@testable import DebutCore

final class MockApplicationControl: ApplicationControlling, @unchecked Sendable {
    var targets: [String: ApplicationShortcutTarget] = [:]
    private(set) var calls: [String] = []

    func runningTarget(bundleID: String) -> ApplicationShortcutTarget? { targets[bundleID] }
    func open(bundleID: String, path: String) { calls.append("open \(bundleID)") }
    func hide(pid: pid_t) { calls.append("hide \(pid)") }
    func unhide(pid: pid_t) { calls.append("unhide \(pid)") }
    func sendNewWindowShortcut(pid: pid_t) { calls.append("newWindow \(pid)") }
}

@Suite("App shortcuts", .serialized)
@MainActor
struct ApplicationShortcutTests {
    static let bundleID = "com.test.Editor"
    static let pid: pid_t = 42

    private func fixture(
        _ shortcut: ApplicationShortcut = ApplicationShortcut(
            bundleID: bundleID, appName: "Editor", appPath: "/Applications/Editor.app"
        ),
        windows: [(id: CGWindowID, desktop: Int)] = [],
        target: ApplicationShortcutTarget? = ApplicationShortcutTarget(
            pid: pid, isActive: false, isHidden: false
        )
    ) -> (SpaceController, MockWindowService, MockSpaceSwitcher, MockApplicationControl) {
        let windowService = MockWindowService()
        let spaces = MockSpaceSwitcher(desktops: 3)
        spaces.switchChangesDesktop = false
        let applications = MockApplicationControl()
        applications.targets[Self.bundleID] = target
        let controller = SpaceController(windowService: windowService, keyboardService: MockKeyboardService())
        controller.spaceSwitcher = spaces
        controller.applications = applications
        controller.applicationShortcuts = [shortcut]
        controller.reconcileSpacesWithDesktops()
        let now = Date()
        for (offset, window) in windows.enumerated() {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: window.id, ownerBundleID: Self.bundleID, ownerName: "Editor",
                            windowTitle: "W\(window.id)", ownerPID: Self.pid,
                            lastActivatedAt: now.addingTimeInterval(-Double(offset))),
                toSpaceID: controller.spaceManager.spaces[window.desktop].id
            )
            spaces.windowDesktops[window.id] = window.desktop
        }
        return (controller, windowService, spaces, applications)
    }

    private func spaceIndex(of windowID: CGWindowID, in controller: SpaceController) -> Int? {
        controller.spaceManager.spaces.firstIndex { $0.windows.contains { $0.windowID == windowID } }
    }

    @Test("A visible app on another desktop is reached by switching there, and focused only after the desktop arrives")
    func switchesToOtherDesktop() {
        let (controller, windows, spaces, applications) = fixture(windows: [(201, 1), (202, 2)])
        let id = controller.applicationShortcuts[0].id
        controller.handleKeyEvent(.toggleApplication(id))
        #expect(spaces.switchRequests == [1])
        #expect(spaces.moveRequests.isEmpty)
        #expect(windows.frontedWindows.isEmpty)
        #expect(applications.calls.isEmpty)
        spaces.current = 1
        controller.desktopDidChange()
        #expect(windows.frontedWindows.last == FrontWindowRequest(windowID: 201, ownerPID: Self.pid))
    }

    @Test("A hidden app with no window here has only its most recent window moved here and focused, without a desktop switch")
    func movesMostRecentHiddenWindowHere() {
        let (controller, windows, spaces, applications) = fixture(
            windows: [(201, 1), (202, 2)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: false, isHidden: true)
        )
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(applications.calls == ["unhide \(Self.pid)"])
        #expect(spaces.moveRequests.map(\.windowID) == [201])
        #expect(spaces.moveRequests.allSatisfy { $0.desktop == 0 })
        #expect(spaces.switchRequests.isEmpty)
        #expect(spaceIndex(of: 201, in: controller) == 0)
        #expect(spaceIndex(of: 202, in: controller) == 2)
        #expect(windows.frontedWindows.last == FrontWindowRequest(windowID: 201, ownerPID: Self.pid))
    }

    @Test("A hidden app with a window here is shown in place, leaving its windows on other desktops where they were")
    func showsHiddenAppInPlace() {
        let (controller, windows, spaces, applications) = fixture(
            windows: [(201, 1), (202, 0), (203, 2), (204, 0)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: false, isHidden: true)
        )
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(applications.calls == ["unhide \(Self.pid)"])
        #expect(spaces.moveRequests.isEmpty)
        #expect(spaces.switchRequests.isEmpty)
        #expect(spaceIndex(of: 201, in: controller) == 1)
        #expect(spaceIndex(of: 203, in: controller) == 2)
        #expect(windows.frontedWindows.last == FrontWindowRequest(windowID: 202, ownerPID: Self.pid))
        #expect(windows.trackedRaisedWindowIDs.contains(204))
    }

    @Test("All windows stays on the current desktop when the app has a window here, even if another was used more recently")
    func allWindowsPrefersCurrentDesktop() {
        let (controller, windows, spaces, _) = fixture(windows: [(201, 1), (202, 0), (203, 2)])
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(spaces.switchRequests.isEmpty)
        #expect(spaces.moveRequests.isEmpty)
        #expect(windows.frontedWindows.last == FrontWindowRequest(windowID: 202, ownerPID: Self.pid))
    }

    @Test("Last used window returns to the most recently used window on another desktop, even with one here")
    func lastUsedLeavesCurrentDesktop() {
        let shortcut = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                           windows: .lastUsed)
        let (controller, windows, spaces, _) = fixture(shortcut, windows: [(201, 1), (202, 0)])
        controller.handleKeyEvent(.toggleApplication(shortcut.id))
        #expect(spaces.switchRequests == [1])
        #expect(windows.frontedWindows.isEmpty)
        spaces.current = 1
        controller.desktopDidChange()
        #expect(windows.frontedWindows.last == FrontWindowRequest(windowID: 201, ownerPID: Self.pid))
    }

    @Test("Last used window relocates only the most recent window")
    func lastUsedMovesOneWindow() {
        let shortcut = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                           windows: .lastUsed)
        let (controller, _, spaces, _) = fixture(
            shortcut,
            windows: [(201, 1), (202, 2)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: false, isHidden: true)
        )
        controller.handleKeyEvent(.toggleApplication(shortcut.id))
        #expect(spaces.moveRequests.map(\.windowID) == [201])
        #expect(spaceIndex(of: 202, in: controller) == 2)
    }

    @Test("Moving every window brings visible windows on other desktops here too")
    func moveAllBringsVisibleWindows() {
        let shortcut = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                           placement: .moveAllToCurrentDesktop)
        let (controller, _, spaces, _) = fixture(shortcut, windows: [(201, 1)])
        controller.handleKeyEvent(.toggleApplication(shortcut.id))
        #expect(spaces.moveRequests.map(\.windowID) == [201])
        #expect(spaces.switchRequests.isEmpty)
    }

    @Test("Switching to the window's desktop never relocates a hidden app's windows")
    func switchPlacementKeepsWindowsInPlace() {
        let shortcut = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                           placement: .switchToWindowDesktop)
        let (controller, _, spaces, applications) = fixture(
            shortcut,
            windows: [(201, 2)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: false, isHidden: true)
        )
        controller.handleKeyEvent(.toggleApplication(shortcut.id))
        #expect(applications.calls == ["unhide \(Self.pid)"])
        #expect(spaces.moveRequests.isEmpty)
        #expect(spaces.switchRequests == [2])
    }

    @Test("A refused move focuses the window on the desktop it stayed on")
    func refusedMoveFallsBackToSwitch() {
        let (controller, _, spaces, _) = fixture(
            windows: [(201, 1)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: false, isHidden: true)
        )
        spaces.moveSucceeds = false
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(spaceIndex(of: 201, in: controller) == 1)
        #expect(spaces.switchRequests == [1])
    }

    @Test("The frontmost app with a window on this desktop is hidden")
    func hidesFrontmostApp() {
        let (controller, windows, spaces, applications) = fixture(
            windows: [(201, 0)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: true, isHidden: false)
        )
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(applications.calls == ["hide \(Self.pid)"])
        #expect(windows.frontedWindows.isEmpty)
        #expect(spaces.switchRequests.isEmpty)
    }

    @Test("A frontmost app whose windows are all on other desktops is shown instead of hidden")
    func frontmostElsewhereIsShown() {
        let (controller, _, spaces, applications) = fixture(
            windows: [(201, 2)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: true, isHidden: false)
        )
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(applications.calls.isEmpty)
        #expect(spaces.switchRequests == [2])
    }

    @Test("Only show never hides, and only hide never shows")
    func onlyShowAndOnlyHide() {
        let showOnly = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                           onlyShow: true)
        let (shown, windows, _, showApps) = fixture(
            showOnly, windows: [(201, 0)],
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: true, isHidden: false)
        )
        shown.handleKeyEvent(.toggleApplication(showOnly.id))
        #expect(showApps.calls.isEmpty)
        #expect(windows.frontedWindows.last?.windowID == 201)

        let hideOnly = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                           onlyHide: true)
        let (hidden, hiddenWindows, hiddenSpaces, hideApps) = fixture(hideOnly, windows: [(201, 1)])
        hidden.handleKeyEvent(.toggleApplication(hideOnly.id))
        #expect(hideApps.calls.isEmpty)
        #expect(hiddenWindows.frontedWindows.isEmpty)
        #expect(hiddenSpaces.switchRequests.isEmpty)
    }

    @Test("An app that is not running is launched unless the shortcut only acts on running apps")
    func launchesWhenNotRunning() {
        let (controller, _, _, applications) = fixture(target: nil)
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(applications.calls == ["open \(Self.bundleID)"])

        let runningOnly = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                              onlyIfRunning: true)
        let (skipped, _, _, skippedApps) = fixture(runningOnly, target: nil)
        skipped.handleKeyEvent(.toggleApplication(runningOnly.id))
        #expect(skippedApps.calls.isEmpty)
    }

    @Test("A running app with no windows is reopened, or sent Command-N before it is opened when chosen")
    func noWindows() {
        let (controller, _, _, applications) = fixture()
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(applications.calls == ["open \(Self.bundleID)"])

        let newWindow = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                            opensNewWindowWhenNoneOpen: true)
        let (sending, _, _, sendingApps) = fixture(newWindow)
        sending.handleKeyEvent(.toggleApplication(newWindow.id))
        #expect(sendingApps.calls == ["newWindow \(Self.pid)", "open \(Self.bundleID)"])
    }

    @Test("An ignored app is unhidden and opened without moving or switching")
    func ignoredAppIsOpened() {
        let (controller, _, spaces, applications) = fixture(
            target: ApplicationShortcutTarget(pid: Self.pid, isActive: false, isHidden: true)
        )
        controller.excludedBundleIDs = [Self.bundleID]
        controller.handleKeyEvent(.toggleApplication(controller.applicationShortcuts[0].id))
        #expect(applications.calls == ["unhide \(Self.pid)", "open \(Self.bundleID)"])
        #expect(spaces.moveRequests.isEmpty)
        #expect(spaces.switchRequests.isEmpty)
    }

    @Test("An enabled app shortcut is claimed on both halves and delivers its app once per press")
    func eventTapClaimsShortcut() {
        let shortcut = ApplicationShortcut(
            bundleID: Self.bundleID, appName: "Editor", appPath: "",
            combo: KeyCombo(keyCode: kVK_ANSI_X, option: true)
        )
        let service = EventTapKeyboardService(listensToSession: false)
        service.applicationShortcuts = [shortcut]
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_X), keyDown: true)!
        down.flags = .maskAlternate
        #expect(service.handleCGEvent(type: .keyDown, event: down) == nil)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(service.handleCGEvent(type: .keyDown, event: down) == nil)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_X), keyDown: false)!
        #expect(service.handleCGEvent(type: .keyUp, event: up) == nil)
        #expect(delegate.receivedEvents == [.toggleApplication(shortcut.id)])
    }

    @Test("A disabled or unrecorded app shortcut leaves the key with the foreground app")
    func eventTapPassesDisabledShortcut() {
        let combo = KeyCombo(keyCode: kVK_ANSI_X, option: true)
        let service = EventTapKeyboardService(listensToSession: false)
        service.applicationShortcuts = [
            ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                combo: combo, isEnabled: false),
            ApplicationShortcut(bundleID: "com.test.Other", appName: "Other", appPath: ""),
        ]
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_X), keyDown: true)!
        down.flags = .maskAlternate
        #expect(service.handleCGEvent(type: .keyDown, event: down) != nil)
        #expect(delegate.receivedEvents.isEmpty)
    }

    @Test("Fresh settings carry no app shortcuts, and settings saved before the feature load with none")
    func freshAndLegacySettings() throws {
        #expect(AppSettings().applicationShortcuts.isEmpty)
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any]
        )
        object.removeValue(forKey: "applicationShortcuts")
        let legacy = try JSONDecoder().decode(
            AppSettings.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.applicationShortcuts.isEmpty)
    }

    @Test("App shortcuts survive saving, and a malformed one is dropped without losing the rest")
    func persistence() throws {
        var settings = AppSettings()
        settings.applicationShortcuts = [
            ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "/Applications/Editor.app",
                                combo: KeyCombo(keyCode: kVK_ANSI_X, option: true), windows: .lastUsed),
        ]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var shortcuts = try #require(object["applicationShortcuts"] as? [Any])
        shortcuts.insert(["appName": "No bundle"], at: 0)
        object["applicationShortcuts"] = shortcuts
        object["launchAtLogin"] = false
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.applicationShortcuts == settings.applicationShortcuts)
        #expect(decoded.launchAtLogin == false)
    }

    @Test("Recording an app shortcut flags a Debut shortcut, another app, or a bare key")
    func conflicts() {
        let editor = ApplicationShortcut(bundleID: Self.bundleID, appName: "Editor", appPath: "",
                                         combo: KeyCombo(keyCode: kVK_ANSI_X, option: true))
        let other = ApplicationShortcut(bundleID: "com.test.Other", appName: "Other", appPath: "")
        let shortcuts = [editor, other]
        func messages(_ combo: KeyCombo) -> [String] {
            ConflictDetector.detectConflicts(
                combo: combo, forApplicationShortcut: other.id, among: shortcuts, in: KeyBindings()
            ).map(\.message)
        }
        #expect(messages(KeyCombo(keyCode: kVK_ANSI_X, option: true)) == ["Already opens Editor"])
        #expect(messages(KeyCombo(keyCode: kVK_Tab, option: true))
            == ["Already assigned to \"\(KeyAction.activateAltTabNext.displayName)\""])
        #expect(messages(KeyCombo(keyCode: kVK_ANSI_Z)).count == 1)
        #expect(messages(KeyCombo(keyCode: kVK_ANSI_Z, option: true)).isEmpty)
    }
}
