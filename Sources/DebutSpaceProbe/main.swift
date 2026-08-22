// Does the *shipped* move path work against a real foreign app window?
//
// The unit tests move a window this process owns, which the window server would allow through
// several APIs that silently refuse foreign windows. This probe links DebutCore and drives
// SpaceService against TextEdit, so a pass means the ownership gate was actually cleared.

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
    // Timed because whether this read can sit on the overlay's activation path is a latency
    // question, and KHA-481 was an XPC call that looked free until it was measured.
    let started = Date()
    let desktops = service.desktopIndexes(forWindows: windows.map(\.windowID))
    let elapsed = Date().timeIntervalSince(started) * 1000
    print("showing desktop \(service.currentDesktopIndex().map { $0 + 1 } ?? -1)")
    print(String(format: "desktop read: %d windows in %.1fms", windows.count, elapsed))
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

let doc = "/tmp/kha482-probe9.txt"
try? "KHA-482 shipped-path probe".write(toFile: doc, atomically: true, encoding: .utf8)
Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-a", "TextEdit", doc])
pause(2.5)

guard let app = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else { print("FATAL: no TextEdit"); exit(1) }
app.activate()
pause(0.6)

let info = ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? [])
    .filter { ($0["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == app.processIdentifier }
    .filter { (($0["kCGWindowLayer"] as? NSNumber)?.int32Value ?? -1) == 0 }
    .first

guard let info, let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
    print("FATAL: no TextEdit window"); exit(1)
}

guard let origin = service.desktopIndex(forWindow: wid) else {
    print("FATAL: window \(wid) is on \(service.spaces(forWindow: wid)), need exactly one desktop"); exit(1)
}

// Farthest target, so a pass cannot be a single incidental step.
let target = origin == desktops.count - 1 ? 0 : desktops.count - 1
print("window \(wid): desktop \(origin + 1) -> desktop \(target + 1) (\(abs(target - origin)) away)")

let started = Date()
let done = DispatchSemaphore(value: 0)
nonisolated(unsafe) var moved = false
service.moveWindow(windowID: wid, toDesktop: target) { result in
    moved = result
    done.signal()
}
while done.wait(timeout: .now() + 0.05) == .timedOut { pause(0.05) }
let elapsed = Date().timeIntervalSince(started)

print("SpaceService.moveWindow -> \(moved)   (\(String(format: "%.2f", elapsed))s)")
print("window now on desktop index: \(String(describing: service.desktopIndex(forWindow: wid)))")

if moved {
    print("RESULT: shipped move path works at its own timings.")
} else {
    print("RESULT: shipped move path FAILED — timings or bindings are wrong.")
}

// Put the window back so the probe leaves nothing behind. No desktop switch either way —
// the move is a reassignment, so the probe never leaves the desktop it started on.
if moved {
    let back = DispatchSemaphore(value: 0)
    service.moveWindow(windowID: wid, toDesktop: origin) { _ in back.signal() }
    while back.wait(timeout: .now() + 0.05) == .timedOut { pause(0.05) }
}
app.terminate()
try? FileManager.default.removeItem(atPath: doc)
print("current desktop index: \(String(describing: service.currentDesktopIndex()))")
