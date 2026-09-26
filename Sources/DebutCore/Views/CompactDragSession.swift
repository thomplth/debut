import CoreGraphics
import Foundation
import Observation

/// The one compact window drag an overlay can have in flight (KHA-553).
///
/// Owned by `OverlayWindow` rather than by a view, so a root update that replaces the view value
/// cannot restart it, and hiding the overlay can cancel it before the fade begins. Every scheduled
/// completion carries the session it was scheduled for; one that outlives its session is a no-op.
@MainActor
@Observable
final class CompactDragSession {
    enum Phase: Equatable {
        case idle
        case dragging
        case acceptingDrop
        case settling
    }

    enum Outcome: Equatable {
        case accepted(CompactDropIntent)
        case noChange
        case cancelled(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snapshot: CompactDragSnapshot?
    private(set) var intent: CompactDropIntent?
    private(set) var window: StageWindowData?
    private(set) var presentedGeneration: UInt64?
    private(set) var lastCancellation: String?
    var proxyLocation: CGPoint = .zero
    private var lastPointer: CGPoint?
    private var nextGeneration: UInt64 = 0

    var isActive: Bool { phase != .idle }
    var sessionID: UUID? { snapshot?.sessionID }

    /// Pointer-driven stage focus, hover selection and scroll navigation are all off while a
    /// compact stack is up; it is only the pointer's target that moves.
    var suppressesNavigation: Bool { isActive }

    func makeGeneration() -> UInt64 {
        nextGeneration += 1
        return nextGeneration
    }

    /// Enters compact presentation. The generation is not yet presented: a release before the
    /// compact root reports it laid out cannot accept a target the user never saw.
    func begin(snapshot: CompactDragSnapshot, window: StageWindowData, at location: CGPoint) {
        self.snapshot = snapshot
        self.window = window
        presentedGeneration = nil
        lastCancellation = nil
        phase = .dragging
        proxyLocation = location
        lastPointer = location
        intent = snapshot.resolve(at: location, current: nil)
    }

    /// Called from the compact root's own layout, never from `begin`.
    func acknowledgePresented(generation: UInt64) {
        guard phase == .dragging, snapshot?.generation == generation else { return }
        presentedGeneration = generation
    }

    /// Retargets from a pointer event. The caller moves `proxyLocation`, so the proxy can track
    /// the pointer exactly while the gap it opens animates.
    func move(to location: CGPoint) {
        guard phase == .dragging, let snapshot else { return }
        guard location != lastPointer else { return }
        lastPointer = location
        intent = snapshot.resolve(at: location, current: intent)
    }

    /// Resolves the release once and hands a valid edit to `accept` exactly once, synchronously,
    /// before any animation. Everything else returns to normal presentation without an edit.
    func release(
        at location: CGPoint,
        accept: (PointerWindowDropRequest) -> PointerWindowDropResult
    ) -> Outcome {
        guard phase == .dragging, let snapshot else { return .cancelled("not dragging") }
        guard presentedGeneration == snapshot.generation else {
            cancel(reason: "released before compact layout was presented")
            return .cancelled("released before compact layout was presented")
        }
        if location != lastPointer {
            lastPointer = location
            intent = snapshot.resolve(at: location, current: intent)
        }
        proxyLocation = location
        guard let intent, intent.generation == snapshot.generation else {
            cancel(reason: "released outside every stage")
            return .cancelled("released outside every stage")
        }
        if snapshot.isNoOp(intent) {
            cancel(reason: nil)
            return .noChange
        }
        guard let request = snapshot.dropRequest(for: intent) else {
            cancel(reason: "destination unavailable")
            return .cancelled("destination unavailable")
        }

        phase = .acceptingDrop
        switch accept(request) {
        case .accepted:
            phase = .settling
            return .accepted(intent)
        case .noChange:
            cancel(reason: nil)
            return .noChange
        case let .rejected(reason):
            cancel(reason: reason)
            return .cancelled(reason)
        }
    }

    /// Ends a settle that belongs to `sessionID`. A completion from an earlier session, or one
    /// that arrives after a cancellation, changes nothing.
    func finishSettling(sessionID: UUID) {
        guard phase == .settling, snapshot?.sessionID == sessionID else { return }
        reset()
    }

    /// Returns any phase to idle. Cancelling a held drag adds no edit; an already accepted drop
    /// stays staged in the controller's transaction either way.
    func cancel(reason: String?) {
        guard phase != .idle else { return }
        lastCancellation = reason
        reset()
    }

    private func reset() {
        phase = .idle
        snapshot = nil
        intent = nil
        window = nil
        presentedGeneration = nil
        lastPointer = nil
    }
}
