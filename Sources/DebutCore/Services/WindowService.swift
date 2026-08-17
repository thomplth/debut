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
    static func hasVariedLuminance(_ image: CGImage, sampleSize: Int = 16) -> Bool {
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

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = buffer.bindMemory(to: UInt8.self)
            var minimum = UInt16.max
            var maximum = UInt16.min
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                let luminance = UInt16(bytes[pixel])
                    + UInt16(bytes[pixel + 1])
                    + UInt16(bytes[pixel + 2])
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
            return maximum > minimum
        }
    }
}

public protocol WindowService: Sendable {
    func listRunningApps() -> [AppInfo]
    func listWindows() -> [WindowInfo]
    func listUntrackableWindowIDs() -> Set<CGWindowID>
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
    func activateApp(bundleID: String) -> Bool
    func isAccessibilityEnabled() -> Bool
}

public extension WindowService {
    func listUntrackableWindowIDs() -> Set<CGWindowID> { [] }
}
