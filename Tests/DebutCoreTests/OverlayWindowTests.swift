import AppKit
import Testing
@testable import DebutCore

@Suite("Overlay window", .serialized)
@MainActor
struct OverlayWindowTests {
    @Test("The overlay is allowed into another app's fullscreen Space")
    func overlayJoinsFullscreenSpaces() {
        // Unlike the desktop surface, the plates have to reach the Space the user is actually
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

        let created = window.update(viewModel: OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(window.frame == screen.frame)
        #expect(created)
    }

    @Test("Removing a window updates the persistent tree so dismissal motion can run")
    func windowRemovalKeepsRenderedTree() {
        let window = OverlayWindow()
        var stageManager = StageManager()
        let stageID = stageManager.activeStageID
        stageManager.addWindow(
            StageWindow(
                windowID: 101,
                ownerBundleID: "com.example.One",
                ownerName: "One",
                windowTitle: "One"
            ),
            toStageID: stageID
        )
        stageManager.addWindow(
            StageWindow(
                windowID: 202,
                ownerBundleID: "com.example.Two",
                ownerName: "Two",
                windowTitle: "Two"
            ),
            toStageID: stageID
        )
        let createdInitialTree = window.update(viewModel: OverlayViewModel(
            stageManager: stageManager,
            activeStageIndex: 0,
            selectedWindowIndex: 1
        ))
        let reusedTree = window.update(viewModel: OverlayViewModel(
            stageManager: stageManager,
            activeStageIndex: 0,
            selectedWindowIndex: 0
        ))

        stageManager.removeWindow(windowID: 202, fromStageID: stageID)
        let reusedTreeForRemoval = window.update(viewModel: OverlayViewModel(
            stageManager: stageManager,
            activeStageIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(createdInitialTree)
        #expect(!reusedTree)
        #expect(!reusedTreeForRemoval)
    }

    @Test("The overlay opens on the display it was pointed at")
    func showOverlayUsesTargetDisplayFrame() async throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let target = screen.frame.insetBy(dx: 120, dy: 120)
        let window = OverlayWindow()
        window.targetScreenFrame = target

        _ = window.update(viewModel: OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
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
        _ = window.update(viewModel: OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0
        ))

        window.targetScreenFrame = nil
        _ = window.update(viewModel: OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(window.frame == screen.frame)
    }

    @Test("Reveal completion is delivered after ordering and rendering")
    func revealCompletion() async {
        let window = OverlayWindow()
        _ = window.update(viewModel: OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
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
        _ = window.update(viewModel: OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
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
