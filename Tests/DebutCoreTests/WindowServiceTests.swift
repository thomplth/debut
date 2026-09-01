import Testing
import Foundation
import ApplicationServices
@testable import DebutCore

@Suite("MockWindowService")
struct WindowServiceTests {

    @Test("Non-modal AX standard and dialog windows are trackable")
    func classifiesTrackableAXWindows() {
        #expect(AccessibilityWindowService.isTrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isModal: false
        ))
        #expect(AccessibilityWindowService.isTrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String,
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

    // Phoenix Slides exposes its borderless image viewer as a 2560x1440 layer-0 window on
    // exactly one desktop, but AX reports AXUnknown for its subrole. "Unknown" is the absence
    // of a classification, not positive evidence that the viewer is auxiliary UI; treating it
    // as untrackable made the real Stage 1 window dormant as `ax_contradicted`.
    @Test("Only a positive AX verdict makes a window untrackable")
    func unknownAXSubroleIsInconclusive() {
        #expect(!AccessibilityWindowService.isPositivelyUntrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXUnknownSubrole as String,
            isModal: false
        ))
        #expect(!AccessibilityWindowService.isPositivelyUntrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String,
            isModal: false
        ))
        #expect(AccessibilityWindowService.isPositivelyUntrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXFloatingWindowSubrole as String,
            isModal: false
        ))
        #expect(AccessibilityWindowService.isPositivelyUntrackableAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isModal: true
        ))
        #expect(AccessibilityWindowService.isPositivelyUntrackableAXWindow(
            role: kAXButtonRole as String,
            subrole: kAXUnknownSubrole as String,
            isModal: false
        ))
    }

    // AX role/subrole is a snapshot, not a verdict: an app that hasn't answered AX yet, or a
    // window on a Space that isn't showing (kAXWindows cannot see it there at all), is neither
    // trackable nor untrackable. Only a positively-untrackable window may be dropped outright;
    // an AX-unknown window instead falls back to this CG-only heuristic.
    @Test("An AX-unknown window is plausible only when every CG signal agrees")
    func classifiesPlausibleUntrackedWindows() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(AccessibilityWindowService.isPlausibleUntrackedWindow(
            layer: 0, isRegularApp: true, bounds: bounds, hasResolvedDesktop: true
        ))
        #expect(!AccessibilityWindowService.isPlausibleUntrackedWindow(
            layer: 3, isRegularApp: true, bounds: bounds, hasResolvedDesktop: true
        ))
        #expect(!AccessibilityWindowService.isPlausibleUntrackedWindow(
            layer: nil, isRegularApp: true, bounds: bounds, hasResolvedDesktop: true
        ))
        #expect(!AccessibilityWindowService.isPlausibleUntrackedWindow(
            layer: 0, isRegularApp: false, bounds: bounds, hasResolvedDesktop: true
        ))
        #expect(!AccessibilityWindowService.isPlausibleUntrackedWindow(
            layer: 0, isRegularApp: true, bounds: bounds, hasResolvedDesktop: false
        ))
        #expect(!AccessibilityWindowService.isPlausibleUntrackedWindow(
            layer: 0, isRegularApp: true,
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10), hasResolvedDesktop: true
        ))
    }

    // Plausibility gates admission, so it may rest on ambiguous evidence: a window macOS
    // cannot place on one desktop is refused entry but proves nothing, because an all-Spaces
    // or fullscreen window looks the same. Eviction cannot use that same bar — it needs a
    // positive statement that the thing is not a window, or it would park real windows.
    //
    // The cases below are measured, not invented. Dia window 4797 on 2026-08-31 was an 84x77
    // surface on layer 3 that CGWindowList kept reporting for hours after it stopped being a
    // window, while Dia 4794 was a real 2338x1440 browser window on layer 0.
    @Test("Only a positive Core Graphics verdict disqualifies an assigned window")
    func disqualifiesWindowsThatCannotBeWindows() {
        #expect(AccessibilityWindowService.isDisqualifiedWindow(
            layer: 3, bounds: CGRect(x: 0, y: 0, width: 84, height: 77)
        ))
        #expect(AccessibilityWindowService.isDisqualifiedWindow(
            layer: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)
        ))
        #expect(!AccessibilityWindowService.isDisqualifiedWindow(
            layer: 0, bounds: CGRect(x: 0, y: 0, width: 2338, height: 1440)
        ))
        // An absent layer is missing evidence, not a verdict.
        #expect(!AccessibilityWindowService.isDisqualifiedWindow(
            layer: nil, bounds: CGRect(x: 0, y: 0, width: 2338, height: 1440)
        ))
    }

    // The two predicates deliberately disagree here, and that gap is the whole design: a
    // fullscreen or all-Spaces window resolves to no single desktop, so it is not plausible
    // enough to admit, yet nothing about it says it is not a window.
    @Test("A window with no resolved desktop is unadmitted but not disqualified")
    func unresolvedDesktopIsNotADisqualification() {
        let bounds = CGRect(x: 0, y: 0, width: 2338, height: 1440)
        #expect(!AccessibilityWindowService.isPlausibleUntrackedWindow(
            layer: 0, isRegularApp: true, bounds: bounds, hasResolvedDesktop: false
        ))
        #expect(!AccessibilityWindowService.isDisqualifiedWindow(layer: 0, bounds: bounds))
    }

    // Values measured 2026-09-01 across all four desktops, sampling each window while its own
    // desktop was the showing one: of 23 CG-plausible windows, 22 were listed by AX and the
    // only exception was Chrome's dismissed omnibox popup.
    @Test("AX silence about a window on the showing desktop contradicts it")
    func accessibilitySilenceOnShowingDesktopIsAVerdict() {
        // Chrome 17776, 1541x89, desktop 3 while desktop 3 showed; Chrome answered with 2 windows.
        #expect(AccessibilityWindowService.accessibilityContradictsWindow(
            windowDesktop: 3, showingDesktop: 3, appAXAnswerCoversShowingDesktop: true
        ))
        // Phoenix Slides explicitly names 31426 but gives its subrole as AXUnknown. The
        // classification is inconclusive, but it is not AX silence and cannot contradict the
        // same window AX just returned.
        #expect(!AccessibilityWindowService.accessibilityContradictsWindow(
            isNamedByAX: true,
            windowDesktop: 3,
            showingDesktop: 3,
            appAXAnswerCoversShowingDesktop: true
        ))
    }

    @Test("AX silence is not a verdict when AX could not have seen the window")
    func accessibilitySilenceElsewhereIsNotAVerdict() {
        // Dia 4794 really is on desktop 0; Dia reports exactly one AX window, the showing one.
        #expect(!AccessibilityWindowService.accessibilityContradictsWindow(
            windowDesktop: 0, showingDesktop: 3, appAXAnswerCoversShowingDesktop: true
        ))
        // An app AX answers nothing for cannot contradict anything, or every one of its
        // windows would be refused at once.
        #expect(!AccessibilityWindowService.accessibilityContradictsWindow(
            windowDesktop: 3, showingDesktop: 3, appAXAnswerCoversShowingDesktop: false
        ))
        // All-Spaces and fullscreen windows resolve to no desktop, so there is no moment at
        // which AX is known to have been able to see them.
        #expect(!AccessibilityWindowService.accessibilityContradictsWindow(
            windowDesktop: nil, showingDesktop: 3, appAXAnswerCoversShowingDesktop: true
        ))
        #expect(!AccessibilityWindowService.accessibilityContradictsWindow(
            windowDesktop: 3, showingDesktop: nil, appAXAnswerCoversShowingDesktop: true
        ))
    }

    // Debut samples on activeSpaceDidChangeNotification, when the window server has switched
    // but `kAXWindows` has not. KHA-582 shipped without this and parked two genuine windows —
    // Notion 182 and Ghostty 78 — on the transition into their own desktop, while an audit a
    // second later showed AX naming both. Whether AX answered is not the question; whether its
    // answer describes the desktop now showing is.
    @Test("An AX answer that names only another desktop cannot contradict anything")
    func laggingAXAnswerCorroboratesNothing() {
        // Ghostty pid 653 settled on desktop 0: AX names 78, which SkyLight puts on desktop 0.
        #expect(AccessibilityWindowService.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: [653: [78]],
            windowDesktops: [78: 0, 45: 3, 79: 1],
            showingDesktop: 0
        ) == [653])

        // The same app one moment earlier, its AX answer still describing desktop 3.
        #expect(AccessibilityWindowService.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: [653: [45]],
            windowDesktops: [78: 0, 45: 3, 79: 1],
            showingDesktop: 0
        ).isEmpty)
    }

    @Test("A corroborated AX answer still contradicts the ghost it declines to name")
    func corroboratedAXAnswerStillContradicts() {
        // Chrome pid 89895 on desktop 3 named 17774 and 18191, both on desktop 3, and declined
        // to name the dismissed omnibox popup 17776, which is on desktop 3 too.
        #expect(AccessibilityWindowService.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: [89895: [17774, 18191]],
            windowDesktops: [17774: 3, 18191: 3, 17776: 3],
            showingDesktop: 3
        ) == [89895])
    }

    @Test("With no showing desktop no AX answer corroborates")
    func noShowingDesktopCorroboratesNothing() {
        #expect(AccessibilityWindowService.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: [653: [78]],
            windowDesktops: [78: 0],
            showingDesktop: nil
        ).isEmpty)
        // A window AX named that SkyLight places nowhere says nothing about the showing desktop.
        #expect(AccessibilityWindowService.appPIDsWhoseAXAnswerCoversShowingDesktop(
            axWindowIDsByPID: [653: [78]],
            windowDesktops: [:],
            showingDesktop: 0
        ).isEmpty)
    }

    @Test("A contradiction outlives the desktop that produced it")
    func contradictionIsRememberedAcrossDesktops() {
        var registry = AXContradictionRegistry()
        registry.record(windowID: 17776, owner: 89895, bundleID: "com.google.Chrome")
        // AX can only contradict from the window's own desktop, so a verdict that expired
        // when the user switched away would be re-admitted on the very next snapshot.
        #expect(registry.refuses(windowID: 17776, owner: 89895))
    }

    @Test("A remembered contradiction clears the moment AX names the window")
    func contradictionSelfHealsWhenAXCatchesUp() {
        var registry = AXContradictionRegistry()
        registry.record(windowID: 17776, owner: 89895, bundleID: "com.google.Chrome")
        registry.clear(windowIDs: [17776])
        #expect(!registry.refuses(windowID: 17776, owner: 89895))
    }

    @Test("A recycled window ID does not inherit the previous owner's contradiction")
    func contradictionIsKeyedToItsOwner() {
        var registry = AXContradictionRegistry()
        registry.record(windowID: 17776, owner: 89895, bundleID: "com.google.Chrome")
        #expect(!registry.refuses(windowID: 17776, owner: 90001))
        // Chrome exiting takes its verdicts with it.
        registry.retainOnly(owners: [90001])
        #expect(!registry.refuses(windowID: 17776, owner: 89895))
    }

    // The verdict has to be at least as durable as the assignment it overrules. Chrome's
    // omnibox ghost 17776 was parked at 18:25:07 and restored by the next launch's startup
    // reconcile at 18:37:05, because AX can only contradict a window while its own desktop is
    // showing and that is rarely the desktop Debut launches onto.
    @Test("A contradiction survives a Debut restart while its owner keeps running")
    func contradictionSurvivesARestart() {
        var registry = AXContradictionRegistry()
        registry.record(windowID: 17776, owner: 89895, bundleID: "com.google.Chrome")
        let restored = AXContradictionRegistry(
            records: registry.records,
            runningBundleIDsByPID: [89895: "com.google.Chrome"]
        )
        #expect(restored.refuses(windowID: 17776, owner: 89895))
    }

    @Test("A restored contradiction is discarded unless the same process still owns it")
    func restoredContradictionRequiresTheSameProcess() {
        var registry = AXContradictionRegistry()
        registry.record(windowID: 17776, owner: 89895, bundleID: "com.google.Chrome")
        // macOS reissues PIDs from low numbers on every relaunch, so the number alone does not
        // identify the owner and a stale verdict would refuse a stranger's real window.
        #expect(!AXContradictionRegistry(
            records: registry.records,
            runningBundleIDsByPID: [89895: "com.apple.Preview"]
        ).refuses(windowID: 17776, owner: 89895))
        #expect(!AXContradictionRegistry(
            records: registry.records,
            runningBundleIDsByPID: [:]
        ).refuses(windowID: 17776, owner: 89895))
    }

    @Test("Disabled live previews neither enumerate nor capture")
    func disabledLivePreviewsAvoidCapture() async {
        let service = AccessibilityWindowService(windowCaptureEnabled: false)
        let counter = CaptureCounter()
        let enumerations = CaptureCounter()

        await service.captureWindowImages(
            windowIDs: [kCGNullWindowID],
            onEnumerated: { _ in enumerations.increment() }
        ) { _ in
            counter.increment()
        }
        #expect(counter.value == 0)
        #expect(enumerations.value == 0)
    }

    @Test("Preview validation checks pixels rather than image presence")
    func previewValidationChecksPixelVariation() throws {
        let uniform = try #require(makeImage(bytes: [127, 127]))
        let varied = try #require(makeImage(bytes: [0, 255]))

        #expect(!WindowImageStatistics.hasVariedLuminance(uniform))
        #expect(WindowImageStatistics.hasVariedLuminance(varied))
    }

    /// A terminal sitting at a prompt puts content on well under 1% of its pixels. Validation
    /// runs on the downscaled capture, so it has to survive the downscale rather than rely on
    /// landing a sample on one of those pixels.
    @Test("Sparse window content survives preview validation", arguments: [
        (background: UInt8(255), ink: UInt8(0)),
        (background: UInt8(0), ink: UInt8(255)),
    ])
    func sparseContentSurvivesPreviewValidation(background: UInt8, ink: UInt8) throws {
        let sparse = try #require(makeSparseContentImage(
            width: 356,
            height: 640,
            background: background,
            ink: ink,
            inkRows: 2
        ))

        #expect(WindowImageStatistics.hasVariedLuminance(sparse))
    }

    @Test("A capture with no content at all is still rejected", arguments: [UInt8(0), 127, 255])
    func flatCaptureIsRejected(value: UInt8) throws {
        let flat = try #require(makeSparseContentImage(
            width: 356,
            height: 640,
            background: value,
            ink: value,
            inkRows: 0
        ))

        #expect(!WindowImageStatistics.hasVariedLuminance(flat))
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

    @Test("Close window records the targeted window")
    func closeWindow() {
        let svc = MockWindowService()
        #expect(svc.closeWindow(windowID: 202))
        #expect(svc.closedWindowIDs == [202])
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

    @Test("An oversized window is captured down to the preview cap")
    func capturePixelSizeIsCapped() {
        let size = PreviewCaptureSize.pixelSize(
            contentSize: CGSize(width: 2206, height: 1440),
            pointPixelScale: 2,
            maxPixelDimension: 640
        )

        #expect(size.width == 640)
        #expect(size.height == 418)
    }

    @Test("A window smaller than the cap is captured at native resolution")
    func smallCaptureKeepsNativeSize() {
        let size = PreviewCaptureSize.pixelSize(
            contentSize: CGSize(width: 300, height: 200),
            pointPixelScale: 1,
            maxPixelDimension: 640
        )

        #expect(size.width == 300)
        #expect(size.height == 200)
    }

    @Test("A degenerate window still yields a capturable size")
    func degenerateCaptureSizeStaysValid() {
        let size = PreviewCaptureSize.pixelSize(
            contentSize: CGSize(width: 0, height: 0),
            pointPixelScale: 2,
            maxPixelDimension: 640
        )

        #expect(size.width == 1)
        #expect(size.height == 1)
    }
}

private func makeImage(bytes: [UInt8]) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: bytes.count,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: bytes.count,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

/// A flat background carrying `inkRows` rows of thin, evenly spaced marks, standing in for
/// text near the top of an otherwise empty window.
private func makeSparseContentImage(
    width: Int,
    height: Int,
    background: UInt8,
    ink: UInt8,
    inkRows: Int
) -> CGImage? {
    var pixels = [UInt8](repeating: background, count: width * height)
    for row in 0..<inkRows {
        let top = 8 + row * 20
        for y in top..<min(top + 11, height) {
            for x in stride(from: 10, to: min(300, width), by: 9) {
                for glyphColumn in x..<min(x + 4, width) {
                    pixels[y * width + glyphColumn] = ink
                }
            }
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

private final class CaptureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

@Suite("Recent value cache")
struct RecentValueCacheTests {
    private final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        private var storedCalls = 0
        private var storedNanoseconds: UInt64 = 0
        var shouldFail = false
        var delaySeconds: Double = 0

        var calls: Int { lock.withLock { storedCalls } }
        var now: UInt64 { lock.withLock { storedNanoseconds } }
        func advance(milliseconds: UInt64) {
            lock.withLock { storedNanoseconds += milliseconds * 1_000_000 }
        }

        struct Failure: Error {}

        func load() async throws -> Int {
            let sequence = lock.withLock { () -> Int in
                storedCalls += 1
                return storedCalls
            }
            if delaySeconds > 0 { try? await Task.sleep(for: .seconds(delaySeconds)) }
            if shouldFail { throw Failure() }
            return sequence
        }
    }

    private func makeCache(_ loader: Loader, maximumAgeMilliseconds: UInt64 = 500) -> RecentValueCache<Int> {
        RecentValueCache(
            maximumAgeNanoseconds: maximumAgeMilliseconds * 1_000_000,
            now: { loader.now },
            load: { try await loader.load() }
        )
    }

    @Test("Callers that arrive during a load join it instead of starting another")
    func concurrentCallersShareOneLoad() async throws {
        // The wallpaper capture and the window previews both need the shareable
        // content at the same instant of a presentation, and the enumeration
        // costs tens of milliseconds no matter who asks for it.
        let loader = Loader()
        loader.delaySeconds = 0.05
        let cache = makeCache(loader)

        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await cache.value() } }
            var collected: [Int] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(loader.calls == 1)
        #expect(values == [1, 1, 1, 1, 1])
    }

    @Test("A value older than the maximum age is loaded again")
    func staleValueIsReloaded() async throws {
        let loader = Loader()
        let cache = makeCache(loader, maximumAgeMilliseconds: 500)

        #expect(try await cache.value() == 1)
        loader.advance(milliseconds: 100)
        #expect(try await cache.value() == 1)
        loader.advance(milliseconds: 500)
        #expect(try await cache.value() == 2)
        #expect(loader.calls == 2)
    }

    @Test("A failed load is not cached")
    func failedLoadIsNotCached() async throws {
        let loader = Loader()
        loader.shouldFail = true
        let cache = makeCache(loader)

        await #expect(throws: Loader.Failure.self) { try await cache.value() }
        loader.shouldFail = false
        #expect(try await cache.value() == 2)
    }
}
