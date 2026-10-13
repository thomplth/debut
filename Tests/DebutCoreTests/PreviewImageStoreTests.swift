import CoreGraphics
import Foundation
import Observation
import Testing
@testable import DebutCore

private func solid(_ gray: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return context.makeImage()!
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

@Suite("Preview image store")
@MainActor
struct PreviewImageStoreTests {
    @Test("A new preview invalidates only the card that shows it")
    func updateTouchesOnlyChangedSlot() {
        let store = PreviewImageStore()
        let first = solid(0.1), second = solid(0.9)
        store.update(to: [1: first, 2: second])

        let otherCardInvalidated = Flag()
        let changedCardInvalidated = Flag()
        withObservationTracking { _ = store.slot(for: 2).image } onChange: { otherCardInvalidated.raise() }
        withObservationTracking { _ = store.slot(for: 1).image } onChange: { changedCardInvalidated.raise() }

        store.update(to: [1: solid(0.5), 2: second])

        #expect(changedCardInvalidated.isRaised)
        #expect(!otherCardInvalidated.isRaised, "an unchanged card must not redraw")
    }

    @Test("A removed preview clears its slot")
    func removalClearsSlot() {
        let store = PreviewImageStore()
        store.update(to: [1: solid(0.2)])
        store.update(to: [:])
        #expect(store.slot(for: 1).image == nil)
    }

    @Test("A card reads its live slot over the snapshot it was built with")
    func cardReadsLiveSlot() {
        let store = PreviewImageStore()
        let stale = solid(0.2), fresh = solid(0.8)
        store.update(to: [7: stale])
        let card = StageWindowData.card(
            for: SpaceWindow(windowID: 7, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"),
            previews: [7: stale],
            sizes: [:],
            adaptive: true,
            previewStore: store
        )
        #expect(card.currentPreview === stale)
        store.update(to: [7: fresh])
        #expect(card.currentPreview === fresh)
    }
}
