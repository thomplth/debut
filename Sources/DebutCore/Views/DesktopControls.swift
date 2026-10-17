import SwiftUI

/// Where the overlay stages a new desktop. ⌘N puts it after the selected desktop; the + above
/// the first plate and below the last one put it at that end of the stack.
public enum NewDesktopPosition: Hashable, Sendable {
    case afterSelection
    case top
    case bottom
}

/// Where the desktop controls sit and what they catch, kept apart from the view so tests can
/// measure them without drawing glass.
enum DesktopControlGeometry {
    /// The add button's diameter at the stage's own scale.
    static let addButtonDiameter: CGFloat = 30
    /// The smallest the drag view's + may draw, however far the drag view has shrunk.
    static let minimumDropTargetDiameter: CGFloat = 22
    /// Clearance between the last plate's bottom edge and the add button.
    static let addButtonGap: CGFloat = 10

    /// The band from a plate out to the + hung from it, below the last plate or above the
    /// first. Pointing anywhere in it keeps that plate hovered, so reaching for the button never
    /// shrinks the plate it hangs from and carries the button away from the pointer.
    static func addZone(plate: CGRect?, button: CGRect?) -> CGRect? {
        guard let plate, let button else { return nil }
        let minX = min(plate.minX, button.minX)
        let maxX = max(plate.maxX, button.maxX)
        if button.midY < plate.midY {
            let top = min(button.minY, plate.minY) - 6
            return CGRect(x: minX, y: top, width: maxX - minX, height: plate.minY - top)
        }
        let bottom = max(button.maxY, plate.maxY) + 6
        return CGRect(x: minX, y: plate.maxY, width: maxX - minX, height: bottom - plate.maxY)
    }
}

struct AddDesktopButtonFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [NewDesktopPosition: CGRect] = [:]
    static func reduce(value: inout [NewDesktopPosition: CGRect],
                       nextValue: () -> [NewDesktopPosition: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The + that hangs below the last plate, or above the first, while that plate is hovered. Same
/// glass as the plates, so it reads as part of the stack rather than chrome laid over it.
struct AddDesktopButton: View {
    let position: NewDesktopPosition
    let scale: CGFloat
    let appearance: SwitcherAppearance
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let diameter = DesktopControlGeometry.addButtonDiameter * scale
        Image(systemName: "plus")
            .font(.system(size: 13 * scale, weight: .semibold))
            .foregroundStyle(.primary.opacity(isHovered ? 0.95 : 0.7))
            .frame(width: diameter, height: diameter)
            .modifier(OverlayGlassCapsuleModifier(
                glassStyle: appearance.glassStyle,
                dockGlassStyle: appearance.dockGlassStyle
            ))
            .scaleEffect(isHovered ? 1.08 : 1)
            .contentShape(Circle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isHovered = hovering
                }
            }
            .onTapGesture(perform: action)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AddDesktopButtonFramePreferenceKey.self,
                        value: [position: geometry.frame(in: .named("overlay"))]
                    )
                }
            }
            .accessibilityLabel(position == .top ? "Add desktop at top" : "Add desktop")
            .accessibilityAddTraits(.isButton)
    }
}

/// The + at each end of a held window drag. It opens into an empty plate when the window
/// reaches it, which is the whole of its hint: the drag view adds no outline or label.
struct NewDesktopDropTarget: View {
    /// What one end draws in one compact layout: a + where it is collapsed, the plate where it
    /// is open, nothing once a drop there has made the desktop real.
    struct Shape: Equatable {
        let isExpanded: Bool
        /// The window's placeholder is in the open plate.
        let isTargeted: Bool
        let size: CGSize
        let centerY: CGFloat

        init?(position: NewDesktopPosition, compact: CompactDragSnapshot,
              projection: CompactProjection?, excluding stageIDs: Set<UUID>) {
            if compact.expandedNewDesktop == position, let index = compact.newDesktopStageIndex,
               let stage = compact.stages[safe: index] {
                guard !stageIDs.contains(stage.spaceID) else { return nil }
                isExpanded = true
                isTargeted = projection?.placeholder?.stageIndex == index
                size = CGSize(
                    width: (projection?.plateWidths[safe: index] ?? 0) * compact.scale,
                    height: stage.baseHeight * compact.scale
                )
                centerY = stage.centerY
            } else if let target = compact.newDesktopTargets.first(where: { $0.position == position }) {
                guard !stageIDs.contains(target.spaceID) else { return nil }
                isExpanded = false
                isTargeted = false
                size = CGSize(width: target.diameter, height: target.diameter)
                centerY = target.center.y
            } else {
                return nil
            }
        }
    }

    let shape: Shape
    let cornerRadius: CGFloat
    let appearance: SwitcherAppearance

    var body: some View {
        let diameter = min(shape.size.width, shape.size.height)
        ZStack {
            Color.clear
                .frame(width: shape.size.width, height: shape.size.height)
                .modifier(LiquidGlassModifier(
                    cornerRadius: shape.isExpanded ? cornerRadius : diameter / 2,
                    appearance: appearance
                ))
            Image(systemName: "plus")
                // Sized from the circle, which keeps a legible minimum, not from the drag
                // view's scale, which can shrink the glyph to a speck.
                .font(.system(size: diameter * 13 / DesktopControlGeometry.addButtonDiameter,
                              weight: .semibold))
                .foregroundStyle(.primary.opacity(0.7))
                .opacity(shape.isExpanded ? 0 : 1)
        }
    }
}

/// A held plate, drawn at the drag view's scale under the pointer: the whole plate, cards and
/// glass, as a held card is drawn whole. Merged, its cards line up across the gap they opened
/// while its glass goes, so the hand-off to the real cards there is a swap.
struct HeldPlateView: View {
    let plate: StageData
    let compact: CompactDragSnapshot
    let projection: CompactProjection?
    /// The scale it is laid out at. The drag view's own scale, when that differs, is applied
    /// on top as a transform, so a rescale glides rather than snapping to the new layout.
    let layoutScale: CGFloat
    let settlesIntoGap: Bool
    let appearance: AppSettings
    let switcherAppearance: SwitcherAppearance

    /// The held plate's laid-out size, before the transform to the drag view's scale.
    static func size(compact: CompactDragSnapshot, projection: CompactProjection?,
                     scale: CGFloat) -> CGSize {
        let index = compact.sourceStageIndex
        return CGSize(
            width: (projection?.plateWidths[safe: index] ?? 0) * scale,
            height: (compact.stages[safe: index]?.baseHeight ?? 0) * scale
        )
    }

    var body: some View {
        let index = compact.sourceStageIndex
        let scale = layoutScale
        let size = Self.size(compact: compact, projection: projection, scale: scale)
        let own = projection?.cardOffsets[safe: index] ?? [:]
        let gap = settlesIntoGap ? projection?.placeholder : nil
        let landed = gap.flatMap { projection?.cardOffsets[safe: $0.stageIndex] } ?? [:]
        // Landing in a plate that shrank its cards to take them, they shrink to match.
        let cardScale = scale * (gap.flatMap { projection?.contentScales[safe: $0.stageIndex] } ?? 1)
        ZStack {
            Color.clear
                .frame(width: size.width, height: size.height)
                .modifier(LiquidGlassModifier(
                    cornerRadius: CGFloat(switcherAppearance.stageCornerRadius)
                        * compact.metrics.scaleFactor * scale,
                    appearance: switcherAppearance
                ))
                .opacity(settlesIntoGap ? 0 : 1)
            ForEach(plate.windows, id: \.windowID) { window in
                let offset = gap.flatMap { gap in
                    landed[window.windowID].map {
                        CGPoint(x: $0.x - gap.offset.x, y: $0.y - gap.offset.y)
                    }
                } ?? own[window.windowID] ?? .zero
                WindowPreviewView(
                    window: window,
                    isWindowSelected: false,
                    metrics: compact.metrics
                        .adapted(toContentAspect: window.contentAspect)
                        .scaled(by: cardScale),
                    appearance: appearance
                )
                .position(x: size.width / 2 + offset.x * scale,
                          y: size.height / 2 + offset.y * scale)
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(scale > 0 ? compact.scale / scale : 1)
    }
}

/// A held plate's proxy leaving or joining its resting frame: it is drawn at that frame's size
/// and centre, and moves to the pointer from there. The proxy is placed with `position`, so it
/// fills the overlay; the scale is anchored at the pointer within it.
struct PlatePickupEffect: ViewModifier {
    let scale: CGFloat
    let anchor: UnitPoint
    let offset: CGSize

    func body(content: Content) -> some View {
        content.scaleEffect(scale, anchor: anchor).offset(offset)
    }

    static func transition(from frame: CGRect?, size: CGSize, returns: Bool,
                           pointer: CGPoint, in container: CGSize) -> AnyTransition {
        guard let frame, size.width > 0, size.height > 0,
              container.width > 0, container.height > 0
        else { return .identity }
        let atRest = PlatePickupEffect(
            scale: min(frame.width / size.width, frame.height / size.height),
            anchor: UnitPoint(x: pointer.x / container.width, y: pointer.y / container.height),
            offset: CGSize(width: frame.midX - pointer.x, height: frame.midY - pointer.y)
        )
        let held = PlatePickupEffect(scale: 1, anchor: atRest.anchor, offset: .zero)
        return .asymmetric(
            insertion: .modifier(active: atRest, identity: held),
            removal: returns ? .modifier(active: atRest, identity: held) : .identity
        )
    }
}
