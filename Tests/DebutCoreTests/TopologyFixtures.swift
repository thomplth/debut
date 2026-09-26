import CoreGraphics
import Foundation
@testable import DebutCore

extension SpaceManager {
    /// Adds one desktop beside the active one and shows it, the way Mission Control's "+" does.
    /// It changes the model only through `reconcileSpaceStacks(with:)`, as production must:
    /// the stages Debut holds are always the desktops macOS reports.
    mutating func addFixtureDesktop(above: Bool = false) {
        guard let selected = spaceStacks.first(where: { $0.id == selectedSpaceStackID }),
              let active = selected.spaces.firstIndex(where: { $0.id == selected.activeSpaceID })
        else { return }
        let insertion = above ? active : active + 1
        let descriptors = connectedSpaceStacks.map { stack -> SpaceStackDescriptor in
            let current = stack.spaces.firstIndex(where: { $0.id == stack.activeSpaceID }) ?? 0
            // A model not yet joined to desktops stays unjoined, so the switcher topology a test
            // installs later still adopts every space by position, as a real launch does.
            guard stack.spaces.allSatisfy({ $0.desktopUUID != nil }) else {
                let count = stack.spaces.count + (stack.id == selected.id ? 1 : 0)
                return fixtureDescriptor(
                    id: stack.id,
                    name: stack.displayName,
                    count: count,
                    current: stack.id == selected.id ? count - 1 : current
                )
            }
            var uuids = stack.spaces.compactMap(\.desktopUUID)
            guard stack.id == selected.id else {
                return fixtureDescriptor(id: stack.id, name: stack.displayName, uuids: uuids, current: current)
            }
            uuids.insert("FIXTURE-\(UUID().uuidString)", at: insertion)
            return fixtureDescriptor(id: stack.id, name: stack.displayName, uuids: uuids, current: insertion)
        }
        reconcileSpaceStacks(with: SpaceTopology(
            separateSpaces: descriptors.count > 1 || selected.id != SpaceTopology.sharedStackID,
            stacks: descriptors
        ))
    }

    /// Unjoined spaces can only be resized, which appends: a stage added this way lands last.
    private func fixtureDescriptor(
        id: String,
        name: String,
        count: Int,
        current: Int
    ) -> SpaceStackDescriptor {
        let ids = (0..<count).map { CGSSpaceID(2_000 + $0) }
        return SpaceStackDescriptor(
            id: id,
            displayID: nil,
            displayName: name,
            frame: .zero,
            desktopIDs: ids,
            currentDesktopID: ids[current]
        )
    }

    private func fixtureDescriptor(
        id: String,
        name: String,
        uuids: [String],
        current: Int
    ) -> SpaceStackDescriptor {
        let ids = uuids.map { CGSSpaceID(abs($0.hashValue) % 1_000_000 + 1) }
        return SpaceStackDescriptor(
            id: id,
            displayID: nil,
            displayName: name,
            frame: .zero,
            desktopIDs: ids,
            desktopUUIDs: uuids,
            currentDesktopID: ids[current],
            currentDesktopUUID: uuids[current]
        )
    }
}
