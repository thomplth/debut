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

    @Test("Delete overflows apps up")
    func deleteOverflowUp() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        let secondID = sm.stages[1].id
        sm.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: secondID)
        sm.activateStage(id: secondID)
        sm.deleteStage(id: secondID)
        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].apps.count == 1)
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

    @Test("Add and move app")
    func moveApp() {
        var sm = StageManager()
        sm.createStage(name: "B", position: .below)
        let aID = sm.stages[0].id
        let bID = sm.stages[1].id
        sm.addApp(StageApp(bundleID: "com.x", name: "X"), toStageID: aID)
        sm.moveApp(bundleID: "com.x", fromStageID: aID, toStageID: bID)
        #expect(sm.stages[0].apps.isEmpty)
        #expect(sm.stages[1].apps.count == 1)
    }

    @Test("MRU: bringAppToFront")
    func mru() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: id)
        sm.addApp(StageApp(bundleID: "com.b", name: "B"), toStageID: id)
        sm.addApp(StageApp(bundleID: "com.c", name: "C"), toStageID: id)
        sm.bringAppToFront(bundleID: "com.c", inStageID: id)
        #expect(sm.stages[0].apps.map(\.bundleID) == ["com.c", "com.a", "com.b"])
    }

    @Test("Save template")
    func saveTemplate() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: id)
        sm.saveStageAsTemplate(stageID: id, templateName: "T")
        #expect(sm.templates.count == 1)
        #expect(sm.templates[0].appBundleIDs == ["com.a"])
    }

    @Test("StageManager is Codable")
    func codable() throws {
        var sm = StageManager()
        sm.createStage(name: "Coding", position: .below)
        sm.addApp(StageApp(bundleID: "com.a", name: "A"), toStageID: sm.stages[1].id)
        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(StageManager.self, from: data)
        #expect(decoded.stages.count == 2)
        #expect(decoded.stages[1].apps.count == 1)
    }
}
