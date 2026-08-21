// KHA-482 probe 6 — is the drag-and-switch move O(1) or O(distance)?
//
// Probe 4 proved the route works with Control+Fn+Right, but that chord is *relative*: moving
// a window three stages over would mean three chained chords and three visible Space
// transitions. Debut needs "put this window on stage N", so the question that decides
// whether the route is usable is whether the same drag accepts the *direct*
// "switch to desktop N" chord (symbolic hotkeys 118-125, Control+1..5 and enabled here).
//
// Also times the operation, since assignment latency is the one cost this architecture
// pays that the current overlay design does not.

import AppKit
import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let rtld = UnsafeMutableRawPointer(bitPattern: -2 as Int)
private func sym<T>(_ n: String) -> T? { dlsym(rtld, n).map { unsafeBitCast($0, to: T.self) } }

let conn: (@convention(c) () -> CGSConnectionID)? = sym("CGSMainConnectionID")
let displaySpaces: (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? = sym("CGSCopyManagedDisplaySpaces")
let spacesForWindows: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?)? = sym("SLSCopySpacesForWindows")
let cid = conn!()

func desktops() -> [CGSSpaceID] {
    guard let raw = displaySpaces!(cid, nil)?.takeRetainedValue() as? [[String: Any]],
          let d = raw.first, let list = d["Spaces"] as? [[String: Any]] else { return [] }
    return list.compactMap {
        guard ($0["type"] as? NSNumber)?.intValue ?? 0 == 0 else { return nil }
        return ($0["id64"] as? NSNumber)?.uint64Value
    }
}

func currentSpace() -> CGSSpaceID {
    guard let raw = displaySpaces!(cid, nil)?.takeRetainedValue() as? [[String: Any]],
          let d = raw.first,
          let cur = (d["Current Space"] as? [String: Any])?["id64"] as? NSNumber else { return 0 }
    return cur.uint64Value
}

func spaceOf(_ w: UInt32) -> [CGSSpaceID] {
    guard let r = spacesForWindows!(cid, 7, [NSNumber(value: w)] as CFArray)?
        .takeRetainedValue() as? [NSNumber] else { return [] }
    return r.map { $0.uint64Value }
}

func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

guard AXIsProcessTrusted() else { print("FATAL: needs Accessibility"); exit(1) }

let all = desktops()
print("desktops in order: \(all)")
guard all.count >= 3 else { print("FATAL: need 3+ desktops to prove a multi-hop jump"); exit(1) }

// MARK: - Target

let doc = "/tmp/kha482-probe6.txt"
try? "KHA-482 direct-move probe".write(toFile: doc, atomically: true, encoding: .utf8)
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

let origin = spaceOf(wid)
guard origin.count == 1, let originIndex = all.firstIndex(of: origin[0]) else {
    print("FATAL: window reports \(origin), need exactly one known desktop"); exit(1)
}

// Jump as far as possible, so a success cannot be explained by a single relative step.
let targetIndex = originIndex == all.count - 1 ? 0 : all.count - 1
let targetSpace = all[targetIndex]
print("window \(wid) on desktop \(originIndex + 1) (\(origin[0])) -> aiming at desktop \(targetIndex + 1) (\(targetSpace))")
print("distance: \(abs(targetIndex - originIndex)) desktops")

// MARK: - Drag + direct switch

let digitKeys: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28]  // 1..8
guard targetIndex < digitKeys.count else { print("FATAL: no direct chord for that desktop"); exit(1) }

let grab = CGPoint(x: bounds.midX, y: bounds.minY + 12)
let restore = CGEvent(source: nil)?.location ?? .zero
let src = CGEventSource(stateID: .hidSystemState)
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

// The installed binding for "switch to desktop N" here is Control+Option+N
// (symbolic hotkey 118-122, modifiers 0xC0000), not the stock Control+N.
let directFlags: CGEventFlags = [.maskControl, .maskAlternate]
print("\n=== drag + Control+Option+\(targetIndex + 1) ===")
let started = Date()

post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: grab, mouseButton: .left))
pause(0.12)
post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: grab, mouseButton: .left))
pause(0.12)
for dy in stride(from: 4, through: 16, by: 4) {
    post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
                 mouseCursorPosition: CGPoint(x: grab.x, y: grab.y + CGFloat(dy)), mouseButton: .left))
    pause(0.05)
}

let key = digitKeys[targetIndex]
let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
d?.flags = directFlags
post(d)
pause(0.08)
let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
u?.flags = directFlags
post(u)

pause(1.4)
let midCurrent = currentSpace()
post(CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
             mouseCursorPosition: CGPoint(x: grab.x, y: grab.y + 16), mouseButton: .left))
pause(1.0)

let elapsed = Date().timeIntervalSince(started)
let after = spaceOf(wid)
print("current space after chord: \(midCurrent)")
print("window now on: \(after)   (wall time \(String(format: "%.2f", elapsed))s)")

if after == [targetSpace] {
    print("RESULT: DIRECT MOVE SUCCEEDED — one chord jumped \(abs(targetIndex - originIndex)) desktops.")
    print("        Assignment is O(1), not O(distance).")
} else if after != origin {
    print("RESULT: window moved to \(after) but not to the requested desktop.")
} else if midCurrent == origin[0] {
    print("RESULT: the direct chord did not switch the Space during the drag.")
} else {
    print("RESULT: Space switched but the window stayed on \(after).")
}

CGWarpMouseCursorPosition(restore)
print("\ncurrent space: \(currentSpace())")
