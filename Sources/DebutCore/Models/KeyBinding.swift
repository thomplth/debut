import Carbon.HIToolbox

public enum KeyAction: String, Codable, Sendable, CaseIterable {
    // Global Stage Manager activation
    case activateNextWindow
    case activatePreviousWindow
    case activateNextStage
    case activatePreviousStage
    case activatePreviousStageAlternate

    // Global stage switching
    case quickSwitchStage1, quickSwitchStage2, quickSwitchStage3
    case quickSwitchStage4, quickSwitchStage5, quickSwitchStage6
    case quickSwitchStage7, quickSwitchStage8, quickSwitchStage9

    // Global same-app window cycling
    case nextAppWindow
    case previousAppWindow

    // Stage Manager session
    case nextWindow
    case previousWindow
    case previousWindowAlternate
    case nextStage
    case previousStage
    case jumpToStage1, jumpToStage2, jumpToStage3
    case jumpToStage4, jumpToStage5, jumpToStage6
    case jumpToStage7, jumpToStage8, jumpToStage9
    case newStageBelow
    case newStageAbove
    case deleteStage
    case deleteStageForward
    case moveWindowUp
    case moveWindowDown
    case swapStageUp
    case swapStageDown
    case dismissOverlay

    public var displayName: String {
        switch self {
        case .activateNextWindow: "Open / cycle windows"
        case .activatePreviousWindow: "Open / cycle windows backward"
        case .activateNextStage: "Open / cycle stages"
        case .activatePreviousStage: "Open / cycle stages backward"
        case .activatePreviousStageAlternate: "Open / cycle stages backward (alternate)"
        case .quickSwitchStage1: "Quick switch to stage 1"
        case .quickSwitchStage2: "Quick switch to stage 2"
        case .quickSwitchStage3: "Quick switch to stage 3"
        case .quickSwitchStage4: "Quick switch to stage 4"
        case .quickSwitchStage5: "Quick switch to stage 5"
        case .quickSwitchStage6: "Quick switch to stage 6"
        case .quickSwitchStage7: "Quick switch to stage 7"
        case .quickSwitchStage8: "Quick switch to stage 8"
        case .quickSwitchStage9: "Quick switch to stage 9"
        case .nextAppWindow: "Next window in current app"
        case .previousAppWindow: "Previous window in current app"
        case .nextWindow: "Next window"
        case .previousWindow: "Previous window"
        case .previousWindowAlternate: "Previous window (alternate)"
        case .nextStage: "Next stage"
        case .previousStage: "Previous stage"
        case .jumpToStage1: "Jump to stage 1"
        case .jumpToStage2: "Jump to stage 2"
        case .jumpToStage3: "Jump to stage 3"
        case .jumpToStage4: "Jump to stage 4"
        case .jumpToStage5: "Jump to stage 5"
        case .jumpToStage6: "Jump to stage 6"
        case .jumpToStage7: "Jump to stage 7"
        case .jumpToStage8: "Jump to stage 8"
        case .jumpToStage9: "Jump to last stage"
        case .newStageBelow: "New stage below"
        case .newStageAbove: "New stage above"
        case .deleteStage: "Delete stage"
        case .deleteStageForward: "Delete stage (forward delete)"
        case .moveWindowUp: "Move window up"
        case .moveWindowDown: "Move window down"
        case .swapStageUp: "Swap stage up"
        case .swapStageDown: "Swap stage down"
        case .dismissOverlay: "Close overlay"
        }
    }

    public func toKeyEvent() -> DebutKeyEvent {
        switch self {
        case .activateNextWindow: .cmdTabHold
        case .activatePreviousWindow: .cmdShiftTabHold
        case .activateNextStage: .cmdOptionTabHold
        case .activatePreviousStage: .cmdOptionShiftTabHold
        case .activatePreviousStageAlternate: .cmdOptionShiftTabHold
        case .quickSwitchStage1: .switchToStage(1)
        case .quickSwitchStage2: .switchToStage(2)
        case .quickSwitchStage3: .switchToStage(3)
        case .quickSwitchStage4: .switchToStage(4)
        case .quickSwitchStage5: .switchToStage(5)
        case .quickSwitchStage6: .switchToStage(6)
        case .quickSwitchStage7: .switchToStage(7)
        case .quickSwitchStage8: .switchToStage(8)
        case .quickSwitchStage9: .switchToStage(9)
        case .nextAppWindow: .cmdBacktick
        case .previousAppWindow: .cmdShiftBacktick
        case .nextWindow: .nextWindow
        case .previousWindow: .previousWindow
        case .previousWindowAlternate: .previousWindow
        case .nextStage: .nextStage
        case .previousStage: .previousStage
        case .jumpToStage1: .jumpToStage(1)
        case .jumpToStage2: .jumpToStage(2)
        case .jumpToStage3: .jumpToStage(3)
        case .jumpToStage4: .jumpToStage(4)
        case .jumpToStage5: .jumpToStage(5)
        case .jumpToStage6: .jumpToStage(6)
        case .jumpToStage7: .jumpToStage(7)
        case .jumpToStage8: .jumpToStage(8)
        case .jumpToStage9: .jumpToLastStage
        case .newStageBelow: .newStageBelow
        case .newStageAbove: .newStageAbove
        case .deleteStage: .deleteStage
        case .deleteStageForward: .deleteStage
        case .moveWindowUp: .moveWindowUp
        case .moveWindowDown: .moveWindowDown
        case .swapStageUp: .swapStageUp
        case .swapStageDown: .swapStageDown
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
        default: toKeyEvent()
        }
    }

    public var shortcutScope: ShortcutScope {
        switch self {
        case .activateNextWindow, .activatePreviousWindow,
             .activateNextStage, .activatePreviousStage, .activatePreviousStageAlternate,
             .quickSwitchStage1, .quickSwitchStage2, .quickSwitchStage3,
             .quickSwitchStage4, .quickSwitchStage5, .quickSwitchStage6,
             .quickSwitchStage7, .quickSwitchStage8, .quickSwitchStage9,
             .nextAppWindow, .previousAppWindow:
            .global
        default:
            .session
        }
    }

    public var isOverlayActivation: Bool {
        switch self {
        case .activateNextWindow, .activatePreviousWindow,
             .activateNextStage, .activatePreviousStage, .activatePreviousStageAlternate:
            true
        default:
            false
        }
    }

    public var quickSwitchPosition: Int? {
        switch self {
        case .quickSwitchStage1: 1
        case .quickSwitchStage2: 2
        case .quickSwitchStage3: 3
        case .quickSwitchStage4: 4
        case .quickSwitchStage5: 5
        case .quickSwitchStage6: 6
        case .quickSwitchStage7: 7
        case .quickSwitchStage8: 8
        case .quickSwitchStage9: 9
        default: nil
        }
    }

    public var isSameAppCycle: Bool {
        self == .nextAppWindow || self == .previousAppWindow
    }

    /// Actions that step a selection one place along a list. Only these are paced while held:
    /// swallowing repeats of something like "delete stage" would drop keystrokes the user meant.
    public var isCycling: Bool {
        switch self {
        case .activateNextWindow, .activatePreviousWindow,
             .activateNextStage, .activatePreviousStage, .activatePreviousStageAlternate,
             .nextAppWindow, .previousAppWindow,
             .nextWindow, .previousWindow, .previousWindowAlternate,
             .nextStage, .previousStage:
            true
        default:
            false
        }
    }

    public static let activationActions: [KeyAction] = [
        .activateNextWindow, .activatePreviousWindow,
        .activateNextStage, .activatePreviousStage, .activatePreviousStageAlternate,
    ]

    public static let quickSwitchActions: [KeyAction] = [
        .quickSwitchStage1, .quickSwitchStage2, .quickSwitchStage3,
        .quickSwitchStage4, .quickSwitchStage5, .quickSwitchStage6,
        .quickSwitchStage7, .quickSwitchStage8, .quickSwitchStage9,
    ]

    public static let sameAppActions: [KeyAction] = [
        .nextAppWindow, .previousAppWindow,
    ]

    public static let globalActions = activationActions + quickSwitchActions + sameAppActions
    public static let sessionActions = allCases.filter { $0.shortcutScope == .session }

    public static func jumpAction(forStageIndex index: Int) -> KeyAction? {
        switch index {
        case 0: .jumpToStage1
        case 1: .jumpToStage2
        case 2: .jumpToStage3
        case 3: .jumpToStage4
        case 4: .jumpToStage5
        case 5: .jumpToStage6
        case 6: .jumpToStage7
        case 7: .jumpToStage8
        case 8: .jumpToStage9
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
            .activateNextStage: KeyCombo(keyCode: kVK_Tab, command: true, option: true),
            .activatePreviousStage: KeyCombo(
                keyCode: kVK_Tab,
                command: true,
                shift: true,
                option: true
            ),
            .activatePreviousStageAlternate: KeyCombo(
                keyCode: kVK_ANSI_Grave,
                command: true,
                option: true
            ),
            .quickSwitchStage1: KeyCombo(keyCode: kVK_ANSI_1, control: true),
            .quickSwitchStage2: KeyCombo(keyCode: kVK_ANSI_2, control: true),
            .quickSwitchStage3: KeyCombo(keyCode: kVK_ANSI_3, control: true),
            .quickSwitchStage4: KeyCombo(keyCode: kVK_ANSI_4, control: true),
            .quickSwitchStage5: KeyCombo(keyCode: kVK_ANSI_5, control: true),
            .quickSwitchStage6: KeyCombo(keyCode: kVK_ANSI_6, control: true),
            .quickSwitchStage7: KeyCombo(keyCode: kVK_ANSI_7, control: true),
            .quickSwitchStage8: KeyCombo(keyCode: kVK_ANSI_8, control: true),
            .quickSwitchStage9: KeyCombo(keyCode: kVK_ANSI_9, control: true),
            .nextAppWindow: KeyCombo(keyCode: kVK_ANSI_Grave, command: true),
            .previousAppWindow: KeyCombo(
                keyCode: kVK_ANSI_Grave,
                command: true,
                shift: true
            ),
            .nextWindow: KeyCombo(keyCode: kVK_Tab),
            .previousWindow: KeyCombo(keyCode: kVK_Tab, shift: true),
            .previousWindowAlternate: KeyCombo(keyCode: kVK_ANSI_Grave),
            .nextStage: KeyCombo(keyCode: kVK_Tab, option: true),
            .previousStage: KeyCombo(keyCode: kVK_Tab, shift: true, option: true),
            .jumpToStage1: KeyCombo(keyCode: kVK_ANSI_1),
            .jumpToStage2: KeyCombo(keyCode: kVK_ANSI_2),
            .jumpToStage3: KeyCombo(keyCode: kVK_ANSI_3),
            .jumpToStage4: KeyCombo(keyCode: kVK_ANSI_4),
            .jumpToStage5: KeyCombo(keyCode: kVK_ANSI_5),
            .jumpToStage6: KeyCombo(keyCode: kVK_ANSI_6),
            .jumpToStage7: KeyCombo(keyCode: kVK_ANSI_7),
            .jumpToStage8: KeyCombo(keyCode: kVK_ANSI_8),
            .jumpToStage9: KeyCombo(keyCode: kVK_ANSI_9),
            .newStageBelow: KeyCombo(keyCode: kVK_ANSI_N),
            .newStageAbove: KeyCombo(keyCode: kVK_ANSI_N, shift: true),
            .deleteStage: KeyCombo(keyCode: kVK_Delete),
            .deleteStageForward: KeyCombo(keyCode: kVK_ForwardDelete),
            .moveWindowUp: KeyCombo(keyCode: kVK_UpArrow),
            .moveWindowDown: KeyCombo(keyCode: kVK_DownArrow),
            .swapStageUp: KeyCombo(keyCode: kVK_UpArrow, option: true),
            .swapStageDown: KeyCombo(keyCode: kVK_DownArrow, option: true),
            .dismissOverlay: KeyCombo(keyCode: kVK_Escape),
        ]
    }
}

public struct KeyBindings: Codable, Sendable, Equatable {
    public var bindings: [KeyAction: KeyCombo]

    public init() {
        self.bindings = KeyCombo.defaults()
    }

    private enum CodingKeys: String, CodingKey {
        case bindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decodeIfPresent(
            DecodedKeyActionDictionary<KeyCombo>.self,
            forKey: .bindings
        )?.values ?? [:]
        bindings = KeyCombo.defaults().merging(saved) { _, savedCombo in savedCombo }
    }

    public func action(for combo: KeyCombo) -> KeyAction? {
        bindings.first(where: { $0.value == combo })?.key
    }

    public func action(for combo: KeyCombo, scope: ShortcutScope) -> KeyAction? {
        KeyAction.allCases.first { action in
            action.shortcutScope == scope && bindings[action] == combo
        }
    }

    public func combo(for action: KeyAction) -> KeyCombo? {
        bindings[action]
    }

    public mutating func restoreDefaults() {
        bindings = KeyCombo.defaults()
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
