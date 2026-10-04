import Testing
import Foundation
import CoreGraphics
@testable import DebutCore

/// A window an app assigns to All Desktops (Dock → Options) is on every desktop at once, so it
/// belongs to whichever one is showing and keeps one place in the global MRU order (KHA-853).
@Suite("Windows assigned to all desktops")
struct AllDesktopsWindowTests {
    private static let music: CGWindowID = 9
    private static let safari: CGWindowID = 5
    private static let notes: CGWindowID = 6

    private func makeController(current: Int) -> (SpaceController, MockSpaceSwitcher) {
        let spaces = MockSpaceSwitcher(desktops: 3, current: current)
        let controller = SpaceController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.spaceSwitcher = spaces
        controller.reconcileSpacesWithDesktops()
        return (controller, spaces)
    }

    private func add(_ windowID: CGWindowID, _ bundleID: String, to index: Int,
                     activatedAt: Date?, in controller: SpaceController) {
        let spaceID = controller.spaceManager.spaces[index].id
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: windowID, ownerBundleID: bundleID, ownerName: bundleID,
                        windowTitle: "\(windowID)", ownerPID: pid_t(windowID)),
            toSpaceID: spaceID)
        if let activatedAt {
            controller.spaceManager.bringWindowToFront(
                windowID: windowID, inSpaceID: spaceID, activatedAt: activatedAt)
        }
    }

    private func ids(_ controller: SpaceController, _ index: Int) -> [CGWindowID] {
        controller.spaceManager.spaces[index].windows.map(\.windowID)
    }

    /// Music was focused on desktop 2, then the user switched to desktop 1 with Ctrl+number or
    /// a swipe. macOS keeps Music in front, so Debut must too: it is on desktop 1 now, and still
    /// the most recent window everywhere.
    private func focusMusicOnDesktopTwoThenShowDesktopOne() -> (SpaceController, MockSpaceSwitcher) {
        let (controller, spaces) = makeController(current: 1)
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        add(Self.notes, "com.apple.Notes", to: 0, activatedAt: nil, in: controller)
        add(Self.safari, "com.apple.Safari", to: 0, activatedAt: base, in: controller)
        add(Self.music, "com.apple.Music", to: 1, activatedAt: base + 10, in: controller)
        spaces.windowDesktops = [Self.safari: 0, Self.notes: 0]
        spaces.allDesktopWindowIDs = [Self.music]

        spaces.current = 0
        controller.desktopDidChange()
        return (controller, spaces)
    }

    @Test("Switching desktops brings an all-desktops window along, keeping its MRU place")
    func followsShowingDesktop() {
        let (controller, _) = focusMusicOnDesktopTwoThenShowDesktopOne()

        #expect(ids(controller, 0) == [Self.music, Self.safari, Self.notes])
        #expect(ids(controller, 1).isEmpty)
        #expect(controller.spaceManager.globalWindowOrder().first?.window.windowID == Self.music)
    }

    @Test("Switching to another app on the new desktop leaves the all-desktops window second")
    func secondAfterSwitchingAway() {
        let (controller, _) = focusMusicOnDesktopTwoThenShowDesktopOne()

        controller.recordWindowActivation(windowID: Self.safari)

        #expect(ids(controller, 0) == [Self.safari, Self.music, Self.notes])
        #expect(controller.spaceManager.globalWindowOrder().map(\.window.windowID)
            == [Self.safari, Self.music, Self.notes])
    }

    @Test("An all-desktops window never activated slots behind every stamped window")
    func unstampedJoinsBehindStamped() {
        let (controller, spaces) = makeController(current: 1)
        add(Self.safari, "com.apple.Safari", to: 0,
            activatedAt: Date(timeIntervalSinceReferenceDate: 1_000), in: controller)
        add(Self.music, "com.apple.Music", to: 1, activatedAt: nil, in: controller)
        spaces.windowDesktops = [Self.safari: 0]
        spaces.allDesktopWindowIDs = [Self.music]

        spaces.current = 0
        controller.desktopDidChange()

        #expect(ids(controller, 0) == [Self.safari, Self.music])
    }

    /// Focus can reach the window before any desktop change re-files it — the app was just
    /// assigned to All Desktops, or Debut launched with it filed on another desktop.
    @Test("Focusing an all-desktops window files it under the desktop showing")
    func activationFilesOnShowingDesktop() {
        let (controller, spaces) = makeController(current: 0)
        add(Self.safari, "com.apple.Safari", to: 0,
            activatedAt: Date(timeIntervalSinceReferenceDate: 1_000), in: controller)
        add(Self.music, "com.apple.Music", to: 1, activatedAt: nil, in: controller)
        spaces.windowDesktops = [Self.safari: 0]
        spaces.allDesktopWindowIDs = [Self.music]

        controller.recordWindowActivation(windowID: Self.music)

        #expect(ids(controller, 0) == [Self.music, Self.safari])
        #expect(ids(controller, 1).isEmpty)
    }

    @Test("Launch reconciliation files an all-desktops window under the desktop showing")
    func launchFilesOnShowingDesktop() {
        let (controller, spaces) = makeController(current: 2)
        add(Self.music, "com.apple.Music", to: 1, activatedAt: nil, in: controller)
        spaces.allDesktopWindowIDs = [Self.music]

        controller.reconcileSpacesWithDesktops()

        #expect(ids(controller, 2) == [Self.music])
        #expect(ids(controller, 1).isEmpty)
    }

    /// Silence is not evidence of being everywhere: a window SkyLight places on no desktop at
    /// all must keep its assignment rather than be dragged along.
    @Test("A window with no desktop answer stays where it is filed")
    func silenceDoesNotFollow() {
        let (controller, spaces) = makeController(current: 1)
        add(Self.music, "com.apple.Music", to: 1, activatedAt: nil, in: controller)

        spaces.current = 0
        controller.desktopDidChange()

        #expect(ids(controller, 1) == [Self.music])
    }
}
