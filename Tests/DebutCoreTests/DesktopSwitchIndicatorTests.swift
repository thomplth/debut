import AppKit
import Testing
@testable import DebutCore

@MainActor
@Suite("Desktop switch indicator")
struct DesktopSwitchIndicatorTests {
    private func topology(currentOnSecondDisplay: CGSSpaceID) -> SpaceTopology {
        SpaceTopology(separateSpaces: true, stacks: [
            SpaceStackDescriptor(
                id: "display-a",
                displayID: 41,
                displayName: "Built-in Display",
                frame: .zero,
                desktopIDs: [100, 101],
                currentDesktopID: 100
            ),
            SpaceStackDescriptor(
                id: "display-b",
                displayID: 42,
                displayName: "Studio Display",
                frame: .zero,
                desktopIDs: [200, 201, 202, 203],
                currentDesktopID: currentOnSecondDisplay
            ),
        ])
    }

    @Test("Indicator copy uses a one-based desktop position")
    func copy() {
        let presentation = DesktopSwitchIndicatorPresentation(
            stackID: "display-a",
            displayID: 42,
            displayName: "Studio Display",
            desktopPosition: 1,
            desktopCount: 4
        )

        #expect(presentation.title == "Desktop 1 of 4")
        #expect(presentation.accessibilityLabel == "Studio Display, desktop 1 of 4")
    }

    @Test("Indicator uses the overlay header position on its display")
    func placement() {
        let frame = DesktopSwitchIndicatorWindow.frame(
            screenFrame: CGRect(x: 1200, y: -200, width: 1440, height: 900),
            topContentInset: 32,
            indicatorSize: CGSize(width: 180, height: 38)
        )

        #expect(frame.midX == 1920)
        #expect(frame.maxY == 650)
    }

    @Test("Indicator shifts up when the menu bar is auto-hidden")
    func placementWithAutoHiddenMenuBar() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleMenuBarInset = OverlayDisplayResolver.topContentInset(
            frame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1054),
            safeAreaTopInset: 0
        )
        let hiddenMenuBarInset = OverlayDisplayResolver.topContentInset(
            frame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaTopInset: 0
        )
        let size = CGSize(width: 180, height: 38)
        let belowVisibleMenuBar = DesktopSwitchIndicatorWindow.frame(
            screenFrame: screenFrame,
            topContentInset: visibleMenuBarInset,
            indicatorSize: size
        )
        let belowHiddenMenuBar = DesktopSwitchIndicatorWindow.frame(
            screenFrame: screenFrame,
            topContentInset: hiddenMenuBarInset,
            indicatorSize: size
        )

        #expect(belowHiddenMenuBar.maxY - belowVisibleMenuBar.maxY == 26)
        #expect(belowHiddenMenuBar.maxY == screenFrame.maxY - DesktopSwitchIndicatorWindow.topPadding)
    }

    @Test("Indicator retains the configured overlay glass style")
    func glassStyle() {
        let presentation = DesktopSwitchIndicatorPresentation(
            stackID: "display-a",
            displayID: 42,
            displayName: "Studio Display",
            desktopPosition: 2,
            desktopCount: 4
        )

        #expect(DesktopSwitchIndicatorView(
            presentation: presentation,
            glassStyle: .clear
        ).glassStyle == .clear)
        #expect(DesktopSwitchIndicatorView(
            presentation: presentation,
            glassStyle: .regular
        ).glassStyle == .regular)
    }

    @Test("Presentation policy honors the setting and an open overlay")
    func presentationPolicy() {
        let change = DesktopSwitchIndicatorPresentation(
            stackID: "display-a",
            displayID: 42,
            displayName: "Studio Display",
            desktopPosition: 2,
            desktopCount: 4
        )

        #expect(DesktopSwitchIndicatorPolicy.presentations(
            for: [change], isEnabled: true, overlayVisible: false
        ) == [change])
        #expect(DesktopSwitchIndicatorPolicy.presentations(
            for: [change], isEnabled: false, overlayVisible: false
        ).isEmpty)
        #expect(DesktopSwitchIndicatorPolicy.presentations(
            for: [change], isEnabled: true, overlayVisible: true
        ).isEmpty)
    }

    @Test("Only the display stack that moved emits a presentation")
    func changedDisplayStack() throws {
        var tracker = DesktopSwitchIndicatorTracker()
        tracker.seed(with: topology(currentOnSecondDisplay: 200))

        let changes = tracker.recordConfirmedChanges(
            in: topology(currentOnSecondDisplay: 202)
        )

        #expect(changes.count == 1)
        let change = try #require(changes.first)
        #expect(change.stackID == "display-b")
        #expect(change.displayID == 42)
        #expect(change.displayName == "Studio Display")
        #expect(change.desktopPosition == 3)
        #expect(change.desktopCount == 4)
    }

    @Test("Indicator dwell is one second")
    func dwellDuration() {
        #expect(DesktopSwitchIndicatorWindow.visibleDuration == 1)
        #expect(DesktopSwitchIndicatorWindow.fadeDuration < 0.2)
    }

    @Test("Indicator can appear over fullscreen apps without taking input")
    func windowBehavior() {
        let window = DesktopSwitchIndicatorWindow()

        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.ignoresMouseEvents)
        #expect(!window.hidesOnDeactivate)
    }

    @Test("A stale dismissal cannot hide a refreshed indicator")
    func staleDismissalCannotHideRefresh() {
        let window = DesktopSwitchIndicatorWindow()
        let firstGeneration = window.beginPresentation()
        let secondGeneration = window.beginPresentation()

        #expect(!window.dismissIfCurrent(generation: firstGeneration, animated: false))
        #expect(window.dismissIfCurrent(generation: secondGeneration, animated: false))
    }
}
