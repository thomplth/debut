import Testing
import Foundation
@testable import DebutCore

@Suite("StageManager")
struct StageManagerTests {

    @Test("Starts with one default stage")
    func defaultState() {
        let sm = StageManager()
        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].name == "Stage 1")
        #expect(sm.activeStageID == sm.stages[0].id)
    }

    @Test("Create stage below active")
    func createBelow() {
        var sm = StageManager()
        let originalID = sm.activeStageID
        sm.createStage(name: "New", position: .below)
        #expect(sm.stages.count == 2)
        #expect(sm.stages[0].id == originalID)
        #expect(sm.stages[1].name == "New")
        #expect(sm.activeStageID == sm.stages[1].id)
    }

    @Test("Create stage above active")
    func createAbove() {
        var sm = StageManager()
        let originalID = sm.activeStageID
        sm.createStage(name: "New", position: .above)
        #expect(sm.stages.count == 2)
        #expect(sm.stages[0].name == "New")
        #expect(sm.stages[1].id == originalID)
    }

    @Test("Auto-name stages")
    func autoName() {
        var sm = StageManager()
        sm.createStage(position: .below)
        #expect(sm.stages[1].name == "Stage 2")
    }

    @Test("Delete overflows windows up")
    func deleteOverflowUp() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
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
        #expect(sm.stages[0].name == "Stage 1")
    }

    @Test("Rename stage")
    func rename() {
        var sm = StageManager()
        sm.renameStage(id: sm.stages[0].id, to: "Coding")
        #expect(sm.stages[0].name == "Coding")
    }

    @Test("Swap stages")
    func swap() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        let secondID = sm.stages[1].id
        sm.swapStage(id: secondID, direction: .up)
        #expect(sm.stages[0].name == "Second")
    }

    @Test("Add and move window")
    func moveWindow() {
        var sm = StageManager()
        sm.createStage(name: "B", position: .below)
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

    @Test("StageManager is Codable")
    func codable() throws {
        var sm = StageManager()
        sm.createStage(name: "Coding", position: .below)
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: sm.stages[1].id)
        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(StageManager.self, from: data)
        #expect(decoded.stages.count == 2)
        #expect(decoded.stages[1].windows.count == 1)
    }
}
