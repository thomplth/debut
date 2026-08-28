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
    public let desktopIDs: [CGSSpaceID]
    /// The same desktops as `desktopIDs`, in the same order, keyed by the identity that
    /// survives a reboot. Empty when the window server withheld a uuid for any desktop, so
    /// this is all-or-nothing rather than something to index opportunistically.
    public let desktopUUIDs: [String]
    public let currentDesktopID: CGSSpaceID?
    public let currentDesktopUUID: String?

    public init(
        id: String,
        displayID: CGDirectDisplayID?,
        displayName: String,
        frame: CGRect,
        desktopIDs: [CGSSpaceID],
        desktopUUIDs: [String] = [],
        currentDesktopID: CGSSpaceID?,
        currentDesktopUUID: String? = nil
    ) {
        self.id = id
        self.displayID = displayID
        self.displayName = displayName
        self.frame = frame
        self.desktopIDs = desktopIDs
        self.desktopUUIDs = desktopUUIDs.count == desktopIDs.count ? desktopUUIDs : []
        self.currentDesktopID = currentDesktopID
        self.currentDesktopUUID = currentDesktopUUID
    }

    public var currentDesktopIndex: Int? {
        currentDesktopID.flatMap(desktopIDs.firstIndex)
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
}
