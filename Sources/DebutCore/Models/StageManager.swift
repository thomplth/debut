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
    public private(set) var dormantWindowAssignments: [DormantWindowAssignment]

    private enum CodingKeys: String, CodingKey {
        case stages
        case activeStageID
        case templates
        case dormantWindowAssignments
    }

    public init() {
        let initial = Stage()
        self.stages = [initial]
        self.activeStageID = initial.id
        self.templates = []
        self.dormantWindowAssignments = []
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stages = try container.decode([Stage].self, forKey: .stages)
        self.activeStageID = try container.decode(UUID.self, forKey: .activeStageID)
        self.templates = try container.decode([Template].self, forKey: .templates)
        self.dormantWindowAssignments = try container.decodeIfPresent(
            [DormantWindowAssignment].self,
            forKey: .dormantWindowAssignments
        ) ?? []
        let stageIDs = Set(stages.map(\.id))
        self.dormantWindowAssignments.removeAll { !stageIDs.contains($0.stageID) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stages, forKey: .stages)
        try container.encode(activeStageID, forKey: .activeStageID)
        try container.encode(templates, forKey: .templates)
        try container.encode(dormantWindowAssignments, forKey: .dormantWindowAssignments)
    }

    public var activeStage: Stage {
        stages.first(where: { $0.id == activeStageID }) ?? stages[0]
    }

    public func stage(atIndex index: Int) -> Stage? {
        guard stages.indices.contains(index) else { return nil }
        return stages[index]
    }

    // MARK: - Stage lifecycle

    public mutating func createStage(position: StageInsertPosition) {
        let newStage = Stage()

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
        dormantWindowAssignments.removeAll { $0.stageID == id }

        if stages.count == 1 {
            stages.removeAll()
            let newDefault = Stage()
            stages = [newDefault]
            activeStageID = newDefault.id
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

    public mutating func moveStage(fromIndex: Int, toIndex: Int) {
        guard stages.indices.contains(fromIndex),
              toIndex >= 0, toIndex < stages.count,
              fromIndex != toIndex
        else { return }
        let stage = stages.remove(at: fromIndex)
        stages.insert(stage, at: toIndex)
    }

    // MARK: - Active stage

    public mutating func activateStage(id: UUID) {
        guard stages.contains(where: { $0.id == id }) else { return }
        activeStageID = id
    }

    /// Remove stages that have no windows, keeping at least one stage.
    public mutating func removeEmptyStages() {
        let dormantStageIDs = Set(dormantWindowAssignments.map(\.stageID))
        let nonEmpty = stages.filter { !$0.windows.isEmpty || dormantStageIDs.contains($0.id) }
        if nonEmpty.isEmpty { return } // keep all if everything is empty
        stages = nonEmpty
        // Fix activeStageID if it pointed to a removed stage
        if !stages.contains(where: { $0.id == activeStageID }) {
            activeStageID = stages[0].id
        }
    }

    // MARK: - Window management

    /// Discards every cached window assignment and stage while keeping reusable
    /// templates. The caller repopulates the new default stage from a fresh AX
    /// discovery so ephemeral IDs and dormant ghosts cannot survive the reset.
    public mutating func resetWindowCache() {
        let initial = Stage()
        stages = [initial]
        activeStageID = initial.id
        dormantWindowAssignments.removeAll()
    }

    public mutating func addWindow(_ window: StageWindow, toStageID stageID: UUID) {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[index].addWindow(window)
    }

    public mutating func insertWindow(_ window: StageWindow, at windowIndex: Int, inStageID stageID: UUID) {
        guard let stageIndex = stages.firstIndex(where: { $0.id == stageID }) else { return }
        stages[stageIndex].insertWindow(window, at: windowIndex)
    }

    public mutating func removeWindow(windowID: CGWindowID, fromStageID stageID: UUID) {
        if let index = stages.firstIndex(where: { $0.id == stageID }) {
            stages[index].removeWindow(windowID: windowID)
        }
        dormantWindowAssignments.removeAll {
            $0.stageID == stageID && $0.window.windowID == windowID
        }
    }

    mutating func removeLiveWindowFromAllStages(windowID: CGWindowID) {
        for index in stages.indices {
            stages[index].removeWindow(windowID: windowID)
        }
    }

    public mutating func removeAllWindows(forBundleID bundleID: String) {
        for index in stages.indices {
            stages[index].removeAllWindows(forBundleID: bundleID)
        }
        dormantWindowAssignments.removeAll { $0.window.ownerBundleID == bundleID }
    }

    @discardableResult
    public mutating func removeAllWindows(forOwnerPID ownerPID: pid_t) -> Int {
        var removedCount = 0
        for index in stages.indices {
            removedCount += stages[index].removeAllWindows(forOwnerPID: ownerPID)
        }
        let previousDormantCount = dormantWindowAssignments.count
        dormantWindowAssignments.removeAll { $0.window.ownerPID == ownerPID }
        return removedCount + previousDormantCount - dormantWindowAssignments.count
    }

    @discardableResult
    public mutating func makeWindowsDormant(forOwnerPID ownerPID: pid_t) -> Int {
        let assignments: [DormantWindowAssignment] = stages.flatMap { stage in
            stage.windows.enumerated().compactMap { windowIndex, window -> DormantWindowAssignment? in
                guard window.ownerPID == ownerPID else { return nil }
                return DormantWindowAssignment(
                    stageID: stage.id,
                    windowIndex: windowIndex,
                    window: window
                )
            }
        }
        guard !assignments.isEmpty else { return 0 }

        let assignmentIDs = Set(assignments.map(\.id))
        dormantWindowAssignments.removeAll { assignmentIDs.contains($0.id) }
        dormantWindowAssignments.append(contentsOf: assignments)
        for index in stages.indices {
            _ = stages[index].removeAllWindows(forOwnerPID: ownerPID)
        }
        return assignments.count
    }

    @discardableResult
    public mutating func restoreDormantWindow(
        assignmentID: UUID,
        windowID: CGWindowID,
        ownerPID: pid_t,
        windowTitle: String
    ) -> Bool {
        guard let assignmentIndex = dormantWindowAssignments.firstIndex(where: {
            $0.id == assignmentID
        }) else { return false }
        let assignment = dormantWindowAssignments.remove(at: assignmentIndex)
        guard stages.contains(where: { $0.id == assignment.stageID }) else { return false }

        var restoredWindow = assignment.window
        restoredWindow.windowID = windowID
        restoredWindow.ownerPID = ownerPID
        restoredWindow.windowTitle = windowTitle
        insertWindow(
            restoredWindow,
            at: assignment.windowIndex,
            inStageID: assignment.stageID
        )
        return true
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
