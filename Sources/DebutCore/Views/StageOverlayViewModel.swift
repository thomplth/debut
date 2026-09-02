import Foundation
import CoreGraphics

public struct StageWindowData: Sendable, Identifiable {
    public let id: CGWindowID
    public let windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public let windowTitle: String
    public let previewImage: CGImage?
    /// The window's own width over its height, when it has been measured. The card takes this
    /// shape; `nil` leaves it on the display's, which is what every card had before.
    public let contentAspect: CGFloat?

    public init(
        id: CGWindowID,
        windowID: CGWindowID,
        ownerBundleID: String,
        ownerName: String,
        windowTitle: String,
        previewImage: CGImage?,
        contentAspect: CGFloat? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.previewImage = previewImage
        self.contentAspect = contentAspect
    }

    public var displayTitle: String {
        SpaceWindow.displayTitle(windowTitle: windowTitle, ownerName: ownerName)
    }

    /// One card for a window, taking its own shape when the overlay knows the window's size and
    /// the user has left adaptive sizing on.
    static func card(
        for window: SpaceWindow,
        previews: [CGWindowID: CGImage],
        sizes: [CGWindowID: CGSize],
        adaptive: Bool
    ) -> StageWindowData {
        StageWindowData(
            id: window.windowID,
            windowID: window.windowID,
            ownerBundleID: window.ownerBundleID,
            ownerName: window.ownerName,
            windowTitle: window.windowTitle,
            previewImage: previews[window.windowID],
            contentAspect: adaptive ? contentAspect(of: sizes[window.windowID]) : nil
        )
    }

    /// A window with no area has no shape to take, so it falls back to the display's.
    static func contentAspect(of size: CGSize?) -> CGFloat? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}

public struct StageData: Sendable, Identifiable {
    public let id: UUID
    public let windows: [StageWindowData]
    public let isActive: Bool
    public let index: Int
}

public struct StageOverlayViewModel: Sendable {
    public let spaceManager: SpaceManager
    public var activeSpaceIndex: Int
    public var selectedWindowIndex: Int
    public let windowPreviews: [CGWindowID: CGImage]
    /// The size each window was last discovered at. Read from `WindowInfo.bounds` rather than
    /// from a preview, which arrives asynchronously and would reshape the grid mid-overlay.
    public let windowSizes: [CGWindowID: CGSize]
    public var appearance: AppSettings
    /// Mean brightness of the wallpaper the overlay is drawn over, when it could be measured.
    public var wallpaperLuminance: Double?
    /// Test-only presentation mode used by the single-display Tart guest so screenshots can
    /// review the display indicator without changing normal display-stack behavior.
    public var forceDisplayStackIndicator: Bool

    public var displayStackName: String {
        spaceManager.selectedSpaceStack?.displayName ?? "Display"
    }

    public var displayStackPosition: Int {
        (spaceManager.connectedSpaceStacks.firstIndex {
            $0.id == spaceManager.selectedSpaceStackID
        } ?? 0) + 1
    }

    public var displayStackCount: Int {
        max(spaceManager.connectedSpaceStacks.count, forceDisplayStackIndicator ? 2 : 0)
    }

    public var shouldShowDisplayStackIndicator: Bool { displayStackCount > 1 }

    public var displayStackShortcut: String {
        guard let combo = appearance.keyBindings.combo(for: .nextDisplayStack) else { return "" }
        return combo.displayStackShortcutString
    }

    public var displayStackShortcutSpacing: CGFloat { 3.5 }

    public init(spaceManager: SpaceManager, activeSpaceIndex: Int, selectedWindowIndex: Int, windowPreviews: [CGWindowID: CGImage] = [:], windowSizes: [CGWindowID: CGSize] = [:], appearance: AppSettings = AppSettings(), wallpaperLuminance: Double? = nil, forceDisplayStackIndicator: Bool = false) {
        self.spaceManager = spaceManager
        self.activeSpaceIndex = activeSpaceIndex
        self.selectedWindowIndex = selectedWindowIndex
        self.windowPreviews = windowPreviews
        self.windowSizes = windowSizes
        self.appearance = appearance
        self.wallpaperLuminance = wallpaperLuminance
        self.forceDisplayStackIndicator = forceDisplayStackIndicator
    }

    public var stages: [StageData] {
        spaceManager.spaces.enumerated().map { index, space in
            StageData(
                id: space.id,
                windows: space.windows.map(card(for:)),
                isActive: index == activeSpaceIndex,
                index: index
            )
        }
    }

    private func card(for window: SpaceWindow) -> StageWindowData {
        StageWindowData.card(
            for: window,
            previews: windowPreviews,
            sizes: windowSizes,
            adaptive: appearance.adaptiveCardSizing
        )
    }

    public var selectedWindow: StageWindowData? {
        guard spaceManager.spaces.indices.contains(activeSpaceIndex) else { return nil }
        let space = spaceManager.spaces[activeSpaceIndex]
        guard space.windows.indices.contains(selectedWindowIndex) else { return nil }
        return card(for: space.windows[selectedWindowIndex])
    }

    public func isSelected(spaceIndex: Int, windowIndex: Int) -> Bool {
        spaceIndex == activeSpaceIndex && windowIndex == selectedWindowIndex
    }
}
