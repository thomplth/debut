import CoreGraphics
import Foundation

extension SpaceController {
    func toggleApplication(id: UUID) {
        guard !isSpaceManagerVisible,
              let shortcut = applicationShortcuts.first(where: { $0.id == id })
        else { return }
        let target = applications.runningTarget(bundleID: shortcut.bundleID)
        let windows = target.map { target in
            spaceManager.globalWindowOrder().filter {
                $0.window.ownerBundleID == shortcut.bundleID
                    && ($0.window.ownerPID ?? target.pid) == target.pid
            }
        } ?? []
        let toggle = ApplicationToggle.plan(
            shortcut,
            target: target,
            windows: windows,
            activeSpaceID: spaceManager.activeSpaceID,
            isExcluded: excludedBundleIDs.contains(shortcut.bundleID),
            canMoveWindows: spaceSwitcher?.canMoveWindows == true
        )
        diag.report("application_shortcut", details: [
            "bundleID": shortcut.bundleID,
            "running": "\(target != nil)",
            "active": "\(target?.isActive ?? false)",
            "hidden": "\(target?.isHidden ?? false)",
            "trackedWindows": "\(windows.count)",
            "action": Self.diagnosticName(of: toggle),
        ])

        switch toggle {
        case .ignore:
            break
        case .open:
            if let target, target.isHidden { applications.unhide(pid: target.pid) }
            applications.open(bundleID: shortcut.bundleID, path: shortcut.appPath)
        case .hide(let pid):
            applications.hide(pid: pid)
        case .openNewWindow(let pid):
            // Sent first, so the window exists before the open's reopen event can make another.
            applications.sendNewWindowShortcut(pid: pid)
            applications.open(bundleID: shortcut.bundleID, path: shortcut.appPath)
        case .reveal(let reveal):
            if reveal.unhides { applications.unhide(pid: reveal.pid) }
            relocateToActiveDesktop(reveal.relocatedWindowIDs) { [weak self] in
                self?.finishReveal(reveal)
            }
        }
    }

    private func relocateToActiveDesktop(
        _ windowIDs: [CGWindowID],
        completion: @escaping @Sendable () -> Void
    ) {
        let activeSpaceID = spaceManager.activeSpaceID
        guard !windowIDs.isEmpty,
              let switcher = spaceSwitcher,
              let stackID = spaceManager.spaceStackID(containingSpaceID: activeSpaceID),
              let index = spaceManager.spaceIndex(id: activeSpaceID),
              let location = switcher.spaceTopology().stack(id: stackID)?.location(at: index)
        else {
            completion()
            return
        }
        let barrier = WindowRelocationBarrier(count: windowIDs.count, completion: completion)
        applicationRelocationWindowIDs.formUnion(windowIDs)
        for windowID in windowIDs {
            switcher.moveWindow(windowID: windowID, to: location) { [weak self] moved in
                let finish: @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    self.applicationRelocationWindowIDs.remove(windowID)
                    if moved, let sourceID = self.spaceManager.spaceContainingWindow(windowID: windowID),
                       self.spaceManager.allSpaces.contains(where: { $0.id == activeSpaceID }) {
                        self.spaceManager.moveWindow(windowID: windowID, fromSpaceID: sourceID,
                                                     toSpaceID: activeSpaceID, at: 0)
                        self.delegate?.spaceControllerDidMutateState(self)
                    }
                    self.diag.report(moved ? "application_window_moved" : "window_move_failed", details: [
                        "windowID": "\(windowID)", "toSpaceIndex": "\(index)", "source": "application_shortcut",
                    ])
                    barrier.arrive()
                }
                if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
            }
        }
    }

    /// A refused move leaves its window where it was, so the destination is read again here
    /// rather than trusted from the plan.
    private func finishReveal(_ reveal: ApplicationReveal) {
        guard let destinationID = spaceManager.spaceContainingWindow(windowID: reveal.focusWindowID)
        else { return }
        for windowID in reveal.raisedWindowIDs
        where spaceManager.spaceContainingWindow(windowID: windowID) == destinationID {
            _ = windowService.raiseTrackedWindow(windowID: windowID)
        }
        switchToSpace(id: destinationID, raiseWindowID: reveal.focusWindowID)
    }

    private static func diagnosticName(of toggle: ApplicationToggle) -> String {
        switch toggle {
        case .ignore: "ignore"
        case .open: "open"
        case .hide: "hide"
        case .openNewWindow: "open_new_window"
        case .reveal(let reveal):
            "reveal(moved=\(reveal.relocatedWindowIDs.count),raised=\(reveal.raisedWindowIDs.count))"
        }
    }
}
