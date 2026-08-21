// KHA-482 probe 5 — isolate the keyboard leg of the drag-and-switch route.
//
// Probe 4 posted Control+Right and the current Space did not change, so the drag leg was
// never actually tested. The binding is present and enabled (symbolic hotkey 81 = virtual
// key 124, modifiers 0x840000), and 0x840000 is Control | SecondaryFn — arrow keys carry
// the Fn bit, and probe 4 set only Control. This probe fires the chord on its own, with no
// drag, so a failure here is unambiguously about event synthesis rather than about the drag.

import AppKit
import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let rtld = UnsafeMutableRawPointer(bitPattern: -2 as Int)
private func sym<T>(_ n: String) -> T? { dlsym(rtld, n).map { unsafeBitCast($0, to: T.self) } }

let conn: (@convention(c) () -> CGSConnectionID)? = sym("CGSMainConnectionID")
let displaySpaces: (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? = sym("CGSCopyManagedDisplaySpaces")
let cid = conn!()

func currentSpace() -> CGSSpaceID {
    guard let raw = displaySpaces!(cid, nil)?.takeRetainedValue() as? [[String: Any]],
          let d = raw.first,
          let cur = (d["Current Space"] as? [String: Any])?["id64"] as? NSNumber else { return 0 }
    return cur.uint64Value
}

func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

let src = CGEventSource(stateID: .hidSystemState)
let kVK_RightArrow: CGKeyCode = 124
let kVK_LeftArrow: CGKeyCode = 123

func chord(_ key: CGKeyCode, _ flags: CGEventFlags) {
    let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    d?.flags = flags
    d?.post(tap: .cghidEventTap)
    pause(0.08)
    let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    u?.flags = flags
    u?.post(tap: .cghidEventTap)
    pause(1.2)
}

func trial(_ label: String, _ flags: CGEventFlags) -> Bool {
    let before = currentSpace()
    chord(kVK_RightArrow, flags)
    let after = currentSpace()
    let moved = after != before
    print("  \(label): \(before) -> \(after)  \(moved ? "SWITCHED ✓" : "no change")")
    if moved {
        chord(kVK_LeftArrow, flags)
        print("    returned to \(currentSpace())")
    }
    return moved
}

print("current space: \(currentSpace())")
print("\n=== Control+Right, varying the flag set ===")

var winner: String?
if trial("Control only            ", [.maskControl]) { winner = "control" }
if winner == nil, trial("Control + SecondaryFn   ", [.maskControl, .maskSecondaryFn]) { winner = "control+fn" }
if winner == nil, trial("Control + Fn + NumericPad", [.maskControl, .maskSecondaryFn, .maskNumericPad]) { winner = "control+fn+numpad" }

print("\nRESULT: \(winner.map { "space switching works with \($0) flags" } ?? "no flag combination switched the Space")")
