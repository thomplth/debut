import AppKit
import Foundation
import Testing
@testable import DebutCore

private final class HealthFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var current = HealthSample(
        uptimeNanoseconds: 1_000_000_000,
        cpuNanoseconds: 0,
        energyNanojoules: 0,
        gpuNanojoules: 0,
        footprintBytes: 150 * 1_048_576,
        peakFootprintBytes: 180 * 1_048_576,
        wakeups: 0
    )
    private var scheduled: [(deadline: UInt64, work: () -> Void)] = []
    private var latencies: [UUID: PresentedOverlayLatency] = [:]

    var sample: HealthSample { lock.withLock { current } }
    var now: UInt64 { lock.withLock { current.uptimeNanoseconds } }

    func advance(
        seconds: Double,
        cpuMilliseconds: Double = 0,
        millijoules: Double = 0,
        gpuMillijoules: Double = 0,
        wakeups: UInt64 = 0,
        footprintMegabytes: UInt64? = nil
    ) {
        let due: [() -> Void] = lock.withLock {
            current.uptimeNanoseconds += UInt64(seconds * 1_000_000_000)
            current.cpuNanoseconds += UInt64(cpuMilliseconds * 1_000_000)
            current.energyNanojoules += UInt64(millijoules * 1_000_000)
            current.gpuNanojoules = current.gpuNanojoules.map { $0 + UInt64(gpuMillijoules * 1_000_000) }
            current.wakeups += wakeups
            if let footprintMegabytes { current.footprintBytes = footprintMegabytes * 1_048_576 }
            let ready = scheduled.filter { $0.deadline <= current.uptimeNanoseconds }
            scheduled.removeAll { $0.deadline <= current.uptimeNanoseconds }
            return ready.map(\.work)
        }
        due.forEach { $0() }
    }

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            scheduled.append((current.uptimeNanoseconds + UInt64(seconds * 1_000_000_000), work))
        }
    }

    func present(_ traceID: UUID, latency: PresentedOverlayLatency) {
        lock.withLock { latencies[traceID] = latency }
    }

    func latency(_ traceID: UUID) -> PresentedOverlayLatency? { lock.withLock { latencies[traceID] } }
}

private final class ScriptedFrameCounter: OverlayFrameCounting, @unchecked Sendable {
    var summary: FramePacingSummary?
    private(set) var started = 0
    func start(screen: NSScreen?) { started += 1 }
    func stop() -> FramePacingSummary? { summary }
}

@Suite("Development health recorder")
struct DevelopmentHealthRecorderTests {
    private let fixture = HealthFixture()
    private let reports = RecordedReports()
    private let frames = ScriptedFrameCounter()

    private func makeRecorder(processStartedAt: UInt64? = nil) -> DevelopmentHealthRecorder {
        let fixture = fixture
        return DevelopmentHealthRecorder(
            report: reports.report,
            sample: { fixture.sample },
            uptime: { fixture.now },
            processStartedAt: processStartedAt,
            presentedLatency: { fixture.latency($0) },
            frameCounter: frames,
            schedule: { fixture.schedule(after: $0, $1) },
            rollupInterval: 3600,
            idleGap: 600
        )
    }

    @Test("An hour of use closes into one retained active rollup with its cost and action counts")
    func hourOfUseRollsUp() throws {
        let recorder = makeRecorder()
        recorder.overlayShown(traceID: nil, screen: nil)
        for _ in 0..<12 {
            fixture.advance(seconds: 1, cpuMilliseconds: 100, millijoules: 80, gpuMillijoules: 300)
            recorder.overlayHidden()
            fixture.advance(seconds: 299, cpuMilliseconds: 50, millijoules: 40, gpuMillijoules: 100, wakeups: 10)
            recorder.focusAccepted(windowID: 7)
            recorder.desktopChangeNotified()
            recorder.overlayShown(traceID: nil, screen: nil)
        }

        let rollup = try #require(reports.events("health_rollup").first)
        #expect(reports.all.first { $0.event == "health_rollup" }?.level == .retained)
        #expect(rollup["kind"] == "active")
        #expect(rollup["intervalSeconds"] == "3600.0")
        #expect(rollup["reveals"] == "12")
        #expect(rollup["focusChanges"] == "1")
        #expect(rollup["desktopChanges"] == "11")
        #expect(rollup["cpuMilliseconds"] == "1800.0")
        #expect(rollup["cpuPercent"] == "0.050")
        #expect(rollup["energyMillijoules"] == "1440.0")
        #expect(rollup["milliwatts"] == "0.40")
        #expect(rollup["gpuMillijoules"] == "4800.0")
        #expect(rollup["wakeups"] == "120")
        #expect(rollup["footprintMegabytes"] == "150.0")
        #expect(rollup["peakFootprintMegabytes"] == "180.0")
    }

    @Test("A quiet gap after the last action becomes its own idle rollup")
    func quietGapIsIdle() throws {
        let recorder = makeRecorder()
        recorder.focusAccepted(windowID: 1)
        fixture.advance(seconds: 60, cpuMilliseconds: 600, millijoules: 300)
        recorder.focusAccepted(windowID: 2)
        fixture.advance(seconds: 700, cpuMilliseconds: 7, millijoules: 4.2)
        recorder.focusAccepted(windowID: 3)

        let rollups = reports.events("health_rollup")
        #expect(rollups.map { $0["kind"] } == ["active", "idle"])
        #expect(rollups[0]["intervalSeconds"] == "60.0")
        #expect(rollups[0]["focusChanges"] == "2")
        #expect(rollups[0]["cpuMilliseconds"] == "600.0")
        #expect(rollups[1]["intervalSeconds"] == "700.0")
        #expect(rollups[1]["focusChanges"] == "0")
        #expect(rollups[1]["cpuMilliseconds"] == "7.0")
        #expect(rollups[1]["milliwatts"] == "0.01")
    }

    @Test("Suspension closes the open rollup and the locked time is never counted")
    func suspensionClosesRollup() throws {
        let recorder = makeRecorder()
        recorder.focusAccepted(windowID: 1)
        fixture.advance(seconds: 120, cpuMilliseconds: 240)
        recorder.suspensionChanged(true)
        fixture.advance(seconds: 2500, cpuMilliseconds: 25)
        recorder.focusAccepted(windowID: 9)
        fixture.advance(seconds: 2500, cpuMilliseconds: 25)
        recorder.suspensionChanged(false)
        fixture.advance(seconds: 10)
        recorder.focusAccepted(windowID: 2)
        fixture.advance(seconds: 30, cpuMilliseconds: 30)
        recorder.terminating()

        let rollups = reports.events("health_rollup")
        #expect(rollups.map { $0["kind"] } == ["active", "active"])
        #expect(rollups.map { $0["intervalSeconds"] } == ["120.0", "30.0"])
        #expect(rollups.map { $0["cpuMilliseconds"] } == ["240.0", "30.0"])
    }

    @Test("A reveal reports its own cost, its frame pacing and how long the press took to show")
    func revealReportsSessionCost() throws {
        let recorder = makeRecorder()
        let traceID = UUID()
        frames.summary = FramePacingSummary(
            frames: 240,
            slowFrames: 3,
            longestMilliseconds: 41.7,
            refreshMilliseconds: 8.3
        )
        recorder.overlayShown(traceID: traceID, screen: nil)
        fixture.present(traceID, latency: PresentedOverlayLatency(
            pressToRevealMilliseconds: 142,
            holdDelayMilliseconds: 100,
            inputLatencyMilliseconds: 0.4
        ))
        fixture.advance(seconds: 2, cpuMilliseconds: 900, millijoules: 650, gpuMillijoules: 700)
        recorder.overlayHidden()

        let session = try #require(reports.events("overlay_session_cost").first)
        #expect(reports.all.first { $0.event == "overlay_session_cost" }?.level == .retained)
        #expect(frames.started == 1)
        #expect(session["visibleMilliseconds"] == "2000.0")
        #expect(session["cpuMilliseconds"] == "900.0")
        #expect(session["energyMillijoules"] == "650.0")
        #expect(session["gpuMillijoules"] == "700.0")
        #expect(session["pressToRevealMilliseconds"] == "142.0")
        #expect(session["holdDelayMilliseconds"] == "100.0")
        #expect(session["inputLatencyMilliseconds"] == "0.4")
        #expect(session["frames"] == "240")
        #expect(session["slowFrames"] == "3")
        #expect(session["longestFrameMilliseconds"] == "41.7")
        #expect(session["refreshMilliseconds"] == "8.3")
    }

    @Test("Hiding an overlay that was never shown reports no session")
    func hideWithoutShowReportsNothing() {
        let recorder = makeRecorder()
        recorder.overlayHidden()
        #expect(reports.events("overlay_session_cost").isEmpty)
    }

    @Test("A same-desktop commit settles when focus reaches the chosen window")
    func sameDesktopCommitSettlesOnFocus() throws {
        let recorder = makeRecorder()
        recorder.overlayCommitted(windowID: 42, crossesDesktop: false)
        fixture.advance(seconds: 0.03)
        recorder.focusAccepted(windowID: 9)
        fixture.advance(seconds: 0.09)
        recorder.focusAccepted(windowID: 42)

        let settled = try #require(reports.events("focus_commit_settled").first)
        #expect(settled["crossesDesktop"] == "false")
        #expect(settled["focusedMilliseconds"] == "120.0")
        #expect(settled["desktopChangedMilliseconds"] == nil)
        #expect(settled["outcome"] == "focused")
    }

    @Test("A cross-desktop commit settles only once both the desktop change and the focus arrived")
    func crossDesktopCommitWaitsForBoth() throws {
        let recorder = makeRecorder()
        recorder.overlayCommitted(windowID: 42, crossesDesktop: true)
        fixture.advance(seconds: 0.05)
        recorder.focusAccepted(windowID: 42)
        #expect(reports.events("focus_commit_settled").isEmpty)
        fixture.advance(seconds: 0.4)
        recorder.desktopChangeNotified()

        let settled = try #require(reports.events("focus_commit_settled").first)
        #expect(settled["crossesDesktop"] == "true")
        #expect(settled["focusedMilliseconds"] == "50.0")
        #expect(settled["desktopChangedMilliseconds"] == "450.0")
        #expect(settled["outcome"] == "focused")
    }

    @Test("A commit replaced by another before its window took focus is reported as superseded")
    func replacedCommitIsSuperseded() throws {
        let recorder = makeRecorder()
        recorder.overlayCommitted(windowID: 42, crossesDesktop: false)
        fixture.advance(seconds: 0.2)
        recorder.overlayCommitted(windowID: 43, crossesDesktop: false)
        fixture.advance(seconds: 0.1)
        recorder.focusAccepted(windowID: 43)
        fixture.advance(seconds: 5)

        let settled = reports.events("focus_commit_settled")
        #expect(settled.map { $0["outcome"] } == ["superseded", "focused"])
        #expect(settled[1]["focusedMilliseconds"] == "100.0")
    }

    @Test("A commit whose window never takes focus is reported as timed out")
    func unansweredCommitTimesOut() throws {
        let recorder = makeRecorder()
        recorder.overlayCommitted(windowID: 42, crossesDesktop: true)
        fixture.advance(seconds: 0.4)
        recorder.desktopChangeNotified()
        fixture.advance(seconds: 3)

        let settled = try #require(reports.events("focus_commit_settled").first)
        #expect(settled["outcome"] == "timed_out")
        #expect(settled["desktopChangedMilliseconds"] == "400.0")
        #expect(settled["focusedMilliseconds"] == nil)
    }

    @Test("A window that failed to take the front counts as recovered when it gains focus within a second")
    func frontFailureRecovers() throws {
        let recorder = makeRecorder()
        recorder.frontNotTaken(windowID: 5)
        fixture.advance(seconds: 0.3)
        recorder.focusAccepted(windowID: 5)
        recorder.frontNotTaken(windowID: 6)
        fixture.advance(seconds: 1.2)

        let outcomes = reports.events("window_front_outcome")
        #expect(outcomes.map { $0["windowID"] } == ["5", "6"])
        #expect(outcomes.map { $0["recovered"] } == ["true", "false"])
        #expect(outcomes[0]["recoveredMilliseconds"] == "300.0")
    }

    @Test("Launch readiness is measured from the moment the process started")
    func launchReadyFromProcessStart() throws {
        let recorder = makeRecorder(processStartedAt: fixture.now)
        fixture.advance(seconds: 0.42)
        recorder.launchReady()

        let ready = try #require(reports.events("launch_ready").first)
        #expect(ready["milliseconds"] == "420.0")
    }

    @Test("A main run-loop stall is reported with whether the overlay was up")
    func stallReported() throws {
        let recorder = makeRecorder()
        recorder.overlayShown(traceID: nil, screen: nil)
        recorder.mainRunLoopStalled(milliseconds: 276.4)

        let stall = try #require(reports.events("main_run_loop_stalled").first)
        #expect(stall["milliseconds"] == "276.4")
        #expect(stall["overlayVisible"] == "true")
    }
}

@Suite("Run-loop stall detector")
struct RunLoopStallDetectorTests {
    @Test("Work longer than the threshold within one pass is a stall; sleeping between passes is not")
    func detectsLongPassesOnly() {
        var detector = RunLoopStallDetector(thresholdMilliseconds: 100)
        let ms: (Double) -> UInt64 = { UInt64($0 * 1_000_000) }
        #expect(detector.observe(.woke, at: ms(0)) == nil)
        #expect(detector.observe(.passBegan, at: ms(30)) == nil)
        #expect(detector.observe(.aboutToSleep, at: ms(60)) == nil)
        #expect(detector.observe(.woke, at: ms(5_000)) == nil)
        #expect(detector.observe(.passBegan, at: ms(5_250)) == 250)
        #expect(detector.observe(.aboutToSleep, at: ms(5_270)) == nil)
        #expect(detector.observe(.passBegan, at: ms(9_000)) == nil)
        #expect(detector.observe(.aboutToSleep, at: ms(9_150)) == 150)
    }
}

@Suite("Frame pacing counter")
struct FramePacingCounterTests {
    @Test("Frames arriving more than one and a half refresh intervals apart count as slow")
    func countsSlowFrames() throws {
        var counter = FramePacingCounter()
        let refresh = 1.0 / 120
        var timestamp = 10.0
        counter.frame(timestamp: timestamp, duration: refresh)
        for gap in [1.0, 1.0, 3.0, 1.0, 1.6, 1.4] {
            timestamp += gap * refresh
            counter.frame(timestamp: timestamp, duration: refresh)
        }

        let summary = try #require(counter.summary)
        #expect(summary.frames == 6)
        #expect(summary.slowFrames == 2)
        #expect(abs(summary.longestMilliseconds - 25) < 0.01)
        #expect(abs(summary.refreshMilliseconds - 8.333) < 0.01)
    }

    @Test("A counter that saw fewer than two frames has no summary")
    func tooFewFrames() {
        var counter = FramePacingCounter()
        counter.frame(timestamp: 1, duration: 1.0 / 60)
        #expect(counter.summary == nil)
    }
}
