import CoreGraphics
import Testing
@testable import DebutCore

@Suite("Overlay display resolution")
struct OverlayDisplayResolverTests {
    private let left = DesktopScreenDescriptor(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    private let right = DesktopScreenDescriptor(
        displayID: 2,
        frame: CGRect(x: 1920, y: 0, width: 1440, height: 900)
    )

    @Test("The overlay opens on the display holding the focused window")
    func focusedWindowDisplayWins() {
        let display = OverlayDisplayResolver.resolve(
            focusedWindowFrame: CGRect(x: 2000, y: 100, width: 800, height: 600),
            displays: [left, right],
            mainDisplayID: 1
        )

        #expect(display == 2)
    }

    @Test("A window straddling two displays opens on the one showing most of it")
    func straddlingWindowPicksLargestOverlap() {
        // 700pt of width lands on the left display, 300pt on the right.
        let display = OverlayDisplayResolver.resolve(
            focusedWindowFrame: CGRect(x: 1220, y: 100, width: 1000, height: 600),
            displays: [left, right],
            mainDisplayID: 2
        )

        #expect(display == 1)
    }

    @Test("Without a focused window the overlay stays on the main display")
    func missingFrameFallsBackToMain() {
        let display = OverlayDisplayResolver.resolve(
            focusedWindowFrame: nil,
            displays: [left, right],
            mainDisplayID: 2
        )

        #expect(display == 2)
    }

    @Test("A frame touching no display falls back to the main display")
    func offscreenFrameFallsBackToMain() {
        let display = OverlayDisplayResolver.resolve(
            focusedWindowFrame: CGRect(x: -4000, y: -4000, width: 100, height: 100),
            displays: [left, right],
            mainDisplayID: 2
        )

        #expect(display == 2)
    }

    @Test("A zero-sized focused frame still resolves by the display containing it")
    func degenerateFrameResolvesByContainment() {
        // AX reports a zero size for some windows mid-transition; the origin is still a
        // truthful answer to "which display", and intersection area alone would discard it.
        let display = OverlayDisplayResolver.resolve(
            focusedWindowFrame: CGRect(x: 2500, y: 400, width: 0, height: 0),
            displays: [left, right],
            mainDisplayID: 1
        )

        #expect(display == 2)
    }

    @Test("An unknown main display falls back to the first connected display")
    func unknownMainFallsBackToFirstDisplay() {
        let display = OverlayDisplayResolver.resolve(
            focusedWindowFrame: nil,
            displays: [left, right],
            mainDisplayID: nil
        )

        #expect(display == 1)
    }

    @Test("No connected display resolves to nothing")
    func noDisplaysResolveToNothing() {
        let display = OverlayDisplayResolver.resolve(
            focusedWindowFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            displays: [],
            mainDisplayID: 1
        )

        #expect(display == nil)
    }

    @Test("The display top inset includes an auto-hidden menu bar")
    func topInsetIncludesAutoHiddenMenuBar() {
        let inset = OverlayDisplayResolver.topContentInset(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTopInset: 0,
            menuBarHeight: 22
        )

        #expect(inset == 22)
    }

    @Test("The display top inset preserves a larger hardware safe area")
    func topInsetPreservesHardwareSafeArea() {
        let inset = OverlayDisplayResolver.topContentInset(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1093),
            safeAreaTopInset: 38,
            menuBarHeight: 22
        )

        #expect(inset == 38)
    }
}
