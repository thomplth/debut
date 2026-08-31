import Foundation

public final class StateStore: Sendable {
    private let directory: URL
    private var stateFileURL: URL { directory.appendingPathComponent("state.json") }
    private var settingsFileURL: URL { directory.appendingPathComponent("settings.json") }
    private var contradictionsFileURL: URL {
        directory.appendingPathComponent("ax-contradictions.json")
    }

    public init(directory: URL) {
        self.directory = directory
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
        let data = try encoder.encode(manager)
        try data.write(to: stateFileURL, options: .atomic)
    }

    public func load() throws -> SpaceManager {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            return SpaceManager()
        }
        let data = try Data(contentsOf: stateFileURL)

        // A window ID or PID saved here means nothing on its own — macOS reissues both from
        // low numbers on every relaunch, not only across a reboot. `RuntimeWindowReconciler`
        // validates each assignment against the live snapshot instead of trusting the file;
        // a legacy file's leftover `bootSessionID` key is simply ignored by the decoder.
        if let manager = try? JSONDecoder().decode(SpaceManager.self, from: data) {
            return manager
        }

        // Legacy format had SpaceApp with bundleID — window IDs are ephemeral,
        // so we preserve space names/structure but clear window lists.
        // Windows will be rediscovered on launch via WindowDiscoveryService.
        return SpaceManager()
    }

    // MARK: - Accessibility contradictions

    func saveContradictions(_ records: [AXContradictionRecord]) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: contradictionsFileURL, options: .atomic)
    }

    func loadContradictions() throws -> [AXContradictionRecord] {
        guard FileManager.default.fileExists(atPath: contradictionsFileURL.path) else { return [] }
        let data = try Data(contentsOf: contradictionsFileURL)
        return (try? JSONDecoder().decode([AXContradictionRecord].self, from: data)) ?? []
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
