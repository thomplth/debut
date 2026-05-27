import SwiftUI

public struct PlateConstants {
    public static let plateHeight: CGFloat = 130
    public static let iconSize: CGFloat = 72
    public static let iconSpacing: CGFloat = 6
    public static let padding: CGFloat = 16
    public static let minPlateWidth: CGFloat = 200

    public static func plateWidth(forAppCount count: Int) -> CGFloat {
        let iconsWidth = CGFloat(max(count, 1)) * iconSize + CGFloat(max(0, count - 1)) * iconSpacing
        return max(iconsWidth + padding * 2, minPlateWidth)
    }
}

public struct OverlaySwiftUIView: View {
    public let viewModel: OverlayViewModel

    public init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let plates = viewModel.plates
        let maxApps = plates.map(\.apps.count).max() ?? 0
        let plateWidth = PlateConstants.plateWidth(forAppCount: maxApps)

        GeometryReader { geo in
            let spacing: CGFloat = 10
            let totalHeight = CGFloat(plates.count) * PlateConstants.plateHeight + CGFloat(max(0, plates.count - 1)) * spacing
            let activeTop = CGFloat(viewModel.activeStageIndex) * (PlateConstants.plateHeight + spacing)
            let activeCenter = activeTop + PlateConstants.plateHeight / 2
            let offset = geo.size.height / 2 - activeCenter

            VStack(spacing: spacing) {
                ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                    PlateSwiftUIView(
                        plate: plate,
                        isSelected: index == viewModel.activeStageIndex,
                        selectedAppIndex: index == viewModel.activeStageIndex ? viewModel.selectedAppIndex : nil
                    )
                    .frame(width: plateWidth, height: PlateConstants.plateHeight)
                }
            }
            .frame(width: geo.size.width, height: totalHeight, alignment: .top)
            .offset(y: offset)
        }
    }
}

struct PlateSwiftUIView: View {
    let plate: PlateData
    let isSelected: Bool
    let selectedAppIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plate.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.leading, PlateConstants.padding)
                .padding(.top, 10)

            HStack(spacing: PlateConstants.iconSpacing) {
                if plate.apps.isEmpty {
                    Text("Empty")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(plate.apps.enumerated()), id: \.offset) { index, app in
                        AppIconView(app: app, isAppSelected: selectedAppIndex == index)
                    }
                }
            }
            .padding(.horizontal, PlateConstants.padding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(LiquidGlassModifier(cornerRadius: 18))
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.2), lineWidth: 1.5)
                : nil
        )
    }
}

struct AppIconView: View {
    let app: PlateAppData
    let isAppSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if isAppSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.primary.opacity(0.1))
                        .frame(width: PlateConstants.iconSize + 8, height: PlateConstants.iconSize + 8)
                }

                AppIconImage(bundleID: app.bundleID, name: app.name)
                    .frame(width: PlateConstants.iconSize, height: PlateConstants.iconSize)
            }

            Text(app.name)
                .font(.system(size: 10))
                .foregroundStyle(isAppSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                .lineLimit(1)
                .frame(width: PlateConstants.iconSize + 10)
        }
    }
}

struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

struct AppIconImage: NSViewRepresentable {
    let bundleID: String
    let name: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = resolveIcon()
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = resolveIcon()
    }

    private func resolveIcon() -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let size = PlateConstants.iconSize
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: size - 12, height: size - 12), xRadius: 14, yRadius: 14).fill()
        let label = String(name.prefix(2)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: size / 2 - sz.width / 2, y: size / 2 - sz.height / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }
}
