import Foundation

public struct LabModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = LabModifiers(rawValue: 1 << 0)
    public static let control = LabModifiers(rawValue: 1 << 1)
    public static let option = LabModifiers(rawValue: 1 << 2)
    public static let shift = LabModifiers(rawValue: 1 << 3)
}

public struct LabSettings: Codable, Equatable, Sendable {
    public var selectedPreset: GesturePreset
    public var recipe: GestureRecipe
    public var requiredModifiers: LabModifiers

    public init(
        selectedPreset: GesturePreset,
        recipe: GestureRecipe,
        requiredModifiers: LabModifiers
    ) {
        self.selectedPreset = selectedPreset
        self.recipe = recipe
        self.requiredModifiers = requiredModifiers
    }

    public static let defaults = LabSettings(
        selectedPreset: .debutInstant,
        recipe: .preset(.debutInstant),
        requiredModifiers: .control
    )
}

public enum HotkeyMapping {
    private static let numberKeyCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    public static func desktopIndex(
        keyCode: Int64,
        modifiers: LabModifiers,
        requiredModifiers: LabModifiers
    ) -> Int? {
        guard modifiers == requiredModifiers else { return nil }
        return numberKeyCodes.firstIndex(of: keyCode)
    }
}
