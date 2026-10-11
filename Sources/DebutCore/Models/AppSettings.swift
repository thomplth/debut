import Foundation

public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    /// Clear glass tuned to match the native Dock and Command-Tab switcher (DockGlass).
    case native = "Native"
    case clear = "Clear"
    case regular = "Regular"

    /// Whether surfaces draw through DockGlass rather than SwiftUI's glass directly.
    public var usesDockGlass: Bool { self == .native }
}

/// Where a preview card shows its app's icon. Magnify, the old alternative selection style,
/// was retired in KHA-1064; a saved choice of it is ignored and the highlight is used.
public enum BadgePlacement: String, Codable, Sendable, CaseIterable {
    /// Overhanging the preview's top-left corner.
    case corner = "Corner"
    /// Centred just inside the preview's lower edge, as Mission Control places icons.
    case bottom = "Bottom"
    /// A small icon before the title; the preview carries no badge.
    case titleRow = "Title"
    /// Centred on the preview's top edge.
    case top = "Top"
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
    public static let disabled = ShortcutModifiers()

    public static let choices: [ShortcutModifiers] = (0..<16).map { bits in
        ShortcutModifiers(
            command: bits & 1 != 0,
            control: bits & 2 != 0,
            shift: bits & 4 != 0,
            option: bits & 8 != 0
        )
    }

    public var displayString: String {
        if self == .disabled { return "Disabled" }
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
    public static let defaultOverlayPresentationDelay: TimeInterval = 0.1
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
    public static let defaultSpaceSwitchDuration: TimeInterval = 0
    /// Zero is a real setting, not a degenerate one: it posts the original high-velocity
    /// flick and the Dock cuts straight to the target desktop with no transition.
    public static let minimumSpaceSwitchDuration: TimeInterval = 0
    public static let maximumSpaceSwitchDuration: TimeInterval = 0.4

    public var features: FeatureSettings
    public var launchAtLogin: Bool
    /// Off makes Debut an agent again — no Dock icon and no menu bar, reachable only from its
    /// status item. Its own Settings window then leaves the space manager with it, because
    /// every discovery path admits regular applications only.
    public var showsDockIcon: Bool
    public var excludedBundleIDs: [String]
    /// Sends crash and hang reports without asking. Off until the user opts in.
    public var sendsCrashReportsAutomatically: Bool

    // Appearance
    /// Enlarge the complete presentation proportionally while retaining the original size as
    /// the lower end of the user-selectable range.
    public static let defaultStageScale: Double = 1.5
    public static let defaultIconScale: Double = 1
    /// The user-selectable range. Automatic viewport fitting has its own lower floor.
    public static let minimumStageScale: Double = 1.0
    public static let maximumStageScale: Double = 4
    public static let stageScaleStep: Double = 0.05
    public static let defaultPreviewCardSpacing: Double = 14
    public static let minimumPreviewCardSpacing: Double = 0
    public static let maximumPreviewCardSpacing: Double = 36

    /// Native's highlight padding around its icon.
    public static let defaultSelectorOutset: Double = 6
    public static let minimumSelectorOutset: Double = 2
    /// The fill stays inside the card's reserved preview outset, clear of the title.
    public static let maximumSelectorOutset: Double = 9
    /// The corner of every preview, selected or not. The highlight stays concentric with it.
    public static let defaultPreviewCornerRadius: Double = 6
    public static let minimumPreviewCornerRadius: Double = 0
    public static let maximumPreviewCornerRadius: Double = 24

    // Liquid Glass. Each strength scales DockGlass's fitted native look, so 1 is native.
    public static let minimumGlassRimStrength: Double = 0
    public static let maximumGlassRimStrength: Double = 2
    public static let minimumGlassEdgeRefraction: Double = 0
    public static let maximumGlassEdgeRefraction: Double = 2
    public static let minimumSelectionHighlightStrength: Double = 0
    public static let maximumSelectionHighlightStrength: Double = 2
    public static let minimumStageCornerRadius: Double = 0
    /// Room above the native switcher's 57.5-point plate corner.
    public static let maximumStageCornerRadius: Double = 72
    /// How the app badge grows with the preview: the preview's size raised to this power.
    /// 0 keeps it at native size, 1 grows it in proportion.
    public static let defaultBadgeGrowth: Double = 0.5
    public static let minimumBadgeGrowth: Double = 0
    public static let maximumBadgeGrowth: Double = 1
    /// The title halo's blur radius in points, and its strength (0 turns it off).
    public static let minimumTitleHaloSize: Double = 0.5
    public static let maximumTitleHaloSize: Double = 3
    /// The plate's continuous corner when previews show. Icon cards keep the native
    /// switcher's 57.5-point corner, so the two are stored apart behind one slider.
    public static let defaultStageCornerRadius: Double = 47.5
    public static let defaultIconStageCornerRadius: Double = 57.5
    public static let defaultTitleHaloSize: Double = 0.5
    public static let defaultBadgePlacement: BadgePlacement = .titleRow

    public var glassStyle: GlassStyle
    /// Opacity of the hairline rim along the native glass's outline, relative to native.
    public var glassRimStrength: Double
    /// How far the native glass bends its backdrop at the edges, relative to native.
    public var glassEdgeRefraction: Double
    /// Follow System Settings › Appearance › Liquid Glass tint, as the native switcher does.
    public var followsSystemGlassTint: Bool
    /// The tint used when not following the system, from 0 (clear) to 1 (tinted).
    public var glassTintAmount: Double
    /// How strongly the native selection highlight darkens or lightens the glass, relative to
    /// the native switcher.
    public var selectionHighlightStrength: Double
    /// The halo behind every title, from 0 (off) to 1 (two full-strength passes).
    public var titleHaloStrength: Double
    /// The halo's blur radius in points.
    public var titleHaloSize: Double
    /// The halo strength actually drawn: regular glass is opaque enough to keep titles
    /// legible, so it has no halo whatever the saved strength.
    public var effectiveTitleHaloStrength: Double {
        glassStyle == .regular ? 0 : titleHaloStrength
    }
    /// The plate corner when previews show.
    public var stageCornerRadius: Double
    /// The plate corner for icon cards, drawn without previews.
    public var iconStageCornerRadius: Double
    public var inactiveStageScale: Double
    public var stageScale: Double
    /// The same size, for the icon cards drawn without previews. 100% is the native switcher.
    public var iconScale: Double
    /// How the app badge grows with the preview; see `defaultBadgeGrowth`.
    public var badgeGrowth: Double
    /// Where each preview shows its app's icon.
    public var badgePlacement: BadgePlacement
    /// Space between preview card frames before the overlay's automatic scale is applied.
    /// The native gap between neighbouring highlights. No longer adjustable (KHA-1064); saved
    /// values are ignored.
    public var previewCardSpacing: Double { Self.defaultPreviewCardSpacing }
    /// Whether each card takes its own window's shape rather than the display's.
    public var adaptiveCardSizing: Bool
    /// Keep both overlay modes on the system primary display regardless of window focus.
    public var overlayOnMainDisplayOnly: Bool
    /// Show the confirmed desktop number briefly after macOS finishes moving between Spaces.
    public var showsDesktopSwitchIndicator: Bool

    // Window selection
    public var selectorOutset: Double
    /// The preview's corner on every card; the selection highlight is concentric with it.
    public var previewCornerRadius: Double

    // Keyboard
    public var overlayPresentationDelay: TimeInterval
    public var heldCycleMinimumInterval: TimeInterval
    public var keyBindings: KeyBindings
    public var quickSwitchModifiers: ShortcutModifiers
    public var quickSwitchSameApplicationModifiers: ShortcutModifiers

    // Space switching
    public var spaceSwitchDuration: TimeInterval

    // Window previews
    public var previewRefreshPolicy: PreviewRefreshPolicy
    public var previewCacheTTL: TimeInterval

    public init() {
        self.features = FeatureSettings()
        self.launchAtLogin = true
        self.showsDockIcon = true
        self.excludedBundleIDs = []
        self.sendsCrashReportsAutomatically = false

        self.glassStyle = .native
        self.glassRimStrength = 1
        self.glassEdgeRefraction = 1
        self.followsSystemGlassTint = true
        self.glassTintAmount = 0
        self.selectionHighlightStrength = 1
        self.titleHaloStrength = 1
        self.titleHaloSize = Self.defaultTitleHaloSize
        self.stageCornerRadius = Self.defaultStageCornerRadius
        self.iconStageCornerRadius = Self.defaultIconStageCornerRadius
        self.inactiveStageScale = 0.7
        self.stageScale = Self.defaultStageScale
        self.iconScale = Self.defaultIconScale
        self.badgeGrowth = Self.defaultBadgeGrowth
        self.badgePlacement = Self.defaultBadgePlacement
        self.adaptiveCardSizing = true
        self.overlayOnMainDisplayOnly = true
        self.showsDesktopSwitchIndicator = true
        self.selectorOutset = Self.defaultSelectorOutset
        self.previewCornerRadius = Self.defaultPreviewCornerRadius

        self.overlayPresentationDelay = Self.defaultOverlayPresentationDelay
        self.heldCycleMinimumInterval = Self.defaultHeldCycleMinimumInterval
        self.keyBindings = KeyBindings()
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
        features = try container.decodeIfPresent(FeatureSettings.self, forKey: .features) ?? FeatureSettings()
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showsDockIcon = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsDockIcon
        ) ?? true
        excludedBundleIDs = try container.decode([String].self, forKey: .excludedBundleIDs)
        sendsCrashReportsAutomatically = try container.decodeIfPresent(
            Bool.self,
            forKey: .sendsCrashReportsAutomatically
        ) ?? false
        glassStyle = try container.decode(GlassStyle.self, forKey: .glassStyle)
        glassRimStrength = min(Self.maximumGlassRimStrength, max(
            Self.minimumGlassRimStrength,
            try container.decodeIfPresent(Double.self, forKey: .glassRimStrength) ?? 1
        ))
        glassEdgeRefraction = min(Self.maximumGlassEdgeRefraction, max(
            Self.minimumGlassEdgeRefraction,
            try container.decodeIfPresent(Double.self, forKey: .glassEdgeRefraction) ?? 1
        ))
        followsSystemGlassTint = try container.decodeIfPresent(
            Bool.self,
            forKey: .followsSystemGlassTint
        ) ?? true
        glassTintAmount = min(1, max(
            0,
            try container.decodeIfPresent(Double.self, forKey: .glassTintAmount) ?? 0
        ))
        selectionHighlightStrength = min(Self.maximumSelectionHighlightStrength, max(
            Self.minimumSelectionHighlightStrength,
            try container.decodeIfPresent(Double.self, forKey: .selectionHighlightStrength) ?? 1
        ))
        stageCornerRadius = try container.decode(Double.self, forKey: .stageCornerRadius)
        iconStageCornerRadius = try container.decodeIfPresent(
            Double.self,
            forKey: .iconStageCornerRadius
        ) ?? Self.defaultIconStageCornerRadius
        inactiveStageScale = try container.decode(Double.self, forKey: .inactiveStageScale)
        let savedStageScale = try container.decodeIfPresent(
            Double.self,
            forKey: .stageScale
        ) ?? Self.defaultStageScale
        stageScale = min(Self.maximumStageScale, max(Self.minimumStageScale, savedStageScale))
        badgePlacement = (try? container.decodeIfPresent(
            BadgePlacement.self,
            forKey: .badgePlacement
        )) ?? Self.defaultBadgePlacement
        badgeGrowth = min(Self.maximumBadgeGrowth, max(
            Self.minimumBadgeGrowth,
            try container.decodeIfPresent(Double.self, forKey: .badgeGrowth) ?? Self.defaultBadgeGrowth
        ))
        titleHaloStrength = min(1, max(
            0,
            try container.decodeIfPresent(Double.self, forKey: .titleHaloStrength) ?? 1
        ))
        titleHaloSize = min(Self.maximumTitleHaloSize, max(
            Self.minimumTitleHaloSize,
            try container.decodeIfPresent(Double.self, forKey: .titleHaloSize) ?? Self.defaultTitleHaloSize
        ))
        iconScale = min(Self.maximumStageScale, max(
            Self.minimumStageScale,
            try container.decodeIfPresent(Double.self, forKey: .iconScale) ?? Self.defaultIconScale
        ))
        adaptiveCardSizing = try container.decodeIfPresent(
            Bool.self,
            forKey: .adaptiveCardSizing
        ) ?? true
        overlayOnMainDisplayOnly = try container.decodeIfPresent(
            Bool.self,
            forKey: .overlayOnMainDisplayOnly
        ) ?? true
        showsDesktopSwitchIndicator = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsDesktopSwitchIndicator
        ) ?? true
        selectorOutset = try container.decodeIfPresent(
            Double.self,
            forKey: .selectorOutset
        ) ?? Self.defaultSelectorOutset
        previewCornerRadius = min(Self.maximumPreviewCornerRadius, max(
            Self.minimumPreviewCornerRadius,
            try container.decodeIfPresent(Double.self, forKey: .previewCornerRadius)
                ?? Self.defaultPreviewCornerRadius
        ))
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
}

extension AppSettings {
    /// The size the switchers draw at for a card style: previews and icons are sized apart.
    public func overlayScale(for cardStyle: OverlayCardStyle) -> Double {
        cardStyle == .icons ? iconScale : stageScale
    }

    /// The plate corner the switchers draw for a card style.
    public func stageCornerRadius(for cardStyle: OverlayCardStyle) -> Double {
        cardStyle == .icons ? iconStageCornerRadius : stageCornerRadius
    }
}
