import CoreGraphics

/// A bundleless exclusive-fullscreen process has no durable application identity. Keep its
/// window distinct during this run, then discard the assignment before persistence.
enum TransientWindowIdentity {
    private static let prefix = "com.thomplth.Debut.transient.bundleless."

    static func bundleID(for pid: pid_t) -> String { prefix + String(pid) }
    static func isTransient(_ bundleID: String) -> Bool { bundleID.hasPrefix(prefix) }
}

public struct WindowInfo: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public let ownerPID: pid_t
    public let title: String
    public let bounds: CGRect
    public let isOnScreen: Bool
    public let isTransientFullscreen: Bool

    public init(windowID: CGWindowID, ownerBundleID: String, ownerName: String, ownerPID: pid_t, title: String, bounds: CGRect, isOnScreen: Bool, isTransientFullscreen: Bool = false) {
        self.windowID = windowID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.isTransientFullscreen = isTransientFullscreen
    }
}

public struct AppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let pid: pid_t
    public let isHidden: Bool

    public init(bundleID: String, name: String, pid: pid_t, isHidden: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.isHidden = isHidden
    }
}

/// One visible surface in WindowServer's global front-to-back list. This is diagnostic evidence,
/// not the managed-window model: auxiliary surfaces and non-zero layers are kept deliberately so
/// a focus failure cannot hide behind the model's admission filters.
public struct WindowZOrderEntry: Sendable, Equatable {
    public let orderIndex: Int
    public let windowID: CGWindowID
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect
    public let title: String

    public init(
        orderIndex: Int,
        windowID: CGWindowID,
        layer: Int,
        alpha: Double,
        bounds: CGRect,
        title: String
    ) {
        self.orderIndex = orderIndex
        self.windowID = windowID
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
        self.title = title
    }
}

/// Independent answers to “which window is current?” captured at one focus-delivery boundary.
public struct WindowFocusObservation: Sendable, Equatable {
    public let frontmostApplicationPID: pid_t?
    public let axFocusedWindowID: CGWindowID?
    public let visibleWindows: [WindowZOrderEntry]

    public init(
        frontmostApplicationPID: pid_t?,
        axFocusedWindowID: CGWindowID?,
        visibleWindows: [WindowZOrderEntry]
    ) {
        self.frontmostApplicationPID = frontmostApplicationPID
        self.axFocusedWindowID = axFocusedWindowID
        self.visibleWindows = visibleWindows
    }

    public var frontmostLayerZeroWindowID: CGWindowID? {
        visibleWindows.first(where: { $0.layer == 0 })?.windowID
    }
}

/// The synchronous answers from every low-level step used to front and key a foreign window.
/// A zero status means the API accepted that step; none means its private symbol was unavailable
/// or an earlier prerequisite failed before the step could be attempted.
public struct FrontWindowDeliveryTrace: Sendable, Equatable {
    public let accepted: Bool
    public let processSerialNumberStatus: Int32?
    public let frontRequestStatus: Int32?
    public let keyWindowEventStatus: Int32?
    public let frontProcessSymbolResolved: Bool
    public let processSerialNumberSymbolResolved: Bool
    public let keyWindowEventSymbolResolved: Bool

    public init(
        accepted: Bool,
        processSerialNumberStatus: Int32?,
        frontRequestStatus: Int32?,
        keyWindowEventStatus: Int32?,
        frontProcessSymbolResolved: Bool,
        processSerialNumberSymbolResolved: Bool,
        keyWindowEventSymbolResolved: Bool
    ) {
        self.accepted = accepted
        self.processSerialNumberStatus = processSerialNumberStatus
        self.frontRequestStatus = frontRequestStatus
        self.keyWindowEventStatus = keyWindowEventStatus
        self.frontProcessSymbolResolved = frontProcessSymbolResolved
        self.processSerialNumberSymbolResolved = processSerialNumberSymbolResolved
        self.keyWindowEventSymbolResolved = keyWindowEventSymbolResolved
    }
}

public struct WindowImageCapture: @unchecked Sendable {
    public let windowID: CGWindowID
    public let image: CGImage

    public init(windowID: CGWindowID, image: CGImage) {
        self.windowID = windowID
        self.image = image
    }
}

enum PreviewCaptureSize {
    /// Previews are drawn into thumbnails at most 160pt wide, so a native-resolution capture
    /// costs orders of magnitude more memory and render work than the overlay can use: a
    /// 4412x2880 capture is ~50MB on its own, and the cache holds one per window.
    static let maxPixelDimension = 640

    static func pixelSize(
        contentSize: CGSize,
        pointPixelScale: CGFloat,
        maxPixelDimension: Int = maxPixelDimension
    ) -> (width: Int, height: Int) {
        let nativeWidth = contentSize.width * pointPixelScale
        let nativeHeight = contentSize.height * pointPixelScale
        let longest = max(nativeWidth, nativeHeight)
        let scale = longest > CGFloat(maxPixelDimension) ? CGFloat(maxPixelDimension) / longest : 1
        return (
            width: max(1, Int(ceil(nativeWidth * scale))),
            height: max(1, Int(ceil(nativeHeight * scale)))
        )
    }
}

enum WindowImageStatistics {
    /// A cell has to be this opaque to count as window content, so that a capture the window
    /// painted nothing into cannot be read as a luminance.
    ///
    /// This threshold does far less than it looks like it should. A window's rounded corners are
    /// transparent in the source, but at a 16x16 analysis grid each cell averages hundreds of
    /// source pixels and the corner dilutes away: measured over 21 live windows, every one
    /// reported minimum alpha 249-255 and 256 of 256 cells opaque (Pages alone, 252). The filter
    /// therefore only separates the all-or-nothing case — a capture that came back wholly
    /// transparent, which does occur (2 of 23 windows in that same sample).
    private static let opaqueAlpha: UInt8 = 250

    /// How far a cell must sit from the median before it counts as differing from the background.
    /// Flat regions are not bit-exact once a capture has been through colour conversion and
    /// area-averaging, so this clears a little noise rather than reading any difference at all.
    private static let backgroundLuminanceDelta: UInt16 = 6

    /// How much of the frame has to differ from the background before the capture counts as
    /// holding content, as a fraction of the cells the window painted. A fraction rather than a
    /// count because it is a claim about area: content covers some of the window, whereas a blank
    /// one differs from its background only where its chrome is.
    ///
    /// Measured by dumping 25 live captures to disk and reading them against what the window
    /// actually looked like (2026-09-06). Blank windows scored 0, 0, 0, 2 and 4 varied cells of
    /// 256; the lowest genuine content scored 8, then 10, 64, 78 and up. 2% is 5.12 cells, near
    /// the geometric middle of that gap.
    private static let variedCellFraction = 0.02

    /// Whether a capture holds content, rather than a background and nothing else.
    ///
    /// This deliberately does not measure the luminance range. Range cannot separate the two
    /// classes at any threshold: the same 25 captures put blank Notion windows at range 15 and
    /// 24, *above* a real terminal sitting at a prompt at 35 — three traffic lights in one corner
    /// move the range as far as a screen of sparse text does. What differs is where the variance
    /// sits, which is why this counts cells instead.
    static func holdsContent(_ image: CGImage, sampleSize: Int = 16) -> Bool {
        let width = min(sampleSize, image.width)
        let height = min(sampleSize, image.height)
        guard width > 0, height > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }

            // Area-averaging, so every source pixel reaches a cell. Point sampling read 256
            // pixels of a capture that holds hundreds of thousands, and a terminal at a prompt
            // puts content on ~0.3% of them: the samples landed on content less than once on
            // average, and real windows were discarded as failed captures on a coin flip.
            //
            // `.medium` rather than `.high`: high-quality resampling overshoots across a
            // transparent-to-opaque step, and the ringing lands on cells that are themselves
            // fully opaque, so no alpha test can exclude it. That step is sharp in a synthetic
            // fixture and largely averaged away in a real capture, so this matters less in
            // practice than the table suggests — it is kept because `.high` can only ever spread
            // a difference into cells that hold none. Measured over a blank 356x640 with a 12pt
            // radius — luminance range across opaque cells, and the same measure for a window
            // carrying two sparse rows of text:
            //
            //     quality   blank(0)  blank(127)  blank(255)  sparse
            //     .high            0          12           6     108
            //     .medium          0           0           0     213
            //     .low             0           0           0       0
            //     .none            0           0           0       0
            //
            // `.high` cannot separate a blank grey window from content; `.low` and `.none` fall
            // back to point sampling and cannot see the text at all. Only `.medium` does both.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = buffer.bindMemory(to: UInt8.self)
            var luminances: [UInt16] = []
            luminances.reserveCapacity(width * height)
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                guard bytes[pixel + 3] >= opaqueAlpha else { continue }
                luminances.append(
                    UInt16(bytes[pixel]) + UInt16(bytes[pixel + 1]) + UInt16(bytes[pixel + 2])
                )
            }
            // A capture the window painted nothing into is as empty as a flat one.
            guard !luminances.isEmpty else { return false }

            // The median, not the mean: the background is whatever most of the frame is, and a
            // mean is pulled toward the very content being looked for.
            let background = luminances.sorted()[luminances.count / 2]
            let varied = luminances.count {
                (background > $0 ? background - $0 : $0 - background) > backgroundLuminanceDelta
            }
            return Double(varied) > Double(luminances.count) * variedCellFraction
        }
    }
}

/// Why a window is missing from `listWindows()`, as far as the window server can say without
/// asking the app. Only the final reasons are grounds for giving up on a new window.
public enum WindowListingRefusal: String, Sendable, CaseIterable {
    /// Core Graphics does not list the window, possibly not yet.
    case absent
    /// The window server attaches it to another window: a sheet or one of the app's popups.
    case parented
    /// It is drawn on a layer no application window uses.
    case nonApplicationLayer
    /// Listed, and refused on evidence that can still change, such as size or desktop.
    case unadmitted

    public var isFinal: Bool { self == .parented || self == .nonApplicationLayer }
}

public protocol WindowService: Sendable {
    func listRunningApps() -> [AppInfo]
    func listWindows() -> [WindowInfo]
    /// `listWindows()` limited to the given owners, asking only them over Accessibility. The
    /// admission rules are the same ones, so a window admitted here is admitted there.
    func listWindows(ownerPIDs: Set<pid_t>) -> [WindowInfo]
    /// The process Core Graphics says owns a window, without asking any app.
    func windowOwnerPID(windowID: CGWindowID) -> pid_t?
    /// Why a window `listWindows(ownerPIDs:)` left out was left out. Asks no app.
    func listingRefusal(windowID: CGWindowID) -> WindowListingRefusal
    func listUntrackableWindowIDs() -> Set<CGWindowID>
    /// Windows Core Graphics positively contradicts being user-manageable right now, with the
    /// reason — a stronger claim than merely failing `listWindows()` admission. Only some
    /// reasons are grounds for parking a window that is already assigned.
    func listDisqualifiedWindows() -> [CGWindowID: WindowDisqualification]
    /// Window IDs Accessibility positively contradicts, by enumerating their app while their
    /// own desktop was showing and declining to name them. Kept separate from the Core Graphics
    /// verdict because it is only ever available for the desktop currently on screen.
    func listAXContradictedWindowIDs() -> Set<CGWindowID>
    /// What the window server says about the live surfaces: which it attaches to another window —
    /// sheets, and the popups an app raises over one of its own windows — and which it has ordered
    /// out for no reason the user would recognise. A separate channel because these are the only
    /// verdicts readable from any desktop without an Accessibility element.
    ///
    /// `orderedOut` here is already narrowed to ghosts: minimized windows and the windows of
    /// hidden apps have been removed, so every member is refusable on its own.
    func listWindowServerVerdicts() -> WindowServerVerdicts
    func listAllWindowIDs() -> Set<CGWindowID>?
    /// Runs `body` as one pass over a single Accessibility sweep. Every listing inside it that
    /// would classify all apps' AX windows reuses the first classification taken in the pass,
    /// so a caller asking several questions of the same moment pays for one sweep, not one each.
    func withSharedAccessibilitySweep<T>(_ body: () -> T) -> T
    /// `onEnumerated` reports which requested windows the shareable-content
    /// snapshot actually matched, before any of them is captured. Without it a
    /// caller cannot tell the shared enumeration wait apart from capture time.
    func captureWindowImages(
        windowIDs: [CGWindowID],
        onEnumerated: @escaping @Sendable ([CGWindowID]) -> Void,
        onCapture: @escaping @Sendable (WindowImageCapture) -> Void
    ) async
    func raiseWindow(windowID: CGWindowID) -> Bool
    /// Raises the window only through an element already held for it, and never searches for
    /// one. For a window on a desktop that is not showing, a search cannot find it anyway.
    func raiseTrackedWindow(windowID: CGWindowID) -> Bool
    /// Raises without holding the caller. An Accessibility message waits for the owning app, and
    /// an app that was just fronted answers only after its own activation work, which held the
    /// main queue — and the switcher's fade queued behind it — for up to 577ms (KHA-856).
    /// `completion` may run on any queue.
    func raiseWindowDeferred(windowID: CGWindowID, completion: @escaping @Sendable (Bool) -> Void)
    /// Performs the target window's accessibility close action when the app exposes one.
    func closeWindow(windowID: CGWindowID) -> Bool
    /// Makes one window's process frontmost through the window server, naming the window so the
    /// chosen one arrives in front rather than whichever the app last used.
    ///
    /// Returns whether the window server took the request. Prefer this over `activateApp`:
    /// AppKit's activation is advisory from macOS 14 and is declined outright for a background
    /// regular application, which Debut is whenever its Dock icon is on.
    func frontWindow(windowID: CGWindowID, ownerPID: pid_t) -> Bool
    /// Same operation as `frontWindow`, retaining the individual private-API results for a focus
    /// trace. The default preserves conformers that cannot expose those internal steps.
    func frontWindowWithTrace(
        windowID: CGWindowID,
        ownerPID: pid_t
    ) -> FrontWindowDeliveryTrace
    /// The first visible layer-zero window for this process in the window server's front-to-back
    /// order. Unlike Accessibility focus, this describes which app window is actually in front.
    func frontmostWindowID(ownerPID: pid_t) -> CGWindowID?
    /// Captures the independent process, AX focus, and complete visible z-order answers used to
    /// diagnose focus delivery. Call only after keyboard input has left the event-tap callback.
    func focusObservation(ownerPID: pid_t) -> WindowFocusObservation
    /// The process macOS currently shows as frontmost. `frontWindow` reports whether the window
    /// server accepted a request, never whether the app arrived, so this is the only way to find
    /// out that a switch did nothing.
    func frontmostApplicationPID() -> pid_t?
    /// Activates one exact running application instance. Window focus must prefer this over a
    /// bundle lookup because hosted foreground applications can own windows without having a
    /// bundle identifier of their own.
    func activateApp(pid: pid_t) -> Bool
    func activateApp(bundleID: String) -> Bool
    /// Addressed by PID, not bundle ID, so a second instance of the same app is not quit
    /// alongside the one the user selected.
    func terminateApp(pid: pid_t) -> Bool
    func isAccessibilityEnabled() -> Bool
}

public extension WindowService {
    func listWindows(ownerPIDs: Set<pid_t>) -> [WindowInfo] {
        listWindows().filter { ownerPIDs.contains($0.ownerPID) }
    }

    func windowOwnerPID(windowID: CGWindowID) -> pid_t? {
        listWindows().first { $0.windowID == windowID }?.ownerPID
    }

    func listingRefusal(windowID: CGWindowID) -> WindowListingRefusal { .unadmitted }

    func withSharedAccessibilitySweep<T>(_ body: () -> T) -> T { body() }

    /// Conformers that keep no elements have no cheaper path than their ordinary raise.
    func raiseTrackedWindow(windowID: CGWindowID) -> Bool {
        raiseWindow(windowID: windowID)
    }

    /// Conformers that make no cross-process call can answer before returning.
    func raiseWindowDeferred(
        windowID: CGWindowID,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        completion(raiseWindow(windowID: windowID))
    }

    func listUntrackableWindowIDs() -> Set<CGWindowID> { [] }
    func listDisqualifiedWindows() -> [CGWindowID: WindowDisqualification] { [:] }
    func listAXContradictedWindowIDs() -> Set<CGWindowID> { [] }
    func listWindowServerVerdicts() -> WindowServerVerdicts { WindowServerVerdicts() }
    func closeWindow(windowID: CGWindowID) -> Bool { false }
    func frontWindowWithTrace(
        windowID: CGWindowID,
        ownerPID: pid_t
    ) -> FrontWindowDeliveryTrace {
        FrontWindowDeliveryTrace(
            accepted: frontWindow(windowID: windowID, ownerPID: ownerPID),
            processSerialNumberStatus: nil,
            frontRequestStatus: nil,
            keyWindowEventStatus: nil,
            frontProcessSymbolResolved: false,
            processSerialNumberSymbolResolved: false,
            keyWindowEventSymbolResolved: false
        )
    }
    func frontmostWindowID(ownerPID: pid_t) -> CGWindowID? { nil }
    func focusObservation(ownerPID: pid_t) -> WindowFocusObservation {
        WindowFocusObservation(
            frontmostApplicationPID: frontmostApplicationPID(),
            axFocusedWindowID: nil,
            visibleWindows: []
        )
    }
    func frontmostApplicationPID() -> pid_t? { nil }
}

/// Why Core Graphics says a surface cannot be a user-manageable window right now.
public enum WindowDisqualification: String, Sendable {
    case nonApplicationLayer = "non_application_layer"
    case smallWidth = "small_width"
    case smallHeight = "small_height"

    /// A layer is a statement about what the surface is. A small frame is only its current
    /// presentation: Notion's inactive windows collapsed to 2x2 for 23 hours and came back
    /// unchanged (KHA-786). Both refuse a new window; only the layer parks an assigned one.
    public var evictsAssignedWindow: Bool { self == .nonApplicationLayer }
}
