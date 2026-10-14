import Darwin
import Foundation

/// Cumulative CPU, and energy where the kernel will say, of the processes a window capture
/// makes work. Measured with capbench (2026-10-13): each capture costs ~80 CPU-ms in the privacy
/// machinery, the same for every ScreenCaptureKit API, so this is where capture power goes.
///
/// The figures are system-wide: another app recording the screen is counted too. A rollup that
/// pairs them with Debut's own capture count is evidence about a trend, not an attribution.
struct CaptureCostSample: Equatable, Sendable {
    var cpuNanoseconds: [String: UInt64]
    var energyNanojoules: [String: UInt64]

    struct Delta: Equatable, Sendable {
        let cpuNanoseconds: [String: UInt64]
        let energyNanojoules: [String: UInt64]

        var diagnosticDetails: [String: String] {
            var details: [String: String] = [:]
            for (name, value) in cpuNanoseconds {
                details["cpuMilliseconds.\(name)"] = String(format: "%.0f", Double(value) / 1_000_000)
            }
            for (name, value) in energyNanojoules {
                details["energyMillijoules.\(name)"] = String(format: "%.0f", Double(value) / 1_000_000)
            }
            return details
        }
    }

    /// A process that restarted between samples reads lower than before; it is left out rather
    /// than reported as a negative cost.
    func delta(since earlier: CaptureCostSample) -> Delta {
        func subtract(_ now: [String: UInt64], _ then: [String: UInt64]) -> [String: UInt64] {
            now.reduce(into: [:]) { result, entry in
                guard let previous = then[entry.key], entry.value >= previous else { return }
                result[entry.key] = entry.value - previous
            }
        }
        return Delta(
            cpuNanoseconds: subtract(cpuNanoseconds, earlier.cpuNanoseconds),
            energyNanojoules: subtract(energyNanojoules, earlier.energyNanojoules)
        )
    }
}

protocol CaptureCostSampling: Sendable {
    func sample() -> CaptureCostSample
}

/// Reads same-user daemons directly (~1us each) and the root-owned ones through `ps`, since the
/// kernel refuses their counters to an unprivileged caller. Development builds only: it spawns
/// a process.
struct SystemCaptureCostSampler: CaptureCostSampling {
    static let processNames = ["WindowServer", "systemstatusd", "ControlCenter", "tccd", "replayd"]
    static let ownName = "Debut"

    func sample() -> CaptureCostSample {
        var result = CaptureCostSample(cpuNanoseconds: [:], energyNanojoules: [:])
        let ownPID = getpid()
        var unreadable: [pid_t: String] = [:]
        for pid in Self.allPIDs() {
            let name = pid == ownPID ? Self.ownName : Self.name(of: pid)
            guard pid == ownPID || Self.processNames.contains(name) else { continue }
            if let usage = Self.usage(of: pid) {
                result.cpuNanoseconds[name, default: 0] += SystemProcessResourceReader.nanoseconds(
                    ticks: usage.ri_user_time + usage.ri_system_time
                )
                result.energyNanojoules[name, default: 0] += usage.ri_energy_nj
            } else {
                unreadable[pid] = name
            }
        }
        for (pid, nanoseconds) in Self.psCPU(pids: Array(unreadable.keys)) {
            guard let name = unreadable[pid] else { continue }
            result.cpuNanoseconds[name, default: 0] += nanoseconds
        }
        return result
    }

    private static func allPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return Array(pids.prefix(max(0, count))).filter { $0 > 0 }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func usage(of pid: pid_t) -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    private static func psCPU(pids: [pid_t]) -> [pid_t: UInt64] {
        guard !pids.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,time=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parsePS(String(decoding: data, as: UTF8.self))
    }

    /// `ps` prints cumulative CPU as `[[dd-]hh:]mm:ss.cc`.
    static func parsePS(_ output: String) -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count == 2, let pid = pid_t(columns[0]) else { continue }
            var remainder = Substring(columns[1])
            var days = 0.0
            if let dash = remainder.firstIndex(of: "-") {
                days = Double(remainder[..<dash]) ?? 0
                remainder = remainder[remainder.index(after: dash)...]
            }
            let seconds = remainder.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            result[pid] = UInt64(((days * 86_400) + seconds) * 1_000_000_000)
        }
        return result
    }
}
