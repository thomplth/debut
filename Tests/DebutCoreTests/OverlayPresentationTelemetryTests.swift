import Foundation
import Testing
@testable import DebutCore

@Suite("Overlay presentation telemetry")
struct OverlayPresentationTelemetryTests {
    private final class Clock: @unchecked Sendable {
        var nanoseconds: UInt64 = 0
        var date = Date(timeIntervalSince1970: 1_700_000_000)

        func advance(milliseconds: UInt64) {
            nanoseconds += milliseconds * 1_000_000
            date.addTimeInterval(Double(milliseconds) / 1_000)
        }
    }

    @Test("One trace reconstructs activation through full reveal")
    func completeTrace() throws {
        let clock = Clock()
        let performance = PerformanceRecorder(
            resourceReader: UnavailableProcessResourceReader(),
            now: { clock.nanoseconds }
        )
        let recorder = OverlayPresentationRecorder(
            performanceRecorder: performance,
            now: { clock.nanoseconds },
            wallNow: { clock.date }
        )

        let context = recorder.begin(configuredDelayMilliseconds: 80)
        clock.advance(milliseconds: 10)
        recorder.mark(.mainActorDequeued, for: context)
        clock.advance(milliseconds: 10)
        recorder.mark(.presentationScheduled, for: context)
        clock.advance(milliseconds: 100)
        recorder.mark(.presentationDeadlineFired, for: context)
        clock.advance(milliseconds: 20)
        recorder.mark(.preparationBegan, for: context)
        clock.advance(milliseconds: 10)
        recorder.mark(.renderSubmitted, for: context)
        clock.advance(milliseconds: 150)
        recorder.complete(context, outcome: .presented)

        let trace = try #require(recorder.snapshot().completed.last)
        #expect(trace.traceID == context.traceID)
        #expect(trace.outcome == .presented)
        #expect(trace.durationMilliseconds == 300)
        #expect(trace.presentationDelayMilliseconds == 100)
        #expect(trace.presentationDelayOvershootMilliseconds == 20)
        #expect(trace.phases.map(\.phase) == [
            .activationRecognized, .mainActorDequeued, .presentationScheduled,
            .presentationDeadlineFired, .preparationBegan, .renderSubmitted,
            .revealCompleted,
        ])
        let endToEnd = performance.snapshot().recent.last {
            $0.operation == .overlayEndToEndVisible
        }
        #expect(endToEnd?.correlationID == context.traceID)
        #expect(endToEnd?.durationMilliseconds == 300)
    }

    @Test("Cancelled and superseded attempts never enter successful latency samples")
    func unsuccessfulAttempts() throws {
        let clock = Clock()
        let performance = PerformanceRecorder(
            resourceReader: UnavailableProcessResourceReader(),
            now: { clock.nanoseconds }
        )
        let recorder = OverlayPresentationRecorder(
            performanceRecorder: performance,
            now: { clock.nanoseconds },
            wallNow: { clock.date }
        )

        let first = recorder.begin(configuredDelayMilliseconds: 80)
        clock.advance(milliseconds: 20)
        let second = recorder.begin(configuredDelayMilliseconds: 80)
        clock.advance(milliseconds: 30)
        recorder.complete(second, outcome: .releasedBeforePresentation)

        #expect(recorder.snapshot().completed.map(\.outcome) == [
            .superseded, .releasedBeforePresentation,
        ])
        #expect(performance.snapshot().recent.allSatisfy {
            $0.operation != .overlayEndToEndVisible
        })
        #expect(first.traceID != second.traceID)
    }

    @Test("Async child phases remain attachable after reveal")
    func asyncChildPhases() throws {
        let clock = Clock()
        let recorder = OverlayPresentationRecorder(
            performanceRecorder: PerformanceRecorder(
                resourceReader: UnavailableProcessResourceReader(),
                now: { clock.nanoseconds }
            ),
            now: { clock.nanoseconds },
            wallNow: { clock.date }
        )
        let context = recorder.begin(configuredDelayMilliseconds: 0)
        clock.advance(milliseconds: 20)
        recorder.complete(context, outcome: .presented)
        clock.advance(milliseconds: 30)
        recorder.mark(.firstPreviewCompleted, for: context)
        clock.advance(milliseconds: 50)
        recorder.mark(.allPreviewsCompleted, for: context)

        let trace = try #require(recorder.snapshot().completed.last)
        #expect(trace.phases.last?.phase == .allPreviewsCompleted)
        #expect(trace.phases.last?.elapsedMilliseconds == 100)
        #expect(trace.durationMilliseconds == 20)
    }

    @Test("Cache and process temperature are orthogonal")
    func temperatureDimensions() {
        #expect(OverlayPreviewCacheState.classify(cached: 0, assigned: 8) == .empty)
        #expect(OverlayPreviewCacheState.classify(cached: 3, assigned: 8) == .partial)
        #expect(OverlayPreviewCacheState.classify(cached: 8, assigned: 8) == .complete)
        #expect(OverlayPreviewCacheState.classify(cached: 0, assigned: 0) == .empty)

        let environment = OverlayPresentationEnvironment(
            processUse: .firstAttempt,
            previewCache: .complete,
            wallpaperState: .ready,
            hostingView: .created,
            processAge: .underMinute,
            workload: .init(stages: 4, windows: 8, captures: 8),
            cachedPreviewCount: 8
        )
        #expect(environment.processUse == .firstAttempt)
        #expect(environment.previewCache == .complete)
    }
}
