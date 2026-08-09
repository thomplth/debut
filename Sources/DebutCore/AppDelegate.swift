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
    private var debouncedSaver: DebouncedSaver?
    private var runtimeWindowReconciler = RuntimeWindowReconciler()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        diag.report("app_launched")

        let store = StateStore()
        stateStore = store
        debouncedSaver = DebouncedSaver(store: store)
        pendingStageManager = (try? store.load()) ?? StageManager()
        currentSettings = (try? store.loadSettings()) ?? AppSettings()

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

        // Remove empty stages (unless all are empty)
        stageManager.removeEmptyStages()

        if stageManager.stages.allSatisfy({ $0.windows.isEmpty }) &&
            stageManager.dormantWindowAssignments.isEmpty {
            discovery.populateDefaultStage(&stageManager)
        }

        // Activate the stage containing the currently focused window, or fall back to first stage
        let startStageID: UUID
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != "com.thomplth.Debut",
           let focusedWID = discovery.focusedWindowID(for: frontApp.processIdentifier),
           let owningStage = stageManager.stageContainingWindow(windowID: focusedWID) {
            startStageID = owningStage
        } else {
            startStageID = stageManager.stages[0].id
        }
        stageManager.activateStage(id: startStageID)

        // Create desktop surface — sits between active and inactive stage windows
        let surface = DesktopSurfaceWindow()
        surface.orderFront(nil)
        self.desktopSurface = surface

        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            stageManager: stageManager,
            overlayPresentationDelay: currentSettings.overlayPresentationDelay
        )
        controller.delegate = self
        controller.desktopSurface = surface
        stageController = controller

        keyboardService.keyBindings = currentSettings.keyBindings
        keyboardService.quickSwitchExcludedBundleIDs = Set(
            currentSettings.quickSwitchExcludedBundleIDs
        )

        // Raise active stage windows above the desktop surface
        controller.switchToStage(id: stageManager.activeStageID)

        discovery.onWindowsDiscovered = { [weak self] windows in
            DispatchQueue.main.async {
                guard let self, let controller = self.stageController else { return }
                let result = self.runtimeWindowReconciler.reconcile(
                    RuntimeWindowSnapshot(
                        liveWindows: windows,
                        allWindowIDs: nil
                    ),
                    stageManager: &controller.stageManager
                )
                if result.didMutate {
                    self.diag.report("runtime_windows_reconciled", details: [
                        "added": "\(result.addedCount)",
                        "reassigned": "\(result.reassignedCount)",
                        "trigger": "app_launch",
                    ])
                    self.debouncedSaver?.scheduleSave(controller.stageManager)
                }
            }
        }
        discovery.onWindowClosed = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                for stage in self.stageController?.stageManager.stages ?? [] {
                    self.stageController?.stageManager.removeWindow(windowID: windowID, fromStageID: stage.id)
                }
                if let sm = self.stageController?.stageManager {
                    self.debouncedSaver?.scheduleSave(sm)
                }
            }
        }
        discovery.onWindowTitleChanged = { [weak self] windowID, newTitle in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stageController?.stageManager.updateWindowTitle(windowID: windowID, title: newTitle)
                if let sm = self.stageController?.stageManager {
                    self.debouncedSaver?.scheduleSave(sm)
                }
            }
        }
        discovery.onWindowActivated = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stageController?.recordWindowActivation(windowID: windowID)
            }
        }
        discovery.onFrontmostAppChanged = { [weak keyboardService] bundleID in
            keyboardService?.updateFrontmostApp(bundleIdentifier: bundleID)
        }
        discovery.onAppActivated = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, let controller = self.stageController else { return }
                let result = self.runtimeWindowReconciler.reconcile(
                    snapshot,
                    stageManager: &controller.stageManager
                )
                if result.didMutate {
                    self.diag.report("runtime_windows_reconciled", details: [
                        "added": "\(result.addedCount)",
                        "reassigned": "\(result.reassignedCount)",
                        "trigger": "app_activation",
                    ])
                    self.debouncedSaver?.scheduleSave(controller.stageManager)
                }
            }
        }
        discovery.onAppTerminated = { [weak self] ownerPID in
            DispatchQueue.main.async {
                guard let self, let controller = self.stageController else { return }
                let dormantCount = controller.stageManager.makeWindowsDormant(forOwnerPID: ownerPID)
                if dormantCount > 0 {
                    self.diag.report("terminated_app_windows_made_dormant", details: [
                        "count": "\(dormantCount)",
                        "ownerPID": "\(ownerPID)",
                    ])
                    let sm = controller.stageManager
                    self.debouncedSaver?.scheduleSave(sm)
                }
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
        let debouncedSaver = MainActor.assumeIsolated { self.debouncedSaver }
        guard let stageController, let debouncedSaver else { return }
        debouncedSaver.flushNow(stageController.stageManager)
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

    nonisolated public func stageControllerDidMutateState(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            self?.debouncedSaver?.scheduleSave(controller.stageManager)
        }
    }

    private func showStageManagerOverlay() {
        guard let stageController, let overlayWindow else { return }

        overlayWindow.onWindowSelected = { [weak self] stageIndex, windowIndex in
            self?.diag.report("overlay_window_selected_by_pointer", details: [
                "stageIndex": "\(stageIndex)",
                "windowIndex": "\(windowIndex)",
            ])
            self?.stageController?.commitOverlaySelection(
                stageIndex: stageIndex,
                windowIndex: windowIndex
            )
        }

        overlayWindow.onWindowMoved = { [weak self] windowID, fromIndex, toIndex in
            guard let self, let ctrl = self.stageController else { return }
            let stages = ctrl.stageManager.stages
            guard stages.indices.contains(fromIndex), stages.indices.contains(toIndex) else { return }
            ctrl.stageManager.moveWindow(
                windowID: windowID,
                fromStageID: stages[fromIndex].id,
                toStageID: stages[toIndex].id
            )
            self.debouncedSaver?.scheduleSave(ctrl.stageManager)
            self.diag.report("window_moved_by_drag", details: [
                "windowID": "\(windowID)",
                "fromStageIndex": "\(fromIndex)",
                "toStageIndex": "\(toIndex)",
            ])
            self.updateOverlay()
        }

        overlayWindow.onStageReordered = { [weak self] fromIndex, toIndex in
            guard let self, let ctrl = self.stageController else { return }
            let activeID = ctrl.stageManager.stages[safe: ctrl.selectedStageIndex]?.id
            ctrl.stageManager.moveStage(fromIndex: fromIndex, toIndex: toIndex)
            if let activeID, let newIndex = ctrl.stageManager.stages.firstIndex(where: { $0.id == activeID }) {
                ctrl.selectedStageIndex = newIndex
            }
            self.debouncedSaver?.scheduleSave(ctrl.stageManager)
            self.diag.report("stage_reordered_by_drag", details: [
                "fromStageIndex": "\(fromIndex)",
                "toStageIndex": "\(toIndex)",
            ])
            self.updateOverlay()
        }

        let vm = OverlayViewModel(
            stageManager: stageController.stageManager,
            activeStageIndex: stageController.selectedStageIndex,
            selectedWindowIndex: stageController.selectedWindowIndex,
            windowPreviews: stageController.windowPreviews,
            appearance: currentSettings
        )
        overlayWindow.update(viewModel: vm)
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
        overlayWindow.update(viewModel: vm)
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

        let currentStageManager = stageController?.stageManager ?? StageManager()
        var vm = SettingsViewModel(
            settings: settings,
            stageManager: currentStageManager
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
                if let stageManager = self.stageController?.stageManager {
                    self.debouncedSaver?.scheduleSave(stageManager)
                }
                self.keyboardService?.keyBindings = newSettings.keyBindings
                self.stageController?.overlayPresentationDelay = newSettings.overlayPresentationDelay
                self.keyboardService?.quickSwitchExcludedBundleIDs = Set(
                    newSettings.quickSwitchExcludedBundleIDs
                )
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
        window.isReleasedWhenClosed = false
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
