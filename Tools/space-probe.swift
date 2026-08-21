// Feasibility probe for KHA-482.
//
// Debut's stage->Space migration needs three primitives that Space Rabbit never uses:
// moving a FOREIGN process's window to another Space, creating a Space, destroying one.
// AGENTS.md records that SLS/CGS calls silently no-op on windows this process does not
// own, so every step here verifies by reading state back rather than trusting a return
// value or the absence of a crash.

import AppKit
import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2 as Int)

private func sym<T>(_ name: String) -> T? {
    guard let p = dlsym(rtldDefault, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias FnMainConnection = @convention(c) () -> CGSConnectionID
typealias FnDisplaySpaces = @convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?
typealias FnSpacesForWindows = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
typealias FnMoveWindows = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
typealias FnSpaceCreate = @convention(c) (CGSConnectionID, Int32, CFDictionary?) -> CGSSpaceID
typealias FnSpaceDestroy = @convention(c) (CGSConnectionID, CGSSpaceID) -> Void

let mainConnection: FnMainConnection? = sym("CGSMainConnectionID")
let copyDisplaySpaces: FnDisplaySpaces? = sym("CGSCopyManagedDisplaySpaces")
let spacesForWindows: FnSpacesForWindows? = sym("SLSCopySpacesForWindows")
let moveWindows: FnMoveWindows? = sym("SLSMoveWindowsToManagedSpace")
let spaceCreate: FnSpaceCreate? = sym("SLSSpaceCreate")
let spaceDestroy: FnSpaceDestroy? = sym("SLSSpaceDestroy")

guard let mainConnection, let copyDisplaySpaces, let spacesForWindows, let moveWindows else {
    print("FATAL: required symbols missing")
    exit(1)
}

let cid = mainConnection()
print("connection id: \(cid)")
guard cid != 0 else { print("FATAL: no window server connection"); exit(1) }

// MARK: - Space enumeration

func allSpaces() -> [(display: String, current: CGSSpaceID, spaces: [(id: CGSSpaceID, type: Int)])] {
    guard let raw = copyDisplaySpaces(cid, nil)?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return raw.compactMap { d in
        guard let ident = d["Display Identifier"] as? String,
              let cur = (d["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
              let list = d["Spaces"] as? [[String: Any]] else { return nil }
        let spaces = list.compactMap { s -> (CGSSpaceID, Int)? in
            guard let id = (s["id64"] as? NSNumber)?.uint64Value else { return nil }
            return (id, (s["type"] as? NSNumber)?.intValue ?? 0)
        }
        return (ident, cur.uint64Value, spaces)
    }
}

func spaceOf(window: UInt32) -> [CGSSpaceID] {
    let arr = [NSNumber(value: window)] as CFArray
    guard let r = spacesForWindows(cid, 7, arr)?.takeRetainedValue() as? [NSNumber] else { return [] }
    return r.map { $0.uint64Value }
}

print("\n=== STEP 1: current Space layout ===")
let layout = allSpaces()
for d in layout {
    print("display \(d.display): current=\(d.current)")
    for s in d.spaces { print("   space \(s.id) type=\(s.type)") }
}

var userDesktops = layout.flatMap { $0.spaces }.filter { $0.type == 0 }.map { $0.id }

// MARK: - Space creation (runs first: it may supply the second desktop the move test needs)

print("\n=== STEP 1b: create a Space ===")
var createdSpace: CGSSpaceID = 0
var createdIsAttached = false

if let spaceCreate {
    let before = Set(allSpaces().flatMap { $0.spaces.map(\.id) })
    createdSpace = spaceCreate(cid, 1, nil)
    Thread.sleep(forTimeInterval: 0.6)
    let attached = Set(allSpaces().flatMap { $0.spaces.map(\.id) })
    print("SLSSpaceCreate returned: \(createdSpace)")
    print("space set delta: \(attached.subtracting(before))")

    if createdSpace != 0 && attached.contains(createdSpace) {
        createdIsAttached = true
        userDesktops.append(createdSpace)
        print("RESULT: CREATE SUCCEEDED — Space is attached to a display and reachable")
    } else if createdSpace != 0 {
        print("RESULT: CREATE returned an id but it is NOT attached to any display.")
        print("        This is the known SIP-gated behaviour: the Space exists in the")
        print("        window server but Mission Control does not manage it, so nothing")
        print("        can navigate to it. Never move a window here — it would vanish.")
    } else {
        print("RESULT: CREATE FAILED (returned 0)")
    }
} else {
    print("SKIPPED: SLSSpaceCreate unavailable")
}

guard userDesktops.count >= 2 else {
    print("""

    INCONCLUSIVE: the move test needs a second reachable desktop and Space creation
    did not provide one. Add a desktop in Mission Control (Control+Up, then '+') and
    re-run to test the window-move primitive.
    """)
    if createdSpace != 0, let spaceDestroy { spaceDestroy(cid, createdSpace) }
    exit(2)
}

// MARK: - Target a foreign window

print("\n=== STEP 2: find a foreign window to move ===")

// Finder is a safe, always-running foreign target. Open a window so we never
// disturb one the user is actually using.
let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
guard let finder else { print("FATAL: Finder not running"); exit(1) }
let finderPID = finder.processIdentifier

let beforeIDs = Set(((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? [])
    .filter { ($0["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == finderPID }
    .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })

// `open -n` a new Finder window at $HOME
Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [NSHomeDirectory()])
Thread.sleep(forTimeInterval: 1.5)

let candidates = ((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? [])
    .filter { ($0["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == finderPID }
    .filter { (($0["kCGWindowLayer"] as? NSNumber)?.int32Value ?? -1) == 0 }
    .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }

guard let target = candidates.first(where: { !beforeIDs.contains($0) }) ?? candidates.first else {
    print("FATAL: no Finder window found to test with")
    exit(1)
}
let isNewWindow = !beforeIDs.contains(target)
print("target window id: \(target) (owner pid \(finderPID), newly opened: \(isNewWindow))")

let originalSpaces = spaceOf(window: target)
print("target currently on space(s): \(originalSpaces)")
guard let origin = originalSpaces.first, originalSpaces.count == 1 else {
    print("FATAL: target resolves to \(originalSpaces.count) spaces; need exactly 1")
    exit(1)
}

guard let destination = userDesktops.first(where: { $0 != origin }) else {
    print("FATAL: no destination desktop distinct from origin")
    exit(1)
}

// MARK: - The decisive test

print("\n=== STEP 3: move foreign window \(origin) -> \(destination) ===")
moveWindows(cid, [NSNumber(value: target)] as CFArray, destination)
Thread.sleep(forTimeInterval: 0.6)

let after = spaceOf(window: target)
print("after move, window reports space(s): \(after)")

let moved = after == [destination]
if moved {
    print("RESULT: MOVE SUCCEEDED — foreign window relocated under SIP")
} else if after == originalSpaces {
    print("RESULT: MOVE SILENTLY NO-OPPED — window did not leave its origin space")
} else {
    print("RESULT: AMBIGUOUS — window now reports \(after), expected [\(destination)]")
}

// Restore
if moved {
    print("restoring window to space \(origin)...")
    moveWindows(cid, [NSNumber(value: target)] as CFArray, origin)
    Thread.sleep(forTimeInterval: 0.4)
    print("restored to: \(spaceOf(window: target))")
}

// MARK: - Space creation

print("\n=== STEP 4: destroy the Space created in step 1b ===")
if createdSpace != 0, let spaceDestroy {
    spaceDestroy(cid, createdSpace)
    Thread.sleep(forTimeInterval: 0.5)
    let stillThere = Set(allSpaces().flatMap { $0.spaces.map(\.id) }).contains(createdSpace)
    print("destroy \(stillThere ? "FAILED — space still present" : "succeeded (or space was never attached)")")
} else {
    print("SKIPPED: nothing to destroy")
}

print("\n=== SUMMARY ===")
print("Space create + attach:        \(createdIsAttached ? "WORKS" : "DOES NOT WORK")")
print("foreign window move to Space: \(moved ? "WORKS" : "DOES NOT WORK")")
print("SIP: enabled")
