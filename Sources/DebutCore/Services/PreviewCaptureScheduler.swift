import CoreGraphics
import Foundation

/// How soon a preview is needed. Lower is sooner.
enum PreviewCapturePriority: Int, Comparable, Sendable {
    /// The card the overlay has selected.
    case selected
    /// Cards on the stage the overlay is showing.
    case visible
    /// Any other card in an open overlay, and the startup prewarm.
    case overlay
    /// A capture no one is looking at yet, taken because a window event made the old one stale.
    case background

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PreviewCaptureRequest: Equatable, Sendable {
    let windowID: CGWindowID
    var priority: PreviewCapturePriority
    var reason: String
}

/// Orders preview captures per window (KHA-1080).
///
/// The controller used to hand every capture to one task and cancel it whenever a new request
/// arrived, so an overlay open threw away work already under way, and captures ran all at once.
/// On macOS 27 running captures concurrently is slower than running them in turn: 30 windows
/// took 1.29s one at a time and ~2.5s at any concurrency of 2 or more (capbench, 2026-10-13).
///
/// So one batch is in flight at a time and the service captures it in order. Everything ready
/// when a batch finishes leaves as the next one, most urgent first. A request for a window
/// already being captured is dropped; the capture under way is at most a few tens of
/// milliseconds older than the event that asked. A window queued twice keeps its higher
/// priority. Background requests wait until the window's last capture is `backgroundInterval`
/// old; anything an open overlay asks for goes at once.
///
/// Main-queue confined.
final class PreviewCaptureScheduler {
    typealias Dispatch = (_ batch: [PreviewCaptureRequest], _ completion: @escaping () -> Void) -> Void
    typealias Wake = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    static let defaultBackgroundInterval: TimeInterval = 1

    private let backgroundInterval: UInt64
    private let now: () -> UInt64
    private let wake: Wake
    private let dispatch: Dispatch
    private var queued: [CGWindowID: (request: PreviewCaptureRequest, order: Int)] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var lastStarted: [CGWindowID: UInt64] = [:]
    private var arrivals = 0
    private var generation = 0
    private var wakeAt: UInt64?

    init(
        backgroundInterval: TimeInterval = PreviewCaptureScheduler.defaultBackgroundInterval,
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wake: @escaping Wake = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        dispatch: @escaping Dispatch
    ) {
        self.backgroundInterval = UInt64(max(0, backgroundInterval) * 1_000_000_000)
        self.now = now
        self.wake = wake
        self.dispatch = dispatch
    }

    var isIdle: Bool { inFlight.isEmpty && queued.isEmpty }

    func enqueue(_ requests: [PreviewCaptureRequest]) {
        for request in requests where !inFlight.contains(request.windowID) {
            if var existing = queued[request.windowID] {
                if request.priority < existing.request.priority { existing.request = request }
                queued[request.windowID] = existing
            } else {
                arrivals += 1
                queued[request.windowID] = (request, arrivals)
            }
        }
        pump()
    }

    /// Drops everything queued. A batch already in flight runs to the end, but its completion
    /// no longer starts another.
    func reset() {
        generation += 1
        queued.removeAll()
        inFlight.removeAll()
        wakeAt = nil
    }

    private func pump() {
        guard inFlight.isEmpty, !queued.isEmpty else { return }
        let time = now()
        let ready = queued.values.filter { isReady($0.request, at: time) }
        guard !ready.isEmpty else {
            scheduleWake(at: time)
            return
        }
        let batch = ready
            .sorted { ($0.request.priority, $0.order) < ($1.request.priority, $1.order) }
            .map(\.request)
        for request in batch {
            queued[request.windowID] = nil
            inFlight.insert(request.windowID)
            lastStarted[request.windowID] = time
        }
        let generation = generation
        dispatch(batch) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.inFlight.removeAll()
            self.pump()
        }
    }

    private func isReady(_ request: PreviewCaptureRequest, at time: UInt64) -> Bool {
        guard request.priority == .background, let started = lastStarted[request.windowID] else {
            return true
        }
        return time &- started >= backgroundInterval
    }

    private func scheduleWake(at time: UInt64) {
        let due = queued.values.compactMap { entry in
            lastStarted[entry.request.windowID].map { $0 + backgroundInterval }
        }.min()
        guard let due, wakeAt.map({ due < $0 }) ?? true else { return }
        wakeAt = due
        let generation = generation
        wake(Double(due &- time) / 1_000_000_000) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.wakeAt = nil
            self.pump()
        }
    }
}
