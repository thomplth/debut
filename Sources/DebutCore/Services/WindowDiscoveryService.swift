import AppKit

public final class WindowDiscoveryService: NSObject, @unchecked Sendable {
    private let windowService: any WindowService
    public var onAppLaunched: ((StageApp) -> Void)?
    public var onAppTerminated: ((String) -> Void)?
    public var onAppActivated: ((String) -> Void)?

    public init(windowService: any WindowService) {
        self.windowService = windowService
        super.init()
    }

    public func discoverRunningApps() -> [StageApp] {
        windowService.listRunningApps().map { info in
            StageApp(bundleID: info.bundleID, name: info.name, pid: info.pid)
        }
    }

    public func populateDefaultStage(_ stageManager: inout StageManager) {
        let apps = discoverRunningApps()
        let stageID = stageManager.stages[0].id

        for app in apps {
            stageManager.addApp(app, toStageID: stageID)
        }

        DiagnosticReporter.shared.report("apps_discovered", details: [
            "count": "\(apps.count)",
        ])
    }

    public func startObserving() {
        let ws = NSWorkspace.shared
        let nc = ws.notificationCenter

        nc.addObserver(self, selector: #selector(appDidLaunch(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidTerminate(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidActivate(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    public func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              app.activationPolicy == .regular
        else { return }

        let stageApp = StageApp(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier)
        onAppLaunched?(stageApp)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier
        else { return }
        onAppTerminated?(bundleID)
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != "com.thomplth.Debut"
        else { return }
        onAppActivated?(bundleID)
    }
}
