import Foundation
import os.log

public final class DiagnosticReporter: NSObject, @unchecked Sendable {
    public static let shared = DiagnosticReporter()
    public static let diagnosticFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Debut")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostic.json")
    }()

    private let logger = Logger(subsystem: "com.thomplth.Debut", category: "diagnostic")
    private var eventLog: [[String: String]] = []
    private var stateProvider: (() -> [String: String])?
    private let queue = DispatchQueue(label: "com.thomplth.Debut.diagnostic")

    private override init() {
        super.init()
        NSLog("[Debut] DiagnosticReporter initialized")
    }

    public func report(_ event: String, details: [String: String] = [:]) {
        NSLog("[Debut] %@ %@", event, details.description)
        queue.sync {
            var entry = details
            entry["event"] = event
            entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
            eventLog.append(entry)
            if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
        }
        writeDiagnosticFile()
    }

    public func setStateProvider(_ provider: @escaping () -> [String: String]) {
        queue.sync { self.stateProvider = provider }
        writeDiagnosticFile()
    }

    private func writeDiagnosticFile() {
        queue.async { [self] in
            let state = stateProvider?() ?? [:]
            let log = eventLog
            let output: [String: Any] = [
                "state": state,
                "events": log,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Self.diagnosticFile, options: .atomic)
            }
        }
    }
}
