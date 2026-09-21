import Foundation
import Testing
@testable import DebutCore

@Suite("Anonymous telemetry")
struct TelemetryTests {
    @Test("Hourly accumulator exports exact P95 values for user-facing interactions and resets")
    func hourlyP95Accumulator() async throws {
        let transport = RecordingTelemetryClient()
        let exporter = TelemetryExporter(
            client: transport,
            queue: InMemoryTelemetryQueue(),
            enabled: true,
            dailyEventLimit: 24
        )
        for duration in [10.0, 20, 30, 40, 50, 60, 70, 80, 90, 100] {
            await exporter.record(observation(
                operation: .overlayEndToEndVisible,
                duration: duration,
                windows: 12
            ))
        }
        await exporter.record(observation(
            operation: .windowDiscovery,
            duration: 9_999,
            windows: 12
        ))

        try await exporter.flushHourly(appVersion: "1.2.3", operatingSystemMajor: 26)
        try await exporter.flushHourly(appVersion: "1.2.3", operatingSystemMajor: 26)

        let batches = await transport.batches
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
        #expect(batches[0][0].event == .hourlyP95)
        #expect(batches[0][0].operation == .overlayEndToEndVisible)
        #expect(batches[0][0].latencyMilliseconds == 100)
        #expect(batches[0][0].sampleCount == 10)
        #expect(batches[0][0].appVersion == "1.2.3")
        #expect(batches[0][0].operatingSystemMajor == 26)
        #expect(batches[0][0].workload == .typical)
    }

    @Test("TelemetryDeck adapter batches numeric latency metrics in one request")
    func numericTelemetryDeckBatch() throws {
        let client = TelemetryDeckClient(namespace: "debut", appID: "app-id")
        let request = try client.request(for: [
            payload(.overlayEndToEndVisible, milliseconds: 123.456, samples: 18, workload: .busy),
            payload(.spaceSwitch, milliseconds: 88.25, samples: 4),
        ])

        #expect(request.url?.absoluteString == "https://nom.telemetrydeck.com/v2/namespace/debut/")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Debut-Telemetry/1")
        let data = try #require(request.httpBody)
        let events = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(events.count == 2)
        #expect(events[0]["type"] as? String == "Debut.Performance.hourly_p95")
        #expect(events[0]["floatValue"] as? Double == 123.456)
        let dimensions = try #require(events[0]["payload"] as? [String: Any])
        #expect(dimensions["Debut.operation"] as? String == "overlay_end_to_end_visible")
        #expect(dimensions["Debut.sampleCount"] as? Int == 18)
        #expect(dimensions["Debut.latencyBucket"] == nil)
        #expect(events[0]["clientUser"] as? String == "")
        #expect(events[0]["sessionID"] == nil)
    }

    @Test("Failed hourly delivery stays queued and retries as one batch")
    func failedBatchRetries() async throws {
        let transport = FailingOnceTelemetryClient()
        let exporter = TelemetryExporter(
            client: transport,
            queue: InMemoryTelemetryQueue(),
            enabled: true,
            dailyEventLimit: 24
        )
        await exporter.record(observation(operation: .previewFirst, duration: 42, windows: 25))

        await #expect(throws: (any Error).self) {
            try await exporter.flushHourly(appVersion: "1.0", operatingSystemMajor: 26)
        }
        #expect(await exporter.status().queued == 1)

        try await exporter.flush()
        #expect(await exporter.status().queued == 0)
        #expect(await transport.successfulBatches.count == 1)
        #expect(await transport.successfulBatches[0].count == 1)
    }

    @Test("Empty hours do not perform network requests")
    func emptyHoursDoNotSend() async throws {
        let transport = RecordingTelemetryClient()
        let exporter = TelemetryExporter(
            client: transport,
            queue: InMemoryTelemetryQueue(),
            enabled: true
        )

        try await exporter.flushHourly(appVersion: "1.0", operatingSystemMajor: 26)

        #expect(await transport.batches.isEmpty)
    }

    @Test("Fresh and legacy settings default to no sharing while explicit choices remain codable")
    func settingsMigration() throws {
        var settings = AppSettings()
        #expect(!settings.shareAnonymousTelemetry)
        let decodedOptOut = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(!decodedOptOut.shareAnonymousTelemetry)

        settings.shareAnonymousTelemetry = true
        let decodedOptIn = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decodedOptIn.shareAnonymousTelemetry)

        let current = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings())
        ) as! [String: Any]
        var legacy = current
        legacy.removeValue(forKey: "shareAnonymousTelemetry")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        #expect(!decodedLegacy.shareAnonymousTelemetry)
    }

    @Test("Numeric payload contains only approved aggregate dimensions")
    func payloadAllowlist() throws {
        let encoded = try JSONEncoder().encode(payload(
            .overlayEndToEndVisible,
            milliseconds: 82.75,
            samples: 8,
            workload: .busy
        ))
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        #expect(Set(object.keys) == [
            "schemaVersion", "event", "appVersion", "operatingSystemMajor", "workload",
            "operation", "latencyMilliseconds", "sampleCount",
        ])
        let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        for prohibited in [
            "windowTitle", "bundleID", "windowID", "pid", "path", "screenshot", "error", "diagnostic",
        ] {
            #expect(!text.localizedCaseInsensitiveContains(prohibited))
        }
    }

    @Test("Disabling stops collection and deletes queued events")
    func optOutClearsQueue() async throws {
        let transport = FailingOnceTelemetryClient()
        let exporter = TelemetryExporter(
            client: transport,
            queue: InMemoryTelemetryQueue(),
            enabled: true
        )
        await exporter.record(observation(operation: .spaceSwitch, duration: 120))
        await #expect(throws: (any Error).self) {
            try await exporter.flushHourly(appVersion: "1.0", operatingSystemMajor: 26)
        }
        #expect(await exporter.status().queued == 1)

        await exporter.setEnabled(false)
        await exporter.record(observation(operation: .spaceSwitch, duration: 140))
        try await exporter.flushHourly(appVersion: "1.0", operatingSystemMajor: 26)

        #expect(await exporter.status().queued == 0)
        #expect(await transport.successfulBatches.isEmpty)
    }

    @Test("Daily cap drops excess hourly metrics")
    func dailyCap() async throws {
        let transport = RecordingTelemetryClient()
        let exporter = TelemetryExporter(
            client: transport,
            queue: InMemoryTelemetryQueue(),
            enabled: true,
            dailyEventLimit: 1
        )
        await exporter.record(observation(operation: .previewFirst, duration: 10))
        await exporter.record(observation(operation: .spaceSwitch, duration: 20))

        try await exporter.flushHourly(appVersion: "1.0", operatingSystemMajor: 26)

        #expect(await transport.payloads.count == 1)
        let status = await exporter.status()
        #expect(status.sent == 1)
        #expect(status.dropped == 1)
    }

    @Test("Daily installation cap survives exporter restart")
    func durableDailyCap() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTelemetry-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = TelemetryExporter(
            client: RecordingTelemetryClient(),
            queue: DiskTelemetryQueue(file: file),
            enabled: true,
            dailyEventLimit: 1
        )
        await first.record(observation(operation: .previewFirst, duration: 10))
        try await first.flushHourly(appVersion: "1.0", operatingSystemMajor: 26)

        let secondClient = RecordingTelemetryClient()
        let second = TelemetryExporter(
            client: secondClient,
            queue: DiskTelemetryQueue(file: file),
            enabled: true,
            dailyEventLimit: 1
        )
        await second.record(observation(operation: .spaceSwitch, duration: 20))
        try await second.flushHourly(appVersion: "1.0", operatingSystemMajor: 26)

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

    @Test("Legacy bucketed queues decode and are pruned before numeric delivery")
    func legacyQueuesArePruned() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutTelemetryLegacy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data(#"""
        {
          "payloads": [{
            "schemaVersion": 1,
            "event": "anomaly",
            "workload": "typical",
            "operation": "stage_switch",
            "latency": "gte_500ms"
          }],
          "quota": {"day": "2026-08-27", "sent": 0, "dropped": 0}
        }
        """#.utf8)
        try data.write(to: file)
        let queue = DiskTelemetryQueue(file: file)
        let decoded = try await queue.payloads()
        #expect(decoded.count == 1)
        #expect(decoded[0].operation == .spaceSwitch)

        let exporter = TelemetryExporter(client: RecordingTelemetryClient(), queue: queue, enabled: true)
        try await exporter.pruneLegacyPayloads()

        #expect(try await queue.payloads().isEmpty)
    }

    private func observation(
        operation: PerformanceOperation,
        duration: Double,
        windows: Int = 1
    ) -> PerformanceObservation {
        PerformanceObservation(
            correlationID: UUID(),
            operation: operation,
            durationMilliseconds: duration,
            workload: .init(windows: windows)
        )
    }

    private func payload(
        _ operation: PerformanceOperation,
        milliseconds: Double,
        samples: Int,
        workload: TelemetryWorkload = .typical
    ) -> TelemetryPayload {
        .hourlyP95(
            operation: operation,
            milliseconds: milliseconds,
            sampleCount: samples,
            appVersion: "1.2.3",
            operatingSystemMajor: 26,
            workload: workload
        )
    }
}

private actor RecordingTelemetryClient: TelemetryClient {
    private(set) var payloads: [TelemetryPayload] = []
    private(set) var batches: [[TelemetryPayload]] = []

    func send(_ payloads: [TelemetryPayload]) async throws {
        batches.append(payloads)
        self.payloads.append(contentsOf: payloads)
    }
}

private actor FailingOnceTelemetryClient: TelemetryClient {
    enum Failure: Error { case expected }
    private var shouldFail = true
    private(set) var successfulBatches: [[TelemetryPayload]] = []

    func send(_ payloads: [TelemetryPayload]) async throws {
        if shouldFail {
            shouldFail = false
            throw Failure.expected
        }
        successfulBatches.append(payloads)
    }
}
