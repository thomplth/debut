import CoreGraphics
import Observation
import SwiftUI

/// One card's preview, observed by that card alone.
@Observable
public final class PreviewImageSlot: @unchecked Sendable {
    public fileprivate(set) var image: CGImage?

    init(image: CGImage? = nil) {
        self.image = image
    }
}

/// The previews the overlay draws, one observable slot per window (KHA-1079).
///
/// A capture used to reach the screen by rebuilding the whole overlay view model, so every
/// preview that landed while the overlay was up re-diffed every card. A card now reads its own
/// slot, and a new image invalidates that card and nothing else. The swap is not animated: the
/// card shows the newer picture of the same window, not a transition between two things.
///
/// Main-queue confined, like the controller that owns it.
public final class PreviewImageStore: @unchecked Sendable {
    private var slots: [CGWindowID: PreviewImageSlot] = [:]

    public init() {}

    public func slot(for windowID: CGWindowID) -> PreviewImageSlot {
        if let slot = slots[windowID] { return slot }
        let slot = PreviewImageSlot()
        slots[windowID] = slot
        return slot
    }

    /// Brings every slot in line with the controller's previews, touching only the ones whose
    /// image changed so an unchanged card is never invalidated.
    func update(to previews: [CGWindowID: CGImage]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for (windowID, image) in previews where slots[windowID]?.image !== image {
                slot(for: windowID).image = image
            }
            for (windowID, slot) in slots where previews[windowID] == nil && slot.image != nil {
                slot.image = nil
            }
        }
    }
}
