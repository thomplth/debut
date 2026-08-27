import DebutCore
import CoreGraphics
import Foundation

private struct Artifact: Encodable {
    let schemaVersion = 1
    let configuration: String
    let generatedAt: Date
    let benchmarks: [Result]
}

private struct Result: Codable {
    let operation: String
    let iterations: Int
    let workload: PerformanceWorkload
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
    let cpuNanoseconds: UInt64
    let footprintBytes: UInt64?
}

private func measure(
    operation: PerformanceOperation,
    iterations: Int = 100,
    workload: PerformanceWorkload,
    body: () -> Void
) -> Result {
    var samples = PerformanceSampleBuffer(capacity: iterations)
    let resources = SystemProcessResourceReader()
    let before = resources.read()
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    let after = resources.read()
    let summary = samples.summary!
    let cpu: UInt64
    if let before, let after {
        cpu = after.userCPUNanoseconds - before.userCPUNanoseconds
            + after.systemCPUNanoseconds - before.systemCPUNanoseconds
    } else {
        cpu = 0
    }
    return Result(
        operation: operation.rawValue, iterations: iterations, workload: workload,
        medianMilliseconds: summary.medianMilliseconds, p95Milliseconds: summary.p95Milliseconds,
        p99Milliseconds: summary.p99Milliseconds, maximumMilliseconds: summary.maximumMilliseconds,
        cpuNanoseconds: cpu, footprintBytes: after?.physicalFootprintBytes
    )
}

private func manager(spaces: Int, windows: Int) -> SpaceManager {
    var manager = SpaceManager()
    while manager.spaces.count < spaces { manager.createSpace(position: .below) }
    for index in 0..<windows {
        let space = manager.spaces[index % spaces].id
        manager.addWindow(SpaceWindow(
            windowID: CGWindowID(index + 1), ownerBundleID: "fixture.\(index % 10)",
            ownerName: "Fixture", windowTitle: "Window \(index)", ownerPID: pid_t(index % 10 + 100)
        ), toSpaceID: space)
    }
    return manager
}

private let workload = PerformanceWorkload(spaces: 10, windows: 50, dormantWindows: 50, processes: 10)
private let results = [
    measure(operation: .overlayPreparation, workload: workload) {
        _ = StageOverlayViewModel(spaceManager: manager(spaces: 10, windows: 50), activeSpaceIndex: 5, selectedWindowIndex: 0).stages
    },
    measure(operation: .windowReconciliation, workload: workload) {
        var state = manager(spaces: 10, windows: 50)
        var reconciler = RuntimeWindowReconciler()
        let infos = (0..<50).map { index in
            WindowInfo(windowID: CGWindowID(index + 1000), ownerBundleID: "fixture.\(index % 10)", ownerName: "Fixture", ownerPID: pid_t(index % 10 + 100), title: "Dynamic \(index)", bounds: .zero, isOnScreen: true)
        }
        _ = reconciler.reconcile(RuntimeWindowSnapshot(liveWindows: infos, allWindowIDs: Set(infos.map(\.windowID))), spaceManager: &state)
    },
    measure(operation: .statePersistence, workload: workload) {
        _ = try? JSONEncoder().encode(manager(spaces: 10, windows: 50))
    },
]

private let artifact = Artifact(configuration: "release", generatedAt: Date(), benchmarks: results)
private let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(artifact))
FileHandle.standardOutput.write(Data([0x0A]))
