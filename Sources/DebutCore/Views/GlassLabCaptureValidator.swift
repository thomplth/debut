import CoreGraphics

public enum GlassLabCaptureValidator {
    public static func containsVisibleContent(_ image: CGImage) -> Bool {
        let width = min(image.width, 64)
        let height = min(image.height, 64)
        guard width > 0, height > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered, let first = pixels.first else { return false }
        return pixels.contains { abs(Int($0) - Int(first)) > 1 }
    }
}
