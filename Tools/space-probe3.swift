// KHA-482 probe 3 — characterise SLSProcessAssignToSpace, the one call that moved a
// foreign window in probe 2.
//
// It takes a pid, not a window id, which suggests it pins the whole process the way the
// Dock's "Options > Assign To > Desktop N" does. Debut needs PER-WINDOW placement (Cmd+N
// puts a new window in the active stage while the app's other windows stay put), so the
// question that decides the architecture is: does this move every window of the process,
// and does it stick?

import AppKit
import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let rtld = UnsafeMutableRawPointer(bitPattern: -2 as Int)
private func sym<T>(_ n: String) -> T? { dlsym(rtld, n).map { unsafeBitCast($0, to: T.self) } }

let conn: (@convention(c) () -> CGSConnectionID)? = sym("CGSMainConnectionID")
let displaySpaces: (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? = sym("CGSCopyManagedDisplaySpaces")
let spacesForWindows: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?)? = sym("SLSCopySpacesForWindows")
let procAssign: (@convention(c) (CGSConnectionID, pid_t, CGSSpaceID) -> Int32)? = sym("SLSProcessAssignToSpace")

let cid = conn!()

func desktops() -> [CGSSpaceID] {
    guard let raw = displaySpaces!(cid, nil)?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return raw.flatMap { d -> [CGSSpaceID] in
        ((d["Spaces"] as? [[String: Any]]) ?? []).compactMap {
            guard ($0["type"] as? NSNumber)?.intValue ?? 0 == 0 else { return nil }
            return ($0["id64"] as? NSNumber)?.uint64Value
        }
    }
}

func spaceOf(_ w: UInt32) -> [CGSSpaceID] {
    guard let r = spacesForWindows!(cid, 7, [NSNumber(value: w)] as CFArray)?
        .takeRetainedValue() as? [NSNumber] else { return [] }
    return r.map { $0.uint64Value }
}

func finderWindows(_ pid: pid_t) -> [UInt32] {
    ((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? [])
        .filter { ($0["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid }
        .filter { (($0["kCGWindowLayer"] as? NSNumber)?.int32Value ?? -1) == 0 }
        .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
}

let all = desktops()
print("desktops: \(all)")

let pid = NSWorkspace.shared.runningApplications
    .first { $0.bundleIdentifier == "com.apple.finder" }!.processIdentifier

// Two Finder windows so we can see whether assignment is per-process or per-window.
for path in [NSHomeDirectory(), "/Applications"] {
    Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [path])
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
}

var wins = finderWindows(pid)
print("\nFinder windows: \(wins)")
for w in wins { print("  \(w) on \(spaceOf(w))") }

guard wins.count >= 2 else {
    print("need 2+ Finder windows; got \(wins.count)")
    exit(2)
}

let origin = spaceOf(wins[0]).first ?? all[0]
guard let dest = all.first(where: { $0 != origin }) else { exit(1) }

print("\n=== assign whole process -> \(dest) ===")
let rc = procAssign!(cid, pid, dest)
RunLoop.current.run(until: Date().addingTimeInterval(1.0))
print("rc=\(rc)")
for w in wins { print("  window \(w) now on \(spaceOf(w))") }

let allMoved = wins.allSatisfy { spaceOf($0) == [dest] }
let someMoved = wins.contains { spaceOf($0) == [dest] }
print(allMoved ? "=> ALL windows moved: assignment is PER-PROCESS"
      : someMoved ? "=> SOME windows moved: mixed behaviour"
      : "=> no windows moved")

// Does it stick? Open a THIRD window and see whether it is born on the assigned space.
print("\n=== does the assignment persist for new windows? ===")
Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["/Library"])
RunLoop.current.run(until: Date().addingTimeInterval(1.5))
let newWins = finderWindows(pid).filter { !wins.contains($0) }
for w in newWins { print("  NEW window \(w) born on \(spaceOf(w)) (assigned space is \(dest))") }
print(newWins.allSatisfy { spaceOf($0) == [dest] }
      ? "=> assignment PERSISTS — new windows inherit it (this is a sticky pin, not a move)"
      : "=> assignment does not bind new windows")

// Can we then place ONE window back on the origin while the rest stay?
print("\n=== per-window override after process assignment? ===")
if let moveManaged: (@convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void) =
    sym("SLSMoveWindowsToManagedSpace"), let first = wins.first {
    moveManaged(cid, [NSNumber(value: first)] as CFArray, origin)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    print("  window \(first) after per-window move back to \(origin): \(spaceOf(first))")
    print(spaceOf(first) == [origin]
          ? "=> per-window override WORKS"
          : "=> per-window override still blocked — only whole-process granularity available")
}

// Restore: unpin by assigning back to the origin space.
print("\n=== restoring ===")
_ = procAssign!(cid, pid, origin)
RunLoop.current.run(until: Date().addingTimeInterval(0.8))
wins = finderWindows(pid)
for w in wins { print("  window \(w) on \(spaceOf(w))") }
print("\nNOTE: Finder may remain pinned to a desktop. Clear via Dock > Finder > Options > Assign To > None.")
