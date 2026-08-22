import Foundation

public enum DebutCore {
    // Releases stamp the real version in at build time and never commit it, so an unstamped build
    // is honestly reporting that it is not a release.
    public static let version = "0.0.0-dev"

    /// Every on-disk artifact lives here: state, settings, diagnostics, the telemetry queue.
    ///
    /// Named once because the rename to debut-space missed half the call sites and every miss
    /// failed quietly — the app wrote one directory while E2E read another.
    public static let applicationSupportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("DebutSpace")
}
