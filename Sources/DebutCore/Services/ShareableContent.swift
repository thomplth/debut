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
/// much of the result a caller uses, and presenting the overlay makes the
/// wallpaper capture and the window previews both need it at the same instant.
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
