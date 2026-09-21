import Foundation

public enum TelemetryWorkload: String, Codable, Sendable {
    case typical
    case busy
    case stress
}

/// Local performance context retained by overlay diagnostics. Hourly remote metrics do not
/// currently export this value.
public enum TelemetryTemperature: String, Codable, Sendable {
    case processFirst = "process_first"
    case cacheCold = "cache_cold"
    case warm
}

/// The complete remote data contract. It deliberately has no free-form metadata field.
public struct TelemetryPayload: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case hourlyP95 = "hourly_p95"
        // Retained only so queues written by older builds remain decodable.
        case sessionSummary = "session_summary"
        case anomaly
    }

    public let schemaVersion: Int
    public let event: Event
    public let appVersion: String?
    public let operatingSystemMajor: Int?
    public let workload: TelemetryWorkload
    public let operation: PerformanceOperation?
    public let latencyMilliseconds: Double?
    public let sampleCount: Int?

    public static func hourlyP95(
        operation: PerformanceOperation,
        milliseconds: Double,
        sampleCount: Int,
        appVersion: String,
        operatingSystemMajor: Int,
        workload: TelemetryWorkload
    ) -> TelemetryPayload {
        TelemetryPayload(
            schemaVersion: 2,
            event: .hourlyP95,
            appVersion: appVersion,
            operatingSystemMajor: operatingSystemMajor,
            workload: workload,
            operation: operation,
            latencyMilliseconds: max(0, milliseconds),
            sampleCount: max(1, sampleCount)
        )
    }
}

public protocol TelemetryClient: Sendable {
    func send(_ payloads: [TelemetryPayload]) async throws
}

public extension TelemetryClient {
    func send(_ payload: TelemetryPayload) async throws {
        try await send([payload])
    }
}

public struct UnavailableTelemetryClient: TelemetryClient {
    public init() {}
    public func send(_ payloads: [TelemetryPayload]) async throws {
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

    public func send(_ payloads: [TelemetryPayload]) async throws {
        guard !payloads.isEmpty else { return }
        let request = try request(for: payloads)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TelemetryTransportError.rejected(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
    }

    func request(for payload: TelemetryPayload) throws -> URLRequest {
        try request(for: [payload])
    }

    func request(for payloads: [TelemetryPayload]) throws -> URLRequest {
        guard !namespace.isEmpty, !appID.isEmpty,
              let encodedNamespace = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://nom.telemetrydeck.com/v2/namespace/\(encodedNamespace)/")
        else { throw TelemetryTransportError.invalidConfiguration }
        let events: [[String: Any]] = payloads.map { payload in
            var dimensions: [String: Any] = [
                "Debut.schemaVersion": payload.schemaVersion,
                "Debut.workload": payload.workload.rawValue,
            ]
            if let appVersion = payload.appVersion { dimensions["Debut.appVersion"] = appVersion }
            if let major = payload.operatingSystemMajor { dimensions["Debut.operatingSystemMajor"] = major }
            if let operation = payload.operation { dimensions["Debut.operation"] = operation.rawValue }
            if let sampleCount = payload.sampleCount { dimensions["Debut.sampleCount"] = sampleCount }
            var event: [String: Any] = [
                "appID": appID,
                // Must stay empty. Anything identifying here would let events be
                // joined into a per-device history.
                "clientUser": "",
                "type": "Debut.Performance.\(payload.event.rawValue)",
                "payload": dimensions,
            ]
            if let value = payload.latencyMilliseconds { event["floatValue"] = value }
            return event
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Debut-Telemetry/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
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
        let normalized = Self.normalizingLegacyOperationNames(in: data)
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: normalized) { return envelope }
        if let legacy = try? JSONDecoder().decode([TelemetryPayload].self, from: normalized) {
            return Envelope(payloads: legacy, quota: TelemetryQuota())
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid telemetry queue"))
    }

    /// The user-facing terminology moved from stages back to macOS Spaces after early builds
    /// had already persisted telemetry. Normalize exact JSON strings before decoding so one old
    /// anomaly cannot poison the queue, and so summary/quota dictionary keys stay canonical too.
    private static func normalizingLegacyOperationNames(in data: Data) -> Data {
        guard var json = String(data: data, encoding: .utf8) else { return data }
        json = json.replacingOccurrences(of: "\"stage_switch\"", with: "\"space_switch\"")
        json = json.replacingOccurrences(of: "\"stage_raise\"", with: "\"space_raise\"")
        return Data(json.utf8)
    }

    private func write(_ envelope: Envelope) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(envelope).write(to: file, options: [.atomic, .completeFileProtection])
    }
}

/// Decides whether telemetry may send, given the user's setting and how far
/// through first-run they are.
///
/// The setting ships off. Even after a user opts in, sending stays gated until
/// onboarding finishes so the choice is presented before the first delivery.
public enum TelemetryActivationPolicy {
    public static func shouldSend(setting: Bool, onboardingCompleted: Bool) -> Bool {
        setting && onboardingCompleted
    }

    public static func shouldSend(
        settings: AppSettings,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldSend(
            setting: settings.shareAnonymousTelemetry,
            onboardingCompleted: OnboardingLaunchPolicy.hasCompleted(defaults: defaults)
        )
    }
}

public struct TelemetryStatus: Equatable, Sendable {
    public let enabled: Bool
    public let queued: Int
    public let sent: Int
    public let dropped: Int
}

public actor TelemetryExporter {
    private struct HourlySamples: Sendable {
        var durations: [Double] = []
        var maximumWindowCount = 0
    }

    /// These correspond to interactions a person directly waits for. Background maintenance
    /// operations remain available in local diagnostics and do not consume the remote event cap.
    public static let hourlyOperations: Set<PerformanceOperation> = [
        .overlayEndToEndVisible,
        .previewFirst,
        .spaceSwitch,
    ]

    private let client: any TelemetryClient
    private let queue: any TelemetryQueue
    private let dailyEventLimit: Int
    private let now: @Sendable () -> Date
    private var enabled: Bool
    private var hourlySamples: [PerformanceOperation: HourlySamples] = [:]

    public init(
        client: any TelemetryClient,
        queue: any TelemetryQueue,
        enabled: Bool,
        dailyEventLimit: Int = 24,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.queue = queue
        self.enabled = enabled
        self.dailyEventLimit = max(1, dailyEventLimit)
        self.now = now
    }

    public func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        if !enabled {
            hourlySamples.removeAll()
            try? await queue.clear()
        }
    }

    public func record(_ observation: PerformanceObservation) {
        guard enabled, Self.hourlyOperations.contains(observation.operation) else { return }
        var samples = hourlySamples[observation.operation] ?? HourlySamples()
        samples.durations.append(max(0, observation.durationMilliseconds))
        samples.maximumWindowCount = max(samples.maximumWindowCount, observation.workload.windows)
        hourlySamples[observation.operation] = samples
    }

    /// Converts the current partial hour into exact numeric P95 metrics, persists them before
    /// attempting the network request, and resets the window only after persistence succeeds.
    public func flushHourly(appVersion: String, operatingSystemMajor: Int) async throws {
        guard enabled else { return }
        let payloads: [TelemetryPayload] = hourlySamples.keys
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { operation in
            guard let samples = hourlySamples[operation], !samples.durations.isEmpty else { return nil }
            let sorted = samples.durations.sorted()
            let rank = max(1, Int(ceil(0.95 * Double(sorted.count))))
            let p95 = sorted[min(sorted.count - 1, rank - 1)]
            let workload: TelemetryWorkload = samples.maximumWindowCount >= 50
                ? .stress : (samples.maximumWindowCount >= 21 ? .busy : .typical)
            return TelemetryPayload.hourlyP95(
                operation: operation,
                milliseconds: p95,
                sampleCount: samples.durations.count,
                appVersion: appVersion,
                operatingSystemMajor: operatingSystemMajor,
                workload: workload
            )
        }
        guard !payloads.isEmpty else { return }
        try await enqueue(payloads)
        hourlySamples.removeAll()
        try await flush()
    }

    private func enqueue(_ newPayloads: [TelemetryPayload]) async throws {
        guard enabled, !newPayloads.isEmpty else { return }
        var quota = try await currentQuota()
        var payloads = try await queue.payloads()
        let remaining = max(0, dailyEventLimit - quota.sent - payloads.count)
        payloads.append(contentsOf: newPayloads.prefix(remaining))
        quota.dropped += max(0, newPayloads.count - remaining)
        try await queue.replace(with: payloads)
        try await queue.setQuota(quota)
    }

    public func flush() async throws {
        guard enabled else { return }
        var quota = try await currentQuota()
        let payloads = try await queue.payloads()
        guard !payloads.isEmpty else { return }
        try await client.send(payloads)
        quota.sent += payloads.count
        try await queue.replace(with: [])
        try await queue.setQuota(quota)
    }

    /// Bucketed events from schema v1 cannot participate in the numeric time series. They are
    /// discarded locally during migration instead of mixing incompatible schemas remotely.
    public func pruneLegacyPayloads() async throws {
        let payloads = try await queue.payloads()
        let retained = payloads.filter { $0.event == .hourlyP95 }
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
