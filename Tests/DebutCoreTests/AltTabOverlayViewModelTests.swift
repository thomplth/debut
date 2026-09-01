import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Alt-tab overlay view model")
struct AltTabOverlayViewModelTests {
    private func entry(_ spaceID: UUID, _ windowID: CGWindowID, _ title: String) -> GlobalWindowEntry {
        GlobalWindowEntry(
            spaceID: spaceID,
            window: SpaceWindow(
                windowID: windowID,
                ownerBundleID: "com.test.\(windowID)",
                ownerName: "App \(windowID)",
                windowTitle: title
            )
        )
    }

    private func solidImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// The whole point of the switcher: which space a window lives on stops being structure and
    /// becomes invisible, so two spaces' windows sit in one list in the order they were handed over.
    @Test("Every space's windows flatten into one ordered list")
    func flattensSpaces() {
        let first = UUID()
        let second = UUID()
        let model = AltTabOverlayViewModel(
            entries: [
                entry(first, 1, "One"),
                entry(second, 2, "Two"),
                entry(first, 3, "Three"),
            ],
            selectedIndex: 0
        )

        #expect(model.windows.map(\.windowID) == [1, 2, 3])
        #expect(model.windows.map(\.displayTitle) == ["One", "Two", "Three"])
    }

    @Test("A card carries the preview captured for its window")
    func carriesPreviews() {
        let space = UUID()
        let image = solidImage()
        let model = AltTabOverlayViewModel(
            entries: [entry(space, 1, "One"), entry(space, 2, "Two")],
            selectedIndex: 0,
            windowPreviews: [2: image]
        )

        #expect(model.windows[0].previewImage == nil)
        #expect(model.windows[1].previewImage != nil)
    }

    @Test("The selection resolves the card at its index")
    func resolvesSelection() {
        let space = UUID()
        let model = AltTabOverlayViewModel(
            entries: [entry(space, 1, "One"), entry(space, 2, "Two")],
            selectedIndex: 1
        )

        #expect(model.selectedWindow?.windowID == 2)
        #expect(model.isSelected(1))
        #expect(!model.isSelected(0))
    }

    /// The controller can hand over an index for a window that a reconcile has just removed, so
    /// an out-of-range selection has to draw an unselected list rather than trap.
    @Test("An out-of-range selection resolves to no window")
    func outOfRangeSelection() {
        let model = AltTabOverlayViewModel(
            entries: [entry(UUID(), 1, "One")],
            selectedIndex: 4
        )

        #expect(model.selectedWindow == nil)
        #expect(!model.isSelected(0))
    }

    @Test("An empty list draws no cards and resolves no selection")
    func emptyList() {
        let model = AltTabOverlayViewModel(entries: [], selectedIndex: 0)

        #expect(model.windows.isEmpty)
        #expect(model.selectedWindow == nil)
    }

    /// The flat list is one stage holding every window, so it reuses the stage grid rather than
    /// growing a second layout that could disagree about how big a card is.
    @Test("The flat list wraps into one balanced grid")
    func wrapsIntoBalancedGrid() {
        let space = UUID()
        let model = AltTabOverlayViewModel(
            entries: (1...5).map { entry(space, CGWindowID($0), "W\($0)") },
            selectedIndex: 0
        )
        let metrics = StageMetrics.standard
        let width = StageWindowLayout.columnCapacity(availableWidth: 900, metrics: metrics)

        let layout = model.layout(containerSize: CGSize(width: 900 + StageConstants.screenMargin * 2, height: 900))

        #expect(width == 4)
        #expect(layout.windowCount == 5)
        #expect(layout.rowSizes == [3, 2])
    }

    /// A global list is far longer than any one space's, so it is the first thing in the app that
    /// routinely overflows the display. It must give scale back rather than draw off-screen.
    @Test("A list too large for the display gives scale back until it fits")
    func shrinksToFit() {
        let space = UUID()
        let container = CGSize(width: 1440, height: 900)
        let few = AltTabOverlayViewModel(
            entries: (1...4).map { entry(space, CGWindowID($0), "W\($0)") },
            selectedIndex: 0
        )
        let many = AltTabOverlayViewModel(
            entries: (1...60).map { entry(space, CGWindowID($0), "W\($0)") },
            selectedIndex: 0
        )

        let fewMetrics = few.metrics(containerSize: container)
        let manyMetrics = many.metrics(containerSize: container)

        #expect(manyMetrics.thumbnailWidth < fewMetrics.thumbnailWidth)
        #expect(
            many.layout(containerSize: container).stageSize.height
                <= StageConstants.availableStageHeight(screenHeight: container.height)
        )
    }
}
