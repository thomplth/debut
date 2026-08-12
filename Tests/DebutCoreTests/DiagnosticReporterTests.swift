import Foundation
import Testing
@testable import DebutCore

@Suite("DiagnosticReporter")
struct DiagnosticReporterTests {

    private func makeTempDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func durableLines(in directory: URL) -> [[String: String]] {
        let url = directory.appendingPathComponent("diagnostic.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
                else { return nil }
                return object
            }
    }

    @Test("Lifecycle events append one parseable JSONL line each")
    func lifecycleEventsAppend() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        reporter.report("window_assigned", level: .lifecycle, details: ["windowID": "1"])
        reporter.report("window_assigned", level: .lifecycle, details: ["windowID": "2"])
        reporter.report("window_retired", level: .lifecycle, details: ["windowID": "1"])
        reporter.flush()

        let lines = durableLines(in: dir)
        #expect(lines.count == 3)
        #expect(lines.map { $0["event"] } == ["window_assigned", "window_assigned", "window_retired"])
        #expect(lines[1]["windowID"] == "2")
        #expect(lines.allSatisfy { $0["timestamp"]?.isEmpty == false })
    }

    @Test("Transient events never reach the durable log")
    func transientEventsStayInMemory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        for _ in 0..<200 {
            reporter.report("key_event", level: .transient, details: ["keyEvent": "tab"])
        }
        reporter.report("window_assigned", level: .lifecycle, details: ["windowID": "9"])
        reporter.flush()

        let lines = durableLines(in: dir)
        #expect(lines.count == 1)
        #expect(lines.first?["event"] == "window_assigned")
    }

    @Test("Durable log rotates and keeps exactly one previous generation")
    func durableLogRotates() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir, rotationByteLimit: 512)
        let padding = String(repeating: "x", count: 120)
        for index in 0..<40 {
            reporter.report("window_assigned", level: .lifecycle, details: [
                "windowID": "\(index)",
                "padding": padding,
            ])
        }
        reporter.flush()

        let current = dir.appendingPathComponent("diagnostic.jsonl")
        let rotated = dir.appendingPathComponent("diagnostic.jsonl.1")
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("diagnostic.jsonl.2").path))

        let size = (try FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(size <= 512)
    }

    @Test("Snapshot file keeps its existing shape for E2E consumers")
    func snapshotFileShapeUnchanged() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        reporter.setStateProvider { ["stageCount": "3"] }
        reporter.report("app_launched", level: .lifecycle)
        reporter.flush()

        let url = dir.appendingPathComponent("diagnostic.json")
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let state = try #require(object["state"] as? [String: String])
        #expect(state["stageCount"] == "3")
        let events = try #require(object["events"] as? [[String: String]])
        #expect(events.last?["event"] == "app_launched")
        #expect(object["updatedAt"] as? String != nil)
        #expect(object["performance"] as? [String: Any] != nil)
    }

    @Test("Completed operations appear in the authoritative snapshot with workload correlation")
    func performanceAppearsInSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = PerformanceRecorder(
            resourceReader: UnavailableProcessResourceReader(),
            now: { 1_000_000 }
        )
        let reporter = DiagnosticReporter(directory: dir, performanceRecorder: recorder)
        let correlation = recorder.begin(.overlayPreparation, workload: .init(stages: 4, windows: 12))
        _ = recorder.end(correlation)

        reporter.report("overlay_shown", level: .transient)
        reporter.flush()

        let data = try Data(contentsOf: dir.appendingPathComponent("diagnostic.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let performance = try #require(object["performance"] as? [String: Any])
        let recent = try #require(performance["recent"] as? [[String: Any]])
        #expect(recent.last?["operation"] as? String == "overlay_preparation")
        let workload = try #require(recent.last?["workload"] as? [String: Any])
        #expect(workload["windows"] as? Int == 12)
    }

    @Test("Shared reporter never writes into the real support directory under test")
    func sharedReporterIsSandboxedDuringTests() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Debut")

        // Suites that exercise StageController report through the shared
        // instance. Without redirection those events corrupt the very log a
        // real session gets diagnosed from.
        #expect(!DiagnosticReporter.diagnosticFile.path.hasPrefix(appSupport.path))
    }

    @Test("Transient events still appear in the in-memory snapshot")
    func transientEventsInSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        reporter.report("key_event", level: .transient, details: ["keyEvent": "tab"])
        reporter.flush()

        let data = try Data(contentsOf: dir.appendingPathComponent("diagnostic.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(object["events"] as? [[String: String]])
        #expect(events.contains { $0["event"] == "key_event" })
    }

    /// Holds the value the state provider returns so a test can change it between
    /// reports.
    private final class MutableState: @unchecked Sendable {
        var value = "0"
    }

    @Test("A transient event refreshes the state snapshot")
    func transientEventsRefreshStateSnapshot() throws {
        // Held Tab reports nothing but transient events, so reusing the previous
        // snapshot for them leaves the state block stale for the whole sequence.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        let selection = MutableState()
        reporter.setStateProvider { ["selectedWindowIndex": selection.value] }
        reporter.report("overlay_opened", level: .lifecycle)

        selection.value = "3"
        reporter.report("key_event", level: .transient)
        reporter.flush()

        let data = try Data(contentsOf: dir.appendingPathComponent("diagnostic.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(object["state"] as? [String: String])
        #expect(state["selectedWindowIndex"] == "3")
    }

    @Test("A main-queue state provider is isolated from background reporters")
    func mainQueueStateProviderRunsOnMainThread() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        reporter.setMainQueueStateProvider {
            ["providerThread": Thread.isMainThread ? "main" : "background"]
        }

        await Task.detached {
            reporter.report("preview_capture_completed", level: .transient)
        }.value
        reporter.flush()

        let data = try Data(contentsOf: dir.appendingPathComponent("diagnostic.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(object["state"] as? [String: String])
        #expect(state["providerThread"] == "main")
    }
}
