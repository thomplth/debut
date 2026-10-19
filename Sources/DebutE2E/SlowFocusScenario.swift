import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DebutCore

/// KHA-1166: focus inside an app too slow to answer Debut's 50ms AX read, and into it from
/// another app. Debut used to re-read the app's focused window on every focus notification, and
/// dropped each switch the read timed out on; the WindowServer reports them all.
@MainActor
func scenario_slow_focus_app() {
    header("Focus inside, and into, an app slow to answer Accessibility (KHA-1166)")
    let insideCheck = "Focus moving inside an app whose AX focus read stalls reaches the MRU order"
    let activationCheck = "Activating that app from another one puts its focused window at the MRU head"
    let returnCheck = "Command-Tab from that app returns to the app activated before it"

    func skipAll(_ reason: String) {
        for check in [insideCheck, activationCheck, returnCheck] { skipTest(check, reason: reason) }
    }

    guard let bundle = StalledFocusFixture.makeBundle() else {
        skipAll("The stalled-focus fixture bundle could not be written")
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [StalledFocusFixture.subcommand]
    let launched = LockedBox<NSRunningApplication>()
    let failure = LockedBox<String>()
    let ready = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { application, error in
        launched.store(application)
        failure.store(error.map { String(describing: $0) })
        ready.signal()
    }
    _ = ready.wait(timeout: .now() + 20)
    guard let fixture = launched.load() else {
        info("  Fixture launch failed: \(failure.load() ?? "timed out")")
        skipAll("The stalled-focus fixture did not launch")
        return
    }
    defer { fixture.forceTerminate() }
    let pid = fixture.processIdentifier

    func fixtureWindowIDs() -> [String: CGWindowID] {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var found: [String: CGWindowID] = [:]
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let title = window[kCGWindowName as String] as? String,
                  StalledFocusFixture.titles.contains(title),
                  let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            found[title] = windowID
        }
        return found
    }

    func frontWindowID(of processIdentifier: pid_t) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    func reportedOrder() -> [[CGWindowID]] {
        SpaceController.decodeWindowIDs(readState()["windowIDsBySpace"] ?? "")
    }

    func ranksAhead(_ first: CGWindowID, of second: CGWindowID) -> Bool {
        reportedOrder().contains { windows in
            guard let firstIndex = windows.firstIndex(of: first),
                  let secondIndex = windows.firstIndex(of: second)
            else { return false }
            return firstIndex < secondIndex
        }
    }

    func heads(_ windowID: CGWindowID) -> Bool {
        reportedOrder().contains { $0.first == windowID }
    }

    func focusReadMilliseconds() -> Double {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        var window: CFTypeRef?
        let started = DispatchTime.now().uptimeNanoseconds
        _ = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window)
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    let opened = waitFor(timeout: 15) { fixtureWindowIDs().count == StalledFocusFixture.titles.count }
    let windows = fixtureWindowIDs()
    guard opened,
          let first = windows[StalledFocusFixture.titles[0]],
          let second = windows[StalledFocusFixture.titles[1]]
    else {
        info("  Fixture windows: \(windows)")
        skipAll("The stalled-focus fixture did not open both windows")
        return
    }
    let tracked = waitFor(timeout: 12) {
        let ids = Set(reportedOrder().flatMap { $0 })
        return ids.contains(first) && ids.contains(second)
    }
    info("Stalled focus fixture: pid=\(pid) windows=\(windows) tracked=\(tracked) "
        + "focusRead=\(String(format: "%.0f", focusReadMilliseconds()))ms")
    guard tracked else {
        test(insideCheck) {
            info("  Debut never tracked both fixture windows: \(reportedOrder())")
            return false
        }
        skipTest(activationCheck, reason: "Debut does not track the fixture's windows")
        skipTest(returnCheck, reason: "Debut does not track the fixture's windows")
        return
    }

    func moveFocus(to target: CGWindowID, from other: CGWindowID) -> (inFront: Bool, landed: Bool) {
        let title = windows.first { $0.value == target }?.key ?? ""
        StalledFocusFixture.requestFocus(title)
        let inFront = waitFor(timeout: 5) { frontWindowID(of: pid) == target }
        let landed = inFront && waitFor(timeout: 5) { ranksAhead(target, of: other) }
        info("  Focus \(title): inFront=\(inFront) landed=\(landed) order=\(reportedOrder())")
        return (inFront, landed)
    }

    let behind = ranksAhead(first, of: second) ? second : first
    let ahead = behind == first ? second : first
    let forward = moveFocus(to: behind, from: ahead)
    let back = moveFocus(to: ahead, from: behind)
    if !(forward.inFront && back.inFront) {
        skipTest(insideCheck, reason: "The fixture never brought the requested window to the front")
    } else {
        test(insideCheck) {
            if !(forward.landed && back.landed) {
                info("  a window the fixture put in front on screen never led the MRU order")
            }
            return forward.landed && back.landed
        }
    }

    let fixtureDocuments = currentFixtureWindowIDs()
    guard let previous = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
        .first(where: { editor in fixtureDocuments.contains { ownerPID(ofWindow: $0) == editor.processIdentifier } })
    else {
        skipTest(activationCheck, reason: "No shared TextEdit fixture is running to activate from")
        skipTest(returnCheck, reason: "No shared TextEdit fixture is running to activate from")
        return
    }
    _ = previous.activate()
    let previousInFront = waitFor(timeout: 5) {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier
            && frontWindowID(of: previous.processIdentifier).map(heads) == true
    }
    _ = fixture.activate()
    let fixtureInFront = waitFor(timeout: 5) {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    let fixtureFront = frontWindowID(of: pid)
    let fixtureHeads = waitFor(timeout: 5) { fixtureFront.map(heads) == true }
    info("  Activation: previousInFront=\(previousInFront) fixtureInFront=\(fixtureInFront) "
        + "fixtureFront=\(fixtureFront.map(String.init) ?? "none") order=\(reportedOrder())")
    if !(previousInFront && fixtureInFront) {
        skipTest(activationCheck, reason: "macOS did not hand activation between the two apps")
        skipTest(returnCheck, reason: "macOS did not hand activation between the two apps")
        return
    }
    test(activationCheck) { fixtureHeads }

    postFlagsChanged(flags: [.maskCommand])
    wait(0.05)
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    postKeyUp(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    postFlagsChanged(flags: [])
    let returned = waitFor(timeout: 5) {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier
    }
    test(returnCheck) {
        if !returned {
            info("  frontmost after Command-Tab: "
                + "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") "
                + "order=\(reportedOrder())")
        }
        return returned
    }
}

private func ownerPID(ofWindow windowID: CGWindowID) -> pid_t? {
    let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] ?? []
    return windows.first.flatMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
}
