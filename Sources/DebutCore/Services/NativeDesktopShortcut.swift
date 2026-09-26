import CoreGraphics
import Foundation

// The WindowServer's live copy of the symbolic hotkeys, which is what it matches keystrokes
// against. `com.apple.symbolichotkeys` is only the saved preference and can lag behind it.
private let cgsGetSymbolicHotKeyValue: (@convention(c)
    (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>,
     UnsafeMutablePointer<UInt32>) -> CGError)? =
    skyLightSymbol("CGSGetSymbolicHotKeyValue")
private let cgsIsSymbolicHotKeyEnabled: (@convention(c) (Int32) -> Bool)? =
    skyLightSymbol("CGSIsSymbolicHotKeyEnabled")
// Session-scoped, not written to preferences: the user's saved choice is untouched.
private let cgsSetSymbolicHotKeyEnabled: (@convention(c) (Int32, Bool) -> CGError)? =
    skyLightSymbol("CGSSetSymbolicHotKeyEnabled")

/// One symbolic hotkey as the WindowServer currently binds it.
struct SymbolicHotKeyBinding: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let isEnabled: Bool
}

/// macOS's own "Switch to Desktop N" shortcut, which is what Control-number triggers.
///
/// The Dock answers it with one direct transition to the numbered desktop. A Dock swipe moves
/// at most one desktop per gesture, so an addressed swipe route to a far desktop slides through
/// every desktop in between; this shortcut is the only addressed request that does not.
enum NativeDesktopShortcut {
    /// "Switch to Desktop 1". Desktops 1 through 16 follow consecutively.
    static let firstHotKeyID: Int32 = 118
    static let numberedDesktopCount = 16
    /// The key code a symbolic hotkey reports when nothing is bound to it.
    static let unboundKeyCode: CGKeyCode = 0xFFFF

    /// The shortcut addressing `location`, when it is one of the numbered desktops.
    ///
    /// Only a single Space stack is addressed. Whether macOS numbers desktops per display or
    /// across displays when displays have separate Spaces has not been measured, and a wrong
    /// guess would switch a different display's desktop.
    static func hotKeyID(for location: DesktopLocation, in topology: SpaceTopology) -> Int32? {
        guard topology.stacks.count == 1,
              let stack = topology.stack(id: location.stackID),
              stack.desktopIDs.indices.contains(location.index),
              stack.desktopIDs[location.index] == location.desktopID,
              location.index < numberedDesktopCount,
              stack.currentDesktopID != location.desktopID
        else { return nil }
        return firstHotKeyID + Int32(location.index)
    }

    enum Delivery: Equatable {
        case post(SymbolicHotKeyBinding)
        /// macOS ships these shortcuts disabled. Enabling one for the length of Debut's own
        /// keystroke gives the native transition without changing the user's saved choice.
        case postTemporarilyEnabled(SymbolicHotKeyBinding)
    }

    /// Whether posting the binding's keystroke is safe. A keystroke the WindowServer does not
    /// claim as a hotkey reaches the frontmost app instead, so a binding without a modifier —
    /// which would type a character into it — is never posted.
    static func delivery(for binding: SymbolicHotKeyBinding?) -> Delivery? {
        guard let binding,
              binding.keyCode != unboundKeyCode,
              !binding.flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty
        else { return nil }
        return binding.isEnabled ? .post(binding) : .postTemporarilyEnabled(binding)
    }
}

/// The WindowServer side of the symbolic hotkeys. A protocol so the delivery order can be
/// tested without posting a real keystroke into the session running the tests.
protocol SymbolicHotKeyControlling: Sendable {
    func binding(forHotKey id: Int32) -> SymbolicHotKeyBinding?
    @discardableResult func setEnabled(_ enabled: Bool, hotKey id: Int32) -> Bool
    func post(_ binding: SymbolicHotKeyBinding) -> Bool
}

struct WindowServerSymbolicHotKeys: SymbolicHotKeyControlling {
    func binding(forHotKey id: Int32) -> SymbolicHotKeyBinding? {
        guard let cgsGetSymbolicHotKeyValue, let cgsIsSymbolicHotKeyEnabled else { return nil }
        var character: UInt16 = 0
        var keyCode: UInt16 = 0
        var modifiers: UInt32 = 0
        guard cgsGetSymbolicHotKeyValue(id, &character, &keyCode, &modifiers) == .success
        else { return nil }
        return SymbolicHotKeyBinding(
            keyCode: keyCode,
            flags: CGEventFlags(rawValue: UInt64(modifiers)),
            isEnabled: cgsIsSymbolicHotKeyEnabled(id)
        )
    }

    func setEnabled(_ enabled: Bool, hotKey id: Int32) -> Bool {
        cgsSetSymbolicHotKeyEnabled?(id, enabled) == .success
    }

    /// Symbolic hotkeys are matched where hardware input enters the session, so the keystroke
    /// is posted at the HID tap. It carries Debut's synthetic marker so Debut's own taps let it
    /// pass instead of reading it as the user's Control-number.
    func post(_ binding: SymbolicHotKeyBinding) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode,
                                 keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode,
                               keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = binding.flags
            event.setIntegerValueField(.eventSourceUserData,
                                       value: DesktopSwipeService.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Requests a desktop through its native shortcut.
///
/// Resolving and posting are separate so the caller can decide synchronously whether this route
/// applies, then post a moment later.
struct NativeDesktopShortcutSwitch {
    /// Long enough for the WindowServer to have matched the posted keystroke; the Dock's
    /// transition itself does not depend on the hotkey staying enabled.
    static let temporaryEnableDuration: TimeInterval = 0.5

    struct Resolved: Equatable {
        let hotKeyID: Int32
        let delivery: NativeDesktopShortcut.Delivery

        var temporarilyEnabled: Bool {
            if case .postTemporarilyEnabled = delivery { return true }
            return false
        }
    }

    let hotKeys: any SymbolicHotKeyControlling
    /// Runs the restore of a temporarily enabled shortcut. Injected so tests can run it inline.
    let scheduleRestore: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The shortcut for `location`, or nil when the desktop is not addressable that way and the
    /// caller must use another route. Posts nothing.
    func resolve(_ location: DesktopLocation, in topology: SpaceTopology) -> Resolved? {
        guard let id = NativeDesktopShortcut.hotKeyID(for: location, in: topology),
              let delivery = NativeDesktopShortcut.delivery(for: hotKeys.binding(forHotKey: id))
        else { return nil }
        return Resolved(hotKeyID: id, delivery: delivery)
    }

    /// Posts a resolved shortcut. A shortcut that cannot be enabled posts nothing, so no
    /// keystroke reaches an app.
    @discardableResult
    func post(_ resolved: Resolved) -> Bool {
        let id = resolved.hotKeyID
        switch resolved.delivery {
        case .post(let binding):
            return hotKeys.post(binding)
        case .postTemporarilyEnabled(let binding):
            guard hotKeys.setEnabled(true, hotKey: id) else { return false }
            let posted = hotKeys.post(binding)
            let hotKeys = hotKeys
            if posted {
                scheduleRestore(Self.temporaryEnableDuration) {
                    hotKeys.setEnabled(false, hotKey: id)
                }
            } else {
                hotKeys.setEnabled(false, hotKey: id)
            }
            return posted
        }
    }
}
