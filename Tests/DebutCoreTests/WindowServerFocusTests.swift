import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

final class MockWindowServerEvents: WindowServerWindowEventSource, @unchecked Sendable {
    var accepted = WindowServerWindowEvent.allCases
    var onScreen: Set<CGWindowID> = []
    private(set) var handler: Handler?
    private(set) var watched: Set<CGWindowID> = []

    func start(handler: @escaping Handler) -> [WindowServerWindowEvent] {
        self.handler = handler
        return accepted
    }

    func watch(_ windowIDs: Set<CGWindowID>) {
        watched = windowIDs
    }

    func onScreenWindowIDs() -> Set<CGWindowID> {
        onScreen
    }

    func send(_ event: WindowServerWindowEvent, _ windowID: CGWindowID, at time: TimeInterval) {
        handler?(event, windowID, time)
    }
}

final class UptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }

    func read() -> TimeInterval {
        lock.withLock { value }
    }

    func write(_ value: TimeInterval) {
        lock.withLock { self.value = value }
    }
}

@Suite("Window-server focus")
struct WindowServerFocusTests {
    private let dia = AppInfo(bundleID: "company.thebrowser.dia", name: "Dia", pid: 4433, isHidden: false)
    private let orca = AppInfo(bundleID: "com.stablyai.orca", name: "Orca", pid: 31138, isHidden: false)
    private let develop: CGWindowID = 59667
    private let debutTab: CGWindowID = 86144
    private let orcaWindow: CGWindowID = 81160

    private struct Harness {
        let service: WindowDiscoveryService
        let events: MockWindowServerEvents
        let probe: DeferredFocusProbe
        let frontmost: FrontmostPIDBox
        let uptime: UptimeBox
        let reporter: DiagnosticReporter
        let directory: URL
        let activated: Activations

        func diagnostics() -> [[String: String]] {
            reporter.flush()
            let url = directory.appendingPathComponent("diagnostic.jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
            }
        }
    }

    final class Activations: @unchecked Sendable {
        var windowIDs: [CGWindowID] = []
    }

    private func makeHarness(
        accepted: [WindowServerWindowEvent] = WindowServerWindowEvent.allCases,
        onScreen: Set<CGWindowID> = []
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutWindowServerFocusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reporter = DiagnosticReporter(directory: directory)
        let windowService = MockWindowService()
        windowService.apps = [dia, orca]
        windowService.windowList = [
            window(develop, of: dia),
            window(debutTab, of: dia),
            window(orcaWindow, of: orca),
        ]
        let events = MockWindowServerEvents()
        events.accepted = accepted
        events.onScreen = onScreen
        let probe = DeferredFocusProbe()
        let frontmost = FrontmostPIDBox(orca.pid)
        let uptime = UptimeBox(100)
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusProbeScheduler: probe.schedule,
            frontmostPIDProvider: frontmost.read,
            processExitMonitor: MockProcessExitMonitor(),
            windowServerEvents: events,
            uptime: uptime.read,
            diagnosticReporter: reporter
        )
        service.armingOverride = { _, _ in .armed }
        service.windowElementOverride = { _, _ in nil }
        let activated = Activations()
        service.onWindowActivated = { windowID, _ in activated.windowIDs.append(windowID) }
        service.startWindowServerFocus()
        service.registerTracking(windowID: develop, pid: dia.pid)
        service.registerTracking(windowID: debutTab, pid: dia.pid)
        service.registerTracking(windowID: orcaWindow, pid: orca.pid)
        return Harness(
            service: service,
            events: events,
            probe: probe,
            frontmost: frontmost,
            uptime: uptime,
            reporter: reporter,
            directory: directory,
            activated: activated
        )
    }

    private func window(_ windowID: CGWindowID, of app: AppInfo) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            ownerBundleID: app.bundleID,
            ownerName: app.name,
            ownerPID: app.pid,
            title: "Window \(windowID)",
            bounds: .zero,
            isOnScreen: true
        )
    }

    private func activate(_ app: AppInfo, in harness: Harness, at time: TimeInterval) {
        harness.uptime.write(time)
        harness.frontmost.write(app.pid)
        harness.service.handleAppActivation(app)
    }

    @Test("A focus change inside the frontmost app is credited when the app never answers its AX read")
    func inAppFocusChangeIsCreditedWithoutAX() throws {
        let harness = try makeHarness()
        harness.frontmost.write(dia.pid)

        harness.events.send(.windowFocused, develop, at: 200)

        #expect(harness.activated.windowIDs == [develop])
    }

    @Test("An outside activation records its window from the window server while its probe is still out")
    func outsideActivationIsAnsweredByTheWindowServer() throws {
        let harness = try makeHarness()

        activate(dia, in: harness, at: 200)
        harness.events.send(.windowFocused, develop, at: 200.07)

        #expect(harness.activated.windowIDs == [develop])
    }

    @Test("The windows an outside activation raises after its focus are not credited")
    func activationRaisesAreNotCredited() throws {
        let harness = try makeHarness()

        activate(dia, in: harness, at: 200)
        harness.events.send(.windowFocused, develop, at: 200.07)
        harness.events.send(.windowFocused, debutTab, at: 200.18)

        #expect(harness.activated.windowIDs == [develop])
    }

    @Test("The activation probe's late answer yields to the window server's")
    func activationProbeYieldsToTheWindowServer() throws {
        let harness = try makeHarness()

        activate(dia, in: harness, at: 200)
        harness.events.send(.windowFocused, develop, at: 200.07)
        harness.probe.resolve(pid: dia.pid, windowID: debutTab)

        #expect(harness.activated.windowIDs == [develop])
        let yielded = try #require(harness.diagnostics().first { $0["event"] == "app_activation_probe_yielded" })
        #expect(yielded["probedWindowID"] == "\(debutTab)")
        #expect(yielded["focusWindowID"] == "\(develop)")
    }

    @Test("A focus event that beats its app's activation notification answers that activation")
    func focusBeforeActivationAnswersIt() throws {
        let harness = try makeHarness()

        harness.events.send(.windowFocused, develop, at: 200)
        activate(dia, in: harness, at: 200.05)

        #expect(harness.activated.windowIDs == [develop])
    }

    @Test("An activation superseded before anything names its window is reported unanswered")
    func supersededUnansweredActivationIsReported() throws {
        let harness = try makeHarness()

        activate(dia, in: harness, at: 200)
        activate(orca, in: harness, at: 201.9)

        let unanswered = try #require(harness.diagnostics().first { $0["event"] == "app_activation_unanswered" })
        #expect(unanswered["ownerPID"] == "\(dia.pid)")
        #expect(unanswered["supersededBy"] == orca.bundleID)
    }

    @Test("An activation the window server answered is not reported unanswered when superseded")
    func answeredActivationIsNotReported() throws {
        let harness = try makeHarness()

        activate(dia, in: harness, at: 200)
        harness.events.send(.windowFocused, develop, at: 200.07)
        activate(orca, in: harness, at: 201.9)

        #expect(!harness.diagnostics().contains { $0["event"] == "app_activation_unanswered" })
    }

    @Test("Every 808 decision is kept in the diagnostic log with its verdict")
    func focusDecisionsAreLogged() throws {
        let harness = try makeHarness()

        activate(dia, in: harness, at: 200)
        harness.events.send(.windowFocused, develop, at: 200.07)
        harness.events.send(.windowFocused, debutTab, at: 200.18)

        let verdicts = harness.diagnostics().filter { $0["event"] == "window_server_focus" }
            .map { "\($0["windowID"] ?? ""):\($0["verdict"] ?? "")" }
        #expect(verdicts == ["\(develop):credited", "\(debutTab):activation_raise"])
    }

    @Test("A raise of a window already on screen in the frontmost app is credited")
    func inAppRaiseIsCredited() throws {
        let harness = try makeHarness(onScreen: [develop, debutTab])
        harness.frontmost.write(dia.pid)
        harness.events.send(.windowOrderedIn, develop, at: 200)

        harness.events.send(.windowOrderedIn, debutTab, at: 201)

        #expect(harness.activated.windowIDs == [develop, debutTab])
    }

    @Test("A window coming back on screen with its desktop is not a raise")
    func returningWindowIsNotCredited() throws {
        let harness = try makeHarness()
        harness.frontmost.write(dia.pid)

        harness.events.send(.windowOrderedIn, develop, at: 200)

        #expect(harness.activated.windowIDs.isEmpty)
    }

    @Test("Every tracked window is watched, and a closed one stops being watched")
    func trackedWindowsAreWatched() throws {
        let harness = try makeHarness()
        #expect(harness.events.watched == [develop, debutTab, orcaWindow])

        harness.service.handleProcessExit(pid: orca.pid)

        #expect(harness.events.watched == [develop, debutTab])
    }

    @Test("The AX focus observer stays off while the window server reports focus")
    func axFocusObserverStaysOff() throws {
        let harness = try makeHarness()
        var registrations: [pid_t] = []
        harness.service.focusObserverRegistrationOverride = { pid in
            registrations.append(pid)
            return .success
        }

        harness.service.installFocusObserver(for: dia.pid, bundleID: dia.bundleID)

        #expect(registrations.isEmpty)
        #expect(harness.service.isWindowServerFocusActive)
    }

    @Test("The AX focus observer returns when the window server never reports focus")
    func axFocusObserverReturnsWhenTheWindowServerIsSilent() throws {
        let harness = try makeHarness()
        var registrations: [pid_t] = []
        harness.service.focusObserverRegistrationOverride = { pid in
            registrations.append(pid)
            return .success
        }

        for step in 0..<WindowDiscoveryService.silentWindowServerFocusActivationLimit {
            let app = step.isMultiple(of: 2) ? dia : orca
            activate(app, in: harness, at: 200 + Double(step))
        }
        harness.service.installFocusObserver(for: dia.pid, bundleID: dia.bundleID)

        #expect(registrations == [dia.pid])
        #expect(harness.diagnostics().contains { $0["event"] == "window_server_focus_silent" })
    }

    @Test("The AX focus observer stays on when SkyLight does not accept the focus event")
    func axFocusObserverStaysOnWithoutTheFocusEvent() throws {
        let harness = try makeHarness(accepted: [.windowOrderedIn, .windowOrderedOut])
        var registrations: [pid_t] = []
        harness.service.focusObserverRegistrationOverride = { pid in
            registrations.append(pid)
            return .success
        }

        harness.service.installFocusObserver(for: dia.pid, bundleID: dia.bundleID)

        #expect(registrations == [dia.pid])
        #expect(!harness.service.isWindowServerFocusActive)
    }

    @Test("A focus change names the window its AX notification carried when the app's focus read times out")
    func axFocusChangeUsesTheNotifiedWindow() {
        let windowService = MockWindowService()
        windowService.apps = [dia]
        windowService.windowList = [window(develop, of: dia), window(debutTab, of: dia)]
        let probe = DeferredFocusProbe()
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusProbeScheduler: probe.schedule,
            processExitMonitor: MockProcessExitMonitor()
        )
        service.focusObserverRegistrationOverride = { _ in .success }
        service.notifiedWindowIDReader = { [develop] _ in develop }
        var activated: [CGWindowID] = []
        service.onWindowActivated = { windowID, _ in activated.append(windowID) }
        service.installFocusObserver(for: dia.pid, bundleID: dia.bundleID)

        service.handleFocusChanged(notifiedWindow: AXUIElementCreateApplication(dia.pid))

        #expect(activated == [develop])
    }

    @Test("A focus change whose notified window cannot be read falls back to the app's focused window")
    func axFocusChangeFallsBackToTheFocusRead() {
        let windowService = MockWindowService()
        windowService.apps = [dia]
        windowService.windowList = [window(develop, of: dia), window(debutTab, of: dia)]
        let probe = DeferredFocusProbe()
        let service = WindowDiscoveryService(
            windowService: windowService,
            focusProbeScheduler: probe.schedule,
            processExitMonitor: MockProcessExitMonitor()
        )
        service.focusObserverRegistrationOverride = { _ in .success }
        service.notifiedWindowIDReader = { _ in nil }
        var activated: [CGWindowID] = []
        service.onWindowActivated = { windowID, _ in activated.append(windowID) }
        service.installFocusObserver(for: dia.pid, bundleID: dia.bundleID)

        service.handleFocusChanged(notifiedWindow: AXUIElementCreateApplication(dia.pid))
        probe.resolve(pid: dia.pid, windowID: debutTab)

        #expect(activated == [debutTab])
    }
}
