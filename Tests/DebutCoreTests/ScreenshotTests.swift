import Testing
import AppKit
import SwiftUI
import Foundation
import DockGlass
@testable import DebutCore

@MainActor
@Suite("Screenshot Tests")
struct ScreenshotTests {
    static let outputDir: URL = {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/test-screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func renderSwiftUI<V: View>(
        _ view: V, size: NSSize, background: CGFloat = 0.1
    ) -> NSImage? {
        let hostingView = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: NSColor(white: background, alpha: 1.0)))
        )
        // Otherwise dynamic colours follow the host's light or dark mode, which differs between
        // machines. A view that sets its own colour scheme still overrides this.
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        guard let rep else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    private func renderStageFrames<V: View>(_ view: V, size: NSSize) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        let rootView = view
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(StageFramePreferenceKey.self) { frames = $0 }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        return frames
    }

    private func renderWindowFrames<V: View>(_ view: V, size: NSSize) -> [WindowFrameID: CGRect] {
        var frames: [WindowFrameID: CGRect] = [:]
        let rootView = view
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(WindowFramePreferenceKey.self) { frames = $0 }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        return frames
    }

    private func renderStageSurfaceFrames<V: View>(_ view: V, size: NSSize) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        let rootView = view
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(StageSurfaceFramePreferenceKey.self) { frames = $0 }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        return frames
    }

    private func saveImage(_ image: NSImage, name: String) throws {
        let url = Self.outputDir.appendingPathComponent("\(name).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ScreenshotError.renderFailed }
        try png.write(to: url)
    }

    private struct ScreenshotDifference {
        let meanChannelDifference: Double
        let changedPixelRatio: Double
        let comparedPixelCount: Int
    }

    @Test("Screenshot comparison ignores bare background but detects changed content")
    func screenshotComparisonContentMask() throws {
        func bitmap(content: NSColor) throws -> NSBitmapImageRep {
            let image = NSImage(size: NSSize(width: 20, height: 20))
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 20, height: 20).fill()
            content.setFill()
            NSRect(x: 5, y: 5, width: 10, height: 10).fill()
            image.unlockFocus()
            return try #require(normalizedBitmap(image, size: image.size))
        }
        let original = try bitmap(content: .red)
        let identical = try bitmap(content: .red)
        let changed = try bitmap(content: .blue)
        let same = screenshotDifference(original, identical)
        let different = screenshotDifference(original, changed)
        #expect(same.comparedPixelCount > 300)
        #expect(same.comparedPixelCount < original.pixelsWide * original.pixelsHigh)
        #expect(same.meanChannelDifference == 0)
        #expect(different.comparedPixelCount == same.comparedPixelCount)
        #expect(different.meanChannelDifference > 0.4)
        // The 20x20 changed core can acquire a one-pixel antialiased fringe when AppKit's
        // point-backed image is normalized on a hosted runner: 400 changed pixels out of a
        // 22x22 content mask. Most of the content must still change.
        #expect(different.changedPixelRatio > 0.8)
    }

    /// Draws an image into a deterministic @2x bitmap. Passing a smaller point size is the
    /// screenshot equivalent of looking at a scaled stage from the same distance.
    private func normalizedBitmap(_ image: NSImage, size: NSSize) -> NSBitmapImageRep? {
        let scale: CGFloat = 2
        var sourceRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil),
              let context = CGContext(
                  data: nil,
                  width: Int((size.width * scale).rounded()),
                  height: Int((size.height * scale).rounded()),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(
            x: 0,
            y: 0,
            width: size.width * scale,
            height: size.height * scale
        ))
        guard let normalized = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: normalized)
        bitmap.size = size
        return bitmap
    }

    /// Compares only pixels that contain overlay content in at least one image. The large bare
    /// desktop around the stages must not dilute a local visual regression into a passing score.
    private func screenshotDifference(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep
    ) -> ScreenshotDifference {
        precondition(lhs.pixelsWide == rhs.pixelsWide && lhs.pixelsHigh == rhs.pixelsHigh)
        // Draw both inputs into the same explicit byte layout. colorAt(x:y:) constructs
        // millions of NSColor objects for the large composition fixture.
        func pixels(_ image: NSBitmapImageRep) -> (CGContext, UnsafeMutablePointer<UInt8>)? {
            guard let source = image.cgImage,
                  let context = CGContext(
                    data: nil, width: image.pixelsWide, height: image.pixelsHigh,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ), let data = context.data
            else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0,
                width: image.pixelsWide, height: image.pixelsHigh))
            return (context, data.assumingMemoryBound(to: UInt8.self))
        }
        guard let (leftContext, leftBytes) = pixels(lhs),
              let (rightContext, rightBytes) = pixels(rhs)
        else { return ScreenshotDifference(meanChannelDifference: 1, changedPixelRatio: 1, comparedPixelCount: 0) }
        func channel(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ component: Int) -> Double {
            let alpha = Int(bytes[offset + 3])
            guard component != 3 else { return Double(alpha) / 255 }
            guard alpha > 0 else { return 0 }
            return Double(min(255, Int(bytes[offset + component]) * 255 / alpha)) / 255
        }
        let backgroundR = channel(leftBytes, 0, 0)
        let backgroundG = channel(leftBytes, 0, 1)
        let backgroundB = channel(leftBytes, 0, 2)
        var totalDifference = 0.0
        var changedPixels = 0
        var comparedPixels = 0

        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                let leftOffset = y * leftContext.bytesPerRow + x * 4
                let rightOffset = y * rightContext.bytesPerRow + x * 4
                let lr = channel(leftBytes, leftOffset, 0)
                let lg = channel(leftBytes, leftOffset, 1)
                let lb = channel(leftBytes, leftOffset, 2)
                let rr = channel(rightBytes, rightOffset, 0)
                let rg = channel(rightBytes, rightOffset, 1)
                let rb = channel(rightBytes, rightOffset, 2)
                let leftFromBackground = max(abs(lr - backgroundR), abs(lg - backgroundG), abs(lb - backgroundB))
                let rightFromBackground = max(abs(rr - backgroundR), abs(rg - backgroundG), abs(rb - backgroundB))
                guard max(leftFromBackground, rightFromBackground) > 0.01 else { continue }

                let redDifference = abs(lr - rr)
                let greenDifference = abs(lg - rg)
                let blueDifference = abs(lb - rb)
                let leftAlpha = channel(leftBytes, leftOffset, 3)
                let rightAlpha = channel(rightBytes, rightOffset, 3)
                let alphaDifference = abs(leftAlpha - rightAlpha)
                let difference = (redDifference + greenDifference
                    + blueDifference + alphaDifference) / 4
                totalDifference += difference
                changedPixels += difference > 0.08 ? 1 : 0
                comparedPixels += 1
            }
        }

        return ScreenshotDifference(
            meanChannelDifference: comparedPixels > 0
                ? totalDifference / Double(comparedPixels)
                : 1,
            changedPixelRatio: comparedPixels > 0
                ? Double(changedPixels) / Double(comparedPixels)
                : 1,
            comparedPixelCount: comparedPixels
        )
    }

    enum ScreenshotError: Error { case renderFailed }

    private func makeSampleViewModel(
        spaceCount: Int = 3,
        windowsPerSpace: [Int] = [3, 4, 2],
        activeIndex: Int = 1,
        appearance: AppSettings = AppSettings(),
        windowSizes: [CGWindowID: CGSize] = [:],
        windowPreviews: [CGWindowID: CGImage] = [:]
    ) -> StageOverlayViewModel {
        var sm = SpaceManager()
        let windowData: [(String, String, String)] = [
            ("com.apple.mail", "Mail", "Inbox"), ("com.apple.Safari", "Safari", "Google"),
            ("com.apple.Terminal", "Terminal", "~ zsh"), ("com.microsoft.VSCode", "VS Code", "main.swift"),
            ("com.tinyspeck.slackmacgap", "Slack", "#general"), ("com.apple.finder", "Finder", "Downloads"),
            ("com.apple.Notes", "Notes", "Meeting Notes"), ("com.google.Chrome", "Chrome", "GitHub"),
            ("com.apple.dt.Xcode", "Xcode", "Debut.xcodeproj"), ("com.apple.Preview", "Preview", "screenshot.png"),
        ]
        let defaultID = sm.spaces[0].id
        var windowCounter: CGWindowID = 100

        for i in 0..<spaceCount {
            if i == 0 {
                for _ in 0..<windowsPerSpace[i % windowsPerSpace.count] {
                    let w = windowData[Int(windowCounter - 100) % windowData.count]
                    sm.addWindow(SpaceWindow(windowID: windowCounter, ownerBundleID: w.0, ownerName: w.1, windowTitle: w.2), toSpaceID: defaultID)
                    windowCounter += 1
                }
            } else {
                sm.activateSpace(id: sm.spaces[i - 1].id)
                sm.addFixtureDesktop()
                let spaceID = sm.spaces[i].id
                for _ in 0..<windowsPerSpace[i % windowsPerSpace.count] {
                    let w = windowData[Int(windowCounter - 100) % windowData.count]
                    sm.addWindow(SpaceWindow(windowID: windowCounter, ownerBundleID: w.0, ownerName: w.1, windowTitle: w.2), toSpaceID: spaceID)
                    windowCounter += 1
                }
            }
        }
        sm.activateSpace(id: sm.spaces[min(activeIndex, sm.spaces.count - 1)].id)
        return StageOverlayViewModel(
            spaceManager: sm,
            activeSpaceIndex: activeIndex,
            selectedWindowIndex: 1,
            windowPreviews: windowPreviews,
            windowSizes: windowSizes,
            appearance: appearance
        )
    }

    /// A spread of window shapes to draw a stage from: a couple of ultrawides, a couple of
    /// portraits, and display-shaped windows between them.
    private func assortedWindowSizes(count: Int) -> [CGWindowID: CGSize] {
        let shapes = [
            CGSize(width: 2_560, height: 1_080), CGSize(width: 700, height: 1_100),
            CGSize(width: 1_440, height: 900), CGSize(width: 520, height: 1_000),
            CGSize(width: 1_920, height: 1_080),
        ]
        return Dictionary(uniqueKeysWithValues: (0..<count).map {
            (CGWindowID(100 + $0), shapes[$0 % shapes.count])
        })
    }

    @Test("Three stages render correctly")
    func threeStages() throws {
        let vm = makeSampleViewModel(spaceCount: 3, windowsPerSpace: [3, 4, 2], activeIndex: 1)
        guard let img = renderSwiftUI(StageOverlayView(viewModel: vm), size: NSSize(width: 1200, height: 600)) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "02_three_stages")
        #expect(vm.stages.count == 3)
    }

    /// Each card takes its own window's shape, which is the shipping default. A narrow window
    /// then takes less of the row than the widest one beside it.
    @Test("Adaptive cards draw at the width of the window each one shows")
    func adaptiveCardsRenderAtTheirOwnWidths() throws {
        let size = NSSize(width: 1_600, height: 1_000)
        let vm = makeSampleViewModel(
            spaceCount: 3,
            windowsPerSpace: [5, 5, 5],
            activeIndex: 1,
            windowSizes: assortedWindowSizes(count: 15)
        )
        guard let img = renderSwiftUI(StageOverlayView(viewModel: vm), size: size) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "02_adaptive_card_sizing")

        // The drawn card has to be the size the grid measured its slot at, or the drop
        // projection and the E2E hit tests aim at a card that is not there.
        let aspects = vm.stages.map { $0.windows.map(\.contentAspect) }
        let metrics = StageConstants.drawnMetrics(
            stageScale: CGFloat(vm.appearance.stageScale),
            contentAspects: aspects,
            containerSize: size
        )
        let layout = StageConstants.stageLayouts(
            forContentAspects: aspects,
            screenWidth: size.width,
            metrics: metrics
        )[1]
        let frames = renderWindowFrames(StageOverlayView(viewModel: vm), size: size)
        let widths = (0..<5).map { frames[WindowFrameID(spaceIndex: 1, windowIndex: $0)]!.width }

        for (index, width) in widths.enumerated() {
            #expect(abs(width - layout.cardWidth(at: index)) < 0.5)
        }
        #expect(Set(widths).count > 1)
    }

    @Test("Many stages render with a depth gradient")
    func manyStagesDepthGradient() throws {
        let vm = makeSampleViewModel(
            spaceCount: 9,
            windowsPerSpace: [2, 3, 1],
            activeIndex: 4
        )
        guard let img = renderSwiftUI(
            StageOverlayView(viewModel: vm),
            size: NSSize(width: 1200, height: 700)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "02_many_stages_depth_gradient")
        #expect(vm.stages.count == 9)
    }

    @Test("The flat switcher draws every space's windows on one plate")
    func altTabFlatList() throws {
        let stages = makeSampleViewModel(spaceCount: 3, windowsPerSpace: [3, 4, 2], activeIndex: 1)
        let entries = stages.spaceManager.globalWindowOrder()
        let viewModel = AltTabOverlayViewModel(entries: entries, selectedIndex: 2)

        guard let image = renderSwiftUI(
            AltTabOverlayView(viewModel: viewModel),
            size: NSSize(width: 1200, height: 600)
        ) else { throw ScreenshotError.renderFailed }
        try saveImage(image, name: "10_alt_tab_flat_list")
        let lightFlat = try #require(renderSwiftUI(
            AltTabOverlayView(viewModel: viewModel),
            size: NSSize(width: 1200, height: 600), background: 0.9
        ))
        try saveImage(lightFlat, name: "10_alt_tab_flat_list_light")
        let lightStages = try #require(renderSwiftUI(
            StageOverlayView(viewModel: stages),
            size: NSSize(width: 1200, height: 600), background: 0.9
        ))
        try saveImage(lightStages, name: "02_three_stages_light")

        #expect(viewModel.windows.count == 9)
        #expect(viewModel.selectedWindow?.windowID == entries[2].window.windowID)
    }

    @Test("halo probe", .enabled(if: ProcessInfo.processInfo.environment["DEBUT_HALO_PROBE"] != nil))
    func haloProbe() throws {
        let size = NSSize(width: 240, height: 60)
        func measure(_ view: some View, _ name: String) throws {
            let image = try #require(renderSwiftUI(view.frame(width: size.width, height: size.height), size: size, background: 0.5))
            try saveImage(image, name: "halo_\(name)")
            let bitmap = try #require(normalizedBitmap(image, size: size))
            var brightest: CGFloat = 0, count = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let c = bitmap.colorAt(x: x, y: y)!.redComponent
                brightest = max(brightest, c); if c > 0.55 { count += 1 }
            }}
            print("HALO \(name): brightest \(brightest) pixels>0.55: \(count)")
        }
        try measure(WindowTitleLabel(title: "Meeting Notes", fontSize: 12.8125).environment(\.colorScheme, .light), "flattened")
        try measure(Text("Meeting Notes").dockGlassLabel(fontSize: 12.8125).shadow(color: .white.opacity(0.95), radius: 1).environment(\.colorScheme, .light), "live")
        try measure(Text("Meeting Notes").dockGlassLabel(fontSize: 12.8125).environment(\.colorScheme, .light), "none")
    }

    /// The title halo is adjustable (KHA-1062): at strength 0 nothing lights the backdrop around
    /// a light-mode title, and at the default it visibly does.
    @Test("The title halo follows its strength setting")
    func titleHaloFollowsStrength() throws {
        let size = NSSize(width: 240, height: 60)
        func brightest(strength: Double) throws -> CGFloat {
            let label = WindowTitleLabel(
                title: "Meeting Notes",
                fontSize: DockGlass.Label.standardFontSize,
                haloStrength: strength,
                haloSize: 1
            )
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
            let image = try #require(renderSwiftUI(label, size: size, background: 0.5))
            let bitmap = try #require(normalizedBitmap(image, size: size))
            var peak: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                peak = max(peak, bitmap.colorAt(x: x, y: y)!.redComponent)
            }}
            return peak
        }
        let off = try brightest(strength: 0)
        let on = try brightest(strength: 1)
        #expect(on - off > 0.15, "halo on \(on), off \(off)")
    }

    @Test("Actual previews cast a shadow beyond their image bounds",
          arguments: [CGFloat(0.5), 1, 2.5], [CGFloat(0.3), 1.6, 4])
    func previewDropShadow(scale: CGFloat, aspect: CGFloat) throws {
        let metrics = StageMetrics.standard.scaled(by: scale).adapted(toContentAspect: aspect)
        let size = NSSize(width: 500 * scale, height: 300 * scale)
        let context = try #require(CGContext(
            data: nil, width: Int(100 * aspect), height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let preview = try #require(context.makeImage())
        // Tall and wide windows hit the adaptive width limits and therefore letterbox.
        // The shadow must follow the visible image, not the surrounding layout frame.
        let imageWidth = min(metrics.thumbnailWidth, metrics.thumbnailHeight * aspect)
        let centerY = size.height / 2 - (metrics.titleSpacing + metrics.titleHeight) / 2
        // The shadow does not depend on selection, and native's 9-point highlight would put a
        // sample past it beyond the shadow's reach; offscreen rendering also draws that
        // highlight without the glass it blends with. Sample unselected cards only.
        for selected in [false] {
            for dark in [false, true] {
                let background: CGFloat = dark ? 0.25 : 0.9
                let card = WindowPreviewView(
                    window: StageWindowData(
                        id: 100, windowID: 100, ownerBundleID: "com.apple.finder",
                        ownerName: "", windowTitle: "", previewImage: preview
                    ),
                    isWindowSelected: selected, metrics: metrics, appearance: AppSettings()
                ).environment(\.colorScheme, dark ? .dark : .light)
                let image = try #require(renderSwiftUI(card, size: size, background: background))
                let bitmap = try #require(normalizedBitmap(image, size: size))
                try saveImage(image, name: "05_preview_shadow_\(scale)_\(aspect)_\(selected)_\(dark)")
                // Sample past the selector as well as the image. A selected narrow image has
                // a wide letterbox and selector to its right, so use its bottom edge instead.
                // Unselected narrow images are still sampled inside that letterbox.
                let below = selected && imageWidth < metrics.thumbnailWidth
                let outset = selected ? CGFloat(AppSettings().selectorOutset) * scale : 0
                let point = below
                    ? CGPoint(x: size.width / 2,
                              y: centerY + metrics.thumbnailHeight / 2 + outset + 4 * scale)
                    : CGPoint(x: size.width / 2 + imageWidth / 2 + outset + 4 * scale,
                              y: centerY)
                let shadow = try #require(bitmap.colorAt(
                    x: Int(point.x * 2), y: Int(point.y * 2)
                ))
                let bare = try #require(bitmap.colorAt(x: Int((size.width - 5 * scale) * 2), y: Int(centerY * 2)))
                // Color components are 8-bit here. Require a visible four-level dark shadow or
                // seven-level light shadow without accidentally rounding those minima up.
                let minimumShadowDifference = (dark ? 4.0 : 7.0) / 255.0
                #expect(bare.redComponent - shadow.redComponent >= minimumShadowDifference)
            }
        }
    }

    @Test("A dragged preview keeps the exact resting card size")
    func draggedPreviewKeepsRestingSize() throws {
        let size = NSSize(width: 500, height: 300)
        let context = try #require(CGContext(
            data: nil, width: 160, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let preview = try #require(context.makeImage())
        let window = StageWindowData(
            id: 100,
            windowID: 100,
            ownerBundleID: "com.apple.finder",
            ownerName: "Finder",
            windowTitle: "Preview",
            previewImage: preview
        )
        let resting = try #require(renderSwiftUI(
            WindowPreviewView(
                window: window,
                isWindowSelected: false,
                isDragging: false,
                metrics: .standard,
                appearance: AppSettings()
            ),
            size: size
        ))
        let dragging = try #require(renderSwiftUI(
            WindowPreviewView(
                window: window,
                isWindowSelected: false,
                isDragging: true,
                metrics: .standard,
                appearance: AppSettings()
            ),
            size: size
        ))
        try saveImage(resting, name: "05_window_preview_resting")
        try saveImage(dragging, name: "05_window_preview_dragging")

        let restingBitmap = try #require(normalizedBitmap(resting, size: size))
        let draggingBitmap = try #require(normalizedBitmap(dragging, size: size))
        let difference = screenshotDifference(restingBitmap, draggingBitmap)
        #expect(difference.comparedPixelCount > 10_000)
        #expect(difference.meanChannelDifference < 0.001)
        #expect(difference.changedPixelRatio < 0.001)
    }

    /// A failed capture shows the app's icon at the badge's size and nothing around it: no halo
    /// darkens the empty preview below the icon (KHA-1060).
    @Test("A failed capture's icon casts no halo", arguments: [1.0, 1.45, 2.0])
    func placeholderHasNoHalo(scale: CGFloat) throws {
        let metrics = StageMetrics.standard.withPreviewScale(scale)
        let size = NSSize(width: 500 * scale, height: 400 * scale)
        let card = WindowPreviewView(
            window: StageWindowData(
                id: 100, windowID: 100,
                ownerBundleID: "com.apple.finder", ownerName: "",
                windowTitle: "", previewImage: nil
            ),
            isWindowSelected: false, metrics: metrics, appearance: AppSettings()
        )
        let image = try #require(renderSwiftUI(card, size: size, background: 0.9))
        let bitmap = try #require(normalizedBitmap(image, size: size))
        try saveImage(image, name: "05_placeholder_\(scale)")

        // Both samples are inside the same empty preview at the same height, one just below
        // the icon and one well clear of it. A halo would darken the first.
        let iconCenterY = size.height / 2 - metrics.titleBandHeight / 2 + metrics.cardPadding / 2
        let y = Int((iconCenterY + metrics.placeholderIconSize / 2 + 3) * 2)
        let belowIcon = try #require(bitmap.colorAt(x: Int(size.width), y: y))
        let clear = try #require(bitmap.colorAt(x: Int((size.width / 2 + metrics.thumbnailWidth / 2 - 8) * 2), y: y))
        #expect(abs(clear.redComponent - belowIcon.redComponent) < 0.01)
    }

    /// The global list is the first thing in the app that routinely outgrows the display, so the
    /// crowded case is worth a picture rather than only a number.
    @Test("A crowded flat switcher wraps and shrinks to fit")
    func altTabCrowdedList() throws {
        let stages = makeSampleViewModel(
            spaceCount: 6,
            windowsPerSpace: [7, 8, 6],
            activeIndex: 0
        )
        let entries = stages.spaceManager.globalWindowOrder()
        let viewModel = AltTabOverlayViewModel(entries: entries, selectedIndex: 0)
        let container = CGSize(width: 1440, height: 900)

        guard let image = renderSwiftUI(
            AltTabOverlayView(viewModel: viewModel),
            size: NSSize(width: container.width, height: container.height)
        ) else { throw ScreenshotError.renderFailed }
        try saveImage(image, name: "10_alt_tab_crowded_list")

        let layout = viewModel.layout(containerSize: container)
        #expect(layout.rowCount > 1)
        #expect(
            layout.stageSize.height
                <= StageConstants.availableStageHeight(screenHeight: container.height)
        )
    }

    @Test("Selection on second window")
    func selectionState() throws {
        let vm = StageOverlayViewModel(
            spaceManager: makeSampleViewModel(spaceCount: 2, windowsPerSpace: [5, 3], activeIndex: 0).spaceManager,
            activeSpaceIndex: 0, selectedWindowIndex: 2
        )
        guard let img = renderSwiftUI(StageOverlayView(viewModel: vm), size: NSSize(width: 1200, height: 400)) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "05_selection_state")
        #expect(vm.selectedWindowIndex == 2)
    }

    /// Lit pixels in the thumbnail's top-left corner, where only the badge ever draws: the
    /// placeholder icon sits in the middle of the plate and a preview fills it uniformly. The
    /// badge's own top rows are transparent icon margin, so the sample starts inside its frame.
    private func badgeCornerPixelCount(preview: CGImage?, name: String) throws -> Int {
        // This checks the badge in the preview's top-left corner, the Corner position.
        var cornerBadgeAppearance = AppSettings()
        cornerBadgeAppearance.badgePlacement = .corner
        let metrics = StageMetrics.standard
        let cardSize = NSSize(
            width: metrics.thumbnailWidth + metrics.titleWidthAllowance + metrics.cardPadding * 2,
            height: metrics.thumbnailHeight + metrics.titleSpacing + metrics.titleHeight
                + metrics.cardPadding * 2
        )
        let card = WindowPreviewView(
            window: StageWindowData(
                id: 100,
                windowID: 100,
                ownerBundleID: "com.apple.finder",
                ownerName: "Finder",
                windowTitle: "Downloads",
                previewImage: preview
            ),
            isWindowSelected: false,
            metrics: metrics,
            appearance: cornerBadgeAppearance
        )
        .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)

        guard let image = renderSwiftUI(card, size: cardSize),
              let bitmap = normalizedBitmap(image, size: cardSize)
        else { throw ScreenshotError.renderFailed }
        try saveImage(image, name: name)

        // The title is the widest thing in the card, so the plate sits centered under it.
        let plateOrigin = CGPoint(
            x: metrics.cardPadding + metrics.titleWidthAllowance / 2,
            y: metrics.cardPadding
        )
        // Points to pixels at the fixed @2x of `normalizedBitmap`.
        func pixel(_ point: CGPoint) -> (x: Int, y: Int) {
            (Int((plateOrigin.x + point.x) * 2), Int((plateOrigin.y + point.y) * 2))
        }
        // Empty plate in every case: past the badge, short of the centered placeholder.
        let referencePoint = pixel(CGPoint(x: metrics.thumbnailWidth - 12, y: 12))
        let reference = bitmap.colorAt(x: referencePoint.x, y: referencePoint.y) ?? .black

        let corner = pixel(CGPoint(x: 2, y: 2))
        let cornerEnd = pixel(CGPoint(x: metrics.badgeSize - 8, y: metrics.badgeSize - 8))
        var lit = 0
        for x in corner.x..<cornerEnd.x {
            for y in corner.y..<cornerEnd.y {
                guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
                let distance = max(
                    abs(pixel.redComponent - reference.redComponent),
                    abs(pixel.greenComponent - reference.greenComponent),
                    abs(pixel.blueComponent - reference.blueComponent)
                )
                if distance > 0.02 { lit += 1 }
            }
        }
        return lit
    }

    @Test("A card with no preview draws its app icon only as the centered placeholder")
    func placeholderCardDropsTheCornerBadge() throws {
        var preview: CGImage?
        if let context = CGContext(
            data: nil,
            width: 160,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
            preview = context.makeImage()
        }
        let captured = try #require(preview)

        let withPreview = try badgeCornerPixelCount(
            preview: captured,
            name: "05_card_badge_with_preview"
        )
        let withoutPreview = try badgeCornerPixelCount(
            preview: nil,
            name: "05_card_badge_without_preview"
        )

        #expect(withPreview > 0)
        #expect(withoutPreview == 0)
    }

    // The badge bitmap grew to hold its baked shadow. Framing that padded bitmap directly would
    // widen the card it sits on, which is exactly the kind of change a rendering fix must not make.
    @Test("A preview does not move anything a preview-less card lays out")
    func previewDoesNotChangeCardLayout() throws {
        let size = NSSize(width: 1200, height: 600)
        var preview: [CGWindowID: CGImage] = [:]
        if let context = CGContext(
            data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
            if let image = context.makeImage() {
                for id in CGWindowID(100)...CGWindowID(120) { preview[id] = image }
            }
        }

        let withoutPreviews = renderWindowFrames(
            StageOverlayView(viewModel: makeSampleViewModel()),
            size: size
        )
        let withPreviews = renderWindowFrames(
            StageOverlayView(viewModel: makeSampleViewModel(windowPreviews: preview)),
            size: size
        )

        #expect(!withPreviews.isEmpty)
        #expect(Set(withPreviews.keys) == Set(withoutPreviews.keys))
        for (id, frame) in withPreviews {
            let bare = try #require(withoutPreviews[id])
            #expect(abs(frame.origin.x - bare.origin.x) < 0.5)
            #expect(abs(frame.origin.y - bare.origin.y) < 0.5)
            #expect(abs(frame.width - bare.width) < 0.5)
            #expect(abs(frame.height - bare.height) < 0.5)
        }
    }

    private func unscaledAppearance() -> AppSettings {
        var settings = AppSettings()
        settings.stageScale = 1
        return settings
    }

    @Test("A stage too wide for the display renders its windows in balanced rows")
    func wideStageWrapsIntoRows() throws {
        let vm = makeSampleViewModel(
            spaceCount: 1,
            windowsPerSpace: [8],
            activeIndex: 0,
            appearance: unscaledAppearance()
        )
        let size = NSSize(width: 1200, height: 700)
        // The card takes the container's shape, so the geometry this checks against has to come
        // from the container too rather than from the standard 16:10 card.
        let metrics = StageConstants.drawnMetrics(
            stageScale: 1,
            windowCounts: [8],
            containerSize: size
        )

        guard let img = renderSwiftUI(StageOverlayView(viewModel: vm), size: size) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "06_wrapped_stage_rows")

        let frames = renderWindowFrames(StageOverlayView(viewModel: vm), size: size)
        let cards = (0..<8).map { frames[WindowFrameID(spaceIndex: 0, windowIndex: $0)]! }
        let rows = Dictionary(grouping: cards) { ($0.midY * 10).rounded() }

        #expect(rows.count == 2)
        #expect(rows.values.allSatisfy { $0.count == 4 })
        #expect(cards.allSatisfy { $0.maxX <= size.width })

        guard let stage = renderStageSurfaceFrames(
            StageOverlayView(viewModel: vm),
            size: size
        )[0] else { throw ScreenshotError.renderFailed }
        let expectedHeight: CGFloat = metrics.cardHeight * 2 + metrics.rowSpacing
            + metrics.topPadding + metrics.bottomPadding
        #expect(abs(stage.height - expectedHeight) < 0.5)

        // What is drawn has to be where the geometry says, or drag projection and the E2E hit
        // tests are aiming at slots the view never used.
        let layout = StageWindowLayout(
            windowCount: 8,
            availableWidth: StageConstants.availableStageWidth(screenWidth: size.width),
            metrics: metrics
        )
        for (index, card) in cards.enumerated() {
            let expected = layout.cardOffsetFromCenter(at: index)
            #expect(abs(card.midX - (stage.midX + expected.width)) < 0.5)
            #expect(abs(card.midY - (stage.midY + expected.height)) < 0.5)
        }
    }

    @Test("The stage scale setting reaches the cards the overlay actually draws")
    func stageScaleEnlargesRenderedCards() throws {
        let size = NSSize(width: 1600, height: 1000)
        let counts = [4]
        let enlargedScale = 1.5

        func cardSize(stageScale: Double) -> CGSize {
            var settings = AppSettings()
            settings.stageScale = stageScale
            let vm = makeSampleViewModel(
                spaceCount: 1,
                windowsPerSpace: counts,
                activeIndex: 0,
                appearance: settings
            )
            let frames = renderWindowFrames(StageOverlayView(viewModel: vm), size: size)
            return frames[WindowFrameID(spaceIndex: 0, windowIndex: 0)]!.size
        }

        let unscaled = cardSize(stageScale: 1)
        let enlarged = cardSize(stageScale: enlargedScale)

        // Only the preview grows: the card gains exactly the preview's extra size (KHA-1059).
        let shaped = StageMetrics.shaped(forDisplay: size)
        #expect(abs(enlarged.width - unscaled.width - shaped.thumbnailWidth * (enlargedScale - 1)) < 0.5)
        #expect(abs(enlarged.height - unscaled.height - shaped.thumbnailHeight * (enlargedScale - 1)) < 0.5)

        // E2E clicks screen coordinates it derives from drawnMetrics, so a card drawn at any
        // other size sends those clicks somewhere the overlay never drew.
        let expected = StageConstants.drawnMetrics(
            stageScale: enlargedScale,
            windowCounts: counts,
            containerSize: size
        )
        #expect(abs(enlarged.width - expected.cardWidth) < 0.5)
        #expect(abs(enlarged.height - expected.cardHeight) < 0.5)
    }

    /// Every card is titled, not only the selected one as natively, so a title must read as
    /// clearly unselected as selected: full strength, one fixed size at every window size, and
    /// centred between the card's lower edge and the plate's, not around a highlight only the
    /// selected card draws (KHA-1057).
    @Test("Titles render full-strength at one size, centred below the card")
    func windowTitlesAreUniformAndCentred() throws {
        let size = NSSize(width: 700, height: 600)
        // Measures the title's own glyphs, so no app icon leads it.
        var appearance = AppSettings()
        appearance.badgePlacement = .bottom
        let window = StageWindowData(
            id: 1, windowID: 1, ownerBundleID: "com.apple.finder",
            ownerName: "Finder", windowTitle: "Hg Title", previewImage: nil
        )
        struct Glyphs { var box: CGRect; var peak: CGFloat }
        func glyphs(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> Glyphs? {
            var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh
            var maxX = -1, maxY = -1
            var peak: CGFloat = 0
            for y in rows {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    let level = min(color.redComponent, color.greenComponent, color.blueComponent)
                    guard level > 0.5 else { continue }
                    peak = max(peak, level)
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return Glyphs(box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), peak: peak)
        }

        // The same title on its own, centred in a frame, gives the glyphs' size and how far
        // their ink sits from a centred text box (descenders pull it down).
        let referenceSize = NSSize(width: 300, height: 80)
        let reference = try #require(renderSwiftUI(
            Text("Hg Title")
                .font(DockGlass.Label.font(size: DockGlass.Label.standardFontSize))
                .foregroundStyle(.white)
                .frame(width: referenceSize.width, height: referenceSize.height),
            size: referenceSize
        ))
        let referenceBitmap = try #require(normalizedBitmap(reference, size: referenceSize))
        let expected = try #require(glyphs(referenceBitmap, rows: 0..<referenceBitmap.pixelsHigh))
        let inkOffset = expected.box.midY - referenceSize.height

        for scale: CGFloat in [1, 1.45, 2, 2.5] {
            for selected in [false, true] {
                let metrics = StageMetrics.standard.withPreviewScale(scale)
                let image = try #require(renderSwiftUI(
                    WindowPreviewView(window: window, isWindowSelected: selected,
                        metrics: metrics, appearance: appearance)
                        .environment(\.colorScheme, .dark), size: size
                ))
                try saveImage(image, name: "06_title_\(scale)_\(selected)")
                let bitmap = try #require(normalizedBitmap(image, size: size))
                // Only the band below the preview, which ends at the card's (and plate's) edge.
                let cardTop = size.height / 2 - metrics.cardHeight / 2
                let bandTop = cardTop + metrics.cardPadding + metrics.thumbnailHeight
                let bandBottom = cardTop + metrics.cardHeight
                let measured = try #require(glyphs(bitmap, rows: Int(bandTop * 2)..<Int(bandBottom * 2)))

                #expect(abs(measured.box.width - expected.box.width) <= 2, "scale \(scale)")
                #expect(abs(measured.box.height - expected.box.height) <= 2, "scale \(scale)")
                #expect(measured.peak > 0.95, "an unselected title is as strong as a selected one")
                let bandCentre = (bandTop + bandBottom) // in pixels at 2x
                #expect(abs((measured.box.midY - bandCentre) - inkOffset) <= 2, "scale \(scale) selected \(selected)")
            }
        }
    }

    /// Replaces the proportional-composition check: the size setting no longer enlarges the
    /// whole overlay, only the previews (KHA-1059). The geometry is pinned in
    /// PreviewOnlyScalingTests; this checks the overlay draws it, plate edges and gaps included.
    @Test("A 150 percent size enlarges only the previews in the rendered overlay")
    func enlargedStageScaleGrowsOnlyPreviews() throws {
        let size = NSSize(width: 1_600, height: 1_000)
        func stage(_ scale: Double) throws -> CGRect {
            var appearance = AppSettings()
            appearance.stageScale = scale
            let vm = makeSampleViewModel(spaceCount: 1, windowsPerSpace: [3], activeIndex: 0, appearance: appearance)
            return try #require(renderStageSurfaceFrames(StageOverlayView(viewModel: vm), size: size)[0])
        }
        let native = try stage(1)
        let enlarged = try stage(1.5)
        let shaped = StageMetrics.shaped(forDisplay: size)
        #expect(abs(enlarged.height - native.height - shaped.thumbnailHeight * 0.5) < 0.5)
        #expect(abs(enlarged.width - native.width - shaped.thumbnailWidth * 0.5 * 3) < 0.5)
    }

    @Test("The default stage scale still fits the display, and a crowded space shrinks to fit")
    func defaultStageScaleFitsTheDisplay() throws {
        let size = NSSize(width: 1440, height: 900)
        let vm = makeSampleViewModel(spaceCount: 1, windowsPerSpace: [6], activeIndex: 0)

        guard let img = renderSwiftUI(StageOverlayView(viewModel: vm), size: size) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "06_default_stage_scale")

        guard let stage = renderStageSurfaceFrames(
            StageOverlayView(viewModel: vm),
            size: size
        )[0] else { throw ScreenshotError.renderFailed }
        #expect(stage.width <= StageConstants.availableStageWidth(screenWidth: size.width))
        #expect(stage.height <= StageConstants.availableStageHeight(screenHeight: size.height))

        // The same display cannot hold twenty windows at the requested scale, so the overlay
        // has to give scale back rather than draw a stage off the bottom of the screen.
        let crowded = makeSampleViewModel(spaceCount: 1, windowsPerSpace: [20], activeIndex: 0)
        guard let crowdedStage = renderStageSurfaceFrames(
            StageOverlayView(viewModel: crowded),
            size: size
        )[0] else { throw ScreenshotError.renderFailed }

        #expect(crowdedStage.width <= StageConstants.availableStageWidth(screenWidth: size.width))
        #expect(crowdedStage.height <= StageConstants.availableStageHeight(screenHeight: size.height))
    }

    /// A view with a compact drag already picked up from `source`, aimed at `target`.
    private func compactDragView(
        _ vm: StageOverlayViewModel,
        source: (Int, Int),
        size: NSSize,
        target: (stage: Int, gap: Int)?
    ) throws -> (StageOverlayView, CompactDragSnapshot) {
        let session = CompactDragSession()
        let snapshot = try #require(StageOverlayView.compactDragSnapshot(
            viewModel: vm, spaceIndex: source.0, windowIndex: source.1,
            containerSize: size, generation: session.makeGeneration()
        ))
        let window = vm.stages[source.0].windows[source.1]
        var location = CGPoint(x: 1, y: 1)
        if let target {
            let stage = snapshot.stages[target.stage]
            let intent = CompactDropIntent(
                stageIndex: target.stage, spaceID: stage.spaceID, row: 0, gap: target.gap,
                logicalIndex: target.gap, generation: snapshot.generation
            )
            let placeholder = try #require(snapshot.projection(for: intent).placeholder)
            location = try #require(snapshot.overlayPoint(
                stageIndex: target.stage, offset: placeholder.offset
            ))
        }
        session.begin(snapshot: snapshot, window: window, at: location)
        var view = StageOverlayView(viewModel: vm)
        view.compactDragSession = session
        return (view, snapshot)
    }

    @Test("A compact drag fits four overflowing stages, fixed under every target",
          arguments: [NSSize(width: 1024, height: 768), NSSize(width: 1280, height: 800)])
    func compactDragFitsOverflowingStages(size: NSSize) throws {
        var appearance = AppSettings()
        appearance.stageScale = AppSettings.maximumStageScale
        let vm = makeSampleViewModel(
            spaceCount: 4, windowsPerSpace: [6, 3, 0, 5], activeIndex: 0, appearance: appearance
        )
        let normal = renderStageSurfaceFrames(StageOverlayView(viewModel: vm), size: size)
        #expect(normal.values.contains { $0.minY < 0 || $0.maxY > size.height },
                "fixture must overflow the ordinary overlay")

        var heights: [[CGFloat]] = []
        var centers: [[CGFloat]] = []
        for target in [(0, 0), (1, 0), (1, 3), (2, 0), (3, 5)] {
            let (view, snapshot) = try compactDragView(
                vm, source: (0, 1), size: size, target: (target.0, target.1)
            )
            let frames = renderStageSurfaceFrames(view, size: size)
            #expect(frames.count == 4)
            for frame in frames.values {
                #expect(snapshot.usableBounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
                #expect(abs(frame.midX - size.width / 2) < 0.5)
            }
            heights.append((0..<4).map { frames[$0]?.height ?? -1 })
            centers.append((0..<4).map { frames[$0]?.midY ?? -1 })
        }
        for (h, c) in zip(heights.dropFirst(), centers.dropFirst()) {
            #expect(zip(h, heights[0]).allSatisfy { abs($0 - $1) < 0.5 })
            #expect(zip(c, centers[0]).allSatisfy { abs($0 - $1) < 0.5 })
        }

        let (view, _) = try compactDragView(vm, source: (0, 1), size: size, target: (2, 0))
        let name = "compact-drag-\(Int(size.width))x\(Int(size.height))"
        if let image = renderSwiftUI(view, size: size) { try saveImage(image, name: name) }
    }

    @Test("A compact drop target widens only its destination around a fixed centre")
    func compactDragWidensDestinationOnly() throws {
        let vm = makeSampleViewModel(spaceCount: 2, windowsPerSpace: [3, 2], activeIndex: 0)
        let size = NSSize(width: 1280, height: 800)
        let (idle, snapshot) = try compactDragView(vm, source: (0, 0), size: size, target: nil)
        let (aimed, _) = try compactDragView(vm, source: (0, 0), size: size, target: (1, 1))
        let before = renderStageSurfaceFrames(idle, size: size)
        let after = renderStageSurfaceFrames(aimed, size: size)

        // Drawn exactly as the snapshot hit-tests it, magnified rather than transformed.
        let plate = try #require(snapshot.plateFrame(
            stageIndex: 0, projection: snapshot.projection(for: nil)
        ))
        #expect(abs(before[0]!.width - plate.width) <= 1)
        // Within a point: SwiftUI snaps the drawn frame to whole points.
        #expect(abs(before[0]!.midY - plate.midY) <= 1)
        #expect(after[1]!.width > before[1]!.width)
        #expect(abs(after[0]!.width - before[0]!.width) < 0.5)
        for index in 0..<2 {
            #expect(abs(after[index]!.midX - before[index]!.midX) < 0.5)
            #expect(abs(after[index]!.midY - before[index]!.midY) < 0.5)
            #expect(abs(after[index]!.height - before[index]!.height) < 0.5)
        }
    }

    @Test(
        "Display stack indicator sits at the top of the overlay with configured glass",
        arguments: GlassStyle.allCases
    )
    func displayStackIndicator(glassStyle: GlassStyle) throws {
        var manager = makeSampleViewModel(
            spaceCount: 3,
            windowsPerSpace: [3, 2, 1],
            activeIndex: 1
        ).spaceManager
        manager.reconcileSpaceStacks(with: SpaceTopology(separateSpaces: true, stacks: [
            SpaceStackDescriptor(
                id: "display-a", displayID: 1, displayName: "Studio Display",
                frame: .zero, desktopIDs: [10, 11, 12], currentDesktopID: 11
            ),
            SpaceStackDescriptor(
                id: "display-b", displayID: 2, displayName: "Built-in Display",
                frame: .zero, desktopIDs: [20], currentDesktopID: 20
            ),
        ]))
        var appearance = AppSettings()
        appearance.glassStyle = glassStyle
        let vm = StageOverlayViewModel(
            spaceManager: manager,
            activeSpaceIndex: 1,
            selectedWindowIndex: 1,
            appearance: appearance
        )

        guard let image = renderSwiftUI(
            StageOverlayView(viewModel: vm),
            size: NSSize(width: 1200, height: 600)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(
            image,
            name: "07_display_stack_indicator_\(glassStyle.rawValue.lowercased())"
        )

        #expect(vm.displayStackCount == 2)
    }

    /// The display stack indicator's text carries the window titles' halo (KHA-1076). Only the
    /// indicator's strip is measured, since the cards' titles follow the same setting.
    @Test("The display stack indicator's text follows the title halo")
    func displayStackIndicatorHalo() throws {
        let size = NSSize(width: 1200, height: 600)
        func brightest(strength: Double) throws -> CGFloat {
            var manager = makeSampleViewModel(
                spaceCount: 3,
                windowsPerSpace: [3, 2, 1],
                activeIndex: 1
            ).spaceManager
            manager.reconcileSpaceStacks(with: SpaceTopology(separateSpaces: true, stacks: [
                SpaceStackDescriptor(
                    id: "display-a", displayID: 1, displayName: "Studio Display",
                    frame: .zero, desktopIDs: [10, 11, 12], currentDesktopID: 11
                ),
                SpaceStackDescriptor(
                    id: "display-b", displayID: 2, displayName: "Built-in Display",
                    frame: .zero, desktopIDs: [20], currentDesktopID: 20
                ),
            ]))
            var appearance = AppSettings()
            appearance.glassStyle = .clear
            appearance.titleHaloStrength = strength
            appearance.titleHaloSize = 1
            let vm = StageOverlayViewModel(
                spaceManager: manager,
                activeSpaceIndex: 1,
                selectedWindowIndex: 1,
                appearance: appearance
            )
            let view = StageOverlayView(viewModel: vm).environment(\.colorScheme, .light)
            let image = try #require(renderSwiftUI(view, size: size, background: 0.5))
            return try peakBrightness(
                image,
                size: size,
                in: CGRect(x: size.width / 2 - 200, y: 0, width: 400, height: 60)
            )
        }
        let off = try brightest(strength: 0)
        let on = try brightest(strength: 1)
        #expect(on - off > 0.15, "halo on \(on), off \(off)")
    }

    /// The brightest red channel inside `region`, in top-left-origin points.
    private func peakBrightness(_ image: NSImage, size: NSSize, in region: CGRect) throws -> CGFloat {
        let bitmap = try #require(normalizedBitmap(image, size: size))
        let scaleX = CGFloat(bitmap.pixelsWide) / size.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / size.height
        var peak: CGFloat = 0
        for y in Int(region.minY * scaleY)..<min(bitmap.pixelsHigh, Int(region.maxY * scaleY)) {
            for x in Int(region.minX * scaleX)..<min(bitmap.pixelsWide, Int(region.maxX * scaleX)) {
                peak = max(peak, bitmap.colorAt(x: x, y: y)!.redComponent)
            }
        }
        return peak
    }

    @Test(
        "Desktop switch indicator is a compact top-center capsule with configured glass",
        arguments: GlassStyle.allCases
    )
    func desktopSwitchIndicator(glassStyle: GlassStyle) throws {
        let view = DesktopSwitchIndicatorView(
            presentation: DesktopSwitchIndicatorPresentation(
                stackID: "display-a",
                displayID: 1,
                displayName: "Studio Display",
                desktopPosition: 1,
                desktopCount: 4
            ),
            glassStyle: glassStyle
        )
        for (backgroundName, background) in [("dark", 0.06), ("light", 0.94)] {
            let image = try #require(renderSwiftUI(
                view.padding(DesktopSwitchIndicatorWindow.glassRenderingInset),
                size: NSSize(width: 264, height: 96),
                background: background
            ))
            try saveImage(
                image,
                name: "07_desktop_switch_indicator_\(glassStyle.rawValue.lowercased())_\(backgroundName)"
            )
        }
    }

    /// The indicator's label carries the window titles' halo (KHA-1076): at strength 0 nothing
    /// lights the backdrop around a light-mode label, and at the default it visibly does.
    @Test("The desktop switch indicator's label follows the title halo")
    func desktopSwitchIndicatorHalo() throws {
        let size = NSSize(width: 264, height: 96)
        func brightest(strength: Double) throws -> CGFloat {
            let view = DesktopSwitchIndicatorView(
                presentation: DesktopSwitchIndicatorPresentation(
                    stackID: "display-a",
                    displayID: 1,
                    displayName: "Studio Display",
                    desktopPosition: 1,
                    desktopCount: 4
                ),
                glassStyle: .clear,
                haloStrength: strength,
                haloSize: 1
            )
            .padding(DesktopSwitchIndicatorWindow.glassRenderingInset)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
            let image = try #require(renderSwiftUI(view, size: size, background: 0.5))
            return try peakBrightness(image, size: size, in: CGRect(origin: .zero, size: size))
        }
        let off = try brightest(strength: 0)
        let on = try brightest(strength: 1)
        #expect(on - off > 0.15, "halo on \(on), off \(off)")
    }

    @Test("Launch settings sections render independently", arguments: SettingsSection.allCases)
    func settingsSections(_ section: SettingsSection) throws {
        let view = SettingsView(viewModel: SettingsViewModel(), selectedSection: section)
        let image = try #require(renderSwiftUI(view, size: NSSize(width: 820, height: 620)))
        try saveImage(image, name: "settings_\(section.rawValue)")
    }

    @Test("Disabled faster desktop transitions gray dependent controls without changing choices")
    func disabledFasterDesktopTransitions() throws {
        var settings = AppSettings()
        settings.features.numberShortcuts = true
        settings.features.controlArrows = false
        settings.features.trackpadSwipes = true
        settings.features.setFasterDesktopSwitching(false)
        let view = SettingsView(
            viewModel: SettingsViewModel(settings: settings),
            selectedSection: .desktops
        )
        let image = try #require(renderSwiftUI(view, size: NSSize(width: 820, height: 620)))
        try saveImage(image, name: "settings_faster_desktop_transitions_disabled")
    }

    @Test("Minimal onboarding pages fit the window", arguments: ["welcome", "permission", "one-desktop", "workspace", "workspace-no-previews", "previews", "previews-disabled", "speed", "ready", "small-welcome", "small-permission", "small-one-desktop", "small-previews", "small-speed", "small-ready", "dark-welcome", "dark-permission", "dark-workspace", "dark-one-desktop", "dark-previews", "dark-speed", "dark-ready"])
    func onboardingPages(_ state: String) throws {
        let outputName = state
        let smallScreen = state.hasPrefix("small-")
        let dark = state.hasPrefix("dark-")
        let state = state.replacingOccurrences(of: "small-", with: "").replacingOccurrences(of: "dark-", with: "")
        let page: OnboardingPage = switch state {
        case "welcome", "permission": .welcome
        case "previews", "previews-disabled": .previews
        case "speed": .speed
        case "ready": .ready
        default: .workspace
        }
        let vm = OnboardingViewModel(permissionClient: PreviewOnboardingPermissionClient(
            accessibilityGranted: state != "permission", screenRecordingGranted: !["permission", "workspace-no-previews", "previews-disabled"].contains(state)),
            checkpoint: .init(page: page))
        vm.updateEnvironment(desktopCount: state == "one-desktop" ? 1 : 3)
        let image = try #require(renderSwiftUI(
            OnboardingView(viewModel: vm, previewDirectory: Self.outputDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/media"),
                iconURL: Self.outputDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns"))
                .environment(\.colorScheme, dark ? .dark : .light),
            size: NSSize(width: 820, height: smallScreen ? 570 : 650)))
        try saveImage(image, name: "onboarding_\(outputName)")
    }

    @Test("Optional tutorial has separate exercise and completion views", arguments: ["workspace", "previews", "ready", "disabled"])
    func tutorialPages(_ state: String) throws {
        let page: TutorialPage = state == "previews" ? .previews : state == "ready" ? .ready : .workspace
        let vm = TutorialViewModel(permissionClient: PreviewOnboardingPermissionClient(accessibilityGranted: true),
            checkpoint: .init(page: page, workspacePracticed: false, allWindowsPracticed: false))
        vm.features.workspaceIsolation = state != "disabled"
        vm.setTarget(.init(windowID: 42, originDesktop: 0, destinationDesktop: 1, title: "Next lesson"))
        let image = try #require(renderSwiftUI(TutorialView(viewModel: vm), size: NSSize(width: 820, height: 650)))
        try saveImage(image, name: "tutorial_\(state)")
    }

}

@MainActor
private final class PreviewOnboardingPermissionClient: OnboardingPermissionClient {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool

    init(accessibilityGranted: Bool = false, screenRecordingGranted: Bool = false) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
    }

    func currentState() -> OnboardingPermissionState {
        OnboardingPermissionState(
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted
        )
    }

    func requestAccessibility() {}
    func requestScreenRecording() {}
}
