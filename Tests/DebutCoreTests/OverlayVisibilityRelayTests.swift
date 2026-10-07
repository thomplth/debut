import Foundation
import Testing
@testable import DebutCore

@MainActor
private final class OverlayVisibilityLog {
    var isOpen = true
    var events: [String] = []
}

@Suite("Overlay visibility relay")
@MainActor
struct OverlayVisibilityRelayTests {
    // The hold-delay timer and a queued release can run back to back after a main-queue stall.
    // A show that waited for a later turn ran after that release's hide, and the overlay stayed
    // on screen with no key held (KHA-990).
    @Test("An open followed by a close in the same turn leaves the overlay hidden")
    func closeInSameTurnRunsAfterOpen() async {
        let log = OverlayVisibilityLog()
        let relay = makeRelay(log)

        relay.opened(OverlayPresentationContext())
        log.isOpen = false
        relay.closed(OverlayPresentationContext(), fadeDuration: 0.1)
        await drainMainQueue()

        #expect(log.events == ["show", "hide"])
    }

    @Test("An open reported off the main thread is shown on it")
    func openOffMainShowsOnMain() async {
        let log = OverlayVisibilityLog()
        let relay = makeRelay(log)

        await Task.detached { relay.opened(nil) }.value
        await drainMainQueue()

        #expect(log.events == ["show"])
    }

    @Test("A show that arrives after the switcher closed does not order the overlay in")
    func lateShowAfterCloseIsDropped() async {
        let log = OverlayVisibilityLog()
        let relay = makeRelay(log)

        log.isOpen = false
        relay.closed(nil, fadeDuration: 0)
        await Task.detached { relay.opened(nil) }.value
        await drainMainQueue()

        #expect(log.events == ["hide"])
    }

    private func makeRelay(_ log: OverlayVisibilityLog) -> OverlayVisibilityRelay {
        let relay = OverlayVisibilityRelay()
        relay.bind(
            isOpen: { log.isOpen },
            show: { _ in
                MainActor.assertIsolated()
                log.events.append("show")
            },
            hide: { _, _ in log.events.append("hide") }
        )
        return relay
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
