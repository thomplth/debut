import CoreGraphics
import Foundation

/// One macOS desktop addressed without throwing away the display that owns it.
public struct DesktopLocation: Codable, Equatable, Hashable, Sendable {
    public let stackID: String
    public let desktopID: CGSSpaceID
    public let index: Int

    public init(stackID: String, desktopID: CGSSpaceID, index: Int) {
        self.stackID = stackID
        self.desktopID = desktopID
        self.index = index
    }
}

/// The runtime desktop list for one display, or for the shared display wall.
public struct SpaceStackDescriptor: Equatable, Sendable {
    public let id: String
    public let displayID: CGDirectDisplayID?
    public let displayName: String
    public let frame: CGRect
    /// Every navigable macOS Space in Mission Control order, including fullscreen and tiled
    /// Spaces that do not correspond to one of Debut's desktop-backed stages.
    public let orderedSpaceIDs: [CGSSpaceID]
    public let desktopIDs: [CGSSpaceID]
    /// The same desktops as `desktopIDs`, in the same order, keyed by the identity that
    /// survives a reboot. Empty when the window server withheld a uuid for any desktop, so
    /// this is all-or-nothing rather than something to index opportunistically.
    public let desktopUUIDs: [String]
    /// WindowServer's showing Space. The historical name is retained because callers that need
    /// a type-0 desktop distinguish it with `currentDesktopIndex`.
    public let currentDesktopID: CGSSpaceID?
    public let currentDesktopUUID: String?

    public init(
        id: String,
        displayID: CGDirectDisplayID?,
        displayName: String,
        frame: CGRect,
        desktopIDs: [CGSSpaceID],
        orderedSpaceIDs: [CGSSpaceID]? = nil,
        desktopUUIDs: [String] = [],
        currentDesktopID: CGSSpaceID?,
        currentDesktopUUID: String? = nil
    ) {
        self.id = id
        self.displayID = displayID
        self.displayName = displayName
        self.frame = frame
        self.desktopIDs = desktopIDs
        let ordered = orderedSpaceIDs ?? desktopIDs
        self.orderedSpaceIDs = Set(ordered).count == ordered.count
            && desktopIDs.allSatisfy(ordered.contains)
            ? ordered
            : desktopIDs
        self.desktopUUIDs = desktopUUIDs.count == desktopIDs.count ? desktopUUIDs : []
        self.currentDesktopID = currentDesktopID
        self.currentDesktopUUID = currentDesktopUUID
    }

    public var currentDesktopIndex: Int? {
        currentDesktopID.flatMap(desktopIDs.firstIndex)
    }

    /// The showing position in Mission Control's complete Space order. Unlike
    /// `currentDesktopIndex`, this remains resolved while a fullscreen app is showing.
    public var currentSpaceIndex: Int? {
        currentDesktopID.flatMap(orderedSpaceIDs.firstIndex)
    }

    public func desktopUUID(at index: Int) -> String? {
        guard desktopUUIDs.indices.contains(index) else { return nil }
        return desktopUUIDs[index]
    }

    public func location(at index: Int) -> DesktopLocation? {
        guard desktopIDs.indices.contains(index) else { return nil }
        return DesktopLocation(stackID: id, desktopID: desktopIDs[index], index: index)
    }
}

/// The complete Space topology macOS exposes at one instant.
public struct SpaceTopology: Equatable, Sendable {
    public static let sharedStackID = "shared"

    public let separateSpaces: Bool
    public let stacks: [SpaceStackDescriptor]

    public init(separateSpaces: Bool, stacks: [SpaceStackDescriptor]) {
        self.separateSpaces = separateSpaces
        self.stacks = stacks
    }

    /// Whether any stack reports a desktop. The window server can answer with none.
    public var hasDesktops: Bool { stacks.contains { !$0.desktopIDs.isEmpty } }

    public func stack(id: String) -> SpaceStackDescriptor? {
        stacks.first { $0.id == id }
    }

    public func stack(displayID: CGDirectDisplayID) -> SpaceStackDescriptor? {
        stacks.first { $0.displayID == displayID }
    }

    public func location(ofSpace spaceID: CGSSpaceID) -> DesktopLocation? {
        for stack in stacks {
            if let index = stack.desktopIDs.firstIndex(of: spaceID) {
                return DesktopLocation(stackID: stack.id, desktopID: spaceID, index: index)
            }
        }
        return nil
    }

    /// The showing desktop, for a window the window server puts on that desktop and at least
    /// one other of the same stack — which is what Dock → Options → Assign To: All Desktops
    /// does. Such a window is wherever the user is, so the desktop showing is its one honest
    /// location. A single Space, or none, is not this case and answers nil (KHA-853).
    public func showingLocation(ofWindowOnSpaces spaceIDs: [CGSSpaceID]) -> DesktopLocation? {
        let locations = Set(spaceIDs.compactMap(location(ofSpace:)))
        for stack in stacks {
            guard let index = stack.currentDesktopIndex,
                  let showing = stack.location(at: index),
                  locations.contains(showing),
                  locations.contains(where: { $0.stackID == stack.id && $0 != showing })
            else { continue }
            return showing
        }
        return nil
    }
}

public extension SpaceTopology {
    /// One shared stack of synthetic desktops, for tests and benchmarks that need desktops
    /// without a window server. A model only ever gains or loses stages by reconciling a
    /// topology like this one: Debut cannot create or delete a macOS desktop (KHA-783).
    static func synthetic(desktopUUIDs: [String], currentIndex: Int = 0) -> SpaceTopology {
        let desktopIDs = desktopUUIDs.indices.map { CGSSpaceID(1_000 + $0) }
        let current = desktopUUIDs.indices.contains(currentIndex) ? currentIndex : nil
        return SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: desktopIDs,
                desktopUUIDs: desktopUUIDs,
                currentDesktopID: current.map { desktopIDs[$0] },
                currentDesktopUUID: current.map { desktopUUIDs[$0] }
            ),
        ])
    }

    static func synthetic(desktopCount: Int, currentIndex: Int = 0) -> SpaceTopology {
        synthetic(
            desktopUUIDs: (0..<max(0, desktopCount)).map { "SYNTHETIC-DESKTOP-\($0 + 1)" },
            currentIndex: currentIndex
        )
    }
}
