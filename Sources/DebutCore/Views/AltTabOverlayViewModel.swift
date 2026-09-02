import CoreGraphics
import Foundation

/// What the flat switcher draws: every live window, from every space of every display, as one
/// list. Cards are `StageWindowData` and the grid is `StageWindowLayout`, so a card here and a
/// card on a stage cannot disagree about how big it is or what it is called.
public struct AltTabOverlayViewModel: Sendable {
    public let windows: [StageWindowData]
    public var selectedIndex: Int
    public var appearance: AppSettings
    /// The inset macOS reserves at the top of the display for the menu bar or hardware.
    public var displayTopContentInset: CGFloat

    public init(
        entries: [GlobalWindowEntry],
        selectedIndex: Int,
        windowPreviews: [CGWindowID: CGImage] = [:],
        windowSizes: [CGWindowID: CGSize] = [:],
        appearance: AppSettings = AppSettings(),
        displayTopContentInset: CGFloat = 0
    ) {
        self.windows = entries.map {
            StageWindowData.card(
                for: $0.window,
                previews: windowPreviews,
                sizes: windowSizes,
                adaptive: appearance.adaptiveCardSizing
            )
        }
        self.selectedIndex = selectedIndex
        self.appearance = appearance
        self.displayTopContentInset = displayTopContentInset
    }

    public var selectedWindow: StageWindowData? { windows[safe: selectedIndex] }

    public func isSelected(_ index: Int) -> Bool {
        index == selectedIndex && windows.indices.contains(index)
    }

    /// The list is one stage holding every window, so it fits itself the same way a stack of
    /// stages does — by walking the scale slider's own steps down until the grid fits.
    public func metrics(containerSize: CGSize) -> StageMetrics {
        StageConstants.drawnMetrics(
            stageScale: CGFloat(appearance.stageScale),
            contentAspects: [windows.map(\.contentAspect)],
            containerSize: containerSize
        )
    }

    public func layout(containerSize: CGSize) -> StageWindowLayout {
        StageWindowLayout(
            contentAspects: windows.map(\.contentAspect),
            availableWidth: StageConstants.availableStageWidth(screenWidth: containerSize.width),
            metrics: metrics(containerSize: containerSize)
        )
    }
}
