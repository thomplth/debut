import CoreGraphics
import Foundation

// Moving a foreign window between desktops needs a Space switch to happen *while a drag is
// held*, and the only switch that works under that condition is a real keyboard shortcut.
// Probe 8 established the alternative does not exist: the Dock ignores the forged DockSwipe
// that SpaceService otherwise uses whenever a mouse drag is in flight.
//
// So the move rides on the user's own "switch to desktop" shortcuts, which means reading what
// those shortcuts actually are. Assuming the documented defaults is wrong twice over — the
// arrow bindings carry Fn alongside Control, and the numbered bindings on this machine are
// Control+Option+N rather than Control+N.

/// A shortcut as macOS has it configured, ready to post as a key event.
public struct SymbolicHotkey: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags

    public init(keyCode: CGKeyCode, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }

    /// Modifier bits as `com.apple.symbolichotkeys` stores them, which are `NSEvent`'s values.
    private static let modifierFlags: [(mask: Int, flag: CGEventFlags)] = [
        (0x20000, .maskShift),
        (0x40000, .maskControl),
        (0x80000, .maskAlternate),
        (0x100000, .maskCommand),
        (0x800000, .maskSecondaryFn),
    ]

    /// - Returns: `nil` when the binding is disabled or malformed. A disabled binding must not
    ///   be posted: its chord means something else, and the drag would deliver that to
    ///   whichever app owns the window.
    static func parse(_ entry: Any?) -> SymbolicHotkey? {
        guard let entry = entry as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber],
              parameters.count >= 3
        else { return nil }

        let keyCode = parameters[1].intValue
        guard let key = CGKeyCode(exactly: keyCode) else { return nil }

        let mask = parameters[2].intValue
        let flags = modifierFlags.reduce(into: CGEventFlags()) { result, entry in
            if mask & entry.mask != 0 { result.insert(entry.flag) }
        }
        return SymbolicHotkey(keyCode: key, flags: flags)
    }
}

/// The `AppleSymbolicHotKeys` identifiers this app depends on.
enum SymbolicHotkeyID {
    static let moveLeft = 79
    static let moveRight = 81

    /// "Switch to Desktop N" for a zero-based desktop index. Only a handful of these exist —
    /// 118 through 122 on a stock system — so a far desktop legitimately resolves to nothing.
    static func directDesktop(_ index: Int) -> Int { 118 + index }
}

public protocol SymbolicHotkeyReading: Sendable {
    func hotkey(id: Int) -> SymbolicHotkey?
}

/// Reads the live bindings out of `com.apple.symbolichotkeys`.
public struct SymbolicHotkeyDefaults: SymbolicHotkeyReading {
    public init() {}

    public func hotkey(id: Int) -> SymbolicHotkey? {
        guard let all = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        else { return nil }
        return SymbolicHotkey.parse(all["\(id)"])
    }
}

/// Which chords to press, in order, while a window drag is held.
enum SpaceMoveKeystrokes {

    /// - Returns: `nil` when there is nothing to do or no binding can do it. An empty array
    ///   would be worse than `nil` — it reads as success and leaves the caller holding a drag
    ///   that never resolves anywhere.
    static func plan(from current: Int,
                     to target: Int,
                     desktopCount: Int,
                     direct: (Int) -> SymbolicHotkey?,
                     step: (SpaceSwitchDirection) -> SymbolicHotkey?) -> [SymbolicHotkey]? {
        guard let plan = SpaceSwitchPlan(from: current, to: target, desktopCount: desktopCount)
        else { return nil }

        if let chord = direct(target) { return [chord] }
        guard let chord = step(plan.direction) else { return nil }
        return Array(repeating: chord, count: plan.steps)
    }
}
