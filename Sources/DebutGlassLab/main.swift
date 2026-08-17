import AppKit
import DebutCore
import ImageIO
import SwiftUI

private struct GlassLabPlateSpec: Identifiable {
    let id: Int
    let width: CGFloat
    let iconCount: Int

    static let samples = [
        GlassLabPlateSpec(id: 1, width: 760, iconCount: 5),
        GlassLabPlateSpec(id: 2, width: 620, iconCount: 4),
        GlassLabPlateSpec(id: 3, width: 480, iconCount: 3),
    ]

    static let height: CGFloat = 164
    static let spacing: CGFloat = 18
    static let cornerRadius: CGFloat = 28
}

private struct GlassLabPlateContent: View {
    let spec: GlassLabPlateSpec
    @State private var selectedIndex = 1
    @State private var hoverIndex: Int?
    @State private var dragOffset = CGSize.zero

    private let symbols = ["safari", "envelope.fill", "terminal.fill", "note.text", "folder.fill"]
    private let labels = ["Safari", "Mail", "Terminal", "Notes", "Finder"]

    var body: some View {
        HStack(spacing: 22) {
            ForEach(0..<spec.iconCount, id: \.self) { index in
                let highlighted = (hoverIndex ?? selectedIndex) == index
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(highlighted ? Color.accentColor.opacity(0.24) : .white.opacity(0.07))
                        .frame(width: 92, height: 92)
                        .overlay {
                            Image(systemName: symbols[index])
                                .font(.system(size: 42, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.primary)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.white.opacity(highlighted ? 0.34 : 0.10), lineWidth: 1)
                        }
                        .scaleEffect(highlighted ? 1.06 : 1)
                        .shadow(color: .black.opacity(highlighted ? 0.26 : 0.12), radius: highlighted ? 14 : 6, y: 5)

                    Text(labels[index])
                        .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
                        .foregroundStyle(highlighted ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoverIndex = hovering ? index : (hoverIndex == index ? nil : hoverIndex)
                }
                .onTapGesture { selectedIndex = index }
                .animation(.spring(duration: 0.18, bounce: 0.08), value: highlighted)
            }
        }
        .frame(width: spec.width, height: GlassLabPlateSpec.height)
        .contentShape(RoundedRectangle(cornerRadius: GlassLabPlateSpec.cornerRadius))
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { dragOffset = $0.translation }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.32, bounce: 0.16)) {
                        dragOffset = .zero
                    }
                }
        )
    }
}

private struct GlassLabSwiftUIStack: View {
    let recipe: GlassLabRecipe

    var body: some View {
        if recipe.family == .swiftUIContainer {
            GlassEffectContainer(spacing: 0) {
                stack
            }
        } else {
            stack
        }
    }

    private var stack: some View {
        VStack(spacing: GlassLabPlateSpec.spacing) {
            ForEach(GlassLabPlateSpec.samples) { spec in
                surface(for: spec)
            }
        }
    }

    @ViewBuilder
    private func surface(for spec: GlassLabPlateSpec) -> some View {
        switch recipe {
        case .swiftUIIndependentClear, .swiftUIContainerClear:
            GlassLabPlateContent(spec: spec)
                .glassEffect(.clear, in: .rect(cornerRadius: GlassLabPlateSpec.cornerRadius))
        case .swiftUIIndependentRegular, .swiftUIContainerRegular:
            GlassLabPlateContent(spec: spec)
                .glassEffect(.regular, in: .rect(cornerRadius: GlassLabPlateSpec.cornerRadius))
        case .swiftUIThickMaterial:
            GlassLabPlateContent(spec: spec)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: GlassLabPlateSpec.cornerRadius))
                .shadow(color: .black.opacity(0.20), radius: 18, y: 7)
        default:
            GlassLabPlateContent(spec: spec)
        }
    }
}

@MainActor
private struct GlassLabAppKitStack: NSViewRepresentable {
    let recipe: GlassLabRecipe

    func makeNSView(context: Context) -> NSView {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = GlassLabPlateSpec.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for spec in GlassLabPlateSpec.samples {
            let surface = makeSurface(spec: spec)
            surface.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(surface)
            NSLayoutConstraint.activate([
                surface.widthAnchor.constraint(equalToConstant: spec.width),
                surface.heightAnchor.constraint(equalToConstant: GlassLabPlateSpec.height),
            ])
        }

        if recipe.family == .legacyControl {
            root.addSubview(stack)
        } else {
            let container = NSGlassEffectContainerView()
            container.spacing = 0
            container.translatesAutoresizingMaskIntoConstraints = false
            container.contentView = stack
            root.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                container.topAnchor.constraint(equalTo: root.topAnchor),
                container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        return root
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func makeSurface(spec: GlassLabPlateSpec) -> NSView {
        let hostingView = NSHostingView(rootView: GlassLabPlateContent(spec: spec))
        hostingView.frame = NSRect(x: 0, y: 0, width: spec.width, height: GlassLabPlateSpec.height)
        hostingView.autoresizingMask = [.width, .height]

        switch recipe {
        case .legacyHUD, .legacyPopover:
            let effect = NSVisualEffectView()
            effect.material = recipe == .legacyHUD ? .hudWindow : .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = GlassLabPlateSpec.cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(hostingView)
            return effect
        default:
            let glass = NSGlassEffectView()
            glass.cornerRadius = recipe.tuning.cornerRadius
            if let rawStyle = recipe.appKitStyleRawValue {
                glass.style = NSGlassEffectView.Style(rawValue: rawStyle)
                    ?? unsafeBitCast(rawStyle, to: NSGlassEffectView.Style.self)
            }
            if let tintWhite = recipe.tuning.tintWhite {
                glass.tintColor = NSColor(
                    white: tintWhite,
                    alpha: recipe.tuning.tintAlpha
                )
            }
            glass.contentView = hostingView
            applyTuning(recipe.tuning, to: glass)
            return glass
        }
    }

    private func applyTuning(_ tuning: GlassLabTuning, to view: NSView) {
        guard tuning.borderWidth > 0 || tuning.shadowAlpha > 0 else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = tuning.cornerRadius
        view.layer?.borderColor = NSColor(
            white: tuning.borderWhite,
            alpha: tuning.borderAlpha
        ).cgColor
        view.layer?.borderWidth = tuning.borderWidth
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = Float(tuning.shadowAlpha)
        view.layer?.shadowRadius = tuning.shadowRadius
        view.layer?.shadowOffset = CGSize(width: 0, height: tuning.shadowOffsetY)
    }
}

private struct GlassLabRootView: View {
    let recipe: GlassLabRecipe

    var body: some View {
        ZStack {
            if recipe.family == .appKitGlass
                || recipe.family == .supportedTuning
                || recipe.family == .privateResearch
                || recipe == .legacyHUD
                || recipe == .legacyPopover {
                GlassLabAppKitStack(recipe: recipe)
            } else {
                GlassLabSwiftUIStack(recipe: recipe)
            }

            VStack {
                HStack(spacing: 8) {
                    if recipe.usesPrivateAPI {
                        Text("RESEARCH ONLY")
                            .foregroundStyle(.orange)
                    }
                    Text(recipe.title)
                    Text("·")
                    Text(accessibilitySummary)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.54), in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 28)

                Spacer()

                Text("Hover or click an icon · Drag a plate · Esc quits")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.48), in: Capsule())
                    .padding(.bottom, 24)
            }
        }
    }

    private var accessibilitySummary: String {
        let workspace = NSWorkspace.shared
        return "Reduce Transparency \(workspace.accessibilityDisplayShouldReduceTransparency ? "on" : "off"), Increase Contrast \(workspace.accessibilityDisplayShouldIncreaseContrast ? "on" : "off")"
    }
}

@MainActor
private final class GlassLabAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let recipe = configuredRecipe()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: GlassLabRootView(recipe: recipe))
        applyAppearance(to: window)
        window.orderFrontRegardless()
        self.window = window

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 53 else { return event }
            NSApplication.shared.terminate(nil)
            return nil
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    private func configuredRecipe() -> GlassLabRecipe {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--recipe"), arguments.indices.contains(index + 1) {
            return GlassLabRecipe(bundleValue: arguments[index + 1])
        }
        return GlassLabRecipe(
            bundleValue: Bundle.main.object(forInfoDictionaryKey: "DebutGlassLabRecipe") as? String
        )
    }

    private func applyAppearance(to window: NSWindow) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--appearance"),
              arguments.indices.contains(index + 1)
        else { return }
        switch arguments[index + 1] {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }
}

@main
@MainActor
private enum DebutGlassLabMain {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--list-recipes") {
            for recipe in GlassLabRecipe.allCases {
                print(recipe.rawValue)
            }
            return
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--validate-capture"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  GlassLabCaptureValidator.containsVisibleContent(image)
            else {
                fputs("Capture is missing or has uniform luminance: \(path)\n", stderr)
                exit(1)
            }
            print("Validated non-uniform capture: \(path)")
            return
        }
        let application = NSApplication.shared
        let delegate = GlassLabAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

}
