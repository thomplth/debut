import CoreGraphics
import Foundation

/// Tracks the viewport part of a window drag separately from its prospective drop location.
struct DragScrollState: Equatable {
    private(set) var stackOffset: CGFloat
    private(set) var edge: SpaceStackEdge?
    private(set) var edgeEnteredAt: TimeInterval?
    private(set) var showsEarlierSpaces: Bool
    private(set) var showsLaterSpaces: Bool

    private(set) var stackHeight: CGFloat
    let viewportHeight: CGFloat
    let edgeRegion: CGFloat
    let dwell: TimeInterval
    let contentInset: CGFloat
    private var pointerY: CGFloat?
    private var lastUpdateAt: TimeInterval?

    private static let maximumTickDuration: TimeInterval = 1.0 / 30.0
    private static let minimumSpeed: CGFloat = 80
    private static let maximumSpeed: CGFloat = 480

    init(
        stackOffset: CGFloat,
        stackHeight: CGFloat,
        viewportHeight: CGFloat,
        edgeRegion: CGFloat = 56,
        dwell: TimeInterval = 0.25,
        contentInset: CGFloat = 12
    ) {
        self.stackOffset = stackOffset
        self.stackHeight = stackHeight
        self.viewportHeight = viewportHeight
        self.edgeRegion = edgeRegion
        self.dwell = dwell
        self.contentInset = contentInset
        self.showsEarlierSpaces = stackOffset < contentInset
        self.showsLaterSpaces = stackOffset + stackHeight > viewportHeight - contentInset
    }

    mutating func updatePointer(y: CGFloat, now: TimeInterval) {
        let target: SpaceStackEdge?
        if y <= edgeRegion, showsEarlierSpaces {
            target = .top
        } else if y >= viewportHeight - edgeRegion,
                  showsLaterSpaces {
            target = .bottom
        } else {
            target = nil
        }

        pointerY = y
        guard target != edge else { return }
        edge = target
        edgeEnteredAt = target == nil ? nil : now
        lastUpdateAt = target == nil ? nil : now
    }

    /// Advances at a bounded rate using injected monotonic time, including while the pointer is still.
    mutating func advance(now: TimeInterval) -> CGFloat {
        guard let edge, let edgeEnteredAt, let pointerY else { return stackOffset }

        guard now - edgeEnteredAt >= dwell,
              let lastUpdateAt,
              now > lastUpdateAt
        else {
            self.lastUpdateAt = now
            return stackOffset
        }

        let penetration: CGFloat
        switch edge {
        case .top:
            penetration = min(1, max(0, 1 - pointerY / edgeRegion))
        case .bottom:
            penetration = min(1, max(0, 1 - (viewportHeight - pointerY) / edgeRegion))
        }
        let speed = Self.minimumSpeed
            + (Self.maximumSpeed - Self.minimumSpeed) * penetration * penetration
        let elapsed = min(now - lastUpdateAt, Self.maximumTickDuration)
        let distance = speed * CGFloat(elapsed)

        switch edge {
        case .top:
            stackOffset = min(contentInset, stackOffset + distance)
            showsEarlierSpaces = stackOffset < contentInset
        case .bottom:
            let bottomLimit = viewportHeight - contentInset - stackHeight
            stackOffset = max(bottomLimit, stackOffset - distance)
            showsLaterSpaces = stackOffset + stackHeight > viewportHeight - contentInset
        }

        if (edge == .top && !showsEarlierSpaces)
            || (edge == .bottom && !showsLaterSpaces) {
            self.edge = nil
            self.edgeEnteredAt = nil
            self.lastUpdateAt = nil
        } else {
            self.lastUpdateAt = now
        }
        return stackOffset
    }

    mutating func stop() {
        edge = nil
        edgeEnteredAt = nil
        lastUpdateAt = nil
        pointerY = nil
    }

    func isNavigationBand(y: CGFloat) -> Bool {
        (showsEarlierSpaces && y <= edgeRegion)
            || (showsLaterSpaces && y >= viewportHeight - edgeRegion)
    }

    mutating func updateStackHeight(_ height: CGFloat) {
        stackHeight = height
        showsEarlierSpaces = stackOffset < contentInset
        showsLaterSpaces = stackOffset + stackHeight > viewportHeight - contentInset
        if (edge == .top && !showsEarlierSpaces) || (edge == .bottom && !showsLaterSpaces) {
            stop()
        }
    }
}

struct DragScrollTaskID: Equatable {
    let sessionID: UUID
    let edge: SpaceStackEdge
}
