import CoreGraphics
import Foundation

/// Holds a window's background capture until the window has stopped changing (KHA-1084).
///
/// A resize drag reports every frame, a terminal retitles itself as it runs, and a window that
/// was just focused is about to be used. Capturing on each report costs ~80 CPU-ms apiece in the
/// privacy machinery and shows nothing the next report will not supersede, so each report
/// restarts the window's timer and the capture fires once the window has been quiet for the
/// settle delay. There is no maximum wait: a window that never goes quiet is captured when
/// focus leaves it, not periodically.
///
/// Main-queue confined.
final class PreviewCaptureDebouncer: @unchecked Sendable {
    static let defaultSettleDelay: TimeInterval = 1

    private let delay: () -> TimeInterval
    private let fire: (CGWindowID, String) -> Void
    private var pending: [CGWindowID: (reason: String, token: Int)] = [:]
    private var tokens = 0

    init(delay: @escaping () -> TimeInterval, fire: @escaping (CGWindowID, String) -> Void) {
        self.delay = delay
        self.fire = fire
    }

    /// `atLeast` holds the capture longer than the settle delay, for a caller rate-limiting it.
    func debounce(_ windowID: CGWindowID, reason: String, atLeast minimumDelay: TimeInterval = 0) {
        tokens += 1
        let token = tokens
        pending[windowID] = (reason, token)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay(), minimumDelay)) { [weak self] in
            guard let self, let entry = self.pending[windowID], entry.token == token else { return }
            self.pending[windowID] = nil
            self.fire(windowID, entry.reason)
        }
    }

    func cancel(_ windowID: CGWindowID) {
        pending[windowID] = nil
    }

    /// Hands over every capture still waiting, for a caller that will take them now.
    func takePending() -> [CGWindowID: String] {
        defer { pending.removeAll() }
        return pending.mapValues(\.reason)
    }

    func cancelAll() {
        pending.removeAll()
    }
}
