import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@MainActor
@Suite("Alt-tab switcher")
struct AltTabSwitcherTests {
    private func makeController() -> (SpaceController, MockWindowService) {
        let windowService = MockWindowService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused }
        )
        return (controller, windowService)
    }

    private func window(
        _ id: CGWindowID,
        pid: pid_t? = nil,
        activatedAt: Date? = nil
    ) -> SpaceWindow {
        SpaceWindow(
            windowID: id,
            ownerBundleID: "com.test.\(id)",
            ownerName: "App \(id)",
            windowTitle: "Window \(id)",
            ownerPID: pid,
            lastActivatedAt: activatedAt
        )
    }

    /// Two spaces, each holding one window, with the global MRU order 101 then 202.
    private func makeTwoSpaceController() -> (SpaceController, MockWindowService) {
        let (controller, windowService) = makeController()
        let spaceA = controller.spaceManager.spaces[0].id
        controller.spaceManager.createSpace(position: .below)
        let spaceB = controller.spaceManager.spaces[1].id
        let now = Date()
        controller.spaceManager.addWindow(
            window(101, pid: 11, activatedAt: now),
            toSpaceID: spaceA
        )
        controller.spaceManager.addWindow(
            window(202, pid: 22, activatedAt: now.addingTimeInterval(-10)),
            toSpaceID: spaceB
        )
        controller.spaceManager.activateSpace(id: spaceA)
        return (controller, windowService)
    }

    /// The user opened a switcher to leave the window they are on, so a forward summon lands on
    /// the next one — the same bargain Cmd+Tab makes.
    @Test("Opening the switcher selects the next window in global order")
    func opensOnNextWindow() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)

        #expect(controller.overlayMode == .altTab)
        #expect(controller.altTabEntries.map(\.window.windowID) == [101, 202])
        #expect(controller.altTabSelection?.window.windowID == 202)
    }

    /// The activation observer and the shortcut are delivered independently. If the shortcut
    /// wins that race, the stored timestamp still names the window used before the focused one.
    /// Entry zero must describe what the user is actually leaving or the switcher skips an
    /// unrelated window and every subsequent flip appears to change the order arbitrarily.
    @Test("Opening repairs stale MRU from the focused window")
    func openingRepairsStaleFocusedWindow() {
        let now = Date()
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: {
                FocusedWindowSnapshot(windowID: 303, frame: nil, isFullscreen: false)
            }
        )
        let spaceID = controller.spaceManager.activeSpaceID
        controller.spaceManager.addWindow(
            window(101, activatedAt: now),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            window(202, activatedAt: now.addingTimeInterval(-1)),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            window(303, activatedAt: now.addingTimeInterval(-2)),
            toSpaceID: spaceID
        )

        controller.handleKeyEvent(.altTabHold)

        #expect(controller.altTabEntries.map(\.window.windowID) == [303, 101, 202])
        #expect(controller.altTabSelection?.window.windowID == 101)
    }

    @Test("Opening backward selects the last window in global order")
    func opensOnLastWindow() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabShiftHold)

        #expect(controller.altTabSelection?.window.windowID == 202)
    }

    @Test("Cycling forward wraps back to the first window")
    func cyclingWraps() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.altTabHold)

        #expect(controller.altTabSelection?.window.windowID == 101)
    }

    /// A burst of auto-repeats must not yank the selection back to the start mid-cycle.
    @Test("A held repeat clamps at the end of the list")
    func heldRepeatClamps() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.altTabHoldRepeat)
        controller.handleKeyEvent(.altTabHoldRepeat)

        #expect(controller.altTabSelection?.window.windowID == 202)
    }

    /// The stage session owns the held Cmd. Reusing its overlay for a second switcher would
    /// leave the user holding a modifier that no longer commits what they are looking at.
    @Test("Option+Tab is ignored while the stage overlay is open")
    func ignoredWhileStageOverlayIsOpen() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.cmdTabHold)
        controller.handleKeyEvent(.altTabHold)

        #expect(controller.overlayMode == .stages)
        #expect(controller.altTabEntries.isEmpty)
    }

    /// The whole point of a global list: committing reaches a window on a space the user is not
    /// on, without them having found that space first.
    @Test("Committing raises the selected window on its own space")
    func commitRaisesAcrossSpaces() {
        let (controller, windowService) = makeTwoSpaceController()
        let spaceB = controller.spaceManager.spaces[1].id

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.cmdRelease)

        #expect(windowService.raisedWindowIDs.contains(202))
        #expect(controller.spaceManager.activeSpaceID == spaceB)
    }

    @Test("Clicking a flat-list card commits that exact window")
    func pointerCommitSelectsClickedWindow() {
        let (controller, windowService) = makeTwoSpaceController()
        let spaceA = controller.spaceManager.spaces[0].id

        controller.handleKeyEvent(.altTabHold)
        controller.commitAltTabSelection(index: 0)

        #expect(!controller.isSpaceManagerVisible)
        #expect(controller.spaceManager.activeSpaceID == spaceA)
        #expect(windowService.raisedWindowIDs.contains(101))
    }

    /// Quit and close read the stage cursor, so this is the check that the alt-tab cursor is
    /// mirrored onto it — otherwise they would act on whichever window the stage happened to
    /// have selected, on a different space entirely.
    @Test("Closing the selection closes the window under the selector")
    func closeActsOnAltTabSelection() {
        let (controller, windowService) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.closeSelectedWindow)

        #expect(windowService.closedWindowIDs == [202])
    }

    @Test("Quitting the selection quits the app owning the window under the selector")
    func quitActsOnAltTabSelection() {
        let (controller, windowService) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.quitSelectedApp)

        #expect(windowService.terminatedPIDs == [22])
    }

    /// The flat list shows no spaces, so an action that steps between them has nothing to point
    /// at — and it would move the stage cursor the selector is mirrored onto, leaving a later
    /// close or commit acting on a window other than the one on screen.
    @Test("Space navigation is inert while the flat switcher is open")
    func stageNavigationIsInert() {
        let (controller, windowService) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.nextSpace)
        controller.handleKeyEvent(.jumpToSpace(1))

        #expect(controller.altTabSelection?.window.windowID == 202)

        controller.handleKeyEvent(.closeSelectedWindow)

        #expect(windowService.closedWindowIDs == [202])
    }

    /// Stepping a window is the one thing the flat list does show, so the session bindings for it
    /// — bare Tab and bare backtick, reached as Option+Tab and Option+backtick — drive its cursor
    /// rather than the stage's per-space list.
    @Test("Window stepping moves the flat cursor")
    func windowSteppingMovesTheFlatCursor() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.previousWindow)

        #expect(controller.altTabSelection?.window.windowID == 101)

        controller.handleKeyEvent(.nextWindow)

        #expect(controller.altTabSelection?.window.windowID == 202)
    }

    @Test("A held backward repeat clamps at the start of the flat list")
    func heldBackwardRepeatClamps() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.previousWindowRepeat)
        controller.handleKeyEvent(.previousWindowRepeat)

        #expect(controller.altTabSelection?.window.windowID == 101)
    }

    /// Moving a window reassigns its desktop. With no spaces drawn there is nothing to say where
    /// it went, so the flat switcher must not offer an invisible cross-desktop move.
    @Test("Moving a window between spaces is inert while the flat switcher is open")
    func windowMovesAreInert() {
        let (controller, _) = makeTwoSpaceController()
        let spaceB = controller.spaceManager.spaces[1].id

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.moveWindowUp)

        // A move is staged in the overlay transaction, not the committed model, so the preview
        // is the only place a staged reassignment is visible before release.
        #expect(controller.overlaySpaceManager.spaceContainingWindow(windowID: 202) == spaceB)
    }

    private var twoDisplayTopology: SpaceTopology {
        SpaceTopology(separateSpaces: true, stacks: [
            SpaceStackDescriptor(
                id: "display-a",
                displayID: 1,
                displayName: "Built-in Display",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                desktopIDs: [3],
                currentDesktopID: 3
            ),
            SpaceStackDescriptor(
                id: "display-b",
                displayID: 5,
                displayName: "Studio Display",
                frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                desktopIDs: [5338],
                currentDesktopID: 5338
            ),
        ])
    }

    /// A space on another display is only addressable by the stage cursor once its stack is the
    /// selected one. The stage overlay can never reach across displays, so this is the first
    /// selection that has to move the stack — and a commit that did not would raise whichever
    /// window sat at the same index back on the original display.
    @Test("Selecting a window on another display selects that display's stack")
    func selectionMovesAcrossDisplayStacks() {
        let (controller, windowService) = makeController()
        controller.spaceManager.reconcileSpaceStacks(with: twoDisplayTopology)
        let spaceA = controller.spaceManager.spaceStacks[0].spaces[0].id
        let spaceB = controller.spaceManager.spaceStacks[1].spaces[0].id
        let now = Date()
        controller.spaceManager.addWindow(window(101, pid: 11, activatedAt: now), toSpaceID: spaceA)
        controller.spaceManager.addWindow(
            window(202, pid: 22, activatedAt: now.addingTimeInterval(-10)),
            toSpaceID: spaceB
        )
        controller.spaceManager.selectSpaceStack(id: "display-a")

        controller.handleKeyEvent(.altTabHold)

        #expect(controller.altTabSelection?.window.windowID == 202)
        #expect(controller.spaceManager.selectedSpaceStackID == "display-b")

        controller.handleKeyEvent(.cmdRelease)

        #expect(windowService.raisedWindowIDs.contains(202))
    }

    /// A closed window has to leave the flat list too. Leaving it there would let the next cycle
    /// land on a card for a window that no longer exists.
    @Test("Closing a window drops it from the flat list and clamps the selection")
    func closeRefreshesTheFlatList() {
        let (controller, _) = makeTwoSpaceController()

        controller.handleKeyEvent(.altTabHold)
        controller.handleKeyEvent(.closeSelectedWindow)

        #expect(controller.altTabEntries.map(\.window.windowID) == [101])
        #expect(controller.altTabSelection?.window.windowID == 101)
    }
}
