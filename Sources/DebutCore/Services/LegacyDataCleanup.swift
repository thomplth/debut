import Foundation

enum LegacyDataCleanup {
    /// Removes the unsent queue left by builds that offered remote performance sharing.
    static func removeObsoleteRemoteMetricsQueue(
        from directory: URL = DebutCore.applicationSupportDirectory,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: directory.appendingPathComponent("telemetry-queue.json"))
    }
}
