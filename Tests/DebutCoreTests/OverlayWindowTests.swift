import AppKit
import Testing
@testable import DebutCore

@Suite("Overlay window", .serialized)
@MainActor
struct OverlayWindowTests {
    @Test("The overlay is allowed into another app's fullscreen Space")
    func overlayJoinsFullscreenSpaces() {
        // Unlike the desktop surface, the stages have to reach the Space the user is actually
        // looking at, and a fullscreen app owns a Space of its own.
        let window = OverlayWindow()

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.level == .statusBar)
    }

    @Test("Updating content synchronizes the screen frame before layout")
    func updateSynchronizesFrame() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let window = OverlayWindow()
        window.setFrame(.zero, display: false)

        let created = window.update(viewModel: StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(window.frame == screen.frame)
        #expect(created)
    }

    @Test("Removing a window preserves motion then rebases the rendered tree")
    func windowRemovalRebasesRenderedTreeAfterMotion() async throws {
        let window = OverlayWindow()
        var spaceManager = SpaceManager()
        let spaceID = spaceManager.activeSpaceID
        spaceManager.addWindow(
            SpaceWindow(
                windowID: 101,
                ownerBundleID: "com.example.One",
                ownerName: "One",
                windowTitle: "One"
            ),
            toSpaceID: spaceID
        )
        spaceManager.addWindow(
            SpaceWindow(
                windowID: 202,
                ownerBundleID: "com.example.Two",
                ownerName: "Two",
                windowTitle: "Two"
            ),
            toSpaceID: spaceID
        )
        let createdInitialTree = window.update(viewModel: StageOverlayViewModel(
            spaceManager: spaceManager,
            activeSpaceIndex: 0,
            selectedWindowIndex: 1
        ))
        let reusedTree = window.update(viewModel: StageOverlayViewModel(
            spaceManager: spaceManager,
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))
        let initialHostingView = try #require(window.contentView?.subviews.first)

        spaceManager.removeWindow(windowID: 202, fromSpaceID: spaceID)
        let reusedTreeForRemoval = window.update(viewModel: StageOverlayViewModel(
            spaceManager: spaceManager,
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))
        let reusedTreeForLifecycleRefresh = window.update(viewModel: StageOverlayViewModel(
            spaceManager: spaceManager,
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(createdInitialTree)
        #expect(!reusedTree)
        #expect(!reusedTreeForRemoval)
        #expect(!reusedTreeForLifecycleRefresh)
        #expect(window.contentView?.subviews.first === initialHostingView)

        try await Task.sleep(for: .milliseconds(120))

        #expect(window.contentView?.subviews.first === initialHostingView)

        try await Task.sleep(for: .milliseconds(380))

        #expect(window.contentView?.subviews.first !== initialHostingView)
    }

    @Test("The overlay opens on the display it was pointed at")
    func showOverlayUsesTargetDisplayFrame() async throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let target = screen.frame.insetBy(dx: 120, dy: 120)
        let window = OverlayWindow()
        window.targetScreenFrame = target

        _ = window.update(viewModel: StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))
        #expect(window.frame == target)

        await withCheckedContinuation { continuation in
            window.showOverlay(revealDuration: 0) {
                continuation.resume()
            }
        }

        #expect(window.frame == target)
        window.orderOut(nil)
    }

    @Test("Clearing the target display returns the overlay to the main screen")
    func clearedTargetFallsBackToMainScreen() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let window = OverlayWindow()
        window.targetScreenFrame = screen.frame.insetBy(dx: 120, dy: 120)
        _ = window.update(viewModel: StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))

        window.targetScreenFrame = nil
        _ = window.update(viewModel: StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(window.frame == screen.frame)
    }

    @Test("Reveal completion is delivered after ordering and rendering")
    func revealCompletion() async {
        let window = OverlayWindow()
        _ = window.update(viewModel: StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))

        await withCheckedContinuation { continuation in
            window.showOverlay(revealDuration: 0) {
                continuation.resume()
            }
        }

        #expect(window.isVisible)
        #expect(window.alphaValue == 1)
        window.orderOut(nil)
    }

    @Test("The overlay orders front without asking to become the key window")
    func showOrdersFrontWhileInactive() async {
        // Debut is an accessory app, so it is usually inactive when the overlay
        // is shown. A borderless window cannot become key, so asking for key
        // status buys nothing and leaves ordering subject to app activation.
        let window = OverlayWindow()
        _ = window.update(viewModel: StageOverlayViewModel(
            spaceManager: SpaceManager(),
            activeSpaceIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(!window.canBecomeKey)

        await withCheckedContinuation { continuation in
            window.showOverlay(revealDuration: 0) {
                continuation.resume()
            }
        }

        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        #expect(NSApp?.keyWindow !== window)
        window.orderOut(nil)
    }
}
