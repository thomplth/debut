import CoreGraphics
import Foundation

private enum GestureFields {
    static let eventType = CGEventField(rawValue: 55)!
    static let hidType = CGEventField(rawValue: 110)!
    static let scrollY = CGEventField(rawValue: 119)!
    static let swipeMotion = CGEventField(rawValue: 123)!
    static let progress = CGEventField(rawValue: 124)!
    static let velocityX = CGEventField(rawValue: 129)!
    static let velocityY = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!
    static let directionFlag = CGEventField(rawValue: 135)!
    static let zoomDeltaX = CGEventField(rawValue: 139)!
}

public enum DockGesturePoster {
    private static let dockControl: Int64 = 30
    private static let genericGesture: Int64 = 29
    private static let dockSwipe: Int64 = 23
    private static let horizontalMotion: Int64 = 1

    /// Posts one complete recipe synchronously. Timed recipes block only the caller, so the
    /// app runs this off the main thread. All events are allocated before Began is posted.
    @discardableResult
    public static func post(
        recipe unsanitizedRecipe: GestureRecipe,
        direction: SwitchDirection,
        distance: Int,
        location: CGPoint?
    ) -> Bool {
        let recipe = unsanitizedRecipe.sanitized()
        let frames = recipe.frames(direction: direction, distance: distance)
        let controls = frames.compactMap { makeControl(frame: $0, recipe: recipe, direction: direction, location: location) }
        guard controls.count == frames.count else { return false }

        let envelopes: [CGEvent]
        if recipe.includeEnvelope {
            envelopes = frames.compactMap { _ in makeEnvelope(location: location) }
            guard envelopes.count == frames.count else { return false }
        } else {
            envelopes = []
        }

        let start = DispatchTime.now().uptimeNanoseconds
        for index in frames.indices {
            wait(untilMilliseconds: frames[index].delayMilliseconds, since: start)
            controls[index].post(tap: .cgSessionEventTap)
            if recipe.includeEnvelope {
                envelopes[index].post(tap: .cgSessionEventTap)
            }
        }
        return true
    }

    private static func makeControl(
        frame: GestureFrame,
        recipe: GestureRecipe,
        direction: SwitchDirection,
        location: CGPoint?
    ) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        if let location { event.location = location }
        event.setIntegerValueField(GestureFields.eventType, value: dockControl)
        event.setIntegerValueField(GestureFields.hidType, value: dockSwipe)
        event.setIntegerValueField(GestureFields.phase, value: frame.phase.rawValueForEvent)
        if recipe.includeHorizontalMotion {
            event.setIntegerValueField(GestureFields.swipeMotion, value: horizontalMotion)
        }
        if recipe.includeScrollY {
            event.setDoubleValueField(GestureFields.scrollY, value: 0)
        }
        if recipe.includeDirectionFlag {
            event.setIntegerValueField(GestureFields.directionFlag, value: direction.flagBits)
        }
        if recipe.includeZoomEpsilon {
            event.setDoubleValueField(
                GestureFields.zoomDeltaX,
                value: Double(Float.leastNonzeroMagnitude)
            )
        }
        if frame.progress != 0 {
            event.setDoubleValueField(GestureFields.progress, value: frame.progress)
        }
        if frame.velocityX != 0 {
            event.setDoubleValueField(GestureFields.velocityX, value: frame.velocityX)
        }
        if recipe.yVelocity == .matchX || frame.velocityY != 0 {
            event.setDoubleValueField(GestureFields.velocityY, value: frame.velocityY)
        }
        return event
    }

    private static func makeEnvelope(location: CGPoint?) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        if let location { event.location = location }
        event.setIntegerValueField(GestureFields.eventType, value: genericGesture)
        return event
    }

    private static func wait(untilMilliseconds milliseconds: Double, since start: UInt64) {
        let target = start + UInt64(max(0, milliseconds) * 1_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        guard target > now else { return }
        Thread.sleep(forTimeInterval: Double(target - now) / 1_000_000_000)
    }
}
