import Testing
import CoreGraphics
@testable import DebutCore

@Suite("Symbolic hotkey decoding")
struct SymbolicHotkeyDecodingTests {

    private func entry(enabled: Bool, keyCode: Int, modifiers: Int) -> [String: Any] {
        ["enabled": enabled,
         "value": ["parameters": [65535, keyCode, modifiers], "type": "standard"]]
    }

    // The arrow-key bindings carry Fn as well as Control. Posting Control alone never fires
    // them, which looks exactly like the whole technique being unsupported.
    @Test("An arrow binding decodes to Control and Fn together")
    func decodesArrowModifiers() {
        let hotkey = SymbolicHotkey.parse(entry(enabled: true, keyCode: 124, modifiers: 0x840000))

        #expect(hotkey?.keyCode == 124)
        #expect(hotkey?.flags == [.maskControl, .maskSecondaryFn])
    }

    @Test("A direct desktop binding decodes to Control and Option")
    func decodesDirectModifiers() {
        let hotkey = SymbolicHotkey.parse(entry(enabled: true, keyCode: 18, modifiers: 0xC0000))

        #expect(hotkey?.keyCode == 18)
        #expect(hotkey?.flags == [.maskControl, .maskAlternate])
    }

    @Test("Every modifier bit maps to its event flag")
    func decodesAllModifiers() {
        let mask = 0x20000 | 0x40000 | 0x80000 | 0x100000 | 0x800000
        let hotkey = SymbolicHotkey.parse(entry(enabled: true, keyCode: 1, modifiers: mask))

        #expect(hotkey?.flags == [.maskShift, .maskControl, .maskAlternate,
                                  .maskCommand, .maskSecondaryFn])
    }

    // A disabled binding is not a binding. Posting its chord would send an unrelated shortcut
    // into whichever app owns the window being dragged.
    @Test("A disabled binding reads as absent")
    func rejectsDisabled() {
        #expect(SymbolicHotkey.parse(entry(enabled: false, keyCode: 124, modifiers: 0x840000)) == nil)
    }

    @Test("A malformed entry reads as absent")
    func rejectsMalformed() {
        #expect(SymbolicHotkey.parse(nil) == nil)
        #expect(SymbolicHotkey.parse(["enabled": true]) == nil)
        #expect(SymbolicHotkey.parse(["enabled": true, "value": ["parameters": [65535]]]) == nil)
    }

    @Test("Direct desktop hotkey IDs start at 118")
    func directHotkeyIDs() {
        #expect(SymbolicHotkeyID.directDesktop(0) == 118)
        #expect(SymbolicHotkeyID.directDesktop(4) == 122)
    }
}

@Suite("Space move keystrokes")
struct SpaceMoveKeystrokeTests {

    private let direct = SymbolicHotkey(keyCode: 20, flags: [.maskControl, .maskAlternate])
    private let stepRight = SymbolicHotkey(keyCode: 124, flags: [.maskControl, .maskSecondaryFn])
    private let stepLeft = SymbolicHotkey(keyCode: 123, flags: [.maskControl, .maskSecondaryFn])

    // The direct chord is what makes assignment O(1). Stepping three desktops means three
    // visible transitions with a window dragging through each one.
    @Test("A direct binding moves any distance in one chord")
    func prefersDirect() {
        let keys = SpaceMoveKeystrokes.plan(
            from: 0, to: 3, desktopCount: 4,
            direct: { _ in self.direct },
            step: { _ in self.stepRight })

        #expect(keys == [direct])
    }

    @Test("Without a direct binding the move steps once per desktop")
    func fallsBackToStepping() {
        let keys = SpaceMoveKeystrokes.plan(
            from: 0, to: 3, desktopCount: 4,
            direct: { _ in nil },
            step: { direction in direction == .right ? self.stepRight : self.stepLeft })

        #expect(keys == [stepRight, stepRight, stepRight])
    }

    @Test("Stepping backwards uses the left binding")
    func stepsLeft() {
        let keys = SpaceMoveKeystrokes.plan(
            from: 2, to: 0, desktopCount: 4,
            direct: { _ in nil },
            step: { direction in direction == .right ? self.stepRight : self.stepLeft })

        #expect(keys == [stepLeft, stepLeft])
    }

    // The direct hotkeys only exist for the first few desktops — 123 and up are absent even on
    // a machine where 118-122 are enabled — so a far target must still fall back.
    @Test("A target with no direct binding falls back to stepping")
    func fallsBackForFarDesktop() {
        let keys = SpaceMoveKeystrokes.plan(
            from: 0, to: 6, desktopCount: 8,
            direct: { index in index < 5 ? self.direct : nil },
            step: { _ in self.stepRight })

        #expect(keys?.count == 6)
    }

    @Test("Moving to the desktop the window already occupies asks for nothing")
    func noSelfMove() {
        let keys = SpaceMoveKeystrokes.plan(
            from: 1, to: 1, desktopCount: 4,
            direct: { _ in self.direct },
            step: { _ in self.stepRight })

        #expect(keys == nil)
    }

    // With both bindings disabled there is no route. Returning an empty plan instead of nil
    // would let the caller hold a drag it can never resolve.
    @Test("With no usable binding there is no plan")
    func noBindings() {
        let keys = SpaceMoveKeystrokes.plan(
            from: 0, to: 2, desktopCount: 4,
            direct: { _ in nil },
            step: { _ in nil })

        #expect(keys == nil)
    }
}
