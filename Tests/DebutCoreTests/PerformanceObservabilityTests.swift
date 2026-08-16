import Foundation
import Testing
@testable import DebutCore

@Suite("Performance observability")
struct PerformanceObservabilityTests {
    @Test("Canonical operations have stable wire names")
    func stableOperationNames() {
        #expect(PerformanceOperation.allCases.map(\.rawValue) == [
            "event_tap", "main_queue_delivery", "overlay_preparation", "overlay_render_submission",
            "overlay_end_to_end_visible",
            "preview_enumeration",
            "preview_first", "preview_all", "preview_capture", "window_discovery",
            "window_classification", "window_reconciliation", "stage_switch",
            "stage_raise", "wallpaper_capture", "state_persistence", "hidden_idle",
        ])
    }

    @Test("Rolling summary is bounded and uses deterministic nearest-rank percentiles")
    func rollingSummary() {
        var samples = PerformanceSampleBuffer(capacity: 5)
        for value in [100.0, 10, 30, 20, 40, 50] { samples.append(value) }

        #expect(samples.values == [10, 30, 20, 40, 50])
        #expect(samples.summary == PerformanceSummary(
            count: 5,
            medianMilliseconds: 30,
            p95Milliseconds: 50,
            p99Milliseconds: 50,
            maximumMilliseconds: 50
        ))
    }

    @Test("Resource deltas reject reset counters and derive CPU only from elapsed event intervals")
    func resourceDelta() {
        let old = ProcessResourceSnapshot(
            monotonicNanoseconds: 1_000_000_000,
            userCPUNanoseconds: 100_000_000,
            systemCPUNanoseconds: 50_000_000,
            physicalFootprintBytes: 100,
            peakPhysicalFootprintBytes: 120,
            threadCount: 4,
            wakeups: 20,
            bytesRead: 10,
            bytesWritten: 20,
            pageIns: 3
        )
        let new = ProcessResourceSnapshot(
            monotonicNanoseconds: 2_000_000_000,
            userCPUNanoseconds: 300_000_000,
            systemCPUNanoseconds: 150_000_000,
            physicalFootprintBytes: 110,
            peakPhysicalFootprintBytes: 140,
            threadCount: 5,
            wakeups: 25,
            bytesRead: 40,
            bytesWritten: 80,
            pageIns: 11
        )

        let delta = ProcessResourceDelta.between(old, new)
        #expect(delta?.cpuPercent == 30)
        #expect(delta?.wakeups == 5)
        #expect(delta?.bytesRead == 30)
        #expect(delta?.bytesWritten == 60)
        // A stall with no CPU and no reads is either a lock or a page fault, and
        // page-ins are the only one of those the process can see for itself.
        #expect(delta?.pageIns == 8)

        let reset = ProcessResourceSnapshot(
            monotonicNanoseconds: 3_000_000_000,
            userCPUNanoseconds: 1,
            systemCPUNanoseconds: 1,
            physicalFootprintBytes: 90,
            peakPhysicalFootprintBytes: 140,
            threadCount: 4,
            wakeups: 1,
            bytesRead: 1,
            bytesWritten: 1,
            pageIns: 1
        )
        #expect(ProcessResourceDelta.between(new, reset) == nil)
    }

    @Test("Each observation carries the resource cost measured across its own span")
    func perObservationResourceDelta() {
        // A single global delta was overwritten by whichever operation ended
        // last, so it could not be used as evidence about any of them.
        let reader = ScriptedResourceReader([
            makeSnapshot(at: 0, cpuNanoseconds: 0, pageIns: 0),
            makeSnapshot(at: 1_000_000_000, cpuNanoseconds: 500_000_000, pageIns: 7),
            makeSnapshot(at: 2_000_000_000, cpuNanoseconds: 500_000_000, pageIns: 7),
            makeSnapshot(at: 3_000_000_000, cpuNanoseconds: 600_000_000, pageIns: 9),
        ])
        let recorder = PerformanceRecorder(resourceReader: reader, now: { 1 })

        let preparation = recorder.end(recorder.begin(.overlayPreparation))
        let switched = recorder.end(recorder.begin(.stageSwitch))

        #expect(preparation?.resourceDelta?.cpuPercent == 50)
        #expect(preparation?.resourceDelta?.pageIns == 7)
        #expect(switched?.resourceDelta?.cpuPercent == 10)
        #expect(switched?.resourceDelta?.pageIns == 2)
    }

    @Test("A span that skips resource sampling never reads the process counters")
    func unsampledSpanHasNoDelta() {
        let reader = ScriptedResourceReader([
            makeSnapshot(at: 0, cpuNanoseconds: 0, pageIns: 0),
            makeSnapshot(at: 1_000_000_000, cpuNanoseconds: 500_000_000, pageIns: 7),
        ])
        let recorder = PerformanceRecorder(resourceReader: reader, now: { 1 })

        let id = recorder.begin(.previewCapture, sampleResources: false)
        let observation = recorder.end(id)

        #expect(observation?.resourceDelta == nil)
        #expect(reader.reads == 0)
    }

    @Test("Unavailable process metrics do not prevent operation recording")
    func unavailableMetrics() {
        let recorder = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let id = recorder.begin(.windowDiscovery, workload: .init(windows: 12, processes: 4))
        let observation = recorder.end(id)

        #expect(observation?.operation == .windowDiscovery)
        #expect(observation?.workload.windows == 12)
        #expect(recorder.snapshot().resources == nil)
    }

    @Test("Completed observations are published without exposing identifiers beyond correlation")
    func observationHandler() {
        final class Box: @unchecked Sendable { var observation: PerformanceObservation? }
        let box = Box()
        let recorder = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader(), now: { 1 })
        recorder.setObservationHandler { box.observation = $0 }
        let id = recorder.begin(.stageSwitch, workload: .init(stages: 4, windows: 12))
        _ = recorder.end(id)

        #expect(box.observation?.correlationID == id)
        #expect(box.observation?.operation == .stageSwitch)
    }

    @Test("High-frequency event taps cannot evict recent evidence for other operations")
    func recentEvidenceIsBoundedPerOperation() {
        let recorder = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader(), now: { 1 })
        let deliveryID = recorder.begin(.mainQueueDelivery, workload: .init(windows: 14), sampleResources: false)
        _ = recorder.end(deliveryID)

        for _ in 0..<150 {
            let eventID = recorder.begin(.eventTap, sampleResources: false)
            _ = recorder.end(eventID)
        }

        let recent = recorder.snapshot().recent
        #expect(recent.contains { $0.correlationID == deliveryID })
        #expect(recent.filter { $0.operation == .eventTap }.count == 20)
    }
}

@Suite("Preview capture metrics")
struct PreviewCaptureMetricsTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 0

        var now: UInt64 { lock.withLock { nanoseconds } }
        func advance(milliseconds: UInt64) {
            lock.withLock { nanoseconds += milliseconds * 1_000_000 }
        }
    }

    private func makeRecorder(_ clock: Clock) -> PerformanceRecorder {
        PerformanceRecorder(
            resourceReader: UnavailableProcessResourceReader(),
            now: { clock.now }
        )
    }

    @Test("Shareable-content enumeration is timed apart from the captures it precedes")
    func enumerationIsExcludedFromCaptureTimings() {
        // Starting a per-window timer before enumeration billed every window for
        // the shared wait, which made a capture look slow when nothing had been
        // captured yet.
        let clock = Clock()
        let recorder = makeRecorder(clock)
        let metrics = PreviewCaptureMetrics(windowIDs: [1, 2], performanceRecorder: recorder)

        clock.advance(milliseconds: 90)
        metrics.recordEnumeration(matchedWindowIDs: [1, 2])
        clock.advance(milliseconds: 10)
        metrics.recordCapture(windowID: 1)
        metrics.recordCapture(windowID: 2)
        _ = metrics.finish()

        let recent = recorder.snapshot().recent
        let enumeration = recent.filter { $0.operation == .previewEnumeration }
        #expect(enumeration.count == 1)
        #expect(enumeration.first?.durationMilliseconds == 90)

        let captures = recent.filter { $0.operation == .previewCapture }
        #expect(captures.count == 2)
        #expect(captures.allSatisfy { $0.durationMilliseconds == 10 })
    }

    @Test("Windows the enumeration never matched are not timed as captures")
    func unmatchedWindowsAreNotTimedAsCaptures() {
        let clock = Clock()
        let recorder = makeRecorder(clock)
        let metrics = PreviewCaptureMetrics(windowIDs: [1, 2, 3], performanceRecorder: recorder)

        metrics.recordEnumeration(matchedWindowIDs: [1])
        metrics.recordCapture(windowID: 1)
        _ = metrics.finish()

        let captures = recorder.snapshot().recent.filter { $0.operation == .previewCapture }
        #expect(captures.count == 1)
    }

    @Test("A batch that never enumerates still closes its enumeration timing")
    func abandonedBatchClosesEnumeration() {
        let clock = Clock()
        let recorder = makeRecorder(clock)
        let metrics = PreviewCaptureMetrics(windowIDs: [], performanceRecorder: recorder)

        clock.advance(milliseconds: 5)
        _ = metrics.finish()

        let recent = recorder.snapshot().recent
        #expect(recent.filter { $0.operation == .previewEnumeration }.count == 1)
        #expect(recent.filter { $0.operation == .previewCapture }.isEmpty)
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

private final class ScriptedResourceReader: ProcessResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ProcessResourceSnapshot]
    private var readCount = 0

    var reads: Int { lock.withLock { readCount } }

    init(_ snapshots: [ProcessResourceSnapshot]) {
        pending = snapshots
    }

    func read() -> ProcessResourceSnapshot? {
        lock.withLock {
            readCount += 1
            return pending.isEmpty ? nil : pending.removeFirst()
        }
    }
}
