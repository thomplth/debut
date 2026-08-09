import Foundation
import Carbon.HIToolbox

public enum KeyAction: String, Codable, Sendable, CaseIterable {
    case nextWindow
    case previousWindow
    case nextStage
    case previousStage
    case jumpToStage1, jumpToStage2, jumpToStage3
    case jumpToStage4, jumpToStage5, jumpToStage6
    case jumpToStage7, jumpToStage8, jumpToStage9
    case newStageBelow
    case newStageAbove
    case deleteStage
    case saveAsTemplate
    case moveWindowUp
    case moveWindowDown
    case swapStageUp
    case swapStageDown

    public var displayName: String {
        switch self {
        case .nextWindow: "Next window"
        case .previousWindow: "Previous window"
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
        case .saveAsTemplate: "Save as template"
        case .moveWindowUp: "Move window up"
        case .moveWindowDown: "Move window down"
        case .swapStageUp: "Swap stage up"
        case .swapStageDown: "Swap stage down"
        }
    }

    public func toKeyEvent() -> DebutKeyEvent {
        switch self {
        case .nextWindow: .nextWindow
        case .previousWindow: .previousWindow
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
        case .saveAsTemplate: .saveAsTemplate
        case .moveWindowUp: .moveWindowUp
        case .moveWindowDown: .moveWindowDown
        case .swapStageUp: .swapStageUp
        case .swapStageDown: .swapStageDown
        }
    }

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

public struct KeyCombo: Codable, Sendable, Equatable, Hashable {
    public let keyCode: Int
    public let shift: Bool
    public let option: Bool

    public init(keyCode: Int, shift: Bool = false, option: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.option = option
    }

    public var displayString: String {
        var parts: [String] = []
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
            .nextWindow: KeyCombo(keyCode: kVK_Tab),
            .previousWindow: KeyCombo(keyCode: kVK_Tab, shift: true),
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
            .saveAsTemplate: KeyCombo(keyCode: kVK_Space),
            .moveWindowUp: KeyCombo(keyCode: kVK_UpArrow),
            .moveWindowDown: KeyCombo(keyCode: kVK_DownArrow),
            .swapStageUp: KeyCombo(keyCode: kVK_UpArrow, option: true),
            .swapStageDown: KeyCombo(keyCode: kVK_DownArrow, option: true),
        ]
    }
}

public struct KeyBindings: Codable, Sendable, Equatable {
    public var bindings: [KeyAction: KeyCombo]

    public init() {
        self.bindings = KeyCombo.defaults()
    }

    public func action(for combo: KeyCombo) -> KeyAction? {
        bindings.first(where: { $0.value == combo })?.key
    }

    public func combo(for action: KeyAction) -> KeyCombo? {
        bindings[action]
    }

    public mutating func restoreDefaults() {
        bindings = KeyCombo.defaults()
    }
}
