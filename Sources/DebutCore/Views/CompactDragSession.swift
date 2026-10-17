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
    /// Every layout this drag can swap between; `snapshot` is the one drawn.
    private var variants: CompactDragVariants?
    private(set) var intent: CompactDropIntent?
    private(set) var window: StageWindowData?
    /// The plate held, when the drag carries a whole plate rather than one card.
    private(set) var plate: StageData?
    private(set) var presentedGeneration: UInt64?
    private(set) var lastCancellation: String?
    var proxyLocation: CGPoint = .zero
    /// Where the pointer picked the drag up. A held plate is drawn at this point plus how far
    /// the pointer has moved since, as two offsets, so its glide from rest can keep animating
    /// while the pointer moves it without animation.
    private(set) var pickupLocation: CGPoint = .zero
    private var lastPointer: CGPoint?
    private var nextGeneration: UInt64 = 0

    /// The scale a held plate is laid out at: the held layout's. Swaps to and from a slotted
    /// layout rescale it as a transform, which animates where a relayout would snap.
    var heldPlateScale: CGFloat? { plate == nil ? nil : variants?.collapsed.scale }

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
        begin(variants: CompactDragVariants(collapsed: snapshot, expanded: [:]),
              window: window, at: location)
    }

    func begin(variants: CompactDragVariants, plate: StageData, at location: CGPoint) {
        begin(variants: variants, window: nil, at: location)
        self.plate = plate
    }

    func begin(variants: CompactDragVariants, window: StageWindowData?, at location: CGPoint) {
        self.variants = variants
        plate = nil
        let snapshot = variants.layout(at: location, from: variants.collapsed) ?? variants.collapsed
        self.snapshot = snapshot
        self.window = window
        presentedGeneration = nil
        lastCancellation = nil
        phase = .dragging
        proxyLocation = location
        pickupLocation = location
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
        retarget(at: location, from: snapshot)
    }

    /// Whether moving to `location` opens or closes a new-desktop plate, which moves the whole
    /// drag view rather than one gap, so the caller animates it as such.
    func changesLayout(at location: CGPoint) -> Bool {
        guard phase == .dragging, let snapshot, let variants else { return false }
        if variants.layout(at: location, from: snapshot) != nil { return true }
        return variants.plateLayout(for: target(at: location, in: snapshot), from: snapshot) != nil
    }

    /// What the pointer at `location` aims at. A held plate is always measured against the held
    /// layout, as drawn without a slot: the slotted one only rescales the stack around a slot
    /// it already chose, and measuring against it would move the target with the pointer.
    func target(at location: CGPoint) -> CompactDropIntent? {
        snapshot.flatMap { target(at: location, in: $0) }
    }

    private func target(at location: CGPoint, in snapshot: CompactDragSnapshot) -> CompactDropIntent? {
        variants?.target(at: location, in: snapshot, intent: intent)
            ?? snapshot.resolve(at: location, current: intent)
    }

    private func retarget(at location: CGPoint, from current: CompactDragSnapshot) {
        guard let variants else {
            snapshot = current
            intent = current.resolve(at: location, current: intent)
            return
        }
        (snapshot, intent) = variants.retarget(at: location, from: current, intent: intent)
    }

    /// Resolves the release once and hands a valid edit to `accept` exactly once, synchronously,
    /// before any animation. Everything else returns to normal presentation without an edit.
    func release(
        at location: CGPoint,
        accept: (PointerWindowDropRequest) -> PointerWindowDropResult
    ) -> Outcome {
        release(at: location) { snapshot, intent in
            snapshot.dropRequest(for: intent).map(accept)
        }
    }

    /// A held plate's release, resolved and accepted exactly as a card's.
    func releasePlate(
        at location: CGPoint,
        accept: (PlateDropRequest) -> PointerWindowDropResult
    ) -> Outcome {
        release(at: location) { snapshot, intent in
            snapshot.plateRequest(for: intent).map(accept)
        }
    }

    private func release(
        at location: CGPoint,
        accept: (CompactDragSnapshot, CompactDropIntent) -> PointerWindowDropResult?
    ) -> Outcome {
        guard phase == .dragging, let snapshot else { return .cancelled("not dragging") }
        guard presentedGeneration == snapshot.generation else {
            cancel(reason: "released before compact layout was presented")
            return .cancelled("released before compact layout was presented")
        }
        if location != lastPointer {
            lastPointer = location
            retarget(at: location, from: snapshot)
        }
        proxyLocation = location
        guard let snapshot = self.snapshot,
              let intent, intent.generation == snapshot.generation else {
            cancel(reason: "released outside every stage")
            return .cancelled("released outside every stage")
        }
        if snapshot.isNoOp(intent) {
            cancel(reason: nil)
            return .noChange
        }
        phase = .acceptingDrop
        guard let result = accept(snapshot, intent) else {
            cancel(reason: "destination unavailable")
            return .cancelled("destination unavailable")
        }
        switch result {
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
        variants = nil
        plate = nil
        intent = nil
        window = nil
        presentedGeneration = nil
        lastPointer = nil
    }
}
