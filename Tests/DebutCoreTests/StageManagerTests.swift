import Testing
import Foundation
@testable import DebutCore

@Suite("StageManager")
struct StageManagerTests {

    @Test("Starts with one default stage")
    func defaultState() {
        let sm = StageManager()
        #expect(sm.stages.count == 1)
        #expect(sm.activeStageID == sm.stages[0].id)
    }

    @Test("Create stage below active")
    func createBelow() {
        var sm = StageManager()
        let originalID = sm.activeStageID
        sm.createStage(position: .below)
        #expect(sm.stages.count == 2)
        #expect(sm.stages[0].id == originalID)
        #expect(sm.activeStageID == sm.stages[1].id)
    }

    @Test("Create stage above active")
    func createAbove() {
        var sm = StageManager()
        let originalID = sm.activeStageID
        sm.createStage(position: .above)
        #expect(sm.stages.count == 2)
        #expect(sm.stages[1].id == originalID)
    }

    @Test("Delete overflows windows up")
    func deleteOverflowUp() {
        var sm = StageManager()
        sm.createStage(position: .below)
        let secondID = sm.stages[1].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: secondID)
        sm.activateStage(id: secondID)
        sm.deleteStage(id: secondID)
        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].windows.count == 1)
    }

    @Test("Delete last stage creates new default")
    func deleteLastStage() {
        var sm = StageManager()
        sm.deleteStage(id: sm.stages[0].id)
        #expect(sm.stages.count == 1)
    }

    @Test("Swap stages")
    func swap() {
        var sm = StageManager()
        sm.createStage(position: .below)
        let secondID = sm.stages[1].id
        sm.swapStage(id: secondID, direction: .up)
        #expect(sm.stages[0].id == secondID)
    }

    @Test("Add and move window")
    func moveWindow() {
        var sm = StageManager()
        sm.createStage(position: .below)
        let aID = sm.stages[0].id
        let bID = sm.stages[1].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.x", ownerName: "X", windowTitle: "T"), toStageID: aID)
        sm.moveWindow(windowID: 101, fromStageID: aID, toStageID: bID)
        #expect(sm.stages[0].windows.isEmpty)
        #expect(sm.stages[1].windows.count == 1)
    }

    @Test("MRU: bringWindowToFront")
    func mru() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: id)
        sm.addWindow(StageWindow(windowID: 202, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T2"), toStageID: id)
        sm.addWindow(StageWindow(windowID: 303, ownerBundleID: "com.c", ownerName: "C", windowTitle: "T3"), toStageID: id)
        sm.bringWindowToFront(windowID: 303, inStageID: id)
        #expect(sm.stages[0].windows.map(\.windowID) == [303, 101, 202])
    }

    @Test("Remove all windows for bundle ID")
    func removeAllForBundle() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1"), toStageID: id)
        sm.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2"), toStageID: id)
        sm.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3"), toStageID: id)
        sm.removeAllWindows(forBundleID: "com.a")
        #expect(sm.stages[0].windows.count == 1)
        #expect(sm.stages[0].windows[0].ownerBundleID == "com.b")
    }

    @Test("Remove windows for owner PID across stages")
    func removeAllForOwnerPIDAcrossStages() {
        var sm = StageManager()
        sm.createStage(position: .below)
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T1", ownerPID: 10), toStageID: sm.stages[0].id)
        sm.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T2", ownerPID: 10), toStageID: sm.stages[1].id)
        sm.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "T3", ownerPID: 20), toStageID: sm.stages[1].id)

        let removedCount = sm.removeAllWindows(forOwnerPID: 10)

        #expect(removedCount == 2)
        #expect(sm.stages.flatMap(\.windows).map(\.windowID) == [201])
    }

    @Test("Sweep removes stopped owner PIDs across stages")
    func removeStoppedProcessesAcrossStages() {
        var sm = StageManager()
        sm.createStage(position: .below)
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Live", ownerPID: 10), toStageID: sm.stages[0].id)
        sm.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Stopped", ownerPID: 20), toStageID: sm.stages[1].id)

        let removedCount = sm.removeWindowsOwnedByStoppedProcesses(runningPIDs: [10])

        #expect(removedCount == 1)
        #expect(sm.stages.flatMap(\.windows).map(\.windowID) == [101])
    }

    @Test("stageContainingWindow")
    func stageContaining() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: id)
        #expect(sm.stageContainingWindow(windowID: 101) == id)
        #expect(sm.stageContainingWindow(windowID: 999) == nil)
    }

    @Test("Save template from windows")
    func saveTemplate() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: id)
        sm.saveStageAsTemplate(stageID: id, templateName: "T")
        #expect(sm.templates.count == 1)
        #expect(sm.templates[0].appBundleIDs == ["com.a"])
    }

    @Test("Remove empty stages preserves non-empty ones")
    func removeEmpty() {
        var sm = StageManager()
        sm.createStage(position: .below)
        sm.createStage(position: .below)
        // Add a window only to the middle stage (index 1)
        let bID = sm.stages[1].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: bID)
        sm.removeEmptyStages()
        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].id == bID)
        #expect(sm.activeStageID == bID)
    }

    @Test("Remove empty stages keeps all when all empty")
    func removeEmptyKeepsAll() {
        var sm = StageManager()
        sm.createStage(position: .below)
        sm.removeEmptyStages()
        #expect(sm.stages.count == 2) // all empty, keep all
    }

    @Test("Update window title")
    func updateTitle() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Old Title"), toStageID: id)
        sm.updateWindowTitle(windowID: 101, title: "New Title")
        #expect(sm.stages[0].windows[0].windowTitle == "New Title")
    }

    @Test("Update window title for nonexistent window is a no-op")
    func updateTitleNonexistent() {
        var sm = StageManager()
        sm.updateWindowTitle(windowID: 999, title: "Whatever")
        #expect(sm.stages.count == 1) // no crash, no changes
    }

    @Test("StageManager is Codable")
    func codable() throws {
        var sm = StageManager()
        sm.createStage(position: .below)
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: sm.stages[1].id)
        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(StageManager.self, from: data)
        #expect(decoded.stages.count == 2)
        #expect(decoded.stages[1].windows.count == 1)
    }
}
