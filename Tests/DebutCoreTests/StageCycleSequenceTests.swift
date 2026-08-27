import Testing
import CoreGraphics
@testable import DebutInputDriver

@Suite("Stage Cycle Sequence")
struct StageCycleSequenceTests {
    private let tab: CGKeyCode = 48

    private func tabEvents(_ events: [SyntheticKeyEvent]) -> [SyntheticKeyEvent] {
        events.filter {
            if case .key(let code, _) = $0.kind { return code == tab }
            return false
        }
    }

    @Test("Every Tab is delivered with Command and Option held")
    func modifiersStayHeldAcrossTabs() {
        let events = StageCycleSequence.events(forward: 3, backward: 2)
        let tabs = tabEvents(events)
        #expect(!tabs.isEmpty)
        for event in tabs {
            #expect(event.flags.contains(.maskCommand))
            #expect(event.flags.contains(.maskAlternate))
        }
    }

    /// Posting virtual key 55/58 as a key event does not change modifier state;
    /// the shipped fixture did that and the app never saw a modifier at all.
    @Test("Modifier transitions are flag changes, never key presses")
    func modifiersAreNeverPostedAsKeyEvents() {
        let events = StageCycleSequence.events(forward: 3, backward: 2)
        let modifierKeyCodes: Set<CGKeyCode> = [55, 56, 58]
        for event in events {
            if case .key(let code, _) = event.kind {
                #expect(!modifierKeyCodes.contains(code))
            }
        }
        #expect(events.contains { $0.kind == .flagsChanged })
    }

    @Test("The run opens by asserting Command and ends by clearing every modifier")
    func flagsBracketTheRun() {
        let events = StageCycleSequence.events(forward: 4, backward: 1)
        #expect(events.first?.kind == .flagsChanged)
        #expect(events.first?.flags == .maskCommand)
        #expect(events.last?.kind == .flagsChanged)
        #expect(events.last?.flags == [])
    }

    @Test("Command stays asserted until the final release")
    func commandIsHeldThroughout() {
        let events = StageCycleSequence.events(forward: 4, backward: 2)
        for event in events.dropLast() {
            #expect(event.flags.contains(.maskCommand))
        }
    }

    @Test("Every Tab is a matched down/up pair")
    func tabsArePaired() {
        let events = StageCycleSequence.events(forward: 3, backward: 2)
        let tabs = tabEvents(events)
        #expect(tabs.count == 10)
        for pair in stride(from: 0, to: tabs.count, by: 2) {
            #expect(tabs[pair].kind == .key(tab, down: true))
            #expect(tabs[pair + 1].kind == .key(tab, down: false))
        }
    }

    @Test("Backward steps add Shift and forward steps do not")
    func backwardStepsCarryShift() {
        let events = StageCycleSequence.events(forward: 3, backward: 2)
        let tabs = tabEvents(events)
        #expect(tabs.filter { $0.flags.contains(.maskShift) }.count == 4)
        #expect(tabs.filter { !$0.flags.contains(.maskShift) }.count == 6)
    }

    /// The shipped driver posted Cmd+Tab, which is `.nextWindow`, so the VM suite
    /// measured window cycling while claiming to measure space cycling.
    @Test("A space step is never emitted as a bare Command+Tab")
    func neverEmitsWindowCycling() {
        let events = StageCycleSequence.events(forward: 6, backward: 3)
        let windowCycling = tabEvents(events).filter {
            $0.flags.contains(.maskCommand) && !$0.flags.contains(.maskAlternate)
        }
        #expect(windowCycling.isEmpty)
    }

    @Test("A run with no steps still opens and closes cleanly")
    func emptyRunIsBalanced() {
        let events = StageCycleSequence.events(forward: 0, backward: 0)
        #expect(tabEvents(events).isEmpty)
        #expect(events.last?.flags == [])
    }
}
