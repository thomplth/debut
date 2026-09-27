import Foundation

/// Sends crash and hang reports off the Mac, only with the user's consent.
///
/// A report is captured locally either way. Without automatic sending, a crash from the previous
/// run waits for the prompt shown at the next launch, and hangs are dropped.
@MainActor
public protocol CrashReporting: AnyObject {
    /// False when the build has no reporting destination, as in source and local builds.
    var isAvailable: Bool { get }
    /// The previous run crashed and its report has not been sent.
    var hasUnsentCrashReport: Bool { get }
    func start(sendsAutomatically: Bool)
    func setSendsAutomatically(_ enabled: Bool)
    func sendUnsentCrashReport()
    func discardUnsentCrashReport()
}

@MainActor
public final class DisabledCrashReporter: CrashReporting {
    public init() {}
    public let isAvailable = false
    public let hasUnsentCrashReport = false
    public func start(sendsAutomatically: Bool) {}
    public func setSendsAutomatically(_ enabled: Bool) {}
    public func sendUnsentCrashReport() {}
    public func discardUnsentCrashReport() {}
}

public enum CrashReportDecision: Sendable {
    case send
    case alwaysSend
    case dontSend
}

/// Starts the reporter and asks about a crash from the previous run.
@MainActor
public final class CrashReportCoordinator {
    private let reporter: any CrashReporting
    private let askToSend: @MainActor () -> CrashReportDecision
    private let enableAutomaticSending: @MainActor () -> Void
    private var sendsAutomatically = false

    public init(
        reporter: any CrashReporting,
        askToSend: @escaping @MainActor () -> CrashReportDecision,
        enableAutomaticSending: @escaping @MainActor () -> Void
    ) {
        self.reporter = reporter
        self.askToSend = askToSend
        self.enableAutomaticSending = enableAutomaticSending
    }

    public var isAvailable: Bool { reporter.isAvailable }

    public func start(sendsAutomatically: Bool) {
        guard reporter.isAvailable else { return }
        self.sendsAutomatically = sendsAutomatically
        reporter.start(sendsAutomatically: sendsAutomatically)
    }

    /// Asks about the previous run's crash. Separate from `start` so capture begins at launch
    /// while the question waits until Debut is ready.
    public func resolveUnsentCrashReport() {
        guard reporter.isAvailable, reporter.hasUnsentCrashReport else { return }
        switch askToSend() {
        case .send:
            reporter.sendUnsentCrashReport()
        case .alwaysSend:
            self.sendsAutomatically = true
            reporter.setSendsAutomatically(true)
            enableAutomaticSending()
            reporter.sendUnsentCrashReport()
        case .dontSend:
            reporter.discardUnsentCrashReport()
        }
    }

    public func settingsChanged(sendsAutomatically: Bool) {
        guard reporter.isAvailable, sendsAutomatically != self.sendsAutomatically else { return }
        self.sendsAutomatically = sendsAutomatically
        reporter.setSendsAutomatically(sendsAutomatically)
    }
}

/// Decides, per report, whether it may leave the Mac.
///
/// The reporting SDK hands reports over on its own threads, sometimes before the user has
/// answered the prompt, so a crash that arrives undecided is held rather than dropped.
public final class CrashReportConsentGate<Report>: @unchecked Sendable {
    private enum Decision { case undecided, send, discard }

    private let lock = NSLock()
    private var sendsAutomatically: Bool
    private var decision = Decision.undecided
    private var held: [Report] = []

    public init(sendsAutomatically: Bool) {
        self.sendsAutomatically = sendsAutomatically
    }

    public func setSendsAutomatically(_ enabled: Bool) {
        lock.withLock { sendsAutomatically = enabled }
    }

    /// Returns the report when it may be sent now.
    public func admit(_ report: Report, isCrash: Bool) -> Report? {
        lock.withLock {
            if sendsAutomatically { return report }
            guard isCrash else { return nil }
            switch decision {
            case .send: return report
            case .discard: return nil
            case .undecided:
                held.append(report)
                return nil
            }
        }
    }

    /// Consents to the previous run's crash; returns the reports held until now.
    public func send() -> [Report] {
        lock.withLock {
            decision = .send
            defer { held = [] }
            return held
        }
    }

    public func discard() {
        lock.withLock {
            decision = .discard
            held = []
        }
    }
}

public enum CrashReportRedaction {
    /// Binary and frame paths name the home folder when Debut runs from `~/Applications`.
    public static func redactingHomeDirectories(_ path: String) -> String {
        path.replacing(/\/Users\/(?!Shared\/)[^\/]+\//, with: "/Users/<redacted>/")
    }
}
