// Exercises SpaceService's desktop switching against the live window server: every desktop in
// turn, each hop verified against what the window server reports afterwards.

import AppKit
import DebutCore

func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

guard AXIsProcessTrusted() else { print("FATAL: needs Accessibility"); exit(1) }

let service = SpaceService()
let arguments = Array(CommandLine.arguments.dropFirst())

// `goto <n>` parks on one desktop so the window-detection cases — launching an app on a
// given desktop, dragging one across — can be set up and then inspected.
if arguments.first == "goto", let target = arguments.dropFirst().first.flatMap(Int.init) {
    guard service.switchToDesktop(index: target - 1) else {
        print("FATAL: refused to switch to desktop \(target)"); exit(1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    print("now on desktop \(service.currentDesktopIndex().map { $0 + 1 } ?? -1)")
    exit(0)
}

// `windows` dumps what macOS says about every window's desktop. Run it from two different
// desktops and diff: an answer that changes with the desktop showing is the window server
// reporting the view rather than the window, which the whole detection scheme rests on not
// happening.
if arguments.first == "windows" {
    let discovery = AccessibilityWindowService()
    let windows = discovery.listWindows()
    let desktops = service.desktopIndexes(forWindows: windows.map(\.windowID))
    print("showing desktop \(service.currentDesktopIndex().map { $0 + 1 } ?? -1)")
    for window in windows.sorted(by: { $0.windowID < $1.windowID }) {
        let desktop = desktops[window.windowID].map { "\($0 + 1)" } ?? "none"
        print("\(window.windowID)\t\(desktop)\t\(window.ownerName)\t\(window.title)")
    }
    exit(0)
}

// The switch-speed setting is only observable against the live Dock: a unit test can assert
// which velocity was posted, but not whether the Dock snapped or slid at that velocity.
if let velocity = arguments.first.flatMap(Double.init) {
    service.switchVelocity = velocity
}
print("switch velocity: \(service.switchVelocity)")
let desktops = service.userDesktops()
print("desktops in order: \(desktops)")
guard desktops.count >= 2 else { print("FATAL: need 2+ desktops"); exit(1) }
guard service.canSwitchSpaces else {
    print("FATAL: this macOS version rejects synthetic dock swipes"); exit(1)
}
guard let origin = service.currentDesktopIndex() else {
    print("FATAL: cannot read the current desktop"); exit(1)
}
print("starting on desktop \(origin + 1)")

var failures: [String] = []

// The switch is a forged gesture the Dock consumes asynchronously, so the desktop has to be
// re-read until it settles rather than once.
@MainActor func settle(on target: Int) -> Bool {
    for _ in 0..<40 {
        if service.currentDesktopIndex() == target { return true }
        pause(0.05)
    }
    return false
}

@MainActor func hop(to target: Int) {
    let started = Date()
    guard service.switchToDesktop(index: target) else {
        failures.append("desktop \(target + 1): switchToDesktop refused")
        print("  desktop \(target + 1): REFUSED")
        return
    }
    let landed = settle(on: target)
    let ms = Date().timeIntervalSince(started) * 1000
    let reported = service.currentDesktopIndex().map { $0 + 1 }
    print("  desktop \(target + 1): \(landed ? "ok" : "landed on \(String(describing: reported))")"
        + "   \(String(format: "%.0f", ms))ms")
    if !landed {
        failures.append("desktop \(target + 1): landed on \(String(describing: reported))")
    }
}

for target in desktops.indices where target != origin {
    hop(to: target)
}

hop(to: origin)

if failures.isEmpty {
    print("RESULT: PASS — \(desktops.count) desktops, every switch landed where it asked.")
} else {
    print("RESULT: FAIL — \(failures.joined(separator: "; "))")
}
