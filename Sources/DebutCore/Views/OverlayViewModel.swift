import Foundation
import CoreGraphics

public struct PlateWindowData: Sendable, Identifiable {
    public let id: CGWindowID
    public let windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public let windowTitle: String
    public let previewImage: CGImage?
}

public struct PlateData: Sendable, Identifiable {
    public let id: UUID
    public let windows: [PlateWindowData]
    public let isActive: Bool
    public let index: Int
}

public struct OverlayViewModel: Sendable {
    public let stageManager: StageManager
    public var activeStageIndex: Int
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
        stageManager.selectedStageStack?.displayName ?? "Display"
    }

    public var displayStackPosition: Int {
        (stageManager.connectedStageStacks.firstIndex {
            $0.id == stageManager.selectedStageStackID
        } ?? 0) + 1
    }

    public var displayStackCount: Int {
        max(stageManager.connectedStageStacks.count, forceDisplayStackIndicator ? 2 : 0)
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

    public init(stageManager: StageManager, activeStageIndex: Int, selectedWindowIndex: Int, windowPreviews: [CGWindowID: CGImage] = [:], appearance: AppSettings = AppSettings(), wallpaperLuminance: Double? = nil, displayTopContentInset: CGFloat = 0, forceDisplayStackIndicator: Bool = false) {
        self.stageManager = stageManager
        self.activeStageIndex = activeStageIndex
        self.selectedWindowIndex = selectedWindowIndex
        self.windowPreviews = windowPreviews
        self.appearance = appearance
        self.wallpaperLuminance = wallpaperLuminance
        self.displayTopContentInset = displayTopContentInset
        self.forceDisplayStackIndicator = forceDisplayStackIndicator
    }

    public var plates: [PlateData] {
        stageManager.stages.enumerated().map { index, stage in
            PlateData(
                id: stage.id,
                windows: stage.windows.map { window in
                    PlateWindowData(
                        id: window.windowID,
                        windowID: window.windowID,
                        ownerBundleID: window.ownerBundleID,
                        ownerName: window.ownerName,
                        windowTitle: window.windowTitle,
                        previewImage: windowPreviews[window.windowID]
                    )
                },
                isActive: index == activeStageIndex,
                index: index
            )
        }
    }

    public var selectedWindow: PlateWindowData? {
        guard stageManager.stages.indices.contains(activeStageIndex) else { return nil }
        let stage = stageManager.stages[activeStageIndex]
        guard stage.windows.indices.contains(selectedWindowIndex) else { return nil }
        let window = stage.windows[selectedWindowIndex]
        return PlateWindowData(
            id: window.windowID,
            windowID: window.windowID,
            ownerBundleID: window.ownerBundleID,
            ownerName: window.ownerName,
            windowTitle: window.windowTitle,
            previewImage: windowPreviews[window.windowID]
        )
    }

    public func isSelected(stageIndex: Int, windowIndex: Int) -> Bool {
        stageIndex == activeStageIndex && windowIndex == selectedWindowIndex
    }
}
