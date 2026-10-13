import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

/// Drives the scheduler by hand: batches complete when the test says, and time only moves when
/// the test moves it.
private final class SchedulerHarness {
    var now: UInt64 = 1_000_000_000
    var dispatched: [[PreviewCaptureRequest]] = []
    var pendingCompletions: [() -> Void] = []
    var wakes: [(at: UInt64, work: () -> Void)] = []
    lazy var scheduler = PreviewCaptureScheduler(
        backgroundInterval: 1,
        now: { [unowned self] in now },
        wake: { [unowned self] delay, work in
            wakes.append((now + UInt64(delay * 1_000_000_000), work))
        },
        dispatch: { [unowned self] batch, completion in
            dispatched.append(batch)
            pendingCompletions.append(completion)
        }
    )

    func completeBatch() {
        pendingCompletions.removeFirst()()
    }

    func advance(seconds: Double) {
        now += UInt64(seconds * 1_000_000_000)
        let due = wakes.filter { $0.at <= now }
        wakes.removeAll { $0.at <= now }
        due.forEach { $0.work() }
    }

    var lastBatchIDs: [CGWindowID] { dispatched.last?.map(\.windowID) ?? [] }
}

@Suite("Preview capture scheduler")
struct PreviewCaptureSchedulerTests {
    @Test("Ready requests leave as one batch, most urgent first")
    func batchesByPriority() {
        let harness = SchedulerHarness()
        harness.scheduler.enqueue([
            .init(windowID: 3, priority: .overlay, reason: "overlay_refresh"),
            .init(windowID: 1, priority: .selected, reason: "overlay_refresh"),
            .init(windowID: 2, priority: .visible, reason: "overlay_refresh"),
        ])
        #expect(harness.dispatched.count == 1)
        #expect(harness.lastBatchIDs == [1, 2, 3])
    }

    @Test("Work queued behind a batch in flight waits for it instead of cancelling it")
    func queuesBehindInFlight() {
        let harness = SchedulerHarness()
        harness.scheduler.enqueue([.init(windowID: 1, priority: .background, reason: "focus_left")])
        harness.scheduler.enqueue([
            .init(windowID: 2, priority: .overlay, reason: "overlay_refresh"),
            .init(windowID: 3, priority: .selected, reason: "overlay_refresh"),
        ])
        #expect(harness.dispatched.count == 1, "one batch at a time")
        harness.completeBatch()
        #expect(harness.dispatched.count == 2)
        #expect(harness.lastBatchIDs == [3, 2])
    }

    @Test("A request for a window already being captured is dropped")
    func dropsInFlightDuplicate() {
        let harness = SchedulerHarness()
        harness.scheduler.enqueue([.init(windowID: 1, priority: .overlay, reason: "overlay_refresh")])
        harness.scheduler.enqueue([.init(windowID: 1, priority: .selected, reason: "overlay_refresh")])
        harness.completeBatch()
        #expect(harness.dispatched.count == 1)
    }

    @Test("A window queued twice is captured once, at the higher priority")
    func mergesQueuedDuplicate() {
        let harness = SchedulerHarness()
        harness.scheduler.enqueue([.init(windowID: 9, priority: .background, reason: "focus_left")])
        harness.scheduler.enqueue([
            .init(windowID: 1, priority: .overlay, reason: "overlay_refresh"),
            .init(windowID: 2, priority: .background, reason: "title_changed"),
        ])
        harness.scheduler.enqueue([.init(windowID: 2, priority: .selected, reason: "overlay_refresh")])
        harness.completeBatch()
        #expect(harness.lastBatchIDs == [2, 1])
        #expect(harness.dispatched.last?.first?.reason == "overlay_refresh")
    }

    @Test("A background capture waits out the per-window interval; an overlay capture does not")
    func throttlesBackgroundOnly() {
        let harness = SchedulerHarness()
        harness.scheduler.enqueue([.init(windowID: 1, priority: .background, reason: "focus_left")])
        harness.completeBatch()
        harness.advance(seconds: 0.3)
        harness.scheduler.enqueue([.init(windowID: 1, priority: .background, reason: "focus_arrived")])
        #expect(harness.dispatched.count == 1, "captured 0.3s ago")
        harness.advance(seconds: 0.8)
        #expect(harness.dispatched.count == 2, "released when the interval ends")

        harness.completeBatch()
        harness.scheduler.enqueue([.init(windowID: 1, priority: .selected, reason: "overlay_refresh")])
        #expect(harness.dispatched.count == 3, "the overlay never waits")
    }

    @Test("Suspending background capture keeps what an open overlay asked for")
    func dropBackgroundKeepsOverlay() {
        let harness = SchedulerHarness()
        harness.scheduler.enqueue([.init(windowID: 9, priority: .overlay, reason: "overlay_refresh")])
        harness.scheduler.enqueue([
            .init(windowID: 1, priority: .background, reason: "focus_left"),
            .init(windowID: 2, priority: .selected, reason: "overlay_refresh"),
        ])
        harness.scheduler.dropBackground()
        harness.completeBatch()
        #expect(harness.lastBatchIDs == [2])
    }

    @Test("Resetting drops queued work and ignores the batch in flight")
    func resetDropsQueue() {
        let harness = SchedulerHarness()
        harness.scheduler.enqueue([.init(windowID: 1, priority: .overlay, reason: "overlay_refresh")])
        harness.scheduler.enqueue([.init(windowID: 2, priority: .overlay, reason: "overlay_refresh")])
        harness.scheduler.reset()
        harness.completeBatch()
        #expect(harness.dispatched.count == 1)
        harness.scheduler.enqueue([.init(windowID: 1, priority: .overlay, reason: "overlay_refresh")])
        #expect(harness.dispatched.count == 2, "a reset leaves nothing in flight")
    }
}

@Suite("Capture handle catalog")
struct CaptureHandleCatalogTests {
    private final class Enumerations: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var visible: [Int]
        init(_ visible: [Int]) { self.visible = visible }
        var count: Int { lock.withLock { calls } }
        func list() -> [Int] { lock.withLock { calls += 1; return visible } }
    }

    @Test("Held handles are reused and the list is fetched again only for a missing window")
    func reusesHandles() async throws {
        let enumerations = Enumerations([1, 2])
        let catalog = CaptureHandleCatalog<Int>(identify: { CGWindowID($0) }) { enumerations.list() }
        #expect(try await catalog.handles(for: [1, 2]) == [1, 2])
        #expect(try await catalog.handles(for: [2]) == [2])
        #expect(enumerations.count == 1)

        enumerations.visible = [1, 2, 3]
        #expect(try await catalog.handles(for: [3, 1]) == [3, 1], "a new window triggers one fetch")
        #expect(enumerations.count == 2)
        #expect(try await catalog.handles(for: [4]) == [], "a window still missing is simply absent")
        #expect(enumerations.count == 3)
    }

    @Test("A handle whose capture failed is fetched again next time")
    func evictsFailedHandle() async throws {
        let enumerations = Enumerations([1])
        let catalog = CaptureHandleCatalog<Int>(identify: { CGWindowID($0) }) { enumerations.list() }
        _ = try await catalog.handles(for: [1])
        await catalog.evict(1)
        _ = try await catalog.handles(for: [1])
        #expect(enumerations.count == 2)
    }
}
