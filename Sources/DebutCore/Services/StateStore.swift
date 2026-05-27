import Foundation

public final class StateStore: Sendable {
    private let directory: URL
    private var stateFileURL: URL { directory.appendingPathComponent("state.json") }
    private var settingsFileURL: URL { directory.appendingPathComponent("settings.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Debut")
        self.init(directory: dir)
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Stage state

    public func save(_ manager: StageManager) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manager)
        try data.write(to: stateFileURL, options: .atomic)
    }

    public func load() throws -> StageManager {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            return StageManager()
        }
        let data = try Data(contentsOf: stateFileURL)
        return try JSONDecoder().decode(StageManager.self, from: data)
    }

    // MARK: - Settings

    public func saveSettings(_ settings: AppSettings) throws {
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
