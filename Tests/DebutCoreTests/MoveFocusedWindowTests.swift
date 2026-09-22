import Testing
import Carbon.HIToolbox
import CoreGraphics
@testable import DebutCore

@Suite("Move focused window", .serialized)
@MainActor
struct MoveFocusedWindowTests {
    @Test("Command-Option arrows move globally, drain releases and accept consecutive presses",
          arguments: [(kVK_LeftArrow, -1), (kVK_UpArrow, -1), (kVK_RightArrow, 1), (kVK_DownArrow, 1)])
    func arrowChord(_ input: (Int, Int)) {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        #expect(service.start(delegate: delegate))
        defer { service.stop() }
        for _ in 0..<3 {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(input.0), keyDown: true)!
            down.flags = [.maskCommand, .maskAlternate]
            #expect(service.handleCGEvent(type: .keyDown, event: down) == nil)
            down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            #expect(service.handleCGEvent(type: .keyDown, event: down) == nil)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(input.0), keyDown: false)!
            up.flags = []
            #expect(service.handleCGEvent(type: .keyUp, event: up) == nil)
        }
        #expect(delegate.receivedEvents == Array(repeating: .moveFocusedWindowToAdjacentSpace(input.1), count: 3))
    }

    @Test("Window-moving chord yields when isolation is disabled, app excluded, or overview visible")
    func chordYields() {
        for mode in 0..<4 {
            let service = EventTapKeyboardService(desktopNavigationBlocked: { mode == 2 })
            if mode == 0 { service.features.workspaceIsolation = false }
            if mode == 1 {
                service.excludedBundleIDs = ["com.test.Excluded"]
                service.updateFrontmostApp(bundleIdentifier: "com.test.Excluded")
            }
            if mode == 3 { service.desktopNavigationAvailable = false }
            let delegate = TestKeyboardDelegate()
            #expect(service.start(delegate: delegate))
            defer { service.stop() }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: true)!
            event.flags = [.maskCommand, .maskAlternate]
            #expect(service.handleCGEvent(type: .keyDown, event: event) != nil)
            #expect(delegate.receivedEvents.isEmpty)
        }
    }

    private func fixture() -> (SpaceController, MockWindowService, MockSpaceSwitcher) {
        let windows = MockWindowService()
        let spaces = MockSpaceSwitcher(desktops: 4)
        spaces.switchChangesDesktop = false
        let controller = SpaceController(windowService: windows, keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .init(windowID: 102, frame: nil, isFullscreen: false) })
        controller.spaceSwitcher = spaces
        controller.reconcileSpacesWithDesktops()
        for id in [101, 102] {
            controller.spaceManager.addWindow(.init(windowID: CGWindowID(id), ownerBundleID: "com.test.App",
                ownerName: "App", windowTitle: "W\(id)", ownerPID: 42), toSpaceID: controller.spaceManager.spaces[0].id)
            spaces.windowDesktops[CGWindowID(id)] = 0
        }
        return (controller, windows, spaces)
    }

    @Test("A move targets actual focus and only focuses after its desktop arrives")
    func followsFocusedWindow() {
        let (controller, windows, spaces) = fixture()
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        #expect(spaces.moveRequests.map(\.windowID) == [102])
        #expect(spaces.switchRequests == [1])
        #expect(windows.frontedWindows.isEmpty)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101])
        spaces.current = 1
        controller.desktopDidChange()
        #expect(windows.frontedWindows.last == .init(windowID: 102, ownerPID: 42))
        #expect(controller.spaceManager.activeSpaceID == controller.spaceManager.spaces[1].id)
    }

    @Test("Three presses retain their window and wait for each desktop before the next move")
    func chainsMoves() {
        let (controller, windows, spaces) = fixture()
        for _ in 0..<3 { controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1)) }
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        #expect(spaces.switchRequests == [1])
        #expect(windows.frontedWindows.isEmpty)
        for desktop in 1...3 {
            spaces.current = desktop
            controller.desktopDidChange()
            #expect(windows.frontedWindows.last == .init(windowID: 102, ownerPID: 42))
        }
        #expect(spaces.moveRequests.map(\.windowID) == [102, 102, 102])
        #expect(spaces.moveRequests.map(\.desktop) == [1, 2, 3])
        #expect(spaces.switchRequests == [1, 2, 3])
        #expect(controller.spaceManager.spaces[3].windows.map(\.windowID) == [102])
    }

    @Test("A desktop reported early cannot start the next move before its notification")
    func earlyDesktopReadbackDoesNotAdvance() {
        let (controller, _, spaces) = fixture()
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        spaces.current = 1
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        controller.desktopDidChange()
        #expect(spaces.moveRequests.map(\.desktop) == [1, 2])
    }

    @Test("Presses during relocation queue moves through confirmed adjacent desktops")
    func chainsAsynchronousMoves() {
        let (controller, _, spaces) = fixture()
        spaces.completesMovesImmediately = false
        for _ in 0..<3 { controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1)) }
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101, 102])
        for desktop in 1...3 {
            spaces.completeNextMove()
            #expect(spaces.switchRequests.last == desktop)
            spaces.current = desktop
            controller.desktopDidChange()
        }
        #expect(spaces.moveRequests.map(\.desktop) == [1, 2, 3])
        #expect(controller.spaceManager.spaces[3].windows.map(\.windowID) == [102])
    }

    @Test("A stale AX window on another desktop cannot hide the app window actually in front")
    func staleAXFocusUsesVisibleWindow() {
        let (controller, windows, spaces) = fixture()
        controller.spaceManager.moveWindow(windowID: 101,
            fromSpaceID: controller.spaceManager.spaces[0].id,
            toSpaceID: controller.spaceManager.spaces[1].id)
        spaces.windowDesktops[101] = 1
        spaces.current = 1
        controller.spaceManager.activateSpace(id: controller.spaceManager.spaces[1].id)
        windows.frontmostPID = 42
        windows.visibleFrontWindowID = 101
        // AX still names this app's window 102 on desktop 0, as multi-window apps can do
        // after a switch. WindowServer independently names window 101 on the showing desktop.
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        #expect(spaces.moveRequests.map(\.windowID) == [101])
        #expect(spaces.moveRequests.map(\.desktop) == [2])
    }

    @Test("A stale focus report from another app cannot override the app in front")
    func staleFocusFromAnotherAppUsesFrontmostWindow() {
        let (controller, windows, spaces) = fixture()
        controller.spaceManager.addWindow(.init(windowID: 103, ownerBundleID: "com.test.Other",
            ownerName: "Other", windowTitle: "Frontmost", ownerPID: 43),
            toSpaceID: controller.spaceManager.spaces[0].id)
        spaces.windowDesktops[103] = 0
        windows.frontmostPID = 43
        windows.visibleFrontWindowID = 103

        // The focus probe still reports 102, but the frontmost process and WindowServer agree
        // that 103 is the window that can receive the user's shortcut on this same desktop.
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))

        #expect(spaces.moveRequests.map(\.windowID) == [103])
    }

    @Test("Desktop reconciliation can observe a relocation before its confirmation callback")
    func reconciliationOverlapsConfirmation() {
        let (controller, _, spaces) = fixture()
        spaces.completesMovesImmediately = false
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        // The preceding desktop hop can trigger refreshDesktopAssignments while this move's
        // completion is still queued. Membership already agrees with macOS at that point.
        controller.spaceManager.moveWindow(windowID: 102,
            fromSpaceID: controller.spaceManager.spaces[0].id,
            toSpaceID: controller.spaceManager.spaces[1].id)
        spaces.completeNextMove()
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        spaces.current = 1
        controller.desktopDidChange()
        #expect(spaces.moveRequests.map(\.desktop) == [1, 2])
        spaces.completeNextMove()
        #expect(spaces.switchRequests.last == 2)
        #expect(controller.spaceManager.spaces[2].windows.map(\.windowID) == [102])
    }

    @Test("A reverse press returns after the already-started desktop hop")
    func reversesMove() {
        let (controller, windows, spaces) = fixture()
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(-1))
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        #expect(windows.frontedWindows.isEmpty)
        spaces.current = 1
        controller.desktopDidChange()
        #expect(spaces.moveRequests.map(\.desktop) == [1, 0])
        #expect(spaces.switchRequests == [1, 0])
        spaces.current = 0
        controller.desktopDidChange()
        #expect(windows.frontedWindows.last == .init(windowID: 102, ownerPID: 42))
    }

    @Test("An explicit quick switch ends the window traversal")
    func anotherCommandEndsTraversal() {
        let (controller, _, spaces) = fixture()
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        #expect(spaces.moveRequests.map(\.desktop) == [1])
        spaces.switchingStackIDs = [SpaceTopology.sharedStackID]
        controller.handleKeyEvent(.switchToSpace(1))
        spaces.current = 0
        spaces.switchingStackIDs = []
        controller.desktopDidChange()
        // The focused-window fixture still reports 102, but it is now on another desktop.
        // The abandoned traversal must not let a later press move that hidden window again.
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        #expect(spaces.moveRequests.map(\.desktop) == [1])
    }

    @Test("A refused relocation never changes model or desktop; stage boundaries do nothing")
    func refusedAndBoundary() {
        let (controller, _, spaces) = fixture()
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(-1))
        #expect(spaces.moveRequests.isEmpty)
        spaces.canMoveWindows = false
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        #expect(spaces.moveRequests.isEmpty)
        spaces.canMoveWindows = true
        spaces.moveSucceeds = false
        controller.handleKeyEvent(.moveFocusedWindowToAdjacentSpace(1))
        #expect(spaces.switchRequests.isEmpty)
        #expect(controller.spaceManager.spaces[0].windows.map(\.windowID) == [101, 102])
    }
}
