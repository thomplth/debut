import Testing
import Foundation
@testable import DebutCore

@Suite("MockWindowService")
struct WindowServiceTests {

    private func makeMockService() -> MockWindowService {
        let svc = MockWindowService()
        svc.windows = [
            WindowInfo(windowID: 1, appBundleID: "com.a", appName: "AppA", title: "Window 1", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: false, ownerPID: 100),
            WindowInfo(windowID: 2, appBundleID: "com.b", appName: "AppB", title: "Window 2", frame: CGRect(x: 100, y: 100, width: 1200, height: 800), isMinimized: false, ownerPID: 200),
            WindowInfo(windowID: 3, appBundleID: "com.c", appName: "AppC", title: "Window 3", frame: CGRect(x: 200, y: 200, width: 600, height: 400), isMinimized: false, ownerPID: 300),
        ]
        return svc
    }

    @Test("List windows returns all windows")
    func listWindows() {
        let svc = makeMockService()
        #expect(svc.listWindows().count == 3)
    }

    @Test("Hide window adds to hidden set")
    func hideWindow() {
        let svc = makeMockService()
        #expect(svc.hideWindow(windowID: 1))
        #expect(svc.hiddenWindowIDs.contains(1))
    }

    @Test("Show window removes from hidden set")
    func showWindow() {
        let svc = makeMockService()
        _ = svc.hideWindow(windowID: 1)
        #expect(svc.showWindow(windowID: 1))
        #expect(!svc.hiddenWindowIDs.contains(1))
    }

    @Test("Focus window sets focused ID and shows")
    func focusWindow() {
        let svc = makeMockService()
        _ = svc.hideWindow(windowID: 2)
        #expect(svc.focusWindow(windowID: 2))
        #expect(svc.focusedWindowID == 2)
        #expect(!svc.hiddenWindowIDs.contains(2))
    }

    @Test("Close window succeeds and removes from list")
    func closeWindow() {
        let svc = makeMockService()
        #expect(svc.closeWindow(windowID: 1))
        #expect(svc.closedWindowIDs.contains(1))
        #expect(svc.listWindows().count == 2)
    }

    @Test("Close window fails for protected windows")
    func closeWindowFails() {
        let svc = makeMockService()
        svc.closeWillFail = [1]
        #expect(!svc.closeWindow(windowID: 1))
        #expect(!svc.closedWindowIDs.contains(1))
        #expect(svc.listWindows().count == 3)
    }

    @Test("Get window frame")
    func getFrame() {
        let svc = makeMockService()
        let frame = svc.getWindowFrame(windowID: 2)
        #expect(frame == CGRect(x: 100, y: 100, width: 1200, height: 800))
    }

    @Test("Accessibility check")
    func accessibilityCheck() {
        let svc = makeMockService()
        #expect(svc.isAccessibilityEnabled())
        svc.accessibilityEnabled = false
        #expect(!svc.isAccessibilityEnabled())
    }

    // MARK: - Integration with StageManager

    @Test("Hide windows for inactive stage, show for active")
    func stageSwitchHideShow() {
        let svc = makeMockService()
        var sm = StageManager()
        let stageA = sm.stages[0].id
        sm.createStage(name: "B", position: .below)
        let stageB = sm.stages[1].id

        sm.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false), toStageID: stageA)
        sm.addWindow(StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false), toStageID: stageA)
        sm.addWindow(StageWindow(windowID: 3, appBundleID: "com.c", appName: "C", isShared: false), toStageID: stageB)

        // Switch from B (active) to A: hide B's windows, show A's
        let previousStage = sm.stages.first(where: { $0.id == stageB })!
        let targetStage = sm.stages.first(where: { $0.id == stageA })!

        for w in previousStage.windows where !w.isShared {
            _ = svc.hideWindow(windowID: w.windowID)
        }
        for w in targetStage.windows where !w.isShared {
            _ = svc.showWindow(windowID: w.windowID)
        }

        #expect(svc.hiddenWindowIDs.contains(3))
        #expect(!svc.hiddenWindowIDs.contains(1))
        #expect(!svc.hiddenWindowIDs.contains(2))
    }

    @Test("Shared windows not hidden on stage switch")
    func sharedWindowNotHidden() {
        let svc = makeMockService()
        var sm = StageManager()
        let stageA = sm.stages[0].id
        sm.createStage(name: "B", position: .below)
        let stageB = sm.stages[1].id

        sm.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: true), toStageID: stageA)
        sm.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: true), toStageID: stageB)
        sm.addWindow(StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false), toStageID: stageA)

        let previousStage = sm.stages.first(where: { $0.id == stageA })!
        for w in previousStage.windows where !w.isShared {
            _ = svc.hideWindow(windowID: w.windowID)
        }

        #expect(svc.hiddenWindowIDs.contains(2))
        #expect(!svc.hiddenWindowIDs.contains(1))
    }
}
