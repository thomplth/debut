import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@MainActor
@Suite("Compact drag layout")
struct CompactDragLayoutTests {
    /// Stages of `counts` windows, numbered 100, 101, … in stage order.
    static func manager(_ counts: [Int]) -> SpaceManager {
        var manager = SpaceManager()
        var next: CGWindowID = 100
        for (index, count) in counts.enumerated() {
            if index > 0 {
                manager.activateSpace(id: manager.spaces[index - 1].id)
                manager.addFixtureDesktop()
            }
            let spaceID = manager.spaces[index].id
            for _ in 0..<count {
                manager.addWindow(
                    SpaceWindow(windowID: next, ownerBundleID: "com.\(next)",
                                ownerName: "App", windowTitle: "W\(next)"),
                    toSpaceID: spaceID
                )
                next += 1
            }
        }
        manager.activateSpace(id: manager.spaces[0].id)
        return manager
    }

    static func viewModel(
        _ counts: [Int],
        active: Int = 0,
        appearance: AppSettings = AppSettings()
    ) -> StageOverlayViewModel {
        StageOverlayViewModel(
            spaceManager: manager(counts),
            activeSpaceIndex: active,
            selectedWindowIndex: 0,
            appearance: appearance
        )
    }

    static func snapshot(
        _ counts: [Int],
        source: (Int, Int) = (0, 0),
        size: CGSize = CGSize(width: 1024, height: 768),
        appearance: AppSettings = AppSettings()
    ) -> CompactDragSnapshot? {
        StageOverlayView.compactDragSnapshot(
            viewModel: viewModel(counts, appearance: appearance),
            spaceIndex: source.0,
            windowIndex: source.1,
            containerSize: size
        )
    }

    /// Every (stage, row, gap) the pointer can name.
    static func intents(_ snapshot: CompactDragSnapshot) -> [CompactDropIntent] {
        snapshot.stages.enumerated().flatMap { stageIndex, stage in
            stage.canonicalRows.enumerated().flatMap { row, cards in
                (0...cards.count).map { gap in
                    CompactDropIntent(
                        stageIndex: stageIndex,
                        spaceID: stage.spaceID,
                        row: row,
                        gap: gap,
                        logicalIndex: stage.canonicalRows.prefix(row)
                            .reduce(0) { $0 + $1.count } + gap,
                        generation: snapshot.generation
                    )
                }
            }
        }
    }

    @Test("Four stages that overflow normally all fit, at one scale, for every insertion",
          arguments: [CGSize(width: 1024, height: 768), CGSize(width: 1280, height: 800)])
    func everyStageFitsForEveryInsertion(size: CGSize) throws {
        var appearance = AppSettings()
        appearance.stageScale = AppSettings.maximumStageScale
        let snapshot = try #require(Self.snapshot(
            [9, 3, 0, 6], source: (1, 1), size: size, appearance: appearance
        ))
        let bounds = snapshot.usableBounds
        let fixedCenters = snapshot.stages.map(\.centerY)

        for intent in [nil] + Self.intents(snapshot).map(Optional.some) {
            let projection = snapshot.projection(for: intent)
            for index in snapshot.stages.indices {
                let plate = try #require(snapshot.plateFrame(stageIndex: index, projection: projection))
                #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(plate))
                #expect(abs(plate.midX - snapshot.centerX) < 0.001)
                #expect(abs(plate.midY - fixedCenters[index]) < 0.001)
                for offset in projection.cardOffsets[index].values {
                    let point = try #require(snapshot.overlayPoint(stageIndex: index, offset: offset))
                    #expect(plate.insetBy(dx: -0.001, dy: -0.001).contains(point))
                }
            }
        }
        #expect(snapshot.scale > 0 && snapshot.scale <= 1)
    }

    @Test("The compact scale ignores the active stage and the inactive-stage preference")
    func scaleIgnoresFocusInputs() throws {
        var shrunk = AppSettings()
        shrunk.inactiveStageScale = 0.3
        let a = try #require(Self.snapshot([3, 4, 2, 5]))
        let b = try #require(StageOverlayView.compactDragSnapshot(
            viewModel: Self.viewModel([3, 4, 2, 5], active: 3, appearance: shrunk),
            spaceIndex: 0, windowIndex: 0, containerSize: CGSize(width: 1024, height: 768)
        ))
        #expect(a.scale == b.scale)
        #expect(a.stages.map(\.centerY) == b.stages.map(\.centerY))
    }

    @Test("A stack with room to spare is drawn at the focused stage's size, never larger")
    func roomyStackKeepsFocusedSize() throws {
        let snapshot = try #require(Self.snapshot([3, 2], size: CGSize(width: 2560, height: 1410)))
        #expect(snapshot.scale == 1)
        let normal = StageConstants.stageLayouts(
            forContentAspects: [[nil, nil, nil], [nil, nil]],
            screenWidth: 2560,
            metrics: snapshot.metrics
        )
        #expect(snapshot.stages.map(\.originalRows.count) == normal.map { max(1, $0.rowCount) })
    }

    @Test("A stack that has to shrink rewraps into the width shrinking freed up")
    func shrunkStackUnwrapsRows() throws {
        let counts = [9, 8, 9, 7]
        let size = CGSize(width: 1024, height: 768)
        let snapshot = try #require(Self.snapshot(counts, size: size))
        let normal = StageConstants.stageLayouts(
            forContentAspects: counts.map { Array(repeating: nil, count: $0) },
            screenWidth: size.width,
            metrics: snapshot.metrics
        )
        #expect(snapshot.scale < 1)
        let compactRows = snapshot.stages.map(\.originalRows.count)
        let normalRows = normal.map(\.rowCount)
        #expect(zip(compactRows, normalRows).allSatisfy { $0 <= $1 })
        #expect(zip(compactRows, normalRows).contains { $0 < $1 })
        // Every card still keeps its MRU order across the rewrap.
        for (stage, count) in zip(snapshot.stages, counts) {
            #expect(stage.originalRows.flatMap { $0 }.count == count)
        }
        let widest = snapshot.stages.map(\.maximumWidth).max() ?? 0
        #expect(widest * snapshot.scale <= snapshot.usableBounds.width + 0.001)
    }

    @Test("The E2E drop point is the drag view's own geometry")
    func dragViewDropPointMatchesSnapshot() throws {
        let counts = [4, 0, 3]
        let size = CGSize(width: 1024, height: 768)
        let snapshot = try #require(Self.snapshot(counts, source: (0, 1), size: size))
        let point = try #require(StageConstants.dragViewDropPoint(
            contentAspects: counts.map { Array(repeating: nil, count: $0) },
            stageScale: CGFloat(AppSettings().stageScale),
            cardSpacing: CGFloat(AppSettings().previewCardSpacing),
            containerSize: size,
            reservesDisplayIndicator: false,
            sourceSpaceIndex: 0,
            sourceWindowIndex: 1,
            destinationSpaceIndex: 1
        ))
        let intent = try #require(snapshot.resolve(at: point, current: nil))
        #expect(intent.stageIndex == 1)
        #expect(intent.logicalIndex == 0)
    }

    @Test("No drag starts without a positive usable rectangle")
    func invalidBoundsStartNothing() {
        #expect(Self.snapshot([3, 2], size: CGSize(width: 100, height: 40)) == nil)
    }

    @Test("The source is removed once and rows are never rebalanced")
    func canonicalRowsRemoveSourceOnce() throws {
        let snapshot = try #require(Self.snapshot([9], source: (0, 1), size: CGSize(width: 1024, height: 768)))
        let stage = snapshot.stages[0]
        #expect(stage.originalRows.count > 1)
        #expect(stage.canonicalRows.count == stage.originalRows.count)
        #expect(stage.canonicalWindowIDs == (100...108).map(CGWindowID.init).filter { $0 != 101 })
        #expect(zip(stage.originalRows.dropFirst(), stage.canonicalRows.dropFirst())
            .allSatisfy { $0 == $1 })
    }

    @Test("The placeholder lands exactly on its unshifted gap anchor")
    func placeholderMatchesGapAnchor() throws {
        let snapshot = try #require(Self.snapshot([7, 3, 0], source: (0, 2)))
        for intent in Self.intents(snapshot) {
            let placeholder = try #require(snapshot.projection(for: intent).placeholder)
            let anchor = try #require(snapshot.gapAnchor(
                stageIndex: intent.stageIndex, row: intent.row, gap: intent.gap
            ))
            #expect(placeholder.stageIndex == intent.stageIndex)
            #expect(abs(placeholder.offset.x - anchor) < 0.001)
        }
    }

    @Test("Resolving at a placeholder centre chooses that same slot, and drawing it changes nothing")
    func resolutionIsStableUnderItsOwnProjection() throws {
        let snapshot = try #require(Self.snapshot([5, 4, 0, 2], source: (1, 0)))
        for intent in Self.intents(snapshot) {
            let placeholder = try #require(snapshot.projection(for: intent).placeholder)
            let point = try #require(snapshot.overlayPoint(
                stageIndex: intent.stageIndex, offset: placeholder.offset
            ))
            let resolved = try #require(snapshot.resolve(at: point, current: intent))
            #expect(resolved == intent)
            #expect(snapshot.resolve(at: point, current: resolved) == resolved)
        }
    }

    @Test("Gaps between plates and bare desktop are no destination")
    func outsidePlatesResolvesToNothing() throws {
        let snapshot = try #require(Self.snapshot([2, 2]))
        let projection = snapshot.projection(for: nil)
        let upper = try #require(snapshot.plateFrame(stageIndex: 0, projection: projection))
        let lower = try #require(snapshot.plateFrame(stageIndex: 1, projection: projection))
        #expect(snapshot.resolve(at: CGPoint(x: upper.midX, y: (upper.maxY + lower.minY) / 2),
                                 current: nil) == nil)
        #expect(snapshot.resolve(at: CGPoint(x: 2, y: upper.midY), current: nil) == nil)
    }

    @Test("First, middle and last gaps map to MRU indices in the list without the source")
    func logicalIndices() throws {
        let snapshot = try #require(Self.snapshot([4, 3], source: (0, 1)))
        let stage = snapshot.stages[1]
        let midpoints = stage.canonicalRows[0].indices.map { column -> CGFloat in
            let row = stage.canonicalRows[0]
            let left = -CompactDragSnapshot.rowWidth(row, spacing: snapshot.metrics.windowSpacing) / 2
            let preceding = row.prefix(column).reduce(0) { $0 + $1.width }
                + CGFloat(column) * snapshot.metrics.windowSpacing
            return snapshot.centerX + (left + preceding + row[column].width / 2) * snapshot.scale
        }
        let y = stage.centerY + stage.rowOffsets[0] * snapshot.scale
        #expect(snapshot.resolve(at: CGPoint(x: midpoints[0] - 5, y: y), current: nil)?.logicalIndex == 0)
        #expect(snapshot.resolve(at: CGPoint(x: midpoints[1] - 5, y: y), current: nil)?.logicalIndex == 1)
        #expect(snapshot.resolve(at: CGPoint(x: midpoints[2] + 5, y: y), current: nil)?.logicalIndex == 3)
    }

    @Test("A drop back where the card started is no edit")
    func originalPositionIsNoOp() throws {
        let snapshot = try #require(Self.snapshot([4], source: (0, 2)))
        let intent = CompactDropIntent(
            stageIndex: 0, spaceID: snapshot.stages[0].spaceID, row: 0, gap: 2,
            logicalIndex: 2, generation: snapshot.generation
        )
        #expect(snapshot.isNoOp(intent))
    }

    @Test("Placement records neighbours and replays against surviving anchors")
    func placementResolution() {
        #expect(PointerPlacement(index: 0, in: [1, 2]) == .start)
        #expect(PointerPlacement(index: 2, in: [1, 2]) == .end)
        #expect(PointerPlacement(index: 0, in: []) == .start)
        let middle = PointerPlacement(index: 1, in: [1, 2, 3])
        #expect(middle == .between(predecessor: 1, successor: 2))
        #expect(middle.resolvedIndex(in: [9, 1, 2, 3]) == 2)
        #expect(middle.resolvedIndex(in: [9, 1, 3]) == 2)
        #expect(middle.resolvedIndex(in: [2, 3]) == 0)
        #expect(middle.resolvedIndex(in: [7, 8]) == nil)
    }

    @Test("A replayed pointer move with neither neighbour left is skipped, not appended")
    func transactionSkipsOrphanedPlacement() {
        var manager = Self.manager([2, 2])
        let from = manager.spaces[0].id
        let to = manager.spaces[1].id
        var transaction = StageStackTransaction()
        transaction.pointerMove(
            windowID: 100, fromSpaceID: from, toSpaceID: to,
            placement: .between(predecessor: 500, successor: 501)
        )
        let preview = transaction.preview(applyingTo: manager)
        #expect(preview.spaces[0].windows.map(\.windowID) == [100, 101])
        let commit = transaction.commit(to: &manager)
        #expect(commit.relocations.isEmpty)
        #expect(manager.spaces[1].windows.map(\.windowID) == [102, 103])
    }

    @Test("Preview and commit order agree for first, middle and last drops")
    func previewMatchesCommit() {
        for (placement, expected) in [
            (PointerPlacement.start, [100, 102, 103] as [CGWindowID]),
            (.between(predecessor: 102, successor: 103), [102, 100, 103]),
            (.end, [102, 103, 100]),
        ] {
            var manager = Self.manager([2, 2])
            var transaction = StageStackTransaction()
            transaction.pointerMove(
                windowID: 100, fromSpaceID: manager.spaces[0].id,
                toSpaceID: manager.spaces[1].id, placement: placement
            )
            let preview = transaction.preview(applyingTo: manager)
            #expect(preview.spaces[1].windows.map(\.windowID) == expected)
            _ = transaction.commit(to: &manager)
            #expect(manager.spaces[1].windows.map(\.windowID) == expected)
        }
    }
}

@MainActor
@Suite("Compact drag session")
struct CompactDragSessionTests {
    static let window = StageWindowData(
        id: 100, windowID: 100, ownerBundleID: "com.100", ownerName: "App",
        windowTitle: "W", previewImage: nil
    )

    func begun(_ counts: [Int] = [3, 2]) throws -> (CompactDragSession, CompactDragSnapshot) {
        let session = CompactDragSession()
        let snapshot = try #require(StageOverlayView.compactDragSnapshot(
            viewModel: CompactDragLayoutTests.viewModel(counts),
            spaceIndex: 0, windowIndex: 0,
            containerSize: CGSize(width: 1024, height: 768),
            generation: session.makeGeneration()
        ))
        session.begin(snapshot: snapshot, window: Self.window, at: .zero)
        return (session, snapshot)
    }

    func point(_ snapshot: CompactDragSnapshot, stage: Int, gap: Int) throws -> CGPoint {
        let intent = CompactDragLayoutTests.intents(snapshot).first {
            $0.stageIndex == stage && $0.gap == gap
        }
        let placeholder = try #require(snapshot.projection(for: intent).placeholder)
        return try #require(snapshot.overlayPoint(stageIndex: stage, offset: placeholder.offset))
    }

    @Test("A release before the compact generation is presented accepts nothing")
    func unpresentedReleaseCancels() throws {
        let (session, snapshot) = try begun()
        var calls = 0
        let outcome = session.release(at: try point(snapshot, stage: 1, gap: 0)) { _ in
            calls += 1
            return .accepted
        }
        #expect(calls == 0)
        #expect(outcome == .cancelled("released before compact layout was presented"))
        #expect(session.phase == .idle)
    }

    @Test("A valid release is accepted exactly once, from the final pointer location")
    func acceptsOnceAtFinalLocation() throws {
        let (session, snapshot) = try begun()
        session.acknowledgePresented(generation: snapshot.generation)
        session.move(to: try point(snapshot, stage: 1, gap: 0))
        var requests: [PointerWindowDropRequest] = []
        let outcome = session.release(at: try point(snapshot, stage: 1, gap: 2)) {
            requests.append($0)
            return .accepted
        }
        #expect(requests.count == 1)
        #expect(requests.first?.logicalIndex == 2)
        #expect(requests.first?.placement == .end)
        guard case .accepted = outcome else { Issue.record("not accepted"); return }
        #expect(session.phase == .settling)
        session.finishSettling(sessionID: UUID())
        #expect(session.phase == .settling)
        session.finishSettling(sessionID: snapshot.sessionID)
        #expect(session.phase == .idle)
    }

    @Test("Releasing outside every plate never falls back to the last target")
    func outsideReleaseCancels() throws {
        let (session, snapshot) = try begun()
        session.acknowledgePresented(generation: snapshot.generation)
        session.move(to: try point(snapshot, stage: 1, gap: 0))
        var calls = 0
        _ = session.release(at: CGPoint(x: 1, y: 1)) { _ in calls += 1; return .accepted }
        #expect(calls == 0)
        #expect(session.phase == .idle)
    }

    @Test("A controller rejection returns to idle without a landing")
    func rejectionCancels() throws {
        let (session, snapshot) = try begun()
        session.acknowledgePresented(generation: snapshot.generation)
        let outcome = session.release(at: try point(snapshot, stage: 1, gap: 1)) { _ in
            .rejected("stage structure changed")
        }
        #expect(outcome == .cancelled("stage structure changed"))
        #expect(session.phase == .idle)
    }

    @Test("Cancelling mid-drag or mid-settle leaves no pending completion")
    func cancellationIsTokenized() throws {
        let (session, snapshot) = try begun()
        session.acknowledgePresented(generation: snapshot.generation)
        _ = session.release(at: try point(snapshot, stage: 1, gap: 0)) { _ in .accepted }
        session.cancel(reason: "overlay hidden")
        session.finishSettling(sessionID: snapshot.sessionID)
        #expect(session.phase == .idle)
        #expect(session.snapshot == nil)
    }
}
