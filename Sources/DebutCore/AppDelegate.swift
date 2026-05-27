import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var stageController: StageController?
    private var overlayWindow: OverlayWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var stateStore: StateStore?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        stateStore = StateStore()
        let stageManager = (try? stateStore?.load()) ?? StageManager()
        let settings = (try? stateStore?.loadSettings()) ?? AppSettings()

        let windowService = AccessibilityWindowService()
        let keyboardService = EventTapKeyboardService()

        stageController = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            stageManager: stageManager
        )

        overlayWindow = OverlayWindow()

        setupMenuBar()

        if !windowService.isAccessibilityEnabled() {
            showAccessibilityAlert()
        }

        if isFirstLaunch() {
            showSettings(settings: settings)
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

    private func isFirstLaunch() -> Bool {
        let key = "hasLaunchedBefore"
        if UserDefaults.standard.bool(forKey: key) { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Debut needs Accessibility access to manage windows and intercept keyboard shortcuts. Please grant access in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}
