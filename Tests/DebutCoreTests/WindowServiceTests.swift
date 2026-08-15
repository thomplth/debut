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
