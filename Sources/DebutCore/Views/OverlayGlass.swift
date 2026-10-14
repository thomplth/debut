import DockGlass
import SwiftUI

extension GlassStyle {
    /// SwiftUI glass for the clear and regular styles. Native draws through DockGlass instead,
    /// which itself falls back to clear glass when it cannot tune.
    var overlayGlass: Glass {
        self == .regular ? .regular : .clear
    }

    /// The same material for DockGlass, which draws it with a tint override.
    var systemGlassMaterial: SystemGlassMaterial {
        self == .regular ? .regular : .clear
    }
}

extension AppSettings {
    /// The window state every overlay glass draws in. The overlay is a non-activating panel in an
    /// app that never activates, so its glass would otherwise always draw inactive: milky, with
    /// no specular rim. The native switcher draws active (KHA-1065).
    static let overlayGlassFocusState: DockGlassStyle.FocusState = .active

    /// Whether a fixed tint can be drawn. macOS 26's glass filter has no fill inputs, so DockGlass
    /// draws a fixed tint only on the release its response was measured on (KHA-1091).
    static func supportsFixedGlassTint(operatingSystemMajor: Int) -> Bool {
        operatingSystemMajor == 27
    }

    static var supportsFixedGlassTint: Bool {
        supportsFixedGlassTint(operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// The Liquid Glass settings as DockGlass's adjustments to its fitted native look.
    public var dockGlassStyle: DockGlassStyle {
        dockGlassStyle(operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    func dockGlassStyle(operatingSystemMajor: Int) -> DockGlassStyle {
        let fixedTint = !followsSystemGlassTint
            && Self.supportsFixedGlassTint(operatingSystemMajor: operatingSystemMajor)
        return DockGlassStyle(
            rimStrength: glassRimStrength,
            edgeRefraction: glassEdgeRefraction,
            selectionStrength: selectionHighlightStrength,
            tint: fixedTint ? .fixed(glassTintAmount) : .system,
            focusState: Self.overlayGlassFocusState
        )
    }
}

/// Overlay glass in any shape: DockGlass's native switcher material, or SwiftUI's own clear or
/// regular glass, drawn active whatever the window's state.
struct OverlayGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let glassStyle: GlassStyle
    var dockGlassStyle: DockGlassStyle = .native

    /// The style with the overlay's focus state, whatever the caller passed.
    private var activeDockGlassStyle: DockGlassStyle {
        var style = dockGlassStyle
        style.focusState = AppSettings.overlayGlassFocusState
        return style
    }

    func body(content: Content) -> some View {
        if glassStyle.usesDockGlass {
            content
                .dockGlass(in: shape)
                .dockGlassStyle(activeDockGlassStyle)
        } else if case .fixed = dockGlassStyle.tint {
            // SwiftUI's own glass reads the system tint once at launch, so DockGlass writes the
            // override onto the filter (KHA-1072).
            content
                .systemGlass(glassStyle.systemGlassMaterial, in: shape)
                .dockGlassStyle(activeDockGlassStyle)
        } else {
            content
                .glassEffect(glassStyle.overlayGlass, in: shape)
                .dockGlassFocusState(AppSettings.overlayGlassFocusState)
        }
    }
}

struct OverlayGlassCapsuleModifier: ViewModifier {
    let glassStyle: GlassStyle
    var dockGlassStyle: DockGlassStyle = .native

    func body(content: Content) -> some View {
        content.modifier(OverlayGlassModifier(
            shape: Capsule(),
            glassStyle: glassStyle,
            dockGlassStyle: dockGlassStyle
        ))
    }
}
