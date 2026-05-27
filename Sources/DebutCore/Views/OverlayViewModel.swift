import Foundation

public struct PlateAppData: Sendable {
    public let windowID: Int
    public let bundleID: String
    public let name: String
    public let isShared: Bool
}

public struct PlateData: Sendable {
    public let id: UUID
    public let name: String
    public let apps: [PlateAppData]
    public let isActive: Bool
    public let index: Int
}

public struct OverlayViewModel: Sendable {
    public let stageManager: StageManager
    public var activeStageIndex: Int
    public var selectedAppIndex: Int

    public init(stageManager: StageManager, activeStageIndex: Int, selectedAppIndex: Int) {
        self.stageManager = stageManager
        self.activeStageIndex = activeStageIndex
        self.selectedAppIndex = selectedAppIndex
    }

    public var plates: [PlateData] {
        stageManager.stages.enumerated().map { index, stage in
            PlateData(
                id: stage.id,
                name: stage.name,
                apps: stage.windows.map { window in
                    PlateAppData(
                        windowID: window.windowID,
                        bundleID: window.appBundleID,
                        name: window.appName,
                        isShared: window.isShared
                    )
                },
                isActive: index == activeStageIndex,
                index: index
            )
        }
    }

    public var selectedApp: PlateAppData? {
        guard stageManager.stages.indices.contains(activeStageIndex) else { return nil }
        let stage = stageManager.stages[activeStageIndex]
        guard stage.windows.indices.contains(selectedAppIndex) else { return nil }
        let window = stage.windows[selectedAppIndex]
        return PlateAppData(
            windowID: window.windowID,
            bundleID: window.appBundleID,
            name: window.appName,
            isShared: window.isShared
        )
    }

    public func isSelected(stageIndex: Int, appIndex: Int) -> Bool {
        stageIndex == activeStageIndex && appIndex == selectedAppIndex
    }
}
