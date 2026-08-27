import Foundation
import CoreGraphics

public struct StageWindowData: Sendable, Identifiable {
    public let id: CGWindowID
    public let windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public let windowTitle: String
    public let previewImage: CGImage?

    public var displayTitle: String {
        SpaceWindow.displayTitle(windowTitle: windowTitle, ownerName: ownerName)
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
    public var appearance: AppSettings
    /// Mean brightness of the wallpaper the overlay is drawn over, when it could be measured.
    public var wallpaperLuminance: Double?
    /// The inset macOS reserves at the top of the display for the menu bar or hardware.
    public var displayTopContentInset: CGFloat
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
        guard appearance.shouldShowCommandHint(for: .nextDisplayStack),
              let combo = appearance.keyBindings.combo(for: .nextDisplayStack)
        else { return "" }
        return combo.commandHintDisplayString
    }

    public var displayStackShortcutSpacing: CGFloat { 3.5 }

    public var displayStackIndicatorTopPadding: CGFloat {
        max(0, displayTopContentInset) + 18
    }

    public init(spaceManager: SpaceManager, activeSpaceIndex: Int, selectedWindowIndex: Int, windowPreviews: [CGWindowID: CGImage] = [:], appearance: AppSettings = AppSettings(), wallpaperLuminance: Double? = nil, displayTopContentInset: CGFloat = 0, forceDisplayStackIndicator: Bool = false) {
        self.spaceManager = spaceManager
        self.activeSpaceIndex = activeSpaceIndex
        self.selectedWindowIndex = selectedWindowIndex
        self.windowPreviews = windowPreviews
        self.appearance = appearance
        self.wallpaperLuminance = wallpaperLuminance
        self.displayTopContentInset = displayTopContentInset
        self.forceDisplayStackIndicator = forceDisplayStackIndicator
    }

    public var stages: [StageData] {
        spaceManager.spaces.enumerated().map { index, space in
            StageData(
                id: space.id,
                windows: space.windows.map { window in
                    StageWindowData(
                        id: window.windowID,
                        windowID: window.windowID,
                        ownerBundleID: window.ownerBundleID,
                        ownerName: window.ownerName,
                        windowTitle: window.windowTitle,
                        previewImage: windowPreviews[window.windowID]
                    )
                },
                isActive: index == activeSpaceIndex,
                index: index
            )
        }
    }

    public var selectedWindow: StageWindowData? {
        guard spaceManager.spaces.indices.contains(activeSpaceIndex) else { return nil }
        let space = spaceManager.spaces[activeSpaceIndex]
        guard space.windows.indices.contains(selectedWindowIndex) else { return nil }
        let window = space.windows[selectedWindowIndex]
        return StageWindowData(
            id: window.windowID,
            windowID: window.windowID,
            ownerBundleID: window.ownerBundleID,
            ownerName: window.ownerName,
            windowTitle: window.windowTitle,
            previewImage: windowPreviews[window.windowID]
        )
    }

    public func isSelected(spaceIndex: Int, windowIndex: Int) -> Bool {
        spaceIndex == activeSpaceIndex && windowIndex == selectedWindowIndex
    }
}
