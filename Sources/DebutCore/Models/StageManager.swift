import Foundation

public enum StageInsertPosition: Sendable {
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
    private var mruByStage: [UUID: [Int]]
    private var nextStageNumber: Int

    public init() {
        let initial = Stage(name: "Stage 1")
        self.stages = [initial]
        self.activeStageID = initial.id
        self.templates = []
        self.mruByStage = [:]
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
            mruByStage.removeValue(forKey: id)
            let newDefault = Stage(name: "Stage 1")
            stages = [newDefault]
            activeStageID = newDefault.id
            nextStageNumber = 2
            return
        }

        let overflowIndex: Int
        if index == 0 {
            overflowIndex = 1
        } else {
            overflowIndex = index - 1
        }

        for window in deletedStage.windows {
            stages[overflowIndex].addWindow(window)
        }

        stages.remove(at: index)
        mruByStage.removeValue(forKey: id)

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

    // MARK: - Window management

    public mutating func addWindow(_ window: StageWindow, toStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].addWindow(window)
    }

    public mutating func removeWindow(windowID: Int, fromStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].removeWindow(byID: windowID)
    }

    public mutating func moveWindow(windowID: Int, fromStageID: UUID, toStageID: UUID) {
        guard let fromIndex = stages.firstIndex(where: { $0.id == fromStageID }),
              let toIndex = stages.firstIndex(where: { $0.id == toStageID }),
              let window = stages[fromIndex].windows.first(where: { $0.windowID == windowID })
        else { return }

        stages[fromIndex].removeWindow(byID: windowID)
        stages[toIndex].addWindow(window)
    }

    // MARK: - MRU tracking

    public mutating func recordWindowFocus(windowID: Int, inStageID stageID: UUID) {
        var mru = mruByStage[stageID] ?? []
        mru.removeAll { $0 == windowID }
        mru.insert(windowID, at: 0)
        mruByStage[stageID] = mru
    }

    public func mruWindowIDs(forStageID stageID: UUID) -> [Int] {
        guard let stage = stages.first(where: { $0.id == stageID }) else { return [] }
        let tracked = mruByStage[stageID] ?? []
        let stageWindowIDs = Set(stage.windows.map(\.windowID))
        let ordered = tracked.filter { stageWindowIDs.contains($0) }
        let untracked = stage.windows.map(\.windowID).filter { !tracked.contains($0) }
        return ordered + untracked
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
