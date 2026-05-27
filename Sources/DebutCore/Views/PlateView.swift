import SwiftUI

public struct PlateConstants {
    public static let iconSize: CGFloat = 240
    public static let iconSpacing: CGFloat = 12
    public static let padding: CGFloat = 24
    public static let minPlateWidth: CGFloat = 300
    public static let topInset: CGFloat = 12
    public static let iconTopPad: CGFloat = 8
    public static let labelBottomPad: CGFloat = 24
    public static var plateHeight: CGFloat { topInset + 16 + iconTopPad + iconSize + labelBottomPad }

    public static func plateWidth(forAppCount count: Int) -> CGFloat {
        let iconsWidth = CGFloat(max(count, 1)) * iconSize + CGFloat(max(0, count - 1)) * iconSpacing
        return max(iconsWidth + padding * 2, minPlateWidth)
    }
}

public struct OverlaySwiftUIView: View {
    public let viewModel: OverlayViewModel
    public let isRenaming: Bool

    public init(viewModel: OverlayViewModel, isRenaming: Bool = false) {
        self.viewModel = viewModel
        self.isRenaming = isRenaming
    }

    public var body: some View {
        let plates = viewModel.plates
        let maxApps = plates.map(\.apps.count).max() ?? 0
        let plateWidth = PlateConstants.plateWidth(forAppCount: maxApps)

        GeometryReader { geo in
            let spacing: CGFloat = 14
            let totalHeight = CGFloat(plates.count) * PlateConstants.plateHeight + CGFloat(max(0, plates.count - 1)) * spacing
            let activeTop = CGFloat(viewModel.activeStageIndex) * (PlateConstants.plateHeight + spacing)
            let activeCenter = activeTop + PlateConstants.plateHeight / 2
            let offset = geo.size.height / 2 - activeCenter

            VStack(spacing: spacing) {
                ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                    PlateSwiftUIView(
                        plate: plate,
                        isSelected: index == viewModel.activeStageIndex,
                        selectedAppIndex: index == viewModel.activeStageIndex ? viewModel.selectedAppIndex : nil,
                        isRenaming: isRenaming && index == viewModel.activeStageIndex
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
    let isRenaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(plate.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.leading, PlateConstants.padding)
                .padding(.top, PlateConstants.topInset)

            HStack(spacing: PlateConstants.iconSpacing) {
                if plate.apps.isEmpty {
                    Text("Empty")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(plate.apps.enumerated()), id: \.offset) { index, app in
                        AppIconView(app: app, isAppSelected: selectedAppIndex == index)
                    }
                }
            }
            .padding(.horizontal, PlateConstants.padding)
            .padding(.top, PlateConstants.iconTopPad)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(LiquidGlassModifier(cornerRadius: 22, isSelected: isSelected))
    }
}

struct AppIconView: View {
    let app: PlateAppData
    let isAppSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if isAppSelected {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.primary.opacity(0.08))
                        .frame(
                            width: PlateConstants.iconSize + 12,
                            height: PlateConstants.iconSize + 12
                        )
                }
                AppIconImage(bundleID: app.bundleID, name: app.name)
                    .frame(width: PlateConstants.iconSize, height: PlateConstants.iconSize)
            }

            Text(app.name)
                .font(.system(size: 12))
                .foregroundStyle(isAppSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                .lineLimit(1)
                .frame(width: PlateConstants.iconSize + 16)
        }
    }
}

struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isSelected: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    isSelected
                        ? RoundedRectangle(cornerRadius: cornerRadius).stroke(.primary.opacity(0.15), lineWidth: 1.5)
                        : nil
                )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    isSelected
                        ? RoundedRectangle(cornerRadius: cornerRadius).stroke(.primary.opacity(0.15), lineWidth: 1.5)
                        : nil
                )
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
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: PlateConstants.iconSize, height: PlateConstants.iconSize)
            return icon
        }
        let size = PlateConstants.iconSize
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: size - 16, height: size - 16), xRadius: 20, yRadius: 20).fill()
        let label = String(name.prefix(2)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.3),
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: size / 2 - sz.width / 2, y: size / 2 - sz.height / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }
}
