import AppKit
import CoreGraphics
import DebutCore

private func postHIDMouse(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

/// A point on the main display that no window, the menu bar or the Dock covers.
private func uncoveredDesktopPoint() -> CGPoint? {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let covered = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] ?? [])
        .compactMap { info -> CGRect? in
            guard (info[kCGWindowLayer] as? Int) == 0 else { return nil }
            return (info[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
    let insetBounds = bounds.insetBy(dx: 80, dy: 140)
    for row in 0..<8 {
        for column in 0..<8 {
            let point = CGPoint(x: insetBounds.minX + insetBounds.width * CGFloat(column) / 7,
                                y: insetBounds.minY + insetBounds.height * CGFloat(row) / 7)
            if !covered.contains(where: { $0.insetBy(dx: -20, dy: -20).contains(point) }) { return point }
        }
    }
    return nil
}

private func eventLines(_ events: [[String: String]]) -> String {
    events.map { event in
        "      " + ([event["event"] ?? "?"] + event.keys.sorted()
            .filter { !["event", "timestamp", "uptimeNanoseconds"].contains($0) }
            .map { "\($0)=\(event[$0] ?? "")" }).joined(separator: " ")
    }.joined(separator: "\n")
}

private func isSwitchEvidence(_ event: [String: String]) -> Bool {
    let name = event["event"] ?? ""
    return name.contains("move") || name.contains("switch")
        || name.contains("native_shortcut") || name == "key_event"
}

private func usedSystemRoute(_ events: [[String: String]]) -> Bool {
    events.contains {
        $0["event"] == "system_desktop_switch_requested" || $0["event"] == "native_shortcut_posted"
    }
}

/// GitHub #32 (KHA-1208): macOS carries a window held by its title bar to the desktop its own
/// Control-number shortcut switches to. Debut claims that chord, so it has to carry the window too.
@MainActor
func scenario_held_window_quick_switch() {
    header("A window held by its title bar follows a quick switch (KHA-1208)")
    let stillCheck = "A window held by its title bar moves to the desktop a quick switch shows"
    let releasedCheck = "The carried window stays on its new desktop, tracked there, once let go"
    let uncoveredCheck = "A quick switch with the button held over no window still switches the desktop"
    let checks = [stillCheck, releasedCheck, uncoveredCheck]
    guard !skipsSyntheticDrags else { checks.forEach(skipDragTest); return }

    let spaces = SpaceService()
    let windows = AccessibilityWindowService()
    guard spaces.desktopCount() >= 2 else {
        checks.forEach { skipTest($0, reason: "This host has one desktop, so there is nowhere to carry a window") }
        return
    }
    defer { _ = quickSwitch(to: 0, using: spaces) }
    func modelSpace(of windowID: CGWindowID) -> Int? {
        SpaceController.decodeWindowIDs(readState()["windowIDsBySpace"] ?? "")
            .firstIndex { $0.contains(windowID) }
    }
    func describe(_ windowID: CGWindowID) -> String {
        "desktop=\(spaces.currentDesktopIndex().map(String.init) ?? "none") "
            + "windowDesktop=\(spaces.desktopIndex(forWindow: windowID).map(String.init) ?? "none") "
            + "model=\(modelSpace(of: windowID).map(String.init) ?? "none") "
            + "active=\(readState()["activeSpaceIndex"] ?? "none")"
    }

    guard quickSwitch(to: 0, using: spaces) else {
        test(stillCheck) { false }
        return
    }
    let fixtureURL = writeFixtureFile(named: "held-window.txt", contents: "Debut held window fixture\n")
    let pid = launchNewTextEditInstance(opening: [fixtureURL])
    defer { if pid > 0 { NSRunningApplication(processIdentifier: pid)?.forceTerminate() } }
    var fixture: WindowInfo?
    let ready = pid > 0 && waitFor(timeout: 15) {
        guard let window = windows.listWindows().first(where: { $0.ownerPID == pid }) else { return false }
        fixture = window
        _ = NSRunningApplication(processIdentifier: pid)?.activate()
        _ = windows.raiseWindow(windowID: window.windowID)
        return spaces.desktopIndex(forWindow: window.windowID) == 0
            && modelSpace(of: window.windowID) == 0 && liveKeyboardFocus()?.windowID == window.windowID
    }
    guard ready, let window = fixture else {
        info("  Held-window fixture: pid=\(pid) window=\(fixture?.windowID.description ?? "none") "
            + (fixture.map { describe($0.windowID) } ?? ""))
        test(stillCheck) { false }
        return
    }

    // One carry per session: in Tart, after a carry no later synthetic title-bar drag moves its
    // window at all, before Debut is involved (KHA-1208).
    let carryEventsBefore = eventCursor()
    let grab = CGPoint(x: window.bounds.midX, y: window.bounds.minY + 12)
    postHIDMouse(.leftMouseDown, at: grab)
    wait(0.25)
    postQuickSwitch(to: 1)
    let carried = waitFor(timeout: 8) {
        spaces.currentDesktopIndex() == 1 && spaces.desktopIndex(forWindow: window.windowID) == 1
    }
    let heldDescription = describe(window.windowID)
    _ = takeScreenshot("held_window_quick_switch")
    postHIDMouse(.leftMouseUp, at: grab)
    let settled = waitFor(timeout: 5) {
        spaces.currentDesktopIndex() == 1 && spaces.desktopIndex(forWindow: window.windowID) == 1
            && modelSpace(of: window.windowID) == 1 && Int(readState()["activeSpaceIndex"] ?? "") == 1
    }
    if !carried || !settled {
        let evidence = events(since: carryEventsBefore, where: isSwitchEvidence)
        info("  Held window \(window.windowID): systemRoute=\(usedSystemRoute(evidence)) "
            + "front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) grab=\(grab) "
            + "while held \(heldDescription); after release \(describe(window.windowID))\n"
            + eventLines(evidence))
    }
    test(stillCheck) { carried }
    test(releasedCheck) { settled }

    let uncovered = quickSwitch(to: 0, using: spaces) ? uncoveredDesktopPoint() : nil
    guard let uncovered else {
        info("  No uncovered desktop point: desktop=\(spaces.currentDesktopIndex().map(String.init) ?? "none")")
        test(uncoveredCheck) { false }
        return
    }
    let eventsBefore = eventCursor()
    postHIDMouse(.leftMouseDown, at: uncovered)
    wait(0.25)
    postQuickSwitch(to: 1)
    let landed = waitFor(timeout: 8) {
        spaces.currentDesktopIndex() == 1
            && !events(since: eventsBefore, where: { $0["event"] == "space_switched" }).isEmpty
    }
    postHIDMouse(.leftMouseUp, at: uncovered)
    if !landed {
        info("  Button held over \(uncovered): desktop=\(spaces.currentDesktopIndex().map(String.init) ?? "none")\n"
            + eventLines(events(since: eventsBefore, where: isSwitchEvidence)))
    }
    test(uncoveredCheck) { landed }
}
