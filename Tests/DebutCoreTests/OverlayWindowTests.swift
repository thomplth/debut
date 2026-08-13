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
}
