import Foundation
import Testing
@testable import DebutCore

@Suite("Desktop reconfiguration observer")
struct DesktopReconfigurationObserverTests {
    @Test("The subscribed events are the measured Mission Control lifecycle pair")
    func subscribesToMissionControlLifecycle() {
        // Measured on macOS 26.5.2 against a live Mission Control drag: 1327 arrived before
        // the reordered desktop list became readable and 1328 arrived 0.1s after it. The
        // constants are the whole contract with the window server, so they are pinned here
        // rather than left to drift silently into a no-op subscription.
        #expect(DesktopReconfigurationObserver.subscribedEvents == [1327, 1328])
    }

    @Test("Subscribing reports the events it actually registered")
    func startReportsRegisteredEvents() {
        // The private symbol exists on every macOS this ships to, so an empty result would
        // mean the subscription silently stopped covering reorders.
        #expect(DesktopReconfigurationObserver.start() == [1327, 1328])
    }

    @Test("The layout notification reaches an observer on the main queue")
    func notificationReachesObservers() async {
        await confirmation("observer runs") { observed in
            await withCheckedContinuation { continuation in
                var token: (any NSObjectProtocol)?
                token = NotificationCenter.default.addObserver(
                    forName: .debutDesktopLayoutMayHaveChanged,
                    object: nil,
                    queue: .main
                ) { _ in
                    observed()
                    if let token { NotificationCenter.default.removeObserver(token) }
                    continuation.resume()
                }
                DispatchQueue.global().async {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .debutDesktopLayoutMayHaveChanged,
                            object: nil
                        )
                    }
                }
            }
        }
    }
}
