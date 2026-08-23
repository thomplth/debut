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
    public let currentDesktopID: CGSSpaceID?

    public init(
        id: String,
        displayID: CGDirectDisplayID?,
        displayName: String,
        frame: CGRect,
        desktopIDs: [CGSSpaceID],
        currentDesktopID: CGSSpaceID?
    ) {
        self.id = id
        self.displayID = displayID
        self.displayName = displayName
        self.frame = frame
        self.desktopIDs = desktopIDs
        self.currentDesktopID = currentDesktopID
    }

    public var currentDesktopIndex: Int? {
        currentDesktopID.flatMap(desktopIDs.firstIndex)
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
