import CoreGraphics

/// One key of the cropped onboarding keyboard. Key codes are positional, so a
/// press lights the key in the same physical place whatever the input source.
public struct OnboardingKey: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let label: String
    public let symbol: String?
    /// Width in standard key units.
    public let width: CGFloat

    init(_ keyCode: CGKeyCode, _ label: String, symbol: String? = nil, width: CGFloat = 1) {
        self.keyCode = keyCode
        self.label = label
        self.symbol = symbol
        self.width = width
    }
}

public enum OnboardingKeyboard {
    public static let tab: CGKeyCode = 48
    public static let leftCommand: CGKeyCode = 55
    public static let leftOption: CGKeyCode = 58

    /// The left half of a Mac keyboard, top row first. Rows run past the crop so
    /// the diagram can fade them out at its right edge.
    public static let leftHalf: [[OnboardingKey]] = [
        [.init(50, "`", symbol: "~"), .init(18, "1", symbol: "!"), .init(19, "2", symbol: "@"),
         .init(20, "3", symbol: "#"), .init(21, "4", symbol: "$"), .init(23, "5", symbol: "%"),
         .init(22, "6", symbol: "^")],
        [.init(tab, "tab", symbol: "⇥", width: 1.5), .init(12, "Q"), .init(13, "W"), .init(14, "E"),
         .init(15, "R"), .init(17, "T"), .init(16, "Y")],
        [.init(57, "caps lock", symbol: "⇪", width: 1.8), .init(0, "A"), .init(1, "S"), .init(2, "D"),
         .init(3, "F"), .init(5, "G"), .init(4, "H")],
        [.init(56, "shift", symbol: "⇧", width: 2.3), .init(6, "Z"), .init(7, "X"), .init(8, "C"),
         .init(9, "V"), .init(11, "B")],
        [.init(63, "fn"), .init(59, "control", symbol: "⌃"), .init(leftOption, "option", symbol: "⌥"),
         .init(leftCommand, "command", symbol: "⌘", width: 1.25), .init(49, "", width: 5)],
    ]

    /// Device-dependent modifier bits from IOLLEvent.h, which tell left from right.
    static let modifierMasks: [CGKeyCode: UInt64] = [
        59: 0x0001, 56: 0x0002, 60: 0x0004, 55: 0x0008,
        54: 0x0010, 58: 0x0020, 61: 0x0040, 62: 0x2000,
    ]
}

public enum OnboardingKeyInput: Sendable {
    case keyDown(keyCode: CGKeyCode)
    case keyUp(keyCode: CGKeyCode)
    case flagsChanged(keyCode: CGKeyCode, flags: CGEventFlags, deviceFlags: UInt64)
    /// Forget held keys when their key up can no longer be observed.
    case reset
}

public struct OnboardingKeyPresses: Equatable, Sendable {
    public private(set) var pressed: Set<CGKeyCode> = []

    public init() {}

    public mutating func apply(_ input: OnboardingKeyInput) {
        switch input {
        case let .keyDown(keyCode): pressed.insert(keyCode)
        case let .keyUp(keyCode): pressed.remove(keyCode)
        case .reset: pressed.removeAll()
        case let .flagsChanged(keyCode, flags, deviceFlags):
            let down: Bool
            if let mask = OnboardingKeyboard.modifierMasks[keyCode] {
                down = deviceFlags & mask != 0
            } else if keyCode == 57 {
                // Caps Lock reports only its toggle, so it stays lit while locked.
                down = flags.contains(.maskAlphaShift)
            } else if keyCode == 63 {
                down = flags.contains(.maskSecondaryFn)
            } else {
                return
            }
            if down { pressed.insert(keyCode) } else { pressed.remove(keyCode) }
        }
    }
}
