import Foundation

public enum StageInsertPosition: Codable, Sendable {
    case above
    case below
}

public enum SwapDirection: Sendable {
    case up
    case down
}

public struct StageManager: Codable, Sendable {
    public private(set) var stages: [Stage]
    public private(set) var activeStageID: UUID
    public private(set) var templates: [Template]
    private var nextStageNumber: Int

    public init() {
        let initial = Stage(name: "Stage 1")
        self.stages = [initial]
        self.activeStageID = initial.id
        self.templates = []
        self.nextStageNumber = 2
    }

    public var activeStage: Stage {
        stages.first(where: { $0.id == activeStageID })!
    }

    public func stage(atIndex index: Int) -> Stage? {
        guard stages.indices.contains(index) else { return nil }
        return stages[index]
    }

    // MARK: - Stage lifecycle

    public mutating func createStage(name: String? = nil, position: StageInsertPosition) {
        let stageName = name ?? "Stage \(nextStageNumber)"
        nextStageNumber += 1
        let newStage = Stage(name: stageName)

        guard let activeIndex = stages.firstIndex(where: { $0.id == activeStageID }) else { return }

        switch position {
        case .above:
            stages.insert(newStage, at: activeIndex)
        case .below:
            stages.insert(newStage, at: activeIndex + 1)
        }

        activeStageID = newStage.id
    }

    public mutating func deleteStage(id: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
        let deletedStage = stages[index]

        if stages.count == 1 {
            stages.removeAll()
            let newDefault = Stage(name: "Stage 1")
            stages = [newDefault]
            activeStageID = newDefault.id
            nextStageNumber = 2
            return
        }

        let overflowIndex: Int
        if index == 0 { overflowIndex = 1 }
        else { overflowIndex = index - 1 }

        for app in deletedStage.apps {
            stages[overflowIndex].addApp(app)
        }

        stages.remove(at: index)
        let newActiveIndex = min(overflowIndex, stages.count - 1)
        activeStageID = stages[newActiveIndex].id
    }

    public mutating func renameStage(id: UUID, to newName: String) {
        guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
        stages[index].name = newName
    }

    // MARK: - Stage reordering

    public mutating func swapStage(id: UUID, direction: SwapDirection) {
        guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
        switch direction {
        case .up:
            guard index > 0 else { return }
            stages.swapAt(index, index - 1)
        case .down:
            guard index < stages.count - 1 else { return }
            stages.swapAt(index, index + 1)
        }
    }

    // MARK: - Active stage

    public mutating func activateStage(id: UUID) {
        guard stages.contains(where: { $0.id == id }) else { return }
        activeStageID = id
    }

    // MARK: - App management

    public mutating func addApp(_ app: StageApp, toStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].addApp(app)
    }

    public mutating func removeApp(bundleID: String, fromStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].removeApp(bundleID: bundleID)
    }

    public mutating func moveApp(bundleID: String, fromStageID: UUID, toStageID: UUID) {
        guard let fromIndex = stages.firstIndex(where: { $0.id == fromStageID }),
              let toIndex = stages.firstIndex(where: { $0.id == toStageID }),
              let app = stages[fromIndex].apps.first(where: { $0.bundleID == bundleID })
        else { return }
        stages[fromIndex].removeApp(bundleID: bundleID)
        stages[toIndex].addApp(app)
    }

    public mutating func bringAppToFront(bundleID: String, inStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].bringAppToFront(bundleID: bundleID)
    }

    public mutating func markAppShared(bundleID: String, inStageID stageID: UUID) {
        guard let stageIndex = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[stageIndex].markShared(bundleID: bundleID)
    }

    // MARK: - Templates

    public mutating func saveStageAsTemplate(stageID: UUID, templateName: String) {
        guard let stage = stages.first(where: { $0.id == stageID }) else { return }
        let bundleIDs = Array(stage.appBundleIDs.sorted())
        let template = Template(name: templateName, appBundleIDs: bundleIDs)
        templates.append(template)
    }

    public mutating func deleteTemplate(id: UUID) {
        templates.removeAll { $0.id == id }
    }
}
