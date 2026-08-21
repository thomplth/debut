// KHA-482 probe 9 — does the *shipped* move path work, at the timings it actually uses?
//
// Probe 6 proved the technique with generous 1.4s settles. SpaceService trimmed those to keep a
// stage assignment from feeling frozen, and a drag that releases before the desktop transition
// finishes drops the window on the wrong desktop. Probes 1-8 each re-implemented the sequence,
// so none of them could catch that: this one links DebutCore and drives SpaceService itself.

import AppKit
import DebutCore

func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

guard AXIsProcessTrusted() else { print("FATAL: needs Accessibility"); exit(1) }

let service = SpaceService()
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

guard let info,
      let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let bd = info["kCGWindowBounds"] as? [String: Any],
      let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary) else {
    print("FATAL: no TextEdit window"); exit(1)
}

guard let origin = service.desktopIndex(forWindow: wid) else {
    print("FATAL: window \(wid) is on \(service.spaces(forWindow: wid)), need exactly one desktop"); exit(1)
}

// Farthest target, so a pass cannot be a single incidental step.
let target = origin == desktops.count - 1 ? 0 : desktops.count - 1
let grab = CGPoint(x: bounds.midX, y: bounds.minY + 12)
print("window \(wid): desktop \(origin + 1) -> desktop \(target + 1) (\(abs(target - origin)) away)")

let started = Date()
let done = DispatchSemaphore(value: 0)
nonisolated(unsafe) var moved = false
service.moveWindow(windowID: wid, titleBar: grab, toDesktop: target) { result in
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

// Put the window back so the probe leaves nothing behind.
if moved {
    let back = DispatchSemaphore(value: 0)
    service.switchToDesktop(index: target)
    pause(0.8)
    service.moveWindow(windowID: wid, titleBar: grab, toDesktop: origin) { _ in back.signal() }
    while back.wait(timeout: .now() + 0.05) == .timedOut { pause(0.05) }
    service.switchToDesktop(index: origin)
    pause(0.6)
}
app.terminate()
try? FileManager.default.removeItem(atPath: doc)
print("current desktop index: \(String(describing: service.currentDesktopIndex()))")
