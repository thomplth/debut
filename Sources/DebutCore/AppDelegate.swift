import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, SpaceControllerDelegate {
    private var spaceController: SpaceController?
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
    private let launchAtLogin = LaunchAtLoginCoordinator()
    private let applicationUpdater: any ApplicationUpdating

    private var windowService: AccessibilityWindowService?
    private var keyboardService: EventTapKeyboardService?
    private var spaceService: SpaceService?
    private var currentSettings: AppSettings = AppSettings()
    private var pendingSpaceManager: SpaceManager?
    private var debouncedSaver: DebouncedSaver?
    private var runtimeWindowReconciler = RuntimeWindowReconciler()
    private var telemetryExporter: TelemetryExporter?
    private var hiddenIdlePerformanceID: UUID?
    private let forceDisplayStackIndicator =
        ProcessInfo.processInfo.environment["DEBUT_FORCE_DISPLAY_STACK_INDICATOR"] == "1"
        || ProcessInfo.processInfo.arguments.contains("--force-display-stack-indicator")
    private let mainQueueWatchdog = MainQueueStallWatchdog { stall in
        DiagnosticReporter.shared.report("main_queue_stalled", details: [
            "cpuPercent": stall.resourceDelta.map { String(format: "%.1f", $0.cpuPercent) } ?? "unknown",
            "elapsedMilliseconds": String(format: "%.1f", stall.elapsedMilliseconds),
            "pageIns": stall.resourceDelta.map { "\($0.pageIns)" } ?? "unknown",
            "phase": "overlay_render_submission",
            "traceID": stall.traceID?.uuidString ?? "none",
        ])
    }

    public init(applicationUpdater: any ApplicationUpdating = DisabledApplicationUpdater()) {
        self.applicationUpdater = applicationUpdater
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        diag.report("app_launched")

        let store = StateStore()
        stateStore = store
        debouncedSaver = DebouncedSaver(store: store)
        pendingSpaceManager = (try? store.load()) ?? SpaceManager()
        currentSettings = (try? store.loadSettings()) ?? AppSettings()
        launchAtLogin.apply(enabled: currentSettings.launchAtLogin)
        setupTelemetry()

        windowService = AccessibilityWindowService()
        keyboardService = EventTapKeyboardService()

        overlayWindow = OverlayWindow()
        setupMenuBar()
        if DebutCore.version != "0.0.0-dev" {
            applicationUpdater.start()
        }

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
        guard spaceController == nil else { return }

        var spaceManager = pendingSpaceManager ?? SpaceManager()
        pendingSpaceManager = nil

        let discovery = WindowDiscoveryService(windowService: windowService)
        self.windowDiscovery = discovery
        windowService.windowElementResolver = { [weak discovery] windowID in
            discovery?.trackedWindowElement(windowID: windowID)
        }

        // Apply exclusion list
        discovery.excludedBundleIDs = Set(currentSettings.excludedBundleIDs)
        keyboardService.excludedBundleIDs = Set(currentSettings.excludedBundleIDs)

        let spaceService = SpaceService()
        spaceService.switchDuration = currentSettings.spaceSwitchDuration
        self.spaceService = spaceService
        discovery.spaceSwitcher = spaceService

        // Windows are placed by the desktop they are on, so the space list has to cover
        // every desktop before the first reconcile. Growing it afterwards would leave the
        // tail desktops' answers out of range, and those windows would land on space 1.
        let launchTopology = spaceService.spaceTopology()
        let launchSpacesBefore = spaceManager.allSpaces.count
        spaceManager.reconcileSpaceStacks(with: launchTopology)
        diag.report("spaces_reconciled", details: [
            "separateSpaces": "\(launchTopology.separateSpaces)",
            "stackCount": "\(launchTopology.stacks.count)",
            "spacesBefore": "\(launchSpacesBefore)",
            "spacesAfter": "\(spaceManager.allSpaces.count)",
        ])

        // Remove stale window IDs, remap live window IDs from snapshot
        let reconcileID = PerformanceRecorder.shared.begin(
            .windowReconciliation,
            workload: .init(
                spaces: spaceManager.spaces.count,
                windows: spaceManager.liveWindowCount,
                dormantWindows: spaceManager.dormantWindowAssignments.count
            )
        )
        discovery.reconcileWindows(&spaceManager)
        _ = PerformanceRecorder.shared.end(reconcileID)

        // Remove excluded apps' windows from all spaces
        for bundleID in currentSettings.excludedBundleIDs {
            spaceManager.removeAllWindows(forBundleID: bundleID)
        }

        // Empty spaces are deliberately kept: a desktop with nothing on it is still a
        // desktop, and pruning it would shift every later space off the desktop it maps to.

        if spaceManager.allSpaces.allSatisfy({ $0.windows.isEmpty }) &&
            spaceManager.dormantWindowAssignments.isEmpty {
            discovery.populateDefaultSpace(&spaceManager)
        }

        // Activate the space containing the currently focused window, or fall back to first space
        let startSpaceID: UUID
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != "com.thomplth.Debut",
           let focusedWID = discovery.focusedWindowID(for: frontApp.processIdentifier),
           let owningSpace = spaceManager.spaceContainingWindow(windowID: focusedWID) {
            startSpaceID = owningSpace
            if let stackID = spaceManager.spaceStackID(containingSpaceID: owningSpace) {
                spaceManager.selectSpaceStack(id: stackID)
            }
        } else {
            startSpaceID = spaceManager.spaces[0].id
        }
        spaceManager.activateSpace(id: startSpaceID)

        AppIconCache.shared.warm(
            bundleIDs: spaceManager.allWindowOwnerBundleIDs,
            sizes: AppIconCache.overlayIconSizes
        )

        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            spaceManager: spaceManager,
            overlayPresentationDelay: currentSettings.overlayPresentationDelay,
            previewRefreshPolicy: currentSettings.previewRefreshPolicy,
            previewCacheTTL: currentSettings.previewCacheTTL
        )
        controller.delegate = self
        controller.spaceSwitcher = spaceService
        controller.onCommandUsed = { [weak self] action in
            DispatchQueue.main.async {
                self?.recordCommandUsage(action)
            }
        }
        controller.onDesktopReveal = { [weak self] in
            DispatchQueue.main.async {
                NSWorkspace.shared.hideOtherApplications()
                self?.diag.report("real_desktop_presented")
            }
        }
        spaceController = controller

        keyboardService.keyBindings = currentSettings.keyBindings
        keyboardService.quickSwitchExcludedBundleIDs = Set(
            currentSettings.quickSwitchExcludedBundleIDs
        )
        keyboardService.quickSwitchModifiers = currentSettings.quickSwitchModifiers
        keyboardService.quickSwitchSameApplicationModifiers =
            currentSettings.quickSwitchSameApplicationModifiers
        keyboardService.heldCycleMinimumInterval = currentSettings.heldCycleMinimumInterval

        // Spaces are the user's desktops, so the persisted lists are only a starting guess.
        // Reconciliation also adopts each display's currently visible desktop without moving it.
        controller.reconcileSpacesWithDesktops()

        discovery.onWindowsDiscovered = { [weak self] windows in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                let result = self.runtimeWindowReconciler.reconcile(
                    RuntimeWindowSnapshot(
                        liveWindows: windows,
                        allWindowIDs: nil,
                        desktopLocations: self.spaceService?.desktopLocations(
                            forWindows: windows.map(\.windowID)
                        ) ?? [:]
                    ),
                    spaceManager: &controller.spaceManager
                )
                if result.didMutate {
                    self.diag.report("runtime_windows_reconciled", details: [
                        "added": "\(result.addedCount)",
                        "reassigned": "\(result.reassignedCount)",
                        "trigger": "app_launch",
                    ])
                    self.reportAssignmentEvents(result.events, trigger: "app_launch")
                    self.debouncedSaver?.scheduleSave(controller.spaceManager)
                }
            }
        }
        discovery.onWindowClosed = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                let window = self.spaceController?.spaceManager.allSpaces
                    .flatMap(\.windows)
                    .first { $0.windowID == windowID }
                for space in self.spaceController?.spaceManager.allSpaces ?? [] {
                    self.spaceController?.spaceManager.removeWindow(windowID: windowID, fromSpaceID: space.id)
                }
                self.diag.report("window_retired", details: [
                    "windowID": "\(windowID)",
                    "bundleID": window?.ownerBundleID ?? "unknown",
                    "windowTitle": window?.windowTitle ?? "unknown",
                    "reason": "destroyed",
                ])
                if let sm = self.spaceController?.spaceManager {
                    self.debouncedSaver?.scheduleSave(sm)
                }
                self.spaceController?.handleLiveWindowsRemoved()
            }
        }
        discovery.onWindowTitleChanged = { [weak self] windowID, newTitle in
            DispatchQueue.main.async {
                guard let self else { return }
                self.spaceController?.spaceManager.updateWindowTitle(windowID: windowID, title: newTitle)
                if let sm = self.spaceController?.spaceManager {
                    self.debouncedSaver?.scheduleSave(sm)
                }
            }
        }
        discovery.onWindowActivated = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                self.spaceController?.recordWindowActivation(windowID: windowID)
            }
        }
        discovery.onFrontmostAppChanged = { [weak self, weak keyboardService] bundleID in
            keyboardService?.updateFrontmostApp(bundleIdentifier: bundleID)
            guard let self else { return }
            self.spaceController?.updateFrontmostApp(
                isExcluded: bundleID.map { self.currentSettings.excludedBundleIDs.contains($0) }
                    ?? false
            )
        }
        discovery.onAppActivated = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                let result = self.runtimeWindowReconciler.reconcile(
                    snapshot,
                    spaceManager: &controller.spaceManager
                )
                if result.didMutate {
                    self.diag.report("runtime_windows_reconciled", details: [
                        "added": "\(result.addedCount)",
                        "reassigned": "\(result.reassignedCount)",
                        "trigger": "app_activation",
                    ])
                    self.reportAssignmentEvents(result.events, trigger: "app_activation")
                    self.debouncedSaver?.scheduleSave(controller.spaceManager)
                }
            }
        }
        discovery.onDesktopsChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                let result = self.runtimeWindowReconciler.reconcile(
                    snapshot,
                    spaceManager: &controller.spaceManager
                )
                guard result.didMutate else { return }
                self.diag.report("runtime_windows_reconciled", details: [
                    "added": "\(result.addedCount)",
                    "reassigned": "\(result.reassignedCount)",
                    "trigger": "desktop_changed",
                ])
                self.reportAssignmentEvents(result.events, trigger: "desktop_changed")
                self.debouncedSaver?.scheduleSave(controller.spaceManager)
            }
        }
        discovery.onAppTerminated = { [weak self] ownerPID in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                let dormantCount = controller.spaceManager.makeWindowsDormant(forOwnerPID: ownerPID)
                if dormantCount > 0 {
                    self.diag.report("terminated_app_windows_made_dormant", details: [
                        "count": "\(dormantCount)",
                        "ownerPID": "\(ownerPID)",
                    ])
                    let sm = controller.spaceManager
                    self.debouncedSaver?.scheduleSave(sm)
                    controller.handleLiveWindowsRemoved()
                }
            }
        }
        discovery.startObserving()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Screenshot previews are process-local. Warm them after startup reconciliation so the
        // first overlay does not reveal placeholders and then flash as captures arrive.
        controller.prewarmWindowPreviews()

        diag.report("controller_setup", details: [
            "eventTapStarted": "\(controller.keyboardServiceStarted)",
            "eventTapRunning": "\(keyboardService.isRunning)",
            "windowsInDefaultSpace": "\(spaceManager.spaces[0].windows.count)",
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

    /// Fires for Debut's own switches as well as the user's. Debut's own switches are the
    /// ones waiting on this to focus their target; a user's switch has nothing pending and
    /// only needs the active space adopted.
    @objc private func activeSpaceDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spaceController?.desktopDidChange()
            // Moving a window between desktops activates no app, so without this the move is
            // only noticed the next time the user clicks the window.
            self.windowDiscovery?.refreshDesktopAssignments()
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spaceController?.reconcileSpacesWithDesktops()
            self.windowDiscovery?.refreshDesktopAssignments()
        }
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
        if spaceController == nil {
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
        let spaceController = MainActor.assumeIsolated { self.spaceController }
        let debouncedSaver = MainActor.assumeIsolated { self.debouncedSaver }
        if let spaceController, let debouncedSaver {
            debouncedSaver.flushNow(spaceController.spaceManager)
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

    // MARK: - SpaceControllerDelegate

    nonisolated public func spaceControllerDidOpenOverlay(_ controller: SpaceController) {
        spaceControllerDidOpenOverlay(controller, overlayPresentation: nil)
    }

    nonisolated public func spaceControllerDidOpenOverlay(
        _ controller: SpaceController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.showSpaceManagerOverlay(overlayPresentation: overlayPresentation)
        }
    }

    nonisolated public func spaceControllerDidCloseOverlay(_ controller: SpaceController) {
        spaceControllerDidCloseOverlay(controller, overlayPresentation: nil)
    }

    nonisolated public func spaceControllerDidCloseOverlay(
        _ controller: SpaceController,
        overlayPresentation: OverlayPresentationContext?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.hideSpaceManagerOverlay(overlayPresentation: overlayPresentation)
        }
    }

    nonisolated public func spaceControllerDidUpdateSelection(_ controller: SpaceController) {
        DispatchQueue.main.async { [weak self] in
            self?.updateOverlay()
        }
    }

    nonisolated public func spaceControllerDidSwitchSpace(_ controller: SpaceController) {}

    private func reportAssignmentEvents(_ events: [WindowAssignmentEvent], trigger: String) {
        for event in events {
            var details = event.diagnosticDetails
            details["trigger"] = trigger
            diag.report("window_\(event.kind.rawValue)", details: details)
        }
    }

    nonisolated public func spaceControllerDidMutateState(_ controller: SpaceController) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debouncedSaver?.scheduleSave(controller.spaceManager)
            self.diag.report("space_state_mutated")
        }
    }

    private func showSpaceManagerOverlay(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        guard let spaceController, let overlayWindow else { return }
        if let hiddenIdlePerformanceID {
            _ = PerformanceRecorder.shared.end(hiddenIdlePerformanceID)
            self.hiddenIdlePerformanceID = nil
        }
        let workload = PerformanceWorkload(
            spaces: spaceController.spaceManager.spaces.count,
            windows: spaceController.spaceManager.liveWindowCount
        )
        if let overlayPresentation {
            spaceController.markOverlayPresentation(.preparationBegan, context: overlayPresentation)
        }
        let preparationID = PerformanceRecorder.shared.begin(
            .overlayPreparation,
            workload: workload,
            traceID: overlayPresentation?.traceID
        )

        overlayWindow.onWindowSelected = { [weak self] spaceIndex, windowIndex in
            self?.diag.report("overlay_window_selected_by_pointer", level: .transient, details: [
                "spaceIndex": "\(spaceIndex)",
                "windowIndex": "\(windowIndex)",
            ])
            self?.spaceController?.commitOverlaySelection(
                spaceIndex: spaceIndex,
                windowIndex: windowIndex
            )
        }

        overlayWindow.onWindowMoved = {
            [weak self] windowID, fromIndex, fromWindowIndex, toIndex, toWindowIndex in
            guard let self, let ctrl = self.spaceController else { return }
            guard ctrl.moveWindowByDrag(
                windowID: windowID,
                fromSpaceIndex: fromIndex,
                toSpaceIndex: toIndex,
                toWindowIndex: toWindowIndex
            ) else { return }
            self.diag.report("window_move_previewed_by_drag", level: .transient, details: [
                "windowID": "\(windowID)",
                "fromSpaceIndex": "\(fromIndex)",
                "fromWindowIndex": "\(fromWindowIndex)",
                "toSpaceIndex": "\(toIndex)",
                "toWindowIndex": "\(toWindowIndex)",
            ])
            // Let SwiftUI finish the drag transaction before replacing its root view.
            DispatchQueue.main.async { [weak self] in
                self?.updateOverlay()
            }
        }

        overlayWindow.onSpaceScrollSelected = { [weak self] index in
            guard let self, let ctrl = self.spaceController else { return }
            ctrl.jumpToSpace(index: index)
            self.diag.report("space_scrolled_from_overlay", details: [
                "spaceIndex": "\(index)",
            ])
        }

        overlayWindow.onSpaceScrollRouted = { [weak self] scroll in
            self?.diag.report("overlay_scroll_routed", level: .transient, details: [
                "location": formatOverlayPoint(scroll.location),
                "deltaY": String(format: "%.1f", scroll.deltaY),
                "inScrollArea": "\(scroll.isInScrollArea)",
                "steps": "\(scroll.steps)",
                "destination": scroll.destination.map(String.init) ?? "none",
            ])
        }

        // A tap that resolves to nothing is indistinguishable from a tap that never arrived.
        overlayWindow.onOverlayTapRouted = { [weak self] tap in
            self?.diag.report("overlay_tap_routed", details: [
                "target": tap.target.diagnosticName,
                "location": formatOverlayPoint(tap.location),
            ])
        }

        overlayWindow.onOverlayPointerRegionChanged = { [weak self] region in
            self?.diag.report("overlay_pointer_region_changed", level: .transient, details: [
                "region": region.region,
                "location": formatOverlayPoint(region.location),
                "topBoundary": region.topBoundary.map { String(format: "%.1f", $0) } ?? "none",
                "bottomBoundary": region.bottomBoundary.map { String(format: "%.1f", $0) } ?? "none",
            ])
        }

        overlayWindow.onPointerSelectionChanged = { [weak self] spaceIndex, windowIndex in
            self?.diag.report("overlay_pointer_selection_changed", level: .transient, details: [
                "spaceIndex": spaceIndex.map(String.init) ?? "none",
                "windowIndex": windowIndex.map(String.init) ?? "none",
            ])
        }

        overlayWindow.onDesktopSelected = { [weak self] in
            self?.spaceController?.revealDesktop()
        }

        let display = overlayDisplay(focusedWindowFrame: spaceController.focusedWindowFrame)
        if let displayID = display?.displayID {
            spaceController.selectSpaceStack(forDisplayID: displayID)
        }
        overlayWindow.targetScreenFrame = display?.frame
        let vm = StageOverlayViewModel(
            spaceManager: spaceController.overlaySpaceManager,
            activeSpaceIndex: spaceController.selectedSpaceIndex,
            selectedWindowIndex: spaceController.selectedWindowIndex,
            windowPreviews: spaceController.windowPreviews,
            appearance: currentSettings,
            wallpaperLuminance: nil,
            displayTopContentInset: display?.topContentInset ?? 0,
            forceDisplayStackIndicator: forceDisplayStackIndicator
        )
        reportCommandHintLayout(viewModel: vm)
        let createdHostingView = overlayWindow.update(viewModel: vm)
        if let overlayPresentation {
            spaceController.updateOverlayHostingView(
                createdHostingView ? .created : .reused,
                context: overlayPresentation
            )
        }
        overlayWindow.showOverlay { [weak self, weak spaceController] in
            guard let self, let spaceController, let overlayPresentation else { return }
            spaceController.completeOverlayPresentation(
                overlayPresentation,
                outcome: .presented
            )
            self.diag.report("overlay_presentation_completed", level: .transient, details: [
                "outcome": OverlayPresentationOutcome.presented.rawValue,
            ])
        }
        if let overlayPresentation {
            spaceController.markOverlayPresentation(.windowOrdered, context: overlayPresentation)
        }
        _ = PerformanceRecorder.shared.end(preparationID)
        if let overlayPresentation {
            spaceController.markOverlayPresentation(.preparationCompleted, context: overlayPresentation)
        }
        let renderSubmissionID = PerformanceRecorder.shared.begin(
            .overlayRenderSubmission,
            workload: workload,
            traceID: overlayPresentation?.traceID
        )
        // Armed across the enqueue so a queue that is still blocked reports
        // itself, rather than leaving a long duration to be explained afterwards.
        mainQueueWatchdog.arm(traceID: overlayPresentation?.traceID)
        DispatchQueue.main.async { [weak overlayWindow, weak spaceController, watchdog = mainQueueWatchdog] in
            watchdog.disarm()
            overlayWindow?.contentView?.displayIfNeeded()
            CATransaction.flush()
            if let overlayPresentation {
                spaceController?.markOverlayPresentation(
                    .renderSubmitted,
                    context: overlayPresentation
                )
            }
            _ = PerformanceRecorder.shared.end(renderSubmissionID)
        }
        diag.report("overlay_shown")
    }

    private func reportCommandHintLayout(viewModel: StageOverlayViewModel) {
        let leadingHintCount = viewModel.stages.indices.compactMap { index in
            CommandHintCatalog.spaceNumberHint(spaceIndex: index, settings: currentSettings)
        }.count
        guard viewModel.stages.indices.contains(viewModel.activeSpaceIndex) else { return }
        let activeStage = viewModel.stages[viewModel.activeSpaceIndex]
        let footerHints = CommandHintCatalog.stageFooterHints(
            spaceIndex: viewModel.activeSpaceIndex,
            isActive: true,
            hasSelectedWindow: activeStage.windows.indices.contains(viewModel.selectedWindowIndex),
            settings: currentSettings
        )
        let nextWindowIndex = activeStage.windows.indices.first { index in
            !CommandHintCatalog.windowHints(
                windowIndex: index,
                selectedWindowIndex: viewModel.selectedWindowIndex,
                windowCount: activeStage.windows.count,
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

    private func hideSpaceManagerOverlay(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        if let overlayPresentation {
            spaceController?.completeOverlayPresentation(
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
        guard let spaceController, let overlayWindow else { return }
        let display = overlayDisplay(focusedWindowFrame: spaceController.focusedWindowFrame)
        // Stack cycling deliberately keeps the overlay on its current screen; the header
        // changes to identify the remote display whose stages are being inspected.
        if spaceController.spaceManager.connectedSpaceStacks.count <= 1 {
            overlayWindow.targetScreenFrame = display?.frame
        }
        let vm = StageOverlayViewModel(
            spaceManager: spaceController.overlaySpaceManager,
            activeSpaceIndex: spaceController.selectedSpaceIndex,
            selectedWindowIndex: spaceController.selectedWindowIndex,
            windowPreviews: spaceController.windowPreviews,
            appearance: currentSettings,
            wallpaperLuminance: nil,
            displayTopContentInset: display?.topContentInset ?? 0,
            forceDisplayStackIndicator: forceDisplayStackIndicator
        )
        overlayWindow.update(viewModel: vm)
    }

    /// The screen the stages belong on: the one holding the focused window. Accessibility
    /// reports that window in Quartz coordinates, so the displays are matched in that space and
    /// only the winner is translated back into Cocoa's.
    private func overlayDisplay(
        focusedWindowFrame: CGRect?
    ) -> (displayID: CGDirectDisplayID, frame: CGRect, topContentInset: CGFloat)? {
        let displays = NSScreen.screens.map {
            DesktopScreenDescriptor(displayID: $0.displayID, frame: CGDisplayBounds($0.displayID))
        }
        guard let displayID = OverlayDisplayResolver.resolve(
            focusedWindowFrame: focusedWindowFrame,
            displays: displays,
            mainDisplayID: NSScreen.main?.displayID
        ), let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else { return nil }
        let topContentInset = OverlayDisplayResolver.topContentInset(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            menuBarHeight: NSStatusBar.system.thickness
        )
        return (displayID, screen.frame, topContentInset)
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
        if spaceController?.isSpaceManagerVisible == true {
            updateOverlay()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = DebutGlyph.image(size: DebutGlyph.menuBarSize)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Tutorial...", action: #selector(openTutorial), keyEquivalent: ""))
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)
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

    @objc private func checkForUpdates(_ sender: Any?) {
        applicationUpdater.checkForUpdates()
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

        let currentSpaceManager = spaceController?.spaceManager ?? SpaceManager()
        var vm = SettingsViewModel(
            settings: settings,
            spaceManager: currentSpaceManager
        )
        vm.onSettingsChanged = { [weak self] newSettings in
            DispatchQueue.main.async {
                guard let self else { return }
                let telemetryChanged = self.currentSettings.shareAnonymousTelemetry != newSettings.shareAnonymousTelemetry
                self.launchAtLogin.apply(enabled: newSettings.launchAtLogin)
                self.currentSettings = newSettings
                try? self.stateStore?.saveSettings(newSettings)
                self.windowDiscovery?.excludedBundleIDs = Set(newSettings.excludedBundleIDs)
                self.keyboardService?.excludedBundleIDs = Set(newSettings.excludedBundleIDs)
                self.spaceController?.updateFrontmostApp(
                    isExcluded: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        .map(newSettings.excludedBundleIDs.contains) ?? false
                )
                for bundleID in newSettings.excludedBundleIDs {
                    self.spaceController?.spaceManager.removeAllWindows(forBundleID: bundleID)
                }
                if let spaceManager = self.spaceController?.spaceManager {
                    self.debouncedSaver?.scheduleSave(spaceManager)
                }
                self.keyboardService?.keyBindings = newSettings.keyBindings
                self.spaceController?.overlayPresentationDelay = newSettings.overlayPresentationDelay
                self.spaceController?.previewRefreshPolicy = newSettings.previewRefreshPolicy
                self.spaceController?.previewCacheTTL = newSettings.previewCacheTTL
                self.spaceService?.switchDuration = newSettings.spaceSwitchDuration
                self.keyboardService?.quickSwitchExcludedBundleIDs = Set(
                    newSettings.quickSwitchExcludedBundleIDs
                )
                self.keyboardService?.quickSwitchModifiers = newSettings.quickSwitchModifiers
                self.keyboardService?.quickSwitchSameApplicationModifiers =
                    newSettings.quickSwitchSameApplicationModifiers
                self.keyboardService?.heldCycleMinimumInterval =
                    newSettings.heldCycleMinimumInterval
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
        vm.onCheckForUpdates = { [weak self] in
            DispatchQueue.main.async {
                self?.applicationUpdater.checkForUpdates()
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
        let previousManager = spaceController?.spaceManager
            ?? pendingSpaceManager
            ?? (try? stateStore?.load())
            ?? SpaceManager()
        let previousLiveCount = previousManager.liveWindowCount
        let previousDormantCount = previousManager.dormantWindowAssignments.count

        diag.report("window_cache_reset_started", details: [
            "liveAssignments": "\(previousLiveCount)",
            "dormantAssignments": "\(previousDormantCount)",
            "spaceCount": "\(previousManager.spaces.count)",
        ])

        if let controller = spaceController, let discovery = windowDiscovery {
            controller.rebuildWindowCache(using: discovery)

            // No z-order to rebuild — the windows of the active space are the windows on
            // the current desktop, and macOS is already showing them.
            if let firstWindow = controller.spaceManager.activeSpace.windows.first {
                _ = controller.windowService.activateApp(bundleID: firstWindow.ownerBundleID)
            }

            debouncedSaver?.flushNow(controller.spaceManager)
            diag.report("window_cache_reset_completed", details: [
                "discoveredAssignments": "\(controller.spaceManager.activeSpace.windows.count)",
            ])
        } else {
            var resetManager = previousManager
            resetManager.resetWindowCache()
            pendingSpaceManager = resetManager
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
        let manager = spaceController?.spaceManager
            ?? pendingSpaceManager
            ?? (try? stateStore?.load())
            ?? SpaceManager()
        let liveWindows = windowService?.listWindows() ?? []
        let runningApps = windowService?.listRunningApps() ?? []
        let snapshot = DiagnosticExportSnapshot(
            spaceManager: manager,
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
        let support = DebutCore.applicationSupportDirectory
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
        let windowCount = spaceController?.spaceManager.liveWindowCount ?? 0
        let workload: TelemetryWorkload = windowCount >= 50 ? .stress : (windowCount >= 21 ? .busy : .typical)
        let anomalyCount = performance.recent.reduce(into: 0) { count, observation in
            if PerformanceAnomalyPolicy.shouldReport(observation) { count += 1 }
        }
        return .sessionSummary(
            appVersion: DebutCore.version,
            operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            workload: workload,
            operationCounts: counts,
            latencyBuckets: latency,
            anomalyCount: anomalyCount
        )
    }

}

func formatOverlayPoint(_ point: CGPoint) -> String {
    String(format: "%.1f,%.1f", point.x, point.y)
}
