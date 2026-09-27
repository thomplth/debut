import AppKit
import SwiftUI

/// The host settings Debut's behaviour branches on, read in one place.
///
/// Only the shipped app follows the host. Every other process that links DebutCore, the test
/// runner above all, sees one fixed profile: hosted runners boot with Reduce Motion on while a
/// developer's Mac and the Tart guest have it off, and a timing test that inherited the
/// difference passed locally and failed the nightly (KHA-815). A test that needs the other branch
/// injects it where it is used instead of depending on the machine it runs on.
/// `Tests/CI/HostEnvironmentTests.sh` keeps every other file in DebutCore from reading the host.
struct HostEnvironment: Sendable {
    /// `nil` follows the host.
    let reducesMotionOverride: Bool?

    static let live = HostEnvironment(reducesMotionOverride: nil)
    static let fixed = HostEnvironment(reducesMotionOverride: false)
    static let current: HostEnvironment = isDebutApp ? .live : .fixed

    /// Identifies the shipped app positively. Test runners expose neither an `.xctest` bundle nor
    /// `XCTestConfigurationFilePath` under swift-testing, so detecting them by absence is
    /// unreliable.
    static var isDebutApp: Bool {
        Bundle.main.bundleIdentifier == "com.thomplth.Debut"
    }

    func reducesMotion(host: Bool) -> Bool {
        reducesMotionOverride ?? host
    }

    var reducesMotion: Bool {
        reducesMotion(host: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

/// SwiftUI's `accessibilityReduceMotion` cannot be overridden, so views read it through the host
/// profile instead. The host value stays an `@Environment`, so the app still updates the moment
/// the user toggles the setting.
@propertyWrapper
struct HostReducesMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var host

    init() {}

    var wrappedValue: Bool {
        HostEnvironment.current.reducesMotion(host: host)
    }
}
