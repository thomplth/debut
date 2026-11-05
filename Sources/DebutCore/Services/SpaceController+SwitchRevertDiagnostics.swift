import AppKit
import CoreGraphics
import Foundation

public enum SpaceSwitchTrigger: String, Sendable {
    case request
    case quickSwitch = "quick_switch"
    case overlay
    case applicationShortcut = "application_shortcut"
    case windowMove = "window_move"
}

struct IssuedSpaceSwitch {
    let originID: UUID
    let destinationID: UUID
    let trigger: SpaceSwitchTrigger
    let focusesWindow: Bool
    let issuedAt: Date
}

extension SpaceController {
    static let switchRevertWindow: TimeInterval = 3

    func reportRevertIfPulledOffDestination(leftSpaceID: UUID, landedSpaceID: UUID) {
        guard let issued = lastIssuedSwitch,
              leftSpaceID == issued.destinationID,
              let stackID = spaceManager.spaceStackID(containingSpaceID: landedSpaceID),
              spaceSwitcher?.isSwitchInFlight(stackID: stackID) != true
        else { return }
        let elapsed = clock().timeIntervalSince(issued.issuedAt)
        guard elapsed >= 0, elapsed < Self.switchRevertWindow else { return }
        lastIssuedSwitch = nil

        let frontmostPID = windowService.frontmostApplicationPID()
        let frontmostBundleID = frontmostPID
            .flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let focusedDesktopID = focusedWindowID
            .flatMap { spaceManager.spaceContainingWindow(windowID: $0) }
        var details: [String: String] = [
            "from": compactDesktopLabel(forSpaceID: issued.originID),
            "to": compactDesktopLabel(forSpaceID: issued.destinationID),
            "landedOn": compactDesktopLabel(forSpaceID: landedSpaceID),
            "trigger": issued.trigger.rawValue,
            "focusesWindow": "\(issued.focusesWindow)",
            "elapsedMilliseconds": String(format: "%.0f", elapsed * 1000),
        ]
        details["frontmostPID"] = frontmostPID.map { "\($0)" } ?? "none"
        details["frontmostBundleID"] = frontmostBundleID ?? "none"
        details["focusedWindowID"] = focusedWindowID.map { "\($0)" } ?? "none"
        details["focusedWindowDesktop"] = focusedDesktopID.map { compactDesktopLabel(forSpaceID: $0) } ?? "none"
        if let frontmostPID {
            details["frontmostManagedWindows"] = managedWindowInventory(ownerPID: frontmostPID)
            details["frontmostUnmanagedWindows"] = unmanagedWindowInventory(ownerPID: frontmostPID)
        }
        diag.report("desktop_switch_reverted", details: details)
    }

    private func compactDesktopLabel(forSpaceID id: UUID) -> String {
        spaceManager.spaceIndex(id: id).map { "Space \($0 + 1)" } ?? "?"
    }

    private func managedWindowInventory(ownerPID: pid_t) -> String {
        spaceManager.allSpaces.flatMap { space in
            space.windows.filter { $0.ownerPID == ownerPID }.map {
                "\($0.windowID)@\(compactDesktopLabel(forSpaceID: space.id))"
            }
        }.joined(separator: ",")
    }

    /// Dialogs, sheets and panels are refused as stage members, yet an app raising one of them
    /// is exactly what can pull the desktop back, so they are located through the window server.
    private func unmanagedWindowInventory(ownerPID: pid_t) -> String {
        guard let switcher = spaceSwitcher,
              let descriptions = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[CFString: Any]]
        else { return "" }
        let managed = Set(spaceManager.allSpaces.flatMap { $0.windows.map(\.windowID) })
        let locations = switcher.windowLocations()
        return descriptions.compactMap { description -> String? in
            guard (description[kCGWindowOwnerPID] as? NSNumber)?.int32Value == ownerPID,
                  let number = description[kCGWindowNumber] as? NSNumber
            else { return nil }
            let windowID = CGWindowID(number.uint32Value)
            guard !managed.contains(windowID), let location = locations[windowID] else { return nil }
            let layer = (description[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
            return "\(windowID)@Space \(location.index + 1):layer\(layer)"
        }.joined(separator: ",")
    }
}
