import Foundation
import Testing
@testable import DebutCore

@Suite("Anonymous telemetry")
struct TelemetryTests {
    @Test("Settings migration defaults to sharing and remains codable")
    func settingsMigration() throws {
        var settings = AppSettings()
        #expect(settings.shareAnonymousTelemetry)
        settings.shareAnonymousTelemetry = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.shareAnonymousTelemetry)

        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        var legacy = current
        legacy.removeValue(forKey: "shareAnonymousTelemetry")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacyData).shareAnonymousTelemetry)
    }

    @Test("Payload contains only approved aggregate dimensions")
    func payloadAllowlist() throws {
        let payload = TelemetryPayload.sessionSummary(
            appVersion: "1.2.3",
            operatingSystemMajor: 26,
            workload: .busy,
            operationCounts: [.overlayPreparation: 8],
            latencyBuckets: [.overlayPreparation: .milliseconds50To100],
            anomalyCount: 1
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]

        #expect(Set(object.keys) == ["schemaVersion", "event", "appVersion", "operatingSystemMajor", "workload", "operationCounts", "latencyBuckets", "anomalyCount"])
        let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        for prohibited in ["windowTitle", "bundleID", "windowID", "pid", "path", "screenshot", "error", "diagnostic"] {
            #expect(!text.localizedCaseInsensitiveContains(prohibited))
        }
    }

    @Test("Overlay anomaly exposes only a bucketed temperature")
    func overlayTemperatureAllowlist() throws {
        let payload = TelemetryPayload.anomaly(
            operation: .overlayEndToEndVisible,
            latency: .over500Milliseconds,
            workload: .typical,
            temperature: .processFirst
        )
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as! [String: Any]

        #expect(object["temperature"] as? String == "process_first")
        #expect(Set(object.keys) == [
            "schemaVersion", "event", "operation", "latency", "workload", "temperature",
        ])
    }

    @Test("Disabling stops delivery immediately and deletes queued events")
    func optOutClearsQueue() async throws {
        let transport = RecordingTelemetryClient()
        let queue = InMemoryTelemetryQueue()
        let exporter = TelemetryExporter(client: transport, queue: queue, enabled: true, dailyEventLimit: 10)
        try await exporter.enqueue(.anomaly(operation: .spaceSwitch, latency: .milliseconds100To250, workload: .typical))
        #expect(await exporter.status().queued == 1)

        await exporter.setEnabled(false)
        #expect(await exporter.status().queued == 0)
        try await exporter.flush()
        #expect(await transport.payloads.isEmpty)

        try await exporter.enqueue(.anomaly(operation: .spaceSwitch, latency: .milliseconds100To250, workload: .typical))
        #expect(await exporter.status().queued == 0)
    }

    @Test("Daily cap drops excess payloads without network activity")
    func dailyCap() async throws {
        let transport = RecordingTelemetryClient()
        let exporter = TelemetryExporter(
            client: transport,
            queue: InMemoryTelemetryQueue(),
            enabled: true,
            dailyEventLimit: 1
        )
        let payload = TelemetryPayload.anomaly(operation: .previewCapture, latency: .milliseconds250To500, workload: .stress)
        try await exporter.enqueue(payload)
        try await exporter.flush()
        try await exporter.enqueue(payload)
        try await exporter.flush()

        #expect(await transport.payloads.count == 1)
        let status = await exporter.status()
        #expect(status.sent == 1)
        #expect(status.dropped == 1)
    }

    @Test("One noisy operation cannot consume the anomaly budget")
    func perOperationCap() async throws {
        let queue = InMemoryTelemetryQueue()
        let exporter = TelemetryExporter(
            client: RecordingTelemetryClient(),
            queue: queue,
            enabled: true,
            dailyEventLimit: 6,
            dailyPerOperationLimit: 2
        )
        let wallpaper = TelemetryPayload.anomaly(
            operation: .wallpaperCapture,
            latency: .over500Milliseconds,
            workload: .typical
        )
        for _ in 0..<5 { try await exporter.enqueue(wallpaper) }
        try await exporter.enqueue(.anomaly(
            operation: .overlayEndToEndVisible,
            latency: .over500Milliseconds,
            workload: .typical
        ))

        let payloads = await queue.payloads()
        #expect(payloads.filter { $0.operation == .wallpaperCapture }.count == 2)
        #expect(payloads.filter { $0.operation == .overlayEndToEndVisible }.count == 1)
        #expect(await exporter.status().dropped == 3)
    }

    @Test("Per-operation cap survives delivery and exporter restart")
    func durablePerOperationCap() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTelemetryOperations-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let wallpaper = TelemetryPayload.anomaly(
            operation: .wallpaperCapture,
            latency: .over500Milliseconds,
            workload: .typical
        )
        let first = TelemetryExporter(
            client: RecordingTelemetryClient(),
            queue: DiskTelemetryQueue(file: file),
            enabled: true,
            dailyEventLimit: 10,
            dailyPerOperationLimit: 2
        )
        try await first.enqueue(wallpaper)
        try await first.flush()
        try await first.enqueue(wallpaper)
        try await first.flush()

        let secondClient = RecordingTelemetryClient()
        let second = TelemetryExporter(
            client: secondClient,
            queue: DiskTelemetryQueue(file: file),
            enabled: true,
            dailyEventLimit: 10,
            dailyPerOperationLimit: 2
        )
        try await second.enqueue(wallpaper)
        try await second.flush()

        #expect(await secondClient.payloads.isEmpty)
        #expect(await second.status().dropped == 1)
    }

    @Test("Legacy quota files decode without per-operation counters")
    func legacyQuotaMigration() throws {
        let data = Data(#"{"day":"2026-08-13","sent":3,"dropped":4}"#.utf8)
        let quota = try JSONDecoder().decode(TelemetryQuota.self, from: data)

        #expect(quota.day == "2026-08-13")
        #expect(quota.sent == 3)
        #expect(quota.dropped == 4)
        #expect(quota.acceptedByOperation.isEmpty)
    }

    @Test("TelemetryDeck adapter uses v2 EU ingestion with an empty user and flat allowlisted primitives")
    func telemetryDeckRequest() throws {
        let client = TelemetryDeckClient(namespace: "debut", appID: "app-id")
        let payload = TelemetryPayload.sessionSummary(
            appVersion: "1.0", operatingSystemMajor: 26, workload: .typical,
            operationCounts: [.overlayPreparation: 2],
            latencyBuckets: [.overlayPreparation: .milliseconds25To50], anomalyCount: 0
        )
        let request = try client.request(for: payload)
        #expect(request.url?.absoluteString == "https://nom.telemetrydeck.com/v2/namespace/debut/")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Debut-Telemetry/1")
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [[String: Any]])
        #expect(body.first?["clientUser"] as? String == "")
        #expect(body.first?["sessionID"] == nil)
        let dimensions = try #require(body.first?["payload"] as? [String: Any])
        #expect(dimensions["Debut.operation.overlay_preparation.count"] as? Int == 2)
        #expect(dimensions.values.allSatisfy { !($0 is [String: Any]) && !($0 is [Any]) })
    }

    @Test("Daily installation cap survives exporter restart")
    func durableDailyCap() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DebutTelemetry-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let firstClient = RecordingTelemetryClient()
        let payload = TelemetryPayload.anomaly(operation: .spaceSwitch, latency: .milliseconds100To250, workload: .typical)
        let first = TelemetryExporter(client: firstClient, queue: DiskTelemetryQueue(file: file), enabled: true, dailyEventLimit: 1)
        try await first.enqueue(payload)
        try await first.flush()

        let secondClient = RecordingTelemetryClient()
        let second = TelemetryExporter(client: secondClient, queue: DiskTelemetryQueue(file: file), enabled: true, dailyEventLimit: 1)
        try await second.enqueue(payload)
        try await second.flush()

        #expect(await secondClient.payloads.isEmpty)
        #expect(await second.status().dropped == 1)
    }

    @Test("Idle intervals never count as latency anomalies")
    func idleIntervalsAreNotAnomalies() {
        let idle = PerformanceObservation(
            correlationID: UUID(),
            operation: .hiddenIdle,
            durationMilliseconds: 190_000,
            workload: .init()
        )
        let delayedDelivery = PerformanceObservation(
            correlationID: UUID(),
            operation: .mainQueueDelivery,
            durationMilliseconds: 575,
            workload: .init()
        )

        #expect(!PerformanceAnomalyPolicy.shouldReport(idle))
        #expect(PerformanceAnomalyPolicy.shouldReport(delayedDelivery))
    }

    @Test("Exporter removes legacy idle anomalies while retaining real anomalies")
    func pruneLegacyIdleAnomalies() async throws {
        let queue = InMemoryTelemetryQueue()
        await queue.replace(with: [
            .anomaly(operation: .hiddenIdle, latency: .over500Milliseconds, workload: .typical),
            .anomaly(operation: .wallpaperCapture, latency: .over500Milliseconds, workload: .typical),
        ])
        let exporter = TelemetryExporter(
            client: RecordingTelemetryClient(),
            queue: queue,
            enabled: true
        )

        try await exporter.pruneInvalidAnomalies()

        let payloads = await queue.payloads()
        #expect(payloads.count == 1)
        #expect(payloads.first?.operation == .wallpaperCapture)
    }
}

private actor RecordingTelemetryClient: TelemetryClient {
    private(set) var payloads: [TelemetryPayload] = []
    func send(_ payload: TelemetryPayload) async throws { payloads.append(payload) }
}
