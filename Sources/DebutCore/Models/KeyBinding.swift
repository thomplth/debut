import Carbon.HIToolbox

public enum KeyAction: String, Codable, Sendable, CaseIterable {
    // Global Space Manager activation
    case activateNextWindow
    case activatePreviousWindow
    case activateNextSpace
    case activatePreviousSpace
    case activatePreviousSpaceAlternate

    // Global alt-tab switcher activation
    case activateAltTabNext
    case activateAltTabPrevious

    // Global space switching
    case quickSwitchSpace1, quickSwitchSpace2, quickSwitchSpace3
    case quickSwitchSpace4, quickSwitchSpace5, quickSwitchSpace6
    case quickSwitchSpace7, quickSwitchSpace8, quickSwitchSpace9

    // Global same-app window cycling
    case nextAppWindow
    case previousAppWindow

    // Global focused-window movement between spaces
    case moveFocusedWindowToPreviousSpace
    case moveFocusedWindowToPreviousSpaceAlternate
    case moveFocusedWindowToNextSpace
    case moveFocusedWindowToNextSpaceAlternate

    // Space Manager session
    case nextWindow
    case previousWindow
    case previousWindowAlternate
    case selectLeft
    case selectDown
    case selectUp
    case selectRight
    case nextSpace
    case previousSpace
    case nextDisplayStack
    case jumpToSpace1, jumpToSpace2, jumpToSpace3
    case jumpToSpace4, jumpToSpace5, jumpToSpace6
    case jumpToSpace7, jumpToSpace8, jumpToSpace9
    case moveWindowUp
    case moveWindowDown
    case moveWindowLeft
    case moveWindowRight
    case quitSelectedApp
    case closeSelectedWindow
    case dismissOverlay

    public var displayName: String {
        switch self {
        case .activateNextWindow: "Open / cycle windows"
        case .activatePreviousWindow: "Open / cycle windows backward"
        case .activateNextSpace: "Open / cycle spaces"
        case .activatePreviousSpace: "Open / cycle spaces backward"
        case .activatePreviousSpaceAlternate: "Open / cycle spaces backward (alternate)"
        case .activateAltTabNext: "Open / cycle all windows"
        case .activateAltTabPrevious: "Open / cycle all windows backward"
        case .quickSwitchSpace1: "Quick switch to space 1"
        case .quickSwitchSpace2: "Quick switch to space 2"
        case .quickSwitchSpace3: "Quick switch to space 3"
        case .quickSwitchSpace4: "Quick switch to space 4"
        case .quickSwitchSpace5: "Quick switch to space 5"
        case .quickSwitchSpace6: "Quick switch to space 6"
        case .quickSwitchSpace7: "Quick switch to space 7"
        case .quickSwitchSpace8: "Quick switch to space 8"
        case .quickSwitchSpace9: "Quick switch to space 9"
        case .nextAppWindow: "Next window in current app"
        case .previousAppWindow: "Previous window in current app"
        case .moveFocusedWindowToPreviousSpace: "Move to previous stage"
        case .moveFocusedWindowToPreviousSpaceAlternate:
            "Move to previous stage (alternate)"
        case .moveFocusedWindowToNextSpace: "Move to next stage"
        case .moveFocusedWindowToNextSpaceAlternate: "Move to next stage (alternate)"
        case .nextWindow: "Next window"
        case .previousWindow: "Previous window"
        case .previousWindowAlternate: "Previous window (alternate)"
        case .selectLeft: "Select card left"
        case .selectDown: "Select card down"
        case .selectUp: "Select card up"
        case .selectRight: "Select card right"
        case .nextSpace: "Next space"
        case .previousSpace: "Previous space"
        case .nextDisplayStack: "Next display stack"
        case .jumpToSpace1: "Jump to space 1"
        case .jumpToSpace2: "Jump to space 2"
        case .jumpToSpace3: "Jump to space 3"
        case .jumpToSpace4: "Jump to space 4"
        case .jumpToSpace5: "Jump to space 5"
        case .jumpToSpace6: "Jump to space 6"
        case .jumpToSpace7: "Jump to space 7"
        case .jumpToSpace8: "Jump to space 8"
        case .jumpToSpace9: "Jump to last space"
        case .moveWindowUp: "Move window up"
        case .moveWindowDown: "Move window down"
        case .moveWindowLeft: "Move window left in space"
        case .moveWindowRight: "Move window right in space"
        case .quitSelectedApp: "Quit selected app"
        case .closeSelectedWindow: "Close selected window"
        case .dismissOverlay: "Close overlay"
        }
    }

    public func toKeyEvent() -> DebutKeyEvent {
        switch self {
        case .activateNextWindow: .cmdTabHold
        case .activatePreviousWindow: .cmdShiftTabHold
        case .activateNextSpace: .cmdOptionTabHold
        case .activatePreviousSpace: .cmdOptionShiftTabHold
        case .activatePreviousSpaceAlternate: .cmdOptionShiftTabHold
        case .activateAltTabNext: .altTabHold
        case .activateAltTabPrevious: .altTabShiftHold
        case .quickSwitchSpace1: .switchToSpace(1)
        case .quickSwitchSpace2: .switchToSpace(2)
        case .quickSwitchSpace3: .switchToSpace(3)
        case .quickSwitchSpace4: .switchToSpace(4)
        case .quickSwitchSpace5: .switchToSpace(5)
        case .quickSwitchSpace6: .switchToSpace(6)
        case .quickSwitchSpace7: .switchToSpace(7)
        case .quickSwitchSpace8: .switchToSpace(8)
        case .quickSwitchSpace9: .switchToSpace(9)
        case .nextAppWindow: .cmdBacktick
        case .previousAppWindow: .cmdShiftBacktick
        case .moveFocusedWindowToPreviousSpace,
             .moveFocusedWindowToPreviousSpaceAlternate:
            .moveFocusedWindowToAdjacentSpace(-1)
        case .moveFocusedWindowToNextSpace,
             .moveFocusedWindowToNextSpaceAlternate:
            .moveFocusedWindowToAdjacentSpace(1)
        case .nextWindow: .nextWindow
        case .previousWindow: .previousWindow
        case .previousWindowAlternate: .previousWindow
        case .selectLeft: .selectLeft
        case .selectDown: .selectDown
        case .selectUp: .selectUp
        case .selectRight: .selectRight
        case .nextSpace: .nextSpace
        case .previousSpace: .previousSpace
        case .nextDisplayStack: .nextDisplayStack
        case .jumpToSpace1: .jumpToSpace(1)
        case .jumpToSpace2: .jumpToSpace(2)
        case .jumpToSpace3: .jumpToSpace(3)
        case .jumpToSpace4: .jumpToSpace(4)
        case .jumpToSpace5: .jumpToSpace(5)
        case .jumpToSpace6: .jumpToSpace(6)
        case .jumpToSpace7: .jumpToSpace(7)
        case .jumpToSpace8: .jumpToSpace(8)
        case .jumpToSpace9: .jumpToLastSpace
        case .moveWindowUp: .moveWindowUp
        case .moveWindowDown: .moveWindowDown
        case .moveWindowLeft: .moveWindowLeft
        case .moveWindowRight: .moveWindowRight
        case .quitSelectedApp: .quitSelectedApp
        case .closeSelectedWindow: .closeSelectedWindow
        case .dismissOverlay: .escape
        }
    }

    /// Held cycling clamps at the end it is travelling toward instead of wrapping, so an
    /// auto-repeat resolves to a distinct event from a fresh press of the same shortcut.
    public func toKeyEvent(autoRepeat: Bool) -> DebutKeyEvent {
        guard autoRepeat else { return toKeyEvent() }
        return switch self {
        case .activateNextWindow, .nextWindow: .nextWindowRepeat
        case .activatePreviousWindow, .previousWindow, .previousWindowAlternate:
            .previousWindowRepeat
        case .nextAppWindow: .cmdBacktickRepeat
        case .previousAppWindow: .cmdShiftBacktickRepeat
        case .activateAltTabNext: .altTabHoldRepeat
        case .activateAltTabPrevious: .altTabShiftHoldRepeat
        default: toKeyEvent()
        }
    }

    public var shortcutScope: ShortcutScope {
        switch self {
        case .activateNextWindow, .activatePreviousWindow,
             .activateNextSpace, .activatePreviousSpace, .activatePreviousSpaceAlternate,
             .activateAltTabNext, .activateAltTabPrevious,
             .quickSwitchSpace1, .quickSwitchSpace2, .quickSwitchSpace3,
             .quickSwitchSpace4, .quickSwitchSpace5, .quickSwitchSpace6,
             .quickSwitchSpace7, .quickSwitchSpace8, .quickSwitchSpace9,
             .nextAppWindow, .previousAppWindow,
             .moveFocusedWindowToPreviousSpace,
             .moveFocusedWindowToPreviousSpaceAlternate,
             .moveFocusedWindowToNextSpace,
             .moveFocusedWindowToNextSpaceAlternate:
            .global
        default:
            .session
        }
    }

    public var isOverlayActivation: Bool {
        switch self {
        case .activateNextWindow, .activatePreviousWindow,
             .activateNextSpace, .activatePreviousSpace, .activatePreviousSpaceAlternate,
             .activateAltTabNext, .activateAltTabPrevious:
            true
        default:
            false
        }
    }

    /// Opens the flat cross-space switcher rather than the stage overlay.
    public var opensAltTabSwitcher: Bool {
        self == .activateAltTabNext || self == .activateAltTabPrevious
    }

    public var quickSwitchPosition: Int? {
        switch self {
        case .quickSwitchSpace1: 1
        case .quickSwitchSpace2: 2
        case .quickSwitchSpace3: 3
        case .quickSwitchSpace4: 4
        case .quickSwitchSpace5: 5
        case .quickSwitchSpace6: 6
        case .quickSwitchSpace7: 7
        case .quickSwitchSpace8: 8
        case .quickSwitchSpace9: 9
        default: nil
        }
    }

    public var isSameAppCycle: Bool {
        self == .nextAppWindow || self == .previousAppWindow
    }

    public var movesFocusedWindowBetweenSpaces: Bool {
        focusedWindowMoveOffset != nil
    }

    public var focusedWindowMoveOffset: Int? {
        switch self {
        case .moveFocusedWindowToPreviousSpace,
             .moveFocusedWindowToPreviousSpaceAlternate:
            -1
        case .moveFocusedWindowToNextSpace,
             .moveFocusedWindowToNextSpaceAlternate:
            1
        default:
            nil
        }
    }

    /// Actions that step a selection one place along a list. Only these are paced while held:
    /// swallowing repeats of something like "delete space" would drop keystrokes the user meant.
    public var isCycling: Bool {
        switch self {
        case .activateNextWindow, .activatePreviousWindow,
             .activateNextSpace, .activatePreviousSpace, .activatePreviousSpaceAlternate,
             .activateAltTabNext, .activateAltTabPrevious,
             .nextAppWindow, .previousAppWindow,
             .nextWindow, .previousWindow, .previousWindowAlternate,
             .selectLeft, .selectDown, .selectUp, .selectRight,
             .nextSpace, .previousSpace:
            true
        case .nextDisplayStack:
            true
        default:
            false
        }
    }

    public static let activationActions: [KeyAction] = [
        .activateNextWindow, .activatePreviousWindow,
        .activateNextSpace, .activatePreviousSpace, .activatePreviousSpaceAlternate,
    ]

    public static let quickSwitchActions: [KeyAction] = [
        .quickSwitchSpace1, .quickSwitchSpace2, .quickSwitchSpace3,
        .quickSwitchSpace4, .quickSwitchSpace5, .quickSwitchSpace6,
        .quickSwitchSpace7, .quickSwitchSpace8, .quickSwitchSpace9,
    ]

    public static let sameAppActions: [KeyAction] = [
        .nextAppWindow, .previousAppWindow,
    ]

    public static let focusedWindowMoveActions: [KeyAction] = [
        .moveFocusedWindowToPreviousSpace,
        .moveFocusedWindowToPreviousSpaceAlternate,
        .moveFocusedWindowToNextSpace,
        .moveFocusedWindowToNextSpaceAlternate,
    ]

    public static let altTabActions: [KeyAction] = [
        .activateAltTabNext, .activateAltTabPrevious,
    ]

    public static let overlaySelectionActions: [KeyAction] = [
        .selectLeft, .selectDown, .selectUp, .selectRight,
    ]

    public static let globalActions =
        activationActions + altTabActions + quickSwitchActions + sameAppActions
            + focusedWindowMoveActions
    public static let sessionActions = allCases.filter { $0.shortcutScope == .session }

    public static func jumpAction(forSpaceIndex index: Int) -> KeyAction? {
        switch index {
        case 0: .jumpToSpace1
        case 1: .jumpToSpace2
        case 2: .jumpToSpace3
        case 3: .jumpToSpace4
        case 4: .jumpToSpace5
        case 5: .jumpToSpace6
        case 6: .jumpToSpace7
        case 7: .jumpToSpace8
        case 8: .jumpToSpace9
        default: nil
        }
    }
}

public enum ShortcutScope: Sendable, Equatable {
    case global
    case session
}

public struct KeyCombo: Codable, Sendable, Equatable, Hashable {
    public let keyCode: Int
    public let command: Bool
    public let control: Bool
    public let shift: Bool
    public let option: Bool

    public init(
        keyCode: Int,
        command: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        option: Bool = false
    ) {
        self.keyCode = keyCode
        self.command = command
        self.control = control
        self.shift = shift
        self.option = option
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, command, control, shift, option
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(Int.self, forKey: .keyCode)
        command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? false
        control = try container.decodeIfPresent(Bool.self, forKey: .control) ?? false
        shift = try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        option = try container.decodeIfPresent(Bool.self, forKey: .option) ?? false
    }

    public var displayString: String {
        var parts: [String] = []
        if command { parts.append("Command") }
        if control { parts.append("Control") }
        if shift { parts.append("Shift") }
        if option { parts.append("Option") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    /// The compact form shown beside the display-stack indicator: symbols instead of modifier
    /// names, so it fits the indicator's small capsule.
    var displayStackShortcutString: String {
        displayString
            .replacingOccurrences(of: "Shift+", with: "⇧")
            .replacingOccurrences(of: "Option+", with: "⌥")
            .replacingOccurrences(of: "Delete", with: "⌫")
    }

    private var keyName: String {
        switch keyCode {
        case kVK_Tab: "Tab"
        case kVK_Escape: "Esc"
        case kVK_Space: "Space"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "Fwd Delete"
        case kVK_Return: "Return"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_ANSI_Grave: "`"
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Slash: "/"
        default: "Key\(keyCode)"
        }
    }

    public static func defaults() -> [KeyAction: KeyCombo] {
        [
            .activateNextWindow: KeyCombo(keyCode: kVK_Tab, command: true),
            .activatePreviousWindow: KeyCombo(keyCode: kVK_Tab, command: true, shift: true),
            .activateNextSpace: KeyCombo(keyCode: kVK_Tab, command: true, option: true),
            .activatePreviousSpace: KeyCombo(
                keyCode: kVK_Tab,
                command: true,
                shift: true,
                option: true
            ),
            .activatePreviousSpaceAlternate: KeyCombo(
                keyCode: kVK_ANSI_Grave,
                command: true,
                option: true
            ),
            .activateAltTabNext: KeyCombo(keyCode: kVK_Tab, option: true),
            .activateAltTabPrevious: KeyCombo(keyCode: kVK_Tab, shift: true, option: true),
            .quickSwitchSpace1: KeyCombo(keyCode: kVK_ANSI_1, control: true),
            .quickSwitchSpace2: KeyCombo(keyCode: kVK_ANSI_2, control: true),
            .quickSwitchSpace3: KeyCombo(keyCode: kVK_ANSI_3, control: true),
            .quickSwitchSpace4: KeyCombo(keyCode: kVK_ANSI_4, control: true),
            .quickSwitchSpace5: KeyCombo(keyCode: kVK_ANSI_5, control: true),
            .quickSwitchSpace6: KeyCombo(keyCode: kVK_ANSI_6, control: true),
            .quickSwitchSpace7: KeyCombo(keyCode: kVK_ANSI_7, control: true),
            .quickSwitchSpace8: KeyCombo(keyCode: kVK_ANSI_8, control: true),
            .quickSwitchSpace9: KeyCombo(keyCode: kVK_ANSI_9, control: true),
            .nextAppWindow: KeyCombo(keyCode: kVK_ANSI_Grave, command: true),
            .previousAppWindow: KeyCombo(
                keyCode: kVK_ANSI_Grave,
                command: true,
                shift: true
            ),
            .moveFocusedWindowToPreviousSpace: KeyCombo(
                keyCode: kVK_LeftArrow,
                command: true,
                option: true
            ),
            .moveFocusedWindowToPreviousSpaceAlternate: KeyCombo(
                keyCode: kVK_UpArrow,
                command: true,
                option: true
            ),
            .moveFocusedWindowToNextSpace: KeyCombo(
                keyCode: kVK_RightArrow,
                command: true,
                option: true
            ),
            .moveFocusedWindowToNextSpaceAlternate: KeyCombo(
                keyCode: kVK_DownArrow,
                command: true,
                option: true
            ),
            .nextWindow: KeyCombo(keyCode: kVK_Tab),
            .previousWindow: KeyCombo(keyCode: kVK_Tab, shift: true),
            .previousWindowAlternate: KeyCombo(keyCode: kVK_ANSI_Grave),
            .selectLeft: KeyCombo(keyCode: kVK_ANSI_H),
            .selectDown: KeyCombo(keyCode: kVK_ANSI_J),
            .selectUp: KeyCombo(keyCode: kVK_ANSI_K),
            .selectRight: KeyCombo(keyCode: kVK_ANSI_L),
            .nextSpace: KeyCombo(keyCode: kVK_Tab, option: true),
            .previousSpace: KeyCombo(keyCode: kVK_Tab, shift: true, option: true),
            .nextDisplayStack: KeyCombo(keyCode: kVK_Return),
            .jumpToSpace1: KeyCombo(keyCode: kVK_ANSI_1),
            .jumpToSpace2: KeyCombo(keyCode: kVK_ANSI_2),
            .jumpToSpace3: KeyCombo(keyCode: kVK_ANSI_3),
            .jumpToSpace4: KeyCombo(keyCode: kVK_ANSI_4),
            .jumpToSpace5: KeyCombo(keyCode: kVK_ANSI_5),
            .jumpToSpace6: KeyCombo(keyCode: kVK_ANSI_6),
            .jumpToSpace7: KeyCombo(keyCode: kVK_ANSI_7),
            .jumpToSpace8: KeyCombo(keyCode: kVK_ANSI_8),
            .jumpToSpace9: KeyCombo(keyCode: kVK_ANSI_9),
            .moveWindowUp: KeyCombo(keyCode: kVK_UpArrow),
            .moveWindowDown: KeyCombo(keyCode: kVK_DownArrow),
            .moveWindowLeft: KeyCombo(keyCode: kVK_LeftArrow),
            .moveWindowRight: KeyCombo(keyCode: kVK_RightArrow),
            // Session combos are matched with the held primary modifier stripped, so these are
            // the physical Cmd+Q and Cmd+W shortcuts the user already reaches for.
            .quitSelectedApp: KeyCombo(keyCode: kVK_ANSI_Q),
            .closeSelectedWindow: KeyCombo(keyCode: kVK_ANSI_W),
            .dismissOverlay: KeyCombo(keyCode: kVK_Escape),
        ]
    }
}

public struct KeyBindings: Codable, Sendable, Equatable {
    public var bindings: [KeyAction: KeyCombo]
    public private(set) var disabledActions: Set<KeyAction>

    public init() {
        self.bindings = KeyCombo.defaults()
        self.disabledActions = []
    }

    private enum CodingKeys: String, CodingKey {
        case bindings
        case disabledActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decodeIfPresent(
            DecodedKeyActionDictionary<KeyCombo>.self,
            forKey: .bindings
        )?.values ?? [:]
        disabledActions = try container.decodeIfPresent(
            Set<KeyAction>.self, forKey: .disabledActions
        ) ?? []
        var defaults = KeyCombo.defaults()
        for action in KeyAction.overlaySelectionActions where saved[action] == nil {
            if let combo = defaults[action], saved.contains(where: { $0.key != action && $0.value == combo }) {
                defaults.removeValue(forKey: action)
            }
        }
        bindings = defaults.merging(saved) { _, savedCombo in savedCombo }
        for action in disabledActions { bindings.removeValue(forKey: action) }
    }

    public mutating func clear(_ action: KeyAction) {
        bindings.removeValue(forKey: action)
        disabledActions.insert(action)
    }

    public mutating func set(_ combo: KeyCombo, for action: KeyAction) {
        disabledActions.remove(action)
        bindings[action] = combo
    }

    public mutating func record(_ combo: KeyCombo, for action: KeyAction) {
        if (combo.keyCode == kVK_Delete || combo.keyCode == kVK_ForwardDelete)
            && !combo.command && !combo.control && !combo.shift && !combo.option {
            clear(action)
        } else {
            set(combo, for: action)
        }
    }

    public func action(for combo: KeyCombo) -> KeyAction? {
        bindings.first(where: { $0.value == combo && !disabledActions.contains($0.key) })?.key
    }

    public func action(for combo: KeyCombo, scope: ShortcutScope) -> KeyAction? {
        KeyAction.allCases.first { action in
            action.shortcutScope == scope && !disabledActions.contains(action)
                && bindings[action] == combo
        }
    }

    public func combo(for action: KeyAction) -> KeyCombo? {
        disabledActions.contains(action) ? nil : bindings[action]
    }

    public mutating func restoreDefaults() {
        bindings = KeyCombo.defaults()
        disabledActions = []
    }
}

struct DecodedKeyActionDictionary<Value: Decodable>: Decodable {
    let values: [KeyAction: Value]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [KeyAction: Value] = [:]
        while !container.isAtEnd {
            let rawAction = try container.decode(String.self)
            let value = try container.decode(Value.self)
            if let action = KeyAction(rawValue: rawAction) {
                values[action] = value
            }
        }
        self.values = values
    }
}
