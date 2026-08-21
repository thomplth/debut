// KHA-482 probe 4 — the drag-and-switch route.
//
// Probes 1-3 showed every private window-move call no-ops cross-process. But BetterTouchTool
// ships "Move Window One Space or Desktop Right" and needs no SIP change, so a supported
// route exists. The likely one is not an API at all: hold the window by its title bar and
// fire the Space-switch shortcut, which is a gesture macOS supports for the real user.
//
// Two findings from earlier runs are baked in here. The chord needs SecondaryFn as well as
// Control (probe 5: arrow keys carry the Fn bit and the symbolic-hotkey matcher checks it),
// and the target must not be Finder, which is still assigned to every Space and so reports
// four space ids and cannot move.
//
// Nothing here is private except the read-back used to verify the result.

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

print("accessibility trusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else {
    print("FATAL: needs Accessibility. Grant it to the launching process and re-run.")
    exit(1)
}

// MARK: - Target: a fresh TextEdit window (foreign process)

let doc = "/tmp/kha482-probe.txt"
if !FileManager.default.fileExists(atPath: doc) {
    try? "KHA-482 drag probe".write(toFile: doc, atomically: true, encoding: .utf8)
}
Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-a", "TextEdit", doc])
pause(2.5)

guard let app = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else {
    print("FATAL: TextEdit did not launch")
    exit(1)
}
let pid = app.processIdentifier
app.activate()
pause(0.6)

let info = ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? [])
    .filter { ($0["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid }
    .filter { (($0["kCGWindowLayer"] as? NSNumber)?.int32Value ?? -1) == 0 }
    .first

guard let info,
      let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let boundsDict = info["kCGWindowBounds"] as? [String: Any],
      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
    print("FATAL: could not locate a TextEdit window")
    exit(1)
}

print("target window \(wid) bounds \(bounds)")
let originSpace = spaceOf(wid)
let originCurrent = currentSpace()
print("window on space \(originSpace), current space \(originCurrent)")

guard originSpace.count == 1 else {
    print("FATAL: target reports \(originSpace.count) spaces; it is pinned. Need exactly 1.")
    exit(1)
}

// MARK: - The drag

// Title bar centre. Use a small inset from the top so we land on the bar, not the content.
let grab = CGPoint(x: bounds.midX, y: bounds.minY + 12)
print("grab point: \(grab)")

let restore = CGEvent(source: nil)?.location ?? .zero
let src = CGEventSource(stateID: .hidSystemState)

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

print("\n=== simulating drag + Control+Fn+Right ===")

post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: grab, mouseButton: .left))
pause(0.15)
post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: grab, mouseButton: .left))
pause(0.15)

// A few small drags so the window server registers a real drag, not a click.
for dy in stride(from: 4, through: 16, by: 4) {
    let p = CGPoint(x: grab.x, y: grab.y + CGFloat(dy))
    post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
    pause(0.06)
}

let spaceMidDrag = currentSpace()

// Control+Fn+Right = "Move right a space" (symbolic hotkey 81).
let flags: CGEventFlags = [.maskControl, .maskSecondaryFn]
let kVK_RightArrow: CGKeyCode = 124
let down = CGEvent(keyboardEventSource: src, virtualKey: kVK_RightArrow, keyDown: true)
down?.flags = flags
post(down)
pause(0.08)
let up = CGEvent(keyboardEventSource: src, virtualKey: kVK_RightArrow, keyDown: false)
up?.flags = flags
post(up)

// Give the Space transition time to complete while still holding the window.
pause(1.4)
let spaceAfterChord = currentSpace()
print("space during drag: \(spaceMidDrag) -> after chord: \(spaceAfterChord)")

post(CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition:
    CGPoint(x: grab.x, y: grab.y + 16), mouseButton: .left))
pause(1.2)

// MARK: - Verify

let afterSpace = spaceOf(wid)
let afterCurrent = currentSpace()
print("\nwindow now on space \(afterSpace), current space \(afterCurrent)")

if afterSpace != originSpace && !afterSpace.isEmpty {
    print("RESULT: DRAG MOVE SUCCEEDED — \(originSpace) -> \(afterSpace)")
    print("        (foreign window relocated with no private write API and SIP enabled)")
} else if spaceAfterChord == spaceMidDrag {
    print("RESULT: the chord did not switch the Space while the mouse was held.")
    print("        Holding a button appears to suppress the Space-switch hotkey.")
} else {
    print("RESULT: the Space switched but the window did not travel with it.")
    print("        The drag did not take hold — likely grabbed the wrong point.")
}

CGWarpMouseCursorPosition(restore)
print("\ncursor restored to \(restore)")
print("current space is now \(currentSpace()) — switch back manually if needed")
