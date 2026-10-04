import Testing
import CoreGraphics
@testable import DebutCore

/// E2E aims the pointer from the window shapes Debut exports, through the same layout code the
/// overlay draws with, so the export must not change what that code decides (KHA-854).
@Suite("Exported window aspects")
struct WindowAspectExportTests {
    @Test("Window aspects survive the export exactly, unmeasured windows and empty spaces included")
    func roundTripIsExact() {
        let aspects: [[CGFloat?]] = [[1.5698, 1024.0 / 738.0, nil], [], [0.1 + 0.2]]

        #expect(SpaceController.decodeWindowAspects(SpaceController.encode(aspects)) == aspects)
    }

    /// Observed in Tart: a window filling a 1024×738 overlay is exactly display-shaped, so its
    /// card is as wide as its neighbours and the stage draws 2 + 1. Rounded to four places it
    /// came back a hair narrower, the rows balanced as 1 + 2, and the pointer missed every card.
    @Test("A display-shaped window keeps the rows the overlay draws after the export")
    func exportKeepsRows() {
        let size = CGSize(width: 1024, height: 738)
        let aspects: [[CGFloat?]] = [[1.5698, 1.5698, size.width / size.height], [], [], []]
        func rows(_ aspects: [[CGFloat?]]) -> [Int] {
            let metrics = StageConstants.drawnMetrics(
                stageScale: 1.5, contentAspects: aspects, containerSize: size, cardSpacing: 12)
            return StageConstants.stageLayouts(
                forContentAspects: aspects, screenWidth: size.width, metrics: metrics)[0].rowSizes
        }

        let exported = SpaceController.decodeWindowAspects(SpaceController.encode(aspects))

        #expect(rows(aspects) == [2, 1])
        #expect(rows(exported) == rows(aspects))
    }
}
