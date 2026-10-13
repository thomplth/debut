import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

/// Varied pixels, so a capture passes the content check.
private func contentImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for row in stride(from: 4, to: 64, by: 8) { context.fill(CGRect(x: 4, y: row, width: 40, height: 3)) }
    return context.makeImage()!
}

private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// Every window ID any capture call has asked for, in order.
private func captured(_ service: MockWindowService) -> [CGWindowID] {
    service.captureRequests.flatMap { $0 }
}

@Suite("Background preview capture", .serialized)
struct BackgroundPreviewCaptureTests {
    private func makeController(
        settleDelay: TimeInterval = 0.15
    ) -> (SpaceController, MockWindowService, MockKeyboardService, UUID, UUID) {
        let windowService = MockWindowService()
        let keyboardService = MockKeyboardService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: keyboardService,
            focusedWindowSnapshotProvider: { .unfocused }
        )
        controller.backgroundPreviewSettleDelay = settleDelay
        let showing = controller.spaceManager.spaces[0].id
        controller.spaceManager.addFixtureDesktop()
        let hidden = controller.spaceManager.spaces[1].id
        for windowID in [CGWindowID(101), 102] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T\(windowID)"),
                toSpaceID: showing
            )
        }
        controller.spaceManager.addWindow(
            SpaceWindow(windowID: 909, ownerBundleID: "com.b", ownerName: "B", windowTitle: "Away"),
            toSpaceID: hidden
        )
        controller.spaceManager.activateSpace(id: showing)
        windowService.capturedImages = [101: contentImage(), 102: contentImage(), 909: contentImage()]
        return (controller, windowService, keyboardService, showing, hidden)
    }

    @Test("Focus leaving a window captures it at once; the window gaining focus waits to settle")
    func focusChange() {
        // Generous, so a slow runner reaching the first check late cannot see the second fire.
        let (controller, service, _, _, _) = makeController(settleDelay: 2)
        DispatchQueue.main.sync { controller.recordWindowActivation(windowID: 101) }
        DispatchQueue.main.sync { controller.recordWindowActivation(windowID: 102) }

        #expect(waitFor { captured(service).contains(101) }, "the window left is final for now")
        #expect(!captured(service).contains(102), "the window just focused is about to change")
        #expect(waitFor { captured(service).contains(102) })
        #expect(captured(service).filter { $0 == 102 }.count == 1)
    }

    @Test("A burst of resizes is captured once, after it stops")
    func resizeDebounces() {
        // Far longer than a loaded runner can stall between two reports of one drag.
        let (controller, service, _, _, _) = makeController(settleDelay: 1.5)
        for width in stride(from: 800, through: 900, by: 20) {
            DispatchQueue.main.sync {
                controller.recordWindowSize(windowID: 101, size: CGSize(width: width, height: 600))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(captured(service).isEmpty, "still resizing")
        #expect(waitFor { captured(service) == [101] })
        Thread.sleep(forTimeInterval: 1.6)
        #expect(captured(service) == [101], "one capture for the whole drag")
    }

    @Test("A title change on a desktop that is not showing captures nothing")
    func hiddenDesktopSkipped() {
        let (controller, service, _, _, _) = makeController(settleDelay: 0.05)
        DispatchQueue.main.sync {
            controller.recordWindowTitleChange(windowID: 909)
            controller.recordWindowTitleChange(windowID: 101)
        }
        #expect(waitFor { captured(service).contains(101) })
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!captured(service).contains(909))
    }

    @Test("A settled desktop switch captures the windows now showing")
    func desktopSettled() {
        let (controller, service, _, _, hidden) = makeController(settleDelay: 5)
        DispatchQueue.main.sync {
            controller.spaceManager.activateSpace(id: hidden)
            controller.desktopDidChange()
        }
        #expect(waitFor { captured(service).contains(909) })
        #expect(!captured(service).contains(101), "the desktop left is not swept")
    }

    @Test("Opening the overlay takes over a capture still waiting to settle")
    func overlayPromotesPending() {
        let (controller, service, keyboard, _, _) = makeController(settleDelay: 30)
        DispatchQueue.main.sync { controller.recordWindowTitleChange(windowID: 102) }
        keyboard.simulateEvent(.cmdTabHold)
        #expect(waitFor { captured(service).contains(102) }, "a known-stale preview is not left for 30s")
        keyboard.simulateEvent(.escape)
    }

    @Test("Background captures stop while capture is suspended")
    func suspendedDrops() {
        let (controller, service, _, _, _) = makeController(settleDelay: 0.05)
        DispatchQueue.main.sync {
            controller.previewCaptureSuspended = true
            controller.recordWindowActivation(windowID: 101)
            controller.recordWindowActivation(windowID: 102)
            controller.recordWindowTitleChange(windowID: 101)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(captured(service).isEmpty)
    }

    @Test("A background capture is reported under its own reason")
    func reasonReported() {
        let reports = RecordedReports()
        let windowService = MockWindowService()
        let controller = SpaceController(
            windowService: windowService,
            keyboardService: MockKeyboardService(),
            focusedWindowSnapshotProvider: { .unfocused },
            previewFreshness: PreviewFreshnessRecorder(
                report: reports.report,
                measuresDevelopmentCosts: false,
                background: { $0() },
                main: { $0() }
            )
        )
        for windowID in [CGWindowID(101), 102] {
            controller.spaceManager.addWindow(
                SpaceWindow(windowID: windowID, ownerBundleID: "com.a", ownerName: "A", windowTitle: "T"),
                toSpaceID: controller.spaceManager.activeSpaceID
            )
        }
        windowService.capturedImages = [101: contentImage(), 102: contentImage()]
        DispatchQueue.main.sync {
            controller.recordWindowActivation(windowID: 101)
            controller.recordWindowActivation(windowID: 102)
        }
        #expect(waitFor { reports.events("preview_capture_batch").contains { $0["reason"] == "focus_left" } })
    }

    @Test("A light/dark switch recaptures showing windows once redrawn, and the rest at the next open")
    func appearanceChange() {
        let (controller, service, keyboard, _, _) = makeController(settleDelay: 0.1)
        keyboard.simulateEvent(.cmdTabHold)
        #expect(waitFor { controller.windowPreviews.count == 3 })
        keyboard.simulateEvent(.escape)
        #expect(waitFor { !controller.isSpaceManagerVisible })
        let before = service.captureRequests.count
        let image = controller.windowPreviews[909]

        DispatchQueue.main.sync { controller.systemAppearanceDidChange() }
        #expect(controller.windowPreviews[909] === image, "the old picture stays until replaced")
        #expect(waitFor { Set(service.captureRequests[before...].flatMap { $0 }).isSuperset(of: [101, 102]) })
        #expect(!service.captureRequests[before...].flatMap { $0 }.contains(909), "not on a showing desktop")

        let afterSettle = service.captureRequests.count
        keyboard.simulateEvent(.cmdTabHold)
        #expect(waitFor { service.captureRequests.count > afterSettle })
        #expect(waitFor { service.captureRequests[afterSettle...].flatMap { $0 }.contains(909) },
                "a window on another desktop is stale at the next open")
        keyboard.simulateEvent(.escape)
    }
}
