import Foundation
import Testing
@testable import DebutDemo

/// README, onboarding and site media share one nine-window fixture (KHA-1119).
struct CaptureFixtureTests {
    @Test func fixtureMatchesTheSiteArrangement() {
        #expect(captureFixture == [
            [.init("com.apple.Safari", "Field Notes"), .init("com.apple.Terminal", "Research"),
             .init("com.apple.Notes", "Reading list")],
            [.init("com.apple.Safari", "Weekend Guide"), .init("com.apple.weather", "Cupertino"),
             .init("com.apple.stocks")],
            [.init("com.apple.Notes", "Project notes"), .init("com.apple.Chess"),
             .init("com.apple.Terminal", "Project")],
        ])
    }

    @Test func everyFixtureTitleIdentifiesOneWindow() {
        let windows = captureFixture.flatMap { $0 }
        for window in windows {
            // The scene matches the same way: an untitled entry takes the app's only window.
            let matches = windows.filter {
                $0.bundle == window.bundle && (window.title.isEmpty || $0.title.contains(window.title))
            }
            #expect(matches == [window], "\(window) also matches \(matches)")
        }
    }
}

/// Control-arrow switches go straight through SpaceService and report no `space_switched`, so
/// the speed comparison counts the adjacent-switch key events Debut actually handled.
struct DemoSwitchCountTests {
    @Test func countsDistinctHandledAdjacentSwitches() throws {
        let snapshot = """
        {"events": [
          {"event": "key_event", "keyEvent": "switchAdjacentSpace(1)", "uptimeNanoseconds": "10"},
          {"event": "key_event", "keyEvent": "switchAdjacentSpace(-1)", "uptimeNanoseconds": "20"},
          {"event": "key_event", "keyEvent": "cmdTabHold", "uptimeNanoseconds": "30"},
          {"event": "space_switched", "from": "1", "to": "2", "uptimeNanoseconds": "40"}
        ]}
        """
        #expect(handledAdjacentSwitches(in: Data(snapshot.utf8)) == ["10", "20"])
        #expect(handledAdjacentSwitches(in: Data("not json".utf8)).isEmpty)
    }
}
