import Foundation
import CoreGraphics

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
        stages.first(where: { $0.id == activeStageID }) ?? stages[0]
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

        for window in deletedStage.windows {
            stages[overflowIndex].addWindow(window)
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

    /// Remove stages that have no windows, keeping at least one stage.
    public mutating func removeEmptyStages() {
        let nonEmpty = stages.filter { !$0.windows.isEmpty }
        if nonEmpty.isEmpty { return } // keep all if everything is empty
        stages = nonEmpty
        // Fix activeStageID if it pointed to a removed stage
        if !stages.contains(where: { $0.id == activeStageID }) {
            activeStageID = stages[0].id
        }
    }

    // MARK: - Window management

    public mutating func addWindow(_ window: StageWindow, toStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].addWindow(window)
    }

    public mutating func removeWindow(windowID: CGWindowID, fromStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].removeWindow(windowID: windowID)
    }

    public mutating func removeAllWindows(forBundleID bundleID: String) {
        for index in stages.indices {
            stages[index].removeAllWindows(forBundleID: bundleID)
        }
    }

    public mutating func moveWindow(windowID: CGWindowID, fromStageID: UUID, toStageID: UUID) {
        guard let fromIndex = stages.firstIndex(where: { $0.id == fromStageID }),
              let toIndex = stages.firstIndex(where: { $0.id == toStageID }),
              let window = stages[fromIndex].windows.first(where: { $0.windowID == windowID })
        else { return }
        stages[fromIndex].removeWindow(windowID: windowID)
        stages[toIndex].addWindow(window)
    }

    public mutating func bringWindowToFront(windowID: CGWindowID, inStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].bringWindowToFront(windowID: windowID)
    }

    public mutating func markWindowShared(windowID: CGWindowID, inStageID stageID: UUID) {
        guard let stageIndex = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[stageIndex].markShared(windowID: windowID)
    }

    public mutating func updateWindowTitle(windowID: CGWindowID, title: String) {
        for stageIndex in stages.indices {
            if let winIndex = stages[stageIndex].windows.firstIndex(where: { $0.windowID == windowID }) {
                stages[stageIndex].updateWindowTitle(at: winIndex, title: title)
                return
            }
        }
    }

    public mutating func updateWindowIDs(stageIndex: Int, windowIndex: Int, windowID: CGWindowID, ownerPID: pid_t?, windowTitle: String? = nil) {
        guard stages.indices.contains(stageIndex) else { return }
        stages[stageIndex].updateWindow(at: windowIndex, windowID: windowID, ownerPID: ownerPID, windowTitle: windowTitle)
    }

    public func stageContainingWindow(windowID: CGWindowID) -> UUID? {
        stages.first(where: { $0.windows.contains(where: { $0.windowID == windowID }) })?.id
    }

    // MARK: - Templates

    public mutating func saveStageAsTemplate(stageID: UUID, templateName: String) {
        guard let stage = stages.first(where: { $0.id == stageID }) else { return }
        let bundleIDs = Array(Set(stage.windows.map(\.ownerBundleID)).sorted())
        let template = Template(name: templateName, appBundleIDs: bundleIDs)
        templates.append(template)
    }

    public mutating func deleteTemplate(id: UUID) {
        templates.removeAll { $0.id == id }
    }
}
