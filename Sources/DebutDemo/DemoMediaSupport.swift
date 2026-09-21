import CoreGraphics

/// Trim only transparent margins from the isolated window capture, preserving the actual UI.
func croppedOverlay(_ image: CGImage, padding: Int = 32) throws -> CGImage {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw CaptureFailure.failed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = bytes.bindMemory(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where buffer[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { throw CaptureFailure.noFrames }
        minX = max(0, minX - padding); minY = max(0, minY - padding)
        maxX = min(width - 1, maxX + padding); maxY = min(height - 1, maxY + padding)
        let source = context.makeImage()
        guard let result = source?.cropping(to: CGRect(x: minX, y: minY,
            width: maxX - minX + 1, height: maxY - minY + 1))
        else { throw CaptureFailure.failed }
        return result
    }
}

/// Keep the original alpha and leave 64 logical pixels beyond every visible shadow pixel.
func overlayCoverImage(_ image: CGImage, renderedOnWhite: CGImage? = nil) throws -> CGImage {
    let source: CGImage
    if let renderedOnWhite {
        guard image.width == renderedOnWhite.width, image.height == renderedOnWhite.height else {
            throw CaptureFailure.failed
        }
        func canvas() throws -> CGContext {
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw CaptureFailure.failed }
            return context
        }
        let alpha = try canvas(), color = try canvas()
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        alpha.draw(image, in: bounds)
        color.draw(renderedOnWhite, in: bounds)
        guard let a = alpha.data?.assumingMemoryBound(to: UInt8.self),
              let c = color.data?.assumingMemoryBound(to: UInt8.self) else { throw CaptureFailure.failed }
        for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let opacity = Int(a[offset + 3])
            // Remove the known white backing in premultiplied space. This keeps black
            // shadows black and antialiased edges free of a white fringe on dark pages.
            for channel in 0..<3 {
                c[offset + channel] = UInt8(clamping: min(opacity, Int(c[offset + channel]) - (255 - opacity)))
            }
            c[offset + 3] = UInt8(opacity)
        }
        guard let recovered = color.makeImage() else { throw CaptureFailure.failed }
        source = recovered
    } else { source = image }
    let cropped = try croppedOverlay(source, padding: 0)
    let padding = 128
    guard let context = CGContext(data: nil,
        width: cropped.width + 2 * padding, height: cropped.height + 2 * padding,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw CaptureFailure.failed }
    context.draw(cropped, in: CGRect(x: padding, y: padding, width: cropped.width, height: cropped.height))
    guard let result = context.makeImage() else { throw CaptureFailure.failed }
    return result
}
