import CoreGraphics
import Foundation
import Testing
@testable import DebutCore

@Suite("Drag scrolling")
struct DragScrollTests {
    @Test("A stationary drag at the edge scrolls progressively after its dwell")
    func stationaryEdgeScrollsAfterDwell() {
        var state = DragScrollState(
            stackOffset: 0,
            stackHeight: 900,
            viewportHeight: 600
        )
        state.updatePointer(y: 575, now: 0)

        #expect(state.advance(now: 0.249) == 0)
        #expect(state.advance(now: 0.266) < 0)
    }

    @Test("Edge updates preserve dwell until the pointer leaves the edge")
    func pointerUpdatesDoNotRestartTheDwell() {
        var state = DragScrollState(
            stackOffset: 0,
            stackHeight: 900,
            viewportHeight: 600
        )
        state.updatePointer(y: 575, now: 0)
        state.updatePointer(y: 560, now: 0.2)
        #expect(state.advance(now: 0.249) == 0)
        #expect(state.advance(now: 0.266) < 0)

        let reachedOffset = state.stackOffset
        state.updatePointer(y: 500, now: 0.3)
        #expect(state.advance(now: 0.4) == reachedOffset)
    }

    @Test("Returning to an edge starts a fresh dwell")
    func reenteringEdgeRestartsDwell() {
        var state = DragScrollState(
            stackOffset: 0,
            stackHeight: 900,
            viewportHeight: 600
        )
        state.updatePointer(y: 575, now: 0)
        state.updatePointer(y: 500, now: 0.1)
        state.updatePointer(y: 575, now: 1)
        #expect(state.advance(now: 1.249) == 0)
        #expect(state.advance(now: 1.266) < 0)
    }

    @Test("Top edge reveals earlier stages and stops at the content inset")
    func topEdgeStopsAtInset() {
        var state = DragScrollState(
            stackOffset: -500,
            stackHeight: 900,
            viewportHeight: 600
        )
        state.updatePointer(y: 5, now: 0)
        for tick in 1...120 {
            _ = state.advance(now: 0.25 + Double(tick) / 60)
        }

        #expect(state.stackOffset == 12)
        #expect(state.edge == nil)
    }

    @Test("Bottom edge stops when the last stage is fully visible")
    func bottomEdgeStopsAtLastStage() {
        var state = DragScrollState(
            stackOffset: 0,
            stackHeight: 900,
            viewportHeight: 600
        )
        state.updatePointer(y: 599, now: 0)
        for tick in 1...120 {
            _ = state.advance(now: 0.25 + Double(tick) / 60)
        }

        #expect(abs(state.stackOffset - (-312)) < 0.001)
        #expect(state.edge == nil)
    }

    @Test("A delayed display tick cannot jump the viewport")
    func delayedTickIsBounded() {
        var state = DragScrollState(
            stackOffset: 0,
            stackHeight: 900,
            viewportHeight: 600
        )
        state.updatePointer(y: 599, now: 0)
        let offset = state.advance(now: 10)

        #expect(offset < 0)
        #expect(offset > -17)
    }

    @Test("A fully visible stack has no scrollable edge")
    func fittingStackCannotScroll() {
        var state = DragScrollState(
            stackOffset: 12,
            stackHeight: 500,
            viewportHeight: 600
        )
        state.updatePointer(y: 575, now: 0)
        #expect(state.edge == nil)
        #expect(state.advance(now: 1) == 12)
    }
}
