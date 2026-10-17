import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import DebutCore

@MainActor
@Suite("Overlay desktop controls")
struct DesktopControlsTests {

    private func variants(_ counts: [Int], size: CGSize = CGSize(width: 1024, height: 768))
        -> (CompactDragVariants?, [NewDesktopPosition: UUID]) {
        let ids: [NewDesktopPosition: UUID] = [.top: UUID(), .bottom: UUID()]
        var viewModel = CompactDragLayoutTests.viewModel(counts)
        viewModel.canManageDesktops = true
        return (StageOverlayView.compactDragVariants(
            viewModel: viewModel, spaceIndex: 0, windowIndex: 0,
            containerSize: size, newDesktopIDs: ids
        ), ids)
    }

    @Test("A window drag reserves only a + at each end of the stack",
          arguments: [CGSize(width: 1024, height: 768), CGSize(width: 1280, height: 800)])
    func collapsedTargetsReserveOnlyTheButton(size: CGSize) throws {
        let (made, ids) = variants([9, 3, 0, 6], size: size)
        let collapsed = try #require(made?.collapsed)
        #expect(collapsed.stages.count == 4)
        #expect(collapsed.newDesktopStageIndex == nil)
        #expect(collapsed.newDesktopTargets.map(\.position) == [.top, .bottom])
        #expect(collapsed.newDesktopTargets.map(\.spaceID) == [ids[.top], ids[.bottom]])

        let projection = collapsed.projection(for: nil)
        let plates = try collapsed.stages.indices.map {
            try #require(collapsed.plateFrame(stageIndex: $0, projection: projection))
        }
        let top = try #require(collapsed.newDesktopTargets.first)
        let bottom = try #require(collapsed.newDesktopTargets.last)
        #expect(top.frame.maxY < plates[0].minY)
        #expect(bottom.frame.minY > plates[3].maxY)
        #expect(top.diameter >= DesktopControlGeometry.minimumDropTargetDiameter)
        for frame in plates + [top.frame, bottom.frame] {
            #expect(collapsed.usableBounds.insetBy(dx: -0.001, dy: -0.001).contains(frame))
        }

        // Only a button's height is reserved: the stack is laid out no smaller than a full
        // empty plate at either end would leave it.
        let open = try #require(made?.expanded[.bottom])
        #expect(collapsed.scale >= open.scale)
    }

    @Test("Opening a + lays out an empty plate over it, fitted with the rest",
          arguments: [NewDesktopPosition.top, .bottom])
    func expandedPlateCoversItsButton(position: NewDesktopPosition) throws {
        let (made, ids) = variants([9, 3, 0, 6])
        let variants = try #require(made)
        let open = try #require(variants.expanded[position])
        #expect(open.stages.count == 5)
        #expect(open.newDesktopStageIndex == 4)
        #expect(open.expandedNewDesktop == position)
        #expect(open.stages[4].spaceID == ids[position])
        #expect(open.stages[4].canonicalWindowIDs.isEmpty)
        #expect(open.newDesktopTargets.map(\.position) == [position == .top ? .bottom : .top])
        #expect(open.generation == variants.collapsed.generation)
        // Opening moves plates but never rewraps a card.
        #expect(open.stages.prefix(4).map(\.canonicalRows)
            == variants.collapsed.stages.map(\.canonicalRows))

        let projection = open.projection(for: nil)
        let plate = try #require(open.expandedNewDesktopFrame)
        let button = try #require(variants.collapsed.newDesktopTargets.first { $0.position == position })
        #expect(plate.contains(button.frame))
        let neighbour = try #require(open.plateFrame(
            stageIndex: position == .top ? 0 : 3, projection: projection
        ))
        #expect(position == .top ? plate.maxY < neighbour.minY : plate.minY > neighbour.maxY)
        for index in open.stages.indices {
            let frame = try #require(open.plateFrame(stageIndex: index, projection: projection))
            #expect(open.usableBounds.insetBy(dx: -0.001, dy: -0.001).contains(frame))
        }
    }

    @Test("Reaching a + opens it, and leaving the opened plate closes it again")
    func pointerOpensAndClosesTheNewDesktopPlate() throws {
        let (made, _) = variants([2, 1])
        let variants = try #require(made)
        let collapsed = variants.collapsed
        let bottom = try #require(collapsed.newDesktopTargets.last)

        let open = try #require(variants.layout(at: bottom.center, from: collapsed))
        #expect(open.expandedNewDesktop == .bottom)
        #expect(variants.layout(at: bottom.center, from: open) == nil)

        let plate = try #require(open.expandedNewDesktopFrame)
        let inside = CGPoint(x: plate.minX + 4, y: plate.maxY - 4)
        #expect(variants.layout(at: inside, from: open) == nil)
        let first = try #require(open.plateFrame(stageIndex: 0, projection: open.projection(for: nil)))
        #expect(variants.layout(at: CGPoint(x: first.midX, y: first.midY), from: open) == collapsed)
        #expect(variants.layout(at: CGPoint(x: first.midX, y: first.midY), from: collapsed) == nil)
    }

    @Test("Dropping on an opened plate asks for a new desktop at that end, and only there",
          arguments: [NewDesktopPosition.top, .bottom])
    func dropOnNewDesktopPlateCreatesDesktop(position: NewDesktopPosition) throws {
        let (made, ids) = variants([2, 1])
        let open = try #require(made?.expanded[position])
        let plate = try #require(open.expandedNewDesktopFrame)

        let intent = try #require(open.resolve(at: CGPoint(x: plate.midX, y: plate.midY), current: nil))
        #expect(intent.stageIndex == 2)
        #expect(!open.isNoOp(intent))
        let request = try #require(open.dropRequest(for: intent))
        #expect(request.newDesktopPosition == position)
        #expect(request.toSpaceID == ids[position])
        #expect(request.placement == .start)
        #expect(open.modelStageIndex(forStageIndex: 2) == (position == .top ? 0 : 2))

        let other = try #require(open.plateFrame(stageIndex: 1, projection: open.projection(for: nil)))
        let ordinary = try #require(open.resolve(at: CGPoint(x: other.midX, y: other.midY), current: nil))
        #expect(open.dropRequest(for: ordinary)?.createsDesktop == false)
        #expect(open.modelStageIndex(forStageIndex: 1) == 1)
    }

    @Test("A window dropped into a new desktop leaves the focus where it was",
          arguments: [NewDesktopPosition.top, .bottom])
    func dropIntoNewDesktopFocusesNothing(position: NewDesktopPosition) throws {
        let (made, _) = variants([2, 1])
        let open = try #require(made?.expanded[position])
        let plate = try #require(open.expandedNewDesktopFrame)
        let created = try #require(open.resolve(at: CGPoint(x: plate.midX, y: plate.midY), current: nil))
        #expect(open.focusedStageIndex(afterDropping: created) == nil)

        let other = try #require(open.plateFrame(stageIndex: 1, projection: open.projection(for: nil)))
        let ordinary = try #require(open.resolve(at: CGPoint(x: other.midX, y: other.midY), current: nil))
        #expect(open.focusedStageIndex(afterDropping: ordinary) == 1)
    }

    @Test("A drag session opens the plate under a pointer that reaches the +")
    func sessionSwapsLayouts() throws {
        let (made, _) = variants([2, 1])
        let variants = try #require(made)
        let bottom = try #require(variants.collapsed.newDesktopTargets.last)
        let session = CompactDragSession()
        let window = StageWindowData(id: 1, windowID: 1, ownerBundleID: "com.apple.TextEdit",
                                     ownerName: "TextEdit", windowTitle: "", previewImage: nil)
        let first = try #require(variants.collapsed.plateFrame(
            stageIndex: 0, projection: variants.collapsed.projection(for: nil)
        ))
        session.begin(variants: variants, window: window, at: CGPoint(x: first.midX, y: first.midY))
        #expect(session.snapshot?.expandedNewDesktop == nil)

        #expect(session.changesLayout(at: bottom.center))
        session.move(to: bottom.center)
        #expect(session.snapshot?.expandedNewDesktop == .bottom)
        #expect(session.intent?.stageIndex == session.snapshot?.newDesktopStageIndex)

        session.move(to: CGPoint(x: first.midX, y: first.midY))
        #expect(session.snapshot?.expandedNewDesktop == nil)
    }

    @Test("Without desktop management a drag has no +")
    func noPlateWithoutDesktopManagement() throws {
        let compact = try #require(CompactDragLayoutTests.snapshot([2, 1]))
        #expect(compact.newDesktopTargets.isEmpty)
        #expect(compact.newDesktopStageIndex == nil)
        #expect(compact.stages.count == 2)
    }

    @Test("A transient window is never offered a new desktop")
    func transientWindowGetsNoNewDesktop() {
        var viewModel = CompactDragLayoutTests.viewModel([1])
        viewModel.canManageDesktops = true
        let window = StageWindowData(id: 1, windowID: 1, ownerBundleID: "com.apple.Spotlight",
                                     ownerName: "Spotlight", windowTitle: "", previewImage: nil)
        let ordinary = StageWindowData(id: 2, windowID: 2, ownerBundleID: "com.apple.TextEdit",
                                       ownerName: "TextEdit", windowTitle: "", previewImage: nil)
        #expect(StageOverlayView.offersNewDesktop(for: ordinary, viewModel: viewModel))
        #expect(StageOverlayView.offersNewDesktop(for: window, viewModel: viewModel)
            == !TransientWindowIdentity.isTransient("com.apple.Spotlight"))
    }

    @Test("The hover band covers the whole way from the plate out to its + button")
    func addZoneBridgesPlateAndButton() throws {
        let plate = CGRect(x: 100, y: 100, width: 300, height: 120)
        let button = CGRect(x: 235, y: 230, width: 30, height: 30)
        let zone = try #require(DesktopControlGeometry.addZone(plate: plate, button: button))
        #expect(zone.contains(CGPoint(x: 250, y: 225)))
        #expect(zone.contains(CGPoint(x: 250, y: 259)))
        #expect(zone.contains(CGPoint(x: 120, y: 225)))
        #expect(!zone.contains(CGPoint(x: 250, y: 300)))
        #expect(DesktopControlGeometry.addZone(plate: plate, button: nil) == nil)

        let above = CGRect(x: 235, y: 60, width: 30, height: 30)
        let topZone = try #require(DesktopControlGeometry.addZone(plate: plate, button: above))
        #expect(topZone.contains(CGPoint(x: 250, y: 95)))
        #expect(topZone.contains(CGPoint(x: 250, y: 61)))
        #expect(topZone.contains(CGPoint(x: 120, y: 95)))
        #expect(!topZone.contains(CGPoint(x: 250, y: 105)))
        #expect(!topZone.contains(CGPoint(x: 250, y: 30)))
    }

    private func plateSnapshot(_ counts: [Int], holding index: Int) throws -> CompactDragSnapshot {
        var viewModel = CompactDragLayoutTests.viewModel(counts)
        viewModel.canManageDesktops = true
        return try #require(StageOverlayView.compactDragSnapshot(
            viewModel: viewModel, spaceIndex: index, windowIndex: nil,
            containerSize: CGSize(width: 1280, height: 800)
        ))
    }

    @Test("A held plate opens the drag view with a gap as wide as all its cards")
    func heldPlateOpensTheDragView() throws {
        let compact = try plateSnapshot([2, 3, 1], holding: 1)
        #expect(compact.movesWholeStage)
        #expect(compact.newDesktopTargets.isEmpty)
        #expect(compact.sourceWindowIDs == compact.fingerprint.stages[1].windows.map(\.windowID))
        let cards = compact.stages[1].originalRows.joined()
        let block = cards.map(\.width).reduce(0, +)
            + CGFloat(cards.count - 1) * compact.metrics.windowSpacing
        #expect(abs(compact.sourceCardWidth - block) < 0.001)
        // Held, it leaves the stack: the rest close up, and no slot is open until asked for.
        #expect(compact.stackedPlates == [0, 2])
        let resting = compact.projection(for: nil)
        #expect(resting.stageShifts.allSatisfy { $0 == 0 })
        #expect(resting.slotCenterY == nil)
        let first = try #require(compact.plateFrame(stageIndex: 0, projection: resting))
        let last = try #require(compact.plateFrame(stageIndex: 2, projection: resting))
        let spacing = StageConstants.compactStageSpacing * compact.metrics.scaleFactor * compact.scale
        #expect(abs(last.minY - first.maxY - spacing) < 0.5)
        // Back where it came from is no edit.
        let home = try #require(compact.resolve(at: CGPoint(x: first.midX, y: first.maxY + spacing / 2),
                                                current: nil))
        #expect(home.slot == 1)
        #expect(compact.isNoOp(home))
    }

    @Test("Over the middle of another plate a held plate opens a gap there for all its windows")
    func heldPlateMergesIntoAGap() throws {
        let compact = try plateSnapshot([2, 3, 1], holding: 1)
        let resting = compact.projection(for: nil)
        let target = try #require(compact.plateFrame(stageIndex: 0, projection: resting))
        let intent = try #require(compact.resolve(
            at: CGPoint(x: target.maxX - 4, y: target.midY), current: nil
        ))
        #expect(intent.stageIndex == 0)
        #expect(intent.gap == 2)
        #expect(intent.slot == nil)
        #expect(!compact.isNoOp(intent))

        let drawn = compact.projection(for: intent)
        let placeholder = try #require(drawn.placeholder)
        #expect(placeholder.stageIndex == 0)
        #expect(abs(placeholder.width - compact.sourceCardWidth * drawn.contentScales[0]) < 0.001)
        #expect(drawn.plateWidths[0] > resting.plateWidths[0])
        // The held cards have their places across the gap, in order, left to right.
        let landed = compact.sourceWindowIDs.compactMap { drawn.cardOffsets[0][$0]?.x }
        #expect(landed.count == 3)
        #expect(landed == landed.sorted())
        #expect(drawn.stageShifts.allSatisfy { $0 == 0 })

        let request = try #require(compact.plateRequest(for: intent))
        #expect(request.spaceID == compact.stages[1].spaceID)
        #expect(request.action == .merge(into: compact.stages[0].spaceID, placement: .end))
    }

    @Test("A held plate's drag view is sized as a held window's, with its own room freed")
    func heldPlateFitsLikeAHeldWindow() throws {
        var viewModel = CompactDragLayoutTests.viewModel([4, 6, 3])
        viewModel.canManageDesktops = true
        let size = CGSize(width: 1600, height: 900)
        let window = try #require(StageOverlayView.compactDragSnapshot(
            viewModel: viewModel, spaceIndex: 2, windowIndex: 0, containerSize: size
        ))
        let plate = try #require(StageOverlayView.compactDragSnapshot(
            viewModel: viewModel, spaceIndex: 2, windowIndex: nil, containerSize: size
        ))
        // Never smaller than a held window's, and roomier for the plate that left.
        #expect(plate.scale >= window.scale - 0.0001)
        for (held, carried) in zip(plate.stages, window.stages) {
            #expect(held.originalRows.count <= carried.originalRows.count)
        }
    }

    @Test("A plate too full to take a held plate's cards shrinks its own cards, not the stack")
    func overfullTargetCompresses() throws {
        var viewModel = CompactDragLayoutTests.viewModel([4, 6, 3])
        viewModel.canManageDesktops = true
        let compact = try #require(StageOverlayView.compactDragSnapshot(
            viewModel: viewModel, spaceIndex: 0, windowIndex: nil,
            containerSize: CGSize(width: 1600, height: 900)
        ))
        let resting = compact.projection(for: nil)
        let target = try #require(compact.plateFrame(stageIndex: 1, projection: resting))
        let intent = try #require(compact.resolve(at: CGPoint(x: target.midX, y: target.midY),
                                                  current: nil))
        #expect(intent.stageIndex == 1)
        let drawn = compact.projection(for: intent)
        let scale = try #require(drawn.contentScales[safe: 1])
        #expect(scale < 1)
        #expect(drawn.contentScales.enumerated().allSatisfy { $0.offset == 1 || $0.element == 1 })
        let frame = try #require(compact.plateFrame(stageIndex: 1, projection: drawn))
        #expect(compact.usableBounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
        #expect(abs(frame.height - target.height) < 0.001)
        #expect(abs((drawn.placeholder?.width ?? 0) - compact.sourceCardWidth * scale) < 0.001)
    }

    @Test("Over a plate's edge a held plate's slot moves there, and the plates between slide")
    func heldPlateReorders() throws {
        let compact = try plateSnapshot([2, 3, 1, 2], holding: 0)
        let resting = compact.projection(for: nil)
        let third = try #require(compact.plateFrame(stageIndex: 2, projection: resting))
        let intent = try #require(compact.resolve(
            at: CGPoint(x: third.midX, y: third.maxY - 2), current: nil
        ))
        #expect(intent.stageIndex == 0)
        #expect(intent.slot == 2)

        let drawn = compact.projection(for: intent)
        #expect(compact.plateOrder(slot: 2) == [1, 2, 0, 3])
        // The plates part around the slot, keeping the stack centred.
        #expect(drawn.stageShifts[1] < 0)
        #expect(drawn.stageShifts[2] < 0)
        #expect(drawn.stageShifts[3] > 0)
        let slotCenter = try #require(drawn.slotCenterY)
        let above = try #require(compact.plateFrame(stageIndex: 2, projection: drawn))
        let below = try #require(compact.plateFrame(stageIndex: 3, projection: drawn))
        #expect(slotCenter > above.maxY)
        #expect(slotCenter < below.minY)
        let request = try #require(compact.plateRequest(for: intent))
        #expect(request.action == .reorder(after: compact.stages[2].spaceID))

        // The open slot moves plates, but not what the pointer is measured against: holding
        // still keeps it, and the middle of a plate it pushed away still merges there.
        let kept = try #require(compact.resolve(at: CGPoint(x: third.midX, y: third.maxY - 2),
                                                current: intent))
        #expect(kept.slot == 2)
        #expect(kept.stageIndex == 0)
        let fourth = try #require(compact.plateFrame(stageIndex: 3, projection: resting))
        let merge = try #require(compact.resolve(at: CGPoint(x: fourth.midX, y: fourth.midY),
                                                 current: intent))
        #expect(merge.stageIndex == 3)
        #expect(merge.slot == nil)

        let first = try #require(compact.plateFrame(stageIndex: 1, projection: resting))
        let top = try #require(compact.resolve(at: CGPoint(x: first.midX, y: first.minY + 2),
                                               current: intent))
        #expect(top.slot == 0)
        #expect(compact.isNoOp(top))
        #expect(compact.plateRequest(for: top)?.action == .reorder(after: nil))
    }

    @Test("A slot opened past either end of the stack takes a drop anywhere it is drawn")
    func endSlotsTakeDropsWhereDrawn() throws {
        let compact = try plateSnapshot([2, 3, 1, 2], holding: 1)
        let resting = compact.projection(for: nil)
        let first = try #require(compact.plateFrame(stageIndex: 0, projection: resting))
        let last = try #require(compact.plateFrame(stageIndex: 3, projection: resting))

        let atTop = try #require(compact.resolve(at: CGPoint(x: first.midX, y: first.minY - 2),
                                                 current: nil))
        #expect(atTop.slot == 0)
        let topSlot = try #require(compact.projection(for: atTop).slotCenterY)
        let intoTop = try #require(compact.resolve(
            at: CGPoint(x: first.midX, y: topSlot - compact.slotHeight * 0.4), current: atTop
        ))
        #expect(intoTop.slot == 0)
        #expect(compact.plateRequest(for: intoTop)?.action == .reorder(after: nil))

        let atBottom = try #require(compact.resolve(at: CGPoint(x: last.midX, y: last.maxY + 2),
                                                    current: nil))
        #expect(atBottom.slot == 3)
        let bottomSlot = try #require(compact.projection(for: atBottom).slotCenterY)
        let intoBottom = try #require(compact.resolve(
            at: CGPoint(x: last.midX, y: bottomSlot + compact.slotHeight * 0.4), current: atBottom
        ))
        #expect(intoBottom.slot == 3)
        #expect(compact.plateRequest(for: intoBottom)?.action
            == .reorder(after: compact.stages[3].spaceID))
    }

    @Test("A held plate dropped into the slot drawn past either end of the stack reorders there",
          arguments: [true, false])
    func drawnEndSlotTakesTheDrop(top: Bool) throws {
        var viewModel = CompactDragLayoutTests.viewModel([3, 2, 2, 2])
        viewModel.canManageDesktops = true
        let variants = try #require(StageOverlayView.compactDragVariants(
            viewModel: viewModel, spaceIndex: 1, windowIndex: nil,
            containerSize: CGSize(width: 1024, height: 768)
        ))
        let roomy = variants.collapsed
        let resting = roomy.projection(for: nil)
        let end = try #require(roomy.plateFrame(stageIndex: top ? 0 : 3, projection: resting))
        let session = CompactDragSession()
        session.begin(variants: variants, plate: viewModel.stages[1],
                      at: CGPoint(x: end.midX, y: end.midY))
        session.move(to: CGPoint(x: end.midX, y: top ? end.minY - 2 : end.maxY + 2))
        let opened = try #require(session.intent)
        let drawn = try #require(session.snapshot)
        let slotCenter = try #require(drawn.projection(for: opened).slotCenterY)

        for fraction in stride(from: -0.45, through: 0.45, by: 0.15) {
            let point = CGPoint(x: end.midX, y: slotCenter + drawn.slotHeight * fraction)
            session.move(to: point)
            let target = try #require(session.target(at: point), "lost the slot at \(fraction)")
            #expect(target.slot == (top ? 0 : 3), "slot \(String(describing: target.slot)) stage \(target.stageIndex) at \(fraction)")
            #expect(!roomy.isNoOp(target))
        }
    }

    @Test("A held plate taken past either end of the stack, however far, goes to that end")
    func farPastTheEndReorders() throws {
        let compact = try plateSnapshot([2, 3, 1, 2], holding: 0)
        let resting = compact.projection(for: nil)
        let first = try #require(compact.plateFrame(stageIndex: 1, projection: resting))
        let last = try #require(compact.plateFrame(stageIndex: 3, projection: resting))

        let above = try #require(compact.resolve(at: CGPoint(x: first.midX, y: 1), current: nil))
        #expect(above.slot == 0)
        let below = try #require(compact.resolve(at: CGPoint(x: last.midX, y: 799), current: nil))
        #expect(below.slot == 3)
        #expect(compact.plateRequest(for: below)?.action == .reorder(after: compact.stages[3].spaceID))
        #expect(compact.resolve(at: CGPoint(x: 2, y: 799), current: nil) == nil)
    }

    @Test("A held plate's first slot moves the drag view, once, to a scale with room for it")
    func firstSlotRescalesOnce() throws {
        var viewModel = CompactDragLayoutTests.viewModel([3, 2, 2, 2])
        viewModel.canManageDesktops = true
        let variants = try #require(StageOverlayView.compactDragVariants(
            viewModel: viewModel, spaceIndex: 0, windowIndex: nil,
            containerSize: CGSize(width: 1024, height: 768)
        ))
        let roomy = variants.collapsed
        let slotted = try #require(variants.slotted)
        #expect(slotted.scale < roomy.scale)
        #expect(slotted.generation == roomy.generation)
        let held = slotted.stages[0].baseHeight * slotted.scale
        #expect(abs(slotted.slotHeight - held) < 0.5)

        let session = CompactDragSession()
        let plate = try #require(viewModel.stages.first)
        let first = try #require(roomy.plateFrame(stageIndex: 1, projection: roomy.projection(for: nil)))
        session.begin(variants: variants, plate: plate, at: CGPoint(x: first.midX, y: first.midY))
        #expect(session.snapshot == roomy)
        let edge = CGPoint(x: first.midX, y: first.maxY - 2)
        #expect(session.changesLayout(at: edge))
        session.move(to: edge)
        #expect(session.snapshot == slotted)
        #expect(session.intent?.slot != nil)
        // Merging afterwards closes the slot and returns to the held layout, with no room kept.
        let middle = try #require(slotted.plateFrame(stageIndex: 2,
                                                     projection: slotted.projection(for: session.intent)))
        let merging = CGPoint(x: middle.midX, y: middle.midY)
        #expect(session.changesLayout(at: merging))
        session.move(to: merging)
        #expect(session.snapshot == roomy)
        #expect(session.intent?.stageIndex == 2)
        #expect(session.intent?.slot == nil)
        #expect(roomy.projection(for: session.intent).slotCenterY == nil)
        // Reordering again rescales again, and leaving the stack returns to the held layout.
        session.move(to: edge)
        #expect(session.snapshot == slotted)
        session.move(to: CGPoint(x: 2, y: 2))
        #expect(session.intent == nil)
        #expect(session.snapshot == roomy)
    }

    @Test("A slot opening never carries the plate the pointer is heading for out from under it")
    func slotNeverChasesTheTarget() throws {
        // One plate left, and a held plate twice its height: the slot it opens is taller than
        // the plate, so a slot measured against the drawn stack pushed the plate away.
        var viewModel = CompactDragLayoutTests.viewModel([4, 10])
        viewModel.canManageDesktops = true
        let variants = try #require(StageOverlayView.compactDragVariants(
            viewModel: viewModel, spaceIndex: 1, windowIndex: nil,
            containerSize: CGSize(width: 2048, height: 1152)
        ))
        let resting = variants.collapsed
        let target = try #require(resting.plateFrame(stageIndex: 0, projection: resting.projection(for: nil)))
        let band = CompactDragSnapshot.reorderBand(plateHeight: target.height)
        for downward in [true, false] {
            let session = CompactDragSession()
            session.begin(variants: variants, plate: viewModel.stages[1],
                          at: CGPoint(x: target.midX, y: downward ? 40 : 1112))
            var merged: [CGFloat] = []
            for step in 0..<134 {
                let y = downward ? 40 + CGFloat(step) * 8 : 1112 - CGFloat(step) * 8
                session.move(to: CGPoint(x: target.midX, y: y))
                if session.intent?.stageIndex == 0, session.intent?.slot == nil { merged.append(y) }
            }
            // Every point over the plate's middle merges, whichever way the pointer arrived.
            let span = (merged.max() ?? 0) - (merged.min() ?? 0)
            #expect(span >= target.height - 2 * band - 16, "merged at \(merged)")
        }
    }

    @Test("A merge holds against the edge bands of its own target")
    func mergeHoldsAgainstItsTargetEdge() throws {
        let compact = try plateSnapshot([2, 3, 1], holding: 1)
        let target = try #require(compact.plateFrame(stageIndex: 0, projection: compact.projection(for: nil)))
        let band = CompactDragSnapshot.reorderBand(plateHeight: target.height)
        let merge = try #require(compact.resolve(at: CGPoint(x: target.midX, y: target.midY), current: nil))
        #expect(merge.slot == nil)
        let drawn = try #require(compact.plateFrame(stageIndex: 0, projection: compact.projection(for: merge)))
        // Just inside the band, entering from outside reorders; already merging, it stays.
        let edge = CGPoint(x: drawn.midX, y: drawn.maxY - band * 0.75)
        #expect(compact.resolve(at: edge, current: nil)?.slot != nil)
        let held = try #require(compact.resolve(at: edge, current: merge))
        #expect(held.slot == nil)
        #expect(held.stageIndex == 0)
        // Right at the edge it reorders either way.
        let outer = CGPoint(x: drawn.midX, y: drawn.maxY - 2)
        #expect(compact.resolve(at: outer, current: merge)?.slot != nil)
    }

    @Test("Off the stack a held plate has no destination")
    func heldPlateOffTheStack() throws {
        let compact = try plateSnapshot([2, 3], holding: 1)
        #expect(compact.resolve(at: CGPoint(x: 5, y: 5), current: nil) == nil)
    }

    @Test("⌘N and ⌘⌫ are the session defaults for adding and removing desktops")
    func desktopShortcutDefaults() {
        let bindings = KeyBindings()
        #expect(bindings.bindings[.addDesktop] == KeyCombo(keyCode: 0x2D))
        #expect(bindings.bindings[.removeDesktop] == KeyCombo(keyCode: 0x33))
        #expect(KeyAction.addDesktop.toKeyEvent() == .addDesktop)
        #expect(KeyAction.removeDesktop.toKeyEvent() == .removeDesktop)
        #expect(KeyAction.addDesktop.shortcutScope == .session)
    }

    @Test("A saved binding that already uses N keeps it; the new default steps aside")
    func savedBindingKeepsItsKey() throws {
        var saved = KeyBindings()
        saved.set(KeyCombo(keyCode: 0x2D), for: .closeSelectedWindow)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        // Bindings encode as a flat key, value, key, value list. A file saved before the action
        // existed has no pair for it.
        let encoded = try #require(object["bindings"] as? [Any])
        var pairs: [Any] = []
        for index in stride(from: 0, to: encoded.count - 1, by: 2)
            where encoded[index] as? String != KeyAction.addDesktop.rawValue {
            pairs += [encoded[index], encoded[index + 1]]
        }
        object["bindings"] = pairs
        let decoded = try JSONDecoder().decode(
            KeyBindings.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.bindings[.closeSelectedWindow] == KeyCombo(keyCode: 0x2D))
        #expect(decoded.bindings[.addDesktop] == nil)
        #expect(decoded.bindings[.removeDesktop] == KeyCombo(keyCode: 0x33))
    }

    @Test("A desktop added and focused at once starts beside its neighbour, never over it",
          arguments: [0, 2, 4])
    func insertedFocusedPlateStartsBesideItsNeighbour(index: Int) {
        let oldHeights: [CGFloat] = [240, 180, 180, 180]
        let spacing: CGFloat = 16, inactiveScale: CGFloat = 0.62, screenMidY: CGFloat = 384
        let old = StageMotion.stackLayout(stageHeights: oldHeights, focusIndex: 0,
                                          spacing: spacing, inactiveScale: inactiveScale)
        let oldOffset = StageMotion.anchoredOffset(layout: old, anchorIndex: 0, anchorY: screenMidY)
        let oldIDs = oldHeights.map { _ in UUID() }
        var laidOut: [UUID: StageExtent] = [:]
        for (i, id) in oldIDs.enumerated() {
            laidOut[id] = StageExtent(center: oldOffset + old.centers[i], height: old.heights[i])
        }
        var ids = oldIDs
        ids.insert(UUID(), at: index)
        var heights = oldHeights
        heights.insert(180, at: index)
        let new = StageMotion.stackLayout(stageHeights: heights, focusIndex: index,
                                          spacing: spacing, inactiveScale: inactiveScale)
        let newOffset = StageMotion.anchoredOffset(layout: new, anchorIndex: index, anchorY: screenMidY)

        let shift = StageMotion.insertionShift(
            index: index, stageIDs: ids, laidOut: laidOut, spacing: spacing,
            finalLayout: new, finalStackOffset: newOffset
        )
        // Plates scale about their centres, so the centre is where the plate is drawn.
        let start = newOffset + new.centers[index] + shift
        let half = new.heights[index] / 2
        let scale = StageMotion.insertionScale(index: index, stageIDs: ids, laidOut: laidOut)
        switch index {
        case 0:
            let successor = laidOut[oldIDs[0]]!
            #expect(start + half <= successor.center - successor.height / 2 - spacing + 0.001)
        case oldIDs.count:
            let predecessor = laidOut[oldIDs[index - 1]]!
            #expect(start - half >= predecessor.center + predecessor.height / 2 + spacing - 0.001)
        default:
            // No room beside either neighbour: it grows, small, out of the gap between them.
            let above = laidOut[oldIDs[index - 1]]!, below = laidOut[oldIDs[index]]!
            #expect(abs(start - (above.center + above.height / 2 + below.center - below.height / 2) / 2)
                < 0.001)
            #expect(scale < 0.5)
        }
        #expect(StageMotion.insertionShift(
            index: index, stageIDs: ids, laidOut: [:], spacing: spacing,
            finalLayout: new, finalStackOffset: newOffset
        ) == 0)
    }

    @Test("The drag view's + stays legible however far the drag view shrinks")
    func dropTargetHasAMinimumSize() {
        #expect(DesktopControlGeometry.minimumDropTargetDiameter >= 20)
    }
}
