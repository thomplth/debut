import SwiftUI
import CoreGraphics

struct WindowDragState: Equatable {
    let windowID: CGWindowID
    let sourceSpaceIndex: Int
    let sourceWindowIndex: Int
    var location: CGPoint
    var dropTarget: WindowDropTarget?
}

struct WindowDropTarget: Equatable {
    let spaceIndex: Int
    let windowIndex: Int
}

struct WindowMoveRequest: Equatable {
    let windowID: CGWindowID
    let fromSpaceIndex: Int
    let fromWindowIndex: Int
    let toSpaceIndex: Int
    let toWindowIndex: Int
}

struct WindowDropSettlingState {
    let request: WindowMoveRequest
    let window: StageWindowData
    let destination: CGPoint
}

struct WindowLayoutKey: Equatable {
    let spaceWindowIDs: [[CGWindowID]]
}

struct PointerSelection: Equatable {
    let spaceIndex: Int
    let windowIndex: Int
}

struct StageFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct StageSurfaceFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct WindowFrameID: Hashable {
    let spaceIndex: Int
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
