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

    @Test("Move a stage to a drag destination")
    func moveStage() {
        var sm = StageManager()
        let firstID = sm.stages[0].id
        sm.createStage(position: .below)
        let secondID = sm.stages[1].id
        sm.createStage(position: .below)
        let thirdID = sm.stages[2].id

        sm.moveStage(fromIndex: 0, toIndex: 2)
        #expect(sm.stages.map(\.id) == [secondID, thirdID, firstID])
        #expect(sm.activeStageID == thirdID)

        sm.moveStage(fromIndex: 2, toIndex: 0)
        #expect(sm.stages.map(\.id) == [firstID, secondID, thirdID])
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

    @Test("stageContainingWindow")
    func stageContaining() {
        var sm = StageManager()
        let id = sm.stages[0].id
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"), toStageID: id)
        #expect(sm.stageContainingWindow(windowID: 101) == id)
        #expect(sm.stageContainingWindow(windowID: 999) == nil)
    }

    @Test("Resetting the window cache removes live and dormant assignments")
    func resetWindowCache() {
        var sm = StageManager()
        let firstStageID = sm.activeStageID
        sm.addWindow(
            StageWindow(
                windowID: 101,
                ownerBundleID: "com.ghost",
                ownerName: "Ghost",
                windowTitle: "Stale",
                ownerPID: 10
            ),
            toStageID: firstStageID
        )
        _ = sm.makeWindowsDormant(forOwnerPID: 10)
        sm.createStage(position: .below)
        sm.addWindow(
            StageWindow(
                windowID: 202,
                ownerBundleID: "com.live",
                ownerName: "Live",
                windowTitle: "Current",
                ownerPID: 20
            ),
            toStageID: sm.activeStageID
        )

        sm.resetWindowCache()

        #expect(sm.stages.count == 1)
        #expect(sm.stages[0].windows.isEmpty)
        #expect(sm.activeStageID == sm.stages[0].id)
        #expect(sm.dormantWindowAssignments.isEmpty)
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

    @Test("App termination makes windows dormant with their stage positions")
    func makeWindowsDormantPreservesAssignments() {
        var sm = StageManager()
        let stage1 = sm.activeStageID
        sm.createStage(position: .below)
        let stage2 = sm.activeStageID
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toStageID: stage1)
        sm.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Two", ownerPID: 10), toStageID: stage2)
        sm.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Other", ownerPID: 20), toStageID: stage2)

        let count = sm.makeWindowsDormant(forOwnerPID: 10)

        #expect(count == 2)
        #expect(sm.stages.flatMap(\.windows).map(\.windowID) == [201])
        #expect(sm.dormantWindowAssignments.map(\.stageID) == [stage1, stage2])
        #expect(sm.dormantWindowAssignments.map(\.windowIndex) == [0, 0])
        #expect(sm.dormantWindowAssignments.map(\.window.windowID) == [101, 102])
    }

    @Test("A single window can be made dormant without disturbing its neighbours")
    func makeWindowDormantPreservesPlacement() {
        var sm = StageManager()
        let stage1 = sm.activeStageID
        sm.createStage(position: .below)
        let stage2 = sm.activeStageID
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toStageID: stage2)
        sm.addWindow(StageWindow(windowID: 102, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Two", ownerPID: 10), toStageID: stage2)
        sm.addWindow(StageWindow(windowID: 103, ownerBundleID: "com.a", ownerName: "A", windowTitle: "Three", ownerPID: 10), toStageID: stage2)

        let assignment = sm.makeWindowDormant(windowID: 102)

        #expect(assignment?.stageID == stage2)
        #expect(assignment?.windowIndex == 1)
        #expect(sm.stages.first(where: { $0.id == stage2 })?.windows.map(\.windowID) == [101, 103])
        #expect(sm.dormantWindowAssignments.map(\.window.windowID) == [102])
        #expect(sm.makeWindowDormant(windowID: 999) == nil)
        #expect(sm.stages.first(where: { $0.id == stage1 })?.windows.isEmpty == true)
    }

    @Test("Dormant assignments survive persistence and legacy state still decodes")
    func dormantAssignmentsAreCodableAndForwardCompatible() throws {
        var sm = StageManager()
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toStageID: sm.activeStageID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        let data = try JSONEncoder().encode(sm)
        let decoded = try JSONDecoder().decode(StageManager.self, from: data)
        #expect(decoded.dormantWindowAssignments.count == 1)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "dormantWindowAssignments")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(StageManager.self, from: legacyData)
        #expect(legacyDecoded.dormantWindowAssignments.isEmpty)
    }

    @Test("Explicit removal purges a dormant assignment")
    func explicitRemovalPurgesDormantAssignment() {
        var sm = StageManager()
        let stageID = sm.activeStageID
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        sm.removeWindow(windowID: 101, fromStageID: stageID)

        #expect(sm.dormantWindowAssignments.isEmpty)
    }

    @Test("Excluding a bundle purges its dormant assignments")
    func bundleRemovalPurgesDormantAssignments() {
        var sm = StageManager()
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toStageID: sm.activeStageID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        sm.removeAllWindows(forBundleID: "com.a")

        #expect(sm.dormantWindowAssignments.isEmpty)
    }

    @Test("Deleting a stage purges its dormant assignments")
    func stageDeletionPurgesDormantAssignments() {
        var sm = StageManager()
        let stageID = sm.activeStageID
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toStageID: stageID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)

        sm.deleteStage(id: stageID)

        #expect(sm.dormantWindowAssignments.isEmpty)
    }

    @Test("Automatic empty-stage pruning retains stages with dormant assignments")
    func emptyStagePruningRetainsDormantAssignments() {
        var sm = StageManager()
        let dormantStageID = sm.activeStageID
        sm.addWindow(StageWindow(windowID: 101, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10), toStageID: dormantStageID)
        _ = sm.makeWindowsDormant(forOwnerPID: 10)
        sm.createStage(position: .below)
        sm.addWindow(StageWindow(windowID: 201, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Live", ownerPID: 20), toStageID: sm.activeStageID)

        sm.removeEmptyStages()

        #expect(sm.stages.contains(where: { $0.id == dormantStageID }))
        #expect(sm.dormantWindowAssignments.first?.stageID == dormantStageID)
    }
}
