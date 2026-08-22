import CoreGraphics
import Foundation

public struct WindowTrackingDiagnosticSnapshot: Sendable {
    public struct WindowOwner: Sendable {
        public let windowID: CGWindowID
        public let ownerPID: pid_t

        public init(windowID: CGWindowID, ownerPID: pid_t) {
            self.windowID = windowID
            self.ownerPID = ownerPID
        }
    }

    public let knownWindowIDs: Set<CGWindowID>
    public let armedWindowIDs: Set<CGWindowID>
    public let unarmedWindowIDs: Set<CGWindowID>
    public let monitoredProcessIDs: Set<pid_t>
    public let observedPID: pid_t?
    public let observerProcessIDs: Set<pid_t>
    public let windowOwners: [WindowOwner]

    public init(
        knownWindowIDs: Set<CGWindowID>,
        armedWindowIDs: Set<CGWindowID>,
        unarmedWindowIDs: Set<CGWindowID>,
        monitoredProcessIDs: Set<pid_t>,
        observedPID: pid_t?,
        observerProcessIDs: Set<pid_t>,
        windowOwners: [WindowOwner]
    ) {
        self.knownWindowIDs = knownWindowIDs
        self.armedWindowIDs = armedWindowIDs
        self.unarmedWindowIDs = unarmedWindowIDs
        self.monitoredProcessIDs = monitoredProcessIDs
        self.observedPID = observedPID
        self.observerProcessIDs = observerProcessIDs
        self.windowOwners = windowOwners
    }

    public static let empty = WindowTrackingDiagnosticSnapshot(
        knownWindowIDs: [],
        armedWindowIDs: [],
        unarmedWindowIDs: [],
        monitoredProcessIDs: [],
        observedPID: nil,
        observerProcessIDs: [],
        windowOwners: []
    )
}

public struct DiagnosticScreenSnapshot: Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScaleFactor: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect, backingScaleFactor: CGFloat) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
    }
}

public struct DiagnosticExportSnapshot: Sendable {
    public let stageManager: StageManager
    public let settings: AppSettings
    public let liveWindows: [WindowInfo]
    public let runningApps: [AppInfo]
    public let allWindowIDs: Set<CGWindowID>?
    public let untrackableWindowIDs: Set<CGWindowID>
    public let tracking: WindowTrackingDiagnosticSnapshot
    public let frontmostBundleID: String?
    public let accessibilityEnabled: Bool
    public let screens: [DiagnosticScreenSnapshot]

    public init(
        stageManager: StageManager,
        settings: AppSettings,
        liveWindows: [WindowInfo],
        runningApps: [AppInfo],
        allWindowIDs: Set<CGWindowID>?,
        untrackableWindowIDs: Set<CGWindowID>,
        tracking: WindowTrackingDiagnosticSnapshot,
        frontmostBundleID: String?,
        accessibilityEnabled: Bool,
        screens: [DiagnosticScreenSnapshot]
    ) {
        self.stageManager = stageManager
        self.settings = settings
        self.liveWindows = liveWindows
        self.runningApps = runningApps
        self.allWindowIDs = allWindowIDs
        self.untrackableWindowIDs = untrackableWindowIDs
        self.tracking = tracking
        self.frontmostBundleID = frontmostBundleID
        self.accessibilityEnabled = accessibilityEnabled
        self.screens = screens
    }

    public static let empty = DiagnosticExportSnapshot(
        stageManager: StageManager(),
        settings: AppSettings(),
        liveWindows: [],
        runningApps: [],
        allWindowIDs: nil,
        untrackableWindowIDs: [],
        tracking: .empty,
        frontmostBundleID: nil,
        accessibilityEnabled: false,
        screens: []
    )
}

public final class DiagnosticExporter {
    private let directory: URL
    private let now: @Sendable () -> Date

    public convenience init() {
        self.init(applicationSupportDirectory: DebutCore.applicationSupportDirectory)
    }

    init(
        applicationSupportDirectory: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = applicationSupportDirectory
        self.now = now
    }

    public func export(_ snapshot: DiagnosticExportSnapshot, to destination: URL) throws {
        let root: [String: Any] = [
            "metadata": metadata(),
            "runtime": try runtimeObject(snapshot),
            "persisted": [
                "state": jsonFile(named: "state.json"),
                "settings": jsonFile(named: "settings.json"),
            ],
            "diagnostic": [
                "currentSnapshot": jsonFile(named: "diagnostic.json"),
                "currentLifecycleEvents": jsonLinesFile(named: "diagnostic.jsonl"),
                "previousLifecycleEvents": jsonLinesFile(named: "diagnostic.jsonl.1"),
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: destination, options: .atomic)
    }

    private func metadata() -> [String: Any] {
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        return [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: now()),
            "appVersion": DebutCore.version,
            "bundleIdentifier": bundle.bundleIdentifier ?? "unknown",
            "bundleVersion": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "operatingSystem": process.operatingSystemVersionString,
            "processorCount": process.processorCount,
            "physicalMemoryBytes": process.physicalMemory,
            "systemUptimeSeconds": process.systemUptime,
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier,
        ]
    }

    private func runtimeObject(_ snapshot: DiagnosticExportSnapshot) throws -> [String: Any] {
        let allWindowIDs: Any
        if let ids = snapshot.allWindowIDs {
            allWindowIDs = sortedWindowIDs(ids)
        } else {
            allWindowIDs = NSNull()
        }
        let frontmostBundleID: Any
        if let bundleID = snapshot.frontmostBundleID {
            frontmostBundleID = bundleID
        } else {
            frontmostBundleID = NSNull()
        }
        return [
            "stageManager": try jsonObject(snapshot.stageManager),
            "settings": try jsonObject(snapshot.settings),
            "discoveredWindows": snapshot.liveWindows
                .sorted { $0.windowID < $1.windowID }
                .map(windowObject),
            "runningApps": snapshot.runningApps
                .sorted { ($0.bundleID, $0.pid) < ($1.bundleID, $1.pid) }
                .map(appObject),
            "allCGWindowIDs": allWindowIDs,
            "untrackableWindowIDs": sortedWindowIDs(snapshot.untrackableWindowIDs),
            "tracking": trackingObject(snapshot.tracking),
            "frontmostBundleID": frontmostBundleID,
            "accessibilityEnabled": snapshot.accessibilityEnabled,
            "screens": snapshot.screens.map(screenObject),
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func windowObject(_ window: WindowInfo) -> [String: Any] {
        [
            "windowID": Int(window.windowID),
            "ownerBundleID": window.ownerBundleID,
            "ownerName": window.ownerName,
            "ownerPID": Int(window.ownerPID),
            "windowTitle": window.title,
            "bounds": rectObject(window.bounds),
            "isOnScreen": window.isOnScreen,
        ]
    }

    private func appObject(_ app: AppInfo) -> [String: Any] {
        [
            "bundleID": app.bundleID,
            "name": app.name,
            "pid": Int(app.pid),
            "isHidden": app.isHidden,
        ]
    }

    private func trackingObject(_ tracking: WindowTrackingDiagnosticSnapshot) -> [String: Any] {
        let observedPID: Any
        if let pid = tracking.observedPID {
            observedPID = Int(pid)
        } else {
            observedPID = NSNull()
        }
        return [
            "knownWindowIDs": sortedWindowIDs(tracking.knownWindowIDs),
            "armedWindowIDs": sortedWindowIDs(tracking.armedWindowIDs),
            "unarmedWindowIDs": sortedWindowIDs(tracking.unarmedWindowIDs),
            "monitoredProcessIDs": tracking.monitoredProcessIDs.map(Int.init).sorted(),
            "observedPID": observedPID,
            "observerProcessIDs": tracking.observerProcessIDs.map(Int.init).sorted(),
            "windowOwners": tracking.windowOwners
                .sorted { $0.windowID < $1.windowID }
                .map { [
                    "windowID": Int($0.windowID),
                    "ownerPID": Int($0.ownerPID),
                ] },
        ]
    }

    private func screenObject(_ screen: DiagnosticScreenSnapshot) -> [String: Any] {
        [
            "frame": rectObject(screen.frame),
            "visibleFrame": rectObject(screen.visibleFrame),
            "backingScaleFactor": Double(screen.backingScaleFactor),
        ]
    }

    private func rectObject(_ rect: CGRect) -> [String: Double] {
        [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.width),
            "height": Double(rect.height),
        ]
    }

    private func sortedWindowIDs(_ ids: Set<CGWindowID>) -> [Int] {
        ids.map(Int.init).sorted()
    }

    private func jsonFile(named name: String) -> Any {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ["status": "missing"]
        }
        do {
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch {
            return [
                "status": "unreadable",
                "error": String(describing: error),
            ]
        }
    }

    private func jsonLinesFile(named name: String) -> [[String: Any]] {
        let url = directory.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").enumerated().map { index, line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return [
                    "event": "diagnostic_parse_error",
                    "lineNumber": index + 1,
                ]
            }
            return object
        }
    }
}
