// KHA-482 probe 2 — separate "wrong calling convention" from "cross-process gated".
//
// Probe 1 showed SLSMoveWindowsToManagedSpace no-opping on a Finder window. That is only
// meaningful if the same call demonstrably WORKS on a window this process owns. So every
// API below is tried twice: once against our own NSWindow (control) and once against a
// foreign window. A call that moves ours but not Finder's proves the restriction is
// cross-process, not a bad signature.

import AppKit
import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let rtld = UnsafeMutableRawPointer(bitPattern: -2 as Int)
private func sym<T>(_ n: String) -> T? { dlsym(rtld, n).map { unsafeBitCast($0, to: T.self) } }

typealias FnConn = @convention(c) () -> CGSConnectionID
typealias FnDisplaySpaces = @convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?
typealias FnSpacesForWindows = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
typealias FnMoveManaged = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
typealias FnAddRemove = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
typealias FnListWorkspace = @convention(c) (CGSConnectionID, UnsafePointer<UInt32>, Int32, Int32) -> Int32
typealias FnProcAssign = @convention(c) (CGSConnectionID, pid_t, CGSSpaceID) -> Int32

let conn: FnConn? = sym("CGSMainConnectionID")
let displaySpaces: FnDisplaySpaces? = sym("CGSCopyManagedDisplaySpaces")
let spacesForWindows: FnSpacesForWindows? = sym("SLSCopySpacesForWindows")
let moveManaged: FnMoveManaged? = sym("SLSMoveWindowsToManagedSpace")
let addToSpaces: FnAddRemove? = sym("CGSAddWindowsToSpaces")
let removeFromSpaces: FnAddRemove? = sym("CGSRemoveWindowsFromSpaces")
let listWorkspace: FnListWorkspace? = sym("SLSSetWindowListWorkspace")
let procAssign: FnProcAssign? = sym("SLSProcessAssignToSpace")

let cid = conn!()

func userDesktops() -> [CGSSpaceID] {
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

let desktops = userDesktops()
print("user desktops: \(desktops)")
guard desktops.count >= 2 else { print("FATAL: need 2+ desktops"); exit(1) }

// MARK: - Our own window (control subject)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let ownWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
                         styleMask: [.titled], backing: .buffered, defer: false)
ownWindow.title = "KHA-482 probe"
ownWindow.orderFront(nil)
RunLoop.current.run(until: Date().addingTimeInterval(1.0))
let ownID = UInt32(ownWindow.windowNumber)
print("own window id: \(ownID), space: \(spaceOf(ownID))")

// MARK: - Foreign window (Finder)

let finderPID = NSWorkspace.shared.runningApplications
    .first { $0.bundleIdentifier == "com.apple.finder" }!.processIdentifier
Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [NSHomeDirectory()])
RunLoop.current.run(until: Date().addingTimeInterval(1.5))

let foreignID = ((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? [])
    .filter { ($0["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == finderPID }
    .filter { (($0["kCGWindowLayer"] as? NSNumber)?.int32Value ?? -1) == 0 }
    .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    .first
guard let foreignID else { print("FATAL: no Finder window"); exit(1) }
print("foreign window id: \(foreignID), space: \(spaceOf(foreignID))")

// MARK: - Test harness

func attempt(_ name: String, _ wid: UInt32, _ label: String, _ body: (UInt32, CGSSpaceID) -> Void) {
    let before = spaceOf(wid)
    guard let origin = before.first else { print("  \(name) [\(label)]: SKIP (no origin space)"); return }
    guard let dest = desktops.first(where: { $0 != origin }) else { return }

    body(wid, dest)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let after = spaceOf(wid)

    if after == [dest] {
        print("  \(name) [\(label)]: MOVED \(origin) -> \(dest)  ✓")
        body(wid, origin)  // restore
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    } else if after == before {
        print("  \(name) [\(label)]: no-op (still \(after))")
    } else {
        print("  \(name) [\(label)]: ambiguous -> \(after)")
    }
}

print("\n=== SLSMoveWindowsToManagedSpace ===")
if let moveManaged {
    let f: (UInt32, CGSSpaceID) -> Void = { w, s in
        moveManaged(cid, [NSNumber(value: w)] as CFArray, s)
    }
    attempt("SLSMoveWindowsToManagedSpace", ownID, "OWN", f)
    attempt("SLSMoveWindowsToManagedSpace", foreignID, "FOREIGN", f)
}

print("\n=== CGSAddWindowsToSpaces / CGSRemoveWindowsFromSpaces ===")
if let addToSpaces, let removeFromSpaces {
    let f: (UInt32, CGSSpaceID) -> Void = { w, s in
        let wins = [NSNumber(value: w)] as CFArray
        let cur = spaceOf(w).map { NSNumber(value: $0) } as CFArray
        removeFromSpaces(cid, wins, cur)
        addToSpaces(cid, wins, [NSNumber(value: s)] as CFArray)
    }
    attempt("CGSAdd/RemoveWindowsFromSpaces", ownID, "OWN", f)
    attempt("CGSAdd/RemoveWindowsFromSpaces", foreignID, "FOREIGN", f)
}

print("\n=== SLSSetWindowListWorkspace ===")
if let listWorkspace {
    let f: (UInt32, CGSSpaceID) -> Void = { w, s in
        var wid = w
        _ = withUnsafePointer(to: &wid) { listWorkspace(cid, $0, 1, Int32(truncatingIfNeeded: s)) }
    }
    attempt("SLSSetWindowListWorkspace", ownID, "OWN", f)
    attempt("SLSSetWindowListWorkspace", foreignID, "FOREIGN", f)
} else { print("  symbol unavailable") }

print("\n=== SLSProcessAssignToSpace (whole process) ===")
if let procAssign {
    let before = spaceOf(foreignID)
    guard let origin = before.first, let dest = desktops.first(where: { $0 != origin }) else { exit(0) }
    let rc = procAssign(cid, finderPID, dest)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let after = spaceOf(foreignID)
    print("  SLSProcessAssignToSpace(pid \(finderPID) -> \(dest)) rc=\(rc), window now \(after)")
    if after == [dest] {
        print("  ✓ MOVED — restoring")
        _ = procAssign(cid, finderPID, origin)
    } else {
        print("  no-op")
    }
} else { print("  symbol unavailable") }

print("\nDone.")
