import AppKit
import CoreGraphics
import Foundation

/// Debut's own cumulative counters at one moment, plus the system's GPU energy.
struct HealthSample: Equatable, Sendable {
    var uptimeNanoseconds: UInt64
    var cpuNanoseconds: UInt64
    var energyNanojoules: UInt64
    /// System-wide, since Debut's drawing is composited and billed to WindowServer.
    var gpuNanojoules: UInt64?
    var footprintBytes: UInt64
    var peakFootprintBytes: UInt64
    var wakeups: UInt64
}

/// What the overlay trace measured for the reveal a session showed.
struct PresentedOverlayLatency: Equatable, Sendable {
    let pressToRevealMilliseconds: Double
    let holdDelayMilliseconds: Double
    let inputLatencyMilliseconds: Double?
}

/// Measures Debut against its absolute health goals (KHA-1139): what an hour of use or idle
/// costs, what one reveal costs and how smoothly it drew, how long a commit takes to put the
/// chosen window in front, and every main run-loop stall. Every line is `.retained`, so
/// `health.jsonl` alone can judge the goals over weeks; `scripts/health-report.py` does.
///
/// Development builds only. It is driven by user actions rather than a timer: an interval
/// closes at the first action after it ends, a quiet gap becomes its own idle interval, and
/// suspension or quitting closes whatever is open.
///
/// Main-queue confined, like the controller that drives it.
final class DevelopmentHealthRecorder: @unchecked Sendable {
    typealias Report = @Sendable (String, DiagnosticLevel, [String: String]) -> Void

    static let shared: DevelopmentHealthRecorder? = DevelopmentMeasurements.isEnabled
        ? DevelopmentHealthRecorder()
        : nil

    static let rollupInterval: TimeInterval = 3600
    /// Longer than any pause within one stretch of use, so a gap this long is time away.
    static let idleGap: TimeInterval = 600
    static let commitTimeout: TimeInterval = 3
    static let frontRecoveryWindow: TimeInterval = 1

    private struct Interval {
        let start: HealthSample
        var reveals = 0
        var desktopChanges = 0
        var focusChanges = 0
    }

    private struct Session {
        let start: HealthSample
        let traceID: UUID?
    }

    private struct PendingCommit {
        let generation: Int
        let windowID: CGWindowID
        let crossesDesktop: Bool
        let committedAt: UInt64
        var focusedAt: UInt64?
        var desktopChangedAt: UInt64?
    }

    private let report: Report
    private let sample: () -> HealthSample
    private let uptime: () -> UInt64
    private let processStartedAt: UInt64?
    private let presentedLatency: (UUID) -> PresentedOverlayLatency?
    private let frameCounter: (any OverlayFrameCounting)?
    private let schedule: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let rollupIntervalNanoseconds: UInt64
    private let idleGapNanoseconds: UInt64
    private var interval: Interval?
    private var lastAction: HealthSample?
    private var session: Session?
    private var lastFocusedWindowID: CGWindowID?
    private var pendingCommit: PendingCommit?
    private var commitGeneration = 0
    private var pendingFronts: [CGWindowID: UInt64] = [:]
    private var isSuspended = false
    private var stallObserver: MainRunLoopStallObserver?

    private convenience init() {
        let reader = OwnProcessHealthReader()
        let gpu = GPUEnergyReader()
        self.init(
            report: { DiagnosticReporter.shared.report($0, level: $1, details: $2) },
            sample: { reader.sample(gpuNanojoules: gpu?.cumulativeNanojoules()) },
            uptime: { DispatchTime.now().uptimeNanoseconds },
            processStartedAt: reader.processStartedAt(),
            presentedLatency: { traceID in
                OverlayPresentationRecorder.shared.snapshot().completed
                    .last { $0.traceID == traceID && $0.outcome == .presented }
                    .map {
                        PresentedOverlayLatency(
                            pressToRevealMilliseconds: $0.durationMilliseconds,
                            holdDelayMilliseconds: $0.configuredDelayMilliseconds,
                            inputLatencyMilliseconds: $0.inputLatencyMilliseconds
                        )
                    }
            },
            frameCounter: DisplayLinkFrameCounter(),
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        )
    }

    init(
        report: @escaping Report,
        sample: @escaping () -> HealthSample,
        uptime: @escaping () -> UInt64,
        processStartedAt: UInt64?,
        presentedLatency: @escaping (UUID) -> PresentedOverlayLatency?,
        frameCounter: (any OverlayFrameCounting)?,
        schedule: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void,
        rollupInterval: TimeInterval = DevelopmentHealthRecorder.rollupInterval,
        idleGap: TimeInterval = DevelopmentHealthRecorder.idleGap
    ) {
        self.report = report
        self.sample = sample
        self.uptime = uptime
        self.processStartedAt = processStartedAt
        self.presentedLatency = presentedLatency
        self.frameCounter = frameCounter
        self.schedule = schedule
        self.rollupIntervalNanoseconds = UInt64(rollupInterval * 1_000_000_000)
        self.idleGapNanoseconds = UInt64(idleGap * 1_000_000_000)
    }

    func startObservingMainRunLoop() {
        guard stallObserver == nil else { return }
        stallObserver = MainRunLoopStallObserver(thresholdMilliseconds: 100) { [weak self] milliseconds in
            self?.mainRunLoopStalled(milliseconds: milliseconds)
        }
    }

    func launchReady() {
        guard let processStartedAt else { return }
        report("launch_ready", .retained, [
            "milliseconds": Self.format(Self.milliseconds(from: processStartedAt, to: uptime())),
        ])
    }

    // MARK: - Overlay sessions

    func overlayShown(traceID: UUID?, screen: NSScreen?) {
        let now = recordAction { $0.reveals += 1 }
        session = Session(start: now, traceID: traceID)
        frameCounter?.start(screen: screen)
    }

    func overlayHidden() {
        guard let shown = session else { return }
        session = nil
        let end = recordAction { _ in }
        var details = Self.costDetails(from: shown.start, to: end)
        details["visibleMilliseconds"] = Self.format(
            Self.milliseconds(from: shown.start.uptimeNanoseconds, to: end.uptimeNanoseconds)
        )
        if let traceID = shown.traceID, let latency = presentedLatency(traceID) {
            details["pressToRevealMilliseconds"] = Self.format(latency.pressToRevealMilliseconds)
            details["holdDelayMilliseconds"] = Self.format(latency.holdDelayMilliseconds)
            if let input = latency.inputLatencyMilliseconds {
                details["inputLatencyMilliseconds"] = Self.format(input)
            }
        }
        if let frames = frameCounter?.stop() {
            details["frames"] = "\(frames.frames)"
            details["slowFrames"] = "\(frames.slowFrames)"
            details["longestFrameMilliseconds"] = Self.format(frames.longestMilliseconds)
            details["refreshMilliseconds"] = Self.format(frames.refreshMilliseconds)
        }
        report("overlay_session_cost", .retained, details)
    }

    // MARK: - Focus and desktops

    func overlayCommitted(windowID: CGWindowID, crossesDesktop: Bool) {
        if pendingCommit != nil { settleCommit(outcome: "superseded") }
        commitGeneration += 1
        let generation = commitGeneration
        pendingCommit = PendingCommit(
            generation: generation,
            windowID: windowID,
            crossesDesktop: crossesDesktop,
            committedAt: uptime()
        )
        schedule(Self.commitTimeout) { [weak self] in
            guard let self, self.pendingCommit?.generation == generation else { return }
            self.settleCommit(outcome: "timed_out")
        }
    }

    func desktopChangeNotified() {
        let now = recordAction { $0.desktopChanges += 1 }
        guard var commit = pendingCommit, commit.desktopChangedAt == nil else { return }
        commit.desktopChangedAt = now.uptimeNanoseconds
        pendingCommit = commit
        if commit.focusedAt != nil { settleCommit(outcome: "focused") }
    }

    func focusAccepted(windowID: CGWindowID) {
        let changed = windowID != lastFocusedWindowID
        lastFocusedWindowID = windowID
        let now = recordAction { if changed { $0.focusChanges += 1 } }
        if let failedAt = pendingFronts.removeValue(forKey: windowID) {
            report("window_front_outcome", .retained, [
                "windowID": "\(windowID)",
                "recovered": "true",
                "recoveredMilliseconds": Self.format(
                    Self.milliseconds(from: failedAt, to: now.uptimeNanoseconds)
                ),
            ])
        }
        guard var commit = pendingCommit, commit.windowID == windowID, commit.focusedAt == nil
        else { return }
        commit.focusedAt = now.uptimeNanoseconds
        pendingCommit = commit
        if !commit.crossesDesktop || commit.desktopChangedAt != nil { settleCommit(outcome: "focused") }
    }

    func frontNotTaken(windowID: CGWindowID) {
        pendingFronts[windowID] = uptime()
        schedule(Self.frontRecoveryWindow) { [weak self] in
            guard let self, self.pendingFronts.removeValue(forKey: windowID) != nil else { return }
            self.report("window_front_outcome", .retained, [
                "windowID": "\(windowID)",
                "recovered": "false",
            ])
        }
    }

    private func settleCommit(outcome: String) {
        guard let commit = pendingCommit else { return }
        pendingCommit = nil
        var details = [
            "crossesDesktop": "\(commit.crossesDesktop)",
            "outcome": outcome,
        ]
        if let focusedAt = commit.focusedAt {
            details["focusedMilliseconds"] = Self.format(
                Self.milliseconds(from: commit.committedAt, to: focusedAt)
            )
        }
        if let desktopChangedAt = commit.desktopChangedAt {
            details["desktopChangedMilliseconds"] = Self.format(
                Self.milliseconds(from: commit.committedAt, to: desktopChangedAt)
            )
        }
        report("focus_commit_settled", .retained, details)
    }

    // MARK: - Stalls

    func mainRunLoopStalled(milliseconds: Double) {
        report("main_run_loop_stalled", .retained, [
            "milliseconds": Self.format(milliseconds),
            "overlayVisible": "\(session != nil)",
        ])
    }

    // MARK: - Intervals

    /// The screen locked, the displays slept or another session came in front. Nobody is using
    /// this Mac until it returns, so that time belongs to no interval.
    func suspensionChanged(_ suspended: Bool) {
        isSuspended = suspended
        guard suspended else { return }
        closeInterval(at: sample())
    }

    func terminating() {
        closeInterval(at: sample())
    }

    @discardableResult
    private func recordAction(_ count: (inout Interval) -> Void) -> HealthSample {
        let now = sample()
        guard !isSuspended else { return now }
        if var open = interval {
            if let last = lastAction, now.uptimeNanoseconds - last.uptimeNanoseconds >= idleGapNanoseconds {
                emit(open, end: last, kind: "active")
                emit(Interval(start: last), end: now, kind: "idle")
                open = Interval(start: now)
            } else if now.uptimeNanoseconds - open.start.uptimeNanoseconds >= rollupIntervalNanoseconds {
                emit(open, end: now, kind: "active")
                open = Interval(start: now)
            }
            interval = open
        } else {
            interval = Interval(start: now)
        }
        count(&interval!)
        lastAction = now
        return now
    }

    private func closeInterval(at now: HealthSample) {
        guard let open = interval else { return }
        if let last = lastAction, now.uptimeNanoseconds - last.uptimeNanoseconds >= idleGapNanoseconds {
            emit(open, end: last, kind: "active")
            emit(Interval(start: last), end: now, kind: "idle")
        } else {
            emit(open, end: now, kind: "active")
        }
        interval = nil
        lastAction = nil
    }

    private func emit(_ finished: Interval, end: HealthSample, kind: String) {
        let seconds = Double(end.uptimeNanoseconds - finished.start.uptimeNanoseconds) / 1_000_000_000
        guard seconds > 0 else { return }
        var details = Self.costDetails(from: finished.start, to: end)
        let cpu = Double(end.cpuNanoseconds &- finished.start.cpuNanoseconds) / 1_000_000_000
        let energy = Double(end.energyNanojoules &- finished.start.energyNanojoules) / 1_000_000_000
        details["kind"] = kind
        details["intervalSeconds"] = Self.format(seconds)
        details["reveals"] = "\(finished.reveals)"
        details["desktopChanges"] = "\(finished.desktopChanges)"
        details["focusChanges"] = "\(finished.focusChanges)"
        details["cpuPercent"] = String(format: "%.3f", cpu / seconds * 100)
        details["milliwatts"] = String(format: "%.2f", energy / seconds * 1000)
        details["wakeups"] = "\(end.wakeups &- finished.start.wakeups)"
        details["footprintMegabytes"] = Self.format(Double(end.footprintBytes) / 1_048_576)
        details["peakFootprintMegabytes"] = Self.format(Double(end.peakFootprintBytes) / 1_048_576)
        if let processStartedAt {
            details["processAgeSeconds"] = Self.format(
                Double(end.uptimeNanoseconds &- processStartedAt) / 1_000_000_000
            )
        }
        report("health_rollup", .retained, details)
    }

    // MARK: - Helpers

    private static func costDetails(from start: HealthSample, to end: HealthSample) -> [String: String] {
        var details = [
            "cpuMilliseconds": format(Double(end.cpuNanoseconds &- start.cpuNanoseconds) / 1_000_000),
            "energyMillijoules": format(Double(end.energyNanojoules &- start.energyNanojoules) / 1_000_000),
        ]
        if let startGPU = start.gpuNanojoules, let endGPU = end.gpuNanojoules, endGPU >= startGPU {
            details["gpuMillijoules"] = format(Double(endGPU - startGPU) / 1_000_000)
        }
        return details
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end &- start) / 1_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
