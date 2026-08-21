// KHA-482 probe 7 — does the forged DockSwipe actually switch Spaces on this machine?
//
// SpaceServiceTests can only assert that the right private fields are set on the event; no
// unit test can prove the Dock acts on it. This posts the same Began+Ended pair
// `DockSwipeEvent.postSwitch` builds and reads the resulting desktop back out of
// CGSCopyManagedDisplaySpaces, which is the only honest confirmation available.
//
// Keep the field values here in step with Sources/DebutCore/Services/SpaceService.swift.

import AppKit
import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let rtld = UnsafeMutableRawPointer(bitPattern: -2 as Int)
private func sym<T>(_ n: String) -> T? { dlsym(rtld, n).map { unsafeBitCast($0, to: T.self) } }

let conn: (@convention(c) () -> CGSConnectionID)? = sym("CGSMainConnectionID")
let displaySpaces: (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? = sym("CGSCopyManagedDisplaySpaces")
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

func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

let kCGSEventTypeField = CGEventField(rawValue: 55)!
let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
let kCGEventGestureScrollY = CGEventField(rawValue: 119)!
let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
let kCGEventGestureSwipeVelocityY = CGEventField(rawValue: 130)!
let kCGEventGesturePhase = CGEventField(rawValue: 132)!
let kCGEventScrollGestureFlagBits = CGEventField(rawValue: 135)!
let kCGEventGestureZoomDeltaX = CGEventField(rawValue: 139)!

let kCGSEventGesture: Int64 = 29
let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGSGesturePhaseBegan: Int64 = 1
let kCGSGesturePhaseEnded: Int64 = 4
let kGestureMotionHorizontal: Int64 = 1

func makeDockEvent(phase: Int64, isRight: Bool, velocity: Double) -> CGEvent? {
    guard let e = CGEvent(source: nil) else { return nil }
    e.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
    e.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    e.setIntegerValueField(kCGEventGesturePhase, value: phase)
    e.setIntegerValueField(kCGEventScrollGestureFlagBits, value: isRight ? 1 : 0)
    e.setIntegerValueField(kCGEventGestureSwipeMotion, value: kGestureMotionHorizontal)
    e.setDoubleValueField(kCGEventGestureScrollY, value: 0)
    e.setDoubleValueField(kCGEventGestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))
    if phase == kCGSGesturePhaseEnded {
        let sign: Double = isRight ? 1 : -1
        e.setDoubleValueField(kCGEventGestureSwipeProgress, value: sign * 2.0)
        e.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: sign * velocity)
        e.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
    }
    return e
}

func makeEnvelope() -> CGEvent? {
    guard let e = CGEvent(source: nil) else { return nil }
    e.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)
    return e
}

@discardableResult
func postSwitch(isRight: Bool, velocity: Double) -> Bool {
    guard let began = makeDockEvent(phase: kCGSGesturePhaseBegan, isRight: isRight, velocity: 0),
          let beganEnv = makeEnvelope(),
          let ended = makeDockEvent(phase: kCGSGesturePhaseEnded, isRight: isRight, velocity: velocity),
          let endedEnv = makeEnvelope() else { return false }
    for (c, env) in [(began, beganEnv), (ended, endedEnv)] {
        c.post(tap: .cgSessionEventTap)
        env.post(tap: .cgSessionEventTap)
    }
    return true
}

let all = desktops()
print("desktops: \(all)")
print("macOS major: \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
guard all.count >= 2 else { print("FATAL: need 2+ desktops"); exit(1) }

let start = currentSpace()
print("current: \(start) (index \(all.firstIndex(of: start).map(String.init) ?? "?"))")

print("\n=== one step right ===")
let t0 = Date()
postSwitch(isRight: true, velocity: 400)
pause(0.6)
let afterRight = currentSpace()
print("now \(afterRight) after \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))ms")

guard afterRight != start else {
    print("RESULT: DockSwipe did NOT switch the Space. The forged gesture is being ignored.")
    exit(2)
}

print("\n=== one step back left ===")
postSwitch(isRight: false, velocity: 400)
pause(0.6)
let back = currentSpace()
print("now \(back)")

// A multi-step jump scales velocity so the Dock snaps rather than animating through
// each desktop in turn — the behaviour a stage switch depends on.
if all.count >= 3 {
    print("\n=== jump \(all.count - 1) desktops right in one burst ===")
    let steps = all.count - 1
    let t1 = Date()
    for _ in 0..<steps { postSwitch(isRight: true, velocity: 400 * Double(steps)) }
    pause(1.0)
    let far = currentSpace()
    print("now \(far), expected \(all.last!) — \(far == all.last! ? "MATCH" : "MISMATCH") "
          + "(\(String(format: "%.0f", Date().timeIntervalSince(t1) * 1000))ms)")

    for _ in 0..<steps { postSwitch(isRight: false, velocity: 400 * Double(steps)) }
    pause(1.0)
    print("returned to \(currentSpace()), started at \(start)")
}

print("\nRESULT: forged DockSwipe switches Spaces on this machine.")
