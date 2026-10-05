import AppKit
import CoreGraphics

/// The WindowServer's side of keyboard input: what it believes is held, which symbolic hotkeys
/// could take a keystroke before any app sees it, and every process filtering keystrokes.
///
/// A key that dies everywhere until Debut quits (KHA-930) can be lost in the tap, at a
/// hotkey, or in WindowServer state that Debut's connection holds. Captured beside the tap's
/// own record so one report can tell those apart.
enum KeyboardSystemSnapshot {
    static func details() -> [String: String] {
        let hotKeys = WindowServerSymbolicHotKeys()
        var bindings: [Int32: SymbolicHotKeyBinding] = [:]
        for id in Int32(0)..<512 {
            if let binding = hotKeys.binding(forHotKey: id) { bindings[id] = binding }
        }
        let desktopIDs = NativeDesktopShortcut.firstHotKeyID
            ..< NativeDesktopShortcut.firstHotKeyID + Int32(NativeDesktopShortcut.numberedDesktopCount)
        return [
            "heldKeysHID": heldKeys(.hidSystemState),
            "heldKeysSession": heldKeys(.combinedSessionState),
            "flagsHID": String(CGEventSource.flagsState(.hidSystemState).rawValue, radix: 16),
            "flagsSession": String(CGEventSource.flagsState(.combinedSessionState).rawValue, radix: 16),
            "bareKeyHotKeys": bareKeyHotKeys(bindings),
            "desktopHotKeysEnabled": desktopIDs
                .filter { bindings[$0]?.isEnabled == true }
                .map(String.init)
                .joined(separator: ","),
            "keyboardTaps": keyboardTaps(),
        ]
    }

    /// Enabled hotkeys a keystroke without Control, Option or Command can trigger, as
    /// `id:keyCode:flags`. Only these can swallow plain typing.
    static func bareKeyHotKeys(_ bindings: [Int32: SymbolicHotKeyBinding]) -> String {
        bindings
            .filter { _, binding in
                binding.isEnabled
                    && binding.keyCode != NativeDesktopShortcut.unboundKeyCode
                    && binding.flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty
            }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.keyCode):\(String($0.value.flags.rawValue, radix: 16))" }
            .joined(separator: ",")
    }

    private static func heldKeys(_ state: CGEventSourceStateID) -> String {
        (0..<128)
            .filter { CGEventSource.keyState(state, key: CGKeyCode($0)) }
            .map(String.init)
            .joined(separator: ",")
    }

    /// Every event tap that sees key-down, key-up or modifier changes, as
    /// `process(pid):enabled:point:mode`.
    private static func keyboardTaps() -> String {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return "" }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return "" }
        let keyMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        return taps.prefix(Int(count))
            .filter { $0.eventsOfInterest & keyMask != 0 }
            .map { tap in
                let name = NSRunningApplication(processIdentifier: tap.tappingProcess)?
                    .localizedName ?? "unknown"
                let mode = tap.options == .listenOnly ? "listen" : "filter"
                return "\(name)(\(tap.tappingProcess)):\(tap.enabled):\(tap.tapPoint.rawValue):\(mode)"
            }
            .joined(separator: ",")
    }
}
