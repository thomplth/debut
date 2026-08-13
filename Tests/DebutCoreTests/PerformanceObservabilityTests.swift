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
            bytesWritten: 20
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
            bytesWritten: 80
        )

        let delta = ProcessResourceDelta.between(old, new)
        #expect(delta?.cpuPercent == 30)
        #expect(delta?.wakeups == 5)
        #expect(delta?.bytesRead == 30)
        #expect(delta?.bytesWritten == 60)

        let reset = ProcessResourceSnapshot(
            monotonicNanoseconds: 3_000_000_000,
            userCPUNanoseconds: 1,
            systemCPUNanoseconds: 1,
            physicalFootprintBytes: 90,
            peakPhysicalFootprintBytes: 140,
            threadCount: 4,
            wakeups: 1,
            bytesRead: 1,
            bytesWritten: 1
        )
        #expect(ProcessResourceDelta.between(new, reset) == nil)
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
        let deliveryID = recorder.begin(.mainQueueDelivery, workload: .init(windows: 14))
        _ = recorder.end(deliveryID, sampleResources: false)

        for _ in 0..<150 {
            let eventID = recorder.begin(.eventTap)
            _ = recorder.end(eventID, sampleResources: false)
        }

        let recent = recorder.snapshot().recent
        #expect(recent.contains { $0.correlationID == deliveryID })
        #expect(recent.filter { $0.operation == .eventTap }.count == 20)
    }
}
