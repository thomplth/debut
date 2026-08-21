// KHA-482 probe 8 — can a window be dragged across desktops without the user's hotkeys?
//
// Probe 6 moved a window by holding a drag and pressing the "switch to desktop N" chord. That
// works, but it makes the feature depend on a binding Debut does not own: those symbolic
// hotkeys ship *disabled*, and on this machine the enabled binding decoded to Control+Option+N
// rather than the documented Control+N. Shipping on top of that means the move silently stops
// working whenever a user's System Settings differ.
//
// SpaceService already switches desktops with a forged DockSwipe, which needs no binding at
// all. The open question is whether the Dock still honours that gesture while a drag is held —
// if it does, the whole move is self-contained and the hotkey dependency disappears.

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

// MARK: - Forged DockSwipe (mirrors SpaceService)

let fType = CGEventField(rawValue: 55)!
let fHID = CGEventField(rawValue: 110)!
let fScrollY = CGEventField(rawValue: 119)!
let fMotion = CGEventField(rawValue: 123)!
let fProgress = CGEventField(rawValue: 124)!
let fVelX = CGEventField(rawValue: 129)!
let fVelY = CGEventField(rawValue: 130)!
let fPhase = CGEventField(rawValue: 132)!
let fFlagBits = CGEventField(rawValue: 135)!
let fZoomDX = CGEventField(rawValue: 139)!

func dockEvent(phase: Int64, right: Bool, velocity: Double) -> CGEvent? {
    guard let e = CGEvent(source: nil) else { return nil }
    e.setIntegerValueField(fType, value: 30)          // dock control
    e.setIntegerValueField(fHID, value: 23)           // dock swipe
    e.setIntegerValueField(fPhase, value: phase)
    e.setIntegerValueField(fFlagBits, value: right ? 1 : 0)
    e.setIntegerValueField(fMotion, value: 1)         // horizontal
    e.setDoubleValueField(fScrollY, value: 0)
    e.setDoubleValueField(fZoomDX, value: Double(Float.leastNonzeroMagnitude))
    if phase == 4 {
        let sign: Double = right ? 1 : -1
        e.setDoubleValueField(fProgress, value: sign * 2.0)
        e.setDoubleValueField(fVelX, value: sign * velocity)
        e.setDoubleValueField(fVelY, value: 0)
    }
    return e
}

func envelope() -> CGEvent? {
    guard let e = CGEvent(source: nil) else { return nil }
    e.setIntegerValueField(fType, value: 29)
    return e
}

@discardableResult
func swipe(right: Bool, velocity: Double) -> Bool {
    guard let b = dockEvent(phase: 1, right: right, velocity: 0), let be = envelope(),
          let en = dockEvent(phase: 4, right: right, velocity: velocity), let ee = envelope()
    else { return false }
    for (c, v) in [(b, be), (en, ee)] {
        c.post(tap: .cgSessionEventTap)
        v.post(tap: .cgSessionEventTap)
    }
    return true
}

// MARK: - Setup

guard AXIsProcessTrusted() else { print("FATAL: needs Accessibility"); exit(1) }

let all = desktops()
print("desktops in order: \(all)")
guard all.count >= 2 else { print("FATAL: need 2+ desktops"); exit(1) }

let doc = "/tmp/kha482-probe8.txt"
try? "KHA-482 gesture-move probe".write(toFile: doc, atomically: true, encoding: .utf8)
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

// Jump as far as possible so a success cannot be explained by a single incidental step.
let targetIndex = originIndex == all.count - 1 ? 0 : all.count - 1
let targetSpace = all[targetIndex]
let steps = abs(targetIndex - originIndex)
let goRight = targetIndex > originIndex
print("window \(wid) on desktop \(originIndex + 1) (\(origin[0])) -> desktop \(targetIndex + 1) (\(targetSpace)), \(steps) step(s) \(goRight ? "right" : "left")")

// MARK: - Drag + forged gesture

let grab = CGPoint(x: bounds.midX, y: bounds.minY + 12)
let restore = CGEvent(source: nil)?.location ?? .zero
let src = CGEventSource(stateID: .hidSystemState)
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

print("\n=== drag + forged DockSwipe ===")
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

let velocity = 400.0 * Double(steps)
for _ in 0..<steps {
    swipe(right: goRight, velocity: velocity)
    pause(0.08)
}

pause(1.2)
let midCurrent = currentSpace()

// Keep the drag alive across the transition: the window follows the pointer, so it lands on
// whichever desktop is showing when the button is released.
post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
             mouseCursorPosition: CGPoint(x: grab.x, y: grab.y + 20), mouseButton: .left))
pause(0.15)
post(CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
             mouseCursorPosition: CGPoint(x: grab.x, y: grab.y + 20), mouseButton: .left))
pause(1.2)

let elapsed = Date().timeIntervalSince(started)
let after = spaceOf(wid)
print("current space after gesture: \(midCurrent) (expected \(targetSpace))")
print("window now on: \(after)   (wall time \(String(format: "%.2f", elapsed))s)")

if after == [targetSpace] {
    print("RESULT: GESTURE MOVE SUCCEEDED — no symbolic hotkey involved.")
} else if midCurrent != origin[0] && after == origin {
    print("RESULT: the gesture switched desktops but the window did not follow the drag.")
} else if midCurrent == origin[0] {
    print("RESULT: the Dock ignored the forged gesture while a drag was held.")
} else {
    print("RESULT: window landed on \(after), expected \(targetSpace).")
}

CGWarpMouseCursorPosition(restore)
print("\ncurrent space: \(currentSpace())")
