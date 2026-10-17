import AppKit
import Carbon.HIToolbox
import CoreGraphics
import DebutCore

// MARK: - Desktop management

/// Adds, discards, merges and removes real desktops from the overlay (KHA-1087). Only macOS 27
/// adopts a desktop Debut creates, so elsewhere the controls are hidden and this is a skip.
///
/// The model is not the evidence: every step also asks the window server which desktops exist,
/// in what order, and where the moved windows ended up. The scenario leaves as many desktops as
/// it found, with the fixture windows on the first one, so later groups see their usual layout.
@MainActor
func scenario_desktop_management() {
    header("Desktop management adds, merges and removes real desktops")
    let discardTest = "Escape discards a staged desktop without creating one"
    let addTest = "Command-N adds a real desktop after the selected one"
    let mergeTest = "Dropping a plate on another merges its desktop away"
    let removeTest = "Command-Delete removes a desktop and its windows join the one showing"
    let cleanupTest = "Desktop management leaves as many desktops as it found"
    let allTests = [discardTest, addTest, mergeTest, removeTest, cleanupTest]

    let service = SpaceService()
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    guard service.canManageDesktops else {
        for name in allTests {
            skipTest(name, reason: "macOS \(major) does not adopt desktops Debut creates; the controls are hidden")
        }
        return
    }
    let desktopsBefore = service.userDesktops()
    let baseCount = desktopsBefore.count
    guard baseCount >= 2, Int(readState()["spaceCount"] ?? "") == baseCount else {
        for name in allTests {
            skipTest(name, reason: "The fixture needs at least two desktops that Debut lists; "
                + "found \(baseCount), Debut lists \(readState()["spaceCount"] ?? "none")")
        }
        return
    }
    info("  Desktops before: \(desktopsBefore), showing \(service.currentDesktopIndex().map(String.init) ?? "none")")

    func named(_ name: String, since cursor: UInt64, _ extra: ([String: String]) -> Bool = { _ in true })
        -> [[String: String]] {
        events(since: cursor) { $0["event"] == name && extra($0) }
    }
    func openOverlay() -> Bool {
        postFlagsChanged(flags: [.maskCommand])
        wait(0.1)
        postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
        postKeyUp(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
        let open = waitFor { readState()["overlayVisible"] == "true" }
        wait(0.5)
        return open
    }
    func press(_ keyCode: Int) {
        postKeyDown(keyCode: CGKeyCode(keyCode), flags: [.maskCommand])
        postKeyUp(keyCode: CGKeyCode(keyCode), flags: [.maskCommand])
    }
    func releaseCommand() {
        postFlagsChanged(flags: [])
    }
    func overlayClosed() -> Bool { waitFor { readState()["overlayVisible"] == "false" } }
    func spaceCount() -> Int? { Int(readState()["spaceCount"] ?? "") }

    // Commits one Command-N from the overlay and returns the desktop macOS made, with where the
    // overlay asked for it. The commit switches to the new desktop.
    func commitNewDesktop(_ label: String) -> (desktopID: CGSSpaceID, expectedIndex: Int, staged: Bool)? {
        let before = service.userDesktops()
        let cursor = eventCursor()
        let opened = openOverlay()
        let selected = Int(readState()["selectedSpaceIndex"] ?? "") ?? -1
        press(kVK_ANSI_N)
        let staged = waitFor { !named("desktop_add_staged", since: cursor).isEmpty }
        _ = takeScreenshot("desktop_management_\(label)_staged")
        releaseCommand()
        let added = waitFor(timeout: 10) {
            named("desktop_added", since: cursor).count == 1
                && service.userDesktops().count == before.count + 1
                && spaceCount() == before.count + 1
        }
        let event = named("desktop_added", since: cursor).last ?? [:]
        let desktopID = event["desktopID"].flatMap(CGSSpaceID.init)
        let landed = desktopID.map { id in waitFor(timeout: 5) { service.currentDesktop() == id } } ?? false
        _ = overlayClosed()
        info("  \(label): opened=\(opened) selected=\(selected) staged=\(staged) added=\(added) "
            + "landed=\(landed) event=\(event) desktops=\(service.userDesktops()) "
            + "spaceCount=\(spaceCount().map(String.init) ?? "none")")
        guard let desktopID, added, landed else { return nil }
        return (desktopID, selected + 1, staged)
    }

    // 1. A staged desktop that is discarded never reaches macOS. Nothing may arrive afterwards,
    // so a fixed wait is the right check here: load can only delay a desktop, never invent one.
    let discardCursor = eventCursor()
    let discardOpened = openOverlay()
    press(kVK_ANSI_N)
    let discardStaged = waitFor { !named("desktop_add_staged", since: discardCursor).isEmpty }
    let stagedCount = spaceWindowCounts(in: readState()).count
    press(kVK_Escape)
    releaseCommand()
    let discardClosed = overlayClosed()
    wait(1.5)
    let discardAdded = named("desktop_added", since: discardCursor)
    info("  Discard: opened=\(discardOpened) staged=\(discardStaged) previewStages=\(stagedCount) "
        + "closed=\(discardClosed) added=\(discardAdded.count) desktops=\(service.userDesktops())")
    test(discardTest) {
        discardOpened && discardStaged && discardClosed && discardAdded.isEmpty
            && service.userDesktops() == desktopsBefore && spaceCount() == baseCount
    }

    // 2. Command-N stages a desktop after the selected one; releasing Command creates it there.
    let first = commitNewDesktop("add")
    test(addTest) {
        guard let first else { return false }
        let desktops = service.userDesktops()
        info("  Added desktop \(first.desktopID) at \(desktops.firstIndex(of: first.desktopID).map(String.init) ?? "none"), "
            + "expected \(first.expectedIndex)")
        return first.staged
            && desktops.firstIndex(of: first.desktopID) == first.expectedIndex
            && desktopsBefore.allSatisfy(desktops.contains)
    }

    // 3. The new desktop is empty and showing. Lift its plate and drop it on the plate before it:
    // the merge switches there first, then destroys the desktop it left.
    if skipsSyntheticDrags {
        skipTest(mergeTest, reason: "GitHub-hosted macOS does not deliver synthetic drag gestures; run this check in Tart")
    } else if let first, first.expectedIndex > 0 {
        let source = first.expectedIndex
        let destination = source - 1
        let destinationID = service.userDesktops()[desktopManagementSafe: destination]
        let mergeCursor = eventCursor()
        let opened = openOverlay()
        let state = readState()
        let aspects = spaceCardAspects(in: state)
        let selected = Int(state["selectedSpaceIndex"] ?? "") ?? source
        let active = Int(state["activeSpaceIndex"] ?? "") ?? source
        let inactiveScale = CGFloat(interactionSettings.appearance(for: reportedCardStyle).inactiveStageScale)
        let pickup = stageCenter(spaceIndex: source, cardAspects: aspects, activeSpaceIndex: active,
                                 focusedSpaceIndex: selected, inactiveScale: inactiveScale)
        // Crossing the room between plates opens a slot and rescales the drag view, so the drop
        // follows the overlay's own retargeting rather than aiming at one fixed point.
        let path = pickup.flatMap {
            plateMergePath(cardAspects: aspects, pickup: $0, sourceSpaceIndex: source,
                           destinationSpaceIndex: destination)
        }
        info("  Merge: opened=\(opened) source=\(source) destination=\(destination) selected=\(selected) "
            + "active=\(active) windows=\(spaceWindowCounts(in: state)) pickup=\(pickup.map { "\($0)" } ?? "nil") "
            + "release=\(path?.last.map { "\($0)" } ?? "nil") steps=\(path?.count ?? 0)")
        if let path {
            postMouseDrag(path: path)
            let staged = waitFor {
                !named("desktop_remove_staged", since: mergeCursor, { $0["source"] == "merge" }).isEmpty
            }
            _ = takeScreenshot("desktop_management_merge_staged")
            releaseCommand()
            let merged = waitFor(timeout: 10) {
                named("desktop_removed", since: mergeCursor).count == 1
                    && service.userDesktops() == desktopsBefore
                    && spaceCount() == baseCount
            }
            let onDestination = waitFor(timeout: 5) { destinationID != nil && service.currentDesktop() == destinationID }
            _ = overlayClosed()
            info("  Merge commit: staged=\(staged) merged=\(merged) onDestination=\(onDestination) "
                + "events=\(events(since: mergeCursor) { ($0["event"] ?? "").hasPrefix("desktop_") }) "
                + "desktops=\(service.userDesktops()) showing=\(service.currentDesktopIndex().map(String.init) ?? "none")")
            test(mergeTest) { opened && staged && merged && onDestination }
        } else {
            reportDragGeometryFailure(mergeTest, reason: "Could not calculate the plate-merge path")
            releaseCommand()
        }
    } else {
        skipTest(mergeTest, reason: "No desktop was added to merge")
    }

    // 4. Add a desktop again, then remove the first desktop while the new one shows: the first
    // desktop's windows, the fixture documents among them, join the desktop showing.
    if service.userDesktops().count == baseCount, let second = commitNewDesktop("remove-setup") {
        let fixtureIDs = currentFixtureWindowIDs()
        let removedID = service.userDesktops().first
        let windowsBefore = spaceWindowCounts(in: readState())
        let removeCursor = eventCursor()
        let opened = openOverlay()
        press(kVK_ANSI_1)
        let selectedFirst = waitFor { Int(readState()["selectedSpaceIndex"] ?? "") == 0 }
        press(kVK_Delete)
        let staged = waitFor {
            !named("desktop_remove_staged", since: removeCursor, { $0["source"] == "command" }).isEmpty
        }
        _ = takeScreenshot("desktop_management_remove_staged")
        releaseCommand()
        let removed = waitFor(timeout: 10) {
            named("desktop_removed", since: removeCursor).count == 1
                && service.userDesktops().count == baseCount
                && !service.userDesktops().contains(where: { $0 == removedID })
                && spaceCount() == baseCount
        }
        // The windows follow the commit's moves, which the window server reports a little later,
        // and Debut's per-space counts trail both: await the window server and the model together.
        let expectedFirstCount = (windowsBefore.first ?? 0)
            + (windowsBefore[desktopManagementSafe: second.expectedIndex] ?? 0)
        var windowsAfter: [Int] = []
        let windowsMoved = waitFor(timeout: 5) {
            windowsAfter = spaceWindowCounts(in: readState())
            return !fixtureIDs.isEmpty
                && fixtureIDs.allSatisfy { service.spaces(forWindow: $0) == [second.desktopID] }
                && windowsAfter.first == expectedFirstCount
        }
        _ = overlayClosed()
        let secondIndex = service.userDesktops().firstIndex(of: second.desktopID)
        info("  Remove: opened=\(opened) selectedFirst=\(selectedFirst) staged=\(staged) removed=\(removed) "
            + "windowsMoved=\(windowsMoved) expectedFirst=\(expectedFirstCount) fixtures=\(fixtureIDs.sorted()) "
            + "spaces=\(fixtureIDs.sorted().map { service.spaces(forWindow: $0) }) "
            + "windows \(windowsBefore) -> \(windowsAfter) desktops=\(service.userDesktops()) "
            + "secondIndex=\(secondIndex.map(String.init) ?? "none")")
        test(removeTest) {
            opened && selectedFirst && staged && removed && windowsMoved
                && secondIndex == 0
        }
    } else {
        skipTest(removeTest, reason: "The desktop to remove into could not be added")
    }

    // A failed step must not leave its desktop for the next run: the guest persists between
    // runs, and every leftover desktop shrinks the plates the next drag aims at.
    removeDesktopsAdded(since: desktopsBefore, service: service)
    test(cleanupTest) {
        service.userDesktops().count == baseCount && spaceCount() == baseCount
    }
}

/// Removes desktops that are not in `original` until as many remain as it held, switching off
/// one first when it shows. A desktop added to stand in for a removed original stays.
@MainActor
private func removeDesktopsAdded(since original: [CGSSpaceID], service: SpaceService) {
    for desktop in service.userDesktops().reversed() where !original.contains(desktop) {
        guard service.userDesktops().count > original.count else { return }
        if service.currentDesktop() == desktop, let home = original.first,
           let index = service.userDesktops().firstIndex(of: home) {
            service.switchToDesktop(index: index)
            _ = waitFor(timeout: 5) { service.currentDesktop() == home }
        }
        guard let location = service.spaceTopology().location(ofSpace: desktop) else { continue }
        let removed = AtomicFlag()
        service.removeDesktop(location) { removed.set($0) }
        let gone = waitFor(timeout: 5) { !service.userDesktops().contains(desktop) }
        info("  Cleanup: removed desktop \(desktop): accepted=\(removed.value) gone=\(gone)")
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}

private extension Array {
    subscript(desktopManagementSafe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
