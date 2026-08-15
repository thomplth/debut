import AppKit
import ScreenCaptureKit

/// What prompted a wallpaper refresh. Recorded in diagnostics so a stale surface can be
/// traced to a missing trigger rather than a bad capture.
enum WallpaperRefreshReason: String, Sendable {
    case initial
    case presentation
    case wallpaperNotification
    case spaceChanged
    case screenParameters
}

/// The result of one refresh, including how bright the capture actually was.
///
/// Luminance is reported because a non-nil image is not evidence of a wallpaper: macOS 15
/// obsoleted `CGWindowListCreateImageFromArray` into returning a blank-but-non-nil frame, and a
/// nil check reported that black rectangle as a success.
struct WallpaperCaptureOutcome: Sendable {
    let loaded: Bool
    let reason: WallpaperRefreshReason
    let meanLuminance: Double?
    let failure: String?
}

enum WallpaperImageStatistics {
    /// Average brightness in 0...1, measured from a tiny downsample so this stays cheap enough
    /// to run on every capture of a 6K display.
    static func meanLuminance(of image: CGImage, sampleSize: Int = 16) -> Double? {
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        return pixels.withUnsafeMutableBytes { buffer -> Double? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: sampleSize,
                      height: sampleSize,
                      bitsPerComponent: 8,
                      bytesPerRow: sampleSize * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

            let bytes = buffer.bindMemory(to: UInt8.self)
            var total = 0.0
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                total += (Double(bytes[pixel]) + Double(bytes[pixel + 1]) + Double(bytes[pixel + 2])) / 3
            }
            return total / Double(sampleSize * sampleSize) / 255
        }
    }
}

enum WallpaperCaptureError: Error, CustomStringConvertible {
    case displayUnavailable(CGDirectDisplayID)
    case captureFailed(
        underlying: Error,
        contentRect: CGRect,
        pixelSize: CGSize,
        hasPermission: Bool,
        shareableWindows: Int
    )

    var description: String {
        switch self {
        case let .displayUnavailable(displayID):
            return "displayUnavailable(\(displayID))"
        case let .captureFailed(underlying, contentRect, pixelSize, hasPermission, shareableWindows):
            return "captureFailed(content: \(contentRect.width)x\(contentRect.height), "
                + "requested: \(Int(pixelSize.width))x\(Int(pixelSize.height)), "
                + "permission: \(hasPermission), shareableWindows: \(shareableWindows), \(underlying))"
        }
    }
}

/// Deliberately not main-actor isolated. The surface refreshes while the overlay
/// is being presented, so isolating the capture would put ScreenCaptureKit's
/// enumeration and screenshot IPC in the same queue as the overlay's own render
/// work. Only the resulting image assignment needs the main actor.
protocol DesktopWallpaperCapturing: AnyObject, Sendable {
    func captureWallpaper(displayID: CGDirectDisplayID, pixelSize: CGSize) async throws -> CGImage
}

/// Reads the pixels macOS already rendered for the wallpaper.
///
/// Resolving the wallpaper from its stored configuration does not work on macOS 14 and later:
/// providers such as `com.apple.NeptuneOneExtension` and `com.apple.wallpaper.extension.photos`
/// describe how to generate an image rather than where to find one, and expose no file at all.
///
/// The `CGWindowListCreateImage` family cannot read it either — macOS 15 obsoleted those calls,
/// and they now hand back a blank frame rather than failing.
final class SystemDesktopWallpaperCapture: DesktopWallpaperCapturing {
    func captureWallpaper(displayID: CGDirectDisplayID, pixelSize: CGSize) async throws -> CGImage {
        // Desktop windows are left out of this list on purpose: they are the wallpaper. Excluding
        // them below would leave the filter with nothing to composite. The shared snapshot also
        // carries off-screen windows, which cost nothing to exclude because they composite nothing.
        let content = try await ShareableContent.shared.value().content
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw WallpaperCaptureError.displayUnavailable(displayID)
        }

        // Excluding every non-desktop window leaves only the wallpaper. Anything a user would
        // recognise as UI is one of these windows — desktop icons belong to Finder, the menu bar
        // and Dock to Dock — so this drops all of them, Debut's own surface included.
        let filter = SCContentFilter(display: display, excludingWindows: content.windows)
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = false
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw WallpaperCaptureError.captureFailed(
                underlying: error,
                contentRect: filter.contentRect,
                pixelSize: pixelSize,
                hasPermission: CGPreflightScreenCaptureAccess(),
                shareableWindows: content.windows.count
            )
        }
    }
}

@MainActor
protocol DesktopWallpaperChangeObserving: AnyObject {
    func start(handler: @escaping @MainActor @Sendable (WallpaperRefreshReason) -> Void)
}

/// Refreshes a surface that is already visible when the wallpaper or Space changes behind it.
///
/// The `com.apple.desktop` distributed notification is dead — it posts nothing on current macOS.
/// What still moves is the wallpaper store: the system rewrites it on every change, so watching
/// that directory keeps this event-driven with no polling. Dynamic wallpapers that drift with the
/// time of day rewrite nothing, which is why presentation also recaptures.
@MainActor
final class SystemDesktopWallpaperChangeObserver: DesktopWallpaperChangeObserving {
    static let defaultStoreURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store")

    /// Measured on macOS 26: a single change writes the store three times, up to 1.3s apart, and
    /// the new wallpaper is not composited until ~0.3s after the final write. Waiting for the
    /// store to go quiet for longer than that largest gap puts the capture safely past the point
    /// where the old wallpaper has been torn down and the new one drawn.
    static let defaultSettleDelay = Duration.seconds(2)

    private let storeURL: URL
    private let settleDelay: Duration
    private var settleTask: Task<Void, Never>?
    nonisolated(unsafe) private var activeSpaceToken: NSObjectProtocol?
    nonisolated(unsafe) private var storeSource: DispatchSourceFileSystemObject?

    init(
        storeURL: URL = SystemDesktopWallpaperChangeObserver.defaultStoreURL,
        settleDelay: Duration = SystemDesktopWallpaperChangeObserver.defaultSettleDelay
    ) {
        self.storeURL = storeURL
        self.settleDelay = settleDelay
    }

    func start(handler: @escaping @MainActor @Sendable (WallpaperRefreshReason) -> Void) {
        guard activeSpaceToken == nil, storeSource == nil else { return }

        activeSpaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in handler(.spaceChanged) }
        }

        // The store's plist is replaced rather than edited, so a descriptor on the file itself
        // would go stale after the first change. Watch the containing directory instead.
        let descriptor = open(storeURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleSettledReport(handler: handler) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        storeSource = source
    }

    /// Restarts the wait on every write, so a run of writes yields one report once they stop.
    private func scheduleSettledReport(
        handler: @escaping @MainActor @Sendable (WallpaperRefreshReason) -> Void
    ) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: settleDelay)
            } catch {
                return
            }
            handler(.wallpaperNotification)
        }
    }

    deinit {
        if let activeSpaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceToken)
        }
        storeSource?.cancel()
        settleTask?.cancel()
    }
}

@MainActor
final class DesktopWallpaperView: NSView {
    var onFileDragEntered: @MainActor () -> Void = {}
    private var fileDragRevealRequested = false

    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        prepareForDrop(types: sender.draggingPasteboard.types)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fileDragRevealRequested = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // The surface yields during draggingEntered so Finder handles the actual drop.
        false
    }

    func prepareForDrop(types: [NSPasteboard.PasteboardType]?) -> NSDragOperation {
        guard types?.contains(.fileURL) == true else { return [] }
        if !fileDragRevealRequested {
            fileDragRevealRequested = true
            onFileDragEntered()
        }
        return .copy
    }

    func resetFileDrag() {
        fileDragRevealRequested = false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        // The capture already matches this display's aspect ratio and native pixel size, so
        // macOS has applied the user's fill-versus-fit choice for us.
        context.draw(image, in: bounds)
    }
}

/// A full-screen window that mirrors one display's wallpaper and sits between active and
/// inactive stage windows in z-order. Active windows are raised above it; inactive windows are
/// occluded behind it without position or minimize manipulation.
public final class DesktopSurfaceWindow: NSWindow {
    let wallpaperView = DesktopWallpaperView()
    private let displayID: CGDirectDisplayID
    private let wallpaperCapture: DesktopWallpaperCapturing
    private let wallpaperChangeObserver: DesktopWallpaperChangeObserving
    private let onWallpaperRefreshed: @MainActor (WallpaperCaptureOutcome) -> Void
    private var captureTask: Task<Void, Never>?
    nonisolated(unsafe) private var wallpaperLoaded = false
    nonisolated(unsafe) private var wallpaperCapturePending = false

    public convenience init(
        screen: NSScreen,
        onFileDragEntered: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            screen: screen,
            wallpaperCapture: SystemDesktopWallpaperCapture(),
            wallpaperChangeObserver: SystemDesktopWallpaperChangeObserver(),
            onWallpaperRefreshed: { outcome in
                var details = [
                    "loaded": "\(outcome.loaded)",
                    "reason": outcome.reason.rawValue,
                ]
                if let luminance = outcome.meanLuminance {
                    details["meanLuminance"] = String(format: "%.4f", luminance)
                }
                if let failure = outcome.failure {
                    details["failure"] = failure
                }
                DiagnosticReporter.shared.report(
                    "desktop_wallpaper_refreshed",
                    level: .lifecycle,
                    details: details
                )
            },
            onFileDragEntered: onFileDragEntered
        )
    }

    init(
        screen: NSScreen,
        wallpaperCapture: DesktopWallpaperCapturing,
        wallpaperChangeObserver: DesktopWallpaperChangeObserving,
        onWallpaperRefreshed: @escaping @MainActor (WallpaperCaptureOutcome) -> Void = { _ in },
        onFileDragEntered: @escaping @MainActor () -> Void = {}
    ) {
        self.displayID = screen.displayID
        self.wallpaperCapture = wallpaperCapture
        self.wallpaperChangeObserver = wallpaperChangeObserver
        self.onWallpaperRefreshed = onWallpaperRefreshed
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        level = .normal
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        collectionBehavior = [.transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        contentView = wallpaperView
        wallpaperView.onFileDragEntered = onFileDragEntered
        wallpaperView.registerForDraggedTypes([.fileURL])

        wallpaperChangeObserver.start { [weak self] reason in
            self?.refreshWallpaper(reason: reason)
        }
        refreshWallpaper(reason: .initial)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    public override func mouseDown(with event: NSEvent) {}

    func prepareForDrop(types: [NSPasteboard.PasteboardType]?) -> NSDragOperation {
        wallpaperView.prepareForDrop(types: types)
    }

    /// Bring the surface to front, covering all inactive windows.
    /// Call this before raising active stage windows.
    public func orderToFront() {
        wallpaperView.resetFileDrag()
        refreshWallpaper(reason: .presentation)
        orderFront(nil)
    }

    public func updateFrame(_ frame: CGRect) {
        setFrame(frame, display: true)
        refreshWallpaper(reason: .screenParameters)
    }

    public func dismiss() {
        captureTask?.cancel()
        orderOut(nil)
        close()
    }

    nonisolated var overlayWallpaperState: OverlayWallpaperState {
        if wallpaperCapturePending { return .capturePending }
        return wallpaperLoaded ? .ready : .unavailable
    }

    func refreshWallpaper(
        reason: WallpaperRefreshReason,
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        captureTask?.cancel()
        wallpaperCapturePending = true
        captureTask = Task { @MainActor [weak self] in
            await self?.performRefresh(
                reason: reason,
                overlayPresentation: overlayPresentation
            )
        }
    }

    func awaitPendingRefresh() async {
        await captureTask?.value
    }

    private func performRefresh(
        reason: WallpaperRefreshReason,
        overlayPresentation: OverlayPresentationContext?
    ) async {
        let scale = NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 1
        let pixelSize = CGSize(width: frame.width * scale, height: frame.height * scale)

        let performanceID = PerformanceRecorder.shared.begin(
            .wallpaperCapture,
            workload: .init(captures: 1),
            traceID: overlayPresentation?.traceID
        )
        defer { PerformanceRecorder.shared.end(performanceID) }
        do {
            let image = try await wallpaperCapture.captureWallpaper(
                displayID: displayID,
                pixelSize: pixelSize
            )
            guard !Task.isCancelled else { return }
            wallpaperView.image = image
            wallpaperLoaded = true
            wallpaperCapturePending = false
            if let overlayPresentation {
                OverlayPresentationRecorder.shared.mark(
                    .wallpaperCompleted,
                    for: overlayPresentation
                )
            }
            onWallpaperRefreshed(
                WallpaperCaptureOutcome(
                    loaded: true,
                    reason: reason,
                    meanLuminance: WallpaperImageStatistics.meanLuminance(of: image),
                    failure: nil
                )
            )
        } catch {
            guard !Task.isCancelled else { return }
            wallpaperCapturePending = false
            if let overlayPresentation {
                OverlayPresentationRecorder.shared.mark(
                    .wallpaperCompleted,
                    for: overlayPresentation
                )
            }
            // Keep whatever was last captured. Clearing here would flash the surface black on a
            // transient failure, which is the very symptom this window exists to avoid.
            onWallpaperRefreshed(
                WallpaperCaptureOutcome(
                    loaded: false,
                    reason: reason,
                    meanLuminance: nil,
                    failure: "\(error)"
                )
            )
        }
    }
}

public struct DesktopScreenDescriptor: Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect

    public init(displayID: CGDirectDisplayID, frame: CGRect) {
        self.displayID = displayID
        self.frame = frame
    }
}

/// Which surfaces to create, drop, and re-frame for a set of connected displays.
public struct DesktopSurfacePlan: Equatable, Sendable {
    public var added: [DesktopScreenDescriptor] = []
    public var removed: [CGDirectDisplayID] = []
    public var reframed: [DesktopScreenDescriptor] = []

    /// A display already carrying a surface is only re-framed when its geometry actually moved,
    /// so an unrelated display change does not force every screen to recapture.
    public static func plan(
        existing: [CGDirectDisplayID: CGRect],
        screens: [DesktopScreenDescriptor]
    ) -> DesktopSurfacePlan {
        var plan = DesktopSurfacePlan()
        let connected = Set(screens.map(\.displayID))
        plan.removed = existing.keys.filter { !connected.contains($0) }.sorted()
        for descriptor in screens {
            if let frame = existing[descriptor.displayID] {
                if frame != descriptor.frame { plan.reframed.append(descriptor) }
            } else {
                plan.added.append(descriptor)
            }
        }
        return plan
    }
}

/// Owns one surface per connected display so inactive windows are occluded on every screen.
public final class DesktopSurfaceCoordinator {
    private var surfaces: [CGDirectDisplayID: DesktopSurfaceWindow] = [:]
    private var surfaceFrames: [CGDirectDisplayID: CGRect] = [:]
    private var screenParametersToken: NSObjectProtocol?
    private let onFileDragEntered: @MainActor () -> Void

    public init(onFileDragEntered: @escaping @MainActor () -> Void = {}) {
        self.onFileDragEntered = onFileDragEntered
        screenParametersToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileConnectedScreens()
        }
        reconcileConnectedScreens()
    }

    deinit {
        if let screenParametersToken {
            NotificationCenter.default.removeObserver(screenParametersToken)
        }
    }

    public func reconcileConnectedScreens() {
        let screens = NSScreen.screens.map {
            DesktopScreenDescriptor(displayID: $0.displayID, frame: $0.frame)
        }
        let plan = DesktopSurfacePlan.plan(existing: surfaceFrames, screens: screens)

        for displayID in plan.removed {
            surfaces.removeValue(forKey: displayID)?.dismiss()
            surfaceFrames[displayID] = nil
        }
        for descriptor in plan.reframed {
            surfaces[descriptor.displayID]?.updateFrame(descriptor.frame)
            surfaceFrames[descriptor.displayID] = descriptor.frame
        }
        for descriptor in plan.added {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == descriptor.displayID })
            else { continue }
            surfaces[descriptor.displayID] = DesktopSurfaceWindow(
                screen: screen,
                onFileDragEntered: onFileDragEntered
            )
            surfaceFrames[descriptor.displayID] = descriptor.frame
        }
    }

    public func orderToFront() {
        for surface in surfaces.values {
            surface.orderToFront()
        }
    }

    public func orderOut() {
        for surface in surfaces.values {
            surface.dismiss()
        }
    }

    public var overlayWallpaperState: OverlayWallpaperState {
        guard !surfaces.isEmpty else { return .unavailable }
        let states = surfaces.values.map(\.overlayWallpaperState)
        if states.allSatisfy({ $0 == .ready }) { return .ready }
        if states.contains(.capturePending) { return .capturePending }
        return .unavailable
    }

    /// Recapture without reordering, for when an already-visible surface is about to be looked at.
    public func refreshWallpaper(
        overlayPresentation: OverlayPresentationContext? = nil
    ) {
        for surface in surfaces.values {
            surface.refreshWallpaper(
                reason: .presentation,
                overlayPresentation: overlayPresentation
            )
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
