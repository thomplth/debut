import SwiftUI
import CoreGraphics

struct WindowDragState: Equatable {
    let windowID: CGWindowID
    let sourceStageIndex: Int
    let sourceWindowIndex: Int
    var location: CGPoint
    var dropWindowIndex: Int?
}

struct WindowMoveRequest: Equatable {
    let windowID: CGWindowID
    let stageIndex: Int
    let fromWindowIndex: Int
    let toWindowIndex: Int
}

struct WindowDropSettlingState {
    let request: WindowMoveRequest
    let window: PlateWindowData
    let destination: CGPoint
}

struct WindowLayoutKey: Equatable {
    let stageWindowIDs: [[CGWindowID]]
}

/// The held plate travels by slot rather than by pointer offset, so the gesture cannot drift
/// sideways out of the stack and the other plates always have somewhere to sit.
struct StageDragState: Equatable {
    let stageIndex: Int
    let stageID: UUID
    var verticalTranslation: CGFloat
    var destinationIndex: Int
}

struct PointerSelection: Equatable {
    let stageIndex: Int
    let windowIndex: Int
}

struct PlateFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct PlateSurfaceFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct WindowFrameID: Hashable {
    let stageIndex: Int
    let windowIndex: Int
}

struct WindowFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [WindowFrameID: CGRect] = [:]
    static func reduce(
        value: inout [WindowFrameID: CGRect],
        nextValue: () -> [WindowFrameID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
