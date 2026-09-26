import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, SpaceControllerDelegate {
    private var spaceController: SpaceController?
    private var overlayWindow: OverlayWindow?
    private var desktopSwitchIndicatorWindows: [String: DesktopSwitchIndicatorWindow] = [:]
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: OnboardingViewModel?
    private var tutorialWindow: NSWindow?
    private var tutorialTargetWindow: NSWindow?
    private var tutorialWindowNeedsReplacement = false
    private var tutorialWindowAwaitingPlacement = false
    private var pendingTutorialTarget: OnboardingTarget?
    private var preparingTutorialTarget = false
    private var tutorialGeneration = 0
    private var desktopSwipeService: DesktopSwipeService?
    private var desktopNavigationStackID: String?
    private var desktopNavigationEligibility: DesktopNavigationEligibility?
    private let overviewSignalConfirmer = OverviewSignalConfirmer()
    private var desktopNavigationRefreshScheduled = false
    private var consumeOverviewRecoveryOnRefresh = false
    private var tutorialViewModel: TutorialViewModel?
    private var coachmarkPopover: NSPopover?
    private var statusItem: NSStatusItem?
    private var stateStore: StateStore?
    private var observingAccessibilityChanges = false
    private var windowDiscovery: WindowDiscoveryService?
    private let diag = DiagnosticReporter.shared
    /// Verdicts are published from an AX destroy callback and from `listWindows()`, so the write
    /// they trigger is moved off whichever thread produced the evidence.
    private nonisolated let verdictQueue = DispatchQueue(
        label: "com.thomplth.Debut.verdictPersistence",
        qos: .utility
    )
    private let onboardingPermissionClient = SystemOnboardingPermissionClient()
    private lazy var onboardingPermissionGuide = OnboardingPermissionGuide(
        permissionClient: onboardingPermissionClient
    )
    private let onboardingProcessID = UUID().uuidString
    private let launchAtLogin = LaunchAtLoginCoordinator()
    private let activationPolicy = ActivationPolicyCoordinator()
    private let processResponsivenessActivity = ProcessResponsivenessActivity()
    private let applicationUpdater: any ApplicationUpdating

    private var windowService: AccessibilityWindowService?
    private var keyboardService: EventTapKeyboardService?
    private var spaceService: SpaceService?
    private var currentSettings: AppSettings = AppSettings()
    private var pendingSpaceManager: SpaceManager?
    private var debouncedSaver: DebouncedSaver?
    private var runtimeWindowReconciler = RuntimeWindowReconciler()
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

    private static func runningBundleIDsByPID(windowService: any WindowService) -> [pid_t: String] {
        var table = NSWorkspace.shared.runningApplications.reduce(into: [pid_t: String]()) {
            result, app in
            if app.processIdentifier > 0 { result[app.processIdentifier] = app.bundleIdentifier }
        }
        for app in windowService.listRunningApps() {
            table[app.pid] = app.bundleID
        }
        return table
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        processResponsivenessActivity.start()
        NSApp.setActivationPolicy(.accessory)
        diag.report("app_launched")
        NSApp.mainMenu = Self.makeMainMenu(target: self)

        let store = StateStore()
        stateStore = store
        debouncedSaver = DebouncedSaver(store: store)
        pendingSpaceManager = (try? store.load()) ?? SpaceManager()
        currentSettings = (try? store.loadSettings()) ?? AppSettings()
        let spaceService = SpaceService()
        spaceService.switchDuration = currentSettings.spaceSwitchDuration
        spaceService.onSwitchRecovery = { [weak self] in
            DispatchQueue.main.async { self?.handleDesktopDidChange() }
        }
        self.spaceService = spaceService
        let navigationEligibility = DesktopNavigationEligibility(
            canSwitchSpaces: { spaceService.canSwitchSpaces }
        )
        desktopNavigationEligibility = navigationEligibility
        activationPolicy.apply(showsDockIcon: currentSettings.showsDockIcon)
        launchAtLogin.apply(enabled: currentSettings.launchAtLogin)
        // Builds that offered remote performance sharing may have left an unsent queue.
        // It is obsolete and must not survive the integration that created it.
        LegacyDataCleanup.removeObsoleteRemoteMetricsQueue()

        let accessibility = AccessibilityWindowService()
        accessibility.restoreContradictions(
            (try? store.loadContradictions()) ?? [],
            runningBundleIDsByPID: Self.runningBundleIDsByPID(windowService: accessibility)
        )
        accessibility.onContradictionsChanged = { [verdictQueue] records in
            verdictQueue.async { try? store.saveContradictions(records) }
        }
        windowService = accessibility
        keyboardService = EventTapKeyboardService(
            desktopNavigationBlocked: desktopNavigationBlocker()
        )

        overlayWindow = OverlayWindow()
        setupMenuBar()
        if DebutCore.version != "0.0.0-dev" {
            applicationUpdater.start()
        }

        let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--show-onboarding")
        let permissionReturn = OnboardingPermissionReturnStore.pending()
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
                onboardingPermissionClient.openSettings(for: .accessibility)
            }
        }

        if shouldShowOnboarding {
            showOnboarding(restoring: permissionReturn?.page)
        }

        if ProcessInfo.processInfo.arguments.contains("--show-tutorial"), !shouldShowOnboarding {
            showTutorial()
        }

        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            showSettings(settings: currentSettings)
        }

        diag.report("app_ready")
        hiddenIdlePerformanceID = PerformanceRecorder.shared.begin(.hiddenIdle)
    }

    /// During setup the Dock returns to the current lesson, including after practice.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        if onboardingWindow != nil || OnboardingLaunchPolicy.shouldPresent() {
            showOnboarding()
            return true
        }
        if tutorialWindow != nil {
            showTutorial()
            return true
        }
        guard !hasVisibleWindows else { return true }
        openSettings()
        return true
    }

    private func setupController() {
        guard let windowService, let keyboardService, let spaceService,
              desktopNavigationEligibility != nil else { return }
        guard spaceController == nil else { return }

        var spaceManager = pendingSpaceManager ?? SpaceManager()
        pendingSpaceManager = nil

        let discovery = WindowDiscoveryService(windowService: windowService)
        self.windowDiscovery = discovery
        // Restored before the first reconcile, which is the one that would otherwise bind a
        // dead surface its owner still lists to a dormant assignment and resurrect the ghost.
        discovery.restoreRetiredWindows(
            (try? stateStore?.loadRetiredWindows()) ?? [],
            runningBundleIDsByPID: Self.runningBundleIDsByPID(windowService: windowService)
        )
        if let stateStore {
            discovery.onRetiredWindowsChanged = { [verdictQueue] records in
                verdictQueue.async { try? stateStore.saveRetiredWindows(records) }
            }
        }
        windowService.windowElementResolver = { [weak discovery] windowID in
            discovery?.trackedWindowElement(windowID: windowID)
        }

        // Apply exclusion list
        discovery.excludedBundleIDs = Set(currentSettings.excludedBundleIDs)
        keyboardService.excludedBundleIDs = Set(currentSettings.excludedBundleIDs)

        discovery.spaceSwitcher = spaceService
        windowService.spaceSwitcher = spaceService

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
           let frontmostPID = windowService.frontmostApplicationPID(),
           let focusedWID = discovery.focusedWindowID(for: frontmostPID),
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
            sizes: AppIconCache.overlayIconSizes,
            badgeSizes: AppIconCache.overlayBadgeIconSizes
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
        controller.onTutorialSelectionVerified = { [weak self] windowID, practice in
            DispatchQueue.main.async { self?.completeTutorialSelection(windowID: windowID, practice: practice) }
        }
        controller.excludedBundleIDs = Set(currentSettings.excludedBundleIDs)
        controller.spaceSwitcher = spaceService
        controller.fasterDesktopSwitchingEnabled =
            currentSettings.features.fasterDesktopSwitching
        controller.onDesktopReveal = { [weak self] in
            DispatchQueue.main.async {
                NSWorkspace.shared.hideOtherApplications()
                self?.diag.report("real_desktop_presented")
            }
        }
        spaceController = controller

        keyboardService.keyBindings = currentSettings.keyBindings
        keyboardService.quickSwitchModifiers = currentSettings.quickSwitchModifiers
        keyboardService.quickSwitchSameApplicationModifiers =
            currentSettings.quickSwitchSameApplicationModifiers
        let swipeService = DesktopSwipeService(
            desktopNavigationBlocked: desktopNavigationBlocker(),
            switchDesktop: { [weak controller] offset in
                // The event tap owns only the stream decision. Topology and controller work
                // begins after the callback has returned to the run loop.
                DispatchQueue.main.async {
                    controller?.handleKeyEvent(.switchAdjacentSpace(offset))
                }
            }
        )
        desktopSwipeService = swipeService
        if !swipeService.setEnabled(currentSettings.features.effectiveTrackpadSwipes) {
            diag.report("desktop_swipe_tap_failed")
        }
        keyboardService.features = currentSettings.features
        controller.windowPreviewsEnabled = OnboardingCapturePolicy.isEnabled(
            previewsRequested: currentSettings.features.windowPreviews,
            screenRecordingGranted: onboardingPermissionClient.currentState().screenRecordingGranted
                && onboardingViewModel?.screenRecordingRequiresRelaunch != true)
        keyboardService.heldCycleMinimumInterval = currentSettings.heldCycleMinimumInterval

        // Spaces are the user's desktops, so the persisted lists are only a starting guess.
        // Reconciliation also adopts each display's currently visible desktop without moving it.
        controller.reconcileSpacesWithDesktops()
        refreshDesktopNavigationAvailability()

        discovery.onWindowsDiscovered = { [weak self] windows in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                controller.recordWindowSizes(windows)
                let result = self.runtimeWindowReconciler.reconcile(
                    RuntimeWindowSnapshot(
                        liveWindows: windows,
                        allWindowIDs: nil,
                        desktopLocations: self.spaceService?.desktopLocations(
                            forWindows: windows.map(\.windowID)
                        ) ?? [:]
                    ),
                    spaceManager: &controller.spaceManager,
                    controllerOwnedMoveWindowIDs: controller.controllerOwnedMoveWindowIDs
                )
                if result.didMutate || result.refusedCount > 0 {
                    self.diag.report("runtime_windows_reconciled", details: [
                        "added": "\(result.addedCount)",
                        "reassigned": "\(result.reassignedCount)",
                        "refused": "\(result.refusedCount)",
                        "trigger": "app_launch",
                    ])
                    self.reportAssignmentEvents(result.events, trigger: "app_launch")
                    self.debouncedSaver?.scheduleSave(controller.spaceManager)
                }
                self.publishTutorialTargetIfDiscovered()
                // New AppKit windows receive a desktop asynchronously. Discovery is the
                // event that makes preparation safe after a lesson has been reopened.
                if self.tutorialWindowAwaitingPlacement { self.prepareTutorialTarget() }
            }
        }
        discovery.onWindowCreated = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                controller.recordWindowSizes(snapshot.liveWindows)
                let result = self.runtimeWindowReconciler.reconcile(
                    snapshot,
                    spaceManager: &controller.spaceManager,
                    allowDormantBundleFallback: false,
                    controllerOwnedMoveWindowIDs: controller.controllerOwnedMoveWindowIDs
                )
                self.diag.report("runtime_windows_reconciled", details: [
                    "added": "\(result.addedCount)",
                    "reassigned": "\(result.reassignedCount)",
                    "refused": "\(result.refusedCount)",
                    "trigger": "window_created",
                ])
                self.reportAssignmentEvents(result.events, trigger: "window_created")
                if result.didMutate {
                    self.debouncedSaver?.scheduleSave(controller.spaceManager)
                }
                self.publishTutorialTargetIfDiscovered()
                if self.tutorialWindowAwaitingPlacement { self.prepareTutorialTarget() }
            }
        }
        discovery.onWindowClosed = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                let window = self.spaceController?.spaceManager.allSpaces
                    .flatMap(\.windows)
                    .first { $0.windowID == windowID }
                self.diag.report("window_retired", details: [
                    "windowID": "\(windowID)",
                    "bundleID": window?.ownerBundleID ?? "unknown",
                    "windowTitle": window?.windowTitle ?? "unknown",
                    "reason": "destroyed",
                ])
                self.spaceController?.recordWindowDestruction(windowID: windowID)
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
        discovery.onWindowResized = { [weak self] windowID, size in
            DispatchQueue.main.async {
                self?.spaceController?.recordWindowSize(windowID: windowID, size: size)
            }
        }
        discovery.onWindowActivated = { [weak self] windowID in
            DispatchQueue.main.async {
                guard let self else { return }
                self.spaceController?.recordWindowActivation(windowID: windowID)
            }
        }
        discovery.onSystemAttentionRequested = { [weak self] windowID, ownerPID in
            DispatchQueue.main.async {
                self?.spaceController?.recordOverlayActionAttention(
                    windowID: windowID,
                    ownerPID: ownerPID
                )
            }
        }
        discovery.onFrontmostAppChanged = { [weak self, weak keyboardService] bundleID, source in
            keyboardService?.updateFrontmostApp(bundleIdentifier: bundleID)
            guard let self else { return }
            self.spaceController?.updateFrontmostApp(bundleID: bundleID, source: source)
        }
        discovery.onAppActivated = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                controller.recordWindowSizes(snapshot.liveWindows)
                let result = self.runtimeWindowReconciler.reconcile(
                    snapshot,
                    spaceManager: &controller.spaceManager,
                    allowDormantBundleFallback: false,
                    controllerOwnedMoveWindowIDs: controller.controllerOwnedMoveWindowIDs
                )
                if result.didMutate || result.refusedCount > 0 {
                    self.diag.report("runtime_windows_reconciled", details: [
                        "added": "\(result.addedCount)",
                        "reassigned": "\(result.reassignedCount)",
                        "refused": "\(result.refusedCount)",
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
                controller.recordWindowSizes(snapshot.liveWindows)
                let result = self.runtimeWindowReconciler.reconcile(
                    snapshot,
                    spaceManager: &controller.spaceManager,
                    allowDormantBundleFallback: false,
                    controllerOwnedMoveWindowIDs: controller.controllerOwnedMoveWindowIDs
                )
                guard result.didMutate || result.refusedCount > 0 else { return }
                self.diag.report("runtime_windows_reconciled", details: [
                    "added": "\(result.addedCount)",
                    "reassigned": "\(result.reassignedCount)",
                    "refused": "\(result.refusedCount)",
                    "trigger": "desktop_changed",
                ])
                self.reportAssignmentEvents(result.events, trigger: "desktop_changed")
                self.debouncedSaver?.scheduleSave(controller.spaceManager)
            }
        }
        discovery.onAppTerminated = { [weak self] ownerPID in
            DispatchQueue.main.async {
                guard let self, let controller = self.spaceController else { return }
                let isTransient = controller.spaceManager.allSpaces.lazy.flatMap(\.windows)
                    .contains { $0.ownerPID == ownerPID &&
                        TransientWindowIdentity.isTransient($0.ownerBundleID) }
                let removedCount = isTransient
                    ? controller.spaceManager.removeAllWindows(forOwnerPID: ownerPID)
                    : controller.spaceManager.makeWindowsDormant(forOwnerPID: ownerPID)
                controller.recordAppTermination(ownerPID: ownerPID)
                if removedCount > 0 {
                    self.diag.report(isTransient
                        ? "terminated_transient_app_windows_removed"
                        : "terminated_app_windows_made_dormant", details: [
                        "count": "\(removedCount)",
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

        // Reordering desktops changes no active space, so no AppKit notification reports it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(desktopLayoutMayHaveChanged(_:)),
            name: .debutDesktopLayoutMayHaveChanged,
            object: nil
        )
        let subscribed = DesktopReconfigurationObserver.start()
        diag.report("desktop_reconfiguration_observed", details: [
            "events": subscribed.map(String.init).joined(separator: ","),
        ])

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

    private func desktopNavigationBlocker() -> @Sendable () -> Bool {
        guard let eligibility = desktopNavigationEligibility else { return { true } }
        return { [weak self] in
            guard let reason = eligibility.blockReason() else { return false }
            if reason != .syntheticSwitchUnsupported {
                DispatchQueue.main.async {
                    self?.queueDesktopNavigationRefresh(consumingOverviewRecovery: true)
                }
            }
            DiagnosticReporter.shared.report(
                "desktop_navigation_input_yielded",
                level: .transient,
                details: ["reason": reason.rawValue]
            )
            return true
        }
    }

    /// Cross-process state is refreshed after an input callback returns. Multiple native
    /// gestures in the same run-loop turn collapse into one WindowServer query.
    private func queueDesktopNavigationRefresh(consumingOverviewRecovery: Bool) {
        consumeOverviewRecoveryOnRefresh = consumeOverviewRecoveryOnRefresh
            || consumingOverviewRecovery
        guard !desktopNavigationRefreshScheduled else { return }
        desktopNavigationRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.desktopNavigationRefreshScheduled = false
            let consumeRecovery = self.consumeOverviewRecoveryOnRefresh
            self.consumeOverviewRecoveryOnRefresh = false
            self.refreshDesktopNavigationAvailability(
                consumingOverviewRecovery: consumeRecovery
            )
        }
    }

    /// Cache the selected stack, current desktop, and overview ownership before input begins.
    private func refreshDesktopNavigationAvailability(
        consumingOverviewRecovery: Bool = false
    ) {
        let stackID = spaceController?.spaceManager.selectedSpaceStackID
        desktopNavigationStackID = stackID
        guard let spaceService else { return }
        desktopNavigationEligibility?.update(
            stackID: stackID,
            topology: spaceService.spaceTopology(),
            overviewActive: DockOverviewDetector.isActive(),
            consumeOverviewRecovery: consumingOverviewRecovery
        )
    }

    /// Fires for Debut's own switches as well as the user's. Debut's own switches are the
    /// ones waiting on this to focus their target; a user's switch has nothing pending and
    /// only needs the active space adopted.
    @objc private func activeSpaceDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleDesktopDidChange()
        }
    }

    private func handleDesktopDidChange() {
        // The desktop settled, so a pending 1327 came from this transition, not an overview.
        overviewSignalConfirmer.cancel()
        guard let controller = spaceController else { return }
        let changes = controller.desktopDidChange()
        let presentations = DesktopSwitchIndicatorPolicy.presentations(
            for: changes,
            isEnabled: currentSettings.showsDesktopSwitchIndicator,
            overlayVisible: controller.isSpaceManagerVisible
        )
        for presentation in presentations { showDesktopSwitchIndicator(presentation) }
        refreshDesktopNavigationAvailability()
        refreshTutorialEnvironment()
        // Moving a window between desktops activates no app, so without this the move is
        // only noticed the next time the user clicks the window.
        windowDiscovery?.refreshDesktopAssignmentsInBackground()
    }

    private func showDesktopSwitchIndicator(
        _ presentation: DesktopSwitchIndicatorPresentation
    ) {
        let screen = presentation.displayID.flatMap { displayID in
            NSScreen.screens.first(where: { $0.displayID == displayID })
        } ?? NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() })
            ?? NSScreen.main
        guard let screen else { return }
        let window = desktopSwitchIndicatorWindows[presentation.stackID]
            ?? DesktopSwitchIndicatorWindow()
        desktopSwitchIndicatorWindows[presentation.stackID] = window
        window.present(
            presentation,
            on: screen,
            glassStyle: currentSettings.glassStyle
        )
        diag.report("desktop_switch_indicator_shown", level: .transient, details: [
            "desktopCount": "\(presentation.desktopCount)",
            "desktopPosition": "\(presentation.desktopPosition)",
            "displayName": presentation.displayName,
            "stackID": presentation.stackID,
        ])
    }

    /// Mission Control changed the desktop list, or is about to make it mutable.
    ///
    /// Only the space order is re-read. Reordering desktops does not change which desktop a
    /// window is on — each space travels with its `desktopUUID` — so refreshing window
    /// assignments here would be redundant, and it is not harmless: 1327 arrives before the
    /// window server's list settles, so the reassignment lands on a stale read and can pull a
    /// window that is mid-move back to the desktop it just left.
    @objc private func desktopLayoutMayHaveChanged(_ notification: Notification) {
        if let event = notification.object as? DesktopReconfigurationEvent,
           !event.desktopListIsSettled {
            // SkyLight also emits 1327 around ordinary desktop transitions. Only the live
            // Dock/WindowManager marker proves an overview owns input; trusting the signal by
            // itself poisons the cache and leaks the next shortcut back to macOS. The marker
            // can also trail the signal, so the confirmer keeps looking for a bounded moment.
            overviewSignalConfirmer.signalReceived { [weak self] in
                self?.overviewConfirmed()
            }
            diag.report("desktop_navigation_overview_signal_received", level: .transient)
            return
        }
        spaceController?.reconcileSpacesWithDesktops()
        refreshDesktopNavigationAvailability()
        refreshTutorialEnvironment()
    }

    private func overviewConfirmed() {
        guard desktopNavigationEligibility?.overviewWillOpen(confirmed: true) == true else { return }
        // A synthetic hop has no completion signal once Mission Control takes over.
        // Clear it now so a later request cannot coalesce behind stale state, and drain
        // a physical gesture whose Began Debut may already have claimed. Do not sample
        // topology here: 1327 arrives while the current desktop is transiently absent.
        spaceService?.cancelPendingSwitches()
        desktopSwipeService?.cancelActiveGesture()
        diag.report("desktop_navigation_overview_will_open", level: .transient)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spaceController?.reconcileSpacesWithDesktops()
            self.windowDiscovery?.refreshDesktopAssignmentsInBackground()
        }
    }

    @objc private func workspaceApplicationActivated(_ notification: Notification) {
        tutorialViewModel?.refreshPermissions()
        onboardingViewModel?.refreshPermissions()
        handlePermissionStateChange(
            onboardingPermissionClient.currentState(),
            source: "app_activation"
        )
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        tutorialViewModel?.refreshPermissions()
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
        onboardingPermissionGuide.update(
            permissionState: state,
            requiresRelaunch: onboardingViewModel?.screenRecordingRequiresRelaunch ?? false
        )
        if state.accessibilityGranted,
           OnboardingPermissionReturnStore.pending()?.permission == .accessibility {
            OnboardingPermissionReturnStore.clear()
        }
        guard state.accessibilityGranted else { return }
        if spaceController == nil {
            diag.report("accessibility_granted", details: ["source": source])
            setupController()
        }
        let captureEnabled = OnboardingCapturePolicy.isEnabled(
            previewsRequested: currentSettings.features.windowPreviews,
            screenRecordingGranted: state.screenRecordingGranted
                && onboardingViewModel?.screenRecordingRequiresRelaunch != true)
        if spaceController?.windowPreviewsEnabled != captureEnabled {
            spaceController?.windowPreviewsEnabled = captureEnabled
            if captureEnabled { spaceController?.prewarmWindowPreviews() }
        }
        if let tutorialWindow, !tutorialWindowNeedsReplacement { admitSettingsWindowToSpaceManager(tutorialWindow) }
        prepareTutorialTarget()
        stopAccessibilityObservation()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { self.onboardingPermissionGuide.dismiss() }
        OverlayPresentationRecorder.shared.finalizeAll(outcome: .appTerminated)
        let spaceController = MainActor.assumeIsolated { self.spaceController }
        let debouncedSaver = MainActor.assumeIsolated { self.debouncedSaver }
        if let spaceController, let debouncedSaver {
            debouncedSaver.flushNow(spaceController.spaceManager)
        }
        // Written beside the assignments it explains: a ghost's dormant assignment survives a
        // relaunch, so a verdict that does not is overruled by the startup reconcile.
        let stateStore = MainActor.assumeIsolated { self.stateStore }
        let windowService = MainActor.assumeIsolated { self.windowService }
        if let stateStore, let windowService {
            try? stateStore.saveContradictions(windowService.contradictionRecords)
        }
        let windowDiscovery = MainActor.assumeIsolated { self.windowDiscovery }
        if let stateStore, let windowDiscovery {
            try? stateStore.saveRetiredWindows(windowDiscovery.retiredWindowRecords)
        }
    }

    // MARK: - SpaceControllerDelegate

    nonisolated public func spaceController(
        _ controller: SpaceController,
        didAdmitWindow windowID: CGWindowID,
        ownerPID: pid_t
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.windowDiscovery?.registerTracking(windowID: windowID, pid: ownerPID)
        }
    }

    /// Answers on the caller's thread rather than hopping: the admission this gates has already
    /// happened by the time an async reply could arrive. `recordWindowActivation` is only ever
    /// reached from the main queue, which is what makes the assumption safe.
    nonisolated public func spaceController(
        _ controller: SpaceController,
        isWindowRetired windowID: CGWindowID,
        ownerPID: pid_t
    ) -> Bool {
        MainActor.assumeIsolated {
            windowDiscovery?.isRetired(windowID: windowID, ownerPID: ownerPID) ?? false
        }
    }

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
            if self.desktopNavigationStackID != controller.spaceManager.selectedSpaceStackID {
                self.refreshDesktopNavigationAvailability()
            }
            self.diag.report("space_state_mutated")
        }
    }

    private func showSpaceManagerOverlay(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        guard let spaceController, let overlayWindow else { return }
        desktopSwitchIndicatorWindows.values.forEach { $0.hideImmediately() }
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

        overlayWindow.onAltTabWindowSelected = { [weak self] index in
            self?.diag.report("overlay_window_selected_by_pointer", level: .transient, details: [
                "altTabIndex": "\(index)",
            ])
            self?.spaceController?.commitAltTabSelection(index: index)
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
            self?.spaceController?.updateOverlayPointerSelection(
                spaceIndex: spaceIndex,
                windowIndex: windowIndex
            )
            self?.diag.report("overlay_pointer_selection_changed", level: .transient, details: [
                "spaceIndex": spaceIndex.map(String.init) ?? "none",
                "windowIndex": windowIndex.map(String.init) ?? "none",
            ])
        }

        overlayWindow.onAltTabPointerSelectionChanged = { [weak self] index in
            self?.spaceController?.updateAltTabPointerSelection(index: index)
            self?.diag.report("overlay_pointer_selection_changed", level: .transient, details: [
                "altTabIndex": index.map(String.init) ?? "none",
            ])
        }

        overlayWindow.onDesktopSelected = { [weak self] in
            self?.spaceController?.revealDesktop()
        }

        let display = overlayDisplay(
            focusedWindowFrame: spaceController.focusedWindowFrame,
            mainDisplayOnly: currentSettings.overlayOnMainDisplayOnly
        )
        // The flat switcher has already selected the stack holding its own selection, and that
        // selection is what a commit resolves. Re-pointing it at the focused display would
        // silently commit a different window than the one under the selector.
        if spaceController.overlayMode == .stages,
           let focusedDisplay = overlayDisplay(
               focusedWindowFrame: spaceController.focusedWindowFrame,
               mainDisplayOnly: false
           ) {
            // Placement may be pinned, but switching still starts in the focused workspace.
            spaceController.selectSpaceStack(forDisplayID: focusedDisplay.displayID)
        }
        overlayWindow.targetScreenFrame = display?.frame
        let createdHostingView = if spaceController.overlayMode == .altTab {
            overlayWindow.update(altTab: altTabViewModel(spaceController: spaceController))
        } else {
            overlayWindow.update(viewModel: stageViewModel(spaceController: spaceController))
        }
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
                "traceID": overlayPresentation.traceID.uuidString,
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
        let display = overlayDisplay(
            focusedWindowFrame: spaceController.focusedWindowFrame,
            mainDisplayOnly: currentSettings.overlayOnMainDisplayOnly
        )
        // Stack cycling deliberately keeps the overlay on its current screen; the header
        // changes to identify the remote display whose stages are being inspected.
        if spaceController.spaceManager.connectedSpaceStacks.count <= 1 {
            overlayWindow.targetScreenFrame = display?.frame
        }
        if spaceController.overlayMode == .altTab {
            overlayWindow.update(altTab: altTabViewModel(spaceController: spaceController))
            return
        }
        overlayWindow.update(viewModel: stageViewModel(spaceController: spaceController))
    }

    private func stageViewModel(spaceController: SpaceController) -> StageOverlayViewModel {
        var vm = StageOverlayViewModel(spaceManager: spaceController.overlaySpaceManager,
            activeSpaceIndex: spaceController.selectedSpaceIndex, selectedWindowIndex: spaceController.selectedWindowIndex,
            windowPreviews: spaceController.windowPreviews, windowSizes: spaceController.windowSizes,
            appearance: currentSettings, wallpaperLuminance: nil, forceDisplayStackIndicator: forceDisplayStackIndicator,
            keyboardWindowMoveAnimation: spaceController.keyboardWindowMoveAnimation,
            overlayKeyboardInteractionSequence: spaceController.overlayKeyboardInteractionSequence)
        vm.tutorialScope = spaceController.activeTutorialScope
        vm.tutorialCoachmark = spaceController.tutorialCoachmark
        return vm
    }

    private func altTabViewModel(spaceController: SpaceController) -> AltTabOverlayViewModel {
        var vm = AltTabOverlayViewModel(entries: spaceController.altTabEntries,
            selectedIndex: spaceController.altTabSelectionIndex, windowPreviews: spaceController.windowPreviews,
            windowSizes: spaceController.windowSizes, appearance: currentSettings,
            overlayKeyboardInteractionSequence: spaceController.overlayKeyboardInteractionSequence)
        vm.tutorialScope = spaceController.activeTutorialScope
        vm.tutorialCoachmark = spaceController.tutorialCoachmark
        return vm
    }

    /// The screen the stages belong on: the focused window’s display, or the system primary
    /// display when the user pins the overlay there. Accessibility
    /// reports that window in Quartz coordinates, so the displays are matched in that space and
    /// only the winner is translated back into Cocoa's.
    private func overlayDisplay(
        focusedWindowFrame: CGRect?,
        mainDisplayOnly: Bool
    ) -> (displayID: CGDirectDisplayID, frame: CGRect)? {
        let displays = NSScreen.screens.map {
            DesktopScreenDescriptor(displayID: $0.displayID, frame: CGDisplayBounds($0.displayID))
        }
        guard let displayID = OverlayDisplayResolver.resolve(
            focusedWindowFrame: focusedWindowFrame,
            displays: displays,
            // NSScreen.main follows the key window, so pinning must use the system primary.
            mainDisplayID: mainDisplayOnly ? CGMainDisplayID() : NSScreen.main?.displayID,
            mainDisplayOnly: mainDisplayOnly
        ), let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else { return nil }
        return (displayID, screen.overlayFrame)
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            DebutGlyph.installMenuBarIcon(in: button)
        }

        statusItem?.menu = Self.makeStatusMenu(target: self)
        updateFeatureMenu()
    }

    static func makeStatusMenu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        let featureMenu = NSMenu(title: "Features")
        for (index, title) in Self.featureMenuTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(toggleFeature(_:)), keyEquivalent: "")
            item.tag = 100 + index
            item.target = target
            if index == 3 { featureMenu.addItem(.separator()) }
            featureMenu.addItem(item)
        }
        let featuresItem = NSMenuItem(title: "Features", action: nil, keyEquivalent: "")
        featuresItem.submenu = featureMenu
        menu.addItem(featuresItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Setup...", action: #selector(openSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Tutorial...", action: #selector(openTutorial), keyEquivalent: ""))
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = target
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Debut", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    static let featureMenuTitles = ["Window previews", "Workspace Command–Tab", "Option–Tab", "Faster desktop transitions", "Numbered space shortcuts", "Control-arrow switching", "Trackpad desktop swipe"]
    private static let featureKeyPaths: [WritableKeyPath<FeatureSettings, Bool>] = [
        \.windowPreviews, \.workspaceIsolation, \.optionTab, \.fasterDesktopSwitching,
        \.numberShortcuts, \.controlArrows, \.trackpadSwipes,
    ]

    private func updateFeatureMenu() {
        for (index, keyPath) in Self.featureKeyPaths.enumerated() {
            let item = statusItem?.menu?.item(withTitle: "Features")?.submenu?
                .item(withTag: 100 + index)
            item?.state = currentSettings.features[keyPath: keyPath] ? .on : .off
            if index >= 4 {
                item?.isEnabled = currentSettings.features.fasterDesktopSwitching
            }
        }
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        let index = sender.tag - 100
        guard Self.featureKeyPaths.indices.contains(index) else { return }
        var features = currentSettings.features
        features[keyPath: Self.featureKeyPaths[index]].toggle()
        applyFeatures(features)
    }

    /// As a regular application Debut owns the menu bar while it is frontmost, and an app with
    /// no main menu leaves the user without Quit, Close, or their key equivalents.
    static func makeMainMenu(target: AnyObject?) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About Debut",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        for item in [
            NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","),
            NSMenuItem(title: "Tutorial...", action: #selector(openTutorial), keyEquivalent: ""),
            NSMenuItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdates(_:)),
                keyEquivalent: ""
            ),
        ] {
            item.target = target
            appMenu.addItem(item)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide Debut",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        appMenu.addItem(NSMenuItem(
            title: "Quit Debut",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }

    @objc private func openSettings() {
        let settings = (try? stateStore?.loadSettings()) ?? AppSettings()
        showSettings(settings: settings)
    }

    @objc private func openSetup() {
        showOnboarding()
    }

    @objc private func openTutorial() {
        if OnboardingLaunchPolicy.hasCompleted() { showTutorial() }
        else { showOnboarding() }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        applicationUpdater.checkForUpdates()
    }

    private func showTutorial() {
        if tutorialWindowNeedsReplacement, let model = tutorialViewModel {
            // A closed AppKit window can reuse its CG ID, which discovery correctly retired.
            // Give the resumed lesson a new window instead of reviving a destroyed identity.
            tutorialWindow = makeTutorialWindow(model)
            tutorialWindowNeedsReplacement = false
            tutorialWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let tutorialWindow { admitSettingsWindowToSpaceManager(tutorialWindow) }
            restartTutorialExercise()
            refreshTutorialEnvironment()
            return
        }
        if let tutorialWindow {
            tutorialWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            admitSettingsWindowToSpaceManager(tutorialWindow)
            refreshTutorialEnvironment()
            return
        }

        let checkpoint = UserDefaults.standard.data(forKey: "tutorialCheckpoint")
            .flatMap { try? JSONDecoder().decode(TutorialCheckpoint.self, from: $0) }
        let viewModel = TutorialViewModel(
            permissionClient: onboardingPermissionClient,
            features: currentSettings.features,
            onPermissionStateChanged: { [weak self] state in
                self?.handlePermissionStateChange(state, source: "tutorial")
            },
            checkpoint: checkpoint,
            onProgressChanged: { progress in
                if let data = try? JSONEncoder().encode(progress) {
                    UserDefaults.standard.set(data, forKey: "tutorialCheckpoint")
                }
            },
            onCompleted: { [weak self] in self?.completeTutorial() }
        )
        viewModel.onEnvironmentRefresh = { [weak self] in self?.refreshTutorialEnvironment() }
        viewModel.onRestartExercise = { [weak self] in self?.restartTutorialExercise() }
        let window = makeTutorialWindow(viewModel)
        tutorialWindowNeedsReplacement = false

        tutorialViewModel = viewModel
        tutorialWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshTutorialEnvironment()
        admitSettingsWindowToSpaceManager(window)
        prepareTutorialTarget()
        diag.report("tutorial_shown")
    }

    private func makeTutorialWindow(_ viewModel: TutorialViewModel) -> NSWindow {
        tutorialWindowAwaitingPlacement = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        if let screen = NSScreen.main {
            let titleBarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            window.setContentSize(NSSize(width: 820, height: OnboardingLayout.contentHeight(
                visibleHeight: screen.visibleFrame.height, titleBarHeight: titleBarHeight)))
        }
        window.title = "Debut Tutorial"
        window.collectionBehavior = []
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: tutorialContent(viewModel))
        window.center()
        return window
    }

    private func refreshTutorialEnvironment() {
        refreshOnboardingEnvironment()
        guard let tutorialViewModel else { return }
        spaceController?.reconcileSpacesWithDesktops()
        tutorialViewModel.updateEnvironment(
            desktopCount: spaceController?.spaceManager.spaces.count ?? 1,
            windowCount: spaceController?.spaceManager.activeSpace.windows.count ?? 0)
        prepareTutorialTarget()
    }

    private func restartTutorialExercise() {
        spaceController?.tutorialScope = nil
        tutorialGeneration += 1
        pendingTutorialTarget = nil
        preparingTutorialTarget = false
        tutorialTargetWindow?.close()
        tutorialTargetWindow = nil
        tutorialViewModel?.setTarget(nil)
        prepareTutorialTarget()
    }

    private func prepareTutorialTarget() {
        guard !tutorialWindowNeedsReplacement, !preparingTutorialTarget, pendingTutorialTarget == nil, let model = tutorialViewModel,
              let tutorial = tutorialWindow, let service = spaceService,
              model.permissions.accessibilityGranted, model.shortcutEnabled, model.desktopCount >= 1,
              model.page == .workspace || model.page == .previews else { return }
        if let target = model.target, tutorialTargetWindow != nil {
            configureTutorialScope(target)
            return
        }
        tutorialTargetWindow?.close()
        tutorialTargetWindow = nil
        guard let origin = service.desktopIndex(forWindow: CGWindowID(tutorial.windowNumber)) else {
            if !tutorialWindowAwaitingPlacement {
                model.targetError = "The tutorial is not on a regular desktop. Move it to a desktop, then restart this exercise."
            }
            return
        }
        tutorialWindowAwaitingPlacement = false
        let adjacent = model.desktopCount == 1 ? origin : (origin + 1 < model.desktopCount ? origin + 1 : origin - 1)
        let title: String
        let placement: Int
        let destination: Int
        if model.page == .previews {
            title = "Tutorial complete"
            placement = adjacent
            destination = adjacent
        } else {
            switch model.exercise {
            case .switchWindow:
                title = model.desktopCount == 1 ? "Window previews" : "Desktop switching"
                placement = origin
                destination = origin
            case .switchDesktop:
                title = "Move a window"
                placement = adjacent
                destination = adjacent
            case .moveWindow:
                title = "Window previews"
                placement = origin
                destination = adjacent
            }
        }
        preparingTutorialTarget = true
        tutorialGeneration += 1
        let generation = tutorialGeneration
        let target = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 390),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        target.title = title
        target.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: OnboardingDestinationView(title: title, onReturn: { [weak self] in
            guard let self else { return }
            if self.tutorialWindowNeedsReplacement {
                self.showTutorial()
                return
            }
            guard let tutorial = self.tutorialWindow else { return }
            if let controller = self.spaceController,
               let spaceID = controller.spaceManager.spaceContainingWindow(windowID: CGWindowID(tutorial.windowNumber)) {
                controller.switchToSpace(id: spaceID, raiseWindowID: CGWindowID(tutorial.windowNumber))
            }
            tutorial.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 390)
        target.contentView = hosting
        target.center()
        target.orderBack(nil)
        tutorial.makeKeyAndOrderFront(nil)
        tutorialTargetWindow = target
        let windowID = CGWindowID(target.windowNumber)
        configureTutorialScope(.init(windowID: windowID, originDesktop: origin,
                                     destinationDesktop: destination, title: title))
        let finish: @Sendable (Bool) -> Void = { [weak self] moved in
            DispatchQueue.main.async {
                guard let self, self.tutorialGeneration == generation,
                      self.tutorialTargetWindow === target else { return }
                self.preparingTutorialTarget = false
                guard moved, service.desktopIndex(forWindow: windowID) == placement else {
                    self.spaceController?.tutorialScope = nil
                    target.close()
                    self.tutorialTargetWindow = nil
                    model.targetError = "The tutorial target could not be placed on the desktop. Restart this exercise to try again."
                    return
                }
                self.admitSettingsWindowToSpaceManager(target)
                self.pendingTutorialTarget = .init(windowID: windowID, originDesktop: origin,
                                                   destinationDesktop: destination, title: title)
                self.publishTutorialTargetIfDiscovered()
            }
        }
        if service.desktopIndex(forWindow: windowID) == placement { finish(true) }
        else { service.moveWindow(windowID: windowID, toDesktop: placement, completion: finish) }
    }

    private func configureTutorialScope(_ target: OnboardingTarget) {
        guard let lesson = tutorialWindow, let model = tutorialViewModel else { return }
        let practice: OnboardingPractice = model.page == .previews ? .allWindows
            : model.exercise == .switchWindow ? .workspace : model.exercise == .switchDesktop ? .desktop : .moveWindow
        spaceController?.tutorialScope = .init(lessonWindowID: CGWindowID(lesson.windowNumber), target: target, practice: practice)
    }

    private func publishTutorialTargetIfDiscovered() {
        guard let target = pendingTutorialTarget, let model = tutorialViewModel,
              let window = tutorialTargetWindow, CGWindowID(window.windowNumber) == target.windowID,
              spaceController?.spaceManager.allSpaces.contains(where: { space in
                  space.windows.contains { $0.windowID == target.windowID }
              }) == true else { return }
        pendingTutorialTarget = nil
        model.setTarget(target)
        configureTutorialScope(target)
        diag.report("onboarding_target_created", details: [
            "windowID": "\(target.windowID)", "title": target.title,
            "placementDesktop": "\(spaceService?.desktopIndex(forWindow: target.windowID) ?? -1)",
            "destinationDesktop": "\(target.destinationDesktop)",
            "lessonWindowID": "\(tutorialWindow?.windowNumber ?? -1)",
            "originDesktop": "\(target.originDesktop)",
            "exercise": model.exercise.rawValue, "page": "\(model.page)",
            "currentDesktop": "\(spaceService?.currentDesktopIndex() ?? -1)",
            "keyWindowID": "\(NSApp.keyWindow?.windowNumber ?? -1)",
        ])
    }

    private func completeTutorialSelection(windowID: CGWindowID, practice: OnboardingPractice) {
        if let target = tutorialTargetWindow, CGWindowID(target.windowNumber) == windowID {
            diag.report("onboarding_selection_checked", details: [
                "practice": "\(practice)", "windowID": "\(windowID)",
                "keyWindowID": "\(NSApp.keyWindow?.windowNumber ?? -1)",
                "desktop": "\(spaceService?.currentDesktopIndex() ?? -1)",
            ])
        }
        guard let model = tutorialViewModel, let target = tutorialTargetWindow,
              CGWindowID(target.windowNumber) == windowID,
              NSApp.keyWindow === target,
              let desktop = spaceService?.desktopIndex(forWindow: windowID),
              spaceService?.currentDesktopIndex() == desktop,
              model.recordPractice(practice, windowID: windowID, desktopIndex: desktop) else { return }
        spaceController?.tutorialScope = nil
        let previous = tutorialWindow
        tutorialWindow = target
        tutorialTargetWindow = nil
        target.title = "Debut Tutorial"
        target.setContentSize(NSSize(width: 820, height: 650))
        target.contentView = NSHostingView(rootView: tutorialContent(model))
        target.center()
        target.makeKeyAndOrderFront(nil)
        previous?.close()
        admitSettingsWindowToSpaceManager(target)
        diag.report("onboarding_practice_verified", details: [
            "practice": "\(practice)", "windowID": "\(windowID)", "desktop": "\(desktop)",
        ])
        refreshTutorialEnvironment()
    }

    private func tutorialContent(_ model: TutorialViewModel) -> TutorialView {
        TutorialView(viewModel: model, onExit: { [weak self] in self?.endTutorial() },
            onOpenSettings: { [weak self] in self?.openSettings() })
    }

    private func completeTutorial() {
        UserDefaults.standard.removeObject(forKey: "tutorialCheckpoint")
        endTutorial()
        diag.report("tutorial_completed")
    }

    private func endTutorial() {
        tutorialGeneration += 1
        pendingTutorialTarget = nil
        preparingTutorialTarget = false
        if spaceController?.activeTutorialScope != nil { spaceController?.handleKeyEvent(.escape) }
        spaceController?.tutorialScope = nil
        let lesson = tutorialWindow
        let target = tutorialTargetWindow
        tutorialWindow = nil
        tutorialTargetWindow = nil
        tutorialViewModel = nil
        tutorialWindowNeedsReplacement = false
        tutorialWindowAwaitingPlacement = false
        lesson?.close()
        target?.close()
    }

    private func showOnboarding(restoring pendingPage: OnboardingPage? = nil) {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshOnboardingEnvironment()
            return
        }
        // Separate setup storage intentionally ignores the old exercise-based checkpoint.
        let checkpoint = pendingPage.map(OnboardingCheckpoint.init(page:))
            ?? UserDefaults.standard.data(forKey: "setupCheckpoint")
                .flatMap { try? JSONDecoder().decode(OnboardingCheckpoint.self, from: $0) }
        let model = OnboardingViewModel(permissionClient: onboardingPermissionClient,
            features: currentSettings.features,
            spaceSwitchDuration: currentSettings.spaceSwitchDuration,
            onSpaceSwitchDurationChanged: { [weak self] duration in
                guard let self else { return }
                var settings = self.currentSettings
                settings.spaceSwitchDuration = duration
                self.applySettings(settings)
            },
            onFeaturesChanged: { [weak self] in self?.applyFeatures($0) },
            onPermissionStateChanged: { [weak self] in self?.handlePermissionStateChange($0, source: "onboarding") },
            onPermissionRequestWillStart: { [weak self] permission, page in
                guard let self,
                      let checkpointData = try? JSONEncoder().encode(OnboardingCheckpoint(page: page)) else {
                    return false
                }
                let defaults = UserDefaults.standard
                defaults.set(checkpointData, forKey: "setupCheckpoint")
                guard defaults.synchronize(), OnboardingPermissionReturnStore.save(
                    permission: permission,
                    page: page,
                    processID: self.onboardingProcessID
                ) else {
                    self.diag.report("onboarding_permission_handoff_persistence_failed")
                    return false
                }
                return true
            },
            onPermissionRequestDidStart: { [weak self] permission in
                self?.presentPermissionGuide(permission)
            },
            onPermissionHandoffCancelled: { [weak self] permission in
                guard let self else { return }
                if permission != .screenRecording
                    || !self.onboardingPermissionClient.currentState().screenRecordingGranted {
                    OnboardingPermissionReturnStore.clear()
                }
                self.onboardingPermissionGuide.dismiss()
            },
            onRestartDebut: { [weak self] in self?.onboardingPermissionClient.restartDebut() },
            checkpoint: checkpoint,
            onProgressChanged: { [weak self] progress in
                if let pending = OnboardingPermissionReturnStore.pending(),
                   pending.page != progress.page,
                   self?.onboardingViewModel?.screenRecordingRequiresRelaunch != true {
                    OnboardingPermissionReturnStore.clear()
                }
                if let data = try? JSONEncoder().encode(progress) {
                    UserDefaults.standard.set(data, forKey: "setupCheckpoint")
                    _ = UserDefaults.standard.synchronize()
                }
            },
            onCompleted: { [weak self] in self?.completeOnboarding() },
            onDestination: { [weak self] destination in
                switch destination {
                case .tutorial: self?.showTutorial()
                case .settings: self?.openSettings()
                case .useDebut: self?.showMenuBarCoachmark()
                }
            })
        model.onEnvironmentRefresh = { [weak self] in self?.refreshOnboardingEnvironment() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        if let screen = NSScreen.main {
            let titleBarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            window.setContentSize(NSSize(width: 820, height: OnboardingLayout.contentHeight(
                visibleHeight: screen.visibleFrame.height, titleBarHeight: titleBarHeight)))
        }
        window.title = "Welcome to Debut"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(viewModel: model))
        window.delegate = self
        onboardingWindow = window
        onboardingViewModel = model
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if OnboardingPermissionReturnStore.pending() != nil {
            OnboardingPermissionReturnStore.clear()
            diag.report("onboarding_permission_handoff_restored", details: [
                "page": "\(model.page.rawValue)",
            ])
        } else if let checkpoint = try? JSONEncoder().encode(OnboardingCheckpoint(page: model.page)) {
            UserDefaults.standard.set(checkpoint, forKey: "setupCheckpoint")
            _ = UserDefaults.standard.synchronize()
        }
        refreshOnboardingEnvironment()
        diag.report("onboarding_shown", details: ["forced": "\(ProcessInfo.processInfo.arguments.contains("--show-onboarding"))"])
    }

    private func presentPermissionGuide(_ permission: OnboardingPermission) {
        onboardingPermissionGuide.present(
            permission: permission,
            onReturn: { [weak self] in
                guard let self else { return }
                self.onboardingViewModel?.refreshPermissions()
                if self.onboardingViewModel?.screenRecordingRequiresRelaunch != true {
                    OnboardingPermissionReturnStore.clear()
                }
                self.onboardingWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            },
            onCancel: { [weak self] permission in
                self?.onboardingViewModel?.cancelPermissionHandoff(permission)
            }
        )
    }

    private func refreshOnboardingEnvironment() {
        guard onboardingViewModel != nil else { return }
        // Count every connected stack; do not mistake one desktop on the focused display
        // for a device with only one desktop. Exclude disconnected recovery stacks.
        let count = spaceService?.spaceTopology().stacks.reduce(0) { $0 + $1.desktopIDs.count }
        if let count { onboardingViewModel?.updateEnvironment(desktopCount: count) }
    }

    private func completeOnboarding() {
        OnboardingLaunchPolicy.markCompleted()
        OnboardingPermissionReturnStore.clear()
        UserDefaults.standard.removeObject(forKey: "setupCheckpoint")
        UserDefaults.standard.removeObject(forKey: "onboardingCheckpoint")
        // Exiting the tutorial keeps a checkpoint to resume from, but finishing setup starts the
        // tutorial over: its destination button promises the first lesson, not someone else's place.
        UserDefaults.standard.removeObject(forKey: "tutorialCheckpoint")
        let window = onboardingWindow
        onboardingWindow = nil
        onboardingViewModel = nil
        window?.close()
        diag.report("onboarding_completed")
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

    private func applySettings(_ incomingSettings: AppSettings) {
        let newSettings = incomingSettings
        self.launchAtLogin.apply(enabled: newSettings.launchAtLogin)
        self.activationPolicy.apply(showsDockIcon: newSettings.showsDockIcon)
        self.currentSettings = newSettings
        if !newSettings.showsDesktopSwitchIndicator {
            desktopSwitchIndicatorWindows.values.forEach { $0.hideImmediately() }
        }
        try? self.stateStore?.saveSettings(newSettings)
        self.windowDiscovery?.excludedBundleIDs = Set(newSettings.excludedBundleIDs)
        self.keyboardService?.excludedBundleIDs = Set(newSettings.excludedBundleIDs)
        self.spaceController?.excludedBundleIDs = Set(newSettings.excludedBundleIDs)
        self.spaceController?.updateFrontmostApp(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
        self.spaceController?.fasterDesktopSwitchingEnabled =
            newSettings.features.fasterDesktopSwitching
        self.keyboardService?.quickSwitchModifiers = newSettings.quickSwitchModifiers
        self.keyboardService?.quickSwitchSameApplicationModifiers =
            newSettings.quickSwitchSameApplicationModifiers
        self.keyboardService?.heldCycleMinimumInterval =
            newSettings.heldCycleMinimumInterval
        if desktopSwipeService?.setEnabled(newSettings.features.effectiveTrackpadSwipes) == false {
            diag.report("desktop_swipe_tap_failed")
        }
        keyboardService?.features = newSettings.features
        spaceController?.windowPreviewsEnabled = OnboardingCapturePolicy.isEnabled(
            previewsRequested: newSettings.features.windowPreviews,
            screenRecordingGranted: onboardingPermissionClient.currentState().screenRecordingGranted
                && onboardingViewModel?.screenRecordingRequiresRelaunch != true)
        let tutorialShortcutWasEnabled = tutorialViewModel?.shortcutEnabled
        tutorialViewModel?.features = newSettings.features
        onboardingViewModel?.features = newSettings.features
        onboardingViewModel?.spaceSwitchDuration = newSettings.spaceSwitchDuration
        if tutorialShortcutWasEnabled != tutorialViewModel?.shortcutEnabled { restartTutorialExercise() }
        else { prepareTutorialTarget() }
        NotificationCenter.default.post(name: .debutSettingsChanged, object: newSettings)
        updateFeatureMenu()
    }

    private func applyFeatures(_ features: FeatureSettings) {
        var settings = currentSettings
        settings.features = features
        applySettings(settings)
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
                self.applySettings(newSettings)
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
        admitSettingsWindowToSpaceManager(window)

        diag.report("settings_shown", details: [
            "fullSizeContentView": "\(window.styleMask.contains(.fullSizeContentView))",
            "titleHidden": "\(window.titleVisibility == .hidden)",
            "titlebarTransparent": "\(window.titlebarAppearsTransparent)",
            "titlebarSeparatorHidden": "\(window.titlebarSeparatorStyle == .none)",
        ])

        self.settingsWindow = window
    }

    /// Only Settings and tutorial windows are admitted to Debut's own switchers.
    /// Consent is withdrawn on close so the closed window's surface cannot be re-admitted.
    ///
    /// Debut's own activation is deliberately not an app activation, so the window is discovered
    /// the way a launched app's windows are rather than waiting for an unrelated reconcile.
    private func admitSettingsWindowToSpaceManager(_ window: NSWindow) {
        window.delegate = self
        windowService?.setOwnWindowConsent(true, windowID: CGWindowID(window.windowNumber))
        windowDiscovery?.handleAppLaunch(AppInfo(
            bundleID: "com.thomplth.Debut",
            name: "Debut",
            pid: ProcessInfo.processInfo.processIdentifier,
            isHidden: false
        ))
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            onboardingWindow = nil
            onboardingViewModel = nil
        }
        if window === tutorialWindow {
            tutorialWindowNeedsReplacement = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.tutorialWindow === window else { return }
                self.endTutorial()
            }
        }
        if window === tutorialTargetWindow || window === tutorialWindow { spaceController?.tutorialScope = nil }
        if window === tutorialTargetWindow {
            tutorialTargetWindow = nil
            tutorialViewModel?.setTarget(nil)
            tutorialViewModel?.targetError = "The next lesson window was closed. Restart the exercise to reopen it."
        }
        windowService?.setOwnWindowConsent(false, windowID: CGWindowID(window.windowNumber))
        windowDiscovery?.onWindowClosed?(CGWindowID(window.windowNumber))
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
                if let ownerPID = firstWindow.ownerPID {
                    _ = controller.windowService.activateApp(pid: ownerPID)
                } else {
                    _ = controller.windowService.activateApp(bundleID: firstWindow.ownerBundleID)
                }
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

}

func formatOverlayPoint(_ point: CGPoint) -> String {
    String(format: "%.1f,%.1f", point.x, point.y)
}
