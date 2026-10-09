import DockGlass
import SwiftUI

extension GlassStyle {
    /// SwiftUI glass for the clear and regular styles. Native draws through DockGlass instead,
    /// which itself falls back to clear glass when it cannot tune.
    var overlayGlass: Glass {
        self == .regular ? .regular : .clear
    }
}

extension AppSettings {
    /// The Liquid Glass settings as DockGlass's adjustments to its fitted native look.
    public var dockGlassStyle: DockGlassStyle {
        DockGlassStyle(
            rimStrength: glassRimStrength,
            edgeRefraction: glassEdgeRefraction,
            tint: followsSystemGlassTint ? .system : .fixed(glassTintAmount)
        )
    }
}

/// Overlay glass in any shape: DockGlass's native switcher material, or SwiftUI's own clear or
/// regular glass.
struct OverlayGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let glassStyle: GlassStyle
    var dockGlassStyle: DockGlassStyle = .native

    func body(content: Content) -> some View {
        if glassStyle.usesDockGlass {
            content
                .dockGlass(in: shape)
                .dockGlassStyle(dockGlassStyle)
        } else {
            content.glassEffect(glassStyle.overlayGlass, in: shape)
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
