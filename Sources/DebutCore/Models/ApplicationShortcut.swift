import CoreGraphics
import Foundation

public enum ApplicationShortcutWindows: String, Codable, Sendable, CaseIterable {
    case all
    case lastUsed

    public var displayName: String {
        switch self {
        case .all: "All windows"
        case .lastUsed: "Last used window"
        }
    }
}

public enum ApplicationShortcutPlacement: String, Codable, Sendable, CaseIterable {
    case moveHiddenToCurrentDesktop
    case moveAllToCurrentDesktop
    case switchToWindowDesktop

    public var displayName: String {
        switch self {
        case .moveHiddenToCurrentDesktop: "Move hidden windows to current desktop"
        case .moveAllToCurrentDesktop: "Move windows to current desktop"
        case .switchToWindowDesktop: "Switch to the window's desktop"
        }
    }
}

public struct ApplicationShortcut: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var appPath: String
    public var combo: KeyCombo?
    public var isEnabled: Bool
    public var onlyHide: Bool
    public var onlyShow: Bool
    public var onlyIfRunning: Bool
    public var opensNewWindowWhenNoneOpen: Bool
    public var windows: ApplicationShortcutWindows
    public var placement: ApplicationShortcutPlacement

    public init(
        id: UUID = UUID(),
        bundleID: String,
        appName: String,
        appPath: String,
        combo: KeyCombo? = nil,
        isEnabled: Bool = true,
        onlyHide: Bool = false,
        onlyShow: Bool = false,
        onlyIfRunning: Bool = false,
        opensNewWindowWhenNoneOpen: Bool = false,
        windows: ApplicationShortcutWindows = .all,
        placement: ApplicationShortcutPlacement = .moveHiddenToCurrentDesktop
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.appPath = appPath
        self.combo = combo
        self.isEnabled = isEnabled
        self.onlyHide = onlyHide
        self.onlyShow = onlyShow
        self.onlyIfRunning = onlyIfRunning
        self.opensNewWindowWhenNoneOpen = opensNewWindowWhenNoneOpen
        self.windows = windows
        self.placement = placement
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleID, appName, appPath, combo, isEnabled, onlyHide, onlyShow, onlyIfRunning
        case opensNewWindowWhenNoneOpen, windows, placement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ApplicationShortcut(bundleID: "", appName: "", appPath: "")
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        id = value(.id, UUID())
        bundleID = try container.decode(String.self, forKey: .bundleID)
        appName = value(.appName, bundleID)
        appPath = value(.appPath, defaults.appPath)
        combo = try? container.decodeIfPresent(KeyCombo.self, forKey: .combo)
        isEnabled = value(.isEnabled, defaults.isEnabled)
        onlyHide = value(.onlyHide, defaults.onlyHide)
        onlyShow = value(.onlyShow, defaults.onlyShow)
        onlyIfRunning = value(.onlyIfRunning, defaults.onlyIfRunning)
        opensNewWindowWhenNoneOpen = value(
            .opensNewWindowWhenNoneOpen, defaults.opensNewWindowWhenNoneOpen
        )
        windows = value(.windows, defaults.windows)
        placement = value(.placement, defaults.placement)
    }

    public var activeCombo: KeyCombo? { isEnabled ? combo : nil }
}

public struct ApplicationShortcutTarget: Sendable, Equatable {
    public let pid: pid_t
    public let isActive: Bool
    public let isHidden: Bool

    public init(pid: pid_t, isActive: Bool, isHidden: Bool) {
        self.pid = pid
        self.isActive = isActive
        self.isHidden = isHidden
    }
}

public struct ApplicationReveal: Sendable, Equatable {
    public let pid: pid_t
    public let unhides: Bool
    public let focusWindowID: CGWindowID
    public let destinationSpaceID: UUID
    public let relocatedWindowIDs: [CGWindowID]
    /// Back to front, so the last raise leaves the most recent of them nearest the focused window.
    public let raisedWindowIDs: [CGWindowID]
}

public enum ApplicationToggle: Sendable, Equatable {
    case ignore
    case open
    case hide(pid: pid_t)
    case openNewWindow(pid: pid_t)
    case reveal(ApplicationReveal)

    /// - Parameter windows: The application's tracked windows, most recently used first.
    public static func plan(
        _ shortcut: ApplicationShortcut,
        target: ApplicationShortcutTarget?,
        windows: [GlobalWindowEntry],
        activeSpaceID: UUID,
        isExcluded: Bool,
        canMoveWindows: Bool
    ) -> ApplicationToggle {
        guard let target else {
            return shortcut.onlyIfRunning || shortcut.onlyHide ? .ignore : .open
        }
        // An active app with tracked windows only on other desktops is not in view; hiding it
        // would make the first press do nothing visible.
        let isInView = target.isActive && !target.isHidden
            && (isExcluded || windows.isEmpty || windows.contains { $0.spaceID == activeSpaceID })
        if isInView, !shortcut.onlyShow { return .hide(pid: target.pid) }
        if shortcut.onlyHide { return .ignore }
        if isExcluded { return .open }
        guard let mostRecent = windows.first else {
            return shortcut.opensNewWindowWhenNoneOpen ? .openNewWindow(pid: target.pid) : .open
        }

        let affected = shortcut.windows == .lastUsed ? [mostRecent] : windows
        let placementRelocates = switch shortcut.placement {
        case .moveAllToCurrentDesktop: true
        case .moveHiddenToCurrentDesktop: target.isHidden
        case .switchToWindowDesktop: false
        }
        let relocated = canMoveWindows && placementRelocates
            ? affected.filter { $0.spaceID != activeSpaceID }.map(\.window.windowID) : []
        func finalSpace(of entry: GlobalWindowEntry) -> UUID {
            relocated.contains(entry.window.windowID) ? activeSpaceID : entry.spaceID
        }
        let focused = shortcut.windows == .all
            ? windows.first { finalSpace(of: $0) == activeSpaceID } ?? mostRecent
            : mostRecent
        let destination = finalSpace(of: focused)
        let raised = shortcut.windows == .all
            ? windows.filter { $0 != focused && finalSpace(of: $0) == destination }
                .map(\.window.windowID).reversed()
            : []
        return .reveal(ApplicationReveal(
            pid: target.pid,
            unhides: target.isHidden,
            focusWindowID: focused.window.windowID,
            destinationSpaceID: destination,
            relocatedWindowIDs: relocated,
            raisedWindowIDs: Array(raised)
        ))
    }
}
