import Foundation

public enum GlassLabRecipeFamily: String, Sendable {
    case swiftUIIndependent
    case swiftUIContainer
    case appKitGlass
    case supportedTuning
    case legacyControl
    case privateResearch
}

public struct GlassLabTuning: Equatable, Sendable {
    public var tintWhite: Double?
    public var tintAlpha: Double
    public var borderWhite: Double
    public var borderAlpha: Double
    public var borderWidth: Double
    public var shadowAlpha: Double
    public var shadowRadius: Double
    public var shadowOffsetY: Double
    public var cornerRadius: Double

    public static let baseline = GlassLabTuning(
        tintWhite: nil,
        tintAlpha: 0,
        borderWhite: 1,
        borderAlpha: 0,
        borderWidth: 0,
        shadowAlpha: 0,
        shadowRadius: 0,
        shadowOffsetY: 0,
        cornerRadius: 28
    )

    public static let neutral = GlassLabTuning(
        tintWhite: 0.5,
        tintAlpha: 0.10,
        borderWhite: 1,
        borderAlpha: 0.18,
        borderWidth: 0.5,
        shadowAlpha: 0.28,
        shadowRadius: 22,
        shadowOffsetY: -8,
        cornerRadius: 28
    )
}

public enum GlassLabRecipe: String, CaseIterable, Hashable, Sendable {
    case swiftUIIndependentClear = "swiftui-independent-clear"
    case swiftUIIndependentRegular = "swiftui-independent-regular"
    case swiftUIContainerClear = "swiftui-container-clear"
    case swiftUIContainerRegular = "swiftui-container-regular"
    case appKitClear = "appkit-clear"
    case appKitRegular = "appkit-regular"
    case appKitTunedNeutral = "appkit-tuned-neutral"
    case legacyHUD = "legacy-hud"
    case legacyPopover = "legacy-popover"
    case swiftUIThickMaterial = "swiftui-thick-material"
    case privateDock = "private-dock"
    case privateAppIcons = "private-app-icons"

    public init(bundleValue: String?) {
        self = bundleValue.flatMap(Self.init(rawValue:)) ?? .swiftUIIndependentClear
    }

    public var family: GlassLabRecipeFamily {
        switch self {
        case .swiftUIIndependentClear, .swiftUIIndependentRegular:
            .swiftUIIndependent
        case .swiftUIContainerClear, .swiftUIContainerRegular:
            .swiftUIContainer
        case .appKitClear, .appKitRegular:
            .appKitGlass
        case .appKitTunedNeutral:
            .supportedTuning
        case .legacyHUD, .legacyPopover, .swiftUIThickMaterial:
            .legacyControl
        case .privateDock, .privateAppIcons:
            .privateResearch
        }
    }

    public var usesPrivateAPI: Bool {
        family == .privateResearch
    }

    public var appKitStyleRawValue: Int? {
        switch self {
        case .appKitRegular, .appKitTunedNeutral: 0
        case .appKitClear: 1
        case .privateDock: 2
        case .privateAppIcons: 3
        default: nil
        }
    }

    public var tuning: GlassLabTuning {
        self == .appKitTunedNeutral ? .neutral : .baseline
    }

    public var artifactName: String {
        "DebutGlassLab-\(rawValue)"
    }

    public var title: String {
        switch self {
        case .swiftUIIndependentClear: "SwiftUI · Independent Clear"
        case .swiftUIIndependentRegular: "SwiftUI · Independent Regular"
        case .swiftUIContainerClear: "SwiftUI Container · Clear"
        case .swiftUIContainerRegular: "SwiftUI Container · Regular"
        case .appKitClear: "AppKit Embedded · Clear"
        case .appKitRegular: "AppKit Embedded · Regular"
        case .appKitTunedNeutral: "AppKit Embedded · Tuned Neutral"
        case .legacyHUD: "Legacy Control · HUD Window"
        case .legacyPopover: "Legacy Control · Popover"
        case .swiftUIThickMaterial: "Legacy Control · Thick Material"
        case .privateDock: "Research Only · Raw Style 2 (Dock)"
        case .privateAppIcons: "Research Only · Raw Style 3 (App Icons)"
        }
    }
}
