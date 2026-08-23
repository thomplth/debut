import CoreGraphics
import Foundation

public enum StageInsertPosition: Codable, Sendable { case above, below }
public enum StageStackEdge: Sendable, Equatable { case top, bottom }
public enum SwapDirection: Sendable { case up, down }

/// Persisted stages belonging to one display-scoped Space list.
public struct StageStack: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var isConnected: Bool
    public var stages: [Stage]
    public var activeStageID: UUID

    public init(
        id: String,
        displayName: String,
        isConnected: Bool = true,
        stages: [Stage]? = nil,
        activeStageID: UUID? = nil
    ) {
        let resolvedStages = stages.flatMap { $0.isEmpty ? nil : $0 } ?? [Stage()]
        self.id = id
        self.displayName = displayName
        self.isConnected = isConnected
        self.stages = resolvedStages
        self.activeStageID = activeStageID.flatMap { candidate in
            resolvedStages.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? resolvedStages[0].id
    }
}

public struct StageManager: Codable, Sendable {
    public private(set) var stageStacks: [StageStack]
    public private(set) var selectedStageStackID: String
    public private(set) var dormantWindowAssignments: [DormantWindowAssignment]

    private enum CodingKeys: String, CodingKey {
        case stageStacks, selectedStageStackID, dormantWindowAssignments
        case stages, activeStageID
    }

    public init() {
        let stack = StageStack(id: SpaceTopology.sharedStackID, displayName: "All Displays")
        stageStacks = [stack]
        selectedStageStackID = stack.id
        dormantWindowAssignments = []
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dormantWindowAssignments = try container.decodeIfPresent(
            [DormantWindowAssignment].self,
            forKey: .dormantWindowAssignments
        ) ?? []
        if let decoded = try container.decodeIfPresent([StageStack].self, forKey: .stageStacks),
           !decoded.isEmpty {
            stageStacks = decoded
            let requested = try container.decodeIfPresent(
                String.self,
                forKey: .selectedStageStackID
            )
            selectedStageStackID = requested.flatMap { id in
                decoded.contains(where: { $0.id == id }) ? id : nil
            } ?? decoded.first(where: \.isConnected)?.id ?? decoded[0].id
        } else {
            let legacyStages = try container.decode([Stage].self, forKey: .stages)
            let legacyActive = try container.decode(UUID.self, forKey: .activeStageID)
            let legacy = StageStack(
                id: "legacy",
                displayName: "Legacy Display",
                stages: legacyStages,
                activeStageID: legacyActive
            )
            stageStacks = [legacy]
            selectedStageStackID = legacy.id
        }
        let stageIDs = Set(allStages.map(\.id))
        dormantWindowAssignments.removeAll { !stageIDs.contains($0.stageID) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stageStacks, forKey: .stageStacks)
        try container.encode(selectedStageStackID, forKey: .selectedStageStackID)
        try container.encode(dormantWindowAssignments, forKey: .dormantWindowAssignments)
        // Keep the selected stack readable by older diagnostics and downgrade builds.
        try container.encode(stages, forKey: .stages)
        try container.encode(activeStageID, forKey: .activeStageID)
    }

    /// Compatibility view used by the controller: stages in the selected display stack.
    public var stages: [Stage] { selectedStack?.stages ?? [] }
    public var activeStageID: UUID { selectedStack?.activeStageID ?? stages[0].id }
    public var activeStage: Stage {
        stages.first(where: { $0.id == activeStageID }) ?? stages[0]
    }
    public var selectedStageStack: StageStack? { selectedStack }
    public var connectedStageStacks: [StageStack] { stageStacks.filter(\.isConnected) }
    public var allStages: [Stage] { stageStacks.flatMap(\.stages) }
    public var liveWindowCount: Int {
        allStages.reduce(into: 0) { $0 += $1.windows.count }
    }
    public var allWindowOwnerBundleIDs: [String] {
        var seen: Set<String> = []
        let live = allStages.flatMap(\.windows).map(\.ownerBundleID)
        let dormant = dormantWindowAssignments.map(\.window.ownerBundleID)
        return (live + dormant).filter { seen.insert($0).inserted }
    }

    private var selectedStackIndex: Int? {
        stageStacks.firstIndex { $0.id == selectedStageStackID }
    }
    private var selectedStack: StageStack? {
        stageStacks.first { $0.id == selectedStageStackID }
    }

    public func stage(atIndex index: Int) -> Stage? {
        guard stages.indices.contains(index) else { return nil }
        return stages[index]
    }
    public func stageStackID(containingStageID stageID: UUID) -> String? {
        stageStacks.first { $0.stages.contains(where: { $0.id == stageID }) }?.id
    }
    public func stageStackID(containingWindow windowID: CGWindowID) -> String? {
        stageContainingWindow(windowID: windowID).flatMap(stageStackID(containingStageID:))
    }
    public func stageID(stackID: String, at index: Int) -> UUID? {
        guard let stack = stageStacks.first(where: { $0.id == stackID }),
              stack.stages.indices.contains(index) else { return nil }
        return stack.stages[index].id
    }
    public func stageIndex(id: UUID) -> Int? {
        for stack in stageStacks {
            if let index = stack.stages.firstIndex(where: { $0.id == id }) { return index }
        }
        return nil
    }

    public mutating func selectStageStack(id: String) {
        guard stageStacks.contains(where: { $0.id == id && $0.isConnected }) else { return }
        selectedStageStackID = id
    }
    public mutating func selectNextStageStack() {
        let connected = connectedStageStacks
        guard connected.count > 1,
              let index = connected.firstIndex(where: { $0.id == selectedStageStackID })
        else { return }
        selectedStageStackID = connected[(index + 1) % connected.count].id
    }

    /// Matches connected stacks to macOS while retaining dormant assignments for unplugged displays.
    public mutating func reconcileStageStacks(with topology: SpaceTopology) {
        guard !topology.stacks.isEmpty else { return }
        prepareForTopologyTransition(topology)
        for index in stageStacks.indices { stageStacks[index].isConnected = false }

        for descriptor in topology.stacks where !descriptor.desktopIDs.isEmpty {
            if let index = stageStacks.firstIndex(where: { $0.id == descriptor.id }) {
                stageStacks[index].displayName = descriptor.displayName
                stageStacks[index].isConnected = true
                resizeStack(at: index, to: descriptor.desktopIDs.count)
                if let current = descriptor.currentDesktopIndex,
                   stageStacks[index].stages.indices.contains(current) {
                    stageStacks[index].activeStageID = stageStacks[index].stages[current].id
                }
            } else {
                let stages = (0..<descriptor.desktopIDs.count).map { _ in Stage() }
                let activeIndex = min(
                    max(descriptor.currentDesktopIndex ?? 0, 0),
                    stages.count - 1
                )
                stageStacks.append(StageStack(
                    id: descriptor.id,
                    displayName: descriptor.displayName,
                    stages: stages,
                    activeStageID: stages[activeIndex].id
                ))
            }
        }

        let dormantStageIDs = Set(dormantWindowAssignments.map(\.stageID))
        stageStacks.removeAll { stack in
            !stack.isConnected
                && stack.stages.allSatisfy(\.windows.isEmpty)
                && stack.stages.allSatisfy { !dormantStageIDs.contains($0.id) }
        }
        if !stageStacks.contains(where: { $0.id == selectedStageStackID && $0.isConnected }),
           let first = stageStacks.first(where: \.isConnected) {
            selectedStageStackID = first.id
        }
    }

    /// Mission Control changes this mode at login. Preserve the old model while changing its
    /// shape so the next live-window reconciliation can refine placements without losing
    /// dormant assignments that have no window-server answer.
    private mutating func prepareForTopologyTransition(_ topology: SpaceTopology) {
        guard let firstDescriptor = topology.stacks.first else { return }

        if !topology.separateSpaces, topology.stacks.count == 1 {
            let baseIndex = stageStacks.firstIndex(where: {
                $0.id == SpaceTopology.sharedStackID
            }) ?? selectedStackIndex ?? 0
            resizeStack(at: baseIndex, to: firstDescriptor.desktopIDs.count)
            let baseStageIDs = stageStacks[baseIndex].stages.map(\.id)
            let sourceStacks = stageStacks.enumerated().filter { $0.offset != baseIndex }

            for (_, source) in sourceStacks {
                for (stageIndex, stage) in source.stages.enumerated() {
                    let destination = min(stageIndex, baseStageIDs.count - 1)
                    for window in stage.windows {
                        stageStacks[baseIndex].stages[destination].addWindow(window)
                    }
                }
            }
            dormantWindowAssignments = dormantWindowAssignments.map { assignment in
                guard let source = sourceStacks.first(where: { _, stack in
                    stack.stages.contains(where: { $0.id == assignment.stageID })
                }),
                let stageIndex = source.element.stages.firstIndex(where: {
                    $0.id == assignment.stageID
                }) else { return assignment }
                return DormantWindowAssignment(
                    stageID: baseStageIDs[min(stageIndex, baseStageIDs.count - 1)],
                    windowIndex: assignment.windowIndex,
                    window: assignment.window
                )
            }
            let base = stageStacks[baseIndex]
            stageStacks = [StageStack(
                id: firstDescriptor.id,
                displayName: firstDescriptor.displayName,
                stages: base.stages,
                activeStageID: base.activeStageID
            )]
            selectedStageStackID = firstDescriptor.id
            return
        }

        // The old single-stack format had no display identity. Its only honest migration is
        // to the first display stack; windows with positive desktop answers are redistributed
        // to other displays immediately afterwards.
        let hasKnownDisplayStack = topology.stacks.contains { descriptor in
            stageStacks.contains(where: { $0.id == descriptor.id })
        }
        if topology.separateSpaces, stageStacks.count == 1, !hasKnownDisplayStack {
            stageStacks[0].id = firstDescriptor.id
            stageStacks[0].displayName = firstDescriptor.displayName
            selectedStageStackID = firstDescriptor.id
        }
    }

    private mutating func resizeStack(at stackIndex: Int, to requestedCount: Int) {
        let count = max(1, requestedCount)
        while stageStacks[stackIndex].stages.count > count {
            let removed = stageStacks[stackIndex].stages.removeLast()
            dormantWindowAssignments.removeAll { $0.stageID == removed.id }
            let destination = stageStacks[stackIndex].stages.count - 1
            for window in removed.windows {
                stageStacks[stackIndex].stages[destination].addWindow(window)
            }
        }
        while stageStacks[stackIndex].stages.count < count {
            stageStacks[stackIndex].stages.append(Stage())
        }
        if !stageStacks[stackIndex].stages.contains(where: {
            $0.id == stageStacks[stackIndex].activeStageID
        }) {
            stageStacks[stackIndex].activeStageID = stageStacks[stackIndex].stages[0].id
        }
    }

    // MARK: Stage lifecycle

    public mutating func createStage(position: StageInsertPosition) {
        guard let stackIndex = selectedStackIndex else { return }
        let newStage = Stage()
        guard let activeIndex = stageStacks[stackIndex].stages.firstIndex(where: {
            $0.id == stageStacks[stackIndex].activeStageID
        }) else { return }
        let insertionIndex = position == .above ? activeIndex : activeIndex + 1
        stageStacks[stackIndex].stages.insert(newStage, at: insertionIndex)
        stageStacks[stackIndex].activeStageID = newStage.id
    }

    public mutating func deleteStage(id: UUID) {
        guard let location = stageLocation(id: id) else { return }
        let deleted = stageStacks[location.stack].stages[location.stage]
        dormantWindowAssignments.removeAll { $0.stageID == id }
        if stageStacks[location.stack].stages.count == 1 {
            let replacement = Stage()
            stageStacks[location.stack].stages = [replacement]
            stageStacks[location.stack].activeStageID = replacement.id
            return
        }
        let overflow = location.stage == 0 ? 1 : location.stage - 1
        for window in deleted.windows {
            stageStacks[location.stack].stages[overflow].addWindow(window)
        }
        stageStacks[location.stack].stages.remove(at: location.stage)
        let active = min(overflow, stageStacks[location.stack].stages.count - 1)
        stageStacks[location.stack].activeStageID = stageStacks[location.stack].stages[active].id
    }

    public mutating func activateStage(id: UUID) {
        guard let location = stageLocation(id: id) else { return }
        stageStacks[location.stack].activeStageID = id
    }

    public mutating func removeEmptyStages() {
        guard let stackIndex = selectedStackIndex else { return }
        let dormantIDs = Set(dormantWindowAssignments.map(\.stageID))
        let nonEmpty = stageStacks[stackIndex].stages.filter {
            !$0.windows.isEmpty || dormantIDs.contains($0.id)
        }
        if nonEmpty.isEmpty { return }
        stageStacks[stackIndex].stages = nonEmpty
        if !nonEmpty.contains(where: { $0.id == stageStacks[stackIndex].activeStageID }) {
            stageStacks[stackIndex].activeStageID = nonEmpty[0].id
        }
    }

    // MARK: Window management

    public mutating func resetWindowCache() {
        let stack = StageStack(id: SpaceTopology.sharedStackID, displayName: "All Displays")
        stageStacks = [stack]
        selectedStageStackID = stack.id
        dormantWindowAssignments.removeAll()
    }
    public mutating func addWindow(_ window: StageWindow, toStageID id: UUID) {
        guard let location = stageLocation(id: id) else { return }
        stageStacks[location.stack].stages[location.stage].addWindow(window)
    }
    public mutating func insertWindow(_ window: StageWindow, at index: Int, inStageID id: UUID) {
        guard let location = stageLocation(id: id) else { return }
        stageStacks[location.stack].stages[location.stage].insertWindow(window, at: index)
    }
    public mutating func removeWindow(windowID: CGWindowID, fromStageID id: UUID) {
        if let location = stageLocation(id: id) {
            stageStacks[location.stack].stages[location.stage].removeWindow(windowID: windowID)
        }
        dormantWindowAssignments.removeAll {
            $0.stageID == id && $0.window.windowID == windowID
        }
    }
    mutating func removeLiveWindowFromAllStages(windowID: CGWindowID) {
        for stack in stageStacks.indices {
            for stage in stageStacks[stack].stages.indices {
                stageStacks[stack].stages[stage].removeWindow(windowID: windowID)
            }
        }
    }
    public mutating func removeAllWindows(forBundleID bundleID: String) {
        for stack in stageStacks.indices {
            for stage in stageStacks[stack].stages.indices {
                stageStacks[stack].stages[stage].removeAllWindows(forBundleID: bundleID)
            }
        }
        dormantWindowAssignments.removeAll { $0.window.ownerBundleID == bundleID }
    }
    @discardableResult
    public mutating func removeAllWindows(forOwnerPID pid: pid_t) -> Int {
        var removed = 0
        for stack in stageStacks.indices {
            for stage in stageStacks[stack].stages.indices {
                removed += stageStacks[stack].stages[stage].removeAllWindows(forOwnerPID: pid)
            }
        }
        let dormantBefore = dormantWindowAssignments.count
        dormantWindowAssignments.removeAll { $0.window.ownerPID == pid }
        return removed + dormantBefore - dormantWindowAssignments.count
    }
    @discardableResult
    public mutating func makeWindowsDormant(forOwnerPID pid: pid_t) -> Int {
        let assignments = allStages.flatMap { stage in
            stage.windows.enumerated().compactMap { index, window in
                window.ownerPID == pid
                    ? DormantWindowAssignment(stageID: stage.id, windowIndex: index, window: window)
                    : nil
            }
        }
        guard !assignments.isEmpty else { return 0 }
        let ids = Set(assignments.map(\.id))
        dormantWindowAssignments.removeAll { ids.contains($0.id) }
        dormantWindowAssignments.append(contentsOf: assignments)
        for stack in stageStacks.indices {
            for stage in stageStacks[stack].stages.indices {
                _ = stageStacks[stack].stages[stage].removeAllWindows(forOwnerPID: pid)
            }
        }
        return assignments.count
    }
    @discardableResult
    public mutating func makeWindowDormant(windowID: CGWindowID) -> DormantWindowAssignment? {
        for stack in stageStacks.indices {
            for stage in stageStacks[stack].stages.indices {
                guard let index = stageStacks[stack].stages[stage].windows.firstIndex(where: {
                    $0.windowID == windowID
                }) else { continue }
                let current = stageStacks[stack].stages[stage]
                let assignment = DormantWindowAssignment(
                    stageID: current.id,
                    windowIndex: index,
                    window: current.windows[index]
                )
                stageStacks[stack].stages[stage].removeWindow(windowID: windowID)
                dormantWindowAssignments.removeAll { $0.id == assignment.id }
                dormantWindowAssignments.append(assignment)
                return assignment
            }
        }
        return nil
    }
    @discardableResult
    public mutating func restoreDormantWindow(
        assignmentID: UUID,
        windowID: CGWindowID,
        ownerPID: pid_t,
        windowTitle: String
    ) -> Bool {
        guard let index = dormantWindowAssignments.firstIndex(where: { $0.id == assignmentID })
        else { return false }
        let assignment = dormantWindowAssignments.remove(at: index)
        guard stageLocation(id: assignment.stageID) != nil else { return false }
        var window = assignment.window
        window.windowID = windowID
        window.ownerPID = ownerPID
        window.windowTitle = windowTitle
        insertWindow(window, at: assignment.windowIndex, inStageID: assignment.stageID)
        return true
    }
    public mutating func moveWindow(
        windowID: CGWindowID,
        fromStageID: UUID,
        toStageID: UUID,
        at windowIndex: Int? = nil
    ) {
        guard let source = stageLocation(id: fromStageID),
              let destination = stageLocation(id: toStageID),
              let window = stageStacks[source.stack].stages[source.stage].windows.first(where: {
                  $0.windowID == windowID
              }) else { return }
        guard fromStageID != toStageID || windowIndex != nil else { return }
        stageStacks[source.stack].stages[source.stage].removeWindow(windowID: windowID)
        if let windowIndex {
            stageStacks[destination.stack].stages[destination.stage]
                .insertWindow(window, at: windowIndex)
        } else {
            stageStacks[destination.stack].stages[destination.stage].addWindow(window)
        }
    }
    public mutating func bringWindowToFront(windowID: CGWindowID, inStageID id: UUID) {
        guard let location = stageLocation(id: id) else { return }
        stageStacks[location.stack].stages[location.stage].bringWindowToFront(windowID: windowID)
    }
    public mutating func updateWindowTitle(windowID: CGWindowID, title: String) {
        for stack in stageStacks.indices {
            for stage in stageStacks[stack].stages.indices {
                if let index = stageStacks[stack].stages[stage].windows.firstIndex(where: {
                    $0.windowID == windowID
                }) {
                    stageStacks[stack].stages[stage].updateWindowTitle(at: index, title: title)
                    return
                }
            }
        }
    }
    public mutating func updateWindowIDs(
        stageIndex: Int,
        windowIndex: Int,
        windowID: CGWindowID,
        ownerPID: pid_t?,
        windowTitle: String? = nil
    ) {
        guard let stack = selectedStackIndex,
              stageStacks[stack].stages.indices.contains(stageIndex) else { return }
        stageStacks[stack].stages[stageIndex].updateWindow(
            at: windowIndex,
            windowID: windowID,
            ownerPID: ownerPID,
            windowTitle: windowTitle
        )
    }
    public mutating func updateWindowIDs(
        stageID: UUID,
        windowIndex: Int,
        windowID: CGWindowID,
        ownerPID: pid_t?,
        windowTitle: String? = nil
    ) {
        guard let location = stageLocation(id: stageID) else { return }
        stageStacks[location.stack].stages[location.stage].updateWindow(
            at: windowIndex,
            windowID: windowID,
            ownerPID: ownerPID,
            windowTitle: windowTitle
        )
    }
    public func stageContainingWindow(windowID: CGWindowID) -> UUID? {
        allStages.first(where: { stage in
            stage.windows.contains(where: { $0.windowID == windowID })
        })?.id
    }

    private func stageLocation(id: UUID) -> (stack: Int, stage: Int)? {
        for stack in stageStacks.indices {
            if let stage = stageStacks[stack].stages.firstIndex(where: { $0.id == id }) {
                return (stack, stage)
            }
        }
        return nil
    }
}
