import Foundation

/// Holds an activity assertion for Debut's process lifetime. This prevents App Nap from turning
/// a global keyboard switcher into background work while still allowing the Mac to enter idle
/// system sleep.
final class ProcessResponsivenessActivity {
    typealias BeginActivity = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol

    private let beginActivity: BeginActivity
    private var token: NSObjectProtocol?

    init(beginActivity: @escaping BeginActivity = { options, reason in
        ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }) {
        self.beginActivity = beginActivity
    }

    func start() {
        guard token == nil else { return }
        token = beginActivity(
            .userInitiatedAllowingIdleSystemSleep,
            "Preserve global switcher responsiveness"
        )
    }
}

/// Bounded lanes for cross-process calls. A wedged AX client, WindowServer request, or process
/// query can occupy one worker without consuming every worker available to another dependency.
final class ExternalCallScheduler: @unchecked Sendable {
    enum Lane: CaseIterable, Sendable {
        case accessibility
        case windowServer
        case process
    }

    struct Configuration: Equatable, Sendable {
        let qualityOfService: QualityOfService
        let maximumConcurrency: Int
    }

    static let shared = ExternalCallScheduler()

    private let configurations: [Lane: Configuration]
    private let queues: [Lane: OperationQueue]

    init() {
        configurations = [
            .accessibility: Configuration(
                qualityOfService: .userInteractive,
                maximumConcurrency: 4
            ),
            .windowServer: Configuration(
                qualityOfService: .userInitiated,
                maximumConcurrency: 4
            ),
            .process: Configuration(
                qualityOfService: .userInitiated,
                maximumConcurrency: 2
            ),
        ]
        queues = Dictionary(uniqueKeysWithValues: configurations.map { lane, configuration in
            let queue = OperationQueue()
            queue.name = "com.thomplth.Debut.external.\(lane)"
            queue.qualityOfService = configuration.qualityOfService
            queue.maxConcurrentOperationCount = configuration.maximumConcurrency
            return (lane, queue)
        })
    }

    func configuration(for lane: Lane) -> Configuration {
        configurations[lane]!
    }

    func schedule(
        on lane: Lane,
        operation: @escaping @Sendable () -> Void
    ) {
        queues[lane]?.addOperation(operation)
    }
}
