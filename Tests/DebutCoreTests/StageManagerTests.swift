import Testing
import Foundation
@testable import DebutCore

@Suite("StageManager")
struct StageManagerTests {

    // MARK: - Initialization

    @Test("Starts with one default stage")
    func defaultState() {
        let sm = StageManager()
        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].name == "Stage 1")
        #expect(sm.activeStageID == sm.stages[0].id)
    }

    // MARK: - Create stages

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
        #expect(sm.activeStageID == sm.stages[0].id)
    }

    @Test("Create stage auto-names with prefix")
    func autoName() {
        var sm = StageManager()
        sm.createStage(position: .below)
        #expect(sm.stages[1].name == "Stage 2")
        sm.createStage(position: .below)
        #expect(sm.stages[2].name == "Stage 3")
    }

    // MARK: - Delete stages

    @Test("Delete non-first stage overflows windows up")
    func deleteOverflowUp() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        let secondID = sm.stages[1].id
        let window = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        sm.addWindow(window, toStageID: secondID)
        sm.activateStage(id: secondID)

        sm.deleteStage(id: secondID)

        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].windows.count == 1)
        #expect(sm.stages[0].windows[0].windowID == 1)
    }

    @Test("Delete first stage overflows windows down")
    func deleteOverflowDown() {
        var sm = StageManager()
        let firstID = sm.stages[0].id
        let window = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        sm.addWindow(window, toStageID: firstID)
        sm.createStage(name: "Second", position: .below)

        sm.deleteStage(id: firstID)

        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].name == "Second")
        #expect(sm.stages[0].windows.count == 1)
    }

    @Test("Delete last remaining stage creates new default")
    func deleteLastStage() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.deleteStage(id: id)
        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].name == "Stage 1")
        #expect(sm.activeStageID == sm.stages[0].id)
    }

    // MARK: - Rename

    @Test("Rename stage")
    func rename() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.renameStage(id: id, to: "Coding")
        #expect(sm.stages[0].name == "Coding")
    }

    // MARK: - Reorder

    @Test("Swap stage with neighbor above")
    func swapUp() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        sm.createStage(name: "Third", position: .below)
        let thirdID = sm.stages[2].id
        sm.swapStage(id: thirdID, direction: .up)
        #expect(sm.stages[1].name == "Third")
        #expect(sm.stages[2].name == "Second")
    }

    @Test("Swap stage with neighbor below")
    func swapDown() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        let firstID = sm.stages[0].id
        sm.activateStage(id: firstID)
        sm.swapStage(id: firstID, direction: .down)
        #expect(sm.stages[0].name == "Second")
        #expect(sm.stages[1].name == "Stage 1")
    }

    @Test("Swap at boundary is no-op")
    func swapBoundary() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.swapStage(id: id, direction: .up)
        #expect(sm.stages.count == 1)
    }

    // MARK: - Window management

    @Test("Add window to stage")
    func addWindow() {
        var sm = StageManager()
        let id = sm.stages[0].id
        let w = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        sm.addWindow(w, toStageID: id)
        #expect(sm.stages[0].windows.count == 1)
    }

    @Test("Move window between stages")
    func moveWindow() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        let firstID = sm.stages[0].id
        let secondID = sm.stages[1].id
        let w = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        sm.addWindow(w, toStageID: firstID)

        sm.moveWindow(windowID: 1, fromStageID: firstID, toStageID: secondID)

        #expect(sm.stages[0].windows.isEmpty)
        #expect(sm.stages[1].windows.count == 1)
    }

    @Test("Remove window from stage")
    func removeWindow() {
        var sm = StageManager()
        let id = sm.stages[0].id
        let w = StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false)
        sm.addWindow(w, toStageID: id)
        sm.removeWindow(windowID: 1, fromStageID: id)
        #expect(sm.stages[0].windows.isEmpty)
    }

    // MARK: - Active stage

    @Test("Activate specific stage")
    func activateStage() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        let firstID = sm.stages[0].id
        sm.activateStage(id: firstID)
        #expect(sm.activeStageID == firstID)
    }

    @Test("Active stage property returns correct stage")
    func activeStageProperty() {
        let sm = StageManager()
        #expect(sm.activeStage.name == "Stage 1")
    }

    // MARK: - Stage index

    @Test("Stage at index")
    func stageAtIndex() {
        var sm = StageManager()
        sm.createStage(name: "Second", position: .below)
        #expect(sm.stage(atIndex: 0)?.name == "Stage 1")
        #expect(sm.stage(atIndex: 1)?.name == "Second")
        #expect(sm.stage(atIndex: 2) == nil)
    }

    // MARK: - MRU tracking

    @Test("MRU order updates on app focus")
    func mruTracking() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false), toStageID: id)
        sm.addWindow(StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false), toStageID: id)
        sm.addWindow(StageWindow(windowID: 3, appBundleID: "com.c", appName: "C", isShared: false), toStageID: id)

        sm.recordWindowFocus(windowID: 3, inStageID: id)
        sm.recordWindowFocus(windowID: 1, inStageID: id)

        let mru = sm.mruWindowIDs(forStageID: id)
        #expect(mru == [1, 3, 2])
    }

    // MARK: - Template operations

    @Test("Save stage as template")
    func saveTemplate() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false), toStageID: id)
        sm.addWindow(StageWindow(windowID: 2, appBundleID: "com.b", appName: "B", isShared: false), toStageID: id)

        sm.saveStageAsTemplate(stageID: id, templateName: "My Template")

        #expect(sm.templates.count == 1)
        #expect(sm.templates[0].name == "My Template")
        #expect(sm.templates[0].appBundleIDs.sorted() == ["com.a", "com.b"])
    }

    @Test("Delete template")
    func deleteTemplate() {
        var sm = StageManager()
        sm.saveStageAsTemplate(stageID: sm.stages[0].id, templateName: "T")
        let templateID = sm.templates[0].id
        sm.deleteTemplate(id: templateID)
        #expect(sm.templates.isEmpty)
    }

    // MARK: - Codable round-trip

    @Test("StageManager is Codable")
    func codableRoundTrip() throws {
        var sm = StageManager()
        sm.createStage(name: "Coding", position: .below)
        sm.addWindow(
            StageWindow(windowID: 1, appBundleID: "com.a", appName: "A", isShared: false),
            toStageID: sm.stages[1].id
        )
        sm.saveStageAsTemplate(stageID: sm.stages[1].id, templateName: "Coding Template")

        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(StageManager.self, from: data)

        #expect(decoded.stages.count == 2)
        #expect(decoded.stages[1].name == "Coding")
        #expect(decoded.stages[1].windows.count == 1)
        #expect(decoded.templates.count == 1)
        #expect(decoded.activeStageID == sm.activeStageID)
    }
}
