import SwiftUI

extension GlassStyle {
    var overlayGlass: Glass {
        self == .clear ? .clear : .regular
    }
}

/// Keeps compact overlay chrome on the same user-selected glass as the stage surfaces.
struct OverlayGlassCapsuleModifier: ViewModifier {
    let glassStyle: GlassStyle

    func body(content: Content) -> some View {
        content.glassEffect(glassStyle.overlayGlass, in: .capsule)
    }
}
