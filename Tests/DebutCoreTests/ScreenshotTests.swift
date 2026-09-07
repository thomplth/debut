import Testing
import AppKit
import SwiftUI
import Foundation
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

    private func renderSwiftUI<V: View>(_ view: V, size: NSSize) -> NSImage? {
        let hostingView = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: NSColor(white: 0.1, alpha: 1.0)))
        )
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
        let background = lhs.colorAt(x: 0, y: 0) ?? .black
        var totalDifference = 0.0
        var changedPixels = 0
        var comparedPixels = 0

        for x in 0..<lhs.pixelsWide {
            for y in 0..<lhs.pixelsHigh {
                guard let left = lhs.colorAt(x: x, y: y),
                      let right = rhs.colorAt(x: x, y: y)
                else { continue }
                let leftFromBackground = max(
                    abs(left.redComponent - background.redComponent),
                    abs(left.greenComponent - background.greenComponent),
                    abs(left.blueComponent - background.blueComponent)
                )
                let rightFromBackground = max(
                    abs(right.redComponent - background.redComponent),
                    abs(right.greenComponent - background.greenComponent),
                    abs(right.blueComponent - background.blueComponent)
                )
                guard max(leftFromBackground, rightFromBackground) > 0.01 else { continue }

                let redDifference = abs(left.redComponent - right.redComponent)
                let greenDifference = abs(left.greenComponent - right.greenComponent)
                let blueDifference = abs(left.blueComponent - right.blueComponent)
                let alphaDifference = abs(left.alphaComponent - right.alphaComponent)
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
                sm.createSpace(position: .below)
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

        #expect(viewModel.windows.count == 9)
        #expect(viewModel.selectedWindow?.windowID == entries[2].window.windowID)
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
            appearance: AppSettings()
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

    @Test("Magnify remains available as a selection style")
    func magnifySelectionState() throws {
        var appearance = AppSettings()
        appearance.windowSelectionStyle = .magnify
        appearance.magnifyScale = 1.12
        appearance.magnifyShadowStrength = 1.5
        let vm = StageOverlayViewModel(
            spaceManager: makeSampleViewModel(
                spaceCount: 1,
                windowsPerSpace: [3],
                activeIndex: 0
            ).spaceManager,
            activeSpaceIndex: 0,
            selectedWindowIndex: 1,
            appearance: appearance
        )
        guard let image = renderSwiftUI(
            StageOverlayView(viewModel: vm),
            size: NSSize(width: 900, height: 300)
        ) else { throw ScreenshotError.renderFailed }

        try saveImage(image, name: "05_magnify_selection_state")
        #expect(vm.appearance.windowSelectionStyle == .magnify)
    }

    /// Pins the scale so the wrap threshold under test is a property of the width, not of
    /// whatever the stage-scale default happens to be.
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
        #expect(abs(stage.height
            - (metrics.cardHeight * 2 + metrics.rowSpacing
                + metrics.topPadding + metrics.bottomPadding)) < 0.5)

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

        #expect(abs(enlarged.width - unscaled.width * enlargedScale) < 0.5)
        #expect(abs(enlarged.height - unscaled.height * enlargedScale) < 0.5)

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

    @Test("A 150 percent stage scale is a proportional rendering of the original UI")
    func enlargedStageScalePreservesRenderedProportions() throws {
        let originalSize = NSSize(width: 1_200, height: 600)
        let scale: CGFloat = 1.5
        let enlargedSize = NSSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )

        var originalAppearance = AppSettings()
        originalAppearance.stageScale = 1
        let original = try #require(renderSwiftUI(
            StageOverlayView(viewModel: makeSampleViewModel(
                spaceCount: 3,
                windowsPerSpace: [3, 4, 2],
                activeIndex: 1,
                appearance: originalAppearance
            )),
            size: originalSize
        ))
        var enlargedAppearance = AppSettings()
        enlargedAppearance.stageScale = Double(scale)
        let enlarged = try #require(renderSwiftUI(
            StageOverlayView(viewModel: makeSampleViewModel(
                spaceCount: 3,
                windowsPerSpace: [3, 4, 2],
                activeIndex: 1,
                appearance: enlargedAppearance
            )),
            size: enlargedSize
        ))
        let originalBitmap = try #require(normalizedBitmap(original, size: originalSize))
        let normalizedEnlarged = try #require(normalizedBitmap(enlarged, size: originalSize))

        let normalizedImage = NSImage(size: originalSize)
        normalizedImage.addRepresentation(normalizedEnlarged)
        try saveImage(original, name: "06_proportional_scale_original")
        try saveImage(normalizedImage, name: "06_proportional_scale_normalized_150_percent")

        let difference = screenshotDifference(originalBitmap, normalizedEnlarged)
        #expect(difference.comparedPixelCount > 10_000)
        #expect(
            difference.meanChannelDifference < 0.035,
            "mean normalized screenshot difference was \(difference.meanChannelDifference)"
        )
        #expect(
            difference.changedPixelRatio < 0.12,
            "normalized screenshot changed-pixel ratio was \(difference.changedPixelRatio)"
        )
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

    @Test("Dragging a window preview does not shift the stage stack")
    func windowDragPreviewDoesNotShiftStageStack() throws {
        let vm = makeSampleViewModel(spaceCount: 3, windowsPerSpace: [3, 4, 2], activeIndex: 1)
        let size = NSSize(width: 1200, height: 600)
        let drag = WindowDragState(
            windowID: vm.stages[1].windows[0].id,
            sourceSpaceIndex: 1,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 300),
            dropTarget: nil
        )
        let idleFrames = renderStageFrames(StageOverlayView(viewModel: vm), size: size)
        let draggingFrames = renderStageFrames(
            StageOverlayView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        guard let idleFrame = idleFrames[1], let draggingFrame = draggingFrames[1] else {
            throw ScreenshotError.renderFailed
        }
        #expect(abs(idleFrame.midY - draggingFrame.midY) < 0.5)
    }

    @Test("Window frame preferences remain stable drag-slot anchors")
    func windowFramesRemainStableDragSlotAnchors() throws {
        let vm = makeSampleViewModel(spaceCount: 1, windowsPerSpace: [3], activeIndex: 0)
        let size = NSSize(width: 1200, height: 400)
        let drag = WindowDragState(
            windowID: vm.stages[0].windows[0].id,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 200),
            dropTarget: WindowDropTarget(spaceIndex: 0, windowIndex: 2)
        )
        let idle = renderWindowFrames(StageOverlayView(viewModel: vm), size: size)
        let dragging = renderWindowFrames(
            StageOverlayView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        #expect(abs(
            dragging[WindowFrameID(spaceIndex: 0, windowIndex: 0)]!.midX
                - idle[WindowFrameID(spaceIndex: 0, windowIndex: 0)]!.midX
        ) < 0.5)
    }

    @Test("Cross-space drag grows the target stage before drop")
    func crossSpaceDragFocusesTargetStage() throws {
        let vm = makeSampleViewModel(spaceCount: 2, windowsPerSpace: [2, 2], activeIndex: 0)
        let size = NSSize(width: 1200, height: 500)
        let drag = WindowDragState(
            windowID: vm.stages[0].windows[0].id,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 330),
            dropTarget: WindowDropTarget(spaceIndex: 1, windowIndex: 0)
        )
        let idle = renderStageFrames(StageOverlayView(viewModel: vm), size: size)
        let dragging = renderStageFrames(
            StageOverlayView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        #expect(idle[0]!.width > idle[1]!.width)
        #expect(dragging[1]!.width > dragging[0]!.width)
    }

    @Test("Cross-space drag resizes the rendered stage surfaces")
    func crossSpaceDragResizesStageSurfaces() throws {
        let vm = makeSampleViewModel(spaceCount: 2, windowsPerSpace: [2, 2], activeIndex: 0)
        let size = NSSize(width: 1200, height: 500)
        let drag = WindowDragState(
            windowID: vm.stages[0].windows[0].id,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 330),
            dropTarget: WindowDropTarget(spaceIndex: 1, windowIndex: 0)
        )
        let idle = renderStageSurfaceFrames(StageOverlayView(viewModel: vm), size: size)
        let dragging = renderStageSurfaceFrames(
            StageOverlayView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        #expect(dragging[0]!.width < idle[0]!.width)
        #expect(dragging[1]!.width > idle[1]!.width)
    }

    @Test("Cross-space drag keeps source icons inside its centered stage surface")
    func crossSpaceDragKeepsSourceIconsInsideStageSurface() throws {
        let vm = makeSampleViewModel(spaceCount: 2, windowsPerSpace: [3, 2], activeIndex: 0)
        let size = NSSize(width: 1200, height: 500)
        let drag = WindowDragState(
            windowID: vm.stages[0].windows[2].id,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 2,
            location: CGPoint(x: 600, y: 330),
            dropTarget: WindowDropTarget(spaceIndex: 1, windowIndex: 0)
        )
        let view = StageOverlayView(viewModel: vm, initialWindowDrag: drag)
        let surfaces = renderStageSurfaceFrames(view, size: size)
        let windows = renderWindowFrames(view, size: size)

        let sourceSurface = try #require(surfaces[0])
        let visibleSourceFrames = windows
            .filter { $0.key.spaceIndex == 0 && $0.key.windowIndex != 2 }
            .map(\.value)
        let sourceBounds = try #require(visibleSourceFrames.reduce(nil as CGRect?) { bounds, frame in
            bounds.map { $0.union(frame) } ?? frame
        })

        #expect(sourceBounds.minX >= sourceSurface.minX)
        #expect(sourceBounds.maxX <= sourceSurface.maxX)
        #expect(abs(sourceBounds.midX - sourceSurface.midX) < 0.5)
    }

    @Test("Display stack indicator sits at the top of the overlay")
    func displayStackIndicator() throws {
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
        let vm = StageOverlayViewModel(
            spaceManager: manager,
            activeSpaceIndex: 1,
            selectedWindowIndex: 1
        )

        guard let image = renderSwiftUI(
            StageOverlayView(viewModel: vm),
            size: NSSize(width: 1200, height: 600)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(image, name: "07_display_stack_indicator")

        #expect(vm.displayStackCount == 2)
    }

    @Test("Launch settings sections render independently", arguments: SettingsSection.allCases)
    func settingsSections(_ section: SettingsSection) throws {
        let view = SettingsView(viewModel: SettingsViewModel(), selectedSection: section)
        let image = try #require(renderSwiftUI(view, size: NSSize(width: 820, height: 620)))
        try saveImage(image, name: "settings_\(section.rawValue)")
    }

    @Test("Onboarding pages and permission states fit the window", arguments: ["welcome", "permission", "one-desktop", "practice", "previews", "speed", "ready", "small-speed"])
    func onboardingPages(_ state: String) throws {
        let smallScreen = state == "small-speed"
        let state = smallScreen ? "speed" : state
        let vm = OnboardingViewModel(permissionClient: PreviewOnboardingPermissionClient(
            accessibilityGranted: state != "permission", screenRecordingGranted: false))
        if state != "welcome" { vm.advance() }
        if !["welcome", "permission", "one-desktop"].contains(state) {
            vm.updateEnvironment(desktopCount: 2, windowCount: 2)
        }
        if ["previews", "speed", "ready"].contains(state) {
            vm.recordPractice(.workspace)
            vm.advance()
        }
        if ["speed", "ready"].contains(state) {
            vm.useWithoutPreviews()
            vm.recordPractice(.allWindows)
            vm.advance()
        }
        if state == "ready" { vm.advance() }
        let image = try #require(renderSwiftUI(
            OnboardingView(viewModel: vm, previewDirectory: Self.outputDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/media")),
            size: NSSize(width: 860, height: smallScreen ? 620 : 700)))
        try saveImage(image, name: "onboarding_\(smallScreen ? "small-speed" : state)")
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
