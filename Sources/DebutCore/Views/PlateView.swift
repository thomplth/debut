import AppKit
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

    static func plateScale(
        isSelected: Bool,
        isInteractionTarget: Bool,
        inactiveScale: CGFloat
    ) -> CGFloat {
        isSelected || isInteractionTarget ? 1 : inactiveScale
    }

    static func plateLayoutScale(
        isSelected: Bool,
        inactiveScale: CGFloat
    ) -> CGFloat {
        isSelected ? 1 : inactiveScale
    }

    static func stageHandleExpansion(isRevealed: Bool) -> CGFloat {
        isRevealed ? PlateConstants.stageHandleRevealWidth : 0
    }

    static func windowScale(isSelected: Bool, isDragging: Bool) -> CGFloat {
        if isDragging { return 0.96 }
        return isSelected ? 1.06 : 1
    }
}

enum PlateInteraction {
    static let minimumWindowDragDistance: CGFloat = 6

    static func isStageHandleHotspot(
        locationX: CGFloat,
        isRevealed: Bool
    ) -> Bool {
        let hoverWidth = PlateConstants.stageHandleHoverWidth
            + (isRevealed ? PlateConstants.stageHandleRevealWidth : 0)
        return locationX >= 0 && locationX <= hoverWidth
    }

    static func isWindowClick(
        translation: CGSize,
        minimumDragDistance: CGFloat = minimumWindowDragDistance
    ) -> Bool {
        hypot(translation.width, translation.height) < minimumDragDistance
    }

    static func shouldMoveWindow(fromStageIndex: Int, toStageIndex: Int?) -> Bool {
        guard let toStageIndex else { return false }
        return fromStageIndex != toStageIndex
    }

    static func finishWindowDrag(
        _ windowDrag: inout WindowDragState?
    ) -> WindowMoveRequest? {
        guard let completedDrag = windowDrag else { return nil }
        windowDrag = nil
        guard shouldMoveWindow(
            fromStageIndex: completedDrag.sourceStageIndex,
            toStageIndex: completedDrag.dropTargetStageIndex
        ), let targetStageIndex = completedDrag.dropTargetStageIndex
        else { return nil }
        return WindowMoveRequest(
            windowID: completedDrag.windowID,
            fromStageIndex: completedDrag.sourceStageIndex,
            toStageIndex: targetStageIndex
        )
    }

    static func stageDestination(
        from sourceIndex: Int,
        translation: CGFloat,
        plateStride: CGFloat,
        stageCount: Int
    ) -> Int? {
        guard stageCount > 1,
              (0..<stageCount).contains(sourceIndex),
              plateStride > 0
        else { return nil }
        let moved = Int(round(translation / plateStride))
        let destination = max(0, min(sourceIndex + moved, stageCount - 1))
        return destination == sourceIndex ? nil : destination
    }

    static func pointerSelection(
        current: PointerSelection?,
        target: PointerSelection,
        isHovering: Bool
    ) -> PointerSelection? {
        if isHovering { return target }
        return current == target ? nil : current
    }
}

struct PointerMovementGate {
    private var initialLocation: CGPoint?
    private(set) var hasMoved = false

    init(initialLocation: CGPoint? = nil) {
        self.initialLocation = initialLocation
    }

    mutating func reset(at location: CGPoint) {
        initialLocation = location
        hasMoved = false
    }

    mutating func observe(at location: CGPoint) -> Bool {
        if hasMoved { return true }
        guard let initialLocation else {
            reset(at: location)
            return false
        }
        hasMoved = initialLocation != location
        return hasMoved
    }
}

public struct PlateConstants {
    public static let thumbnailWidth: CGFloat = 160
    public static let thumbnailHeight: CGFloat = 100
    public static let windowSpacing: CGFloat = 12
    public static let padding: CGFloat = 24
    public static let minPlateWidth: CGFloat = 300
    public static let windowCardPadding: CGFloat = 6
    public static let windowTitleWidthAllowance: CGFloat = 8
    public static let topPadding: CGFloat = 24
    public static let bottomPadding: CGFloat = 24
    public static let screenMargin: CGFloat = 80
    public static let badgeSize: CGFloat = 40
    public static let stageSpacing: CGFloat = 34
    public static let commandHintFooterOffset: CGFloat = 24
    public static let stageHandleHoverWidth: CGFloat = 24
    public static let stageHandleRevealWidth: CGFloat = 36

    public static func thumbnailSize(forWindowCount count: Int, screenWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let maxWidth = screenWidth - screenMargin * 2
        let availableForWindowCards = maxWidth - padding * 2
        let maxPerWindow = count > 0
            ? (availableForWindowCards - CGFloat(max(0, count - 1)) * windowSpacing) / CGFloat(count)
                - windowCardExtraWidth
            : thumbnailWidth
        let w = min(thumbnailWidth, max(80, maxPerWindow))
        let h = w * (thumbnailHeight / thumbnailWidth)
        return (w, h)
    }

    public static var windowCardExtraWidth: CGFloat {
        windowTitleWidthAllowance + windowCardPadding * 2
    }

    public static func plateHeight(thumbnailHeight: CGFloat) -> CGFloat {
        topPadding + thumbnailHeight + 16 + bottomPadding
    }

    public static func plateWidth(forWindowCount count: Int, thumbnailWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return minPlateWidth }
        let cardsWidth = CGFloat(count) * (thumbnailWidth + windowCardExtraWidth)
            + CGFloat(count - 1) * windowSpacing
        return cardsWidth + padding * 2
    }

    public static func plateWidths(forWindowCounts counts: [Int], thumbnailWidth: CGFloat) -> [CGFloat] {
        counts.map { plateWidth(forWindowCount: $0, thumbnailWidth: thumbnailWidth) }
    }

    public static func plateCenterY(
        stageIndex: Int,
        stageCount: Int,
        activeStageIndex: Int,
        plateHeight: CGFloat,
        inactiveScale: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat? {
        guard (0..<stageCount).contains(stageIndex),
              (0..<stageCount).contains(activeStageIndex)
        else { return nil }

        let scale: (Int) -> CGFloat = { $0 == activeStageIndex ? 1 : inactiveScale }
        let top: (Int) -> CGFloat = { index in
            (0..<index).reduce(0) { partial, precedingIndex in
                partial + plateHeight * scale(precedingIndex) + stageSpacing
            }
        }
        let yOffset = containerHeight / 2 - top(activeStageIndex) - plateHeight / 2
        return yOffset + top(stageIndex) + plateHeight * scale(stageIndex) / 2
    }
}

public struct OverlaySwiftUIView: View {
    public let viewModel: OverlayViewModel
    public var onWindowSelected: ((Int, Int) -> Void)?
    public var onWindowMoved: ((CGWindowID, Int, Int) -> Void)?
    public var onStageReordered: ((Int, Int) -> Void)?
    public var onStageHandleVisibilityChanged: ((Int, Bool) -> Void)?
    public var onPointerSelectionChanged: ((Int?, Int?) -> Void)?

    @State private var windowDrag: WindowDragState?
    @State private var stageDrag: StageDragState?
    @State private var pointerSelection: PointerSelection?
    @State private var pointerMovementGate: PointerMovementGate
    @State private var plateFrames: [Int: CGRect] = [:]
    @State private var revealedStageHandleIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: OverlayViewModel,
        onWindowSelected: ((Int, Int) -> Void)? = nil,
        onWindowMoved: ((CGWindowID, Int, Int) -> Void)? = nil,
        onStageReordered: ((Int, Int) -> Void)? = nil,
        onStageHandleVisibilityChanged: ((Int, Bool) -> Void)? = nil,
        onPointerSelectionChanged: ((Int?, Int?) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onWindowSelected = onWindowSelected
        self.onWindowMoved = onWindowMoved
        self.onStageReordered = onStageReordered
        self.onStageHandleVisibilityChanged = onStageHandleVisibilityChanged
        self.onPointerSelectionChanged = onPointerSelectionChanged
        _pointerMovementGate = State(
            initialValue: PointerMovementGate(initialLocation: NSEvent.mouseLocation)
        )
    }

    public var body: some View {
        let plates = viewModel.plates
        let maxWindows = plates.map(\.windows.count).max() ?? 0

        GeometryReader { geo in
            let tSize = PlateConstants.thumbnailSize(forWindowCount: maxWindows, screenWidth: geo.size.width)
            let pHeight = PlateConstants.plateHeight(thumbnailHeight: tSize.height)
            let plateWidths = PlateConstants.plateWidths(
                forWindowCounts: plates.map(\.windows.count),
                thumbnailWidth: tSize.width
            )

            let inactiveScale = CGFloat(viewModel.appearance.inactivePlateScale)
            let spacing = PlateConstants.stageSpacing
            let focusTransition = PlateMotion.focusTransition(reduceMotion: reduceMotion)

            let totalBefore = CGFloat(viewModel.activeStageIndex) * (pHeight * inactiveScale + spacing)
            let activeCenter = totalBefore + pHeight / 2
            let yOffset = geo.size.height / 2 - activeCenter

            ZStack {
                VStack(spacing: spacing) {
                    ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                        let plateWidth = plateWidths[index]
                        let isActive = index == viewModel.activeStageIndex
                        let isWindowDropTarget = windowDrag?.dropTargetStageIndex == index
                            && windowDrag?.sourceStageIndex != index
                        let isStageDropTarget = stageDrag?.destinationIndex == index
                        let isStageDragging = stageDrag?.stageIndex == index
                        let isStageHandleRevealed = revealedStageHandleIndex == index
                        let stageHandleExpansion = PlateMotion.stageHandleExpansion(
                            isRevealed: isStageHandleRevealed
                        )
                        let isPointerTarget = pointerSelection?.stageIndex == index
                        let isInteractionTarget = isWindowDropTarget
                            || isStageDropTarget
                            || isStageDragging
                            || isPointerTarget
                        let scale = PlateMotion.plateScale(
                            isSelected: isActive,
                            isInteractionTarget: isInteractionTarget,
                            inactiveScale: inactiveScale
                        )
                        let layoutScale = PlateMotion.plateLayoutScale(
                            isSelected: isActive,
                            inactiveScale: inactiveScale
                        )
                        let lift = PlateMotion.lift(isActive: isActive || isInteractionTarget)
                        let selectedWindowIndex = pointerSelection?.stageIndex == index
                            ? pointerSelection?.windowIndex
                            : (isActive ? viewModel.selectedWindowIndex : nil)
                        let stageNumberHint = CommandHintCatalog.stageNumberHint(
                            stageIndex: index,
                            settings: viewModel.appearance
                        )
                        let footerHints = CommandHintCatalog.plateFooterHints(
                            stageIndex: index,
                            isActive: isActive,
                            hasSelectedWindow: selectedWindowIndex != nil
                                && !plate.windows.isEmpty,
                            settings: viewModel.appearance
                        )

                        PlateSwiftUIView(
                            plate: plate,
                            selectedWindowIndex: selectedWindowIndex,
                            thumbnailWidth: tSize.width,
                            thumbnailHeight: tSize.height,
                            appearance: viewModel.appearance,
                            stageNumberHint: stageNumberHint,
                            footerHints: footerHints,
                            stageHandleExpansion: stageHandleExpansion,
                            isStageHandleRevealed: isStageHandleRevealed,
                            windowDrag: $windowDrag,
                            plateFrames: $plateFrames,
                            stageIndex: index,
                            onPointerSelectionChanged: { selection, isHovering, location in
                                if isHovering && !pointerMovementGate.observe(at: location) {
                                    return
                                }
                                let nextSelection = PlateInteraction.pointerSelection(
                                    current: pointerSelection,
                                    target: selection,
                                    isHovering: isHovering
                                )
                                guard nextSelection != pointerSelection else { return }
                                pointerSelection = nextSelection
                                onPointerSelectionChanged?(
                                    nextSelection?.stageIndex,
                                    nextSelection?.windowIndex
                                )
                            },
                            onWindowSelected: onWindowSelected,
                            onWindowMoved: onWindowMoved,
                            onStageHandleHoverChanged: { isHovering in
                                if isHovering, revealedStageHandleIndex != index {
                                    revealedStageHandleIndex = index
                                    onStageHandleVisibilityChanged?(index, true)
                                } else if revealedStageHandleIndex == index,
                                          stageDrag?.stageIndex != index {
                                    revealedStageHandleIndex = nil
                                    onStageHandleVisibilityChanged?(index, false)
                                }
                            },
                            onStageDragChanged: { translation in
                                updateStageDrag(
                                    index: index,
                                    plate: plate,
                                    translation: translation,
                                    plateStride: pHeight * inactiveScale + spacing
                                )
                            },
                            onStageDragEnded: {
                                finishStageDrag()
                                if revealedStageHandleIndex == index {
                                    revealedStageHandleIndex = nil
                                    onStageHandleVisibilityChanged?(index, false)
                                }
                            }
                        )
                        .frame(width: plateWidth + stageHandleExpansion, height: pHeight)
                        .offset(x: -stageHandleExpansion / 2)
                        .frame(width: plateWidth, height: pHeight)
                        .scaleEffect(scale)
                        .frame(
                            width: plateWidth * layoutScale,
                            height: pHeight * layoutScale
                        )
                        .shadow(
                            color: .black.opacity(lift.shadowOpacity),
                            radius: lift.shadowRadius,
                            y: lift.shadowY
                        )
                        .opacity(isStageDragging ? 0.78 : 1.0)
                        .offset(isStageDragging ? (stageDrag?.offset ?? .zero) : .zero)
                        .zIndex(isStageDragging ? 3 : (isActive || isInteractionTarget ? 2 : 0))
                        .background(
                            GeometryReader { plateGeo in
                                Color.clear.preference(
                                    key: PlateFramePreferenceKey.self,
                                    value: [index: plateGeo.frame(in: .named("overlay"))]
                                )
                            }
                        )
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
                    .scaleEffect(1.08)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .position(drag.location)
                    .allowsHitTesting(false)
                }
            }
            .id(focusTransition.usesSpatialMotion ? -1 : viewModel.activeStageIndex)
            .transition(focusTransition.usesSpatialMotion ? .identity : .opacity)
            .animation(focusTransition.animation, value: viewModel.activeStageIndex)
            .animation(focusTransition.animation, value: pointerSelection)
            .animation(focusTransition.animation, value: windowDrag?.dropTargetStageIndex)
            .animation(focusTransition.animation, value: stageDrag?.destinationIndex)
            .coordinateSpace(name: "overlay")
            .onPreferenceChange(PlateFramePreferenceKey.self) { frames in
                plateFrames = frames
            }
        }
    }

    private func updateStageDrag(
        index: Int,
        plate: PlateData,
        translation: CGSize,
        plateStride: CGFloat
    ) {
        guard windowDrag == nil else { return }
        let destination = PlateInteraction.stageDestination(
            from: index,
            translation: translation.height,
            plateStride: plateStride,
            stageCount: viewModel.plates.count
        )
        if stageDrag == nil {
            guard viewModel.plates.count > 1 else { return }
            stageDrag = StageDragState(
                stageIndex: index,
                stageID: plate.id,
                offset: translation,
                destinationIndex: destination
            )
        } else {
            stageDrag?.offset = translation
            stageDrag?.destinationIndex = destination
        }
    }

    private func finishStageDrag() {
        guard let drag = stageDrag else { return }
        stageDrag = nil
        if let destination = drag.destinationIndex {
            onStageReordered?(drag.stageIndex, destination)
        }
    }
}

struct PlateSwiftUIView: View {
    let plate: PlateData
    let selectedWindowIndex: Int?
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let appearance: AppSettings
    let stageNumberHint: CommandHintPresentation?
    let footerHints: [CommandHintPresentation]
    let stageHandleExpansion: CGFloat
    let isStageHandleRevealed: Bool
    @Binding var windowDrag: WindowDragState?
    @Binding var plateFrames: [Int: CGRect]
    let stageIndex: Int
    var onPointerSelectionChanged: ((PointerSelection, Bool, CGPoint) -> Void)?
    var onWindowSelected: ((Int, Int) -> Void)?
    var onWindowMoved: ((CGWindowID, Int, Int) -> Void)?
    var onStageHandleHoverChanged: ((Bool) -> Void)?
    var onStageDragChanged: ((CGSize) -> Void)?
    var onStageDragEnded: (() -> Void)?

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
                            isWindowSelected: selectedWindowIndex == index,
                            isDragging: isDragging,
                            thumbnailWidth: thumbnailWidth,
                            thumbnailHeight: thumbnailHeight,
                            appearance: appearance,
                            commandHints: CommandHintCatalog.windowHints(
                                windowIndex: index,
                                selectedWindowIndex: selectedWindowIndex ?? -1,
                                windowCount: plate.windows.count,
                                settings: appearance
                            )
                        )
                        .opacity(isDragging ? 0.3 : 1.0)
                        .onContinuousHover { phase in
                            let selection = PointerSelection(
                                stageIndex: stageIndex,
                                windowIndex: index
                            )
                            switch phase {
                            case .active:
                                onPointerSelectionChanged?(
                                    selection,
                                    true,
                                    NSEvent.mouseLocation
                                )
                            case .ended:
                                onPointerSelectionChanged?(
                                    selection,
                                    false,
                                    NSEvent.mouseLocation
                                )
                            }
                        }
                        .highPriorityGesture(windowDragGesture(window: window, windowIndex: index))
                    }
                }
            }
            .padding(.leading, PlateConstants.padding + stageHandleExpansion)
            .padding(.trailing, PlateConstants.padding)
            .padding(.top, PlateConstants.topPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(LiquidGlassModifier(
            cornerRadius: CGFloat(appearance.plateCornerRadius),
            appearance: appearance
        ))
        .overlay(alignment: .leading) {
            if isStageHandleRevealed {
                StageDragHandle()
                    .frame(width: PlateConstants.stageHandleRevealWidth)
                    .contentShape(Rectangle())
                    .gesture(stageHandleDragGesture)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .leading) {
            if let stageNumberHint {
                CommandHintStrip(hints: [stageNumberHint])
                    .offset(x: -18)
            }
        }
        .overlay(alignment: .bottom) {
            if !footerHints.isEmpty {
                CommandHintStrip(hints: footerHints)
                    .offset(y: PlateConstants.commandHintFooterOffset)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                onStageHandleHoverChanged?(
                    PlateInteraction.isStageHandleHotspot(
                        locationX: location.x,
                        isRevealed: isStageHandleRevealed
                    )
                )
            case .ended:
                onStageHandleHoverChanged?(false)
            }
        }
        .animation(.easeOut(duration: 0.14), value: isStageHandleRevealed)
    }

    private var stageHandleDragGesture: some Gesture {
        DragGesture(coordinateSpace: .named("overlay"))
            .onChanged { value in
                onStageDragChanged?(value.translation)
            }
            .onEnded { _ in
                onStageDragEnded?()
            }
    }

    private func windowDragGesture(window: PlateWindowData, windowIndex: Int) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named("overlay")
        )
            .onChanged { value in
                guard !PlateInteraction.isWindowClick(translation: value.translation) else {
                    return
                }
                if windowDrag == nil {
                    windowDrag = WindowDragState(
                        windowID: window.windowID,
                        sourceStageIndex: stageIndex,
                        sourceWindowIndex: windowIndex,
                        location: value.location,
                        dropTargetStageIndex: dropTargetIndex(at: value.location)
                    )
                } else {
                    windowDrag?.location = value.location
                    windowDrag?.dropTargetStageIndex = dropTargetIndex(at: value.location)
                }
            }
            .onEnded { value in
                if PlateInteraction.isWindowClick(translation: value.translation) {
                    onWindowSelected?(stageIndex, windowIndex)
                    return
                }
                guard let request = PlateInteraction.finishWindowDrag(&windowDrag) else {
                    return
                }
                onWindowMoved?(
                    request.windowID,
                    request.fromStageIndex,
                    request.toStageIndex
                )
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

private struct StageDragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.8))
            .frame(maxHeight: .infinity)
            .help("Drag to reorder stage")
            .accessibilityLabel("Reorder stage")
    }
}

struct WindowPreviewView: View {
    let window: PlateWindowData
    let isWindowSelected: Bool
    var isDragging: Bool = false
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    let appearance: AppSettings
    var commandHints: [CommandHintPresentation] = []

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
                .overlay(alignment: .bottomTrailing) {
                    if !commandHints.isEmpty {
                        CommandHintStrip(hints: commandHints)
                            .padding(6)
                    }
                }

                AppIconImage(bundleID: window.ownerBundleID, name: window.ownerName, iconSize: PlateConstants.badgeSize)
                    .frame(width: PlateConstants.badgeSize, height: PlateConstants.badgeSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: -4, y: -4)
            }

            Text(window.windowTitle.isEmpty ? window.ownerName : window.windowTitle)
                .font(.system(size: max(9, thumbnailWidth * 0.065)))
                .foregroundStyle(isWindowSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: thumbnailWidth + PlateConstants.windowTitleWidthAllowance)
        }
        .padding(PlateConstants.windowCardPadding)
        .scaleEffect(PlateMotion.windowScale(isSelected: isWindowSelected, isDragging: isDragging))
        .shadow(
            color: .black.opacity(isWindowSelected && !isDragging ? 0.24 : 0),
            radius: isWindowSelected ? 8 : 0,
            y: isWindowSelected ? 4 : 0
        )
        .animation(.spring(duration: 0.18, bounce: 0.08), value: isWindowSelected)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }
}

struct CommandHintStrip: View {
    let hints: [CommandHintPresentation]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(hints) { hint in
                HStack(spacing: 3) {
                    if let iconSystemName = hint.iconSystemName {
                        Image(systemName: iconSystemName)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    Text(hint.shortcut)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay {
                        Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5)
                    }
                    .help("\(hint.label): \(hint.shortcut)")
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hints.map { "\($0.label), \($0.shortcut)" }.joined(separator: "; ")
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
