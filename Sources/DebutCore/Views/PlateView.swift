import SwiftUI
import CoreGraphics

enum PlateFocusTransition: Equatable {
    case spring(duration: TimeInterval, bounce: Double)
    case fade(duration: TimeInterval)

    var animation: Animation {
        switch self {
        case let .spring(duration, bounce):
            .spring(duration: duration, bounce: bounce)
        case let .fade(duration):
            .easeOut(duration: duration)
        }
    }

    var usesSpatialMotion: Bool {
        switch self {
        case .spring: true
        case .fade: false
        }
    }
}

struct PlateLift: Equatable {
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
}

enum PlateMotion {
    static func focusTransition(reduceMotion: Bool) -> PlateFocusTransition {
        reduceMotion
            ? .fade(duration: 0.12)
            : .spring(duration: 0.26, bounce: 0.08)
    }

    static func lift(isActive: Bool) -> PlateLift {
        isActive
            ? PlateLift(shadowOpacity: 0.22, shadowRadius: 18, shadowY: 8)
            : PlateLift(shadowOpacity: 0.08, shadowRadius: 6, shadowY: 2)
    }
}

public struct PlateConstants {
    public static let thumbnailWidth: CGFloat = 160
    public static let thumbnailHeight: CGFloat = 100
    public static let windowSpacing: CGFloat = 12
    public static let padding: CGFloat = 24
    public static let minPlateWidth: CGFloat = 300
    public static let topPadding: CGFloat = 24
    public static let bottomPadding: CGFloat = 24
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
        topPadding + thumbnailHeight + 16 + bottomPadding
    }

    public static func plateWidth(forWindowCount count: Int, thumbnailWidth: CGFloat) -> CGFloat {
        let thumbsWidth = CGFloat(max(count, 1)) * thumbnailWidth + CGFloat(max(0, count - 1)) * windowSpacing
        return max(thumbsWidth + padding * 2, minPlateWidth)
    }
}

public struct OverlaySwiftUIView: View {
    public let viewModel: OverlayViewModel
    public var onWindowMoved: ((CGWindowID, Int, Int) -> Void)?
    public var onStageReordered: ((Int, Int) -> Void)?

    @State private var windowDrag: WindowDragState?
    @State private var stageDrag: StageDragState?
    @State private var plateFrames: [Int: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: OverlayViewModel,
        onWindowMoved: ((CGWindowID, Int, Int) -> Void)? = nil,
        onStageReordered: ((Int, Int) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onWindowMoved = onWindowMoved
        self.onStageReordered = onStageReordered
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
            let focusTransition = PlateMotion.focusTransition(reduceMotion: reduceMotion)

            let totalBefore = CGFloat(viewModel.activeStageIndex) * (pHeight * inactiveScale + spacing)
            let activeCenter = totalBefore + pHeight / 2
            let yOffset = geo.size.height / 2 - activeCenter

            ZStack {
                VStack(spacing: spacing) {
                    ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                        let isActive = index == viewModel.activeStageIndex
                        let scale = isActive ? 1.0 : inactiveScale
                        let isDropTarget = windowDrag?.dropTargetStageIndex == index
                            && windowDrag?.sourceStageIndex != index
                        let isStageDragging = stageDrag?.stageIndex == index
                        let lift = PlateMotion.lift(isActive: isActive)

                        // Insertion indicator above this plate
                        if let drag = stageDrag, drag.insertionIndex == index, drag.stageIndex != index {
                            insertionIndicator(width: plateWidth * scale)
                        }

                        PlateSwiftUIView(
                            plate: plate,
                            selectedWindowIndex: isActive ? viewModel.selectedWindowIndex : nil,
                            thumbnailWidth: tSize.width,
                            thumbnailHeight: tSize.height,
                            appearance: viewModel.appearance,
                            isDropTarget: isDropTarget,
                            windowDrag: $windowDrag,
                            plateFrames: $plateFrames,
                            stageIndex: index,
                            onWindowMoved: onWindowMoved
                        )
                        .frame(width: plateWidth, height: pHeight)
                        .scaleEffect(scale)
                        .frame(width: plateWidth * scale, height: pHeight * scale)
                        .shadow(
                            color: .black.opacity(lift.shadowOpacity),
                            radius: lift.shadowRadius,
                            y: lift.shadowY
                        )
                        .opacity(isStageDragging ? 0.3 : 1.0)
                        .zIndex(isActive ? 1 : 0)
                        .background(
                            GeometryReader { plateGeo in
                                Color.clear.preference(
                                    key: PlateFramePreferenceKey.self,
                                    value: [index: plateGeo.frame(in: .named("overlay"))]
                                )
                            }
                        )
                        .gesture(stageDragGesture(index: index, plate: plate, pHeight: pHeight * inactiveScale + spacing))

                        // Insertion indicator after the last plate
                        if index == plates.count - 1,
                           let drag = stageDrag,
                           drag.insertionIndex == plates.count,
                           drag.stageIndex != plates.count - 1 {
                            insertionIndicator(width: plateWidth * scale)
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .center)
                .offset(y: yOffset)

                if let drag = windowDrag,
                   let plate = plates[safe: drag.sourceStageIndex],
                   let window = plate.windows[safe: drag.sourceWindowIndex] {
                    WindowPreviewView(
                        window: window,
                        isWindowSelected: true,
                        thumbnailWidth: tSize.width,
                        thumbnailHeight: tSize.height,
                        appearance: viewModel.appearance
                    )
                    .opacity(0.85)
                    .scaleEffect(1.05)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .offset(drag.offset)
                    .allowsHitTesting(false)
                }
            }
            .id(focusTransition.usesSpatialMotion ? -1 : viewModel.activeStageIndex)
            .transition(focusTransition.usesSpatialMotion ? .identity : .opacity)
            .animation(focusTransition.animation, value: viewModel.activeStageIndex)
            .coordinateSpace(name: "overlay")
            .onPreferenceChange(PlateFramePreferenceKey.self) { frames in
                plateFrames = frames
            }
        }
    }

    private func stageDragGesture(index: Int, plate: PlateData, pHeight: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named("overlay"))
            .onChanged { value in
                guard windowDrag == nil else { return }
                if stageDrag == nil {
                    guard viewModel.plates.count > 1 else { return }
                    stageDrag = StageDragState(
                        stageIndex: index,
                        stageID: plate.id,
                        offset: value.translation
                    )
                } else {
                    stageDrag?.offset = value.translation
                    stageDrag?.insertionIndex = computeInsertionIndex(
                        draggedIndex: index,
                        yTranslation: value.translation.height,
                        plateHeight: pHeight
                    )
                }
            }
            .onEnded { _ in
                guard let drag = stageDrag else { return }
                if let target = drag.insertionIndex, target != drag.stageIndex {
                    let adjustedTarget = target > drag.stageIndex ? target - 1 : target
                    if adjustedTarget != drag.stageIndex {
                        onStageReordered?(drag.stageIndex, adjustedTarget)
                    }
                }
                stageDrag = nil
            }
    }

    private func computeInsertionIndex(draggedIndex: Int, yTranslation: CGFloat, plateHeight: CGFloat) -> Int {
        let platesMoved = Int(round(yTranslation / plateHeight))
        let rawTarget = draggedIndex + platesMoved
        return max(0, min(rawTarget, viewModel.plates.count))
    }

    @ViewBuilder
    private func insertionIndicator(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: width, height: 2)
            .padding(.vertical, -6)
    }
}

struct PlateSwiftUIView: View {
    let plate: PlateData
    let selectedWindowIndex: Int?
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let appearance: AppSettings
    var isDropTarget: Bool = false
    @Binding var windowDrag: WindowDragState?
    @Binding var plateFrames: [Int: CGRect]
    let stageIndex: Int
    var onWindowMoved: ((CGWindowID, Int, Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PlateConstants.windowSpacing) {
                if plate.windows.isEmpty {
                    Text("Empty")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(plate.windows.enumerated()), id: \.element.id) { index, window in
                        let isDragging = windowDrag?.sourceStageIndex == stageIndex
                            && windowDrag?.sourceWindowIndex == index
                        WindowPreviewView(
                            window: window,
                            isWindowSelected: selectedWindowIndex == index && !isDragging,
                            thumbnailWidth: thumbnailWidth,
                            thumbnailHeight: thumbnailHeight,
                            appearance: appearance
                        )
                        .opacity(isDragging ? 0.3 : 1.0)
                        .gesture(windowDragGesture(window: window, windowIndex: index))
                    }
                }
            }
            .padding(.horizontal, PlateConstants.padding)
            .padding(.top, PlateConstants.topPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(
            isDropTarget
                ? RoundedRectangle(cornerRadius: CGFloat(appearance.plateCornerRadius))
                    .stroke(Color.accentColor, lineWidth: 2)
                : nil
        )
        .modifier(LiquidGlassModifier(
            cornerRadius: CGFloat(appearance.plateCornerRadius),
            appearance: appearance
        ))
    }

    private func windowDragGesture(window: PlateWindowData, windowIndex: Int) -> some Gesture {
        DragGesture(coordinateSpace: .named("overlay"))
            .onChanged { value in
                if windowDrag == nil {
                    windowDrag = WindowDragState(
                        windowID: window.windowID,
                        sourceStageIndex: stageIndex,
                        sourceWindowIndex: windowIndex,
                        offset: value.translation
                    )
                } else {
                    windowDrag?.offset = value.translation
                    windowDrag?.dropTargetStageIndex = dropTargetIndex(at: value.location)
                }
            }
            .onEnded { _ in
                guard let drag = windowDrag else { return }
                if let target = drag.dropTargetStageIndex, target != drag.sourceStageIndex {
                    onWindowMoved?(drag.windowID, drag.sourceStageIndex, target)
                }
                windowDrag = nil
            }
    }

    private func dropTargetIndex(at location: CGPoint) -> Int? {
        for (index, frame) in plateFrames {
            if frame.contains(location) {
                return index
            }
        }
        return nil
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

                AppIconImage(bundleID: window.ownerBundleID, name: window.ownerName, iconSize: PlateConstants.badgeSize)
                    .frame(width: PlateConstants.badgeSize, height: PlateConstants.badgeSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: -4, y: -4)
            }

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

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
