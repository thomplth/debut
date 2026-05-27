import Foundation

public struct PlateAppData: Sendable {
    public let bundleID: String
    public let name: String
    public let isShared: Bool
}

public struct PlateData: Sendable, Identifiable {
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
                apps: stage.apps.map { app in
                    PlateAppData(bundleID: app.bundleID, name: app.name, isShared: app.isShared)
                },
                isActive: index == activeStageIndex,
                index: index
            )
        }
    }

    public var selectedApp: PlateAppData? {
        guard stageManager.stages.indices.contains(activeStageIndex) else { return nil }
        let stage = stageManager.stages[activeStageIndex]
        guard stage.apps.indices.contains(selectedAppIndex) else { return nil }
        let app = stage.apps[selectedAppIndex]
        return PlateAppData(bundleID: app.bundleID, name: app.name, isShared: app.isShared)
    }

    public func isSelected(stageIndex: Int, appIndex: Int) -> Bool {
        stageIndex == activeStageIndex && appIndex == selectedAppIndex
    }
}
