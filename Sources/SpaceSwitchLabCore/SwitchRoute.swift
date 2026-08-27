import Foundation

public struct SwitchRoute: Equatable, Sendable {
    public let direction: SwitchDirection
    public let distance: Int

    public init?(from current: Int, to target: Int, desktopCount: Int) {
        guard desktopCount > 1,
              (0..<desktopCount).contains(current),
              (0..<desktopCount).contains(target),
              current != target
        else { return nil }
        direction = target > current ? .right : .left
        distance = abs(target - current)
    }

    public func directions(for scheduling: HopScheduling) -> [SwitchDirection] {
        switch scheduling {
        case .confirmedAdjacent: [direction]
        case .batched: Array(repeating: direction, count: distance)
        }
    }
}
