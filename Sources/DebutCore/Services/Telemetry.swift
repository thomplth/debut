import Foundation

public enum TelemetryWorkload: String, Codable, Sendable {
    case typical
    case busy
    case stress
}

public enum TelemetryTemperature: String, Codable, Sendable {
    case processFirst = "process_first"
    case cacheCold = "cache_cold"
    case warm
}

/// Selects latency anomalies that represent delayed work. Hidden-idle spans measure how long
/// Debut remained inactive, so a long duration is expected and must never consume telemetry quota.
public enum PerformanceAnomalyPolicy {
    public static let minimumDurationMilliseconds = 500.0

    public static func shouldReport(_ observation: PerformanceObservation) -> Bool {
        observation.operation != .hiddenIdle
            && observation.durationMilliseconds >= minimumDurationMilliseconds
    }

    static func shouldRetain(_ payload: TelemetryPayload) -> Bool {
        payload.event != .anomaly || payload.operation != .hiddenIdle
    }
}

public enum TelemetryLatencyBucket: String, Codable, Sendable {
    case under10Milliseconds = "lt_10ms"
    case milliseconds10To25 = "10_25ms"
    case milliseconds25To50 = "25_50ms"
    case milliseconds50To100 = "50_100ms"
    case milliseconds100To250 = "100_250ms"
    case milliseconds250To500 = "250_500ms"
    case over500Milliseconds = "gte_500ms"

    public init(milliseconds: Double) {
        switch milliseconds {
        case ..<10: self = .under10Milliseconds
        case ..<25: self = .milliseconds10To25
        case ..<50: self = .milliseconds25To50
        case ..<100: self = .milliseconds50To100
        case ..<250: self = .milliseconds100To250
        case ..<500: self = .milliseconds250To500
        default: self = .over500Milliseconds
        }
    }
}

/// The complete remote data contract. It deliberately has no free-form metadata field.
public struct TelemetryPayload: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable { case sessionSummary = "session_summary", anomaly }

    public let schemaVersion: Int
    public let event: Event
    public let appVersion: String?
    public let operatingSystemMajor: Int?
    public let workload: TelemetryWorkload
    public let temperature: TelemetryTemperature?
    public let operationCounts: [String: Int]?
    public let latencyBuckets: [String: TelemetryLatencyBucket]?
    public let anomalyCount: Int?
    public let operation: PerformanceOperation?
    public let latency: TelemetryLatencyBucket?

    public static func sessionSummary(
        appVersion: String,
        operatingSystemMajor: Int,
        workload: TelemetryWorkload,
        operationCounts: [PerformanceOperation: Int],
        latencyBuckets: [PerformanceOperation: TelemetryLatencyBucket],
        anomalyCount: Int
    ) -> TelemetryPayload {
        TelemetryPayload(
            schemaVersion: 1,
            event: .sessionSummary,
            appVersion: appVersion,
            operatingSystemMajor: operatingSystemMajor,
            workload: workload,
            temperature: nil,
            operationCounts: Dictionary(uniqueKeysWithValues: operationCounts.map { ($0.key.rawValue, $0.value) }),
            latencyBuckets: Dictionary(uniqueKeysWithValues: latencyBuckets.map { ($0.key.rawValue, $0.value) }),
            anomalyCount: max(0, anomalyCount),
            operation: nil,
            latency: nil
        )
    }

    public static func anomaly(
        operation: PerformanceOperation,
        latency: TelemetryLatencyBucket,
        workload: TelemetryWorkload,
        temperature: TelemetryTemperature? = nil
    ) -> TelemetryPayload {
        TelemetryPayload(
            schemaVersion: 1,
            event: .anomaly,
            appVersion: nil,
            operatingSystemMajor: nil,
            workload: workload,
            temperature: temperature,
            operationCounts: nil,
            latencyBuckets: nil,
            anomalyCount: nil,
            operation: operation,
            latency: latency
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, event, appVersion, operatingSystemMajor, workload, temperature
        case operationCounts, latencyBuckets, anomalyCount, operation, latency
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(event, forKey: .event)
        try container.encode(workload, forKey: .workload)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(operatingSystemMajor, forKey: .operatingSystemMajor)
        try container.encodeIfPresent(operationCounts, forKey: .operationCounts)
        try container.encodeIfPresent(latencyBuckets, forKey: .latencyBuckets)
        try container.encodeIfPresent(anomalyCount, forKey: .anomalyCount)
        try container.encodeIfPresent(operation, forKey: .operation)
        try container.encodeIfPresent(latency, forKey: .latency)
    }
}

public protocol TelemetryClient: Sendable {
    func send(_ payload: TelemetryPayload) async throws
}

public struct UnavailableTelemetryClient: TelemetryClient {
    public init() {}
    public func send(_ payload: TelemetryPayload) async throws {
        throw TelemetryTransportError.invalidConfiguration
    }
}

public enum TelemetryTransportError: Error {
    case invalidConfiguration
    case rejected(statusCode: Int)
}

/// Minimal direct adapter for TelemetryDeck Ingest v2. Using the HTTP boundary avoids the
/// vendor SDK's automatic device, locale, accessibility, session, and persistent-user fields.
public final class TelemetryDeckClient: TelemetryClient, @unchecked Sendable {
    private let namespace: String
    private let appID: String
    private let session: URLSession

    public init(namespace: String, appID: String, session: URLSession = .shared) {
        self.namespace = namespace
        self.appID = appID
        self.session = session
    }

    public func send(_ payload: TelemetryPayload) async throws {
        let request = try request(for: payload)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TelemetryTransportError.rejected(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
    }

    func request(for payload: TelemetryPayload) throws -> URLRequest {
        guard !namespace.isEmpty, !appID.isEmpty,
              let encodedNamespace = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://nom.telemetrydeck.com/v2/namespace/\(encodedNamespace)/")
        else { throw TelemetryTransportError.invalidConfiguration }
        var dimensions: [String: Any] = [
            "Debut.schemaVersion": payload.schemaVersion,
            "Debut.workload": payload.workload.rawValue,
        ]
        if let appVersion = payload.appVersion { dimensions["Debut.appVersion"] = appVersion }
        if let major = payload.operatingSystemMajor { dimensions["Debut.operatingSystemMajor"] = major }
        if let count = payload.anomalyCount { dimensions["Debut.anomalyCount"] = count }
        if let operation = payload.operation { dimensions["Debut.operation"] = operation.rawValue }
        if let latency = payload.latency { dimensions["Debut.latencyBucket"] = latency.rawValue }
        if let temperature = payload.temperature {
            dimensions["Debut.temperature"] = temperature.rawValue
        }
        for (operation, count) in payload.operationCounts ?? [:] {
            dimensions["Debut.operation.\(operation).count"] = count
        }
        for (operation, bucket) in payload.latencyBuckets ?? [:] {
            dimensions["Debut.operation.\(operation).latencyBucket"] = bucket.rawValue
        }
        let event: [String: Any] = [
            "appID": appID,
            "clientUser": "",
            "type": "Debut.Performance.\(payload.event.rawValue)",
            "payload": dimensions,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Debut-Telemetry/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [event], options: [.sortedKeys])
        request.timeoutInterval = 10
        return request
    }
}

public protocol TelemetryQueue: Sendable {
    func payloads() async throws -> [TelemetryPayload]
    func replace(with payloads: [TelemetryPayload]) async throws
    func clear() async throws
    func quota() async throws -> TelemetryQuota
    func setQuota(_ quota: TelemetryQuota) async throws
}

public struct TelemetryQuota: Codable, Equatable, Sendable {
    public var day: String
    public var sent: Int
    public var dropped: Int
    public var acceptedByOperation: [String: Int]

    public init(
        day: String = "",
        sent: Int = 0,
        dropped: Int = 0,
        acceptedByOperation: [String: Int] = [:]
    ) {
        self.day = day
        self.sent = sent
        self.dropped = dropped
        self.acceptedByOperation = acceptedByOperation
    }

    private enum CodingKeys: String, CodingKey {
        case day, sent, dropped, acceptedByOperation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        sent = try container.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        dropped = try container.decodeIfPresent(Int.self, forKey: .dropped) ?? 0
        acceptedByOperation = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .acceptedByOperation
        ) ?? [:]
    }
}

public actor InMemoryTelemetryQueue: TelemetryQueue {
    private var storage: [TelemetryPayload] = []
    private var storedQuota = TelemetryQuota()
    public init() {}
    public func payloads() -> [TelemetryPayload] { storage }
    public func replace(with payloads: [TelemetryPayload]) { storage = payloads }
    public func clear() { storage.removeAll() }
    public func quota() -> TelemetryQuota { storedQuota }
    public func setQuota(_ quota: TelemetryQuota) { storedQuota = quota }
}

public actor DiskTelemetryQueue: TelemetryQueue {
    private struct Envelope: Codable {
        var payloads: [TelemetryPayload]
        var quota: TelemetryQuota
    }
    private let file: URL
    private let maximumPayloads: Int

    public init(file: URL, maximumPayloads: Int = 100) {
        self.file = file
        self.maximumPayloads = max(1, maximumPayloads)
    }

    public func payloads() throws -> [TelemetryPayload] {
        try read().payloads
    }

    public func replace(with payloads: [TelemetryPayload]) throws {
        var envelope = try read()
        envelope.payloads = Array(payloads.suffix(maximumPayloads))
        try write(envelope)
    }

    public func clear() throws {
        var envelope = try read()
        envelope.payloads.removeAll()
        try write(envelope)
    }

    public func quota() throws -> TelemetryQuota { try read().quota }

    public func setQuota(_ quota: TelemetryQuota) throws {
        var envelope = try read()
        envelope.quota = quota
        try write(envelope)
    }

    private func read() throws -> Envelope {
        guard let data = try? Data(contentsOf: file) else {
            return Envelope(payloads: [], quota: TelemetryQuota())
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) { return envelope }
        if let legacy = try? JSONDecoder().decode([TelemetryPayload].self, from: data) {
            return Envelope(payloads: legacy, quota: TelemetryQuota())
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid telemetry queue"))
    }

    private func write(_ envelope: Envelope) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(envelope).write(to: file, options: [.atomic, .completeFileProtection])
    }
}

public struct TelemetryStatus: Equatable, Sendable {
    public let enabled: Bool
    public let queued: Int
    public let sent: Int
    public let dropped: Int
}

public actor TelemetryExporter {
    private let client: any TelemetryClient
    private let queue: any TelemetryQueue
    private let dailyEventLimit: Int
    private let dailyPerOperationLimit: Int
    private let now: @Sendable () -> Date
    private var enabled: Bool

    public init(
        client: any TelemetryClient,
        queue: any TelemetryQueue,
        enabled: Bool,
        dailyEventLimit: Int = 20,
        dailyPerOperationLimit: Int = 2,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.queue = queue
        self.enabled = enabled
        self.dailyEventLimit = max(1, dailyEventLimit)
        self.dailyPerOperationLimit = max(1, dailyPerOperationLimit)
        self.now = now
    }

    public func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        if !enabled { try? await queue.clear() }
    }

    public func enqueue(_ payload: TelemetryPayload) async throws {
        guard enabled, PerformanceAnomalyPolicy.shouldRetain(payload) else { return }
        var quota = try await currentQuota()
        var payloads = try await queue.payloads()
        if payload.event == .anomaly, let operation = payload.operation {
            let accepted = quota.acceptedByOperation[operation.rawValue, default: 0]
            guard accepted < dailyPerOperationLimit else {
                quota.dropped += 1
                try await queue.setQuota(quota)
                return
            }
        }
        let summaryReservation = dailyEventLimit > 1 && payload.event == .anomaly ? 1 : 0
        guard quota.sent + payloads.count < dailyEventLimit - summaryReservation else {
            quota.dropped += 1
            try await queue.setQuota(quota)
            return
        }
        payloads.append(payload)
        if payload.event == .anomaly, let operation = payload.operation {
            quota.acceptedByOperation[operation.rawValue, default: 0] += 1
            try await queue.setQuota(quota)
        }
        try await queue.replace(with: payloads)
    }

    public func flush() async throws {
        guard enabled else { return }
        var quota = try await currentQuota()
        var payloads = try await queue.payloads()
        while enabled, let payload = payloads.first {
            do {
                try await client.send(payload)
                quota.sent += 1
                payloads.removeFirst()
                try await queue.replace(with: payloads)
                try await queue.setQuota(quota)
            } catch {
                throw error
            }
        }
    }

    /// Removes invalid records written by older builds without disturbing valid queued events.
    public func pruneInvalidAnomalies() async throws {
        let payloads = try await queue.payloads()
        let retained = payloads.filter(PerformanceAnomalyPolicy.shouldRetain)
        if retained.count != payloads.count {
            try await queue.replace(with: retained)
        }
    }

    public func status() async -> TelemetryStatus {
        let quota = (try? await currentQuota()) ?? TelemetryQuota()
        return TelemetryStatus(
            enabled: enabled,
            queued: (try? await queue.payloads().count) ?? 0,
            sent: quota.sent,
            dropped: quota.dropped
        )
    }

    public func preview(_ payload: TelemetryPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private func currentQuota() async throws -> TelemetryQuota {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now())
        var quota = try await queue.quota()
        if quota.day != day {
            quota = TelemetryQuota(day: day)
            try await queue.setQuota(quota)
        }
        return quota
    }
}
