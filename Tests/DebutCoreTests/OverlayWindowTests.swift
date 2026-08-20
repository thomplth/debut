import AppKit
import Testing
@testable import DebutCore

@Suite("Overlay window", .serialized)
@MainActor
struct OverlayWindowTests {
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
