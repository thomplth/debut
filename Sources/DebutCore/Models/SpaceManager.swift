import CoreGraphics
import Foundation

public enum SpaceInsertPosition: Codable, Sendable { case above, below }
public enum SpaceStackEdge: Sendable, Equatable { case top, bottom }
public enum SwapDirection: Sendable { case up, down }

/// Persisted spaces belonging to one display-scoped Space list.
public struct SpaceStack: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var isConnected: Bool
    public var spaces: [Space]
    public var activeSpaceID: UUID

    public init(
        id: String,
        displayName: String,
        isConnected: Bool = true,
        spaces: [Space]? = nil,
        activeSpaceID: UUID? = nil
    ) {
        let resolvedSpaces = spaces.flatMap { $0.isEmpty ? nil : $0 } ?? [Space()]
        self.id = id
        self.displayName = displayName
        self.isConnected = isConnected
        self.spaces = resolvedSpaces
        self.activeSpaceID = activeSpaceID.flatMap { candidate in
            resolvedSpaces.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? resolvedSpaces[0].id
    }
}

public struct SpaceManager: Codable, Sendable {
    public private(set) var spaceStacks: [SpaceStack]
    public private(set) var selectedSpaceStackID: String
    public private(set) var dormantWindowAssignments: [DormantWindowAssignment]

    private enum CodingKeys: String, CodingKey {
        case spaceStacks, selectedSpaceStackID, dormantWindowAssignments
        case spaces, activeSpaceID
    }

    public init() {
        let stack = SpaceStack(id: SpaceTopology.sharedStackID, displayName: "All Displays")
        spaceStacks = [stack]
        selectedSpaceStackID = stack.id
        dormantWindowAssignments = []
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dormantWindowAssignments = try container.decodeIfPresent(
            [DormantWindowAssignment].self,
            forKey: .dormantWindowAssignments
        ) ?? []
        if let decoded = try container.decodeIfPresent([SpaceStack].self, forKey: .spaceStacks),
           !decoded.isEmpty {
            spaceStacks = decoded
            let requested = try container.decodeIfPresent(
                String.self,
                forKey: .selectedSpaceStackID
            )
            selectedSpaceStackID = requested.flatMap { id in
                decoded.contains(where: { $0.id == id }) ? id : nil
            } ?? decoded.first(where: \.isConnected)?.id ?? decoded[0].id
        } else {
            let legacySpaces = try container.decode([Space].self, forKey: .spaces)
            let legacyActive = try container.decode(UUID.self, forKey: .activeSpaceID)
            let legacy = SpaceStack(
                id: "legacy",
                displayName: "Legacy Display",
                spaces: legacySpaces,
                activeSpaceID: legacyActive
            )
            spaceStacks = [legacy]
            selectedSpaceStackID = legacy.id
        }
        let spaceIDs = Set(allSpaces.map(\.id))
        dormantWindowAssignments.removeAll { !spaceIDs.contains($0.spaceID) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spaceStacks, forKey: .spaceStacks)
        try container.encode(selectedSpaceStackID, forKey: .selectedSpaceStackID)
        try container.encode(dormantWindowAssignments, forKey: .dormantWindowAssignments)
        // Keep the selected stack readable by older diagnostics and downgrade builds.
        try container.encode(spaces, forKey: .spaces)
        try container.encode(activeSpaceID, forKey: .activeSpaceID)
    }

    /// Compatibility view used by the controller: spaces in the selected display stack.
    public var spaces: [Space] { selectedStack?.spaces ?? [] }
    public var activeSpaceID: UUID { selectedStack?.activeSpaceID ?? spaces[0].id }
    public var activeSpace: Space {
        spaces.first(where: { $0.id == activeSpaceID }) ?? spaces[0]
    }
    public var selectedSpaceStack: SpaceStack? { selectedStack }
    public var connectedSpaceStacks: [SpaceStack] { spaceStacks.filter(\.isConnected) }
    public var allSpaces: [Space] { spaceStacks.flatMap(\.spaces) }
    public var liveWindowCount: Int {
        allSpaces.reduce(into: 0) { $0 += $1.windows.count }
    }
    public var allWindowOwnerBundleIDs: [String] {
        var seen: Set<String> = []
        let live = allSpaces.flatMap(\.windows).map(\.ownerBundleID)
        let dormant = dormantWindowAssignments.map(\.window.ownerBundleID)
        return (live + dormant).filter { seen.insert($0).inserted }
    }

    private var selectedStackIndex: Int? {
        spaceStacks.firstIndex { $0.id == selectedSpaceStackID }
    }
    private var selectedStack: SpaceStack? {
        spaceStacks.first { $0.id == selectedSpaceStackID }
    }

    public func space(atIndex index: Int) -> Space? {
        guard spaces.indices.contains(index) else { return nil }
        return spaces[index]
    }
    public func spaceStackID(containingSpaceID spaceID: UUID) -> String? {
        spaceStacks.first { $0.spaces.contains(where: { $0.id == spaceID }) }?.id
    }
    public func spaceStackID(containingWindow windowID: CGWindowID) -> String? {
        spaceContainingWindow(windowID: windowID).flatMap(spaceStackID(containingSpaceID:))
    }
    public func spaceID(stackID: String, at index: Int) -> UUID? {
        guard let stack = spaceStacks.first(where: { $0.id == stackID }),
              stack.spaces.indices.contains(index) else { return nil }
        return stack.spaces[index].id
    }
    public func spaceIndex(id: UUID) -> Int? {
        for stack in spaceStacks {
            if let index = stack.spaces.firstIndex(where: { $0.id == id }) { return index }
        }
        return nil
    }

    public mutating func selectSpaceStack(id: String) {
        guard spaceStacks.contains(where: { $0.id == id && $0.isConnected }) else { return }
        selectedSpaceStackID = id
    }
    public mutating func selectNextSpaceStack() {
        let connected = connectedSpaceStacks
        guard connected.count > 1,
              let index = connected.firstIndex(where: { $0.id == selectedSpaceStackID })
        else { return }
        selectedSpaceStackID = connected[(index + 1) % connected.count].id
    }

    /// Matches connected stacks to macOS while retaining dormant assignments for unplugged displays.
    public mutating func reconcileSpaceStacks(with topology: SpaceTopology) {
        guard !topology.stacks.isEmpty else { return }
        prepareForTopologyTransition(topology)
        for index in spaceStacks.indices { spaceStacks[index].isConnected = false }

        for descriptor in topology.stacks where !descriptor.desktopIDs.isEmpty {
            if let index = spaceStacks.firstIndex(where: { $0.id == descriptor.id }) {
                spaceStacks[index].displayName = descriptor.displayName
                spaceStacks[index].isConnected = true
                alignStack(at: index, to: descriptor)
                if let active = activeSpaceID(at: index, for: descriptor) {
                    spaceStacks[index].activeSpaceID = active
                }
            } else {
                let spaces = (0..<descriptor.desktopIDs.count).map { position in
                    Space(desktopUUID: descriptor.desktopUUID(at: position))
                }
                let activeIndex = min(
                    max(descriptor.currentDesktopIndex ?? 0, 0),
                    spaces.count - 1
                )
                spaceStacks.append(SpaceStack(
                    id: descriptor.id,
                    displayName: descriptor.displayName,
                    spaces: spaces,
                    activeSpaceID: spaces[activeIndex].id
                ))
            }
        }

        let dormantSpaceIDs = Set(dormantWindowAssignments.map(\.spaceID))
        spaceStacks.removeAll { stack in
            !stack.isConnected
                && stack.spaces.allSatisfy(\.windows.isEmpty)
                && stack.spaces.allSatisfy { !dormantSpaceIDs.contains($0.id) }
        }
        if !spaceStacks.contains(where: { $0.id == selectedSpaceStackID && $0.isConnected }),
           let first = spaceStacks.first(where: \.isConnected) {
            selectedSpaceStackID = first.id
        }
    }

    /// Mission Control changes this mode at login. Preserve the old model while changing its
    /// shape so the next live-window reconciliation can refine placements without losing
    /// dormant assignments that have no window-server answer.
    private mutating func prepareForTopologyTransition(_ topology: SpaceTopology) {
        guard let firstDescriptor = topology.stacks.first else { return }

        if !topology.separateSpaces, topology.stacks.count == 1 {
            let baseIndex = spaceStacks.firstIndex(where: {
                $0.id == SpaceTopology.sharedStackID
            }) ?? selectedStackIndex ?? 0
            resizeStack(at: baseIndex, to: firstDescriptor.desktopIDs.count)
            let baseSpaceIDs = spaceStacks[baseIndex].spaces.map(\.id)
            let sourceStacks = spaceStacks.enumerated().filter { $0.offset != baseIndex }

            for (_, source) in sourceStacks {
                for (spaceIndex, space) in source.spaces.enumerated() {
                    let destination = min(spaceIndex, baseSpaceIDs.count - 1)
                    for window in space.windows {
                        spaceStacks[baseIndex].spaces[destination].addWindow(window)
                    }
                }
            }
            dormantWindowAssignments = dormantWindowAssignments.map { assignment in
                guard let source = sourceStacks.first(where: { _, stack in
                    stack.spaces.contains(where: { $0.id == assignment.spaceID })
                }),
                let spaceIndex = source.element.spaces.firstIndex(where: {
                    $0.id == assignment.spaceID
                }) else { return assignment }
                return DormantWindowAssignment(
                    spaceID: baseSpaceIDs[min(spaceIndex, baseSpaceIDs.count - 1)],
                    windowIndex: assignment.windowIndex,
                    window: assignment.window
                )
            }
            let base = spaceStacks[baseIndex]
            spaceStacks = [SpaceStack(
                id: firstDescriptor.id,
                displayName: firstDescriptor.displayName,
                spaces: base.spaces,
                activeSpaceID: base.activeSpaceID
            )]
            selectedSpaceStackID = firstDescriptor.id
            return
        }

        // The old single-stack format had no display identity. Its only honest migration is
        // to the first display stack; windows with positive desktop answers are redistributed
        // to other displays immediately afterwards.
        let hasKnownDisplayStack = topology.stacks.contains { descriptor in
            spaceStacks.contains(where: { $0.id == descriptor.id })
        }
        if topology.separateSpaces, spaceStacks.count == 1, !hasKnownDisplayStack {
            spaceStacks[0].id = firstDescriptor.id
            spaceStacks[0].displayName = firstDescriptor.displayName
            selectedSpaceStackID = firstDescriptor.id
        }
    }

    /// Rebuilds one stack so its spaces stand in the order macOS reports its desktops in.
    ///
    /// macOS is authoritative for the order, the count and the membership; the uuid stored on
    /// a space is only the join key that says which stored record belongs to which desktop.
    /// Without it a reorder is invisible, because it leaves the desktop count unchanged and a
    /// count is all a resize can compare.
    private mutating func alignStack(at stackIndex: Int, to descriptor: SpaceStackDescriptor) {
        guard !descriptor.desktopUUIDs.isEmpty else {
            resizeStack(at: stackIndex, to: descriptor.desktopIDs.count)
            return
        }

        var unclaimed = spaceStacks[stackIndex].spaces
        var aligned: [Space?] = Array(repeating: nil, count: descriptor.desktopUUIDs.count)

        // Identity first, so a space only ever lands on the desktop it was already joined to.
        for (position, uuid) in descriptor.desktopUUIDs.enumerated() {
            guard let match = unclaimed.firstIndex(where: { $0.desktopUUID == uuid }) else { continue }
            aligned[position] = unclaimed.remove(at: match)
        }

        // Then position, which only reaches spaces that have never been joined to a desktop.
        // A space whose desktop is gone is deliberately not reused: inheriting it would
        // attach one desktop's windows to another, which is the failure this exists to stop.
        for position in aligned.indices where aligned[position] == nil {
            let uuid = descriptor.desktopUUIDs[position]
            if let adoptable = unclaimed.firstIndex(where: { $0.desktopUUID == nil }) {
                var space = unclaimed.remove(at: adoptable)
                space.joinDesktop(uuid: uuid)
                aligned[position] = space
            } else {
                aligned[position] = Space(desktopUUID: uuid)
            }
        }

        var spaces = aligned.compactMap { $0 }
        for departed in unclaimed {
            dormantWindowAssignments.removeAll { $0.spaceID == departed.id }
            for window in departed.windows {
                spaces[spaces.count - 1].addWindow(window)
            }
        }

        spaceStacks[stackIndex].spaces = spaces
        if !spaces.contains(where: { $0.id == spaceStacks[stackIndex].activeSpaceID }) {
            spaceStacks[stackIndex].activeSpaceID = spaces[0].id
        }
    }

    private func activeSpaceID(
        at stackIndex: Int,
        for descriptor: SpaceStackDescriptor
    ) -> UUID? {
        let spaces = spaceStacks[stackIndex].spaces
        if let uuid = descriptor.currentDesktopUUID,
           let space = spaces.first(where: { $0.desktopUUID == uuid }) {
            return space.id
        }
        guard let current = descriptor.currentDesktopIndex,
              spaces.indices.contains(current) else { return nil }
        return spaces[current].id
    }

    private mutating func resizeStack(at stackIndex: Int, to requestedCount: Int) {
        let count = max(1, requestedCount)
        while spaceStacks[stackIndex].spaces.count > count {
            let removed = spaceStacks[stackIndex].spaces.removeLast()
            dormantWindowAssignments.removeAll { $0.spaceID == removed.id }
            let destination = spaceStacks[stackIndex].spaces.count - 1
            for window in removed.windows {
                spaceStacks[stackIndex].spaces[destination].addWindow(window)
            }
        }
        while spaceStacks[stackIndex].spaces.count < count {
            spaceStacks[stackIndex].spaces.append(Space())
        }
        if !spaceStacks[stackIndex].spaces.contains(where: {
            $0.id == spaceStacks[stackIndex].activeSpaceID
        }) {
            spaceStacks[stackIndex].activeSpaceID = spaceStacks[stackIndex].spaces[0].id
        }
    }

    // MARK: Space lifecycle

    public mutating func createSpace(position: SpaceInsertPosition) {
        guard let stackIndex = selectedStackIndex else { return }
        let newSpace = Space()
        guard let activeIndex = spaceStacks[stackIndex].spaces.firstIndex(where: {
            $0.id == spaceStacks[stackIndex].activeSpaceID
        }) else { return }
        let insertionIndex = position == .above ? activeIndex : activeIndex + 1
        spaceStacks[stackIndex].spaces.insert(newSpace, at: insertionIndex)
        spaceStacks[stackIndex].activeSpaceID = newSpace.id
    }

    public mutating func deleteSpace(id: UUID) {
        guard let location = spaceLocation(id: id) else { return }
        let deleted = spaceStacks[location.stack].spaces[location.space]
        dormantWindowAssignments.removeAll { $0.spaceID == id }
        if spaceStacks[location.stack].spaces.count == 1 {
            let replacement = Space()
            spaceStacks[location.stack].spaces = [replacement]
            spaceStacks[location.stack].activeSpaceID = replacement.id
            return
        }
        let overflow = location.space == 0 ? 1 : location.space - 1
        for window in deleted.windows {
            spaceStacks[location.stack].spaces[overflow].addWindow(window)
        }
        spaceStacks[location.stack].spaces.remove(at: location.space)
        let active = min(overflow, spaceStacks[location.stack].spaces.count - 1)
        spaceStacks[location.stack].activeSpaceID = spaceStacks[location.stack].spaces[active].id
    }

    public mutating func activateSpace(id: UUID) {
        guard let location = spaceLocation(id: id) else { return }
        spaceStacks[location.stack].activeSpaceID = id
    }

    public mutating func removeEmptySpaces() {
        guard let stackIndex = selectedStackIndex else { return }
        let dormantIDs = Set(dormantWindowAssignments.map(\.spaceID))
        let nonEmpty = spaceStacks[stackIndex].spaces.filter {
            !$0.windows.isEmpty || dormantIDs.contains($0.id)
        }
        if nonEmpty.isEmpty { return }
        spaceStacks[stackIndex].spaces = nonEmpty
        if !nonEmpty.contains(where: { $0.id == spaceStacks[stackIndex].activeSpaceID }) {
            spaceStacks[stackIndex].activeSpaceID = nonEmpty[0].id
        }
    }

    // MARK: Window management

    public mutating func resetWindowCache() {
        let stack = SpaceStack(id: SpaceTopology.sharedStackID, displayName: "All Displays")
        spaceStacks = [stack]
        selectedSpaceStackID = stack.id
        dormantWindowAssignments.removeAll()
    }
    public mutating func addWindow(_ window: SpaceWindow, toSpaceID id: UUID) {
        guard let location = spaceLocation(id: id) else { return }
        spaceStacks[location.stack].spaces[location.space].addWindow(window)
    }
    public mutating func insertWindow(_ window: SpaceWindow, at index: Int, inSpaceID id: UUID) {
        guard let location = spaceLocation(id: id) else { return }
        spaceStacks[location.stack].spaces[location.space].insertWindow(window, at: index)
    }
    public mutating func removeWindow(windowID: CGWindowID, fromSpaceID id: UUID) {
        if let location = spaceLocation(id: id) {
            spaceStacks[location.stack].spaces[location.space].removeWindow(windowID: windowID)
        }
        dormantWindowAssignments.removeAll {
            $0.spaceID == id && $0.window.windowID == windowID
        }
    }
    mutating func removeLiveWindowFromAllSpaces(windowID: CGWindowID) {
        for stack in spaceStacks.indices {
            for space in spaceStacks[stack].spaces.indices {
                spaceStacks[stack].spaces[space].removeWindow(windowID: windowID)
            }
        }
    }
    public mutating func removeAllWindows(forBundleID bundleID: String) {
        for stack in spaceStacks.indices {
            for space in spaceStacks[stack].spaces.indices {
                spaceStacks[stack].spaces[space].removeAllWindows(forBundleID: bundleID)
            }
        }
        dormantWindowAssignments.removeAll { $0.window.ownerBundleID == bundleID }
    }
    @discardableResult
    public mutating func removeAllWindows(forOwnerPID pid: pid_t) -> Int {
        var removed = 0
        for stack in spaceStacks.indices {
            for space in spaceStacks[stack].spaces.indices {
                removed += spaceStacks[stack].spaces[space].removeAllWindows(forOwnerPID: pid)
            }
        }
        let dormantBefore = dormantWindowAssignments.count
        dormantWindowAssignments.removeAll { $0.window.ownerPID == pid }
        return removed + dormantBefore - dormantWindowAssignments.count
    }
    @discardableResult
    public mutating func makeWindowsDormant(forOwnerPID pid: pid_t) -> Int {
        let assignments = allSpaces.flatMap { space in
            space.windows.enumerated().compactMap { index, window in
                window.ownerPID == pid
                    ? DormantWindowAssignment(spaceID: space.id, windowIndex: index, window: window)
                    : nil
            }
        }
        guard !assignments.isEmpty else { return 0 }
        let ids = Set(assignments.map(\.id))
        dormantWindowAssignments.removeAll { ids.contains($0.id) }
        dormantWindowAssignments.append(contentsOf: assignments)
        for stack in spaceStacks.indices {
            for space in spaceStacks[stack].spaces.indices {
                _ = spaceStacks[stack].spaces[space].removeAllWindows(forOwnerPID: pid)
            }
        }
        return assignments.count
    }
    /// Parks every live assignment, keeping the space and position it recorded. Used when
    /// the window IDs and PIDs those assignments carry came from a boot that has ended.
    @discardableResult
    public mutating func makeAllWindowsDormant() -> Int {
        let assignments = allSpaces.flatMap { space in
            space.windows.enumerated().map { index, window in
                DormantWindowAssignment(spaceID: space.id, windowIndex: index, window: window)
            }
        }
        guard !assignments.isEmpty else { return 0 }
        let ids = Set(assignments.map(\.id))
        dormantWindowAssignments.removeAll { ids.contains($0.id) }
        dormantWindowAssignments.append(contentsOf: assignments)
        for stack in spaceStacks.indices {
            for space in spaceStacks[stack].spaces.indices {
                spaceStacks[stack].spaces[space].removeAllWindows()
            }
        }
        return assignments.count
    }
    @discardableResult
    public mutating func makeWindowDormant(windowID: CGWindowID) -> DormantWindowAssignment? {
        for stack in spaceStacks.indices {
            for space in spaceStacks[stack].spaces.indices {
                guard let index = spaceStacks[stack].spaces[space].windows.firstIndex(where: {
                    $0.windowID == windowID
                }) else { continue }
                let current = spaceStacks[stack].spaces[space]
                let assignment = DormantWindowAssignment(
                    spaceID: current.id,
                    windowIndex: index,
                    window: current.windows[index]
                )
                spaceStacks[stack].spaces[space].removeWindow(windowID: windowID)
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
        guard spaceLocation(id: assignment.spaceID) != nil else { return false }
        var window = assignment.window
        window.windowID = windowID
        window.ownerPID = ownerPID
        window.windowTitle = windowTitle
        insertWindow(window, at: assignment.windowIndex, inSpaceID: assignment.spaceID)
        return true
    }
    public mutating func moveWindow(
        windowID: CGWindowID,
        fromSpaceID: UUID,
        toSpaceID: UUID,
        at windowIndex: Int? = nil
    ) {
        guard let source = spaceLocation(id: fromSpaceID),
              let destination = spaceLocation(id: toSpaceID),
              let window = spaceStacks[source.stack].spaces[source.space].windows.first(where: {
                  $0.windowID == windowID
              }) else { return }
        guard fromSpaceID != toSpaceID || windowIndex != nil else { return }
        spaceStacks[source.stack].spaces[source.space].removeWindow(windowID: windowID)
        if let windowIndex {
            spaceStacks[destination.stack].spaces[destination.space]
                .insertWindow(window, at: windowIndex)
        } else {
            spaceStacks[destination.stack].spaces[destination.space].addWindow(window)
        }
    }
    public mutating func bringWindowToFront(windowID: CGWindowID, inSpaceID id: UUID) {
        guard let location = spaceLocation(id: id) else { return }
        spaceStacks[location.stack].spaces[location.space].bringWindowToFront(windowID: windowID)
    }
    public mutating func updateWindowTitle(windowID: CGWindowID, title: String) {
        for stack in spaceStacks.indices {
            for space in spaceStacks[stack].spaces.indices {
                if let index = spaceStacks[stack].spaces[space].windows.firstIndex(where: {
                    $0.windowID == windowID
                }) {
                    spaceStacks[stack].spaces[space].updateWindowTitle(at: index, title: title)
                    return
                }
            }
        }
    }
    public mutating func updateWindowIDs(
        spaceIndex: Int,
        windowIndex: Int,
        windowID: CGWindowID,
        ownerPID: pid_t?,
        windowTitle: String? = nil
    ) {
        guard let stack = selectedStackIndex,
              spaceStacks[stack].spaces.indices.contains(spaceIndex) else { return }
        spaceStacks[stack].spaces[spaceIndex].updateWindow(
            at: windowIndex,
            windowID: windowID,
            ownerPID: ownerPID,
            windowTitle: windowTitle
        )
    }
    public mutating func updateWindowIDs(
        spaceID: UUID,
        windowIndex: Int,
        windowID: CGWindowID,
        ownerPID: pid_t?,
        windowTitle: String? = nil
    ) {
        guard let location = spaceLocation(id: spaceID) else { return }
        spaceStacks[location.stack].spaces[location.space].updateWindow(
            at: windowIndex,
            windowID: windowID,
            ownerPID: ownerPID,
            windowTitle: windowTitle
        )
    }
    public func spaceContainingWindow(windowID: CGWindowID) -> UUID? {
        allSpaces.first(where: { space in
            space.windows.contains(where: { $0.windowID == windowID })
        })?.id
    }

    private func spaceLocation(id: UUID) -> (stack: Int, space: Int)? {
        for stack in spaceStacks.indices {
            if let space = spaceStacks[stack].spaces.firstIndex(where: { $0.id == id }) {
                return (stack, space)
            }
        }
        return nil
    }
}
