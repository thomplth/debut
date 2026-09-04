import Foundation

public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    case clear = "Clear"
    case regular = "Regular"
}

public enum WindowSelectionStyle: String, Codable, Sendable, CaseIterable {
    case filled = "Filled"
    case magnify = "Magnify"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "Filled", "Outline": self = .filled
        case "Magnify": self = .magnify
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown window selection style"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
    /// Off makes Debut an agent again — no Dock icon and no menu bar, reachable only from its
    /// status item. Its own Settings window then leaves the space manager with it, because
    /// every discovery path admits regular applications only.
    public var showsDockIcon: Bool
    public var excludedBundleIDs: [String]
    public var shareAnonymousTelemetry: Bool

    // Appearance
    /// Keep the original overlay dimensions as the default; users can enlarge the complete,
    /// proportionally scaled presentation with the appearance setting when they need it.
    public static let defaultStageScale: Double = 1.0
    /// The floor doubles as the floor the automatic viewport fit may shrink to, so a space
    /// holding more windows than the display can show at any readable size still fits.
    public static let minimumStageScale: Double = 0.5
    public static let maximumStageScale: Double = 2.5
    public static let stageScaleStep: Double = 0.05

    public static let defaultSelectorOutset: Double = 6
    public static let minimumSelectorOutset: Double = 2
    /// The fill stays inside the card's reserved preview outset, clear of the title.
    public static let maximumSelectorOutset: Double = 6
    public static let defaultSelectorCornerRadius: Double = 12
    public static let minimumSelectorCornerRadius: Double = 0
    public static let maximumSelectorCornerRadius: Double = 24
    public static let defaultMagnifyScale: Double = 1.06
    public static let minimumMagnifyScale: Double = 1
    public static let maximumMagnifyScale: Double = 1.2
    public static let magnifyScaleStep: Double = 0.01
    public static let defaultMagnifyShadowStrength: Double = 1
    public static let minimumMagnifyShadowStrength: Double = 0
    public static let maximumMagnifyShadowStrength: Double = 2

    public var glassStyle: GlassStyle
    public var stageCornerRadius: Double
    public var inactiveStageScale: Double
    public var stageScale: Double
    /// Whether each card takes its own window's shape rather than the display's.
    public var adaptiveCardSizing: Bool

    // Window selection
    public var windowSelectionStyle: WindowSelectionStyle
    public var selectorOutset: Double
    public var selectorCornerRadius: Double
    public var magnifyScale: Double
    public var magnifyShadowStrength: Double

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

    public init() {
        self.launchAtLogin = true
        self.showsDockIcon = true
        self.excludedBundleIDs = []
        self.shareAnonymousTelemetry = true

        self.glassStyle = .clear
        self.stageCornerRadius = 40
        self.inactiveStageScale = 0.7
        self.stageScale = Self.defaultStageScale
        self.adaptiveCardSizing = true
        self.windowSelectionStyle = .filled
        self.selectorOutset = Self.defaultSelectorOutset
        self.selectorCornerRadius = Self.defaultSelectorCornerRadius
        self.magnifyScale = Self.defaultMagnifyScale
        self.magnifyShadowStrength = Self.defaultMagnifyShadowStrength

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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showsDockIcon = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsDockIcon
        ) ?? true
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
        adaptiveCardSizing = try container.decodeIfPresent(
            Bool.self,
            forKey: .adaptiveCardSizing
        ) ?? true
        windowSelectionStyle = try container.decodeIfPresent(
            WindowSelectionStyle.self,
            forKey: .windowSelectionStyle
        ) ?? .filled
        selectorOutset = try container.decodeIfPresent(
            Double.self,
            forKey: .selectorOutset
        ) ?? Self.defaultSelectorOutset
        selectorCornerRadius = try container.decodeIfPresent(
            Double.self,
            forKey: .selectorCornerRadius
        ) ?? Self.defaultSelectorCornerRadius
        magnifyScale = try container.decodeIfPresent(
            Double.self,
            forKey: .magnifyScale
        ) ?? Self.defaultMagnifyScale
        magnifyShadowStrength = try container.decodeIfPresent(
            Double.self,
            forKey: .magnifyShadowStrength
        ) ?? Self.defaultMagnifyShadowStrength
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
    }

    public func isQuickSwitchExcluded(bundleID: String) -> Bool {
        quickSwitchExcludedBundleIDs.contains(bundleID)
    }
}
