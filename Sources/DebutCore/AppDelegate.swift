import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, StageControllerDelegate {
    private var stageController: StageController?
    private var overlayWindow: OverlayWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: OnboardingViewModel?
    private var coachmarkPopover: NSPopover?
    private var statusItem: NSStatusItem?
    private var stateStore: StateStore?
    private var observingAccessibilityChanges = false
    private var windowDiscovery: WindowDiscoveryService?
    private let diag = DiagnosticReporter.shared
    private let onboardingPermissionClient = SystemOnboardingPermissionClient()

    private var windowService: AccessibilityWindowService?
    private var keyboardService: EventTapKeyboardService?
    private var desktopSurfaces: DesktopSurfaceCoordinator?
    private var currentSettings: AppSettings = AppSettings()
    private var pendingStageManager: StageManager?
    private var debouncedSaver: DebouncedSaver?
    private var runtimeWindowReconciler = RuntimeWindowReconciler()
    private var telemetryExporter: TelemetryExporter?
    private var hiddenIdlePerformanceID: UUID?

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
        setupTelemetry()

        windowService = AccessibilityWindowService()
        keyboardService = EventTapKeyboardService()

        overlayWindow = OverlayWindow()
        setupMenuBar()

        let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--show-onboarding")
        let shouldShowOnboarding = OnboardingLaunchPolicy.shouldPresent(force: forceOnboarding)

        if onboardingPermissionClient.currentState().accessibilityGranted {
            diag.report("accessibility_already_granted")
            setupController()
        } else {
            startAccessibilityObservation()
            if shouldShowOnboarding {
                diag.report("accessibility_not_granted_waiting_for_onboarding")
            } else {
                diag.report("accessibility_not_granted_prompting")
                onboardingPermissionClient.requestAccessibility()
            }
        }

        if shouldShowOnboarding {
            showOnboarding()
        }

        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            showSettings(settings: currentSettings)
        }

        diag.report("app_ready")
        hiddenIdlePerformanceID = PerformanceRecorder.shared.begin(.hiddenIdle)
    }

    private func setupController() {
        guard let windowService, let keyboardService else { return }
        guard stageController == nil else { return }

        var stageManager = pendingStageManager ?? StageManager()
        pendingStageManager = nil

        let discovery = WindowDiscoveryService(windowService: windowService)
        self.windowDiscovery = discovery
        windowService.windowElementResolver = { [weak discovery] windowID in
            discovery?.trackedWindowElement(windowID: windowID)
        }

        // Apply exclusion list
        discovery.excludedBundleIDs = Set(currentSettings.excludedBundleIDs)

        // Remove stale window IDs, remap live window IDs from snapshot
        let reconcileID = PerformanceRecorder.shared.begin(
            .windowReconciliation,
            workload: .init(
                stages: stageManager.stages.count,
                windows: stageManager.stages.reduce(0) { $0 + $1.windows.count },
                dormantWindows: stageManager.dormantWindowAssignments.count
            )
        )
        discovery.reconcileWindows(&stageManager)
        _ = PerformanceRecorder.shared.end(reconcileID)

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

        // Create desktop surfaces — one per display, sitting between active and inactive
        // stage windows
        let surfaces = DesktopSurfaceCoordinator(onFileDragEntered: { [weak self] in
            guard let self else { return }
            self.desktopSurfaces?.orderOut()
            NSWorkspace.shared.hideOtherApplications()
            self.diag.report("real_desktop_presented_for_file_drag")
        })
        surfaces.orderToFront()
        self.desktopSurfaces = surfaces

        let controller = StageController(
            windowService: windowService,
            keyboardService: keyboardService,
            stageManager: stageManager,
            overlayPresentationDelay: currentSettings.overlayPresentationDelay,
            quickSwitchBehavior: currentSettings.quickSwitchBehavior
        )
        controller.delegate = self
        controller.desktopSurfaces = surfaces
        controller.onCommandUsed = { [weak self] action in
            DispatchQueue.main.async {
                self?.recordCommandUsage(action)
            }
        }
        controller.onDesktopReveal = { [weak self] in
            DispatchQueue.main.async {
                self?.desktopSurfaces?.orderOut()
                NSWorkspace.shared.hideOtherApplications()
                self?.diag.report("real_desktop_presented")
            }
        }
        stageController = controller

        keyboardService.keyBindings = currentSettings.keyBindings
        keyboardService.quickSwitchExcludedBundleIDs = Set(
            currentSettings.quickSwitchExcludedBundleIDs
        )
        keyboardService.quickSwitchModifiers = currentSettings.quickSwitchModifiers

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
                    self.reportAssignmentEvents(result.events, trigger: "app_launch")
                    self.debouncedSaver?.scheduleSave(controller.stageManager)
                }
            }
        }
        discovery.onWindowClosed = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                let window = self.stageController?.stageManager.stages
                    .flatMap(\.windows)
                    .first { $0.windowID == windowID }
                for stage in self.stageController?.stageManager.stages ?? [] {
                    self.stageController?.stageManager.removeWindow(windowID: windowID, fromStageID: stage.id)
                }
                self.diag.report("window_retired", details: [
                    "windowID": "\(windowID)",
                    "bundleID": window?.ownerBundleID ?? "unknown",
                    "windowTitle": window?.windowTitle ?? "unknown",
                    "reason": "destroyed",
                ])
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
        discovery.onFrontmostAppChanged = { [weak self, weak keyboardService] bundleID in
            keyboardService?.updateFrontmostApp(bundleIdentifier: bundleID)
            guard let self else { return }
            self.stageController?.updateFrontmostApp(
                isExcluded: bundleID.map { self.currentSettings.excludedBundleIDs.contains($0) }
                    ?? false
            )
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
                    self.reportAssignmentEvents(result.events, trigger: "app_activation")
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

    private func startAccessibilityObservation() {
        guard !observingAccessibilityChanges else { return }
        observingAccessibilityChanges = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func stopAccessibilityObservation() {
        guard observingAccessibilityChanges else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        observingAccessibilityChanges = false
    }

    @objc private func workspaceApplicationActivated(_ notification: Notification) {
        onboardingViewModel?.refreshPermissions()
        handlePermissionStateChange(
            onboardingPermissionClient.currentState(),
            source: "app_activation"
        )
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        onboardingViewModel?.refreshPermissions()
        handlePermissionStateChange(
            onboardingPermissionClient.currentState(),
            source: "debut_activation"
        )
    }

    private func handlePermissionStateChange(
        _ state: OnboardingPermissionState,
        source: String
    ) {
        guard state.accessibilityGranted else { return }
        if stageController == nil {
            diag.report("accessibility_granted", details: ["source": source])
            setupController()
        }
        stopAccessibilityObservation()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated public func applicationWillTerminate(_ notification: Notification) {
        OverlayPresentationRecorder.shared.finalizeAll(outcome: .appTerminated)
        let stageController = MainActor.assumeIsolated { self.stageController }
        let debouncedSaver = MainActor.assumeIsolated { self.debouncedSaver }
        if let stageController, let debouncedSaver {
            debouncedSaver.flushNow(stageController.stageManager)
        }
        let exporter = MainActor.assumeIsolated { self.telemetryExporter }
        let payload = MainActor.assumeIsolated { self.currentTelemetrySummary() }
        if let exporter {
            let queued = DispatchSemaphore(value: 0)
            Task {
                try? await exporter.enqueue(payload)
                queued.signal()
            }
            _ = queued.wait(timeout: .now() + 0.5)
        }
    }

    // MARK: - StageControllerDelegate

    nonisolated public func stageControllerDidOpenOverlay(_ controller: StageController) {
        stageControllerDidOpenOverlay(controller, overlayPresentation: nil)
    }

    nonisolated public func stageControllerDidOpenOverlay(
        _ controller: StageController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.showStageManagerOverlay(overlayPresentation: overlayPresentation)
        }
    }

    nonisolated public func stageControllerDidCloseOverlay(_ controller: StageController) {
        stageControllerDidCloseOverlay(controller, overlayPresentation: nil)
    }

    nonisolated public func stageControllerDidCloseOverlay(
        _ controller: StageController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.hideStageManagerOverlay(overlayPresentation: overlayPresentation)
        }
    }

    nonisolated public func stageControllerDidUpdateSelection(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            self?.updateOverlay()
        }
    }

    nonisolated public func stageControllerDidSwitchStage(_ controller: StageController) {}

    private func reportAssignmentEvents(_ events: [WindowAssignmentEvent], trigger: String) {
        for event in events {
            var details = event.diagnosticDetails
            details["trigger"] = trigger
            diag.report("window_\(event.kind.rawValue)", details: details)
        }
    }

    nonisolated public func stageControllerDidMutateState(_ controller: StageController) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debouncedSaver?.scheduleSave(controller.stageManager)
            self.diag.report("stage_state_mutated")
        }
    }

    private func showStageManagerOverlay(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        guard let stageController, let overlayWindow else { return }
        if let hiddenIdlePerformanceID {
            _ = PerformanceRecorder.shared.end(hiddenIdlePerformanceID)
            self.hiddenIdlePerformanceID = nil
        }
        let workload = PerformanceWorkload(
            stages: stageController.stageManager.stages.count,
            windows: stageController.stageManager.stages.reduce(0) { $0 + $1.windows.count }
        )
        if let overlayPresentation {
            stageController.markOverlayPresentation(.preparationBegan, context: overlayPresentation)
        }
        let preparationID = PerformanceRecorder.shared.begin(
            .overlayPreparation,
            workload: workload,
            traceID: overlayPresentation?.traceID
        )

        overlayWindow.onWindowSelected = { [weak self] stageIndex, windowIndex in
            self?.diag.report("overlay_window_selected_by_pointer", level: .transient, details: [
                "stageIndex": "\(stageIndex)",
                "windowIndex": "\(windowIndex)",
            ])
            self?.stageController?.commitOverlaySelection(
                stageIndex: stageIndex,
                windowIndex: windowIndex
            )
        }

        overlayWindow.onWindowMoved = {
            [weak self] windowID, fromIndex, fromWindowIndex, toIndex, toWindowIndex in
            guard let self, let ctrl = self.stageController else { return }
            guard ctrl.moveWindowByDrag(
                windowID: windowID,
                fromStageIndex: fromIndex,
                toStageIndex: toIndex,
                toWindowIndex: toWindowIndex
            ) else { return }
            self.diag.report("window_moved_by_drag", details: [
                "windowID": "\(windowID)",
                "fromStageIndex": "\(fromIndex)",
                "fromWindowIndex": "\(fromWindowIndex)",
                "toStageIndex": "\(toIndex)",
                "toWindowIndex": "\(toWindowIndex)",
            ])
            // Let SwiftUI finish the drag transaction before replacing its root view.
            DispatchQueue.main.async { [weak self] in
                self?.updateOverlay()
            }
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

        overlayWindow.onStageHandleVisibilityChanged = { [weak self] stageIndex, isRevealed in
            self?.diag.report("stage_drag_handle_visibility_changed", level: .transient, details: [
                "stageIndex": "\(stageIndex)",
                "isRevealed": "\(isRevealed)",
            ])
        }

        overlayWindow.onPointerSelectionChanged = { [weak self] stageIndex, windowIndex in
            self?.diag.report("overlay_pointer_selection_changed", level: .transient, details: [
                "stageIndex": stageIndex.map(String.init) ?? "none",
                "windowIndex": windowIndex.map(String.init) ?? "none",
            ])
        }

        overlayWindow.onDesktopSelected = { [weak self] in
            self?.stageController?.revealDesktop()
        }

        let vm = OverlayViewModel(
            stageManager: stageController.stageManager,
            activeStageIndex: stageController.selectedStageIndex,
            selectedWindowIndex: stageController.selectedWindowIndex,
            windowPreviews: stageController.windowPreviews,
            appearance: currentSettings
        )
        reportCommandHintLayout(viewModel: vm)
        let createdHostingView = overlayWindow.update(viewModel: vm)
        if let overlayPresentation {
            stageController.updateOverlayHostingView(
                createdHostingView ? .created : .reused,
                context: overlayPresentation
            )
        }
        overlayWindow.showOverlay { [weak self, weak stageController] in
            guard let self, let stageController, let overlayPresentation else { return }
            stageController.completeOverlayPresentation(
                overlayPresentation,
                outcome: .presented
            )
            self.diag.report("overlay_presentation_completed", level: .transient, details: [
                "outcome": OverlayPresentationOutcome.presented.rawValue,
            ])
        }
        if let overlayPresentation {
            stageController.markOverlayPresentation(.windowOrdered, context: overlayPresentation)
        }
        _ = PerformanceRecorder.shared.end(preparationID)
        if let overlayPresentation {
            stageController.markOverlayPresentation(.preparationCompleted, context: overlayPresentation)
        }
        let renderSubmissionID = PerformanceRecorder.shared.begin(
            .overlayRenderSubmission,
            workload: workload,
            traceID: overlayPresentation?.traceID
        )
        DispatchQueue.main.async { [weak overlayWindow, weak stageController] in
            overlayWindow?.contentView?.displayIfNeeded()
            CATransaction.flush()
            if let overlayPresentation {
                stageController?.markOverlayPresentation(
                    .renderSubmitted,
                    context: overlayPresentation
                )
            }
            _ = PerformanceRecorder.shared.end(renderSubmissionID)
        }
        diag.report("overlay_shown")
    }

    private func reportCommandHintLayout(viewModel: OverlayViewModel) {
        let leadingHintCount = viewModel.plates.indices.compactMap { index in
            CommandHintCatalog.stageNumberHint(stageIndex: index, settings: currentSettings)
        }.count
        guard viewModel.plates.indices.contains(viewModel.activeStageIndex) else { return }
        let activePlate = viewModel.plates[viewModel.activeStageIndex]
        let footerHints = CommandHintCatalog.plateFooterHints(
            stageIndex: viewModel.activeStageIndex,
            isActive: true,
            hasSelectedWindow: activePlate.windows.indices.contains(viewModel.selectedWindowIndex),
            settings: currentSettings
        )
        let nextWindowIndex = activePlate.windows.indices.first { index in
            !CommandHintCatalog.windowHints(
                windowIndex: index,
                selectedWindowIndex: viewModel.selectedWindowIndex,
                windowCount: activePlate.windows.count,
                settings: currentSettings
            ).isEmpty
        }
        diag.report("command_hints_laid_out", details: [
            "footerHintCount": "\(footerHints.count)",
            "footerIconCount": "\(footerHints.compactMap(\.iconSystemName).count)",
            "nextWindowIndex": nextWindowIndex.map(String.init) ?? "none",
            "stageLeadingHintCount": "\(leadingHintCount)",
        ])
    }

    private func hideStageManagerOverlay(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        if let overlayPresentation {
            stageController?.completeOverlayPresentation(
                overlayPresentation,
                outcome: .hiddenBeforeReveal
            )
        }
        overlayWindow?.hideOverlay()
        diag.report("overlay_hidden")
        if hiddenIdlePerformanceID == nil {
            hiddenIdlePerformanceID = PerformanceRecorder.shared.begin(.hiddenIdle)
        }
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

    private func recordCommandUsage(_ action: KeyAction) {
        let didChange = currentSettings.recordCommandUsage(action)
        diag.report("command_hint_usage_observed", details: [
            "action": action.rawValue,
            "count": "\(currentSettings.commandUsageCounts[action] ?? 0)",
            "didChange": "\(didChange)",
        ])
        guard didChange else { return }
        try? stateStore?.saveSettings(currentSettings)
        if stageController?.isStageManagerVisible == true {
            updateOverlay()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "theatermask.and.paintbrush", accessibilityDescription: "Debut")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Tutorial...", action: #selector(openTutorial), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Debut", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        let settings = (try? stateStore?.loadSettings()) ?? AppSettings()
        showSettings(settings: settings)
    }

    @objc private func openTutorial() {
        showOnboarding()
    }

    private func showOnboarding() {
        if let onboardingWindow, onboardingWindow.isVisible {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = OnboardingViewModel(
            permissionClient: onboardingPermissionClient,
            shareAnonymousTelemetry: currentSettings.shareAnonymousTelemetry,
            onTelemetryChanged: { [weak self] enabled in
                guard let self else { return }
                self.currentSettings.shareAnonymousTelemetry = enabled
                try? self.stateStore?.saveSettings(self.currentSettings)
                if let exporter = self.telemetryExporter {
                    Task { await exporter.setEnabled(enabled) }
                }
            },
            onPermissionStateChanged: { [weak self] state in
                self?.handlePermissionStateChange(state, source: "onboarding")
            },
            onCompleted: { [weak self] in
                self?.completeOnboarding()
            }
        )
        let view = OnboardingView(viewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Debut"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        onboardingViewModel = viewModel
        onboardingWindow = window
        diag.report("onboarding_shown", details: [
            "forced": "\(ProcessInfo.processInfo.arguments.contains("--show-onboarding"))",
        ])
    }

    private func completeOnboarding() {
        OnboardingLaunchPolicy.markCompleted()
        onboardingWindow?.close()
        onboardingWindow = nil
        onboardingViewModel = nil
        diag.report("onboarding_completed")
        showMenuBarCoachmark()
    }

    private func showMenuBarCoachmark() {
        guard let button = statusItem?.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 150)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarCoachmarkView { [weak self] in
                self?.coachmarkPopover?.close()
                self?.coachmarkPopover = nil
            }
        )
        coachmarkPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        diag.report("onboarding_coachmark_shown")
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
                let telemetryChanged = self.currentSettings.shareAnonymousTelemetry != newSettings.shareAnonymousTelemetry
                self.currentSettings = newSettings
                try? self.stateStore?.saveSettings(newSettings)
                self.windowDiscovery?.excludedBundleIDs = Set(newSettings.excludedBundleIDs)
                self.stageController?.updateFrontmostApp(
                    isExcluded: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        .map(newSettings.excludedBundleIDs.contains) ?? false
                )
                for bundleID in newSettings.excludedBundleIDs {
                    self.stageController?.stageManager.removeAllWindows(forBundleID: bundleID)
                }
                if let stageManager = self.stageController?.stageManager {
                    self.debouncedSaver?.scheduleSave(stageManager)
                }
                self.keyboardService?.keyBindings = newSettings.keyBindings
                self.stageController?.overlayPresentationDelay = newSettings.overlayPresentationDelay
                self.stageController?.quickSwitchBehavior = newSettings.quickSwitchBehavior
                self.keyboardService?.quickSwitchExcludedBundleIDs = Set(
                    newSettings.quickSwitchExcludedBundleIDs
                )
                self.keyboardService?.quickSwitchModifiers = newSettings.quickSwitchModifiers
                if telemetryChanged, let exporter = self.telemetryExporter {
                    Task {
                        await exporter.setEnabled(newSettings.shareAnonymousTelemetry)
                        if newSettings.shareAnonymousTelemetry { try? await exporter.flush() }
                    }
                }
            }
        }
        vm.onResetWindowCache = { [weak self] in
            DispatchQueue.main.async {
                self?.resetWindowCache()
            }
        }
        vm.onExportDiagnosticData = { [weak self] in
            DispatchQueue.main.async {
                self?.exportDiagnosticData()
            }
        }
        let view = SettingsView(
            viewModel: vm,
            shortcutRecordingService: keyboardService
        )
        let window = SettingsWindow(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        diag.report("settings_shown", details: [
            "fullSizeContentView": "\(window.styleMask.contains(.fullSizeContentView))",
            "titleHidden": "\(window.titleVisibility == .hidden)",
            "titlebarTransparent": "\(window.titlebarAppearsTransparent)",
            "titlebarSeparatorHidden": "\(window.titlebarSeparatorStyle == .none)",
        ])

        self.settingsWindow = window
    }

    private func resetWindowCache() {
        let previousManager = stageController?.stageManager
            ?? pendingStageManager
            ?? (try? stateStore?.load())
            ?? StageManager()
        let previousLiveCount = previousManager.stages.reduce(0) { $0 + $1.windows.count }
        let previousDormantCount = previousManager.dormantWindowAssignments.count

        diag.report("window_cache_reset_started", details: [
            "liveAssignments": "\(previousLiveCount)",
            "dormantAssignments": "\(previousDormantCount)",
            "stageCount": "\(previousManager.stages.count)",
        ])

        if let controller = stageController, let discovery = windowDiscovery {
            controller.rebuildWindowCache(using: discovery)

            // Rebuild the z-order as well as the model so windows that were on
            // an inactive stage become visible immediately after the reset.
            desktopSurfaces?.orderToFront()
            for window in controller.stageManager.activeStage.windows {
                _ = controller.windowService.raiseWindow(windowID: window.windowID)
            }
            if let firstWindow = controller.stageManager.activeStage.windows.first {
                _ = controller.windowService.activateApp(bundleID: firstWindow.ownerBundleID)
            }

            debouncedSaver?.flushNow(controller.stageManager)
            diag.report("window_cache_reset_completed", details: [
                "discoveredAssignments": "\(controller.stageManager.activeStage.windows.count)",
            ])
        } else {
            var resetManager = previousManager
            resetManager.resetWindowCache()
            pendingStageManager = resetManager
            debouncedSaver?.flushNow(resetManager)
            diag.report("window_cache_reset_completed", details: [
                "discoveredAssignments": "0",
                "controllerAvailable": "false",
            ])
        }
    }

    private func exportDiagnosticData() {
        let panel = NSSavePanel()
        panel.title = "Export Debut Diagnostic Data"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = diagnosticExportFilename()

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.writeDiagnosticExport(to: destination)
        }
        if let settingsWindow {
            panel.beginSheetModal(for: settingsWindow, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func writeDiagnosticExport(to destination: URL) {
        let manager = stageController?.stageManager
            ?? pendingStageManager
            ?? (try? stateStore?.load())
            ?? StageManager()
        let liveWindows = windowService?.listWindows() ?? []
        let runningApps = windowService?.listRunningApps() ?? []
        let snapshot = DiagnosticExportSnapshot(
            stageManager: manager,
            settings: currentSettings,
            liveWindows: liveWindows,
            runningApps: runningApps,
            allWindowIDs: windowService?.listAllWindowIDs(),
            untrackableWindowIDs: windowService?.listUntrackableWindowIDs() ?? [],
            tracking: windowDiscovery?.diagnosticTrackingSnapshot ?? .empty,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            accessibilityEnabled: windowService?.isAccessibilityEnabled() ?? false,
            screens: NSScreen.screens.map {
                DiagnosticScreenSnapshot(
                    frame: $0.frame,
                    visibleFrame: $0.visibleFrame,
                    backingScaleFactor: $0.backingScaleFactor
                )
            }
        )

        diag.report("diagnostic_export_requested", details: [
            "liveWindowCount": "\(liveWindows.count)",
            "runningAppCount": "\(runningApps.count)",
            "destinationExtension": destination.pathExtension,
        ])
        diag.flush()

        do {
            try DiagnosticExporter().export(snapshot, to: destination)
            diag.report("diagnostic_export_completed", details: [
                "filename": destination.lastPathComponent,
            ])
        } catch {
            diag.report("diagnostic_export_failed", details: [
                "error": String(describing: error),
            ])
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Diagnostic Export Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func diagnosticExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Debut-Diagnostics-\(formatter.string(from: Date())).json"
    }

    private func setupTelemetry() {
        let environment = ProcessInfo.processInfo.environment
        let namespace = environment["DEBUT_TELEMETRYDECK_NAMESPACE"]
            ?? Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckNamespace") as? String
            ?? ""
        let appID = environment["DEBUT_TELEMETRYDECK_APP_ID"]
            ?? Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID") as? String
            ?? ""
        let client: any TelemetryClient = namespace.isEmpty || appID.isEmpty
            ? UnavailableTelemetryClient()
            : TelemetryDeckClient(namespace: namespace, appID: appID)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Debut")
        let exporter = TelemetryExporter(
            client: client,
            queue: DiskTelemetryQueue(file: support.appendingPathComponent("telemetry-queue.json")),
            enabled: currentSettings.shareAnonymousTelemetry
        )
        telemetryExporter = exporter
        PerformanceRecorder.shared.setObservationHandler { observation in
            guard PerformanceAnomalyPolicy.shouldReport(observation) else { return }
            let workload: TelemetryWorkload = observation.workload.windows >= 50
                ? .stress : (observation.workload.windows >= 21 ? .busy : .typical)
            Task {
                try? await exporter.enqueue(.anomaly(
                    operation: observation.operation,
                    latency: TelemetryLatencyBucket(milliseconds: observation.durationMilliseconds),
                    workload: workload,
                    temperature: observation.temperature
                ))
                try? await exporter.flush()
            }
        }
        let telemetryEnabled = currentSettings.shareAnonymousTelemetry
        Task {
            try? await exporter.pruneInvalidAnomalies()
            if telemetryEnabled { try? await exporter.flush() }
        }
    }

    private func currentTelemetrySummary() -> TelemetryPayload {
        let performance = PerformanceRecorder.shared.snapshot()
        var counts: [PerformanceOperation: Int] = [:]
        var latency: [PerformanceOperation: TelemetryLatencyBucket] = [:]
        for observation in performance.recent { counts[observation.operation, default: 0] += 1 }
        for (name, summary) in performance.summaries {
            if let operation = PerformanceOperation(rawValue: name) {
                latency[operation] = TelemetryLatencyBucket(milliseconds: summary.p95Milliseconds)
            }
        }
        let windowCount = stageController?.stageManager.stages.reduce(0) { $0 + $1.windows.count } ?? 0
        let workload: TelemetryWorkload = windowCount >= 50 ? .stress : (windowCount >= 21 ? .busy : .typical)
        return .sessionSummary(
            appVersion: DebutCore.version,
            operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            workload: workload,
            operationCounts: counts,
            latencyBuckets: latency,
            anomalyCount: performance.recent.filter(PerformanceAnomalyPolicy.shouldReport).count
        )
    }

}
