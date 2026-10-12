import AppKit
import DockGlass
import QuartzCore
import SwiftUI
import Testing
@testable import DebutCore

/// The overlay is a non-activating panel in an app that never activates, so its glass would
/// always draw in macOS's inactive state: milky Clear, no specular rim (KHA-1065). Every glass
/// style must draw active instead, as the native switcher does.
///
/// The test window is never key in an active app, the same state as the overlay. The system hides
/// the glass's specular rim on inactive glass (its layer's opacity drops to 0), which makes the
/// rim layer a readable witness of the state the glass drew in.
@MainActor
@Suite("Overlay glass focus state", .serialized)
struct OverlayGlassFocusTests {
    @Test("Every glass style draws active in an inactive window", arguments: GlassStyle.allCases)
    func drawsActive(style: GlassStyle) throws {
        try #require(DockGlass.canOverrideFocusState)
        let window = Self.host(style: style, dockGlassStyle: AppSettings().dockGlassStyle)
        defer { window.orderOut(nil) }
        #expect(!window.isKeyWindow)
        let opacities = Self.rimOpacities(in: try #require(window.contentView?.layer))
        #expect(!opacities.isEmpty, "no glass rim layer for \(style)")
        #expect(opacities.allSatisfy { $0 == 1 }, "\(style) rim opacities \(opacities)")
    }

    @Test("A style that asks for another state still draws active", arguments: [DockGlassStyle.FocusState.inactive, .matchWindow])
    func overridesCallerFocus(focus: DockGlassStyle.FocusState) throws {
        try #require(DockGlass.canOverrideFocusState)
        let window = Self.host(style: .native, dockGlassStyle: DockGlassStyle(focusState: focus))
        defer { window.orderOut(nil) }
        let opacities = Self.rimOpacities(in: try #require(window.contentView?.layer))
        #expect(!opacities.isEmpty && opacities.allSatisfy { $0 == 1 }, "rim opacities \(opacities)")
    }

    @Test("Debut asks DockGlass for the active state")
    func dockGlassStyleIsActive() {
        #expect(AppSettings().dockGlassStyle.focusState == .active)
    }

    static func host(style: GlassStyle, dockGlassStyle: DockGlassStyle) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: Color.clear
            .frame(width: 300, height: 120)
            .modifier(OverlayGlassModifier(
                shape: RoundedRectangle(cornerRadius: 30, style: .continuous),
                glassStyle: style,
                dockGlassStyle: dockGlassStyle
            )))
        window.orderFrontRegardless()
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return window
    }

    /// The opacity of every specular rim layer under `layer`.
    static func rimOpacities(in layer: CALayer) -> [Float] {
        var found: [Float] = []
        if NSStringFromClass(type(of: layer)) == "CASDFLayer",
           layer.responds(to: NSSelectorFromString("effect")),
           let effect = layer.value(forKey: "effect") as? NSObject,
           NSStringFromClass(type(of: effect)) == "CASDFKeyFillHighlightEffect" {
            found.append(layer.opacity)
        }
        for sublayer in layer.sublayers ?? [] { found += rimOpacities(in: sublayer) }
        return found
    }
}
