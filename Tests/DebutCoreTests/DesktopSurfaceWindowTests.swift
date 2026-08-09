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

    @Test("Wallpaper store selects the most recently used desktop choice")
    func wallpaperStoreSelectsCurrentDesktop() throws {
        let older = try storedDesktop(
            url: URL(fileURLWithPath: "/tmp/older.jpg"),
            lastUse: Date(timeIntervalSince1970: 10),
            colorComponents: [1, 0, 0, 1]
        )
        let current = try storedDesktop(
            url: URL(fileURLWithPath: "/tmp/current.jpg"),
            lastUse: Date(timeIntervalSince1970: 20),
            colorComponents: [0, 0.25, 0.5, 1]
        )
        let root: [String: Any] = [
            "AllSpacesAndDisplays": older,
            "Spaces": ["current-space": current],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )

        let choice = try #require(WallpaperStoreResolver.choice(from: data))

        #expect(choice.url?.path == "/tmp/current.jpg")
        let rgb = try #require(choice.fillColor.usingColorSpace(.deviceRGB))
        #expect(abs(rgb.redComponent - 0) < 0.001)
        #expect(abs(rgb.greenComponent - 0.25) < 0.001)
        #expect(abs(rgb.blueComponent - 0.5) < 0.001)
    }

    @Test("Wallpaper store preserves a missing image choice instead of using a default")
    func wallpaperStorePreservesMissingChoice() throws {
        let desktop = try storedDesktop(
            url: URL(fileURLWithPath: "/missing/custom.jpg"),
            lastUse: Date(),
            colorComponents: [0.1, 0.2, 0.3, 1]
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["AllSpacesAndDisplays": desktop],
            format: .binary,
            options: 0
        )

        let choice = try #require(WallpaperStoreResolver.choice(from: data))

        #expect(choice.url?.path == "/missing/custom.jpg")
        #expect(choice.fillColor != .black)
    }

    @Test("Wallpaper store treats absolute file paths as file URLs")
    func wallpaperStoreParsesAbsoluteFilePath() throws {
        let desktop = try storedDesktop(
            url: URL(fileURLWithPath: "/tmp/configuration.jpg"),
            lastUse: Date(),
            colorComponents: [0, 0, 0, 1]
        )
        var content = try #require(
            (desktop["Desktop"] as? [String: Any])?["Content"] as? [String: Any]
        )
        content["Choices"] = [["Files": ["/tmp/from-files.jpg"]]]
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "Desktop": [
                    "Content": content,
                    "LastUse": Date(),
                ],
            ],
            format: .binary,
            options: 0
        )

        let choice = try #require(WallpaperStoreResolver.choice(from: data))

        #expect(choice.url?.isFileURL == true)
        #expect(choice.url?.path == "/tmp/from-files.jpg")
    }

    private func storedDesktop(
        url: URL,
        lastUse: Date,
        colorComponents: [Double]
    ) throws -> [String: Any] {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: [
                "type": "imageFile",
                "url": ["relative": url.absoluteString],
            ],
            format: .binary,
            options: 0
        )
        let options = try PropertyListSerialization.data(
            fromPropertyList: [
                "values": [
                    "customColor": [
                        "color": [
                            "_0": [
                                "color": ["components": colorComponents],
                            ],
                        ],
                    ],
                ],
            ],
            format: .binary,
            options: 0
        )
        return [
            "Desktop": [
                "Content": [
                    "Choices": [[
                        "Configuration": configuration,
                        "Files": [],
                        "Provider": "com.apple.wallpaper.choice.image",
                    ]],
                    "EncodedOptionValues": options,
                ],
                "LastUse": lastUse,
            ],
        ]
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
