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
    private let diag = DiagnosticReporter.shared

    private var windowService: AccessibilityWindowService?
    private var keyboardService: EventTapKeyboardService?
    private var pendingStageManager: StageManager?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        diag.report("app_launched")

        stateStore = StateStore()
        pendingStageManager = (try? stateStore?.load()) ?? StageManager()
        let settings = (try? stateStore?.loadSettings()) ?? AppSettings()

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
            showSettings(settings: settings)
        }

        diag.report("app_ready")
    }

    private func setupController() {
        guard let windowService, let keyboardService else { return }
        guard stageController == nil else { return }

        let stageManager = pendingStageManager ?? StageManager()
        pendingStageManager = nil

        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            stageManager: stageManager
        )
        controller.delegate = self
        stageController = controller

        diag.report("controller_setup", details: [
            "eventTapStarted": "\(controller.keyboardServiceStarted)",
            "eventTapRunning": "\(keyboardService.isRunning)",
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

    private func showStageManagerOverlay() {
        guard let stageController, let overlayWindow else { return }
        let vm = OverlayViewModel(
            stageManager: stageController.stageManager,
            activeStageIndex: stageController.selectedStageIndex,
            selectedAppIndex: stageController.selectedAppIndex
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
            selectedAppIndex: stageController.selectedAppIndex
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

        let vm = SettingsViewModel(
            settings: settings,
            stageManager: stageController?.stageManager ?? StageManager()
        )
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
