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

    private func renderPlateFrames<V: View>(_ view: V, size: NSSize) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        let rootView = view
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(PlateFramePreferenceKey.self) { frames = $0 }
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

    private func renderPlateSurfaceFrames<V: View>(_ view: V, size: NSSize) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        let rootView = view
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(PlateSurfaceFramePreferenceKey.self) { frames = $0 }
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

    enum ScreenshotError: Error { case renderFailed }

    private func makeSampleViewModel(
        stageCount: Int = 3,
        windowsPerStage: [Int] = [3, 4, 2],
        activeIndex: Int = 1,
        appearance: AppSettings = AppSettings()
    ) -> OverlayViewModel {
        var sm = StageManager()
        let windowData: [(String, String, String)] = [
            ("com.apple.mail", "Mail", "Inbox"), ("com.apple.Safari", "Safari", "Google"),
            ("com.apple.Terminal", "Terminal", "~ zsh"), ("com.microsoft.VSCode", "VS Code", "main.swift"),
            ("com.tinyspeck.slackmacgap", "Slack", "#general"), ("com.apple.finder", "Finder", "Downloads"),
            ("com.apple.Notes", "Notes", "Meeting Notes"), ("com.google.Chrome", "Chrome", "GitHub"),
            ("com.apple.dt.Xcode", "Xcode", "Debut.xcodeproj"), ("com.apple.Preview", "Preview", "screenshot.png"),
        ]
        let defaultID = sm.stages[0].id
        var windowCounter: CGWindowID = 100

        for i in 0..<stageCount {
            if i == 0 {
                for _ in 0..<windowsPerStage[i % windowsPerStage.count] {
                    let w = windowData[Int(windowCounter - 100) % windowData.count]
                    sm.addWindow(StageWindow(windowID: windowCounter, ownerBundleID: w.0, ownerName: w.1, windowTitle: w.2), toStageID: defaultID)
                    windowCounter += 1
                }
            } else {
                sm.activateStage(id: sm.stages[i - 1].id)
                sm.createStage(position: .below)
                let stageID = sm.stages[i].id
                for _ in 0..<windowsPerStage[i % windowsPerStage.count] {
                    let w = windowData[Int(windowCounter - 100) % windowData.count]
                    sm.addWindow(StageWindow(windowID: windowCounter, ownerBundleID: w.0, ownerName: w.1, windowTitle: w.2), toStageID: stageID)
                    windowCounter += 1
                }
            }
        }
        sm.activateStage(id: sm.stages[min(activeIndex, sm.stages.count - 1)].id)
        return OverlayViewModel(
            stageManager: sm,
            activeStageIndex: activeIndex,
            selectedWindowIndex: 1,
            appearance: appearance
        )
    }

    @Test("Three plates render correctly")
    func threePlates() throws {
        let vm = makeSampleViewModel(stageCount: 3, windowsPerStage: [3, 4, 2], activeIndex: 1)
        guard let img = renderSwiftUI(OverlaySwiftUIView(viewModel: vm), size: NSSize(width: 1200, height: 600)) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "02_three_plates")
        #expect(vm.plates.count == 3)
    }

    @Test("Many plates render with a depth gradient")
    func manyPlatesDepthGradient() throws {
        let vm = makeSampleViewModel(
            stageCount: 9,
            windowsPerStage: [2, 3, 1],
            activeIndex: 4
        )
        guard let img = renderSwiftUI(
            OverlaySwiftUIView(viewModel: vm),
            size: NSSize(width: 1200, height: 700)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "02_many_plates_depth_gradient")
        #expect(vm.plates.count == 9)
    }

    @Test("Selection on second window")
    func selectionState() throws {
        let vm = OverlayViewModel(
            stageManager: makeSampleViewModel(stageCount: 2, windowsPerStage: [5, 3], activeIndex: 0).stageManager,
            activeStageIndex: 0, selectedWindowIndex: 2
        )
        guard let img = renderSwiftUI(OverlaySwiftUIView(viewModel: vm), size: NSSize(width: 1200, height: 400)) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "05_selection_state")
        #expect(vm.selectedWindowIndex == 2)
    }

    /// Pins the scale so the wrap threshold under test is a property of the width, not of
    /// whatever the plate-scale default happens to be.
    private func unscaledAppearance() -> AppSettings {
        var settings = AppSettings()
        settings.plateScale = 1
        return settings
    }

    @Test("A plate too wide for the display renders its windows in balanced rows")
    func widePlateWrapsIntoRows() throws {
        let metrics = PlateMetrics.standard
        let vm = makeSampleViewModel(
            stageCount: 1,
            windowsPerStage: [8],
            activeIndex: 0,
            appearance: unscaledAppearance()
        )
        let size = NSSize(width: 1200, height: 700)

        guard let img = renderSwiftUI(OverlaySwiftUIView(viewModel: vm), size: size) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "06_wrapped_plate_rows")

        let frames = renderWindowFrames(OverlaySwiftUIView(viewModel: vm), size: size)
        let cards = (0..<8).map { frames[WindowFrameID(stageIndex: 0, windowIndex: $0)]! }
        let rows = Dictionary(grouping: cards) { ($0.midY * 10).rounded() }

        #expect(rows.count == 2)
        #expect(rows.values.allSatisfy { $0.count == 4 })
        #expect(cards.allSatisfy { $0.maxX <= size.width })

        guard let plate = renderPlateSurfaceFrames(
            OverlaySwiftUIView(viewModel: vm),
            size: size
        )[0] else { throw ScreenshotError.renderFailed }
        #expect(abs(plate.height
            - (metrics.cardHeight * 2 + metrics.rowSpacing
                + metrics.topPadding + metrics.bottomPadding)) < 0.5)

        // What is drawn has to be where the geometry says, or drag projection and the E2E hit
        // tests are aiming at slots the view never used.
        let layout = PlateWindowLayout(
            windowCount: 8,
            availableWidth: PlateConstants.availablePlateWidth(screenWidth: size.width),
            metrics: metrics
        )
        for (index, card) in cards.enumerated() {
            let expected = layout.cardOffsetFromCenter(at: index)
            #expect(abs(card.midX - (plate.midX + expected.width)) < 0.5)
            #expect(abs(card.midY - (plate.midY + expected.height)) < 0.5)
        }
    }

    @Test("The plate scale setting reaches the cards the overlay actually draws")
    func plateScaleEnlargesRenderedCards() throws {
        let size = NSSize(width: 1600, height: 1000)
        let counts = [4]

        func cardSize(plateScale: Double) -> CGSize {
            var settings = AppSettings()
            settings.plateScale = plateScale
            let vm = makeSampleViewModel(
                stageCount: 1,
                windowsPerStage: counts,
                activeIndex: 0,
                appearance: settings
            )
            let frames = renderWindowFrames(OverlaySwiftUIView(viewModel: vm), size: size)
            return frames[WindowFrameID(stageIndex: 0, windowIndex: 0)]!.size
        }

        let unscaled = cardSize(plateScale: 1)
        let enlarged = cardSize(plateScale: AppSettings.defaultPlateScale)

        #expect(abs(enlarged.width - unscaled.width * 1.5) < 0.5)
        #expect(abs(enlarged.height - unscaled.height * 1.5) < 0.5)

        // E2E clicks screen coordinates it derives from drawnMetrics, so a card drawn at any
        // other size sends those clicks somewhere the overlay never drew.
        let expected = PlateConstants.drawnMetrics(
            plateScale: CGFloat(AppSettings.defaultPlateScale),
            windowCounts: counts,
            containerSize: size
        )
        #expect(abs(enlarged.width - expected.cardWidth) < 0.5)
        #expect(abs(enlarged.height - expected.cardHeight) < 0.5)
    }

    @Test("The default plate scale still fits the display, and a crowded stage shrinks to fit")
    func defaultPlateScaleFitsTheDisplay() throws {
        let size = NSSize(width: 1440, height: 900)
        let vm = makeSampleViewModel(stageCount: 1, windowsPerStage: [6], activeIndex: 0)

        guard let img = renderSwiftUI(OverlaySwiftUIView(viewModel: vm), size: size) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "06_default_plate_scale")

        guard let plate = renderPlateSurfaceFrames(
            OverlaySwiftUIView(viewModel: vm),
            size: size
        )[0] else { throw ScreenshotError.renderFailed }
        #expect(plate.width <= PlateConstants.availablePlateWidth(screenWidth: size.width))
        #expect(plate.height <= PlateConstants.availablePlateHeight(screenHeight: size.height))

        // The same display cannot hold twenty windows at the requested scale, so the overlay
        // has to give scale back rather than draw a plate off the bottom of the screen.
        let crowded = makeSampleViewModel(stageCount: 1, windowsPerStage: [20], activeIndex: 0)
        guard let crowdedPlate = renderPlateSurfaceFrames(
            OverlaySwiftUIView(viewModel: crowded),
            size: size
        )[0] else { throw ScreenshotError.renderFailed }

        #expect(crowdedPlate.width <= PlateConstants.availablePlateWidth(screenWidth: size.width))
        #expect(crowdedPlate.height <= PlateConstants.availablePlateHeight(screenHeight: size.height))
    }

    @Test("Dragging a window preview does not shift the plate stack")
    func windowDragPreviewDoesNotShiftPlateStack() throws {
        let vm = makeSampleViewModel(stageCount: 3, windowsPerStage: [3, 4, 2], activeIndex: 1)
        let size = NSSize(width: 1200, height: 600)
        let drag = WindowDragState(
            windowID: vm.plates[1].windows[0].id,
            sourceStageIndex: 1,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 300),
            dropTarget: nil
        )
        let idleFrames = renderPlateFrames(OverlaySwiftUIView(viewModel: vm), size: size)
        let draggingFrames = renderPlateFrames(
            OverlaySwiftUIView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        guard let idleFrame = idleFrames[1], let draggingFrame = draggingFrames[1] else {
            throw ScreenshotError.renderFailed
        }
        #expect(abs(idleFrame.midY - draggingFrame.midY) < 0.5)
    }

    @Test("Window frame preferences remain stable drag-slot anchors")
    func windowFramesRemainStableDragSlotAnchors() throws {
        let vm = makeSampleViewModel(stageCount: 1, windowsPerStage: [3], activeIndex: 0)
        let size = NSSize(width: 1200, height: 400)
        let drag = WindowDragState(
            windowID: vm.plates[0].windows[0].id,
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 200),
            dropTarget: WindowDropTarget(stageIndex: 0, windowIndex: 2)
        )
        let idle = renderWindowFrames(OverlaySwiftUIView(viewModel: vm), size: size)
        let dragging = renderWindowFrames(
            OverlaySwiftUIView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        #expect(abs(
            dragging[WindowFrameID(stageIndex: 0, windowIndex: 0)]!.midX
                - idle[WindowFrameID(stageIndex: 0, windowIndex: 0)]!.midX
        ) < 0.5)
    }

    @Test("Cross-stage drag grows the target plate before drop")
    func crossStageDragFocusesTargetPlate() throws {
        let vm = makeSampleViewModel(stageCount: 2, windowsPerStage: [2, 2], activeIndex: 0)
        let size = NSSize(width: 1200, height: 500)
        let drag = WindowDragState(
            windowID: vm.plates[0].windows[0].id,
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 330),
            dropTarget: WindowDropTarget(stageIndex: 1, windowIndex: 0)
        )
        let idle = renderPlateFrames(OverlaySwiftUIView(viewModel: vm), size: size)
        let dragging = renderPlateFrames(
            OverlaySwiftUIView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        #expect(idle[0]!.width > idle[1]!.width)
        #expect(dragging[1]!.width > dragging[0]!.width)
    }

    @Test("Cross-stage drag resizes the rendered plate surfaces")
    func crossStageDragResizesPlateSurfaces() throws {
        let vm = makeSampleViewModel(stageCount: 2, windowsPerStage: [2, 2], activeIndex: 0)
        let size = NSSize(width: 1200, height: 500)
        let drag = WindowDragState(
            windowID: vm.plates[0].windows[0].id,
            sourceStageIndex: 0,
            sourceWindowIndex: 0,
            location: CGPoint(x: 600, y: 330),
            dropTarget: WindowDropTarget(stageIndex: 1, windowIndex: 0)
        )
        let idle = renderPlateSurfaceFrames(OverlaySwiftUIView(viewModel: vm), size: size)
        let dragging = renderPlateSurfaceFrames(
            OverlaySwiftUIView(viewModel: vm, initialWindowDrag: drag),
            size: size
        )

        #expect(dragging[0]!.width < idle[0]!.width)
        #expect(dragging[1]!.width > idle[1]!.width)
    }

    @Test("Cross-stage drag keeps source icons inside its centered plate surface")
    func crossStageDragKeepsSourceIconsInsidePlateSurface() throws {
        let vm = makeSampleViewModel(stageCount: 2, windowsPerStage: [3, 2], activeIndex: 0)
        let size = NSSize(width: 1200, height: 500)
        let drag = WindowDragState(
            windowID: vm.plates[0].windows[2].id,
            sourceStageIndex: 0,
            sourceWindowIndex: 2,
            location: CGPoint(x: 600, y: 330),
            dropTarget: WindowDropTarget(stageIndex: 1, windowIndex: 0)
        )
        let view = OverlaySwiftUIView(viewModel: vm, initialWindowDrag: drag)
        let surfaces = renderPlateSurfaceFrames(view, size: size)
        let windows = renderWindowFrames(view, size: size)

        let sourceSurface = try #require(surfaces[0])
        let visibleSourceFrames = windows
            .filter { $0.key.stageIndex == 0 && $0.key.windowIndex != 2 }
            .map(\.value)
        let sourceBounds = try #require(visibleSourceFrames.reduce(nil as CGRect?) { bounds, frame in
            bounds.map { $0.union(frame) } ?? frame
        })

        #expect(sourceBounds.minX >= sourceSurface.minX)
        #expect(sourceBounds.maxX <= sourceSurface.maxX)
        #expect(abs(sourceBounds.midX - sourceSurface.midX) < 0.5)
    }

    @Test("Display stack indicator clears the menu bar")
    func displayStackIndicatorClearsMenuBar() throws {
        var manager = makeSampleViewModel(
            stageCount: 3,
            windowsPerStage: [3, 2, 1],
            activeIndex: 1
        ).stageManager
        manager.reconcileStageStacks(with: SpaceTopology(separateSpaces: true, stacks: [
            SpaceStackDescriptor(
                id: "display-a", displayID: 1, displayName: "Studio Display",
                frame: .zero, desktopIDs: [10, 11, 12], currentDesktopID: 11
            ),
            SpaceStackDescriptor(
                id: "display-b", displayID: 2, displayName: "Built-in Display",
                frame: .zero, desktopIDs: [20], currentDesktopID: 20
            ),
        ]))
        let vm = OverlayViewModel(
            stageManager: manager,
            activeStageIndex: 1,
            selectedWindowIndex: 1,
            displayTopContentInset: 22
        )

        guard let image = renderSwiftUI(
            OverlaySwiftUIView(viewModel: vm),
            size: NSSize(width: 1200, height: 600)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(image, name: "07_display_stack_indicator_below_menu_bar")

        #expect(vm.displayStackCount == 2)
        #expect(vm.displayStackIndicatorTopPadding == 40)
    }

    @Test("Onboarding welcome screen")
    func onboardingWelcome() throws {
        let vm = OnboardingViewModel(permissionClient: PreviewOnboardingPermissionClient())
        guard let img = renderSwiftUI(
            OnboardingView(viewModel: vm),
            size: NSSize(width: 760, height: 560)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "07_onboarding_welcome")
        #expect(vm.page == .welcome)
    }

    @Test("Onboarding permission screen")
    func onboardingPermissions() throws {
        let vm = OnboardingViewModel(permissionClient: PreviewOnboardingPermissionClient())
        vm.continueFromWelcome()
        guard let img = renderSwiftUI(
            OnboardingView(viewModel: vm),
            size: NSSize(width: 760, height: 560)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "08_onboarding_permissions")
        #expect(vm.page == .permissions)
    }

    @Test("Onboarding tutorial screen")
    func onboardingTutorial() throws {
        let vm = OnboardingViewModel(
            permissionClient: PreviewOnboardingPermissionClient(
                accessibilityGranted: true,
                screenRecordingGranted: true
            )
        )
        vm.continueFromWelcome()
        vm.startTutorial()
        guard let img = renderSwiftUI(
            OnboardingView(viewModel: vm),
            size: NSSize(width: 760, height: 560)
        ) else {
            throw ScreenshotError.renderFailed
        }
        try saveImage(img, name: "09_onboarding_tutorial")
        #expect(vm.page == .tutorial)
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
