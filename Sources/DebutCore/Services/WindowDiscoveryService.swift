import AppKit

public final class WindowDiscoveryService: @unchecked Sendable {
    private let windowService: any WindowService
    private var pollTimer: Timer?

    public init(windowService: any WindowService) {
        self.windowService = windowService
    }

    public func discoverAllWindows() -> [StageWindow] {
        let windows = windowService.listWindows()
        return windows.map { info in
            StageWindow(
                windowID: info.windowID,
                appBundleID: info.appBundleID,
                appName: info.appName,
                isShared: false
            )
        }
    }

    public func populateDefaultStage(_ stageManager: inout StageManager) {
        let windows = discoverAllWindows()
        let stageID = stageManager.stages[0].id

        for window in windows {
            stageManager.addWindow(window, toStageID: stageID)
        }

        DiagnosticReporter.shared.report("windows_discovered", details: [
            "count": "\(windows.count)",
            "apps": "\(Set(windows.map(\.appBundleID)).count)",
        ])
    }

    public func syncWindows(_ stageManager: inout StageManager) {
        let currentWindows = windowService.listWindows()
        let currentIDs = Set(currentWindows.map(\.windowID))

        let knownIDs = Set(stageManager.stages.flatMap { $0.windows.map(\.windowID) })

        // Add new windows to active stage
        let activeStageID = stageManager.activeStageID
        for info in currentWindows where !knownIDs.contains(info.windowID) {
            let window = StageWindow(
                windowID: info.windowID,
                appBundleID: info.appBundleID,
                appName: info.appName,
                isShared: false
            )
            stageManager.addWindow(window, toStageID: activeStageID)
        }

        // Remove windows that no longer exist
        for stage in stageManager.stages {
            for window in stage.windows where !currentIDs.contains(window.windowID) {
                stageManager.removeWindow(windowID: window.windowID, fromStageID: stage.id)
            }
        }
    }

    public func startPolling(interval: TimeInterval = 2.0, update: @escaping () -> Void) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            update()
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
