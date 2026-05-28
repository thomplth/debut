import SwiftUI
import CoreGraphics

public struct PlateConstants {
    public static let thumbnailWidth: CGFloat = 160
    public static let thumbnailHeight: CGFloat = 100
    public static let windowSpacing: CGFloat = 12
    public static let padding: CGFloat = 24
    public static let minPlateWidth: CGFloat = 300
    public static let topInset: CGFloat = 12
    public static let thumbnailTopPad: CGFloat = 8
    public static let labelBottomPad: CGFloat = 24
    public static let screenMargin: CGFloat = 80
    public static let badgeSize: CGFloat = 40

    public static func thumbnailSize(forWindowCount count: Int, screenWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let maxWidth = screenWidth - screenMargin * 2
        let availableForThumbnails = maxWidth - padding * 2
        let maxPerWindow = count > 0
            ? (availableForThumbnails - CGFloat(max(0, count - 1)) * windowSpacing) / CGFloat(count)
            : thumbnailWidth
        let w = min(thumbnailWidth, max(80, maxPerWindow))
        let h = w * (thumbnailHeight / thumbnailWidth)
        return (w, h)
    }

    public static func plateHeight(thumbnailHeight: CGFloat) -> CGFloat {
        topInset + 16 + thumbnailTopPad + thumbnailHeight + 16 + labelBottomPad
    }

    public static func plateWidth(forWindowCount count: Int, thumbnailWidth: CGFloat) -> CGFloat {
        let thumbsWidth = CGFloat(max(count, 1)) * thumbnailWidth + CGFloat(max(0, count - 1)) * windowSpacing
        return max(thumbsWidth + padding * 2, minPlateWidth)
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
        let maxWindows = plates.map(\.windows.count).max() ?? 0

        GeometryReader { geo in
            let tSize = PlateConstants.thumbnailSize(forWindowCount: maxWindows, screenWidth: geo.size.width)
            let pHeight = PlateConstants.plateHeight(thumbnailHeight: tSize.height)
            let plateWidth = PlateConstants.plateWidth(forWindowCount: maxWindows, thumbnailWidth: tSize.width)

            let inactiveScale = CGFloat(viewModel.appearance.inactivePlateScale)
            let spacing: CGFloat = 14

            // Calculate offset to center the active plate
            let totalBefore = CGFloat(viewModel.activeStageIndex) * (pHeight * inactiveScale + spacing)
            let activeCenter = totalBefore + pHeight / 2
            let offset = geo.size.height / 2 - activeCenter

            VStack(spacing: spacing) {
                ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                    let isActive = index == viewModel.activeStageIndex
                    let scale = isActive ? 1.0 : inactiveScale

                    PlateSwiftUIView(
                        plate: plate,
                        isSelected: isActive,
                        selectedWindowIndex: isActive ? viewModel.selectedWindowIndex : nil,
                        isRenaming: isRenaming && isActive,
                        thumbnailWidth: tSize.width,
                        thumbnailHeight: tSize.height,
                        appearance: viewModel.appearance
                    )
                    .frame(width: plateWidth, height: pHeight)
                    .scaleEffect(scale)
                    .frame(width: plateWidth * scale, height: pHeight * scale)
                }
            }
            .frame(width: geo.size.width, alignment: .center)
            .offset(y: offset)
        }
    }
}

struct PlateSwiftUIView: View {
    let plate: PlateData
    let isSelected: Bool
    let selectedWindowIndex: Int?
    let isRenaming: Bool
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let appearance: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isRenaming {
                RenameField(initialName: plate.name)
                    .padding(.leading, PlateConstants.padding)
                    .padding(.top, PlateConstants.topInset)
            } else {
                Text(plate.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.leading, PlateConstants.padding)
                    .padding(.top, PlateConstants.topInset)
            }

            HStack(spacing: PlateConstants.windowSpacing) {
                if plate.windows.isEmpty {
                    Text("Empty")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(plate.windows.enumerated()), id: \.element.id) { index, window in
                        WindowPreviewView(
                            window: window,
                            isWindowSelected: selectedWindowIndex == index,
                            thumbnailWidth: thumbnailWidth,
                            thumbnailHeight: thumbnailHeight,
                            appearance: appearance
                        )
                    }
                }
            }
            .padding(.horizontal, PlateConstants.padding)
            .padding(.top, PlateConstants.thumbnailTopPad)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(LiquidGlassModifier(
            cornerRadius: CGFloat(appearance.plateCornerRadius),
            appearance: appearance
        ))
    }
}

struct WindowPreviewView: View {
    let window: PlateWindowData
    let isWindowSelected: Bool
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let appearance: AppSettings

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                // Window preview or placeholder
                Group {
                    if let cgImage = window.previewImage {
                        Image(decorative: cgImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.3))
                            .overlay {
                                AppIconImage(bundleID: window.ownerBundleID, name: window.ownerName, iconSize: 32)
                                    .frame(width: 32, height: 32)
                            }
                    }
                }
                .frame(width: thumbnailWidth, height: thumbnailHeight)

                // App icon badge (top-left)
                AppIconImage(bundleID: window.ownerBundleID, name: window.ownerName, iconSize: PlateConstants.badgeSize)
                    .frame(width: PlateConstants.badgeSize, height: PlateConstants.badgeSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: -4, y: -4)
            }

            // Window title — always visible
            Text(window.windowTitle.isEmpty ? window.ownerName : window.windowTitle)
                .font(.system(size: max(9, thumbnailWidth * 0.065)))
                .foregroundStyle(isWindowSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: thumbnailWidth + 8)
        }
        .padding(6)
        .background(
            isWindowSelected
                ? RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(appearance.selectionOpacity))
                : nil
        )
    }
}

struct RenameField: NSViewRepresentable {
    let initialName: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.stringValue = initialName
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.isEditable = true
        field.selectText(nil)
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        field.target = context.coordinator
        field.action = #selector(Coordinator.commitRename(_:))
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        @objc func commitRename(_ sender: NSTextField) {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.thomplth.Debut.renameCommit"),
                object: sender.stringValue,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }
}

struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let appearance: AppSettings

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = appearance.glassStyle == .clear ? .clear : .regular
            content
                .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

struct AppIconImage: NSViewRepresentable {
    let bundleID: String
    let name: String
    var iconSize: CGFloat = 128

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
            icon.size = NSSize(width: iconSize, height: iconSize)
            return icon
        }
        let size = iconSize
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
