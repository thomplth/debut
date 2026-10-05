import Foundation

/// A behavioral group owns its setup, fixtures, input, assertions and cleanup, so it can run on
/// its own from a fresh guest or in any order. First-use permission journeys and the glass
/// gallery run from the guest script as separate invocations, so they are not suite groups.
enum E2EGroup: String, CaseIterable, Sendable {
    case smoke
    case overlayInput = "overlay-input"
    case dragDrop = "drag-drop"
    case desktopNavigation = "desktop-navigation"
    case fullscreen
    case windowMoves = "window-moves"
    case windowLifecycle = "window-lifecycle"
    case onboarding
    case rendering
}

/// Whether Debut must already be running when a scenario starts, or must not be because the
/// scenario launches it itself with its own settings or arguments. Launching an app that is
/// already running only reactivates it, so a scenario handed a running Debut would silently test
/// the wrong configuration.
enum DebutPrecondition: Sendable {
    case running
    case stopped
}

struct E2EScenarioDescriptor: Sendable {
    let id: String
    let group: E2EGroup
    let debut: DebutPrecondition
    let summary: String
}

/// Every scenario in the legacy full order. A group selection runs its scenarios in this order,
/// and the suite refuses to start if a scenario here has no body or a body has no entry here.
let e2eScenarioCatalog: [E2EScenarioDescriptor] = [
    .init(id: "baseline", group: .smoke, debut: .running,
          summary: "Debut is running, discovers the fixture windows and matches the desktop list"),
    .init(id: "system-overviews", group: .desktopNavigation, debut: .running,
          summary: "Spaces survive Mission Control and App Exposé"),
    .init(id: "space-switch", group: .desktopNavigation, debut: .running,
          summary: "Quick switches move the desktop macOS shows, including bursts"),
    .init(id: "overlay-keyboard", group: .overlayInput, debut: .running,
          summary: "Open, navigate, close, hold and commit the overlay from the keyboard"),
    .init(id: "overlay-pointer", group: .overlayInput, debut: .running,
          summary: "Pointer hover selects only after movement, and Command release commits it"),
    .init(id: "window-drop", group: .dragDrop, debut: .running,
          summary: "Dropping a window refreshes both stages and supports an immediate reverse drag"),
    .init(id: "overlay-keyboard-move", group: .windowMoves, debut: .running,
          summary: "Moving a window to another space from the overlay keyboard"),
    .init(id: "overlay-fullscreen", group: .fullscreen, debut: .running,
          summary: "The overlay opens over and commits from a fullscreen Space"),
    .init(id: "custom-activation", group: .overlayInput, debut: .running,
          summary: "A persisted custom shortcut replaces Command-Tab"),
    .init(id: "held-key-across-overlay", group: .overlayInput, debut: .running,
          summary: "A key released while the overlay is open still types afterwards"),
    .init(id: "navigation-controls", group: .desktopNavigation, debut: .stopped,
          summary: "Control-arrow, swipes, bursts and Mission Control with faster switching on"),
    .init(id: "fullscreen-navigation", group: .fullscreen, debut: .stopped,
          summary: "Control-arrow and swipes leave and re-enter a fullscreen Space"),
    .init(id: "system-duration-transition", group: .desktopNavigation, debut: .stopped,
          summary: "Command-Tab uses the system transition with faster switching off"),
    .init(id: "prepared-arrival", group: .desktopNavigation, debut: .stopped,
          summary: "A faster-off switch reveals the chosen window already on top"),
    .init(id: "native-retarget", group: .desktopNavigation, debut: .stopped,
          summary: "A switch requested during a faster-off transition still lands"),
    .init(id: "onboarding-journey", group: .onboarding, debut: .stopped,
          summary: "First-launch onboarding and its guided exercises"),
    .init(id: "settings-chrome", group: .rendering, debut: .stopped,
          summary: "The settings window's chrome, and a normal relaunch after it"),
    .init(id: "selected-window-dismissal", group: .windowLifecycle, debut: .running,
          summary: "Closing the selected window from the overlay"),
    .init(id: "recycled-window-id", group: .windowLifecycle, debut: .stopped,
          summary: "A recycled window ID under a stale identity is parked, not adopted"),
    .init(id: "startup-discovery", group: .windowLifecycle, debut: .stopped,
          summary: "Startup discovers windows on every desktop"),
    .init(id: "launch-focus-and-resize", group: .windowLifecycle, debut: .running,
          summary: "Focus inside a just-launched app, and a resized window reshaping its card"),
    .init(id: "move-duration-sweep", group: .windowMoves, debut: .running,
          summary: "Command-Option arrows chain across desktops at every switch duration"),
]

enum E2EInvocation: Equatable, Sendable {
    /// `nil` for both runs every group in catalog order. Scenarios add single scenarios to any
    /// groups asked for, so a failure can be reproduced without rerunning its whole group.
    case suite(groups: [E2EGroup]?, scenarios: [String]? = nil)
    case list
    case plan(groups: [E2EGroup]?, scenarios: [String]? = nil)
}

struct E2EArgumentError: Error, Equatable {
    let message: String
}

/// Parses suite options. Returns `nil` for a subcommand, which its own handler owns. Nothing here
/// may touch the session: it runs before the harness clears screenshots or launches anything.
func parseE2EInvocation(_ arguments: [String]) -> Result<E2EInvocation, E2EArgumentError>? {
    guard let first = arguments.first else { return .success(.suite(groups: nil)) }
    guard first.hasPrefix("--"), first != "--harness-self-check" else { return nil }

    var listing = false
    var planning = false
    var groups: [E2EGroup]?
    var scenarios: [String]?
    var remaining = arguments[...]
    while let option = remaining.popFirst() {
        switch option {
        case "--list":
            listing = true
        case "--plan":
            planning = true
        case "--groups":
            guard let value = remaining.popFirst() else {
                return .failure(.init(message: "--groups needs a comma-separated list of groups"))
            }
            var selected: [E2EGroup] = []
            for name in value.split(separator: ",", omittingEmptySubsequences: true) {
                let name = name.trimmingCharacters(in: .whitespaces)
                guard let group = E2EGroup(rawValue: name) else {
                    return .failure(.init(message: "Unknown group '\(name)'. Known groups: "
                        + E2EGroup.allCases.map(\.rawValue).joined(separator: ", ")))
                }
                if !selected.contains(group) { selected.append(group) }
            }
            guard !selected.isEmpty else {
                return .failure(.init(message: "--groups selects nothing"))
            }
            groups = selected
        case "--scenarios":
            guard let value = remaining.popFirst() else {
                return .failure(.init(message: "--scenarios needs a comma-separated list of scenario IDs"))
            }
            var selected: [String] = []
            for name in value.split(separator: ",", omittingEmptySubsequences: true) {
                let name = name.trimmingCharacters(in: .whitespaces)
                guard e2eScenarioCatalog.contains(where: { $0.id == name }) else {
                    return .failure(.init(message: "Unknown scenario '\(name)'. Run --list for the catalog."))
                }
                if !selected.contains(name) { selected.append(name) }
            }
            guard !selected.isEmpty else {
                return .failure(.init(message: "--scenarios selects nothing"))
            }
            scenarios = selected
        default:
            return .failure(.init(message: "Unknown option '\(option)'. "
                + "Use --list, --plan, --groups <group,...> or --scenarios <id,...>"))
        }
    }
    if listing {
        guard !planning, groups == nil, scenarios == nil else {
            return .failure(.init(message: "--list takes no other options"))
        }
        return .success(.list)
    }
    return .success(planning
        ? .plan(groups: groups, scenarios: scenarios)
        : .suite(groups: groups, scenarios: scenarios))
}

/// The scenarios a selection runs, in run order: groups in the order asked for, and each group's
/// scenarios in catalog order. Selected scenarios join them; with scenarios in the mix, the
/// whole selection runs in catalog order, so each still gets its usual predecessor's setup.
func plannedScenarios(groups: [E2EGroup]?, scenarios: [String]? = nil) -> [E2EScenarioDescriptor] {
    guard let scenarios else {
        guard let groups else { return e2eScenarioCatalog }
        return groups.flatMap { group in e2eScenarioCatalog.filter { $0.group == group } }
    }
    let selectedGroups = Set(groups ?? [])
    return e2eScenarioCatalog.filter {
        scenarios.contains($0.id) || selectedGroups.contains($0.group)
    }
}

func printScenarioCatalog() {
    for group in E2EGroup.allCases {
        print(group.rawValue)
        for scenario in e2eScenarioCatalog where scenario.group == group {
            print("  \(scenario.id): \(scenario.summary)")
        }
    }
}

func printScenarioPlan(groups: [E2EGroup]?, scenarios: [String]? = nil) {
    let planned = plannedScenarios(groups: groups, scenarios: scenarios)
    print("Runs \(planned.count) of \(e2eScenarioCatalog.count) scenarios:")
    for scenario in planned {
        print("  \(scenario.group.rawValue)/\(scenario.id)")
    }
    let skipped = e2eScenarioCatalog.filter { candidate in
        !planned.contains { $0.id == candidate.id }
    }
    if !skipped.isEmpty {
        print("Not selected: " + skipped.map { "\($0.group.rawValue)/\($0.id)" }.joined(separator: ", "))
    }
}
