import AppKit
import Testing
@testable import DebutCore

@MainActor
@Suite("DesktopSurfaceWindow")
struct DesktopSurfaceWindowTests {
    @Test("Wallpaper image uses aspect fill when clipping is enabled")
    func aspectFillLayout() {
        let target = DesktopWallpaperView.targetRect(
            imageSize: CGSize(width: 100, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            scaling: .scaleProportionallyUpOrDown,
            allowsClipping: true
        )

        #expect(target == CGRect(x: 0, y: -50, width: 200, height: 200))
    }

    @Test("Wallpaper image uses aspect fit when clipping is disabled")
    func aspectFitLayout() {
        let target = DesktopWallpaperView.targetRect(
            imageSize: CGSize(width: 100, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            scaling: .scaleProportionallyUpOrDown,
            allowsClipping: false
        )

        #expect(target == CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    @Test("Wallpaper change notification refreshes the surface")
    func notificationRefreshesSurface() {
        let firstImage = NSImage(size: CGSize(width: 10, height: 10))
        let secondImage = NSImage(size: CGSize(width: 20, height: 20))
        let provider = TestWallpaperProvider(image: firstImage)
        let observer = TestWallpaperChangeObserver()
        let window = DesktopSurfaceWindow(
            screen: NSScreen.main ?? NSScreen.screens[0],
            wallpaperProvider: provider,
            wallpaperChangeObserver: observer
        )

        #expect(window.wallpaperView.wallpaper?.image === firstImage)

        provider.image = secondImage
        observer.notifyChange()

        #expect(window.wallpaperView.wallpaper?.image === secondImage)
        #expect(provider.loadCount == 2)
    }
}

@MainActor
private final class TestWallpaperProvider: DesktopWallpaperProviding {
    var image: NSImage
    var loadCount = 0

    init(image: NSImage) {
        self.image = image
    }

    func wallpaper(for screen: NSScreen) -> DesktopWallpaper? {
        loadCount += 1
        return DesktopWallpaper(
            image: image,
            scaling: .scaleProportionallyUpOrDown,
            allowsClipping: true,
            fillColor: .black
        )
    }
}

@MainActor
private final class TestWallpaperChangeObserver: DesktopWallpaperChangeObserving {
    private var handler: (@MainActor @Sendable () -> Void)?

    func start(handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    func notifyChange() {
        handler?()
    }
}
