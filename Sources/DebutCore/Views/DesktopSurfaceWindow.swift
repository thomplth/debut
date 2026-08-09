import AppKit

@MainActor
struct DesktopWallpaper {
    let image: NSImage
    let scaling: NSImageScaling
    let allowsClipping: Bool
    let fillColor: NSColor
}

@MainActor
protocol DesktopWallpaperProviding: AnyObject {
    func wallpaper(for screen: NSScreen) -> DesktopWallpaper?
}

@MainActor
protocol DesktopWallpaperChangeObserving: AnyObject {
    func start(handler: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
final class SystemDesktopWallpaperProvider: DesktopWallpaperProviding {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func wallpaper(for screen: NSScreen) -> DesktopWallpaper? {
        guard let url = workspace.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)
        else { return nil }

        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber)
            .flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        let allowsClipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        let fillColor = options[.fillColor] as? NSColor ?? .black

        return DesktopWallpaper(
            image: image,
            scaling: scaling,
            allowsClipping: allowsClipping,
            fillColor: fillColor
        )
    }
}

@MainActor
final class SystemDesktopWallpaperChangeObserver: DesktopWallpaperChangeObserving {
    static let desktopDidChangeNotification = Notification.Name("com.apple.desktop")

    nonisolated(unsafe) private var distributedToken: NSObjectProtocol?
    nonisolated(unsafe) private var activeSpaceToken: NSObjectProtocol?

    func start(handler: @escaping @MainActor @Sendable () -> Void) {
        guard distributedToken == nil, activeSpaceToken == nil else { return }

        distributedToken = DistributedNotificationCenter.default().addObserver(
            forName: Self.desktopDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in handler() }
        }
        activeSpaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in handler() }
        }
    }

    deinit {
        if let distributedToken {
            DistributedNotificationCenter.default().removeObserver(distributedToken)
        }
        if let activeSpaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceToken)
        }
    }
}

@MainActor
final class DesktopWallpaperView: NSView {
    var wallpaper: DesktopWallpaper? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (wallpaper?.fillColor ?? .black).setFill()
        dirtyRect.fill()

        guard let wallpaper else { return }
        let target = Self.targetRect(
            imageSize: wallpaper.image.size,
            bounds: bounds,
            scaling: wallpaper.scaling,
            allowsClipping: wallpaper.allowsClipping
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        wallpaper.image.draw(
            in: target,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    static func targetRect(
        imageSize: CGSize,
        bounds: CGRect,
        scaling: NSImageScaling,
        allowsClipping: Bool
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }

        let targetSize: CGSize
        switch scaling {
        case .scaleAxesIndependently:
            return bounds
        case .scaleNone:
            targetSize = imageSize
        case .scaleProportionallyDown:
            let scale = min(1, min(bounds.width / imageSize.width, bounds.height / imageSize.height))
            targetSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        case .scaleProportionallyUpOrDown:
            let widthScale = bounds.width / imageSize.width
            let heightScale = bounds.height / imageSize.height
            let scale = allowsClipping ? max(widthScale, heightScale) : min(widthScale, heightScale)
            targetSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        @unknown default:
            return bounds
        }

        return CGRect(
            x: bounds.midX - targetSize.width / 2,
            y: bounds.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
    }
}

/// A full-screen window that mirrors the current desktop wallpaper and sits between
/// active and inactive stage windows in z-order. Active windows are raised above it;
/// inactive windows are occluded behind it without position or minimize manipulation.
public final class DesktopSurfaceWindow: NSWindow {
    let wallpaperView = DesktopWallpaperView()
    private let wallpaperProvider: DesktopWallpaperProviding
    private let wallpaperChangeObserver: DesktopWallpaperChangeObserving
    private let onWallpaperRefreshed: @MainActor (Bool) -> Void

    public convenience init() {
        self.init(
            screen: NSScreen.main ?? NSScreen.screens[0],
            wallpaperProvider: SystemDesktopWallpaperProvider(),
            wallpaperChangeObserver: SystemDesktopWallpaperChangeObserver(),
            onWallpaperRefreshed: { loaded in
                DiagnosticReporter.shared.report("desktop_wallpaper_refreshed", details: [
                    "loaded": "\(loaded)",
                ])
            }
        )
    }

    init(
        screen: NSScreen,
        wallpaperProvider: DesktopWallpaperProviding,
        wallpaperChangeObserver: DesktopWallpaperChangeObserving,
        onWallpaperRefreshed: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.wallpaperProvider = wallpaperProvider
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
        collectionBehavior = [.stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        contentView = wallpaperView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        wallpaperChangeObserver.start { [weak self] in
            self?.refreshWallpaper()
        }
        refreshWallpaper(for: screen)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    public override func mouseDown(with event: NSEvent) {}

    /// Bring the surface to front, covering all inactive windows.
    /// Call this before raising active stage windows.
    public func orderToFront() {
        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
        orderFront(nil)
    }

    private func refreshWallpaper(for screen: NSScreen? = nil) {
        guard let screen = screen ?? NSScreen.main else { return }
        let wallpaper = wallpaperProvider.wallpaper(for: screen)
        wallpaperView.wallpaper = wallpaper
        onWallpaperRefreshed(wallpaper != nil)
    }

    @objc private func screenDidChange() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
        refreshWallpaper(for: screen)
    }
}
