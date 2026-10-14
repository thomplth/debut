import AppKit
import SwiftUI

/// A live render of the Command-Tab overlay for Settings › Appearance, pinned above the
/// controls so every change shows as it is made (KHA-1064).
///
/// It draws the real `StageOverlayView` for a sample stage, laid out for the main display at
/// the current size and over the current desktop picture, then shrinks the result to fit.
struct AppearancePreview: View {
    let settings: AppSettings
    let cardStyle: OverlayCardStyle
    var backdrop: AppearancePreviewBackdrop = .highContrast
    static let maximumHeight: CGFloat = 320

    /// The width the preview is offered, measured so its height can hug the stage.
    @State private var width: CGFloat = 0

    var body: some View {
        let sample = AppearancePreviewSample.shared
        let screen = AppearancePreviewSample.screenSize
        let stage = sample.stageSize(settings: settings, cardStyle: cardStyle, screen: screen)
        // The overlay lays out on the whole display, as it does for real; only a tight band
        // around the stage is shown.
        let band = CGSize(
            width: min(screen.width, stage.width + 32),
            height: min(screen.height, stage.height + 24)
        )
        let fit = width > 0
            ? min(1, width / band.width, Self.maximumHeight / band.height)
            : 0

        // Measured on a flexible spacer, never on the preview itself: a preview drawn wider
        // than the space it is offered would hold its container open and never shrink back.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: band.height * fit)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                ZStack {
                    AppearancePreviewBackdropView(backdrop: backdrop)
                        .frame(width: band.width, height: band.height)
                        .clipped()
                    StageOverlayView(viewModel: sample.viewModel(settings: settings, cardStyle: cardStyle))
                        .frame(width: screen.width, height: screen.height)
                        .frame(width: band.width, height: band.height)
                        .clipped()
                }
                .frame(width: band.width, height: band.height)
                .scaleEffect(fit)
                .frame(width: band.width * fit, height: band.height * fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Text(fit < 0.995 ? "\(Int((fit * 100).rounded()))% of actual size" : "Actual size")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(6)
                }
            }
            .clipped()
        .allowsHitTesting(false)
        .accessibilityLabel("Preview of the switcher with the current appearance settings")
        .onAppear { AppearancePreviewSample.shared.warmIcons() }
    }
}

/// The windows the preview shows: a browser, mail and a terminal, the middle one selected.
@MainActor
final class AppearancePreviewSample {
    static let shared = AppearancePreviewSample()

    static var screenSize: CGSize {
        (NSScreen.main ?? NSScreen.screens.first)?.frame.size ?? CGSize(width: 1512, height: 982)
    }

    private struct Window {
        let id: CGWindowID
        let bundleID: String
        let name: String
        let title: String
        let kind: Kind
    }

    private enum Kind { case browser, mail, terminal }

    private let windows: [Window] = [
        Window(id: 9_000_001, bundleID: "com.apple.Safari", name: "Safari", title: "Apple Developer", kind: .browser),
        Window(id: 9_000_002, bundleID: "com.apple.mail", name: "Mail", title: "Inbox", kind: .mail),
        Window(id: 9_000_003, bundleID: "com.apple.Terminal", name: "Terminal", title: "~ zsh", kind: .terminal),
    ]
    private let windowSize = CGSize(width: 1440, height: 900)
    private lazy var previews: [CGWindowID: CGImage] = Dictionary(
        uniqueKeysWithValues: windows.map { ($0.id, Self.mockWindow($0.kind)) }
    )

    /// Drawn without owning a window, so icon retention keeps them (KHA-1105).
    var bundleIDs: Set<String> { Set(windows.map(\.bundleID)) }

    func warmIcons() {
        AppIconCache.shared.warm(
            bundleIDs: windows.map(\.bundleID),
            sizes: AppIconCache.shared.warmSizes,
            badgeSizes: AppIconCache.overlayBadgeIconSizes
        )
    }

    func viewModel(settings: AppSettings, cardStyle: OverlayCardStyle) -> StageOverlayViewModel {
        var spaceManager = SpaceManager()
        let spaceID = spaceManager.spaces[0].id
        for window in windows {
            spaceManager.addWindow(SpaceWindow(
                windowID: window.id,
                ownerBundleID: window.bundleID,
                ownerName: window.name,
                windowTitle: window.title
            ), toSpaceID: spaceID)
        }
        var model = StageOverlayViewModel(
            spaceManager: spaceManager,
            activeSpaceIndex: 0,
            selectedWindowIndex: 1,
            windowPreviews: previews,
            windowSizes: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, windowSize) }),
            appearance: settings
        )
        model.cardStyle = cardStyle
        return model
    }

    /// The stage as the overlay would draw it on the given screen, to size the preview around.
    func stageSize(settings: AppSettings, cardStyle: OverlayCardStyle, screen: CGSize) -> CGSize {
        let aspects: [CGFloat?] = windows.map { _ in
            settings.adaptiveCardSizing ? windowSize.width / windowSize.height : nil
        }
        // Cards take the display's shape, so this must be the real display's size.
        let metrics = StageConstants.drawnMetrics(
            stageScale: CGFloat(settings.appearance(for: cardStyle).stageScale),
            contentAspects: [aspects],
            containerSize: screen,
            cardSpacing: CGFloat(settings.previewCardSpacing),
            cardStyle: cardStyle,
            badgeGrowth: CGFloat(settings.badgeGrowth)
        )
        return StageWindowLayout(
            contentAspects: aspects,
            availableWidth: StageConstants.availableStageWidth(screenWidth: screen.width),
            metrics: metrics
        ).stageSize
    }

    private static func mockWindow(_ kind: Kind) -> CGImage {
        let w = 1440, h = 900
        let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        func box(_ x: Int, _ y: Int, _ bw: Int, _ bh: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: bw, height: bh))
        }
        let dark = kind == .terminal
        box(0, 0, w, h, dark ? 0.11 : 0.98, dark ? 0.11 : 0.98, dark ? 0.13 : 0.98)
        box(0, h - 56, w, 56, dark ? 0.17 : 0.93, dark ? 0.17 : 0.93, dark ? 0.19 : 0.94)
        switch kind {
        case .browser:
            box(380, h - 44, 680, 30, 0.86, 0.86, 0.88)
            box(0, h - 400, w, 344, 0.12, 0.42, 0.95)
            box(120, h - 260, 700, 54, 1, 1, 1)
            for line in 0..<6 {
                let y: Int = 380 - line * 52
                box(120, y, 1100 - (line % 3) * 180, 22, 0.55, 0.55, 0.58)
            }
        case .mail:
            box(0, 0, 260, h - 56, 0.92, 0.93, 0.95)
            for line in 0..<9 {
                let y: Int = h - 140 - line * 86
                box(280, y, 420, 18, 0.2, 0.2, 0.22)
                box(280, y - 26, 360, 14, 0.6, 0.6, 0.62)
            }
            for line in 0..<12 {
                let y: Int = h - 140 - line * 48
                box(760, y, 600 - (line % 4) * 90, 16, 0.45, 0.45, 0.48)
            }
        case .terminal:
            let colors: [(CGFloat, CGFloat, CGFloat)] = [
                (0.3, 0.85, 0.4), (0.85, 0.85, 0.85), (0.4, 0.7, 1), (0.95, 0.75, 0.3),
            ]
            for line in 0..<20 {
                let y: Int = h - 100 - line * 38
                let width: Int = 200 + (line * 173) % 900
                let c = colors[line % colors.count]
                box(30, y, width, 18, c.0, c.1, c.2)
            }
        }
        return context.makeImage()!
    }
}

/// What the preview's glass sits on: busy backdrops that show how legible the glass, titles and
/// highlight stay at their worst.
enum AppearancePreviewBackdrop: String, CaseIterable, Identifiable {
    case highContrast = "High Contrast"
    case text = "Text"
    case stripes = "Stripes"

    var id: String { rawValue }
}

struct AppearancePreviewBackdropView: View {
    let backdrop: AppearancePreviewBackdrop

    var body: some View {
        switch backdrop {
        case .highContrast: highContrast
        case .text: text
        case .stripes: stripes
        }
    }

    /// Saturated discs over a dark-to-light ramp with a fine grid, as DockGlass is fitted on.
    private var highContrast: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let colors: [Color] = [.green, .yellow, .cyan, .red, .indigo, .mint, .orange, .purple, .blue]
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.05), Color(white: 0.5), Color(white: 0.95)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                ForEach(colors.indices, id: \.self) { index in
                    let diameter = size.height * 1.1
                    Circle()
                        .fill(colors[index])
                        .opacity(0.85)
                        .frame(width: diameter, height: diameter)
                        .position(
                            x: size.width * (CGFloat(index) + 0.5) / CGFloat(colors.count),
                            y: size.height * (index.isMultiple(of: 2) ? 0.15 : 0.85)
                        )
                }
                Path { path in
                    for x in stride(from: CGFloat(0), through: size.width, by: 24) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: CGFloat(0), through: size.height, by: 24) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.black.opacity(0.55), lineWidth: 2)
            }
        }
    }

    /// A page filled with text, the hardest thing for a title to sit over.
    private var text: some View {
        let lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. "
        return ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<12, id: \.self) { index in
                    Text(index.isMultiple(of: 2) ? "Lorem ipsum dolor sit amet" : "Consectetur adipiscing elit")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(index.isMultiple(of: 3) ? Color.blue : Color.black)
                    Text(String(repeating: lorem, count: 4))
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
    }

    /// Saturated diagonal stripes, alternating dark and light, across every corner.
    private var stripes: some View {
        GeometryReader { geometry in
            // A square as wide as the diagonal still covers the frame once rotated.
            let side = (geometry.size.width * geometry.size.width
                + geometry.size.height * geometry.size.height).squareRoot()
            ZStack {
                LinearGradient(
                    colors: [.orange, .pink, .purple, .blue, .teal],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                HStack(spacing: 14) {
                    ForEach(0..<Int(side / 28) + 2, id: \.self) { index in
                        Rectangle()
                            .fill(index.isMultiple(of: 2) ? Color.black.opacity(0.4) : Color.white.opacity(0.4))
                            .frame(width: 14)
                    }
                }
                .frame(width: side, height: side)
                .rotationEffect(.degrees(18))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}
