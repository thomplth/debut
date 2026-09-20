import AppKit
import CoreGraphics

/// The legend is driven by the exact events the demo posts, including key-up.
struct DemoKeyState {
    private var flags: CGEventFlags = []
    private var shownModifiers: CGEventFlags = .maskCommand
    private var key: CGKeyCode = 48
    private var keyDown = false

    private let modifiers: [(CGEventFlags, String)] = [
        (.maskControl, "⌃ Control"), (.maskAlternate, "⌥ Option"),
        (.maskShift, "⇧ Shift"), (.maskCommand, "⌘ Command"),
    ]

    var labels: [String] {
        modifiers.filter { shownModifiers.contains($0.0) }.map(\.1)
            + [key == 48 ? "Tab" : key == 125 ? "↓" : key == 126 ? "↑" : "Key \(key)"]
    }
    var pressed: [Bool] {
        modifiers.filter { shownModifiers.contains($0.0) }.map { flags.contains($0.0) }
            + [keyDown]
    }
    mutating func update(flags: CGEventFlags) {
        self.flags = flags
        if !flags.isEmpty { shownModifiers = flags }
    }
    mutating func update(key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        update(flags: flags)
        self.key = key
        keyDown = down
    }
}

/// Trim only transparent margins from the isolated window capture, preserving the actual UI.
func croppedOverlay(_ image: CGImage, padding: Int = 32, renderedImage: CGImage? = nil) throws -> CGImage {
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
            for x in 0..<width where buffer[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { throw CaptureFailure.noFrames }
        minX = max(0, minX - padding); minY = max(0, minY - padding)
        maxX = min(width - 1, maxX + padding); maxY = min(height - 1, maxY + padding)
        let source = renderedImage ?? context.makeImage()
        guard let result = source?.cropping(to: CGRect(x: minX, y: minY,
            width: maxX - minX + 1, height: maxY - minY + 1))
        else { throw CaptureFailure.failed }
        return result
    }
}

@MainActor
final class DemoKeyDisplay {
    let panel: NSPanel
    private let legend = KeyLegendView()
    var caption: String = "Hold Command and press Tab" {
        didSet {
            legend.caption = caption
            legend.needsDisplay = true
            panel.displayIfNeeded()
        }
    }

    init() {
        let screen = NSScreen.main!.frame
        panel = NSPanel(contentRect: NSRect(x: screen.midX - 230, y: screen.minY + 26,
            width: 460, height: 100), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = legend
        legend.caption = caption
        panel.orderFrontRegardless()
    }

    func update(flags: CGEventFlags, key: CGKeyCode? = nil, down: Bool = false) {
        if let key { legend.keys.update(key: key, down: down, flags: flags) }
        else { legend.keys.update(flags: flags) }
        legend.needsDisplay = true
        panel.displayIfNeeded()
    }
}

/// Light-mode labels need a light canvas even when GitHub displays the README in dark mode.
func overlayCoverImage(_ image: CGImage, renderedImage: CGImage? = nil) throws -> CGImage {
    let cropped = try croppedOverlay(image, renderedImage: renderedImage)
    guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw CaptureFailure.failed }
    let bounds = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    context.draw(cropped, in: bounds)
    guard let result = context.makeImage() else { throw CaptureFailure.failed }
    return result
}

@MainActor
private final class KeyLegendView: NSView {
    var keys = DemoKeyState()
    var caption = ""

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.06, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        let labels = keys.labels, pressed = keys.pressed
        let keyWidth: CGFloat = 154, gap: CGFloat = 12
        let total = CGFloat(labels.count) * keyWidth + CGFloat(labels.count - 1) * gap
        for index in labels.indices {
            let rect = NSRect(x: (bounds.width - total) / 2 + CGFloat(index) * (keyWidth + gap),
                y: 43, width: keyWidth, height: 43)
            (pressed[index] ? NSColor.white : NSColor(calibratedWhite: 0.2, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            drawText(labels[index], in: rect, size: 23,
                color: pressed[index] ? .black : NSColor(calibratedWhite: 0.7, alpha: 1))
        }
        drawText(caption, in: NSRect(x: 10, y: 10, width: bounds.width - 20, height: 25),
            size: 17, color: .white)
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2,
            width: rect.width, height: height), withAttributes: attributes)
    }
}
