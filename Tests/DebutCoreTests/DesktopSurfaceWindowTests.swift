import AppKit
import Testing
@testable import DebutCore

@Suite("Wallpaper image statistics")
struct WallpaperImageStatisticsTests {
    // A non-nil check cannot tell a real wallpaper from an empty buffer. macOS 15 obsoleted
    // CGWindowListCreateImageFromArray into returning a blank-but-non-nil image, which is exactly
    // how a black surface passed as a successful capture. These assert on pixels instead.
    @Test("An all-black capture reads as zero luminance")
    func blackImageHasZeroLuminance() throws {
        let image = try #require(makeImage(top: .black, bottom: .black))

        let luminance = try #require(WallpaperImageStatistics.meanLuminance(of: image))

        #expect(luminance < 0.01)
    }

    @Test("An all-white capture reads as full luminance")
    func whiteImageHasFullLuminance() throws {
        let image = try #require(makeImage(top: .white, bottom: .white))

        let luminance = try #require(WallpaperImageStatistics.meanLuminance(of: image))

        #expect(luminance > 0.99)
    }

    @Test("A half-lit capture reads as mid luminance")
    func halfLitImageHasMidLuminance() throws {
        let image = try #require(makeImage(top: .white, bottom: .black))

        let luminance = try #require(WallpaperImageStatistics.meanLuminance(of: image))

        #expect(luminance > 0.4)
        #expect(luminance < 0.6)
    }

    private enum Tone { case black, white }

    private func makeImage(top: Tone, bottom: Tone) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let value: (Tone) -> CGFloat = { $0 == .white ? 1 : 0 }
        context.setFillColor(CGColor(red: value(bottom), green: value(bottom), blue: value(bottom), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        context.setFillColor(CGColor(red: value(top), green: value(top), blue: value(top), alpha: 1))
        context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        return context.makeImage()
    }
}

@MainActor
@Suite("DesktopSurfaceWindow")
struct DesktopSurfaceWindowTests {
    @Test("Surface captures its own display at native pixel size")
    func surfaceCapturesItsOwnDisplay() async {
        let capture = TestWallpaperCapture()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = makeSurface(screen: screen, capture: capture)
        await window.awaitPendingRefresh()

        #expect(capture.requests.count == 1)
        #expect(capture.requests.first?.displayID == screen.displayID)
        #expect(
            capture.requests.first?.pixelSize == CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            )
        )
        #expect(window.wallpaperView.image != nil)
    }

    @Test("Presenting the surface recaptures so dynamic wallpapers stay current")
    func presentationRecapturesWallpaper() async {
        let capture = TestWallpaperCapture()
        let window = makeSurface(capture: capture)
        await window.awaitPendingRefresh()
        let first = window.wallpaperView.image

        capture.nextResult = .success(TestWallpaperCapture.makeImage(width: 4))
        window.refreshWallpaper(reason: .presentation)
        await window.awaitPendingRefresh()

        #expect(capture.requests.count == 2)
        #expect(window.wallpaperView.image !== first)
    }

    @Test("Wallpaper change notification refreshes the surface")
    func notificationRefreshesSurface() async {
        let capture = TestWallpaperCapture()
        let observer = TestWallpaperChangeObserver()
        let window = makeSurface(capture: capture, observer: observer)
        await window.awaitPendingRefresh()
        let first = window.wallpaperView.image

        capture.nextResult = .success(TestWallpaperCapture.makeImage(width: 8))
        observer.notifyChange()
        await window.awaitPendingRefresh()

        #expect(capture.requests.count == 2)
        #expect(window.wallpaperView.image !== first)
    }

    @Test("A Space change is reported separately from a wallpaper change")
    func spaceChangeIsDistinguishable() async {
        let recorder = OutcomeRecorder()
        let observer = TestWallpaperChangeObserver()
        let window = makeSurface(
            capture: TestWallpaperCapture(),
            observer: observer,
            onWallpaperRefreshed: { recorder.record($0) }
        )
        await window.awaitPendingRefresh()

        observer.notifyChange(reason: .wallpaperNotification)
        await window.awaitPendingRefresh()
        observer.notifyChange(reason: .spaceChanged)
        await window.awaitPendingRefresh()

        #expect(recorder.reasons == ["initial", "wallpaperNotification", "spaceChanged"])
    }

    @Test("A successful capture reports the luminance actually rendered")
    func refreshReportsCapturedLuminance() async throws {
        let recorder = OutcomeRecorder()
        let capture = TestWallpaperCapture()
        capture.nextResult = .success(TestWallpaperCapture.makeImage(width: 4, white: true))
        let window = makeSurface(capture: capture, onWallpaperRefreshed: { recorder.record($0) })
        await window.awaitPendingRefresh()

        let outcome = try #require(recorder.outcomes.first)
        #expect(outcome.loaded)
        #expect(outcome.failure == nil)
        #expect(try #require(outcome.meanLuminance) > 0.99)
    }

    @Test("A failed capture keeps the last good wallpaper instead of flashing black")
    func failedCaptureKeepsLastGoodImage() async throws {
        let recorder = OutcomeRecorder()
        let capture = TestWallpaperCapture()
        let window = makeSurface(capture: capture, onWallpaperRefreshed: { recorder.record($0) })
        await window.awaitPendingRefresh()
        let first = try #require(window.wallpaperView.image)

        capture.nextResult = .failure(TestWallpaperCapture.Failure.denied)
        window.refreshWallpaper(reason: .presentation)
        await window.awaitPendingRefresh()

        #expect(window.wallpaperView.image === first)
        let outcome = try #require(recorder.outcomes.last)
        #expect(!outcome.loaded)
        #expect(outcome.failure != nil)
    }

    @Test("Surface falls back to an opaque black fill when it has never captured")
    func surfaceFallsBackToBlack() async {
        let capture = TestWallpaperCapture()
        capture.nextResult = .failure(TestWallpaperCapture.Failure.denied)
        let window = makeSurface(capture: capture)
        await window.awaitPendingRefresh()

        #expect(window.wallpaperView.image == nil)
        #expect(window.wallpaperView.isOpaque)
        #expect(window.backgroundColor == .black)
    }

    @Test("The captured wallpaper renders upright rather than vertically flipped")
    func wallpaperRendersUpright() throws {
        // Core Graphics images are top-row-first while AppKit views draw bottom-up, so a
        // mismatch here would show the wallpaper upside down.
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        // In a y-up context the upper row is y == 1, which is the image's first row.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        let image = context.makeImage()!

        let view = DesktopWallpaperView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.image = image
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // NSBitmapImageRep indexes from the top-left corner in pixels, so sample by fraction
        // of the backing store rather than assuming a 1x scale.
        let x = rep.pixelsWide / 4
        let topLeft = try #require(rep.colorAt(x: x, y: rep.pixelsHigh / 4)?.usingColorSpace(.deviceRGB))
        let bottomLeft = try #require(rep.colorAt(x: x, y: rep.pixelsHigh * 3 / 4)?.usingColorSpace(.deviceRGB))
        #expect(topLeft.brightnessComponent > 0.9)
        #expect(bottomLeft.brightnessComponent < 0.1)
    }

    @Test("Desktop surface yields to Mission Control and App Exposé")
    func surfaceIsTransientInSystemWindowOverviews() {
        let window = makeSurface(capture: TestWallpaperCapture())

        #expect(window.collectionBehavior.contains(.transient))
        #expect(!window.collectionBehavior.contains(.stationary))
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
    }

    private func makeSurface(
        screen: NSScreen? = nil,
        capture: TestWallpaperCapture,
        observer: TestWallpaperChangeObserver = TestWallpaperChangeObserver(),
        onWallpaperRefreshed: @escaping @MainActor (WallpaperCaptureOutcome) -> Void = { _ in }
    ) -> DesktopSurfaceWindow {
        DesktopSurfaceWindow(
            screen: screen ?? NSScreen.main ?? NSScreen.screens[0],
            wallpaperCapture: capture,
            wallpaperChangeObserver: observer,
            onWallpaperRefreshed: onWallpaperRefreshed
        )
    }
}

@MainActor
@Suite("Wallpaper change observation")
struct WallpaperChangeObserverTests {
    // macOS no longer posts the com.apple.desktop distributed notification, so the store the
    // system rewrites on every wallpaper change is the signal that still works.
    @Test("Rewriting the wallpaper store reports a wallpaper change")
    func storeRewriteReportsWallpaperChange() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }

        let observer = SystemDesktopWallpaperChangeObserver(storeURL: store, settleDelay: .milliseconds(200))

        try await confirmation("wallpaper change reported", expectedCount: 1...) { reported in
            observer.start { reason in
                if reason == .wallpaperNotification { reported() }
            }
            // The system replaces Index.plist rather than editing in place, so the directory is
            // what has to be watched.
            try Data("x".utf8).write(to: store.appendingPathComponent("Index.plist"))
            try await Task.sleep(for: .milliseconds(900))
        }
    }

    // macOS writes the store several times per change and finishes announcing before it finishes
    // drawing, so every write must collapse into one capture taken after the store goes quiet.
    @Test("A run of store writes collapses into a single change report")
    func repeatedWritesReportOnceAfterSettling() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }

        let observer = SystemDesktopWallpaperChangeObserver(storeURL: store, settleDelay: .milliseconds(400))
        let recorder = ChangeCounter()
        observer.start { reason in
            if reason == .wallpaperNotification { recorder.increment() }
        }

        for index in 0..<4 {
            try Data("\(index)".utf8).write(to: store.appendingPathComponent("Index.plist"))
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .milliseconds(1200))

        #expect(recorder.count == 1)
    }
}

@MainActor
private final class ChangeCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("Desktop surface planning")
struct DesktopSurfacePlanTests {
    @Test("Every connected display gets its own surface")
    func oneSurfacePerDisplay() {
        let plan = DesktopSurfacePlan.plan(
            existing: [:],
            screens: [descriptor(1), descriptor(2, x: 2560)]
        )

        #expect(plan.added.map(\.displayID) == [1, 2])
        #expect(plan.removed.isEmpty)
        #expect(plan.reframed.isEmpty)
    }

    @Test("Adding a display leaves the existing surface untouched")
    func addingDisplayReusesExistingSurfaces() {
        let plan = DesktopSurfacePlan.plan(
            existing: [1: descriptor(1).frame],
            screens: [descriptor(1), descriptor(2, x: 2560)]
        )

        #expect(plan.added.map(\.displayID) == [2])
        #expect(plan.reframed.isEmpty)
        #expect(plan.removed.isEmpty)
    }

    @Test("A resized display re-frames its existing surface")
    func resizedDisplayIsReframed() {
        let resized = DesktopScreenDescriptor(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        let plan = DesktopSurfacePlan.plan(
            existing: [1: descriptor(1).frame],
            screens: [resized]
        )

        #expect(plan.reframed == [resized])
        #expect(plan.added.isEmpty)
        #expect(plan.removed.isEmpty)
    }

    @Test("Disconnecting a display removes only its surface")
    func disconnectedDisplayIsRemoved() {
        let plan = DesktopSurfacePlan.plan(
            existing: [1: descriptor(1).frame, 2: descriptor(2, x: 2560).frame],
            screens: [descriptor(1)]
        )

        #expect(plan.removed == [2])
        #expect(plan.added.isEmpty)
        #expect(plan.reframed.isEmpty)
    }

    @Test("An unrelated display change does not force other screens to recapture")
    func unchangedDisplaysAreLeftAlone() {
        let plan = DesktopSurfacePlan.plan(
            existing: [1: descriptor(1).frame],
            screens: [descriptor(1), descriptor(2, x: 2560)]
        )

        #expect(plan.reframed.isEmpty)
    }

    private func descriptor(
        _ displayID: CGDirectDisplayID,
        x: CGFloat = 0
    ) -> DesktopScreenDescriptor {
        DesktopScreenDescriptor(
            displayID: displayID,
            frame: CGRect(x: x, y: 0, width: 2560, height: 1440)
        )
    }
}

@MainActor
private final class OutcomeRecorder {
    private(set) var outcomes: [WallpaperCaptureOutcome] = []
    var reasons: [String] { outcomes.map(\.reason.rawValue) }

    func record(_ outcome: WallpaperCaptureOutcome) {
        outcomes.append(outcome)
    }
}

@MainActor
private final class TestWallpaperCapture: DesktopWallpaperCapturing {
    enum Failure: Error { case denied }

    struct Request {
        let displayID: CGDirectDisplayID
        let pixelSize: CGSize
    }

    var requests: [Request] = []
    var nextResult: Result<CGImage, Error> = .success(TestWallpaperCapture.makeImage(width: 2))

    func captureWallpaper(displayID: CGDirectDisplayID, pixelSize: CGSize) async throws -> CGImage {
        requests.append(Request(displayID: displayID, pixelSize: pixelSize))
        return try nextResult.get()
    }

    static func makeImage(width: Int, white: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if white {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        }
        return context.makeImage()!
    }
}

@MainActor
private final class TestWallpaperChangeObserver: DesktopWallpaperChangeObserving {
    private var handler: (@MainActor @Sendable (WallpaperRefreshReason) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (WallpaperRefreshReason) -> Void) {
        self.handler = handler
    }

    func notifyChange(reason: WallpaperRefreshReason = .wallpaperNotification) {
        handler?(reason)
    }
}
