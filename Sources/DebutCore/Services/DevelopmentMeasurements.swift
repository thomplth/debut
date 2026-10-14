import Foundation

/// Instrumentation that costs real work runs only in development builds, where the person
/// running it is also the one reading the diagnostics. Release workflows stamp a version, so a
/// shipped build never pays for it. Cheap counters stay on everywhere.
public enum DevelopmentMeasurements {
    public static let isEnabled: Bool = DebutCore.version == "0.0.0-dev" && HostEnvironment.isDebutApp
}
