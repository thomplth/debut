import CoreGraphics
import Foundation

// Adding and removing macOS desktops without Mission Control (KHA-1087).
//
// The window manager accepts a bridged request to create or destroy a desktop from any process,
// with SIP enabled, in a few milliseconds and with nothing drawn. Whether the result is a real
// desktop is decided by the Dock, not the window server:
//
//   - macOS 27: the Dock adopts it. Mission Control lists it, Control-Arrow reaches it, and
//     `com.apple.spaces` stores it within seconds.
//   - macOS 26.6: the window server lists it with a uuid, yet the Dock never learns of it.
//     Control-Arrow stops before it and it is never persisted — a desktop the user cannot reach.
//
// Both answer identically to every call Debut can make, so the capability is gated on the
// release rather than detected.

/// Which macOS releases have been measured to adopt a desktop Debut creates.
enum DesktopManagementCompatibility {
    static func supports(operatingSystemMajor: Int) -> Bool {
        operatingSystemMajor == 27
    }

    /// Shows the desktop controls on an unsupported release so their staging and motion can be
    /// exercised in the macOS 26 guest. A commit there still makes a desktop the Dock never adopts.
    static var isForced: Bool {
        ProcessInfo.processInfo.environment["DEBUT_FORCE_DESKTOP_MANAGEMENT"] == "1"
    }

    static var isSupported: Bool {
        isForced
            || supports(operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

/// Where a new desktop goes in its display's order. macOS appends every new desktop; anything
/// else is a reorder afterwards.
public enum DesktopPlacement: Equatable, Sendable {
    case start
    case end
    /// Straight after this desktop, ahead of any fullscreen Space that follows it.
    case after(CGSSpaceID)
}

/// Why a desktop removal was refused before anything was sent to the window server.
public enum DesktopRemovalRefusal: String, Equatable, Sendable {
    /// The desktop is not in the current topology, or no longer at the index the caller read.
    case unknownDesktop
    /// A display always keeps one desktop.
    case lastDesktop
    /// macOS moves a removed desktop's windows onto the desktop showing. Removing the showing
    /// desktop itself would leave that destination to the window server's choice, so the caller
    /// switches away first.
    case showingDesktop
}

/// The decisions around creating and removing a desktop that do not need a window server.
enum DesktopManagementPlan {

    /// Where a newly created desktop landed, if it landed where it was asked to.
    ///
    /// The window server picks the display. A desktop that appears on another display is not
    /// what the caller asked for, and a desktop not listed yet has not been adopted; both
    /// answer nil.
    static func createdLocation(
        of desktopID: CGSSpaceID,
        onStack stackID: String,
        in topology: SpaceTopology
    ) -> DesktopLocation? {
        guard let location = topology.location(ofSpace: desktopID),
              location.stackID == stackID
        else { return nil }
        return location
    }

    /// Where `desktopID` must stand in the stack's complete Space order to honour `placement`,
    /// or nil when it already does or the anchor is gone. The window server takes the desktop
    /// out and reinserts it at this index, so the index is counted in the finished order.
    static func orderedIndex(
        placing desktopID: CGSSpaceID,
        at placement: DesktopPlacement,
        in stack: SpaceStackDescriptor
    ) -> Int? {
        guard let current = stack.orderedSpaceIDs.firstIndex(of: desktopID) else { return nil }
        let others = stack.orderedSpaceIDs.filter { $0 != desktopID }
        let target: Int
        switch placement {
        case .end:
            return nil
        case .start:
            target = 0
        case let .after(anchor):
            guard let anchorIndex = others.firstIndex(of: anchor) else { return nil }
            target = anchorIndex + 1
        }
        return target == current ? nil : target
    }

    static func removalRefusal(
        for location: DesktopLocation,
        in topology: SpaceTopology
    ) -> DesktopRemovalRefusal? {
        guard let stack = topology.stack(id: location.stackID),
              stack.desktopIDs.indices.contains(location.index),
              stack.desktopIDs[location.index] == location.desktopID
        else { return .unknownDesktop }
        if stack.desktopIDs.count <= 1 { return .lastDesktop }
        if stack.currentDesktopID == location.desktopID { return .showingDesktop }
        return nil
    }
}
