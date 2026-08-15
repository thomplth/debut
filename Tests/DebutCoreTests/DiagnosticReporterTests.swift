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

    @Test("Correlated overlay traces appear in the authoritative snapshot")
    func overlayTraceAppearsInSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let performance = PerformanceRecorder(resourceReader: UnavailableProcessResourceReader())
        let overlay = OverlayPresentationRecorder(performanceRecorder: performance)
        let reporter = DiagnosticReporter(
            directory: dir,
            performanceRecorder: performance,
            overlayPresentationRecorder: overlay
        )
        let context = overlay.begin(configuredDelayMilliseconds: 80)
        overlay.mark(.mainActorDequeued, for: context)
        overlay.complete(context, outcome: .presented)

        reporter.report("overlay_presentation_completed", level: .transient)
        reporter.flush()

        let data = try Data(contentsOf: dir.appendingPathComponent("diagnostic.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshot = try #require(object["overlayPresentation"] as? [String: Any])
        let completed = try #require(snapshot["completed"] as? [[String: Any]])
        #expect(completed.last?["traceID"] as? String == context.traceID.uuidString)
        #expect(completed.last?["outcome"] as? String == "presented")
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

    private func snapshotState(in directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("diagnostic.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? [String: String]
        else { return [:] }
        return state
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @Test("A main-queue state provider is only ever evaluated on the main thread")
    func mainQueueStateProviderRunsOnMainThread() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        reporter.setMainQueueStateProvider {
            #expect(Thread.isMainThread)
            return ["providerThread": Thread.isMainThread ? "main" : "background"]
        }

        await Task.detached {
            reporter.report("preview_capture_completed", level: .transient)
        }.value

        let converged = await waitUntil { [self] in
            reporter.flush()
            return snapshotState(in: dir)["providerThread"] == "main"
        }
        #expect(converged)
    }

    @Test("A background report does not wait for the main queue")
    func backgroundReportDoesNotWaitForMainQueue() async throws {
        // Blocking on the main queue here made every preview capture wait behind
        // the overlay's own render work: a 3.1s main-queue stall was charged to
        // `preview_first` even though the capture had not started.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        reporter.setMainQueueStateProvider { ["overlayVisible": "true"] }

        let occupied = MutableState()
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            occupied.value = "occupied"
            _ = release.wait(timeout: .now() + 5)
        }
        _ = await waitUntil { occupied.value == "occupied" }
        defer { release.signal() }

        let milliseconds = await Task.detached {
            let started = DispatchTime.now().uptimeNanoseconds
            reporter.report("window_preview_capture_started", level: .transient)
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }.value

        #expect(milliseconds < 500)
    }

    @Test("A main-thread report evaluates the provider inline")
    func mainThreadReportEvaluatesProviderInline() async throws {
        // The state block is how E2E observes a running session, so a report made
        // on the main thread must never publish a stale snapshot.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reporter = DiagnosticReporter(directory: dir)
        let selection = MutableState()
        reporter.setMainQueueStateProvider { ["selectedWindowIndex": selection.value] }

        await MainActor.run {
            selection.value = "7"
            reporter.report("stage_switched", level: .lifecycle)
        }
        reporter.flush()

        #expect(snapshotState(in: dir)["selectedWindowIndex"] == "7")
    }
}
