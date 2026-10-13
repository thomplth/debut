import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Capture availability")
struct CaptureAvailabilityTests {
    private func monitor() -> (CaptureAvailabilityMonitor, NotificationCenter, NotificationCenter, LockedChanges) {
        let distributed = NotificationCenter()
        let workspace = NotificationCenter()
        let changes = LockedChanges()
        let monitor = CaptureAvailabilityMonitor(distributedCenter: distributed, workspaceCenter: workspace) {
            changes.append($0)
        }
        return (monitor, distributed, workspace, changes)
    }

    @Test("Locking the screen suspends capture until it unlocks")
    func lockSuspends() {
        let (monitor, distributed, _, changes) = monitor()
        #expect(!monitor.isSuspended)
        distributed.post(name: CaptureAvailabilityMonitor.screenLocked, object: nil)
        #expect(monitor.isSuspended)
        distributed.post(name: CaptureAvailabilityMonitor.screenUnlocked, object: nil)
        #expect(!monitor.isSuspended)
        #expect(changes.values == [true, false])
    }

    @Test("Any one reason keeps capture suspended until all have cleared")
    func reasonsCombine() {
        let (monitor, distributed, workspace, changes) = monitor()
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        distributed.post(name: CaptureAvailabilityMonitor.screenLocked, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(monitor.isSuspended, "still locked")
        distributed.post(name: CaptureAvailabilityMonitor.screenUnlocked, object: nil)
        #expect(!monitor.isSuspended)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(monitor.isSuspended, "another user's session is showing")
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(changes.values == [true, false, true, false])
    }

    @Test("A frame materially smaller than the size asked for is a half-drawn one")
    func partialFrame() {
        #expect(PreviewCaptureRoute.isPartialFrame(width: 400, height: 300, requestedWidth: 800, requestedHeight: 600))
        #expect(!PreviewCaptureRoute.isPartialFrame(width: 799, height: 598, requestedWidth: 800, requestedHeight: 600))
        #expect(PreviewCaptureRoute.isPartialFrame(width: 800, height: 500, requestedWidth: 800, requestedHeight: 600))
    }
}

final class LockedChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var values: [Bool] { lock.withLock { stored } }
    func append(_ value: Bool) { lock.withLock { stored.append(value) } }
}
