import AppKit
import CoreGraphics
import Foundation

// Real macOS Spaces as the backing store for stages.
//
// Everything here was validated by measurement on macOS 26.5.2 arm64 with SIP enabled
// (`Tools/space-probe*.swift`). Two findings shape the design:
//
//   1. Every private *write* API that reassigns a window's Space no-ops across process
//      boundaries — SLSMoveWindowsToManagedSpace, CGSAddWindowsToSpaces and
//      SLSSetWindowListWorkspace all move our own windows and refuse foreign ones. So the
//      only reads below are private; the writes go through gestures the user could perform.
//
//   2. Space *creation* is gated too. SLSSpaceCreate returns an id that no display manages,
//      which is why stages map onto desktops the user made in Mission Control rather than
//      onto desktops Debut creates.

typealias CGSConnectionID = Int32
public typealias CGSSpaceID = UInt64

// MARK: - Private symbols

// SkyLight is opened explicitly rather than trusted to be in the process already: dlsym with
// RTLD_DEFAULT only searches *loaded* images, and a probe that skipped this reported every
// symbol missing even though all of them resolve once the framework is linked.
nonisolated(unsafe) private let skyLight: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        ?? UnsafeMutableRawPointer(bitPattern: -2)
}()

private func skyLightSymbol<T>(_ name: String) -> T? {
    dlsym(skyLight, name).map { unsafeBitCast($0, to: T.self) }
}

nonisolated(unsafe) private let cgsMainConnectionID: (@convention(c) () -> CGSConnectionID)? =
    skyLightSymbol("CGSMainConnectionID")
nonisolated(unsafe) private let cgsCopyManagedDisplaySpaces: (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? =
    skyLightSymbol("CGSCopyManagedDisplaySpaces")
nonisolated(unsafe) private let slsCopySpacesForWindows: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?)? =
    skyLightSymbol("SLSCopySpacesForWindows")

/// Selector for `SLSCopySpacesForWindows` meaning "all spaces the window belongs to".
private let kSpaceSelectorAll: Int32 = 7

// Private CGEvent fields carrying DockSwipe gesture parameters. Values transcribed from
// Space Rabbit, which is the working reference for this technique.
let kCGSEventTypeField = CGEventField(rawValue: 55)!
let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
let kCGEventGestureScrollY = CGEventField(rawValue: 119)!
let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
let kCGEventGestureSwipeVelocityY = CGEventField(rawValue: 130)!
let kCGEventGesturePhase = CGEventField(rawValue: 132)!
let kCGEventScrollGestureFlagBits = CGEventField(rawValue: 135)!
let kCGEventGestureZoomDeltaX = CGEventField(rawValue: 139)!

let kCGSEventGesture: Int64 = 29
let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGSGesturePhaseBegan: Int64 = 1
let kCGSGesturePhaseEnded: Int64 = 4
let kGestureMotionHorizontal: Int64 = 1

/// Velocity high enough that the Dock snaps to the next Space instead of animating toward it.
/// The instant snap is the entire reason this app switches Spaces by gesture rather than by
/// the stock shortcut — an animated transition would reintroduce the delay stages are meant
/// to remove.
private let kInstantSwitchVelocity: Double = 400.0
private let kInstantSwitchProgress: Double = 2.0

// MARK: - Plan

enum SpaceSwitchDirection {
    case left
    case right

    var flagBits: Int64 { self == .right ? 1 : 0 }
    var sign: Double { self == .right ? 1 : -1 }
}

/// How to get from one desktop to another: which way, and how far.
///
/// Kept as a value type with no side effects so the arithmetic — which is where an
/// off-by-one would strand the user on the wrong desktop — is testable without a window
/// server.
struct SpaceSwitchPlan: Equatable {
    let direction: SpaceSwitchDirection
    let steps: Int

    /// - Returns: `nil` when there is nothing to do, which includes the case where the
    ///   target is the desktop already showing. A zero-step gesture is not harmless: it
    ///   opens the Dock's gesture state and the Dock resolves the unmatched Began by
    ///   rubber-banding.
    init?(from current: Int, to target: Int, desktopCount: Int) {
        guard desktopCount > 1,
              (0..<desktopCount).contains(current),
              (0..<desktopCount).contains(target),
              current != target
        else { return nil }

        direction = target > current ? .right : .left
        steps = abs(target - current)
    }
}

extension SpaceSwitchDirection: Equatable {}

// MARK: - Gesture events

enum DockSwipePhase {
    case began
    case ended

    var raw: Int64 { self == .began ? kCGSGesturePhaseBegan : kCGSGesturePhaseEnded }
}

enum DockSwipeEvent {

    /// Builds one dock-control event describing a horizontal Space swipe.
    ///
    /// Only the Ended phase carries velocity and progress; that is the phase where the Dock
    /// decides between snapping and animating.
    static func make(phase: DockSwipePhase,
                     direction: SpaceSwitchDirection,
                     velocity: Double = kInstantSwitchVelocity) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }

        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
        event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(kCGEventGesturePhase, value: phase.raw)
        event.setIntegerValueField(kCGEventScrollGestureFlagBits, value: direction.flagBits)
        event.setIntegerValueField(kCGEventGestureSwipeMotion, value: kGestureMotionHorizontal)
        event.setDoubleValueField(kCGEventGestureScrollY, value: 0)

        // The Dock discards a dock-control event whose zoom delta is exactly zero, so this
        // epsilon is what keeps the whole gesture from being ignored.
        event.setDoubleValueField(kCGEventGestureZoomDeltaX,
                                  value: Double(Float.leastNonzeroMagnitude))

        if phase == .ended {
            event.setDoubleValueField(kCGEventGestureSwipeProgress,
                                      value: direction.sign * kInstantSwitchProgress)
            event.setDoubleValueField(kCGEventGestureSwipeVelocityX,
                                      value: direction.sign * velocity)
            event.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
        }
        return event
    }

    /// The envelope event the Dock expects alongside each dock-control event.
    static func makeEnvelope() -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)
        return event
    }

    /// Posts one complete Began+Ended pair. Both phases are built before either is posted,
    /// so an allocation failure cannot leave the Dock holding an unmatched Began.
    @discardableResult
    static func postSwitch(direction: SpaceSwitchDirection, velocity: Double) -> Bool {
        guard let began = make(phase: .began, direction: direction, velocity: 0),
              let beganEnvelope = makeEnvelope(),
              let ended = make(phase: .ended, direction: direction, velocity: velocity),
              let endedEnvelope = makeEnvelope()
        else { return false }

        for (control, envelope) in [(began, beganEnvelope), (ended, endedEnvelope)] {
            control.post(tap: .cgSessionEventTap)
            envelope.post(tap: .cgSessionEventTap)
        }
        return true
    }
}

// MARK: - Service

/// Where stages get their desktops. Kept as a protocol so stage-switching logic can be
/// tested without a window server — nothing else about a Space switch is observable in a
/// unit test.
public protocol SpaceSwitching: AnyObject {
    func desktopCount() -> Int
    func currentDesktopIndex() -> Int?
    func desktopIndex(forWindow windowID: CGWindowID) -> Int?
    @discardableResult func switchToDesktop(index: Int) -> Bool
    func moveWindow(windowID: CGWindowID, titleBar: CGPoint, toDesktop: Int,
                    completion: (@Sendable (Bool) -> Void)?)
}

public extension SpaceSwitching {
    func moveWindow(windowID: CGWindowID, titleBar: CGPoint, toDesktop: Int) {
        moveWindow(windowID: windowID, titleBar: titleBar, toDesktop: toDesktop, completion: nil)
    }
}

// MARK: - Drag

/// Holds a window by its title bar, switches desktop underneath it, and drops it there.
///
/// Every delay here is waiting on another process: the owning app has to notice the drag, and
/// the WindowServer has to finish the desktop transition before the release lands. There is no
/// callback for either, which is why this is a sequence of sleeps rather than event-driven.
enum WindowDrag {
    private static let grabSettle: TimeInterval = 0.12
    private static let dragStep: TimeInterval = 0.05
    private static let chordSettle: TimeInterval = 0.08
    private static let transitionSettle: TimeInterval = 0.55

    static func perform(grab: CGPoint, chords: [SymbolicHotkey]) {
        let source = CGEventSource(stateID: .hidSystemState)
        let restore = CGEvent(source: nil)?.location
        func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }
        func drag(_ dy: CGFloat) {
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                         mouseCursorPosition: CGPoint(x: grab.x, y: grab.y + dy),
                         mouseButton: .left))
        }

        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                     mouseCursorPosition: grab, mouseButton: .left))
        Thread.sleep(forTimeInterval: grabSettle)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                     mouseCursorPosition: grab, mouseButton: .left))
        Thread.sleep(forTimeInterval: grabSettle)

        // A single jump does not read as a drag; the owning app needs a few moves to enter its
        // drag loop, and until it does the window will not follow across the transition.
        for dy in stride(from: CGFloat(4), through: 16, by: 4) {
            drag(dy)
            Thread.sleep(forTimeInterval: dragStep)
        }

        for chord in chords {
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source,
                                    virtualKey: chord.keyCode, keyDown: isDown)
                event?.flags = chord.flags
                post(event)
            }
            Thread.sleep(forTimeInterval: chordSettle)
        }

        Thread.sleep(forTimeInterval: transitionSettle)
        drag(20)
        Thread.sleep(forTimeInterval: dragStep)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                     mouseCursorPosition: CGPoint(x: grab.x, y: grab.y + 20),
                     mouseButton: .left))
        Thread.sleep(forTimeInterval: transitionSettle)

        if let restore { CGWarpMouseCursorPosition(restore) }
    }
}

/// Reads and changes which macOS Space is showing, and which Space a window lives on.
public final class SpaceService: SpaceSwitching {

    private let hotkeys: any SymbolicHotkeyReading

    /// Serialized because a move drives the physical cursor: two at once would interleave
    /// mouse-down and mouse-up events and leave a button stuck down.
    private let moveQueue = DispatchQueue(label: "com.thomplth.debut.space-move")

    public init(hotkeys: any SymbolicHotkeyReading = SymbolicHotkeyDefaults()) {
        self.hotkeys = hotkeys
    }

    public func desktopCount() -> Int { userDesktops().count }

    private var connection: CGSConnectionID? {
        guard let cgsMainConnectionID else { return nil }
        let cid = cgsMainConnectionID()
        return cid == 0 ? nil : cid
    }

    /// macOS 27 rejects bare synthetic dock swipes and requires an augmented
    /// Began+Changed+Ended sequence carrying a packed IOHID payload. That path is not
    /// implemented here because it cannot be exercised on this machine, and shipping a
    /// gesture path no test or probe has ever run is worse than declining to switch.
    public var canSwitchSpaces: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }

    // MARK: Reading

    /// User desktops on the main display, in the order Mission Control shows them.
    ///
    /// Fullscreen and tiled Spaces are excluded — only `type == 0` entries are desktops a
    /// stage can map onto.
    public func userDesktops() -> [CGSSpaceID] {
        guard let connection, let cgsCopyManagedDisplaySpaces,
              let displays = cgsCopyManagedDisplaySpaces(connection, nil)?
                .takeRetainedValue() as? [[String: Any]],
              let main = displays.first,
              let spaces = main["Spaces"] as? [[String: Any]]
        else { return [] }

        return spaces.compactMap { space in
            guard (space["type"] as? NSNumber)?.intValue ?? 0 == 0 else { return nil }
            return (space["id64"] as? NSNumber)?.uint64Value
        }
    }

    public func currentDesktop() -> CGSSpaceID? {
        guard let connection, let cgsCopyManagedDisplaySpaces,
              let displays = cgsCopyManagedDisplaySpaces(connection, nil)?
                .takeRetainedValue() as? [[String: Any]],
              let main = displays.first,
              let current = (main["Current Space"] as? [String: Any])?["id64"] as? NSNumber
        else { return nil }
        return current.uint64Value
    }

    public func currentDesktopIndex() -> Int? {
        guard let current = currentDesktop() else { return nil }
        return Self.index(of: current, in: userDesktops())
    }

    public func spaces(forWindow windowID: CGWindowID) -> [CGSSpaceID] {
        guard let connection, let slsCopySpacesForWindows,
              let result = slsCopySpacesForWindows(connection, kSpaceSelectorAll,
                                                   [NSNumber(value: windowID)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
        else { return [] }
        return result.map { $0.uint64Value }
    }

    /// Which stage a window belongs to, or `nil` when it does not belong to exactly one.
    public func desktopIndex(forWindow windowID: CGWindowID) -> Int? {
        Self.soleIndex(of: spaces(forWindow: windowID), in: userDesktops())
    }

    static func index(of space: CGSSpaceID, in desktops: [CGSSpaceID]) -> Int? {
        desktops.firstIndex(of: space)
    }

    /// The desktop index a window sits on, but only when it sits on exactly one.
    ///
    /// A window assigned to every Space — Finder is, on some systems — would otherwise
    /// resolve to "the first one" and then fight the user each time a stage moved it.
    static func soleIndex(of spaces: [CGSSpaceID], in desktops: [CGSSpaceID]) -> Int? {
        let known = spaces.compactMap { index(of: $0, in: desktops) }
        guard known.count == 1 else { return nil }
        return known[0]
    }

    // MARK: Switching

    /// Switches the visible desktop by forging a high-velocity trackpad swipe.
    ///
    /// Velocity is scaled by the number of steps so a long jump snaps straight to the target
    /// rather than animating through each desktop on the way.
    @discardableResult
    public func switchToDesktop(index target: Int) -> Bool {
        guard canSwitchSpaces else { return false }
        let desktops = userDesktops()
        guard let current = currentDesktopIndex(),
              let plan = SpaceSwitchPlan(from: current, to: target, desktopCount: desktops.count)
        else { return false }

        let velocity = kInstantSwitchVelocity * Double(plan.steps)
        for _ in 0..<plan.steps {
            guard DockSwipeEvent.postSwitch(direction: plan.direction, velocity: velocity) else {
                return false
            }
        }
        return true
    }

    // MARK: Moving

    /// Puts a window on another desktop by dragging it across a desktop switch.
    ///
    /// This cannot reuse the forged gesture that `switchToDesktop` posts: the Dock ignores
    /// those while a mouse drag is held, so the switch has to come from the user's own
    /// keyboard shortcut. That makes the move dependent on bindings Debut does not own, and
    /// `false` here usually means those bindings are turned off rather than that anything
    /// went wrong.
    ///
    /// Runs off the main thread — the drag spends the better part of a second waiting on other
    /// processes, and blocking the main thread for that long would stall the event tap.
    public func moveWindow(windowID: CGWindowID,
                           titleBar: CGPoint,
                           toDesktop target: Int,
                           completion: (@Sendable (Bool) -> Void)? = nil) {
        moveQueue.async { [self] in
            let moved = performMove(windowID: windowID, titleBar: titleBar, toDesktop: target)
            completion?(moved)
        }
    }

    private func performMove(windowID: CGWindowID, titleBar: CGPoint, toDesktop target: Int) -> Bool {
        let desktops = userDesktops()
        guard let origin = Self.soleIndex(of: spaces(forWindow: windowID), in: desktops),
              // A drag can only grab a window that is actually on screen, so the window's own
              // desktop has to be the one showing.
              currentDesktopIndex() == origin,
              let chords = SpaceMoveKeystrokes.plan(
                from: origin,
                to: target,
                desktopCount: desktops.count,
                direct: { [hotkeys] in hotkeys.hotkey(id: SymbolicHotkeyID.directDesktop($0)) },
                step: { [hotkeys] direction in
                    hotkeys.hotkey(id: direction == .right ? SymbolicHotkeyID.moveRight
                                                           : SymbolicHotkeyID.moveLeft)
                })
        else { return false }

        WindowDrag.perform(grab: titleBar, chords: chords)

        // Verified rather than assumed: the drag can be refused by an app that never entered
        // its drag loop, and that failure is silent.
        return Self.soleIndex(of: spaces(forWindow: windowID), in: userDesktops()) == target
    }
}
