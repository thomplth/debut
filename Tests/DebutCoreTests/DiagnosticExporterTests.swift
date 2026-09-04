import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("DiagnosticExporter")
struct DiagnosticExporterTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebutDiagnosticExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Export contains runtime, persisted, lifecycle, and tracking evidence")
    func exportsInvestigationData() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var manager = SpaceManager()
        manager.addWindow(
            SpaceWindow(
                windowID: 41,
                ownerBundleID: "com.example.Editor",
                ownerName: "Editor",
                windowTitle: "Runtime document",
                ownerPID: 501
            ),
            toSpaceID: manager.activeSpaceID
        )
        let store = StateStore(directory: directory)
        try store.save(manager)
        var settings = AppSettings()
        settings.excludedBundleIDs = ["com.example.Hidden"]
        try store.saveSettings(settings)

        let reporter = DiagnosticReporter(directory: directory)
        reporter.setStateProvider { ["spaceCount": "1", "windowCountsBySpace": "1"] }
        reporter.report("tracking_failed", details: [
            "windowID": "99",
            "step": "element_lookup",
        ])
        reporter.flush()

        let snapshot = DiagnosticExportSnapshot(
            spaceManager: manager,
            settings: settings,
            liveWindows: [
                WindowInfo(
                    windowID: 41,
                    ownerBundleID: "com.example.Editor",
                    ownerName: "Editor",
                    ownerPID: 501,
                    title: "Runtime document",
                    bounds: CGRect(x: 12, y: 34, width: 800, height: 600),
                    isOnScreen: true
                ),
            ],
            runningApps: [
                AppInfo(
                    bundleID: "com.example.Editor",
                    name: "Editor",
                    pid: 501,
                    isHidden: false
                ),
            ],
            allWindowIDs: [41, 99],
            untrackableWindowIDs: [77],
            tracking: WindowTrackingDiagnosticSnapshot(
                knownWindowIDs: [41],
                armedWindowIDs: [41],
                unarmedWindowIDs: [99],
                monitoredProcessIDs: [501],
                observedPID: 501,
                observerProcessIDs: [501],
                windowOwners: [
                    WindowTrackingDiagnosticSnapshot.WindowOwner(windowID: 41, ownerPID: 501),
                    WindowTrackingDiagnosticSnapshot.WindowOwner(windowID: 99, ownerPID: 501),
                ]
            ),
            frontmostBundleID: "com.example.Editor",
            accessibilityEnabled: true,
            screens: [
                DiagnosticScreenSnapshot(
                    frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                    visibleFrame: CGRect(x: 0, y: 25, width: 1728, height: 1068),
                    backingScaleFactor: 2
                ),
            ]
        )
        let destination = directory.appendingPathComponent("export.json")
        let redactor = DiagnosticRedactor(salt: "salt-a")
        let exporter = DiagnosticExporter(
            applicationSupportDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            redactor: redactor
        )

        try exporter.export(snapshot, to: destination)

        let data = try Data(contentsOf: destination)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(root["metadata"] as? [String: Any])
        #expect(metadata["schemaVersion"] as? Int == 1)
        #expect(metadata["generatedAt"] as? String == "2023-11-14T22:13:20Z")

        let runtime = try #require(root["runtime"] as? [String: Any])
        let liveWindows = try #require(runtime["discoveredWindows"] as? [[String: Any]])
        #expect(liveWindows.first?["windowTitle"] == nil)
        #expect(
            liveWindows.first?["windowTitleHash"] as? String == redactor.hashedTitle("Runtime document")
        )
        #expect(runtime["allCGWindowIDs"] as? [Int] == [41, 99])
        #expect(runtime["untrackableWindowIDs"] as? [Int] == [77])
        let tracking = try #require(runtime["tracking"] as? [String: Any])
        #expect(tracking["unarmedWindowIDs"] as? [Int] == [99])

        let persisted = try #require(root["persisted"] as? [String: Any])
        let persistedState = try #require(persisted["state"] as? [String: Any])
        let spaces = try #require(persistedState["spaces"] as? [[String: Any]])
        let persistedWindows = try #require(spaces.first?["windows"] as? [[String: Any]])
        #expect(persistedWindows.first?["windowTitle"] == nil)
        #expect(
            persistedWindows.first?["windowTitleHash"] as? String
                == redactor.hashedTitle("Runtime document")
        )

        // The export is the boundary titles actually cross: it lands wherever a
        // save panel points and gets attached to public bug reports.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Runtime document"))

        let diagnostic = try #require(root["diagnostic"] as? [String: Any])
        let currentLog = try #require(diagnostic["currentLifecycleEvents"] as? [[String: Any]])
        #expect(currentLog.last?["event"] as? String == "tracking_failed")
        let currentSnapshot = try #require(diagnostic["currentSnapshot"] as? [String: Any])
        let diagnosticState = try #require(currentSnapshot["state"] as? [String: String])
        #expect(diagnosticState["spaceCount"] == "1")
    }

    @Test("Export records missing support files instead of failing")
    func missingFilesAreExplicit() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.json")

        try DiagnosticExporter(applicationSupportDirectory: directory)
            .export(.empty, to: destination)

        let data = try Data(contentsOf: destination)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let persisted = try #require(root["persisted"] as? [String: Any])
        let unavailable = try #require(persisted["state"] as? [String: String])
        #expect(unavailable["status"] == "missing")
    }
}
