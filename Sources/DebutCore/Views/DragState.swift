import SwiftUI
import CoreGraphics

struct WindowDragState: Equatable {
    let windowID: CGWindowID
    let sourceStageIndex: Int
    let sourceWindowIndex: Int
    var offset: CGSize
    var dropTargetStageIndex: Int?
}

struct StageDragState: Equatable {
    let stageIndex: Int
    let stageID: UUID
    var offset: CGSize
    var insertionIndex: Int?
}

struct PlateFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
