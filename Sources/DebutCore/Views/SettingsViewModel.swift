import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance = "Appearance"
    case excludedApps = "Excluded Apps"
    case app = "App"
    case privacy = "Privacy"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case troubleshooting = "Troubleshooting"
    case about = "About"
}

public struct SettingsViewModel: Sendable {
    public var settings: AppSettings
    public var stageManager: StageManager
    public let sections: [SettingsSection] = SettingsSection.allCases
    public var onSettingsChanged: (@Sendable (AppSettings) -> Void)?
    public var onResetWindowCache: (@Sendable () -> Void)?
    public var onExportDiagnosticData: (@Sendable () -> Void)?

    public init(settings: AppSettings = AppSettings(), stageManager: StageManager = StageManager()) {
        self.settings = settings
        self.stageManager = stageManager
    }

    public func resetWindowCache() {
        onResetWindowCache?()
    }

    public func exportDiagnosticData() {
        onExportDiagnosticData?()
    }

    public let telemetryExcludedData = "Never shared: window titles, app names or bundle IDs, PIDs, window IDs, paths, screenshots, raw diagnostics, free-form errors, or persistent identifiers."

    public func telemetryPayloadPreview() throws -> String {
        let snapshot = PerformanceRecorder.shared.snapshot()
        var counts: [PerformanceOperation: Int] = [:]
        var buckets: [PerformanceOperation: TelemetryLatencyBucket] = [:]
        for observation in snapshot.recent { counts[observation.operation, default: 0] += 1 }
        for (name, summary) in snapshot.summaries {
            if let operation = PerformanceOperation(rawValue: name) {
                buckets[operation] = TelemetryLatencyBucket(milliseconds: summary.p95Milliseconds)
            }
        }
        let windowCount = stageManager.stages.reduce(0) { $0 + $1.windows.count }
        let workload: TelemetryWorkload = windowCount >= 50 ? .stress : (windowCount >= 21 ? .busy : .typical)
        let payload = TelemetryPayload.sessionSummary(
            appVersion: DebutCore.version,
            operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            workload: workload,
            operationCounts: counts,
            latencyBuckets: buckets,
            anomalyCount: 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
