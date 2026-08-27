import CoreGraphics

public struct SyntheticKeyEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case key(CGKeyCode, down: Bool)
        case flagsChanged
    }

    public let kind: Kind
    public let flags: CGEventFlags

    public init(kind: Kind, flags: CGEventFlags) {
        self.kind = kind
        self.flags = flags
    }
}

public enum StageCycleKey {
    public static let tab: CGKeyCode = 48
}

/// Builds the space-cycling gesture: Command and Option stay asserted while Tab is
/// tapped, because releasing Command commits the selection and dropping Option turns
/// each Tab into window cycling instead of space cycling.
///
/// Modifiers are emitted as flag changes. Posting their virtual key codes as key
/// events leaves the session's modifier state untouched, which is why the shipped
/// fixture's input reached the app carrying no modifiers at all.
public enum StageCycleSequence {
    public static func events(forward: Int, backward: Int) -> [SyntheticKeyEvent] {
        let held: CGEventFlags = [.maskCommand, .maskAlternate]
        var events: [SyntheticKeyEvent] = [
            SyntheticKeyEvent(kind: .flagsChanged, flags: .maskCommand),
            SyntheticKeyEvent(kind: .flagsChanged, flags: held),
        ]

        for _ in 0..<max(0, forward) {
            events.append(contentsOf: tabTap(flags: held))
        }

        if backward > 0 {
            let shifted: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
            events.append(SyntheticKeyEvent(kind: .flagsChanged, flags: shifted))
            for _ in 0..<backward {
                events.append(contentsOf: tabTap(flags: shifted))
            }
            events.append(SyntheticKeyEvent(kind: .flagsChanged, flags: held))
        }

        events.append(SyntheticKeyEvent(kind: .flagsChanged, flags: .maskCommand))
        events.append(SyntheticKeyEvent(kind: .flagsChanged, flags: []))
        return events
    }

    private static func tabTap(flags: CGEventFlags) -> [SyntheticKeyEvent] {
        [
            SyntheticKeyEvent(kind: .key(StageCycleKey.tab, down: true), flags: flags),
            SyntheticKeyEvent(kind: .key(StageCycleKey.tab, down: false), flags: flags),
        ]
    }
}
