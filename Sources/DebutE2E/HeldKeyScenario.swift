import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// What a listen-only tap behind Debut's saw of one key: every key-down that got past Debut,
/// and whether macOS marked it as a repeat.
final class PassedKeyRecorder: @unchecked Sendable {
    var keyDowns: [Bool] = []
    var keyUps = 0
}

private func passedKeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_D) {
        let recorder = Unmanaged<PassedKeyRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .keyDown {
            recorder.keyDowns.append(event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        } else if type == .keyUp {
            recorder.keyUps += 1
        }
    }
    return Unmanaged.passUnretained(event)
}

func focusedText(of pid: pid_t) -> String? {
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused
    ) == .success, let focused else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        focused as! AXUIElement, kAXValueAttribute as CFString, &value
    ) == .success else { return nil }
    return value as? String
}

/// KHA-930: a key held as the overlay opens is released while the overlay owns the keyboard.
/// Its key-down already reached the app, so swallowing that release left the key logically held
/// and every later press of it arrived as a repeat — the second "D stopped working" report.
@MainActor
func scenario_held_key_across_overlay() {
    header("A key held while the overlay opens keeps working (KHA-930)")
    let fixture = writeFixtureFile(named: "held-key.txt", contents: "")
    let pid = launchNewTextEditInstance(opening: [fixture])
    defer { if pid > 0 { NSRunningApplication(processIdentifier: pid)?.terminate() } }
    let editor = NSRunningApplication(processIdentifier: pid)
    let ready = pid > 0 && waitFor(timeout: 15) {
        _ = editor?.activate()
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && focusedText(of: pid) != nil
    }
    guard ready else {
        test("TextEdit fixture is frontmost with a focused document") { false }
        return
    }

    let recorder = PassedKeyRecorder()
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: passedKeyCallback,
        userInfo: Unmanaged.passUnretained(recorder).toOpaque()
    )
    var source: CFRunLoopSource?
    if let tap {
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    defer {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    let d = CGKeyCode(kVK_ANSI_D)
    func typeD() {
        postKeyDown(keyCode: d)
        wait(0.05)
        postKeyUp(keyCode: d)
        wait(0.2)
    }
    typeD()
    test("D types before the overlay opens") {
        waitFor { focusedText(of: pid)?.contains("d") == true }
    }

    // Hold D, open the overlay, and let D's release land while the overlay owns the keyboard.
    postKeyDown(keyCode: d)
    wait(0.1)
    postFlagsChanged(flags: [.maskCommand])
    wait(0.1)
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    postKeyUp(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    let opened = waitFor { readState()["overlayVisible"] == "true" }
    postKeyUp(keyCode: d, flags: [.maskCommand])
    wait(0.1)
    postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
    postKeyUp(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
    wait(0.2)
    postFlagsChanged(flags: [])
    _ = waitFor { readState()["overlayVisible"] == "false" }
    test("The overlay opened while D was held") { opened }

    _ = waitFor {
        _ = editor?.activate()
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    wait(0.5)
    let before = focusedText(of: pid) ?? ""
    let passedBefore = recorder.keyDowns.count
    typeD()
    typeD()
    let after = focusedText(of: pid) ?? ""
    let laterPresses = recorder.keyDowns.dropFirst(passedBefore)
    info("  D presses after the overlay: \(laterPresses.count) passed Debut, "
        + "repeat flags \(Array(laterPresses)); text \(before.count) -> \(after.count) characters")
    test("D still types after its release fell inside the overlay") {
        waitFor { (focusedText(of: pid) ?? "").count >= before.count + 2 }
    }
    test("Later D presses arrive as new presses, not repeats") {
        laterPresses.count == 2 && !laterPresses.contains(true)
    }
}
