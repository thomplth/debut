import Foundation
import Testing
@testable import DebutCore

@Suite("DebutCore basics")
struct DebutCoreTests {
    @Test("Version is set")
    func versionExists() {
        #expect(!DebutCore.version.isEmpty)
    }

    @Test("Obsolete remote metrics queue is removed")
    func removesObsoleteRemoteMetricsQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutRemoteMetricsCleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = directory.appendingPathComponent("telemetry-queue.json")
        try Data("pending".utf8).write(to: queue)

        LegacyDataCleanup.removeObsoleteRemoteMetricsQueue(from: directory)

        #expect(!FileManager.default.fileExists(atPath: queue.path))
    }
}
