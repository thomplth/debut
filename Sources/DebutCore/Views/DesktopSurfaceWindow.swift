import AppKit

@MainActor
struct DesktopWallpaper {
    let image: NSImage
    let scaling: NSImageScaling
    let allowsClipping: Bool
    let fillColor: NSColor
}

@MainActor
struct StoredWallpaperChoice {
    let url: URL?
    let fillColor: NSColor
}

@MainActor
enum WallpaperStoreResolver {
    static func choice(from data: Data) -> StoredWallpaperChoice? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else { return nil }

        var desktops: [(Date, [String: Any])] = []
        collectDesktops(in: root, into: &desktops)
        guard let desktop = desktops.max(by: { $0.0 < $1.0 })?.1,
              let content = desktop["Content"] as? [String: Any]
        else { return nil }

        let url = ((content["Choices"] as? [[String: Any]])?.first)
            .flatMap(choiceURL)
        let fillColor = (content["EncodedOptionValues"] as? Data)
            .flatMap(colorFromOptions) ?? .black
        return StoredWallpaperChoice(url: url, fillColor: fillColor)
    }

    private static func collectDesktops(
        in value: Any,
        into results: inout [(Date, [String: Any])]
    ) {
        if let dictionary = value as? [String: Any] {
            if let desktop = dictionary["Desktop"] as? [String: Any] {
                results.append((desktop["LastUse"] as? Date ?? .distantPast, desktop))
            }
            for child in dictionary.values {
                collectDesktops(in: child, into: &results)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectDesktops(in: child, into: &results)
            }
        }
    }

    private static func choiceURL(_ choice: [String: Any]) -> URL? {
        if let files = choice["Files"] as? [String],
           let file = files.first {
            return wallpaperURL(from: file)
        }
        guard let configurationData = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(
                from: configurationData,
                options: [],
                format: nil
              ) as? [String: Any],
              let urlContainer = configuration["url"] as? [String: Any],
              let relative = urlContainer["relative"] as? String
        else { return nil }
        return wallpaperURL(from: relative)
    }

    private static func wallpaperURL(from value: String) -> URL {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: value)
    }

    private static func colorFromOptions(_ data: Data) -> NSColor? {
        guard let options = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let values = options["values"] as? [String: Any],
        let customColor = values["customColor"] as? [String: Any],
        let color = customColor["color"] as? [String: Any],
        let zero = color["_0"] as? [String: Any],
        let innerColor = zero["color"] as? [String: Any],
        let rawComponents = innerColor["components"] as? [Any]
        else { return nil }

        let components = rawComponents.compactMap { value -> Double? in
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }
        guard components.count >= 3 else { return nil }
        return NSColor(
            deviceRed: components[0],
            green: components[1],
            blue: components[2],
            alpha: components.count > 3 ? components[3] : 1
        )
    }
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
    private let wallpaperStoreURL: URL

    init(
        workspace: NSWorkspace = .shared,
        wallpaperStoreURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    ) {
        self.workspace = workspace
        self.wallpaperStoreURL = wallpaperStoreURL
    }

    func wallpaper(for screen: NSScreen) -> DesktopWallpaper? {
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber)
            .flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        let allowsClipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        let workspaceFillColor = options[.fillColor] as? NSColor ?? .black

        if let data = try? Data(contentsOf: wallpaperStoreURL),
           let choice = WallpaperStoreResolver.choice(from: data) {
            let image = choice.url.flatMap(NSImage.init(contentsOf:))
                ?? Self.solidImage(color: choice.fillColor)
            return DesktopWallpaper(
                image: image,
                scaling: scaling,
                allowsClipping: allowsClipping,
                fillColor: choice.fillColor
            )
        }

        guard let url = workspace.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)
        else { return nil }

        return DesktopWallpaper(
            image: image,
            scaling: scaling,
            allowsClipping: allowsClipping,
            fillColor: workspaceFillColor
        )
    }

    private static func solidImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
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
                DiagnosticReporter.shared.report("desktop_wallpaper_refreshed", level: .transient, details: [
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
        collectionBehavior = [.transient, .ignoresCycle]
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
