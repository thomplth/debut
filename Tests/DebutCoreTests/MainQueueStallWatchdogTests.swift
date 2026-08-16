import Foundation
import Testing
@testable import DebutCore

@Suite("Main queue stall watchdog")
struct MainQueueStallWatchdogTests {
    @Test("A stall is reported with the resource cost measured across it")
    func stallCarriesResourceCost() {
        // The 3.1s overlay stall could only be inferred afterwards from the order
        // in which two unrelated blocks drained. Reporting while the queue is
        // still blocked, with the cost measured across the block, separates a
        // main thread that is burning CPU from one that is waiting on something.
        let scheduler = ManualScheduler()
        let reports = ReportBox()
        let reader = ScriptedReader([
            makeSnapshot(at: 0, cpuNanoseconds: 0, pageIns: 0),
            makeSnapshot(at: 1_000_000_000, cpuNanoseconds: 20_000_000, pageIns: 12),
        ])
        let watchdog = MainQueueStallWatchdog(
            thresholdMilliseconds: 250,
            resourceReader: reader,
            now: { scheduler.now },
            schedule: scheduler.schedule,
            onStall: reports.append
        )

        let traceID = UUID()
        watchdog.arm(traceID: traceID)
        scheduler.advance(milliseconds: 300)
        scheduler.fire(0)

        #expect(reports.values.count == 1)
        let report = reports.values.first
        #expect(report?.traceID == traceID)
        #expect(report?.elapsedMilliseconds == 300)
        #expect(report?.resourceDelta?.pageIns == 12)
        #expect(report?.resourceDelta?.cpuPercent == 2)
    }

    @Test("Work that starts in time is never reported")
    func disarmedWatchdogStaysSilent() {
        let scheduler = ManualScheduler()
        let reports = ReportBox()
        let watchdog = makeWatchdog(scheduler: scheduler, reports: reports)

        watchdog.arm(traceID: UUID())
        watchdog.disarm()
        scheduler.fire(0)

        #expect(reports.values.isEmpty)
    }

    @Test("A later presentation does not inherit an earlier deadline")
    func rearmingSupersedesTheEarlierDeadline() {
        // Without this, the deadline left over from a presentation that finished
        // on time fires against the next one and reports a stall that the second
        // presentation has not had time to have.
        let scheduler = ManualScheduler()
        let reports = ReportBox()
        let watchdog = makeWatchdog(scheduler: scheduler, reports: reports)

        watchdog.arm(traceID: UUID())
        watchdog.disarm()
        watchdog.arm(traceID: UUID())
        scheduler.fire(0)

        #expect(reports.values.isEmpty)
    }

    @Test("The watchdog reports at most once per presentation")
    func stallIsReportedOnce() {
        let scheduler = ManualScheduler()
        let reports = ReportBox()
        let watchdog = makeWatchdog(scheduler: scheduler, reports: reports)

        watchdog.arm(traceID: UUID())
        scheduler.fire(0)
        scheduler.fire(0)
        watchdog.disarm()

        #expect(reports.values.count == 1)
    }

    private func makeWatchdog(scheduler: ManualScheduler, reports: ReportBox) -> MainQueueStallWatchdog {
        MainQueueStallWatchdog(
            thresholdMilliseconds: 250,
            resourceReader: UnavailableProcessResourceReader(),
            now: { scheduler.now },
            schedule: scheduler.schedule,
            onStall: reports.append
        )
    }
}

private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MainQueueStallWatchdog.Stall] = []

    var values: [MainQueueStallWatchdog.Stall] { lock.withLock { stored } }

    @Sendable func append(_ stall: MainQueueStallWatchdog.Stall) {
        lock.withLock { stored.append(stall) }
    }
}

private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0
    private var pending: [@Sendable () -> Void] = []

    var now: UInt64 { lock.withLock { nanoseconds } }

    func advance(milliseconds: UInt64) {
        lock.withLock { nanoseconds += milliseconds * 1_000_000 }
    }

    @Sendable func schedule(afterMilliseconds: Double, work: @escaping @Sendable () -> Void) {
        lock.withLock { pending.append(work) }
    }

    /// Deadlines stay scheduled after firing so a test can fire one twice.
    func fire(_ index: Int) {
        guard let work = lock.withLock({ pending.indices.contains(index) ? pending[index] : nil }) else { return }
        work()
    }
}

private final class ScriptedReader: ProcessResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ProcessResourceSnapshot]

    init(_ snapshots: [ProcessResourceSnapshot]) {
        pending = snapshots
    }

    func read() -> ProcessResourceSnapshot? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }
}

private func makeSnapshot(
    at monotonicNanoseconds: UInt64,
    cpuNanoseconds: UInt64,
    pageIns: UInt64
) -> ProcessResourceSnapshot {
    ProcessResourceSnapshot(
        monotonicNanoseconds: monotonicNanoseconds,
        userCPUNanoseconds: cpuNanoseconds,
        systemCPUNanoseconds: 0,
        physicalFootprintBytes: 0,
        peakPhysicalFootprintBytes: 0,
        threadCount: 1,
        wakeups: 0,
        bytesRead: 0,
        bytesWritten: 0,
        pageIns: pageIns
    )
}
