import Foundation

/// Applies SpaceController's open and close reports to the overlay window, in the order they
/// were made.
///
/// Both reports normally arrive on the main queue, and both are applied in that turn. After a
/// main-queue stall the hold-delay timer and a queued release can run back to back; a show
/// deferred to a later turn then ran after the release's hide, and the overlay stayed on screen
/// with no key held (KHA-990).
final class OverlayVisibilityRelay: @unchecked Sendable {
    private var isOpen: @MainActor () -> Bool = { false }
    private var show: @MainActor (OverlayPresentationContext?) -> Void = { _ in }
    private var hide: @MainActor (OverlayPresentationContext?, TimeInterval) -> Void = { _, _ in }

    /// Read only on the main queue, where every report is applied.
    @MainActor
    func bind(
        isOpen: @escaping @MainActor () -> Bool,
        show: @escaping @MainActor (OverlayPresentationContext?) -> Void,
        hide: @escaping @MainActor (OverlayPresentationContext?, TimeInterval) -> Void
    ) {
        self.isOpen = isOpen
        self.show = show
        self.hide = hide
    }

    func opened(_ context: OverlayPresentationContext?) {
        onMain { [self] in
            // An open reported off the main queue still waits a turn, and the switcher may have
            // closed meanwhile. Nothing would hide a window ordered in after that.
            guard isOpen() else { return }
            show(context)
        }
    }

    func closed(_ context: OverlayPresentationContext?, fadeDuration: TimeInterval) {
        // A commit closes the overlay and then fronts the chosen window in the same turn. A hop
        // queued the fade behind all of that, and the overlay sat opaque until it was done
        // (KHA-856).
        onMain { [self] in
            hide(context, fadeDuration)
        }
    }

    private func onMain(_ body: @escaping @MainActor () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { body() }
            return
        }
        MainActor.assumeIsolated { body() }
    }
}
