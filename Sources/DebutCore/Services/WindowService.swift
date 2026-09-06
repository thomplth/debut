import CoreGraphics

public struct WindowInfo: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerBundleID: String
    public let ownerName: String
    public let ownerPID: pid_t
    public let title: String
    public let bounds: CGRect
    public let isOnScreen: Bool

    public init(windowID: CGWindowID, ownerBundleID: String, ownerName: String, ownerPID: pid_t, title: String, bounds: CGRect, isOnScreen: Bool) {
        self.windowID = windowID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
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

public protocol WindowService: Sendable {
    func listRunningApps() -> [AppInfo]
    func listWindows() -> [WindowInfo]
    func listUntrackableWindowIDs() -> Set<CGWindowID>
    /// Window IDs Core Graphics positively contradicts being user-manageable windows,
    /// which is a stronger claim than merely failing `listWindows()` admission.
    func listDisqualifiedWindowIDs() -> Set<CGWindowID>
    /// Window IDs Accessibility positively contradicts, by enumerating their app while their
    /// own desktop was showing and declining to name them. Kept separate from the Core Graphics
    /// verdict because it is only ever available for the desktop currently on screen.
    func listAXContradictedWindowIDs() -> Set<CGWindowID>
    /// Window IDs the window server attaches to another window — sheets, and the popups an app
    /// raises over one of its own windows. A third channel because it is the only verdict
    /// readable from any desktop without an Accessibility element.
    func listParentedWindowIDs() -> Set<CGWindowID>
    func listAllWindowIDs() -> Set<CGWindowID>?
    /// `onEnumerated` reports which requested windows the shareable-content
    /// snapshot actually matched, before any of them is captured. Without it a
    /// caller cannot tell the shared enumeration wait apart from capture time.
    func captureWindowImages(
        windowIDs: [CGWindowID],
        onEnumerated: @escaping @Sendable ([CGWindowID]) -> Void,
        onCapture: @escaping @Sendable (WindowImageCapture) -> Void
    ) async
    func raiseWindow(windowID: CGWindowID) -> Bool
    /// Performs the target window's accessibility close action when the app exposes one.
    func closeWindow(windowID: CGWindowID) -> Bool
    /// Makes one window's process frontmost through the window server, naming the window so the
    /// chosen one arrives in front rather than whichever the app last used.
    ///
    /// Returns whether the window server took the request. Prefer this over `activateApp`:
    /// AppKit's activation is advisory from macOS 14 and is declined outright for a background
    /// regular application, which Debut is whenever its Dock icon is on.
    func frontWindow(windowID: CGWindowID, ownerPID: pid_t) -> Bool
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
    func listUntrackableWindowIDs() -> Set<CGWindowID> { [] }
    func listDisqualifiedWindowIDs() -> Set<CGWindowID> { [] }
    func listAXContradictedWindowIDs() -> Set<CGWindowID> { [] }
    func listParentedWindowIDs() -> Set<CGWindowID> { [] }
    func closeWindow(windowID: CGWindowID) -> Bool { false }
    func frontmostApplicationPID() -> pid_t? { nil }
}
