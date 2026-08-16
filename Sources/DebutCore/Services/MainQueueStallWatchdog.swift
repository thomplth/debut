import Foundation

/// Reports a main-queue stall while it is still happening, together with the
/// resource cost measured across it.
///
/// A stall is only visible after the fact as a long duration, which does not say
/// whether the main thread was busy or waiting. Sampling the process counters at
/// the deadline answers that: CPU near zero with page-ins points at faulting or
/// a lock, and CPU near a full core points at work.
///
/// Nothing is scheduled unless a presentation is in flight, so an idle Debut
/// still runs no timers.
final class MainQueueStallWatchdog: @unchecked Sendable {
    struct Stall: Sendable {
        let traceID: UUID?
        let elapsedMilliseconds: Double
        let resourceDelta: ProcessResourceDelta?
    }

    private struct Armed {
        let generation: Int
        let traceID: UUID?
        let startedAt: UInt64
        let resources: ProcessResourceSnapshot?
    }

    private let thresholdMilliseconds: Double
    private let resourceReader: any ProcessResourceReading
    private let now: @Sendable () -> UInt64
    private let schedule: @Sendable (Double, @escaping @Sendable () -> Void) -> Void
    private let onStall: @Sendable (Stall) -> Void
    private let lock = NSLock()
    private var generation = 0
    private var armed: Armed?

    init(
        thresholdMilliseconds: Double = 250,
        resourceReader: any ProcessResourceReading = SystemProcessResourceReader(),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        schedule: @escaping @Sendable (Double, @escaping @Sendable () -> Void) -> Void = { milliseconds, work in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(Int(milliseconds)),
                execute: work
            )
        },
        onStall: @escaping @Sendable (Stall) -> Void
    ) {
        self.thresholdMilliseconds = thresholdMilliseconds
        self.resourceReader = resourceReader
        self.now = now
        self.schedule = schedule
        self.onStall = onStall
    }

    func arm(traceID: UUID?) {
        let started = now()
        let resources = resourceReader.read()
        lock.lock()
        generation += 1
        let generation = generation
        armed = Armed(generation: generation, traceID: traceID, startedAt: started, resources: resources)
        lock.unlock()

        schedule(thresholdMilliseconds) { [weak self] in
            self?.checkDeadline(generation: generation)
        }
    }

    func disarm() {
        lock.lock()
        generation += 1
        armed = nil
        lock.unlock()
    }

    private func checkDeadline(generation: Int) {
        lock.lock()
        guard let armed, armed.generation == generation else {
            lock.unlock()
            return
        }
        // Cleared here rather than at disarm so a deadline that has already
        // fired cannot fire again for the same presentation.
        self.armed = nil
        lock.unlock()

        let elapsed = Double(now() &- armed.startedAt) / 1_000_000
        let delta = armed.resources.flatMap { start in
            resourceReader.read().flatMap { ProcessResourceDelta.between(start, $0) }
        }
        onStall(Stall(traceID: armed.traceID, elapsedMilliseconds: elapsed, resourceDelta: delta))
    }
}
