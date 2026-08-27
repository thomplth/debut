import AppKit
import CoreGraphics
import Foundation

public typealias LabSpaceID = UInt64
private typealias CGSConnectionID = Int32

nonisolated(unsafe) private let skyLightHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        ?? UnsafeMutableRawPointer(bitPattern: -2)
}()

private func skyLightSymbol<T>(_ name: String) -> T? {
    dlsym(skyLightHandle, name).map { unsafeBitCast($0, to: T.self) }
}

private let mainConnectionID: (@convention(c) () -> CGSConnectionID)? =
    skyLightSymbol("CGSMainConnectionID")
private let copyManagedDisplaySpaces:
    (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? =
    skyLightSymbol("CGSCopyManagedDisplaySpaces")

public struct LabSpaceStack: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayID: CGDirectDisplayID?
    public let displayName: String
    public let frame: CGRect
    public let desktopIDs: [LabSpaceID]
    public let currentDesktopID: LabSpaceID?

    public var currentDesktopIndex: Int? {
        currentDesktopID.flatMap(desktopIDs.firstIndex)
    }
}

public struct LabSpaceTopology: Equatable, Sendable {
    public let separateSpaces: Bool
    public let stacks: [LabSpaceStack]

    public static let empty = LabSpaceTopology(separateSpaces: false, stacks: [])
}

@MainActor
public final class SpaceTopologyReader {
    public init() {}

    public var canPostLegacyGestures: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }

    public func read() -> LabSpaceTopology {
        guard let mainConnectionID, let copyManagedDisplaySpaces else { return .empty }
        let connection = mainConnectionID()
        guard connection != 0,
              let managed = copyManagedDisplaySpaces(connection, nil)?
                .takeRetainedValue() as? [[String: Any]],
              !managed.isEmpty
        else { return .empty }

        let screens = NSScreen.screens
        let separate = NSScreen.screensHaveSeparateSpaces
        if !separate {
            let display = managed.first {
                ($0["Display Identifier"] as? String) == "Main"
            } ?? managed[0]
            let frames = screens.map(\.frame)
            let frame = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
            return LabSpaceTopology(separateSpaces: false, stacks: [
                LabSpaceStack(
                    id: "shared",
                    displayID: NSScreen.main?.displayID,
                    displayName: "All Displays",
                    frame: frame,
                    desktopIDs: Self.desktopIDs(in: display),
                    currentDesktopID: Self.currentDesktopID(in: display)
                ),
            ])
        }

        var remaining = managed
        var stacks: [LabSpaceStack] = []
        for screen in screens {
            guard let uuid = Self.displayUUID(screen.displayID),
                  let index = remaining.firstIndex(where: {
                      ($0["Display Identifier"] as? String) == uuid
                  })
            else { continue }
            let display = remaining.remove(at: index)
            stacks.append(LabSpaceStack(
                id: uuid,
                displayID: screen.displayID,
                displayName: screen.localizedName,
                frame: screen.frame,
                desktopIDs: Self.desktopIDs(in: display),
                currentDesktopID: Self.currentDesktopID(in: display)
            ))
        }
        for display in remaining {
            guard let id = display["Display Identifier"] as? String else { continue }
            stacks.append(LabSpaceStack(
                id: id,
                displayID: nil,
                displayName: "Display \(stacks.count + 1)",
                frame: .zero,
                desktopIDs: Self.desktopIDs(in: display),
                currentDesktopID: Self.currentDesktopID(in: display)
            ))
        }
        return LabSpaceTopology(separateSpaces: true, stacks: stacks)
    }

    private static func desktopIDs(in display: [String: Any]) -> [LabSpaceID] {
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        return spaces.compactMap { space in
            guard (space["type"] as? NSNumber)?.intValue ?? 0 == 0 else { return nil }
            return (space["id64"] as? NSNumber)?.uint64Value
        }
    }

    private static func currentDesktopID(in display: [String: Any]) -> LabSpaceID? {
        ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
    }

    private static func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
