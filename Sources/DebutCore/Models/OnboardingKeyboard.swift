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
         .init(22, "6", symbol: "^"), .init(26, "7"), .init(28, "8"), .init(25, "9")],
        [.init(tab, "tab", symbol: "⇥", width: 1.5), .init(12, "Q"), .init(13, "W"), .init(14, "E"),
         .init(15, "R"), .init(17, "T"), .init(16, "Y"), .init(32, "U"), .init(34, "I")],
        [.init(57, "caps lock", symbol: "⇪", width: 1.8), .init(0, "A"), .init(1, "S"), .init(2, "D"),
         .init(3, "F"), .init(5, "G"), .init(4, "H"), .init(38, "J"), .init(40, "K")],
        [.init(56, "shift", symbol: "⇧", width: 2.3), .init(6, "Z"), .init(7, "X"), .init(8, "C"),
         .init(9, "V"), .init(11, "B"), .init(45, "N"), .init(46, "M"), .init(43, ",")],
        [.init(63, "fn"), .init(59, "control", symbol: "⌃"), .init(leftOption, "option", symbol: "⌥"),
         .init(leftCommand, "command", symbol: "⌘", width: 1.25), .init(49, "", width: 6)],
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

extension OnboardingKeyboard {
    /// The right edge, in key units from the row start, of the furthest of these keys.
    public static func rightEdge(of keyCodes: Set<CGKeyCode>) -> CGFloat {
        leftHalf.reduce(0) { edge, row in
            var x: CGFloat = 0
            var rowEdge: CGFloat = 0
            for key in row {
                x += key.width
                if keyCodes.contains(key.keyCode) { rowEdge = x }
            }
            return max(edge, rowEdge)
        }
    }
}

/// Splits a switcher page's gallery between the keyboard and the demo's visible
/// plate with one margin repeated three times: before the keyboard, between the
/// keyboard's dissolved edge and the plate, and after the plate. The margin and
/// key size never change, so the keyboard keeps its anchor; the keyboard's crop
/// absorbs the difference, never shorter than the highlighted shortcut.
public struct OnboardingDemoLayout: Equatable, Sendable {
    public static let margin: CGFloat = 32
    /// Width of the progressive blur at the keyboard's cropped edge.
    public static let fadeUnits: CGFloat = 1.8
    /// Longest crop; every row runs past it so the fade never reveals a row's end.
    public static let maximumUnits: CGFloat = 8.5
    /// Kept sharp on every page, highlighted or not, so the modifier row reads whole.
    public static let sharpKeys: Set<CGKeyCode> = [OnboardingKeyboard.leftCommand]

    public let keyboardMinX: CGFloat
    public let keyboardWidth: CGFloat
    /// Where the demo's opaque plate lands, excluding its transparent shadow margin.
    public let plate: CGRect

    public init(width: CGFloat, height: CGFloat, plateAspect: CGFloat, unit: CGFloat, highlighted: Set<CGKeyCode>) {
        let margin = Self.margin
        let available = max(0, width - 3 * margin)
        let minimumKeyboard = (OnboardingKeyboard.rightEdge(of: highlighted.union(Self.sharpKeys)) + Self.fadeUnits) * unit
        let aspect = max(plateAspect, 0.01)
        let plateWidth = max(0, min((height - 2 * margin) * aspect, available - minimumKeyboard))
        keyboardMinX = margin
        // A short window can leave more room than the rows fill; the right margin takes it.
        keyboardWidth = min(Self.maximumUnits * unit, available - plateWidth)
        let plateHeight = plateWidth / aspect
        plate = CGRect(x: 2 * margin + keyboardWidth, y: (height - plateHeight) / 2,
                       width: plateWidth, height: plateHeight)
    }
}
