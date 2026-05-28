import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, StageControllerDelegate {
    private var stageController: StageController?
    private var overlayWindow: OverlayWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var stateStore: StateStore?
    private var accessibilityTimer: Timer?
    private var windowDiscovery: WindowDiscoveryService?
    private let diag = DiagnosticReporter.shared

    private var windowService: AccessibilityWindowService?
    private var keyboardService: EventTapKeyboardService?
    private var desktopSurface: DesktopSurfaceWindow?
    private var currentSettings: AppSettings = AppSettings()
    private var pendingStageManager: StageManager?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        diag.report("app_launched")

        stateStore = StateStore()
        pendingStageManager = (try? stateStore?.load()) ?? StageManager()
        currentSettings = (try? stateStore?.loadSettings()) ?? AppSettings()

        windowService = AccessibilityWindowService()
        keyboardService = EventTapKeyboardService()

        overlayWindow = OverlayWindow()
        setupMenuBar()

        if AXIsProcessTrusted() {
            diag.report("accessibility_already_granted")
            setupController()
        } else {
            diag.report("accessibility_not_granted_prompting")
            promptForAccessibility()
            startAccessibilityPolling()
        }

        if isFirstLaunch() {
            showSettings(settings: currentSettings)
        }

        diag.report("app_ready")
    }

    private func setupController() {
        guard let windowService, let keyboardService else { return }
        guard stageController == nil else { return }

        var stageManager = pendingStageManager ?? StageManager()
        pendingStageManager = nil

        let discovery = WindowDiscoveryService(windowService: windowService)
        self.windowDiscovery = discovery

        // Apply exclusion list
        discovery.excludedBundleIDs = Set(currentSettings.excludedBundleIDs)

        // Remove stale window IDs, remap live window IDs from snapshot
        discovery.reconcileWindows(&stageManager)

        // Remove excluded apps' windows from all stages
        for bundleID in currentSettings.excludedBundleIDs {
            stageManager.removeAllWindows(forBundleID: bundleID)
        }

        if stageManager.stages[0].windows.isEmpty {
            discovery.populateDefaultStage(&stageManager)
        }

        // Always start on the first stage
        stageManager.activateStage(id: stageManager.stages[0].id)

        // Create desktop surface — sits between active and inactive stage windows
        let surface = DesktopSurfaceWindow()
        surface.orderFront(nil)
        self.desktopSurface = surface

        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            stageManager: stageManager
        )
        controller.delegate = self
        controller.desktopSurface = surface
        stageController = controller

        // Raise first stage windows above the desktop surface
        controller.switchToStage(id: stageManager.stages[0].id)

        discovery.onWindowDiscovered = { [weak self] window in
            DispatchQueue.main.async {
                guard let self else { return }
                let activeID = self.stageController?.stageManager.activeStageID ?? self.stageController!.stageManager.stages[0].id
                self.stageController?.stageManager.addWindow(window, toStageID: activeID)
            }
        }
        discovery.onWindowClosed = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                for stage in self.stageController?.stageManager.stages ?? [] {
                    self.stageController?.stageManager.removeWindow(windowID: windowID, fromStageID: stage.id)
                }
            }
        }
        discovery.onWindowActivated = { [weak self] windowID in
            DispatchQueue.main.async {
                self?.stageController?.recordWindowActivation(windowID: windowID)
            }
        }
        discovery.onAppTerminated = { [weak self] bundleID in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stageController?.stageManager.removeAllWindows(forBundleID: bundleID)
            }
        }
        discovery.startObserving()

        diag.report("controller_setup", details: [
            "eventTapStarted": "\(controller.keyboardServiceStarted)",
            "eventTapRunning": "\(keyboardService.isRunning)",
            "windowsInDefaultStage": "\(stageManager.stages[0].windows.count)",
        ])
    }

    private func startAccessibilityPolling() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                Task { @MainActor in
                    self?.diag.report("accessibility_granted_via_poll")
                    self?.setupController()
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated public func applicationWillTerminate(_ notification: Notification) {
        let stageController = MainActor.assumeIsolated { self.stageController }
        let stateStore = MainActor.assumeIsolated { self.stateStore }
        guard let stageController, let stateStore else { return }
        try? stateStore.save(stageController.stageManager)
    }

    // MARK: - StageControllerDelegate

    nonisolated public func stageControllerDidOpenOverlay(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            self?.showStageManagerOverlay()
        }
    }

    nonisolated public func stageControllerDidCloseOverlay(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            self?.hideStageManagerOverlay()
        }
    }

    nonisolated public func stageControllerDidUpdateSelection(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            self?.updateOverlay()
        }
    }

    nonisolated public func stageControllerDidSwitchStage(_ controller: StageController) {}

    nonisolated public func stageControllerDidEnterRenameMode(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            self?.updateOverlay()
        }
    }

    nonisolated public func stageControllerDidExitRenameMode(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            self?.updateOverlay()
        }
    }

    private func showStageManagerOverlay() {
        guard let stageController, let overlayWindow else { return }
        let vm = OverlayViewModel(
            stageManager: stageController.stageManager,
            activeStageIndex: stageController.selectedStageIndex,
            selectedWindowIndex: stageController.selectedWindowIndex,
            windowPreviews: stageController.windowPreviews,
            appearance: currentSettings
        )
        overlayWindow.update(viewModel: vm, isRenaming: stageController.isRenaming)
        overlayWindow.showOverlay()
        diag.report("overlay_shown")
    }

    private func hideStageManagerOverlay() {
        overlayWindow?.hideOverlay()
        diag.report("overlay_hidden")
    }

    private func updateOverlay() {
        guard let stageController, let overlayWindow else { return }
        let vm = OverlayViewModel(
            stageManager: stageController.stageManager,
            activeStageIndex: stageController.selectedStageIndex,
            selectedWindowIndex: stageController.selectedWindowIndex,
            windowPreviews: stageController.windowPreviews,
            appearance: currentSettings
        )
        overlayWindow.update(viewModel: vm, isRenaming: stageController.isRenaming)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "theatermask.and.paintbrush", accessibilityDescription: "Debut")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Debut", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        let settings = (try? stateStore?.loadSettings()) ?? AppSettings()
        showSettings(settings: settings)
    }

    private func showSettings(settings: AppSettings) {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        var vm = SettingsViewModel(
            settings: settings,
            stageManager: stageController?.stageManager ?? StageManager()
        )
        vm.onSettingsChanged = { [weak self] newSettings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentSettings = newSettings
                try? self.stateStore?.saveSettings(newSettings)
                self.windowDiscovery?.excludedBundleIDs = Set(newSettings.excludedBundleIDs)
                for bundleID in newSettings.excludedBundleIDs {
                    self.stageController?.stageManager.removeAllWindows(forBundleID: bundleID)
                }
            }
        }
        let view = SettingsView(viewModel: vm)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Debut Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.settingsWindow = window
    }

    // MARK: - Helpers

    private nonisolated func promptForAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func isFirstLaunch() -> Bool {
        let key = "hasLaunchedBefore"
        if UserDefaults.standard.bool(forKey: key) { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }
}
