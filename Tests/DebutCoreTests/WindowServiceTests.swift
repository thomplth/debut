import Testing
import Foundation
@testable import DebutCore

@Suite("MockWindowService")
struct WindowServiceTests {

    @Test("List running apps")
    func listApps() {
        let svc = MockWindowService()
        svc.apps = [
            AppInfo(bundleID: "com.a", name: "A", pid: 100, isHidden: false),
            AppInfo(bundleID: "com.b", name: "B", pid: 200, isHidden: false),
        ]
        #expect(svc.listRunningApps().count == 2)
    }

    @Test("Hide app")
    func hideApp() {
        let svc = MockWindowService()
        #expect(svc.hideApp(bundleID: "com.a"))
        #expect(svc.hiddenBundleIDs.contains("com.a"))
    }

    @Test("Unhide app")
    func unhideApp() {
        let svc = MockWindowService()
        _ = svc.hideApp(bundleID: "com.a")
        #expect(svc.unhideApp(bundleID: "com.a"))
        #expect(!svc.hiddenBundleIDs.contains("com.a"))
    }

    @Test("Activate app")
    func activateApp() {
        let svc = MockWindowService()
        _ = svc.hideApp(bundleID: "com.a")
        #expect(svc.activateApp(bundleID: "com.a"))
        #expect(svc.activatedBundleID == "com.a")
        #expect(!svc.hiddenBundleIDs.contains("com.a"))
    }

    @Test("Stage switch hides old apps, unhides new")
    func stageSwitchHideShow() {
        let svc = MockWindowService()
        var sm = StageManager()
        let stageA = sm.stages[0].id
        sm.createStage(name: "B", position: .below)
        let stageB = sm.stages[1].id

        sm.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: stageA)
        sm.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: stageB)

        // Simulate switching from B to A
        for app in sm.stages.first(where: { $0.id == stageB })!.apps {
            _ = svc.hideApp(bundleID: app.bundleID)
        }
        for app in sm.stages.first(where: { $0.id == stageA })!.apps {
            _ = svc.unhideApp(bundleID: app.bundleID)
        }

        #expect(svc.hiddenBundleIDs.contains("com.b"))
        #expect(!svc.hiddenBundleIDs.contains("com.a"))
    }
}
