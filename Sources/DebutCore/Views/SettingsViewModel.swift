import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case features = "Features"
    case excludedApps = "Excluded Apps"
    case app = "App"
    case privacy = "Privacy"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case advanced = "Advanced"
    case troubleshooting = "Troubleshooting"
    case about = "About"
}

public struct TelemetryPayloadPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let json: String

    public init(id: UUID = UUID(), json: String) {
        self.id = id
        self.json = json
    }
}

public struct SettingsViewModel: Sendable {
    public var settings: AppSettings
    public var spaceManager: SpaceManager
    public let sections: [SettingsSection] = SettingsSection.allCases
    public var onSettingsChanged: (@Sendable (AppSettings) -> Void)?
    public var onResetWindowCache: (@Sendable () -> Void)?
    public var onExportDiagnosticData: (@Sendable () -> Void)?
    public var onCheckForUpdates: (@Sendable () -> Void)?

    public init(settings: AppSettings = AppSettings(), spaceManager: SpaceManager = SpaceManager()) {
        self.settings = settings
        self.spaceManager = spaceManager
    }

    public func resetWindowCache() {
        onResetWindowCache?()
    }

    public func exportDiagnosticData() {
        onExportDiagnosticData?()
    }

    public func checkForUpdates() {
        onCheckForUpdates?()
    }

    public mutating func restoreDefaultShortcuts() {
        settings.keyBindings.restoreDefaults()
        settings.quickSwitchModifiers = .control
        settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(
            control: true,
            option: true
        )
    }

    public let telemetryExcludedData = "Never shared: window titles, app names or bundle IDs, PIDs, window IDs, paths, screenshots, raw diagnostics, free-form errors, or persistent identifiers."

    public func telemetryPayloadPreview() throws -> String {
        let snapshot = PerformanceRecorder.shared.snapshot()
        let windowCount = spaceManager.liveWindowCount
        let workload: TelemetryWorkload = windowCount >= 50 ? .stress : (windowCount >= 21 ? .busy : .typical)
        let payloads = TelemetryExporter.hourlyOperations.sorted { $0.rawValue < $1.rawValue }
            .compactMap { operation -> TelemetryPayload? in
                guard let summary = snapshot.summaries[operation.rawValue] else { return nil }
                return .hourlyP95(
                    operation: operation,
                    milliseconds: summary.p95Milliseconds,
                    sampleCount: summary.count,
                    appVersion: DebutCore.version,
                    operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    workload: workload
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(payloads), as: UTF8.self)
    }

    public func telemetryPayloadPresentation() throws -> TelemetryPayloadPresentation {
        TelemetryPayloadPresentation(json: try telemetryPayloadPreview())
    }
}
