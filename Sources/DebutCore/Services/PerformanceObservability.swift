import Darwin
import Foundation
import os

/// Stable operation names shared by diagnostics, benchmark artifacts, signposts, and telemetry.
public enum PerformanceOperation: String, CaseIterable, Codable, Sendable {
    case eventTap = "event_tap"
    case mainQueueDelivery = "main_queue_delivery"
    case overlayPreparation = "overlay_preparation"
    case overlayFirstFrame = "overlay_first_frame"
    case previewFirst = "preview_first"
    case previewAll = "preview_all"
    case previewCapture = "preview_capture"
    case windowDiscovery = "window_discovery"
    case windowClassification = "window_classification"
    case windowReconciliation = "window_reconciliation"
    case stageSwitch = "stage_switch"
    case stageRaise = "stage_raise"
    case wallpaperCapture = "wallpaper_capture"
    case statePersistence = "state_persistence"
    case hiddenIdle = "hidden_idle"
}

public struct PerformanceWorkload: Codable, Equatable, Sendable {
    public var stages: Int
    public var windows: Int
    public var dormantWindows: Int
    public var processes: Int
    public var captures: Int

    public init(
        stages: Int = 0,
        windows: Int = 0,
        dormantWindows: Int = 0,
        processes: Int = 0,
        captures: Int = 0
    ) {
        self.stages = max(0, stages)
        self.windows = max(0, windows)
        self.dormantWindows = max(0, dormantWindows)
        self.processes = max(0, processes)
        self.captures = max(0, captures)
    }
}

public struct PerformanceSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
    public let maximumMilliseconds: Double

    public init(
        count: Int,
        medianMilliseconds: Double,
        p95Milliseconds: Double,
        p99Milliseconds: Double,
        maximumMilliseconds: Double
    ) {
        self.count = count
        self.medianMilliseconds = medianMilliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }
}

public struct PerformanceSampleBuffer: Sendable {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ value: Double) {
        values.append(max(0, value))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var summary: PerformanceSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let rank = max(1, Int(ceil(p * Double(sorted.count))))
            return sorted[min(sorted.count - 1, rank - 1)]
        }
        return PerformanceSummary(
            count: sorted.count,
            medianMilliseconds: percentile(0.5),
            p95Milliseconds: percentile(0.95),
            p99Milliseconds: percentile(0.99),
            maximumMilliseconds: sorted.last!
        )
    }
}

public struct ProcessResourceSnapshot: Codable, Equatable, Sendable {
    public let monotonicNanoseconds: UInt64
    public let userCPUNanoseconds: UInt64
    public let systemCPUNanoseconds: UInt64
    public let physicalFootprintBytes: UInt64
    public let peakPhysicalFootprintBytes: UInt64
    public let threadCount: Int
    public let wakeups: UInt64
    public let bytesRead: UInt64
    public let bytesWritten: UInt64

    public init(
        monotonicNanoseconds: UInt64,
        userCPUNanoseconds: UInt64,
        systemCPUNanoseconds: UInt64,
        physicalFootprintBytes: UInt64,
        peakPhysicalFootprintBytes: UInt64,
        threadCount: Int,
        wakeups: UInt64,
        bytesRead: UInt64,
        bytesWritten: UInt64
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.userCPUNanoseconds = userCPUNanoseconds
        self.systemCPUNanoseconds = systemCPUNanoseconds
        self.physicalFootprintBytes = physicalFootprintBytes
        self.peakPhysicalFootprintBytes = peakPhysicalFootprintBytes
        self.threadCount = threadCount
        self.wakeups = wakeups
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

public struct ProcessResourceDelta: Codable, Equatable, Sendable {
    public let cpuPercent: Double
    public let wakeups: UInt64
    public let bytesRead: UInt64
    public let bytesWritten: UInt64

    public static func between(
        _ previous: ProcessResourceSnapshot,
        _ current: ProcessResourceSnapshot
    ) -> ProcessResourceDelta? {
        guard current.monotonicNanoseconds > previous.monotonicNanoseconds,
              current.userCPUNanoseconds >= previous.userCPUNanoseconds,
              current.systemCPUNanoseconds >= previous.systemCPUNanoseconds,
              current.wakeups >= previous.wakeups,
              current.bytesRead >= previous.bytesRead,
              current.bytesWritten >= previous.bytesWritten
        else { return nil }
        let elapsed = current.monotonicNanoseconds - previous.monotonicNanoseconds
        let cpu = current.userCPUNanoseconds - previous.userCPUNanoseconds
            + current.systemCPUNanoseconds - previous.systemCPUNanoseconds
        return ProcessResourceDelta(
            cpuPercent: Double(cpu) / Double(elapsed) * 100,
            wakeups: current.wakeups - previous.wakeups,
            bytesRead: current.bytesRead - previous.bytesRead,
            bytesWritten: current.bytesWritten - previous.bytesWritten
        )
    }
}

public protocol ProcessResourceReading: Sendable {
    func read() -> ProcessResourceSnapshot?
}

public struct UnavailableProcessResourceReader: ProcessResourceReading {
    public init() {}
    public func read() -> ProcessResourceSnapshot? { nil }
}

public struct SystemProcessResourceReader: ProcessResourceReading {
    public init() {}

    public func read() -> ProcessResourceSnapshot? {
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard usageResult == 0 else { return nil }
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        if result == KERN_SUCCESS, let threadList {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            )
        }
        return ProcessResourceSnapshot(
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            userCPUNanoseconds: usage.ri_user_time,
            systemCPUNanoseconds: usage.ri_system_time,
            physicalFootprintBytes: usage.ri_phys_footprint,
            peakPhysicalFootprintBytes: usage.ri_lifetime_max_phys_footprint,
            threadCount: result == KERN_SUCCESS ? Int(threadCount) : 0,
            wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups,
            bytesRead: usage.ri_diskio_bytesread,
            bytesWritten: usage.ri_diskio_byteswritten
        )
    }
}

public struct PerformanceObservation: Codable, Equatable, Sendable {
    public let correlationID: UUID
    public let operation: PerformanceOperation
    public let durationMilliseconds: Double
    public let workload: PerformanceWorkload
}

public struct PerformanceSnapshot: Codable, Sendable {
    public let resources: ProcessResourceSnapshot?
    public let resourceDelta: ProcessResourceDelta?
    public let summaries: [String: PerformanceSummary]
    public let recent: [PerformanceObservation]
}

public final class PerformanceRecorder: @unchecked Sendable {
    private struct Active {
        let operation: PerformanceOperation
        let started: UInt64
        let workload: PerformanceWorkload
        let signpostID: OSSignpostID
    }

    public static let shared = PerformanceRecorder(resourceReader: defaultResourceReader())

    private static func defaultResourceReader() -> any ProcessResourceReading {
        // Unit and screenshot suites create many controllers concurrently. They test injected
        // readers separately and must not turn every synthetic operation into a Mach task scan.
        Bundle.main.bundleIdentifier == "com.thomplth.Debut"
            ? SystemProcessResourceReader()
            : UnavailableProcessResourceReader()
    }
    private let lock = NSLock()
    private let resourceReader: any ProcessResourceReading
    private let now: @Sendable () -> UInt64
    private let log = OSLog(subsystem: "com.thomplth.Debut", category: "performance")
    private var active: [UUID: Active] = [:]
    private var buffers: [PerformanceOperation: PerformanceSampleBuffer] = [:]
    private var observations: [PerformanceObservation] = []
    private var resources: ProcessResourceSnapshot?
    private var resourceDelta: ProcessResourceDelta?
    private var observationHandler: (@Sendable (PerformanceObservation) -> Void)?

    public init(
        resourceReader: any ProcessResourceReading = SystemProcessResourceReader(),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.resourceReader = resourceReader
        self.now = now
    }

    @discardableResult
    public func begin(
        _ operation: PerformanceOperation,
        workload: PerformanceWorkload = PerformanceWorkload(),
        correlationID: UUID = UUID()
    ) -> UUID {
        let signpostID = OSSignpostID(log: log)
        let signpostMetadata = "operation=\(operation.rawValue) correlation=\(correlationID.uuidString) windows=\(workload.windows) stages=\(workload.stages)" as NSString
        os_signpost(.begin, log: log, name: "DebutOperation", signpostID: signpostID,
                    "%{public}@", signpostMetadata)
        lock.lock()
        active[correlationID] = Active(
            operation: operation,
            started: now(),
            workload: workload,
            signpostID: signpostID
        )
        lock.unlock()
        return correlationID
    }

    @discardableResult
    public func end(
        _ correlationID: UUID,
        sampleResources: Bool = true
    ) -> PerformanceObservation? {
        let ended = now()
        let sampled = sampleResources ? resourceReader.read() : nil
        lock.lock()
        guard let span = active.removeValue(forKey: correlationID) else {
            lock.unlock()
            return nil
        }
        let duration = Double(ended >= span.started ? ended - span.started : 0) / 1_000_000
        let observation = PerformanceObservation(
            correlationID: correlationID,
            operation: span.operation,
            durationMilliseconds: duration,
            workload: span.workload
        )
        var buffer = buffers[span.operation] ?? PerformanceSampleBuffer()
        buffer.append(duration)
        buffers[span.operation] = buffer
        observations.append(observation)
        if observations.count > 100 { observations.removeFirst(observations.count - 100) }
        if let sampled {
            resourceDelta = resources.flatMap { ProcessResourceDelta.between($0, sampled) }
            resources = sampled
        }
        let handler = observationHandler
        lock.unlock()
        let signpostMetadata = "operation=\(span.operation.rawValue) correlation=\(correlationID.uuidString) duration_ms=\(duration)" as NSString
        os_signpost(.end, log: log, name: "DebutOperation", signpostID: span.signpostID,
                    "%{public}@", signpostMetadata)
        handler?(observation)
        return observation
    }

    public func setObservationHandler(
        _ handler: (@Sendable (PerformanceObservation) -> Void)?
    ) {
        lock.lock()
        observationHandler = handler
        lock.unlock()
    }

    public func point(
        _ operation: PerformanceOperation,
        correlationID: UUID = UUID(),
        workload: PerformanceWorkload = PerformanceWorkload()
    ) {
        let signpostMetadata = "operation=\(operation.rawValue) correlation=\(correlationID.uuidString) windows=\(workload.windows) stages=\(workload.stages)" as NSString
        os_signpost(.event, log: log, name: "DebutPoint", "%{public}@", signpostMetadata)
    }

    public func snapshot() -> PerformanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PerformanceSnapshot(
            resources: resources,
            resourceDelta: resourceDelta,
            summaries: Dictionary(uniqueKeysWithValues: buffers.compactMap { operation, buffer in
                buffer.summary.map { (operation.rawValue, $0) }
            }),
            recent: observations
        )
    }
}
