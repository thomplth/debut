import Foundation

public struct OverlayPresentationContext: Codable, Equatable, Sendable {
    public let traceID: UUID

    public init(traceID: UUID = UUID()) {
        self.traceID = traceID
    }
}

public enum OverlayPresentationPhase: String, Codable, CaseIterable, Sendable {
    case activationRecognized = "activation_recognized"
    case mainActorDequeued = "main_actor_dequeued"
    case fullscreenProbeCompleted = "fullscreen_probe_completed"
    case controllerAccepted = "controller_accepted"
    case presentationScheduled = "presentation_scheduled"
    case presentationDeadlineFired = "presentation_deadline_fired"
    case preparationBegan = "preparation_began"
    case preparationCompleted = "preparation_completed"
    case windowOrdered = "window_ordered"
    case renderSubmitted = "render_submitted"
    case revealCompleted = "reveal_completed"
    case firstPreviewCompleted = "first_preview_completed"
    case allPreviewsCompleted = "all_previews_completed"
    case wallpaperCompleted = "wallpaper_completed"
}

public enum OverlayPresentationOutcome: String, Codable, Sendable {
    case presented
    case releasedBeforePresentation = "released_before_presentation"
    case fullscreenRejected = "fullscreen_rejected"
    case superseded
    case hiddenBeforeReveal = "hidden_before_reveal"
    case appTerminated = "app_terminated"
}

public enum OverlayProcessUse: String, Codable, Sendable {
    case firstAttempt = "first_attempt"
    case laterAttempt = "later_attempt"
}

public enum OverlayPreviewCacheState: String, Codable, Sendable {
    case empty
    case partial
    case complete

    public static func classify(cached: Int, assigned: Int) -> Self {
        guard assigned > 0, cached > 0 else { return .empty }
        return cached >= assigned ? .complete : .partial
    }
}

public enum OverlayWallpaperState: String, Codable, Sendable {
    case ready
    case capturePending = "capture_pending"
    case unavailable
}

public enum OverlayHostingViewState: String, Codable, Sendable {
    case created
    case reused
    case unknown
}

public enum OverlayProcessAge: String, Codable, Sendable {
    case underMinute = "under_1m"
    case oneToTenMinutes = "1_10m"
    case overTenMinutes = "gte_10m"
}

public struct OverlayPresentationEnvironment: Codable, Equatable, Sendable {
    public var processUse: OverlayProcessUse
    public var previewCache: OverlayPreviewCacheState
    public var wallpaperState: OverlayWallpaperState
    public var hostingView: OverlayHostingViewState
    public var processAge: OverlayProcessAge
    public var workload: PerformanceWorkload
    public var cachedPreviewCount: Int

    public init(
        processUse: OverlayProcessUse,
        previewCache: OverlayPreviewCacheState,
        wallpaperState: OverlayWallpaperState,
        hostingView: OverlayHostingViewState,
        processAge: OverlayProcessAge,
        workload: PerformanceWorkload,
        cachedPreviewCount: Int
    ) {
        self.processUse = processUse
        self.previewCache = previewCache
        self.wallpaperState = wallpaperState
        self.hostingView = hostingView
        self.processAge = processAge
        self.workload = workload
        self.cachedPreviewCount = max(0, cachedPreviewCount)
    }
}

public struct OverlayPresentationPhaseMark: Codable, Equatable, Sendable {
    public let phase: OverlayPresentationPhase
    public let elapsedMilliseconds: Double
}

public struct OverlayPresentationTrace: Codable, Equatable, Sendable {
    public let traceID: UUID
    public let startedAt: Date
    public var completedAt: Date
    public var outcome: OverlayPresentationOutcome
    public var durationMilliseconds: Double
    public let configuredDelayMilliseconds: Double
    public var presentationDelayMilliseconds: Double?
    public var presentationDelayOvershootMilliseconds: Double?
    public var inputLatencyMilliseconds: Double?
    public var phases: [OverlayPresentationPhaseMark]
    public var environment: OverlayPresentationEnvironment

    fileprivate let startedMonotonicNanoseconds: UInt64
}

public struct OverlayPresentationActiveTrace: Codable, Equatable, Sendable {
    public let traceID: UUID
    public let startedAt: Date
    public let configuredDelayMilliseconds: Double
    public let phases: [OverlayPresentationPhaseMark]
    public let environment: OverlayPresentationEnvironment
}

public struct OverlayPresentationSnapshot: Codable, Equatable, Sendable {
    public let active: [OverlayPresentationActiveTrace]
    public let completed: [OverlayPresentationTrace]
}

public final class OverlayPresentationRecorder: @unchecked Sendable {
    private struct Active {
        let context: OverlayPresentationContext
        let startedAt: Date
        let startedNanoseconds: UInt64
        var configuredDelayMilliseconds: Double
        let inputLatencyMilliseconds: Double?
        var phases: [OverlayPresentationPhaseMark]
        var environment: OverlayPresentationEnvironment
    }

    public static let shared = OverlayPresentationRecorder()

    private let lock = NSLock()
    private let performanceRecorder: PerformanceRecorder
    private let now: @Sendable () -> UInt64
    private let wallNow: @Sendable () -> Date
    private let inputLatencyClock: InputLatencyClock
    private let capacity: Int
    private let launchedNanoseconds: UInt64
    private var active: [UUID: Active] = [:]
    private var completed: [OverlayPresentationTrace] = []
    private var attemptCount = 0

    public init(
        performanceRecorder: PerformanceRecorder = .shared,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallNow: @escaping @Sendable () -> Date = Date.init,
        inputLatencyClock: InputLatencyClock = InputLatencyClock(),
        capacity: Int = 20
    ) {
        self.performanceRecorder = performanceRecorder
        self.now = now
        self.wallNow = wallNow
        self.inputLatencyClock = inputLatencyClock
        self.capacity = max(1, capacity)
        self.launchedNanoseconds = now()
    }

    @discardableResult
    public func begin(
        configuredDelayMilliseconds: Double,
        eventTimestamp: UInt64 = 0
    ) -> OverlayPresentationContext {
        let started = now()
        let inputLatency = inputLatencyClock.latencyMilliseconds(
            eventTimestamp: eventTimestamp,
            arrivalNanoseconds: started
        )
        finalizeAll(outcome: .superseded)
        let context = OverlayPresentationContext()
        lock.lock()
        let processUse: OverlayProcessUse = attemptCount == 0 ? .firstAttempt : .laterAttempt
        attemptCount += 1
        let environment = OverlayPresentationEnvironment(
            processUse: processUse,
            previewCache: .empty,
            wallpaperState: .unavailable,
            hostingView: .unknown,
            processAge: processAge(at: started),
            workload: .init(),
            cachedPreviewCount: 0
        )
        active[context.traceID] = Active(
            context: context,
            startedAt: wallNow(),
            startedNanoseconds: started,
            configuredDelayMilliseconds: max(0, configuredDelayMilliseconds),
            inputLatencyMilliseconds: inputLatency,
            phases: [.init(phase: .activationRecognized, elapsedMilliseconds: 0)],
            environment: environment
        )
        lock.unlock()
        _ = performanceRecorder.begin(
            .overlayEndToEndVisible,
            correlationID: context.traceID,
            traceID: context.traceID
        )
        return context
    }

    public func mark(_ phase: OverlayPresentationPhase, for context: OverlayPresentationContext) {
        let timestamp = now()
        lock.lock()
        if var trace = active[context.traceID] {
            append(phase, at: timestamp, to: &trace.phases, started: trace.startedNanoseconds)
            active[context.traceID] = trace
        } else if let index = completed.lastIndex(where: { $0.traceID == context.traceID }) {
            append(
                phase,
                at: timestamp,
                to: &completed[index].phases,
                started: completed[index].startedMonotonicNanoseconds
            )
        }
        lock.unlock()
    }

    public func updateEnvironment(
        for context: OverlayPresentationContext,
        previewCache: OverlayPreviewCacheState,
        wallpaperState: OverlayWallpaperState,
        hostingView: OverlayHostingViewState? = nil,
        workload: PerformanceWorkload,
        cachedPreviewCount: Int
    ) {
        lock.lock()
        guard var trace = active[context.traceID] else {
            lock.unlock()
            return
        }
        trace.environment.previewCache = previewCache
        trace.environment.wallpaperState = wallpaperState
        if let hostingView { trace.environment.hostingView = hostingView }
        trace.environment.workload = workload
        trace.environment.cachedPreviewCount = max(0, cachedPreviewCount)
        active[context.traceID] = trace
        lock.unlock()
        performanceRecorder.updateWorkload(workload, for: context.traceID)
        let temperature: TelemetryTemperature = if trace.environment.processUse == .firstAttempt {
            .processFirst
        } else if previewCache == .empty {
            .cacheCold
        } else {
            .warm
        }
        performanceRecorder.updateTemperature(temperature, for: context.traceID)
    }

    public func updateConfiguredDelay(
        milliseconds: Double,
        for context: OverlayPresentationContext
    ) {
        lock.lock()
        if var trace = active[context.traceID] {
            trace.configuredDelayMilliseconds = max(0, milliseconds)
            active[context.traceID] = trace
        }
        lock.unlock()
    }

    public func updateHostingView(
        _ hostingView: OverlayHostingViewState,
        for context: OverlayPresentationContext
    ) {
        lock.lock()
        if var trace = active[context.traceID] {
            trace.environment.hostingView = hostingView
            active[context.traceID] = trace
        }
        lock.unlock()
    }

    public func complete(
        _ context: OverlayPresentationContext,
        outcome: OverlayPresentationOutcome
    ) {
        let ended = now()
        lock.lock()
        guard var trace = active.removeValue(forKey: context.traceID) else {
            lock.unlock()
            return
        }
        if outcome == .presented {
            append(.revealCompleted, at: ended, to: &trace.phases, started: trace.startedNanoseconds)
        }
        let delay = elapsedBetween(
            .presentationScheduled,
            and: .presentationDeadlineFired,
            in: trace.phases
        )
        let observation = OverlayPresentationTrace(
            traceID: context.traceID,
            startedAt: trace.startedAt,
            completedAt: wallNow(),
            outcome: outcome,
            durationMilliseconds: milliseconds(from: trace.startedNanoseconds, to: ended),
            configuredDelayMilliseconds: trace.configuredDelayMilliseconds,
            presentationDelayMilliseconds: delay,
            presentationDelayOvershootMilliseconds: delay.map {
                max(0, $0 - trace.configuredDelayMilliseconds)
            },
            inputLatencyMilliseconds: trace.inputLatencyMilliseconds,
            phases: trace.phases,
            environment: trace.environment,
            startedMonotonicNanoseconds: trace.startedNanoseconds
        )
        completed.append(observation)
        if completed.count > capacity { completed.removeFirst(completed.count - capacity) }
        lock.unlock()

        if outcome == .presented {
            _ = performanceRecorder.end(context.traceID)
        } else {
            performanceRecorder.cancel(context.traceID)
        }
    }

    public func finalizeAll(outcome: OverlayPresentationOutcome) {
        lock.lock()
        let contexts = active.values.map(\.context)
        lock.unlock()
        for context in contexts { complete(context, outcome: outcome) }
    }

    public func snapshot() -> OverlayPresentationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return OverlayPresentationSnapshot(
            active: active.values.map {
                OverlayPresentationActiveTrace(
                    traceID: $0.context.traceID,
                    startedAt: $0.startedAt,
                    configuredDelayMilliseconds: $0.configuredDelayMilliseconds,
                    phases: $0.phases,
                    environment: $0.environment
                )
            }.sorted { $0.startedAt < $1.startedAt },
            completed: completed
        )
    }

    private func processAge(at timestamp: UInt64) -> OverlayProcessAge {
        let age = timestamp >= launchedNanoseconds ? timestamp - launchedNanoseconds : 0
        if age < 60_000_000_000 { return .underMinute }
        if age < 600_000_000_000 { return .oneToTenMinutes }
        return .overTenMinutes
    }

    private func append(
        _ phase: OverlayPresentationPhase,
        at timestamp: UInt64,
        to phases: inout [OverlayPresentationPhaseMark],
        started: UInt64
    ) {
        guard !phases.contains(where: { $0.phase == phase }) else { return }
        phases.append(.init(
            phase: phase,
            elapsedMilliseconds: milliseconds(from: started, to: timestamp)
        ))
    }

    private func elapsedBetween(
        _ first: OverlayPresentationPhase,
        and second: OverlayPresentationPhase,
        in phases: [OverlayPresentationPhaseMark]
    ) -> Double? {
        guard let start = phases.first(where: { $0.phase == first })?.elapsedMilliseconds,
              let end = phases.first(where: { $0.phase == second })?.elapsedMilliseconds
        else { return nil }
        return max(0, end - start)
    }

    private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }
}
