import DebutCore
import Foundation
import Sentry

/// Reports crashes and hangs to Sentry only with the user's consent.
///
/// Nightlies and stable releases report to the one Debut project through the same consent flow;
/// the Sentry environment keeps them apart. Development builds carry the DSN but never report. Everything Sentry would send
/// on its own besides error events, such as sessions, breadcrumbs, traces and counts of dropped
/// events, is turned off.
@MainActor
final class SentryCrashReporter: CrashReporting {
    static let dsnInfoKey = "DebutCrashReportDSN"

    private let dsn: String?
    private let gate = CrashReportConsentGate<Event>(sendsAutomatically: false)

    init(bundle: Bundle = .main) {
        let dsn = (bundle.object(forInfoDictionaryKey: Self.dsnInfoKey) as? String)?
            .trimmingCharacters(in: .whitespaces)
        self.dsn = dsn?.isEmpty == false
            && CrashReportEnvironment.reportsCrashes(forVersion: DebutCore.version) ? dsn : nil
    }

    var isAvailable: Bool { dsn != nil }

    private(set) var hasUnsentCrashReport = false

    func start(sendsAutomatically: Bool) {
        guard let dsn else { return }
        gate.setSendsAutomatically(sendsAutomatically)
        let gate = gate
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "com.thomplth.Debut@\(DebutCore.version)"
            options.environment = CrashReportEnvironment.name(forVersion: DebutCore.version)
            options.sendDefaultPii = false
            options.sendClientReports = false
            options.enableAutoSessionTracking = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.maxBreadcrumbs = 0
            options.enableAutoPerformanceTracing = false
            options.enableNetworkTracking = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.enableCaptureFailedRequests = false
            options.enableSwizzling = false
            options.enableWatchdogTerminationTracking = false
            // Sentry's own hang tracker is deprecated for false positives; MetricKit reports the
            // hangs macOS itself observed.
            options.enableAppHangTracking = false
            options.enableMetricKit = true
            options.beforeSend = { event in
                gate.admit(event, isCrash: event.level == .fatal).map(Self.redacted)
            }
        }
        hasUnsentCrashReport = !sendsAutomatically && SentrySDK.lastRunStatus == .didCrash
    }

    func setSendsAutomatically(_ enabled: Bool) {
        gate.setSendsAutomatically(enabled)
    }

    func sendUnsentCrashReport() {
        hasUnsentCrashReport = false
        // A report that arrives after this point is admitted by the gate directly.
        for event in gate.send() {
            SentrySDK.capture(event: event)
        }
    }

    func discardUnsentCrashReport() {
        hasUnsentCrashReport = false
        gate.discard()
    }

    private nonisolated static func redacted(_ event: Event) -> Event {
        event.serverName = nil
        event.user = nil
        event.breadcrumbs = nil
        event.context?["device"]?["name"] = nil
        event.context?["app"]?["device_app_hash"] = nil
        let redact = CrashReportRedaction.redactingHomeDirectories
        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map(redact)
        }
        let frames = (event.threads ?? []).flatMap { $0.stacktrace?.frames ?? [] }
            + (event.exceptions ?? []).flatMap { $0.stacktrace?.frames ?? [] }
        for frame in frames {
            frame.package = frame.package.map(redact)
            frame.fileName = frame.fileName.map(redact)
        }
        return event
    }
}
