import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

final class RecordedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(event: String, level: DiagnosticLevel, details: [String: String])] = []

    var all: [(event: String, level: DiagnosticLevel, details: [String: String])] {
        lock.withLock { stored }
    }

    func events(_ name: String) -> [[String: String]] {
        all.filter { $0.event == name }.map(\.details)
    }

    var report: PreviewFreshnessRecorder.Report {
        { [weak self] event, level, details in
            self?.lock.withLock { self?.stored.append((event, level, details)) }
        }
    }
}

private final class ManualUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000
    var now: UInt64 { lock.withLock { value } }
    func advance(milliseconds: Double) { lock.withLock { value += UInt64(milliseconds * 1_000_000) } }
}

private struct ScriptedCostSampler: CaptureCostSampling {
    let samples: LockedBox<[CaptureCostSample]>
    func sample() -> CaptureCostSample { samples.removeFirst() }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

extension LockedBox where Value == [CaptureCostSample] {
    func removeFirst() -> CaptureCostSample { mutate { $0.removeFirst() } }
}

private let inline: PreviewFreshnessRecorder.Executor = { $0() }

private func image(gray: UInt8, width: Int = 32, height: Int = 32) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.setFillColor(gray: CGFloat(gray) / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Suite("Preview freshness metrics")
struct PreviewFreshnessTests {
    private func recorder(
        _ reports: RecordedReports,
        uptime: ManualUptime = ManualUptime(),
        development: Bool = false,
        rollupInterval: TimeInterval = 3600,
        sampler: (any CaptureCostSampling)? = nil
    ) -> PreviewFreshnessRecorder {
        PreviewFreshnessRecorder(
            report: reports.report,
            measuresDevelopmentCosts: development,
            uptime: { uptime.now },
            rollupInterval: rollupInterval,
            costSampler: sampler,
            background: inline,
            main: inline
        )
    }

    @Test("A session reports card ages, shape mismatches and the changes after the reveal")
    func sessionSummary() throws {
        let reports = RecordedReports()
        let uptime = ManualUptime()
        let recorder = recorder(reports, uptime: uptime)
        recorder.sessionRevealed(cards: [
            .init(windowID: 1, ageSeconds: 4, shapeMismatch: false),
            .init(windowID: 2, ageSeconds: 30, shapeMismatch: true),
            .init(windowID: 3, ageSeconds: nil, shapeMismatch: false),
        ], pendingCaptures: 2)
        uptime.advance(milliseconds: 120)
        recorder.previewDelivered(windowID: 1, previous: image(gray: 10), replacement: image(gray: 200))
        uptime.advance(milliseconds: 200)
        recorder.previewDelivered(windowID: 3, previous: nil, replacement: image(gray: 200))
        recorder.previewDelivered(windowID: 99, previous: nil, replacement: image(gray: 1))
        recorder.sessionEnded()

        let event = try #require(reports.events("preview_freshness").first)
        #expect(event["cards"] == "3")
        #expect(event["withPreview"] == "2")
        #expect(event["shapeMismatches"] == "1")
        #expect(event["pendingCaptures"] == "2")
        #expect(event["replacementsAfterReveal"] == "1")
        #expect(event["fillsAfterReveal"] == "1", "a window the overlay is not showing is not counted")
        #expect(event["ageMedianSeconds"] == "30.0")
        #expect(event["ageMaxSeconds"] == "30.0")
        #expect(event["firstChangeMilliseconds"] == "120.0")
        #expect(event["lastChangeMilliseconds"] == "320.0")
        #expect(event["changesScored"] == nil, "visual scoring is a development measurement")
        #expect(reports.all.first { $0.event == "preview_freshness" }?.level == .lifecycle)
    }

    @Test("Development builds score how visibly each replacement changed")
    func developmentChangeScores() throws {
        let reports = RecordedReports()
        let recorder = recorder(reports, development: true, sampler: ScriptedCostSampler(samples: LockedBox([])))
        recorder.sessionRevealed(cards: [
            .init(windowID: 1, ageSeconds: 1, shapeMismatch: false),
            .init(windowID: 2, ageSeconds: 1, shapeMismatch: false),
        ], pendingCaptures: 2)
        recorder.previewDelivered(windowID: 1, previous: image(gray: 100), replacement: image(gray: 101))
        recorder.previewDelivered(windowID: 2, previous: image(gray: 0), replacement: image(gray: 255))
        recorder.sessionEnded()

        let event = try #require(reports.events("preview_freshness").first)
        #expect(event["changesScored"] == "2")
        #expect(event["visibleChanges"] == "1", "a one-level difference is noise")
        #expect(event["changeScoreMaxPercent"] == "100.0")
    }

    @Test("No session means no freshness event")
    func noSessionNoEvent() {
        let reports = RecordedReports()
        let recorder = recorder(reports)
        recorder.previewDelivered(windowID: 1, previous: nil, replacement: image(gray: 1))
        recorder.sessionEnded()
        #expect(reports.events("preview_freshness").isEmpty)
    }

    @Test("Capture batches roll up into captures per hour once the interval has passed")
    func hourlyRollup() throws {
        let reports = RecordedReports()
        let uptime = ManualUptime()
        let recorder = recorder(reports, uptime: uptime, rollupInterval: 60)
        recorder.batchFinished(reason: "overlay_refresh", requested: 3, captured: 2, discarded: 1, wallMilliseconds: 80)
        uptime.advance(milliseconds: 30_000)
        recorder.batchFinished(reason: "focus_left", requested: 1, captured: 1, discarded: 0, wallMilliseconds: 40)
        #expect(reports.events("preview_capture_rollup").isEmpty)
        uptime.advance(milliseconds: 30_000)
        recorder.batchFinished(reason: "overlay_refresh", requested: 2, captured: 1, discarded: 0, wallMilliseconds: 50)

        let rollup = try #require(reports.events("preview_capture_rollup").first)
        #expect(rollup["batches"] == "3")
        #expect(rollup["requested"] == "6")
        #expect(rollup["captured"] == "4")
        #expect(rollup["discarded"] == "1")
        #expect(rollup["failed"] == "1")
        #expect(rollup["intervalSeconds"] == "60.0")
        #expect(rollup["capturesPerHour"] == "240.0")
        #expect(rollup["capturedByReason"] == "focus_left:1,overlay_refresh:3")

        let batches = reports.all.filter { $0.event == "preview_capture_batch" }
        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.level == .transient }, "per-batch events are durable only in development")
        #expect(batches[0].details["failed"] == "0")
    }

    @Test("Development rollups carry the capture machinery's CPU and energy over the interval")
    func developmentRollupCost() throws {
        let reports = RecordedReports()
        let uptime = ManualUptime()
        let sampler = ScriptedCostSampler(samples: LockedBox([
            CaptureCostSample(cpuNanoseconds: ["systemstatusd": 1_000_000_000, "Debut": 5_000_000],
                              energyNanojoules: ["replayd": 2_000_000]),
            CaptureCostSample(cpuNanoseconds: ["systemstatusd": 1_330_000_000, "Debut": 9_000_000],
                              energyNanojoules: ["replayd": 9_000_000]),
        ]))
        let recorder = recorder(reports, uptime: uptime, development: true, rollupInterval: 10, sampler: sampler)
        recorder.batchFinished(reason: "overlay_refresh", requested: 1, captured: 1, discarded: 0, wallMilliseconds: 40)
        uptime.advance(milliseconds: 11_000)
        recorder.batchFinished(reason: "overlay_refresh", requested: 1, captured: 1, discarded: 0, wallMilliseconds: 40)

        let rollup = try #require(reports.events("preview_capture_rollup").first)
        #expect(rollup["cpuMilliseconds.systemstatusd"] == "330")
        #expect(rollup["cpuMilliseconds.Debut"] == "4")
        #expect(rollup["energyMillijoules.replayd"] == "7")
        #expect(reports.all.filter { $0.event == "preview_capture_batch" }.allSatisfy { $0.level == .lifecycle })
    }

    @Test("A restarted process is left out of the cost delta")
    func restartedProcessOmitted() {
        let earlier = CaptureCostSample(cpuNanoseconds: ["tccd": 50, "replayd": 10], energyNanojoules: [:])
        let later = CaptureCostSample(cpuNanoseconds: ["tccd": 5, "replayd": 30], energyNanojoules: [:])
        #expect(later.delta(since: earlier).cpuNanoseconds == ["replayd": 20])
    }

    @Test("ps cumulative CPU parses minutes, hours and days")
    func psParsing() {
        let parsed = SystemCaptureCostSampler.parsePS("""
              641 12:34.50
              735 1:02:03.25
              1 2-00:00:01.00
            """)
        #expect(parsed[641] == 754_500_000_000)
        #expect(parsed[735] == 3_723_250_000_000)
        #expect(parsed[1] == 172_801_000_000_000)
    }

    @Test("An overlay session reports what the cards showed and what changed after the reveal")
    func controllerReportsSession() throws {
        let reports = RecordedReports()
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            overlayPresentationDelay: 0,
            focusedWindowSnapshotProvider: { .unfocused },
            previewFreshness: PreviewFreshnessRecorder(
                report: reports.report,
                measuresDevelopmentCosts: false,
                background: inline,
                main: inline
            )
        )
        let spaceID = controller.spaceManager.activeSpaceID
        for windowID in [CGWindowID(101), 202] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toSpaceID: spaceID
            )
        }
        windowService.capturedImages = [101: contentImage(), 202: contentImage()]

        keyboardService.simulateEvent(.cmdTabHold)
        #expect(spin { controller.windowPreviews.count == 2 })
        keyboardService.simulateEvent(.escape)
        #expect(spin { reports.events("preview_freshness").count == 1 })
        let cold = try #require(reports.events("preview_freshness").first)
        #expect(cold["withPreview"] == "0")
        // The front window's capture starts at the press and may land either side of the reveal.
        #expect((Int(cold["fillsAfterReveal"] ?? "") ?? 0) >= 1)

        let batchesBefore = reports.events("preview_capture_batch").count
        keyboardService.simulateEvent(.cmdTabHold)
        // Only the front window is recaptured; the other card is served from the cache.
        #expect(spin { reports.events("preview_capture_batch").count == batchesBefore + 1 })
        keyboardService.simulateEvent(.escape)
        #expect(spin { reports.events("preview_freshness").count == 2 })
        let warm = try #require(reports.events("preview_freshness").last)
        #expect(warm["withPreview"] == "2")
        #expect(warm["pendingCaptures"] == "0", "the front window is no longer left for after the reveal")
        #expect(warm["fillsAfterReveal"] == "0")
        #expect((Int(warm["replacementsAfterReveal"] ?? "") ?? 9) <= 1)
        let batch = try #require(reports.events("preview_capture_batch").last)
        #expect(batch["reason"] == "overlay_front_window")
        #expect(batch["requested"] == "1")
        #expect(batch["captured"] == "1")
    }

    @Test("A preview whose shape differs from its window by more than a few percent is flagged")
    func shapeMismatch() {
        let wide = image(gray: 1, width: 200, height: 100)
        #expect(!SpaceController.previewShapeDiffers(wide, from: CGSize(width: 1000, height: 505)))
        #expect(SpaceController.previewShapeDiffers(wide, from: CGSize(width: 1000, height: 800)))
        #expect(!SpaceController.previewShapeDiffers(wide, from: nil))
    }
}

/// Varied pixels, so the capture passes the content check.
private func contentImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for row in stride(from: 4, to: 64, by: 8) { context.fill(CGRect(x: 4, y: row, width: 40, height: 3)) }
    return context.makeImage()!
}

/// Waits off the main queue, which the controller hops to, until the condition holds.
private func spin(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
