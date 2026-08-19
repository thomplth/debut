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
            .appendingPathComponent("Screenshots")
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

    private func makeSampleViewModel(stageCount: Int = 3, windowsPerStage: [Int] = [3, 4, 2], activeIndex: Int = 1) -> OverlayViewModel {
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
        return OverlayViewModel(stageManager: sm, activeStageIndex: activeIndex, selectedWindowIndex: 1)
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

    @Test("Add-stage buttons render above the first and below the last plate")
    func stageInsertButtons() throws {
        let vm = makeSampleViewModel(stageCount: 3, windowsPerStage: [3, 4, 2], activeIndex: 1)
        let size = NSSize(width: 1200, height: 600)

        for edge in [StageInsertionEdge.top, .bottom] {
            guard let img = renderSwiftUI(
                OverlaySwiftUIView(viewModel: vm, initialStageInsertionEdge: edge),
                size: size
            ) else {
                throw ScreenshotError.renderFailed
            }
            try saveImage(img, name: "10_stage_insert_button_\(edge)")
        }

        #expect(vm.plates.count == 3)
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

    @Test("A held plate takes its destination slot without drifting sideways")
    func heldPlateTakesDestinationSlot() throws {
        let vm = makeSampleViewModel(stageCount: 3, windowsPerStage: [3, 4, 2], activeIndex: 1)
        let size = NSSize(width: 1200, height: 600)
        let drag = StageDragState(
            stageIndex: 2,
            stageID: vm.plates[2].id,
            verticalTranslation: -260,
            destinationIndex: 0
        )
        let idle = renderPlateFrames(OverlaySwiftUIView(viewModel: vm), size: size)
        let dragging = renderPlateFrames(
            OverlaySwiftUIView(viewModel: vm, initialStageDrag: drag),
            size: size
        )

        guard let idleHeld = idle[2], let heldPlate = dragging[2],
              let displaced = dragging[0]
        else { throw ScreenshotError.renderFailed }

        #expect(heldPlate.midY < displaced.midY)
        #expect(abs(heldPlate.midX - idleHeld.midX) < 0.5)
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
