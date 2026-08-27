import Foundation

public enum GesturePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case debutInstant
    case debutDriven
    case spaceRabbitLegacy
    case instantSpaceSwitcher
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .debutInstant: "Debut · Instant"
        case .debutDriven: "Debut · Driven"
        case .spaceRabbitLegacy: "Space Rabbit · Legacy instant"
        case .instantSpaceSwitcher: "InstantSpaceSwitcher"
        case .custom: "Custom blend"
        }
    }

    public var summary: String {
        switch self {
        case .debutInstant:
            "Began → Ended at velocity 400, with Dock envelopes; confirms every adjacent hop."
        case .debutDriven:
            "Began → timed Changed samples → Ended; cubic ease-out over 150 ms."
        case .spaceRabbitLegacy:
            "Legacy Began → Ended instant recipe, posting distant hops without confirmation."
        case .instantSpaceSwitcher:
            "Began → Changed → Ended at velocity 2000 on X and Y, with tiny progress on every phase."
        case .custom:
            "A freely adjustable recipe based on the last selected preset."
        }
    }
}

public enum ChangedEventMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case single
    case timed

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "None"
        case .single: "One immediate Changed"
        case .timed: "Timed samples"
        }
    }
}

public enum VelocityPhases: String, Codable, CaseIterable, Identifiable, Sendable {
    case endedOnly
    case all

    public var id: String { rawValue }
    public var title: String { self == .endedOnly ? "Ended only" : "Every phase" }
}

public enum YVelocityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case zero
    case matchX

    public var id: String { rawValue }
    public var title: String { self == .zero ? "Zero" : "Match X" }
}

public enum GestureEasing: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear
    case cubicEaseOut

    public var id: String { rawValue }
    public var title: String { self == .linear ? "Linear" : "Cubic ease-out" }

    func apply(_ fraction: Double) -> Double {
        switch self {
        case .linear: fraction
        case .cubicEaseOut: 1 - pow(1 - fraction, 3)
        }
    }
}

public enum EventLocationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case displayCenter
    case pointer
    case unset

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .displayCenter: "Target display center"
        case .pointer: "Current pointer"
        case .unset: "Leave unset"
        }
    }
}

public enum HopScheduling: String, Codable, CaseIterable, Identifiable, Sendable {
    case confirmedAdjacent
    case batched

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .confirmedAdjacent: "Confirm each adjacent hop"
        case .batched: "Post all hops immediately"
        }
    }
}

public enum GesturePhase: String, Codable, Sendable {
    case began
    case changed
    case ended

    public var rawValueForEvent: Int64 {
        switch self {
        case .began: 1
        case .changed: 2
        case .ended: 4
        }
    }
}

public enum SwitchDirection: String, Codable, Equatable, Sendable {
    case left
    case right

    public var sign: Double { self == .right ? 1 : -1 }
    public var flagBits: Int64 { self == .right ? 1 : 0 }
}

public struct GestureFrame: Equatable, Sendable {
    public let phase: GesturePhase
    public let delayMilliseconds: Double
    public let progress: Double
    public let velocityX: Double
    public let velocityY: Double
}

public struct GestureRecipe: Codable, Equatable, Sendable {
    public var changedEvents: ChangedEventMode
    public var beganProgress: Double
    public var changedProgress: Double
    public var endedProgress: Double
    public var velocity: Double
    public var velocityPhases: VelocityPhases
    public var yVelocity: YVelocityMode
    public var durationMilliseconds: Double
    public var sampleRate: Double
    public var easing: GestureEasing
    public var includeEnvelope: Bool
    public var includeDirectionFlag: Bool
    public var includeZoomEpsilon: Bool
    public var includeHorizontalMotion: Bool
    public var includeScrollY: Bool
    public var eventLocation: EventLocationMode
    public var hopScheduling: HopScheduling
    public var scaleVelocityByDistance: Bool

    public static func preset(_ preset: GesturePreset) -> GestureRecipe {
        switch preset {
        case .debutInstant, .custom:
            return GestureRecipe(
                changedEvents: .none,
                beganProgress: 0,
                changedProgress: 1,
                endedProgress: 2,
                velocity: 400,
                velocityPhases: .endedOnly,
                yVelocity: .zero,
                durationMilliseconds: 0,
                sampleRate: 120,
                easing: .cubicEaseOut,
                includeEnvelope: true,
                includeDirectionFlag: true,
                includeZoomEpsilon: true,
                includeHorizontalMotion: true,
                includeScrollY: true,
                eventLocation: .displayCenter,
                hopScheduling: .confirmedAdjacent,
                scaleVelocityByDistance: false
            )
        case .debutDriven:
            return GestureRecipe(
                changedEvents: .timed,
                beganProgress: 0,
                changedProgress: 1,
                endedProgress: 1,
                velocity: 60,
                velocityPhases: .endedOnly,
                yVelocity: .zero,
                durationMilliseconds: 150,
                sampleRate: 120,
                easing: .cubicEaseOut,
                includeEnvelope: true,
                includeDirectionFlag: true,
                includeZoomEpsilon: true,
                includeHorizontalMotion: true,
                includeScrollY: true,
                eventLocation: .displayCenter,
                hopScheduling: .confirmedAdjacent,
                scaleVelocityByDistance: false
            )
        case .spaceRabbitLegacy:
            return GestureRecipe(
                changedEvents: .none,
                beganProgress: 0,
                changedProgress: 1,
                endedProgress: 2,
                velocity: 400,
                velocityPhases: .endedOnly,
                yVelocity: .zero,
                durationMilliseconds: 0,
                sampleRate: 120,
                easing: .cubicEaseOut,
                includeEnvelope: true,
                includeDirectionFlag: true,
                includeZoomEpsilon: true,
                includeHorizontalMotion: true,
                includeScrollY: true,
                eventLocation: .displayCenter,
                hopScheduling: .batched,
                scaleVelocityByDistance: false
            )
        case .instantSpaceSwitcher:
            let epsilon = Double(Float.leastNonzeroMagnitude)
            return GestureRecipe(
                changedEvents: .single,
                beganProgress: epsilon,
                changedProgress: epsilon,
                endedProgress: epsilon,
                velocity: 2000,
                velocityPhases: .all,
                yVelocity: .matchX,
                durationMilliseconds: 0,
                sampleRate: 120,
                easing: .linear,
                includeEnvelope: false,
                includeDirectionFlag: false,
                includeZoomEpsilon: false,
                includeHorizontalMotion: false,
                includeScrollY: false,
                eventLocation: .unset,
                hopScheduling: .batched,
                scaleVelocityByDistance: true
            )
        }
    }

    public func sanitized() -> GestureRecipe {
        var result = self
        result.durationMilliseconds = durationMilliseconds.clamped(to: 0...1_000)
        result.sampleRate = sampleRate.clamped(to: 1...240)
        result.velocity = velocity.clamped(to: 0...10_000)
        result.beganProgress = beganProgress.clamped(to: -10...10)
        result.changedProgress = changedProgress.clamped(to: -10...10)
        result.endedProgress = endedProgress.clamped(to: -10...10)
        return result
    }

    public func frames(direction: SwitchDirection, distance: Int) -> [GestureFrame] {
        let recipe = sanitized()
        let multiplier = recipe.scaleVelocityByDistance ? Double(max(1, distance)) : 1
        let signedVelocity = direction.sign * recipe.velocity * multiplier

        func frame(_ phase: GesturePhase, delay: Double, progress: Double) -> GestureFrame {
            let carriesVelocity = recipe.velocityPhases == .all || phase == .ended
            let x = carriesVelocity ? signedVelocity : 0
            return GestureFrame(
                phase: phase,
                delayMilliseconds: delay,
                progress: direction.sign * progress,
                velocityX: x,
                velocityY: recipe.yVelocity == .matchX ? x : 0
            )
        }

        var result = [frame(.began, delay: 0, progress: recipe.beganProgress)]
        switch recipe.changedEvents {
        case .none:
            break
        case .single:
            result.append(frame(.changed, delay: 0, progress: recipe.changedProgress))
        case .timed:
            let count = max(2, Int((recipe.durationMilliseconds / 1_000 * recipe.sampleRate).rounded()))
            for step in 1..<count {
                let fraction = Double(step) / Double(count)
                result.append(frame(
                    .changed,
                    delay: recipe.durationMilliseconds * fraction,
                    progress: recipe.changedProgress * recipe.easing.apply(fraction)
                ))
            }
        }
        result.append(frame(
            .ended,
            delay: recipe.changedEvents == .timed ? recipe.durationMilliseconds : 0,
            progress: recipe.endedProgress
        ))
        return result
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
