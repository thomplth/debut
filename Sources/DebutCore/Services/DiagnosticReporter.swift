import Foundation
import os.log

/// Controls whether an event survives a restart. Input and hover events fire
/// dozens of times per second, so only lifecycle events earn durable storage.
public enum DiagnosticLevel: Sendable {
    case lifecycle
    case transient
}

public final class DiagnosticReporter: NSObject, @unchecked Sendable {
    public static let shared = DiagnosticReporter()
    public static let diagnosticFile: URL = defaultDirectory.appendingPathComponent("diagnostic.json")

    private static let defaultDirectory: URL = {
        // Suites that exercise StageController report through `shared`. Writing
        // those events into the real support directory corrupts the log a live
        // session is diagnosed from, and has already produced false evidence.
        let dir: URL
        if isHostedByDebutApp {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Debut")
        } else {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DebutDiagnostics-\(ProcessInfo.processInfo.processIdentifier)")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Identifies the shipped app positively. Test runners expose neither an
    /// `.xctest` bundle nor `XCTestConfigurationFilePath` under swift-testing,
    /// so detecting them by absence is unreliable.
    private static var isHostedByDebutApp: Bool {
        Bundle.main.bundleIdentifier == "com.thomplth.Debut"
    }

    private let logger = Logger(subsystem: "com.thomplth.Debut", category: "diagnostic")
    private let directory: URL
    private let rotationByteLimit: Int
    private let performanceRecorder: PerformanceRecorder
    private let overlayPresentationRecorder: OverlayPresentationRecorder
    private var eventLog: [[String: String]] = []
    private let queue = DispatchQueue(label: "com.thomplth.Debut.diagnostic")

    /// Allocating a formatter per event is measurable on the input path. Only touched on
    /// `queue`, which serializes the access the type itself does not guarantee.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    // Guarded separately from `queue` so that reading it never waits behind
    // pending file writes. Some reporters run on background tasks, so providers
    // that read main-queue-owned state must opt into main-queue evaluation.
    private let stateProviderLock = NSLock()
    private var stateProvider: (@Sendable () -> [String: String])?
    private var stateProviderRunsOnMainQueue = false

    private var snapshotFile: URL { directory.appendingPathComponent("diagnostic.json") }
    private var durableFile: URL { directory.appendingPathComponent("diagnostic.jsonl") }
    private var rotatedFile: URL { directory.appendingPathComponent("diagnostic.jsonl.1") }

    private override convenience init() {
        self.init(directory: Self.defaultDirectory)
    }

    init(
        directory: URL,
        rotationByteLimit: Int = 2_000_000,
        performanceRecorder: PerformanceRecorder = .shared,
        overlayPresentationRecorder: OverlayPresentationRecorder = .shared
    ) {
        self.directory = directory
        self.rotationByteLimit = rotationByteLimit
        self.performanceRecorder = performanceRecorder
        self.overlayPresentationRecorder = overlayPresentationRecorder
        super.init()
        NSLog("[Debut] DiagnosticReporter initialized at %@", directory.path)
    }

    public func report(
        _ event: String,
        level: DiagnosticLevel = .lifecycle,
        details: [String: String] = [:]
    ) {
        let occurredAt = Date()

        // Snapshot controller state on the caller's thread. Evaluating the
        // provider later on the queue can race the controller's next mutation.
        // Transient events must snapshot too: the state block is how a running
        // session is observed, and skipping them leaves it stale through an
        // entire held-Tab sequence.
        let state = currentState()
        let performance = performanceRecorder.snapshot()
        let overlayPresentation = overlayPresentationRecorder.snapshot()
        queue.async {
            NSLog("[Debut] %@ %@", event, details.description)
            var entry = details
            entry["event"] = event
            entry["timestamp"] = Self.timestampFormatter.string(from: occurredAt)
            self.eventLog.append(entry)
            if self.eventLog.count > 100 {
                self.eventLog.removeFirst(self.eventLog.count - 100)
            }
            if level == .lifecycle { self.appendDurableEvent(entry) }
            self.writeSnapshotFile(
                state: state,
                performance: performance,
                overlayPresentation: overlayPresentation
            )
        }
    }

    public func setStateProvider(_ provider: @escaping @Sendable () -> [String: String]) {
        setStateProvider(provider, runsOnMainQueue: false)
    }

    public func setMainQueueStateProvider(
        _ provider: @escaping @Sendable () -> [String: String]
    ) {
        setStateProvider(provider, runsOnMainQueue: true)
    }

    private func setStateProvider(
        _ provider: @escaping @Sendable () -> [String: String],
        runsOnMainQueue: Bool
    ) {
        stateProviderLock.lock()
        stateProvider = provider
        stateProviderRunsOnMainQueue = runsOnMainQueue
        stateProviderLock.unlock()
        let state = currentState()
        let performance = performanceRecorder.snapshot()
        let overlayPresentation = overlayPresentationRecorder.snapshot()
        queue.async {
            self.writeSnapshotFile(
                state: state,
                performance: performance,
                overlayPresentation: overlayPresentation
            )
        }
    }

    /// Drains pending writes. Tests need a deterministic point at which the
    /// files on disk reflect every reported event.
    func flush() {
        queue.sync {}
    }

    private func currentState() -> [String: String] {
        stateProviderLock.lock()
        let provider = stateProvider
        let runsOnMainQueue = stateProviderRunsOnMainQueue
        stateProviderLock.unlock()

        guard let provider else { return [:] }
        if runsOnMainQueue, !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: provider)
        }
        return provider()
    }

    // MARK: - Durable event stream

    /// Must be called on `queue`.
    private func appendDurableEvent(_ entry: [String: String]) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        else { return }
        line.append(0x0A)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded(incomingByteCount: line.count)

        if let handle = try? FileHandle(forWritingTo: durableFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: durableFile, options: .atomic)
        }
    }

    private func rotateIfNeeded(incomingByteCount: Int) {
        guard durableFileSize() + incomingByteCount > rotationByteLimit else { return }
        try? FileManager.default.removeItem(at: rotatedFile)
        try? FileManager.default.moveItem(at: durableFile, to: rotatedFile)
    }

    private func durableFileSize() -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: durableFile.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    // MARK: - Current-state snapshot

    /// Must be called on `queue`.
    private func writeSnapshotFile(
        state: [String: String],
        performance: PerformanceSnapshot,
        overlayPresentation: OverlayPresentationSnapshot
    ) {
        let output: [String: Any] = [
            "state": state,
            "events": eventLog,
            "performance": jsonObject(performance) ?? [:],
            "overlayPresentation": jsonObject(overlayPresentation) ?? [:],
            "updatedAt": Self.timestampFormatter.string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: snapshotFile, options: .atomic)
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
