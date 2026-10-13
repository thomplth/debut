import ScreenCaptureKit

/// Serves one recent value to every caller, and lets callers that arrive during
/// a load join it rather than starting a second one.
actor RecentValueCache<Value: Sendable> {
    private let maximumAgeNanoseconds: UInt64
    private let now: @Sendable () -> UInt64
    private let load: @Sendable () async throws -> Value
    private var cached: (value: Value, loadedAt: UInt64)?
    private var inFlight: Task<Value, Error>?

    init(
        maximumAgeNanoseconds: UInt64,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        load: @escaping @Sendable () async throws -> Value
    ) {
        self.maximumAgeNanoseconds = maximumAgeNanoseconds
        self.now = now
        self.load = load
    }

    func value() async throws -> Value {
        if let cached, now() &- cached.loadedAt < maximumAgeNanoseconds {
            return cached.value
        }
        if let inFlight { return try await inFlight.value }

        let task = Task { [load] in try await load() }
        inFlight = task
        defer { inFlight = nil }

        let value = try await task.value
        cached = (value, now())
        return value
    }

}

/// `SCShareableContent` is not `Sendable`, and it only ever crosses isolation
/// boundaries here as an immutable snapshot.
struct SendableShareableContent: @unchecked Sendable {
    let content: SCShareableContent
}

/// Enumerating shareable content costs tens of milliseconds regardless of how
/// much of the result a caller uses, and presenting the overlay starts every
/// window preview capture at the same instant.
/// The snapshot is short-lived so a window that opened moments ago is still
/// found, but long enough to cover one presentation.
enum ShareableContent {
    static let shared = RecentValueCache<SendableShareableContent>(
        maximumAgeNanoseconds: 500_000_000
    ) {
        SendableShareableContent(
            content: try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        )
    }
}

/// Holds ScreenCaptureKit's window handles between captures (KHA-1080).
///
/// A capture needs the window's `SCWindow`, and the only way to get one is to enumerate every
/// shareable window on the system: ~60ms at ~240 windows on macOS 27 (capbench, 2026-10-13).
/// The 500ms snapshot above meant every overlay open, and every background capture, paid that.
/// A held handle keeps capturing the window's current content, so the list is fetched again only
/// when a requested window is missing, or after a capture through a handle failed.
///
/// A held handle's frame is from when it was enumerated, so callers size captures from the
/// window's tracked bounds rather than from the handle.
actor CaptureHandleCatalog<Handle: Sendable> {
    private let identify: @Sendable (Handle) -> CGWindowID
    private let enumerate: @Sendable () async throws -> [Handle]
    private var handles: [CGWindowID: Handle] = [:]

    init(
        identify: @escaping @Sendable (Handle) -> CGWindowID,
        enumerate: @escaping @Sendable () async throws -> [Handle]
    ) {
        self.identify = identify
        self.enumerate = enumerate
    }

    /// The handles for `windowIDs` that exist, in the order asked.
    func handles(for windowIDs: [CGWindowID]) async throws -> [Handle] {
        if windowIDs.contains(where: { handles[$0] == nil }) {
            let listed = try await enumerate()
            handles = Dictionary(listed.map { (identify($0), $0) }, uniquingKeysWith: { first, _ in first })
        }
        return windowIDs.compactMap { handles[$0] }
    }

    func evict(_ windowID: CGWindowID) {
        handles[windowID] = nil
    }
}
