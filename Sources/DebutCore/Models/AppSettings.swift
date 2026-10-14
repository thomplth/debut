import DockGlass
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
    /// Sits on the hold-delay slider's step grid, so the first drag does not shift it.
    public static let defaultOverlayPresentationDelay: TimeInterval = 0.1
    public static let overlayPresentationDelayStep: TimeInterval = 0.005
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
    /// Room above the native switcher's 58-point plate corner.
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
    /// switcher's corner, so the two are stored apart behind one slider.
    public static let defaultStageCornerRadius: Double = 47.5
    public static let defaultIconStageCornerRadius = Double(DockGlass.Metrics.standard.plateCornerRadius)
    public static let defaultTitleHaloSize: Double = 0.5
    public static let defaultBadgePlacement: BadgePlacement = .titleRow

    /// What the switchers draw while previews show.
    public var previewAppearance: SwitcherAppearance
    /// What the switchers draw as icon cards, without previews. Stored and defaulted apart from
    /// the preview appearance, so tuning one mode never moves the other (KHA-1099).
    public var iconAppearance: SwitcherAppearance
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

        self.previewAppearance = .previewDefaults
        self.iconAppearance = .iconDefaults
        self.badgeGrowth = Self.defaultBadgeGrowth
        self.badgePlacement = Self.defaultBadgePlacement
        self.adaptiveCardSizing = true
        self.overlayOnMainDisplayOnly = true
        self.showsDesktopSwitchIndicator = true
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
        if container.contains(.previewAppearance) {
            previewAppearance = try SwitcherAppearance(
                from: container.superDecoder(forKey: .previewAppearance),
                defaults: .previewDefaults
            )
        } else {
            // Written before KHA-1099, when the shared values sat at the top level.
            previewAppearance = try SwitcherAppearance(from: decoder, defaults: .previewDefaults)
        }
        if container.contains(.iconAppearance) {
            iconAppearance = try SwitcherAppearance(
                from: container.superDecoder(forKey: .iconAppearance),
                defaults: .iconDefaults
            )
        } else {
            // Icons drew the shared values too, with only size and stage corner of their own.
            let legacy = try decoder.container(keyedBy: LegacyIconCodingKeys.self)
            var icons = previewAppearance
            icons.stageCornerRadius = try legacy.decodeIfPresent(
                Double.self,
                forKey: .iconStageCornerRadius
            ) ?? SwitcherAppearance.iconDefaults.stageCornerRadius
            icons.stageScale = SwitcherAppearance.clampedScale(
                try legacy.decodeIfPresent(Double.self, forKey: .iconScale)
                    ?? SwitcherAppearance.iconDefaults.stageScale
            )
            iconAppearance = icons
        }
        badgePlacement = (try? container.decodeIfPresent(
            BadgePlacement.self,
            forKey: .badgePlacement
        )) ?? Self.defaultBadgePlacement
        badgeGrowth = min(Self.maximumBadgeGrowth, max(
            Self.minimumBadgeGrowth,
            try container.decodeIfPresent(Double.self, forKey: .badgeGrowth) ?? Self.defaultBadgeGrowth
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
    /// The values the switchers draw for a card style.
    public func appearance(for cardStyle: OverlayCardStyle) -> SwitcherAppearance {
        cardStyle == .icons ? iconAppearance : previewAppearance
    }

    public mutating func setAppearance(_ appearance: SwitcherAppearance, for cardStyle: OverlayCardStyle) {
        switch cardStyle {
        case .previews: previewAppearance = appearance
        case .icons: iconAppearance = appearance
        }
    }

    /// The keys icon size and stage corner were saved under before KHA-1099.
    private enum LegacyIconCodingKeys: String, CodingKey {
        case iconScale
        case iconStageCornerRadius
    }
}

/// The values both switcher modes draw, each mode with its own copy and defaults: Liquid Glass,
/// title halo, stage size and corner, and the selection highlight.
public struct SwitcherAppearance: Encodable, Sendable, Equatable {
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
    /// The plate's continuous corner.
    public var stageCornerRadius: Double
    /// The preview's, or the icon's, size. 100% is the native switcher.
    public var stageScale: Double
    public var inactiveStageScale: Double
    /// Space the selection highlight leaves around the preview or icon.
    public var selectorOutset: Double

    public init(
        glassStyle: GlassStyle,
        glassRimStrength: Double,
        glassEdgeRefraction: Double,
        followsSystemGlassTint: Bool,
        glassTintAmount: Double,
        selectionHighlightStrength: Double,
        titleHaloStrength: Double,
        titleHaloSize: Double,
        stageCornerRadius: Double,
        stageScale: Double,
        inactiveStageScale: Double,
        selectorOutset: Double
    ) {
        self.glassStyle = glassStyle
        self.glassRimStrength = glassRimStrength
        self.glassEdgeRefraction = glassEdgeRefraction
        self.followsSystemGlassTint = followsSystemGlassTint
        self.glassTintAmount = glassTintAmount
        self.selectionHighlightStrength = selectionHighlightStrength
        self.titleHaloStrength = titleHaloStrength
        self.titleHaloSize = titleHaloSize
        self.stageCornerRadius = stageCornerRadius
        self.stageScale = stageScale
        self.inactiveStageScale = inactiveStageScale
        self.selectorOutset = selectorOutset
    }

    public static let previewDefaults = SwitcherAppearance(
        glassStyle: .native,
        glassRimStrength: 1,
        glassEdgeRefraction: 1,
        followsSystemGlassTint: true,
        glassTintAmount: 0,
        selectionHighlightStrength: 1,
        titleHaloStrength: 1,
        titleHaloSize: AppSettings.defaultTitleHaloSize,
        stageCornerRadius: AppSettings.defaultStageCornerRadius,
        stageScale: AppSettings.defaultStageScale,
        inactiveStageScale: 0.7,
        selectorOutset: AppSettings.defaultSelectorOutset
    )

    public static let iconDefaults = SwitcherAppearance(
        glassStyle: .native,
        glassRimStrength: 1,
        glassEdgeRefraction: 1,
        followsSystemGlassTint: true,
        glassTintAmount: 0,
        selectionHighlightStrength: 1,
        titleHaloStrength: 1,
        titleHaloSize: AppSettings.defaultTitleHaloSize,
        stageCornerRadius: AppSettings.defaultIconStageCornerRadius,
        stageScale: AppSettings.defaultIconScale,
        inactiveStageScale: 0.7,
        selectorOutset: AppSettings.defaultSelectorOutset
    )

    /// The halo strength actually drawn: regular glass is opaque enough to keep titles
    /// legible, so it has no halo whatever the saved strength.
    public var effectiveTitleHaloStrength: Double {
        glassStyle == .regular ? 0 : titleHaloStrength
    }

    static func clampedScale(_ scale: Double) -> Double {
        min(AppSettings.maximumStageScale, max(AppSettings.minimumStageScale, scale))
    }

    private enum CodingKeys: String, CodingKey {
        case glassStyle
        case glassRimStrength
        case glassEdgeRefraction
        case followsSystemGlassTint
        case glassTintAmount
        case selectionHighlightStrength
        case titleHaloStrength
        case titleHaloSize
        case stageCornerRadius
        case stageScale
        case inactiveStageScale
        case selectorOutset
    }

    /// Missing values take the mode's defaults; saved ones are clamped to the controls' ranges.
    init(from decoder: Decoder, defaults: SwitcherAppearance) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        func clamped(_ key: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
            min(range.upperBound, max(range.lowerBound, try value(key, fallback)))
        }
        glassStyle = try value(.glassStyle, defaults.glassStyle)
        glassRimStrength = try clamped(
            .glassRimStrength,
            defaults.glassRimStrength,
            AppSettings.minimumGlassRimStrength...AppSettings.maximumGlassRimStrength
        )
        glassEdgeRefraction = try clamped(
            .glassEdgeRefraction,
            defaults.glassEdgeRefraction,
            AppSettings.minimumGlassEdgeRefraction...AppSettings.maximumGlassEdgeRefraction
        )
        followsSystemGlassTint = try value(.followsSystemGlassTint, defaults.followsSystemGlassTint)
        glassTintAmount = try clamped(.glassTintAmount, defaults.glassTintAmount, 0...1)
        selectionHighlightStrength = try clamped(
            .selectionHighlightStrength,
            defaults.selectionHighlightStrength,
            AppSettings.minimumSelectionHighlightStrength...AppSettings.maximumSelectionHighlightStrength
        )
        titleHaloStrength = try clamped(.titleHaloStrength, defaults.titleHaloStrength, 0...1)
        titleHaloSize = try clamped(
            .titleHaloSize,
            defaults.titleHaloSize,
            AppSettings.minimumTitleHaloSize...AppSettings.maximumTitleHaloSize
        )
        stageCornerRadius = try value(.stageCornerRadius, defaults.stageCornerRadius)
        stageScale = Self.clampedScale(try value(.stageScale, defaults.stageScale))
        inactiveStageScale = try value(.inactiveStageScale, defaults.inactiveStageScale)
        selectorOutset = try value(.selectorOutset, defaults.selectorOutset)
    }
}
