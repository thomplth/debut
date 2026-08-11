import Testing
import Foundation
import ApplicationServices
@testable import DebutCore

@Suite("MockWindowService")
struct WindowServiceTests {

    @Test("Only non-modal AX standard windows are trackable")
    func classifiesTrackableAXWindows() {
        #expect(AccessibilityWindowService.isTrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isModal: false
        ))
        #expect(!AccessibilityWindowService.isTrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXUnknownSubrole as String,
            isModal: false
        ))
        #expect(!AccessibilityWindowService.isTrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String,
            isModal: true
        ))
        #expect(!AccessibilityWindowService.isTrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isModal: true
        ))
    }

    @Test("Disabled live previews do not request screen capture")
    func disabledLivePreviewsAvoidCapture() {
        let service = AccessibilityWindowService(windowCaptureEnabled: false)

        #expect(service.captureWindowImage(windowID: kCGNullWindowID) == nil)
    }

    @Test("List running apps")
    func listApps() {
        let svc = MockWindowService()
        svc.apps = [
            AppInfo(bundleID: "com.a", name: "A", pid: 100, isHidden: false),
            AppInfo(bundleID: "com.b", name: "B", pid: 200, isHidden: false),
        ]
        #expect(svc.listRunningApps().count == 2)
    }

    @Test("List windows")
    func listWindows() {
        let svc = MockWindowService()
        svc.windowList = [
            WindowInfo(windowID: 101, ownerBundleID: "com.a", ownerName: "A", ownerPID: 100, title: "T1", bounds: .zero, isOnScreen: true),
            WindowInfo(windowID: 202, ownerBundleID: "com.b", ownerName: "B", ownerPID: 200, title: "T2", bounds: .zero, isOnScreen: true),
        ]
        #expect(svc.listWindows().count == 2)
    }

    @Test("Raise window")
    func raiseWindow() {
        let svc = MockWindowService()
        #expect(svc.raiseWindow(windowID: 101))
        #expect(svc.raisedWindowID == 101)
        #expect(svc.raisedWindowIDs == [101])
    }

    @Test("Raise tracks all raised windows")
    func raiseMultiple() {
        let svc = MockWindowService()
        _ = svc.raiseWindow(windowID: 101)
        _ = svc.raiseWindow(windowID: 202)
        #expect(svc.raisedWindowIDs == [101, 202])
        #expect(svc.raisedWindowID == 202)
    }

    @Test("Activate app")
    func activateApp() {
        let svc = MockWindowService()
        #expect(svc.activateApp(bundleID: "com.a"))
        #expect(svc.activatedBundleID == "com.a")
    }

    @Test("A resolved window element skips the running-app scan")
    func resolvedElementSkipsScan() {
        let service = AccessibilityWindowService()
        let element = AXUIElementCreateSystemWide()
        var scanCount = 0
        service.windowElementResolver = { _ in element }
        service.elementScanOverride = { _ in
            scanCount += 1
            return nil
        }

        _ = service.raiseWindow(windowID: 42)

        #expect(scanCount == 0)
    }

    @Test("An unresolved window element falls back to the running-app scan")
    func unresolvedElementFallsBackToScan() {
        let service = AccessibilityWindowService()
        let element = AXUIElementCreateSystemWide()
        var scannedWindowIDs: [CGWindowID] = []
        service.windowElementResolver = { _ in nil }
        service.elementScanOverride = { windowID in
            scannedWindowIDs.append(windowID)
            return element
        }

        _ = service.raiseWindow(windowID: 42)

        #expect(scannedWindowIDs == [42])
    }

    @Test("Raising without a resolver still scans, so untracked windows keep working")
    func missingResolverStillScans() {
        let service = AccessibilityWindowService()
        var scanCount = 0
        service.elementScanOverride = { _ in
            scanCount += 1
            return nil
        }

        _ = service.raiseWindow(windowID: 42)

        #expect(scanCount == 1)
    }
}
