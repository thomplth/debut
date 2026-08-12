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

        window.update(viewModel: OverlayViewModel(
            stageManager: StageManager(),
            activeStageIndex: 0,
            selectedWindowIndex: 0
        ))

        #expect(window.frame == screen.frame)
    }
}
