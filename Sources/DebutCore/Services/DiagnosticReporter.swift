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
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Debut")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let logger = Logger(subsystem: "com.thomplth.Debut", category: "diagnostic")
    private let directory: URL
    private let rotationByteLimit: Int
    private var eventLog: [[String: String]] = []
    private let queue = DispatchQueue(label: "com.thomplth.Debut.diagnostic")

    // Guarded separately from `queue` so that reading it never waits behind
    // pending file writes. Reporting happens on the main thread.
    private let stateProviderLock = NSLock()
    private var stateProvider: (() -> [String: String])?

    private var snapshotFile: URL { directory.appendingPathComponent("diagnostic.json") }
    private var durableFile: URL { directory.appendingPathComponent("diagnostic.jsonl") }
    private var rotatedFile: URL { directory.appendingPathComponent("diagnostic.jsonl.1") }

    private override convenience init() {
        self.init(directory: Self.defaultDirectory)
    }

    init(directory: URL, rotationByteLimit: Int = 2_000_000) {
        self.directory = directory
        self.rotationByteLimit = rotationByteLimit
        super.init()
        NSLog("[Debut] DiagnosticReporter initialized")
    }

    public func report(
        _ event: String,
        level: DiagnosticLevel = .lifecycle,
        details: [String: String] = [:]
    ) {
        NSLog("[Debut] %@ %@", event, details.description)
        var entry = details
        entry["event"] = event
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())

        // Snapshot controller state on the caller's thread. Evaluating the
        // provider later on the queue can race the controller's next mutation.
        let state = currentState()
        queue.async {
            self.eventLog.append(entry)
            if self.eventLog.count > 100 {
                self.eventLog.removeFirst(self.eventLog.count - 100)
            }
            if level == .lifecycle { self.appendDurableEvent(entry) }
            self.writeSnapshotFile(state: state)
        }
    }

    public func setStateProvider(_ provider: @escaping () -> [String: String]) {
        stateProviderLock.lock()
        stateProvider = provider
        stateProviderLock.unlock()
        let state = currentState()
        queue.async { self.writeSnapshotFile(state: state) }
    }

    /// Drains pending writes. Tests need a deterministic point at which the
    /// files on disk reflect every reported event.
    func flush() {
        queue.sync {}
    }

    private func currentState() -> [String: String] {
        stateProviderLock.lock()
        defer { stateProviderLock.unlock() }
        return stateProvider?() ?? [:]
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
    private func writeSnapshotFile(state: [String: String]) {
        let output: [String: Any] = [
            "state": state,
            "events": eventLog,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: snapshotFile, options: .atomic)
    }
}
