import Testing
@testable import DebutCore

/// Icon retention follows the apps that own a live window (KHA-1105). Most of the app delegate's
/// discovery paths mutate the model in place without telling the controller's delegate — an app
/// quitting among them — so the owners are published from the model itself.
@Suite("Window owner publishing")
struct WindowOwnerPublishingTests {
    private func makeController() -> SpaceController {
        SpaceController(
            windowService: MockWindowService(),
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused }
        )
    }

    @Test("Owners are published on subscription and whenever a direct mutation changes them")
    func publishesOwnerChanges() {
        let controller = makeController()
        let spaceID = controller.spaceManager.activeSpaceID
        var published: [Set<String>] = []
        controller.onWindowOwnersChanged = { published.append($0) }
        #expect(published == [[]])

        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 1, ownerBundleID: "com.a", ownerName: "A", windowTitle: "One", ownerPID: 10),
            toSpaceID: spaceID
        )
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 2, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Two", ownerPID: 20),
            toSpaceID: spaceID
        )
        // A second window of an app that already owns one changes nothing worth publishing.
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 3, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Three", ownerPID: 20),
            toSpaceID: spaceID
        )
        _ = controller.spaceManager.makeWindowsDormant(forOwnerPID: 20)

        #expect(published == [[], ["com.a"], ["com.a", "com.b"], ["com.a"]])
    }
}
