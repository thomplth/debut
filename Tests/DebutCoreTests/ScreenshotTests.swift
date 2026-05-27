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

    private func saveImage(_ image: NSImage, name: String) throws {
        let url = Self.outputDir.appendingPathComponent("\(name).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ScreenshotError.renderFailed }
        try png.write(to: url)
        NSLog("[ScreenshotTest] Saved: \(url.path)")
    }

    enum ScreenshotError: Error { case renderFailed }

    private func makeSampleViewModel(stageCount: Int = 3, appsPerStage: [Int] = [3, 4, 2], activeIndex: Int = 1) -> OverlayViewModel {
        var sm = StageManager()
        let stageNames = ["Email", "Coding", "Review", "Design", "Chat"]
        let apps = [
            ("com.apple.mail", "Mail"),
            ("com.apple.Safari", "Safari"),
            ("com.apple.Terminal", "Terminal"),
            ("com.microsoft.VSCode", "VS Code"),
            ("com.tinyspeck.slackmacgap", "Slack"),
            ("com.apple.finder", "Finder"),
            ("com.apple.Notes", "Notes"),
            ("com.google.Chrome", "Chrome"),
            ("com.apple.dt.Xcode", "Xcode"),
            ("com.apple.Preview", "Preview"),
        ]

        let defaultID = sm.stages[0].id
        var windowCounter = 1

        for i in 0..<stageCount {
            if i == 0 {
                sm.renameStage(id: defaultID, to: stageNames[i % stageNames.count])
                let count = appsPerStage[i % appsPerStage.count]
                for j in 0..<count {
                    let app = apps[(i * 4 + j) % apps.count]
                    sm.addWindow(StageWindow(windowID: windowCounter, appBundleID: app.0, appName: app.1, isShared: false), toStageID: defaultID)
                    windowCounter += 1
                }
            } else {
                sm.activateStage(id: sm.stages[i - 1].id)
                sm.createStage(name: stageNames[i % stageNames.count], position: .below)
                let stageID = sm.stages[i].id
                let count = appsPerStage[i % appsPerStage.count]
                for j in 0..<count {
                    let app = apps[(i * 4 + j) % apps.count]
                    sm.addWindow(StageWindow(windowID: windowCounter, appBundleID: app.0, appName: app.1, isShared: false), toStageID: stageID)
                    windowCounter += 1
                }
            }
        }

        sm.activateStage(id: sm.stages[min(activeIndex, sm.stages.count - 1)].id)
        return OverlayViewModel(stageManager: sm, activeStageIndex: activeIndex, selectedAppIndex: 0)
    }

    @Test("Single plate renders")
    func singlePlate() throws {
        let vm = makeSampleViewModel(stageCount: 1, appsPerStage: [4], activeIndex: 0)
        let size = NSSize(width: 600, height: 160)
        let view = OverlaySwiftUIView(viewModel: vm)
        guard let img = renderSwiftUI(view, size: size) else { throw ScreenshotError.renderFailed }
        try saveImage(img, name: "01_single_plate")
        #expect(vm.plates[0].apps.count == 4)
    }

    @Test("Three plates with active in middle")
    func threePlates() throws {
        let vm = makeSampleViewModel(stageCount: 3, appsPerStage: [3, 4, 2], activeIndex: 1)
        let size = NSSize(width: 800, height: 500)
        let view = OverlaySwiftUIView(viewModel: vm)
        guard let img = renderSwiftUI(view, size: size) else { throw ScreenshotError.renderFailed }
        try saveImage(img, name: "02_three_plates")
        #expect(vm.plates.count == 3)
    }

    @Test("Five plates with overflow")
    func fivePlates() throws {
        let vm = makeSampleViewModel(stageCount: 5, appsPerStage: [3, 5, 2, 4, 3], activeIndex: 2)
        let size = NSSize(width: 900, height: 800)
        let view = OverlaySwiftUIView(viewModel: vm)
        guard let img = renderSwiftUI(view, size: size) else { throw ScreenshotError.renderFailed }
        try saveImage(img, name: "03_five_plates")
        #expect(vm.plates.count == 5)
    }

    @Test("Empty stage plate")
    func emptyStage() throws {
        let vm = makeSampleViewModel(stageCount: 2, appsPerStage: [3, 0], activeIndex: 0)
        let size = NSSize(width: 800, height: 350)
        let view = OverlaySwiftUIView(viewModel: vm)
        guard let img = renderSwiftUI(view, size: size) else { throw ScreenshotError.renderFailed }
        try saveImage(img, name: "04_empty_stage")
        #expect(vm.plates[1].apps.isEmpty)
    }

    @Test("Selection on third app")
    func selectionState() throws {
        let vm = OverlayViewModel(
            stageManager: makeSampleViewModel(stageCount: 2, appsPerStage: [4, 3], activeIndex: 0).stageManager,
            activeStageIndex: 0,
            selectedAppIndex: 2
        )
        let size = NSSize(width: 800, height: 350)
        let view = OverlaySwiftUIView(viewModel: vm)
        guard let img = renderSwiftUI(view, size: size) else { throw ScreenshotError.renderFailed }
        try saveImage(img, name: "05_selection_state")
        #expect(vm.selectedAppIndex == 2)
    }
}
