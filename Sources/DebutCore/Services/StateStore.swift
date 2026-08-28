import Foundation

/// Identifies the running boot. Every window ID and PID in `state.json` was issued by one
/// boot and means nothing in the next, because macOS reissues both from low numbers.
public enum BootSession {
    public static var current: String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return "unknown" }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }
}

public final class StateStore: Sendable {
    private let directory: URL
    private let bootSessionID: String
    private let diag: DiagnosticReporter
    private var stateFileURL: URL { directory.appendingPathComponent("state.json") }
    private var settingsFileURL: URL { directory.appendingPathComponent("settings.json") }

    /// The boot the saved window IDs belong to, written alongside the spaces.
    private struct BootStamp: Codable {
        let bootSessionID: String?
    }

    /// Writes the stamp into `SpaceManager`'s own keyed container, so the file keeps its
    /// shape and the model stays free of a field only persistence cares about.
    private struct StampedState: Encodable {
        let manager: SpaceManager
        let bootSessionID: String

        private enum CodingKeys: String, CodingKey { case bootSessionID }

        func encode(to encoder: any Encoder) throws {
            try manager.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bootSessionID, forKey: .bootSessionID)
        }
    }

    public init(
        directory: URL,
        bootSessionID: String = BootSession.current,
        diagnosticReporter: DiagnosticReporter = .shared
    ) {
        self.directory = directory
        self.bootSessionID = bootSessionID
        self.diag = diagnosticReporter
    }

    public convenience init() {
        self.init(directory: DebutCore.applicationSupportDirectory)
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Space state

    public func save(_ manager: SpaceManager) throws {
        let performanceID = PerformanceRecorder.shared.begin(
            .statePersistence,
            workload: .init(
                spaces: manager.spaces.count,
                windows: manager.liveWindowCount,
                dormantWindows: manager.dormantWindowAssignments.count
            )
        )
        defer { PerformanceRecorder.shared.end(performanceID) }
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(StampedState(manager: manager, bootSessionID: bootSessionID))
        try data.write(to: stateFileURL, options: .atomic)
    }

    public func load() throws -> SpaceManager {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            return SpaceManager()
        }
        let data = try Data(contentsOf: stateFileURL)

        // Try new format first
        if var manager = try? JSONDecoder().decode(SpaceManager.self, from: data) {
            let saved = (try? JSONDecoder().decode(BootStamp.self, from: data))?.bootSessionID
            guard saved == bootSessionID else {
                // A restart reissues window IDs from low numbers, so the saved ones now
                // name unrelated windows rather than nothing. Park every placement and let
                // reconciliation recover it by (bundleID, title) against the live snapshot.
                let parked = manager.makeAllWindowsDormant()
                diag.report("state_boot_session_changed", details: [
                    "savedBootSession": saved ?? "none",
                    "currentBootSession": bootSessionID,
                    "madeDormant": "\(parked)",
                ])
                return manager
            }
            return manager
        }

        // Legacy format had SpaceApp with bundleID — window IDs are ephemeral,
        // so we preserve space names/structure but clear window lists.
        // Windows will be rediscovered on launch via WindowDiscoveryService.
        return SpaceManager()
    }

    // MARK: - Settings

    public func saveSettings(_ settings: AppSettings) throws {
        let performanceID = PerformanceRecorder.shared.begin(.statePersistence)
        defer { PerformanceRecorder.shared.end(performanceID) }
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL, options: .atomic)
    }

    public func loadSettings() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else {
            return AppSettings()
        }
        let data = try Data(contentsOf: settingsFileURL)
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }
}
