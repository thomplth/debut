import DebutCore
import Foundation

/// The settings every capture runs with: Debut's fresh defaults, as a new user sees them,
/// plus only what the fixture needs. Appearance is never set here — media follows whatever
/// `AppSettings()` ships, in both preview and icon mode (KHA-1117).
///
/// - Login launch stays off so macOS posts no login-item banner in the disposable guest.
/// - No application is excluded, so all nine fixture windows are managed.
/// - Faster switching is chosen per clip: off except on the Instant side of a comparison.
/// - Previews are on except for the onboarding stills that show icon mode.
func captureSettings(fasterDesktopSwitching: Bool = false, windowPreviews: Bool = true) -> AppSettings {
    var settings = AppSettings()
    settings.launchAtLogin = false
    settings.excludedBundleIDs = []
    settings.features.fasterDesktopSwitching = fasterDesktopSwitching
    settings.features.windowPreviews = windowPreviews
    return settings
}

/// Writes through the app's own store, so the file has exactly the encoding Debut reads.
func writeCaptureSettings(_ settings: AppSettings,
                          to directory: URL = DebutCore.applicationSupportDirectory) throws {
    try StateStore(directory: directory).saveSettings(settings)
}
