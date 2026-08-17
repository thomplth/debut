import Dispatch

protocol ProcessExitMonitoring: AnyObject, Sendable {
    func startMonitoring(pid: pid_t, onExit: @escaping @Sendable (pid_t) -> Void)
    func stopMonitoring(pid: pid_t)
    func stopMonitoringAll()
}

/// Listens for kernel process-exit events without polling.
final class ProcessExitMonitor: ProcessExitMonitoring, @unchecked Sendable {
    private var sources: [pid_t: DispatchSourceProcess] = [:]

    func startMonitoring(pid: pid_t, onExit: @escaping @Sendable (pid_t) -> Void) {
        guard pid > 0, sources[pid] == nil else { return }

        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler {
            onExit(pid)
        }
        sources[pid] = source
        source.resume()
    }

    func stopMonitoring(pid: pid_t) {
        guard let source = sources.removeValue(forKey: pid) else { return }
        source.cancel()
    }

    func stopMonitoringAll() {
        for pid in Array(sources.keys) {
            stopMonitoring(pid: pid)
        }
    }

    deinit {
        stopMonitoringAll()
    }
}
