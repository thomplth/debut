import SwiftUI
import CoreGraphics

struct WindowDragState: Equatable {
    let windowID: CGWindowID
    let sourceStageIndex: Int
    let sourceWindowIndex: Int
    var location: CGPoint
    var dropTargetStageIndex: Int?
}

struct WindowMoveRequest: Equatable {
    let windowID: CGWindowID
    let fromStageIndex: Int
    let toStageIndex: Int
}

struct StageDragState: Equatable {
    let stageIndex: Int
    let stageID: UUID
    var offset: CGSize
    var destinationIndex: Int?
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
