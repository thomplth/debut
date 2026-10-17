import AppKit
import Darwin
import Foundation
import QuartzCore

// MARK: - Process counters

/// Debut's own `proc_pid_rusage`, about 5 us a read.
struct OwnProcessHealthReader: Sendable {
    func sample(gpuNanojoules: UInt64?) -> HealthSample {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let usage = Self.usage() else {
            return HealthSample(
                uptimeNanoseconds: now,
                cpuNanoseconds: 0,
                energyNanojoules: 0,
                gpuNanojoules: gpuNanojoules,
                footprintBytes: 0,
                peakFootprintBytes: 0,
                wakeups: 0
            )
        }
        return HealthSample(
            uptimeNanoseconds: now,
            cpuNanoseconds: SystemProcessResourceReader.nanoseconds(
                ticks: usage.ri_user_time + usage.ri_system_time
            ),
            energyNanojoules: usage.ri_energy_nj,
            gpuNanojoules: gpuNanojoules,
            footprintBytes: usage.ri_phys_footprint,
            peakFootprintBytes: usage.ri_lifetime_max_phys_footprint,
            wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups
        )
    }

    /// On the uptime clock: the start is Mach absolute time, the same base as
    /// `DispatchTime.uptimeNanoseconds`.
    func processStartedAt() -> UInt64? {
        Self.usage().map { SystemProcessResourceReader.nanoseconds(ticks: $0.ri_proc_start_abstime) }
    }

    private static func usage() -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? usage : nil
    }
}

/// The GPU's cumulative energy from IOReport's "Energy Model" group, the only channel of it an
/// unprivileged process can read on macOS 27: the CPU channels all read zero without root.
/// Private API, so development builds only, and nil wherever the library or channel is missing.
final class GPUEnergyReader: @unchecked Sendable {
    private typealias CopyChannelsInGroup = @convention(c) (
        CFString, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64,
        CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (
        OpaquePointer, CFMutableDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (
        CFDictionary, CFDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleIntegerValue = @convention(c) (
        CFDictionary, UnsafeMutablePointer<Int32>?
    ) -> Int64

    private static let channelName = "GPU Energy"

    private let createSamples: CreateSamples
    private let createSamplesDelta: CreateSamplesDelta
    private let unitLabel: ChannelString
    private let integerValue: SimpleIntegerValue
    private let subscription: OpaquePointer
    private let subscribedChannels: CFMutableDictionary
    private let lock = NSLock()
    private var previous: CFDictionary
    private var total: UInt64 = 0

    init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copyChannels = dlsym(library, "IOReportCopyChannelsInGroup"),
              let createSubscription = dlsym(library, "IOReportCreateSubscription"),
              let createSamples = dlsym(library, "IOReportCreateSamples"),
              let createSamplesDelta = dlsym(library, "IOReportCreateSamplesDelta"),
              let channelName = dlsym(library, "IOReportChannelGetChannelName"),
              let unitLabel = dlsym(library, "IOReportChannelGetUnitLabel"),
              let integerValue = dlsym(library, "IOReportSimpleGetIntegerValue")
        else { return nil }
        let nameOf = unsafeBitCast(channelName, to: ChannelString.self)
        guard let group = unsafeBitCast(copyChannels, to: CopyChannelsInGroup.self)(
            "Energy Model" as CFString, nil, 0, 0, 0
        )?.takeRetainedValue() as? [String: Any],
            let channels = group["IOReportChannels"] as? [CFDictionary]
        else { return nil }
        let gpu = channels.filter {
            nameOf($0)?.takeUnretainedValue() as String? == Self.channelName
        }
        guard !gpu.isEmpty else { return nil }
        var request = group
        request["IOReportChannels"] = gpu
        let requested = NSMutableDictionary(dictionary: request) as CFMutableDictionary
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = unsafeBitCast(createSubscription, to: CreateSubscription.self)(
            nil, requested, &subscribed, 0, nil
        ),
            let subscribedChannels = subscribed?.takeRetainedValue()
        else { return nil }
        self.createSamples = unsafeBitCast(createSamples, to: CreateSamples.self)
        self.createSamplesDelta = unsafeBitCast(createSamplesDelta, to: CreateSamplesDelta.self)
        self.unitLabel = unsafeBitCast(unitLabel, to: ChannelString.self)
        self.integerValue = unsafeBitCast(integerValue, to: SimpleIntegerValue.self)
        self.subscription = subscription
        self.subscribedChannels = subscribedChannels
        guard let first = self.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        else { return nil }
        self.previous = first
    }

    /// Since this reader was created. IOReport only answers deltas between two samples.
    func cumulativeNanojoules() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue(),
              let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue(),
              let channels = (delta as? [String: Any])?["IOReportChannels"] as? [CFDictionary]
        else { return nil }
        previous = current
        for channel in channels {
            let value = integerValue(channel, nil)
            guard value > 0 else { continue }
            total += UInt64(value) * Self.nanojoules(perUnit: unitLabel(channel)?.takeUnretainedValue() as String?)
        }
        return total
    }

    private static func nanojoules(perUnit unit: String?) -> UInt64 {
        switch unit {
        case "mJ": 1_000_000
        case "uJ": 1_000
        default: 1
        }
    }
}

// MARK: - Frame pacing

struct FramePacingSummary: Equatable, Sendable {
    let frames: Int
    let slowFrames: Int
    let longestMilliseconds: Double
    let refreshMilliseconds: Double
}

/// Counts display-link callbacks that arrived more than one and a half refresh intervals after
/// the previous one. The callback runs on the main run loop, so this sees Debut's own hitches;
/// a frame WindowServer drops while compositing never reaches it.
struct FramePacingCounter: Sendable {
    static let slowFactor = 1.5

    private var previousTimestamp: Double?
    private var frames = 0
    private var slowFrames = 0
    private var longest = 0.0
    private var refresh = 0.0

    mutating func frame(timestamp: Double, duration: Double) {
        defer { previousTimestamp = timestamp }
        refresh = duration
        guard let previousTimestamp else { return }
        let interval = timestamp - previousTimestamp
        frames += 1
        longest = max(longest, interval)
        if interval > duration * Self.slowFactor { slowFrames += 1 }
    }

    var summary: FramePacingSummary? {
        guard frames >= 2 else { return nil }
        return FramePacingSummary(
            frames: frames,
            slowFrames: slowFrames,
            longestMilliseconds: longest * 1000,
            refreshMilliseconds: refresh * 1000
        )
    }
}

protocol OverlayFrameCounting: AnyObject {
    func start(screen: NSScreen?)
    func stop() -> FramePacingSummary?
}

/// Runs only while the overlay is visible: an idle Debut gets no callbacks.
final class DisplayLinkFrameCounter: NSObject, OverlayFrameCounting {
    private var link: CADisplayLink?
    private var counter = FramePacingCounter()

    func start(screen: NSScreen?) {
        link?.invalidate()
        counter = FramePacingCounter()
        guard let screen = screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() -> FramePacingSummary? {
        link?.invalidate()
        link = nil
        return counter.summary
    }

    @objc private func tick(_ link: CADisplayLink) {
        counter.frame(timestamp: link.timestamp, duration: link.duration)
    }
}

// MARK: - Main run-loop stalls

/// Times main run-loop work between the points the run loop reports, leaving out the time it
/// sleeps. A nested run loop (menu tracking, a modal) splits the outer pass, so a stall can be
/// under-reported there but never invented.
struct RunLoopStallDetector: Sendable {
    enum Activity: Sendable {
        case woke
        case passBegan
        case aboutToSleep
    }

    private let thresholdNanoseconds: UInt64
    private var workStartedAt: UInt64?

    init(thresholdMilliseconds: Double) {
        thresholdNanoseconds = UInt64(thresholdMilliseconds * 1_000_000)
    }

    /// The stall's length in milliseconds when the work since the last mark crossed the threshold.
    mutating func observe(_ activity: Activity, at now: UInt64) -> Double? {
        defer { workStartedAt = activity == .aboutToSleep ? nil : now }
        guard activity != .woke, let workStartedAt, now &- workStartedAt >= thresholdNanoseconds
        else { return nil }
        return Double(now - workStartedAt) / 1_000_000
    }
}

/// Unlike `MainQueueStallWatchdog`, which covers only render submission, this sees every pass of
/// the main run loop. Each callback reads the clock and nothing else.
final class MainRunLoopStallObserver {
    private var observer: CFRunLoopObserver?

    init(thresholdMilliseconds: Double, onStall: @escaping (Double) -> Void) {
        var detector = RunLoopStallDetector(thresholdMilliseconds: thresholdMilliseconds)
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeTimers, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { _, activity in
            let mapped: RunLoopStallDetector.Activity = switch activity {
            case .afterWaiting: .woke
            case .beforeWaiting: .aboutToSleep
            default: .passBegan
            }
            if let stall = detector.observe(mapped, at: DispatchTime.now().uptimeNanoseconds) {
                onStall(stall)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
    }
}
