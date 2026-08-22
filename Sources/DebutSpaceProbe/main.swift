// Exercises SpaceService's desktop switching against the live window server: every desktop in
// turn, each hop verified against what the window server reports afterwards.

import AppKit
import DebutCore

func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

guard AXIsProcessTrusted() else { print("FATAL: needs Accessibility"); exit(1) }

let service = SpaceService()
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
