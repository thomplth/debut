import Testing
import Foundation
import Carbon.HIToolbox
import CoreGraphics
@testable import DebutCore

@Suite("Native Switch to Desktop N")
struct NativeDesktopShortcutTests {

    private func stack(_ id: String = SpaceTopology.sharedStackID, desktops: Int,
                       current: Int?) -> SpaceStackDescriptor {
        let ids = (0..<desktops).map { CGSSpaceID(100 + $0) }
        return SpaceStackDescriptor(
            id: id, displayID: nil, displayName: id, frame: .zero,
            desktopIDs: ids,
            currentDesktopID: current.map { ids[$0] }
        )
    }

    private func topology(desktops: Int = 4, current: Int? = 0) -> SpaceTopology {
        SpaceTopology(separateSpaces: true, stacks: [stack(desktops: desktops, current: current)])
    }

    private func location(_ index: Int, in topology: SpaceTopology) -> DesktopLocation {
        topology.stacks[0].location(at: index)!
    }

    @Test("A numbered desktop maps to its own Switch to Desktop N shortcut")
    func numberedDesktop() {
        let topology = topology()
        #expect(NativeDesktopShortcut.hotKeyID(for: location(0, in: self.topology(current: 2)),
                                               in: self.topology(current: 2)) == 118)
        #expect(NativeDesktopShortcut.hotKeyID(for: location(2, in: topology), in: topology) == 120)
    }

    @Test("The showing desktop is not requested again")
    func showingDesktop() {
        let topology = topology(current: 2)
        #expect(NativeDesktopShortcut.hotKeyID(for: location(2, in: topology), in: topology) == nil)
    }

    @Test("Desktops past the sixteen numbered shortcuts have none")
    func beyondSixteen() {
        let topology = topology(desktops: 18)
        #expect(NativeDesktopShortcut.hotKeyID(for: location(15, in: topology), in: topology) == 133)
        #expect(NativeDesktopShortcut.hotKeyID(for: location(16, in: topology), in: topology) == nil)
    }

    @Test("Separate display stacks are left to the swipe route")
    func multipleStacks() {
        let topology = SpaceTopology(separateSpaces: true, stacks: [
            stack("a", desktops: 3, current: 0),
            stack("b", desktops: 3, current: 0),
        ])
        let target = topology.stacks[0].location(at: 2)!
        #expect(NativeDesktopShortcut.hotKeyID(for: target, in: topology) == nil)
    }

    @Test("A stale location no longer naming that desktop is refused")
    func staleLocation() {
        let topology = topology()
        let stale = DesktopLocation(stackID: SpaceTopology.sharedStackID, desktopID: 999, index: 2)
        #expect(NativeDesktopShortcut.hotKeyID(for: stale, in: topology) == nil)
    }

    @Test("Only a bound shortcut with a modifier is ever posted")
    func deliveryGuards() {
        let control = SymbolicHotKeyBinding(keyCode: 20, flags: .maskControl, isEnabled: true)
        #expect(NativeDesktopShortcut.delivery(for: nil) == nil)
        #expect(NativeDesktopShortcut.delivery(for: SymbolicHotKeyBinding(
            keyCode: NativeDesktopShortcut.unboundKeyCode, flags: .maskControl, isEnabled: true
        )) == nil)
        #expect(NativeDesktopShortcut.delivery(for: SymbolicHotKeyBinding(
            keyCode: 20, flags: .maskShift, isEnabled: true
        )) == nil)
        #expect(NativeDesktopShortcut.delivery(for: control) == .post(control))
        let disabled = SymbolicHotKeyBinding(keyCode: 20, flags: .maskControl, isEnabled: false)
        #expect(NativeDesktopShortcut.delivery(for: disabled) == .postTemporarilyEnabled(disabled))
    }

    final class FakeHotKeys: SymbolicHotKeyControlling, @unchecked Sendable {
        enum Call: Equatable {
            case enable(Int32, Bool)
            case post(CGKeyCode)
        }
        var bindings: [Int32: SymbolicHotKeyBinding] = [:]
        var enableSucceeds = true
        var postSucceeds = true
        var calls: [Call] = []

        func binding(forHotKey id: Int32) -> SymbolicHotKeyBinding? { bindings[id] }
        func setEnabled(_ enabled: Bool, hotKey id: Int32) -> Bool {
            calls.append(.enable(id, enabled))
            return enableSucceeds
        }
        func post(_ binding: SymbolicHotKeyBinding) -> Bool {
            calls.append(.post(binding.keyCode))
            return postSucceeds
        }
    }

    private func makeSwitch(_ hotKeys: FakeHotKeys) -> NativeDesktopShortcutSwitch {
        NativeDesktopShortcutSwitch(hotKeys: hotKeys, scheduleRestore: { _, restore in restore() })
    }

    @Test("An enabled shortcut is posted as the user's own Control-number")
    func enabledShortcut() {
        let hotKeys = FakeHotKeys()
        hotKeys.bindings[120] = SymbolicHotKeyBinding(keyCode: 20, flags: .maskControl,
                                                      isEnabled: true)
        let topology = topology()
        let shortcut = makeSwitch(hotKeys)
        let resolved = shortcut.resolve(location(2, in: topology), in: topology)
        #expect(resolved?.hotKeyID == 120)
        #expect(resolved?.temporarilyEnabled == false)
        #expect(hotKeys.calls.isEmpty)
        #expect(resolved.map(shortcut.post) == true)
        #expect(hotKeys.calls == [.post(20)])
    }

    @Test("A disabled shortcut is enabled only around Debut's keystroke")
    func disabledShortcut() {
        let hotKeys = FakeHotKeys()
        hotKeys.bindings[120] = SymbolicHotKeyBinding(keyCode: 20, flags: .maskControl,
                                                      isEnabled: false)
        let topology = topology()
        let shortcut = makeSwitch(hotKeys)
        let resolved = shortcut.resolve(location(2, in: topology), in: topology)
        #expect(resolved?.temporarilyEnabled == true)
        #expect(hotKeys.calls.isEmpty)
        #expect(resolved.map(shortcut.post) == true)
        #expect(hotKeys.calls == [.enable(120, true), .post(20), .enable(120, false)])
    }

    @Test("A shortcut that cannot be enabled posts nothing, so no keystroke reaches an app")
    func enableRefused() {
        let hotKeys = FakeHotKeys()
        hotKeys.enableSucceeds = false
        hotKeys.bindings[120] = SymbolicHotKeyBinding(keyCode: 20, flags: .maskControl,
                                                      isEnabled: false)
        let topology = topology()
        let shortcut = makeSwitch(hotKeys)
        let resolved = shortcut.resolve(location(2, in: topology), in: topology)
        #expect(resolved.map(shortcut.post) == false)
        #expect(hotKeys.calls == [.enable(120, true)])
    }

    @Test("A failed post restores the shortcut it enabled")
    func postFailedRestores() {
        let hotKeys = FakeHotKeys()
        hotKeys.postSucceeds = false
        hotKeys.bindings[120] = SymbolicHotKeyBinding(keyCode: 20, flags: .maskControl,
                                                      isEnabled: false)
        let topology = topology()
        let shortcut = makeSwitch(hotKeys)
        let resolved = shortcut.resolve(location(2, in: topology), in: topology)
        #expect(resolved.map(shortcut.post) == false)
        #expect(hotKeys.calls == [.enable(120, true), .post(20), .enable(120, false)])
    }

    @Test("An unbound shortcut falls back without touching the hotkey")
    func unbound() {
        let hotKeys = FakeHotKeys()
        let topology = topology()
        #expect(makeSwitch(hotKeys).resolve(location(2, in: topology), in: topology) == nil)
        #expect(hotKeys.calls.isEmpty)
    }

    @Test("Debut's own shortcut keystroke passes through its keyboard tap untouched")
    func syntheticKeystrokePassesThrough() {
        let service = EventTapKeyboardService()
        let delegate = TestKeyboardDelegate()
        _ = service.start(delegate: delegate)
        defer { service.stop() }
        service.features = FeatureSettings()
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_3),
                            keyDown: true)!
        event.flags = .maskControl
        event.setIntegerValueField(.eventSourceUserData,
                                   value: DesktopSwipeService.syntheticMarker)
        #expect(service.handleCGEvent(type: .keyDown, event: event) != nil)
        #expect(delegate.receivedEvents.isEmpty)
    }
}

@Suite("Native shortcut routes")
struct NativeShortcutRouteTrackerTests {
    private let stackID = SpaceTopology.sharedStackID

    private func location(_ index: Int) -> DesktopLocation {
        DesktopLocation(stackID: stackID, desktopID: CGSSpaceID(100 + index), index: index)
    }

    private func current(_ index: Int) -> [String: CGSSpaceID] { [stackID: CGSSpaceID(100 + index)] }

    @Test("A route completes when its endpoint shows")
    func completes() {
        var tracker = NativeShortcutRouteTracker()
        #expect(tracker.request(location(2), originID: 100) == .start(generation: 1))
        #expect(tracker.isInFlight(stackID: stackID))
        #expect(tracker.desktopDidChange(currentDesktopIDs: current(2)) == [stackID: .completed])
        #expect(!tracker.isInFlight(stackID: stackID))
    }

    @Test("A request during a route replaces its endpoint instead of posting")
    func coalescesAndContinues() {
        var tracker = NativeShortcutRouteTracker()
        _ = tracker.request(location(1), originID: 100)
        #expect(tracker.request(location(2), originID: 100) == .coalesced)
        // The origin still showing is the transition in progress, not a result.
        #expect(tracker.desktopDidChange(currentDesktopIDs: current(0)).isEmpty)
        #expect(tracker.isInFlight(stackID: stackID))
        #expect(tracker.desktopDidChange(currentDesktopIDs: current(1))
            == [stackID: .continueTo(location(2))])
        #expect(!tracker.isInFlight(stackID: stackID))
    }

    @Test("Landing somewhere unrequested abandons the route")
    func abandons() {
        var tracker = NativeShortcutRouteTracker()
        _ = tracker.request(location(1), originID: 100)
        #expect(tracker.desktopDidChange(currentDesktopIDs: current(3)) == [stackID: .abandoned])
        #expect(!tracker.isInFlight(stackID: stackID))
    }

    @Test("A missed shortcut hands back the latest endpoint only while the origin shows")
    func missed() {
        var tracker = NativeShortcutRouteTracker()
        guard case .start(let generation) = tracker.request(location(1), originID: 100) else {
            Issue.record("expected a new route"); return
        }
        _ = tracker.request(location(2), originID: 100)
        #expect(tracker.missed(generation: generation, stackID: stackID,
                               currentDesktopID: 101) == nil)
        #expect(tracker.missed(generation: generation, stackID: stackID,
                               currentDesktopID: 100) == location(2))
        #expect(!tracker.isInFlight(stackID: stackID))
        #expect(tracker.missed(generation: generation, stackID: stackID,
                               currentDesktopID: 100) == nil)
    }

    @Test("A stale generation cannot clear a newer route")
    func staleGeneration() {
        var tracker = NativeShortcutRouteTracker()
        _ = tracker.request(location(1), originID: 100)
        _ = tracker.desktopDidChange(currentDesktopIDs: current(1))
        _ = tracker.request(location(2), originID: 101)
        #expect(tracker.postingFailed(generation: 1, stackID: stackID) == nil)
        #expect(tracker.isInFlight(stackID: stackID))
        #expect(tracker.postingFailed(generation: 2, stackID: stackID) == location(2))
    }
}
