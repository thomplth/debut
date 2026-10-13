import Testing
@testable import DebutCore

@Suite("Background cursor")
struct BackgroundCursorTests {
    @Test("The overlay lets a background application set the cursor")
    @MainActor
    func overlayEnablesBackgroundCursor() {
        _ = OverlayWindow()
        #expect(BackgroundCursor.isEnabled)
    }
}
