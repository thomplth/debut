import Foundation

public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    case clear = "Clear"
    case regular = "Regular"
}

public enum CommandHintVisibility: String, Codable, Sendable, CaseIterable {
    case automatic = "Automatic"
    case never = "Never"
    case always = "Always"
}

public enum PreviewRefreshPolicy: String, Codable, Sendable, CaseIterable {
    case lastActiveOnly
    case all

    public var displayName: String {
        switch self {
        case .lastActiveOnly: "Only windows that may have changed"
        case .all: "Every window, every time"
        }
    }
}

public struct ShortcutModifiers: Codable, Sendable, Equatable, Hashable {
    public var command: Bool
    public var control: Bool
    public var shift: Bool
    public var option: Bool

    public init(
        command: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        option: Bool = false
    ) {
        self.command = command
        self.control = control
        self.shift = shift
        self.option = option
    }

    public static let control = ShortcutModifiers(control: true)

    public static let choices: [ShortcutModifiers] = (1..<16).map { bits in
        ShortcutModifiers(
            command: bits & 1 != 0,
            control: bits & 2 != 0,
            shift: bits & 4 != 0,
            option: bits & 8 != 0
        )
    }

    public var displayString: String {
        var names: [String] = []
        if command { names.append("Command") }
        if control { names.append("Control") }
        if shift { names.append("Shift") }
        if option { names.append("Option") }
        return names.joined(separator: "+")
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    /// Sits on the hold-delay slider's 25ms step grid, so the first drag does not shift it.
    public static let defaultOverlayPresentationDelay: TimeInterval = 0.075
    public static let defaultPreviewCacheTTL: TimeInterval = 60
    /// Paces held cycling independently of the user's key-repeat rate.
    public static let defaultHeldCycleMinimumInterval: TimeInterval = 0.06

    /// How long one desktop's worth of slide takes when switching spaces.
    ///
    /// This replaced a velocity scalar, which was not a duration and did not behave like
    /// one: the Dock ignores progress and skips the transition outright above roughly 80,
    /// and the old slider's whole 100–1000 range sat above that, so every value on it
    /// looked identical and instant. Debut now drives the swipe's progress itself on a
    /// timer, which is what makes a number in milliseconds honest.
    public static let defaultSpaceSwitchDuration: TimeInterval = 0.15
    /// Zero is a real setting, not a degenerate one: it posts the original high-velocity
    /// flick and the Dock cuts straight to the target desktop with no transition.
    public static let minimumSpaceSwitchDuration: TimeInterval = 0
    public static let maximumSpaceSwitchDuration: TimeInterval = 0.4

    public var launchAtLogin: Bool
    public var excludedBundleIDs: [String]
    public var shareAnonymousTelemetry: Bool

    // Appearance
    /// Window thumbnails at the original size were too small to read what was on the captured
    /// screen. The wrapping added in KHA-491 is what makes a larger card safe: a space that no
    /// longer fits across the display spills onto another row instead of over the edge.
    public static let defaultStageScale: Double = 1.5
    /// The floor doubles as the floor the automatic viewport fit may shrink to, so a space
    /// holding more windows than the display can show at any readable size still fits.
    public static let minimumStageScale: Double = 0.5
    public static let maximumStageScale: Double = 2.5
    public static let stageScaleStep: Double = 0.05

    public var glassStyle: GlassStyle
    public var stageCornerRadius: Double
    public var inactiveStageScale: Double
    public var stageScale: Double

    // Keyboard
    public var overlayPresentationDelay: TimeInterval
    public var heldCycleMinimumInterval: TimeInterval
    public var keyBindings: KeyBindings
    public var quickSwitchExcludedBundleIDs: [String]
    public var quickSwitchModifiers: ShortcutModifiers
    public var quickSwitchSameApplicationModifiers: ShortcutModifiers

    // Space switching
    public var spaceSwitchDuration: TimeInterval

    // Window previews
    public var previewRefreshPolicy: PreviewRefreshPolicy
    public var previewCacheTTL: TimeInterval

    // Command hints
    public var commandHintVisibility: CommandHintVisibility
    public var commandUsageCounts: [KeyAction: Int]

    public init() {
        self.launchAtLogin = true
        self.excludedBundleIDs = []
        self.shareAnonymousTelemetry = true

        self.glassStyle = .clear
        self.stageCornerRadius = 40
        self.inactiveStageScale = 0.7
        self.stageScale = Self.defaultStageScale

        self.overlayPresentationDelay = Self.defaultOverlayPresentationDelay
        self.heldCycleMinimumInterval = Self.defaultHeldCycleMinimumInterval
        self.keyBindings = KeyBindings()
        self.quickSwitchExcludedBundleIDs = []
        self.quickSwitchModifiers = .control
        self.quickSwitchSameApplicationModifiers = ShortcutModifiers(
            control: true,
            option: true
        )
        self.spaceSwitchDuration = Self.defaultSpaceSwitchDuration
        self.previewRefreshPolicy = .lastActiveOnly
        self.previewCacheTTL = Self.defaultPreviewCacheTTL
        self.commandHintVisibility = .automatic
        self.commandUsageCounts = [:]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        excludedBundleIDs = try container.decode([String].self, forKey: .excludedBundleIDs)
        shareAnonymousTelemetry = try container.decodeIfPresent(
            Bool.self,
            forKey: .shareAnonymousTelemetry
        ) ?? true
        glassStyle = try container.decode(GlassStyle.self, forKey: .glassStyle)
        stageCornerRadius = try container.decode(Double.self, forKey: .stageCornerRadius)
        inactiveStageScale = try container.decode(Double.self, forKey: .inactiveStageScale)
        stageScale = try container.decodeIfPresent(
            Double.self,
            forKey: .stageScale
        ) ?? Self.defaultStageScale
        overlayPresentationDelay = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .overlayPresentationDelay
        ) ?? Self.defaultOverlayPresentationDelay
        heldCycleMinimumInterval = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .heldCycleMinimumInterval
        ) ?? Self.defaultHeldCycleMinimumInterval
        spaceSwitchDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .spaceSwitchDuration
        ) ?? Self.defaultSpaceSwitchDuration
        keyBindings = try container.decodeIfPresent(KeyBindings.self, forKey: .keyBindings) ?? KeyBindings()
        quickSwitchExcludedBundleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .quickSwitchExcludedBundleIDs
        ) ?? []
        quickSwitchModifiers = try container.decodeIfPresent(
            ShortcutModifiers.self,
            forKey: .quickSwitchModifiers
        ) ?? .control
        quickSwitchSameApplicationModifiers = try container.decodeIfPresent(
            ShortcutModifiers.self,
            forKey: .quickSwitchSameApplicationModifiers
        ) ?? ShortcutModifiers(control: true, option: true)
        previewRefreshPolicy = try container.decodeIfPresent(
            PreviewRefreshPolicy.self,
            forKey: .previewRefreshPolicy
        ) ?? .lastActiveOnly
        previewCacheTTL = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .previewCacheTTL
        ) ?? Self.defaultPreviewCacheTTL
        commandHintVisibility = try container.decodeIfPresent(
            CommandHintVisibility.self,
            forKey: .commandHintVisibility
        ) ?? .automatic
        commandUsageCounts = try container.decodeIfPresent(
            DecodedKeyActionDictionary<Int>.self,
            forKey: .commandUsageCounts
        )?.values ?? [:]
    }

    public func isExcluded(bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    public func isQuickSwitchExcluded(bundleID: String) -> Bool {
        quickSwitchExcludedBundleIDs.contains(bundleID)
    }

    /// Each command is counted on its own, so a shortcut the user never reaches for keeps its
    /// hint even after its neighbour in the same footer group has retired.
    public static let commandHintRetirementUses = 3

    public func shouldShowCommandHint(for action: KeyAction) -> Bool {
        guard !action.isTransitive else { return false }
        switch commandHintVisibility {
        case .automatic:
            return (commandUsageCounts[action] ?? 0) < Self.commandHintRetirementUses
        case .never:
            return false
        case .always:
            return true
        }
    }

    /// Records only the uses needed by automatic mode. Returns whether state changed.
    @discardableResult
    public mutating func recordCommandUsage(_ action: KeyAction) -> Bool {
        guard !action.isTransitive else { return false }
        let currentCount = commandUsageCounts[action] ?? 0
        guard currentCount < Self.commandHintRetirementUses else { return false }
        commandUsageCounts[action] = currentCount + 1
        return true
    }

    public mutating func resetCommandHintUsage() {
        commandUsageCounts.removeAll()
    }
}
