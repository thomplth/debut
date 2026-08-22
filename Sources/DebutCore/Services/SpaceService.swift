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

// Private CGEvent fields carrying DockSwipe gesture parameters.
//
// Switching a Space by forging a synthetic DockSwipe is not Debut's discovery. With thanks to:
//
//   - InstantSpaceSwitcher — https://github.com/jurplel/InstantSpaceSwitcher
//     The original technique, and the source of the velocity presets that showed where the
//     Dock stops animating and starts cutting.
//   - Space Rabbit — https://github.com/Tahul/space-rabbit
//     The working reference these field numbers are transcribed from, and the source of the
//     driven-progress pattern `DockSwipeAnimation` below is modelled on: post Began, then
//     feed the Dock timed Changed samples, then End. Space Rabbit drives progress that way
//     on the Mission Control axis; Debut applies it to the horizontal one so its switch
//     setting can be a duration rather than an opaque speed.
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
let kCGSGesturePhaseChanged: Int64 = 2
let kCGSGesturePhaseEnded: Int64 = 4
let kGestureMotionHorizontal: Int64 = 1

private let kInstantSwitchProgress: Double = 2.0
/// Only used when the switch duration is zero. Far above the band in which the Dock draws a
/// transition at all, which is exactly the point: the desktop cuts rather than slides.
private let kInstantSwitchVelocity: Double = 400
/// Released at the end of a driven slide, where progress has already reached the target and
/// the velocity only has to be enough to commit rather than rubber-band.
private let kAnimatedReleaseVelocity: Double = 60

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

    /// Scaled by distance: at single-step velocity a two-desktop jump animates through the
    /// desktop in between, which is the delay the gesture path exists to avoid.
    func velocity(base: Double) -> Double { base * Double(steps) }
}

extension SpaceSwitchDirection: Equatable {}

// MARK: - Gesture events

enum DockSwipePhase {
    case began
    case changed
    case ended

    var raw: Int64 {
        switch self {
        case .began: kCGSGesturePhaseBegan
        case .changed: kCGSGesturePhaseChanged
        case .ended: kCGSGesturePhaseEnded
        }
    }
}

/// One frame of a driven swipe: how far into the gesture it is, and how far the desktop has
/// travelled by then. Distances are unsigned; the direction is applied when the event is built.
struct DockSwipeSample {
    let delay: TimeInterval
    let progress: Double
}

/// The progress schedule Debut shows the Dock to make a switch take a chosen length of time.
///
/// Without this, a switch is a Began+Ended pair and the Dock alone decides how long the
/// transition takes — which for any velocity much above 80 is "no transition at all". Driving
/// progress on a timer is what lets the setting be a duration in milliseconds instead of an
/// opaque speed scalar that looked identical at every value.
enum DockSwipeAnimation {

    /// One sample per display frame. Finer sampling only posts events the Dock coalesces.
    static let sampleRate: Double = 120

    /// Samples for a single desktop of travel, easing out so the slide settles rather than
    /// stopping dead. Empty for a non-positive duration, which is the instant path.
    static func samples(duration: TimeInterval,
                        sampleRate: Double = sampleRate) -> [DockSwipeSample] {
        guard duration > 0, sampleRate > 0 else { return [] }

        // Two samples minimum: one point is a flick, not a drag.
        let count = max(2, Int((duration * sampleRate).rounded()))
        return (1...count).map { step in
            let fraction = Double(step) / Double(count)
            return DockSwipeSample(delay: duration * fraction,
                                   progress: 1 - pow(1 - fraction, 3))
        }
    }
}

enum DockSwipeEvent {

    /// Builds one dock-control event describing a horizontal Space swipe.
    ///
    /// Only the Ended phase carries velocity and progress; that is the phase where the Dock
    /// decides between snapping and animating.
    static func make(phase: DockSwipePhase,
                     direction: SpaceSwitchDirection,
                     velocity: Double = kInstantSwitchVelocity,
                     progress: Double = kInstantSwitchProgress) -> CGEvent? {
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

        switch phase {
        case .began:
            break
        case .changed:
            // No velocity: a driven slide is a finger still on the glass, and the Dock only
            // reads velocity when deciding what to do with the release.
            event.setDoubleValueField(kCGEventGestureSwipeProgress,
                                      value: direction.sign * progress)
        case .ended:
            event.setDoubleValueField(kCGEventGestureSwipeProgress,
                                      value: direction.sign * progress)
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

    /// Posts one hop as a gesture whose progress Debut drives across `samples`, so the slide
    /// takes as long as the samples say rather than as long as the Dock feels like.
    ///
    /// Blocks for the length of the animation, so it belongs off the main thread. `isCancelled`
    /// is consulted between samples; a cancelled slide still Ends, because abandoning an open
    /// gesture leaves the Dock rubber-banding on its own.
    @discardableResult
    static func postDrivenSwitch(direction: SpaceSwitchDirection,
                                 samples: [DockSwipeSample],
                                 isCancelled: () -> Bool = { false }) -> Bool {
        guard let began = make(phase: .began, direction: direction, velocity: 0),
              let beganEnvelope = makeEnvelope(),
              let ended = make(phase: .ended, direction: direction,
                               velocity: kAnimatedReleaseVelocity, progress: 1),
              let endedEnvelope = makeEnvelope()
        else { return false }

        let start = DispatchTime.now()
        began.post(tap: .cgSessionEventTap)
        beganEnvelope.post(tap: .cgSessionEventTap)

        for sample in samples.dropLast() {
            guard !isCancelled() else { break }
            wait(untilElapsed: sample.delay, since: start)
            guard let changed = make(phase: .changed, direction: direction,
                                     progress: sample.progress),
                  let envelope = makeEnvelope()
            else { continue }
            changed.post(tap: .cgSessionEventTap)
            envelope.post(tap: .cgSessionEventTap)
        }

        if !isCancelled(), let last = samples.last {
            wait(untilElapsed: last.delay, since: start)
        }
        ended.post(tap: .cgSessionEventTap)
        endedEnvelope.post(tap: .cgSessionEventTap)
        return true
    }

    /// Sleeps until `elapsed` has passed since `start`, measured against the monotonic clock
    /// so posting cost is absorbed rather than accumulated across samples.
    private static func wait(untilElapsed elapsed: TimeInterval, since start: DispatchTime) {
        let target = start.uptimeNanoseconds + UInt64(max(0, elapsed) * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        guard target > now else { return }
        Thread.sleep(forTimeInterval: Double(target - now) / 1_000_000_000)
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
    /// Declared here, not only in the extension, so a conformer's faster batch
    /// implementation is reached through an `any SpaceSwitching` too.
    func desktopIndexes(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: Int]
    @discardableResult func switchToDesktop(index: Int) -> Bool
    /// Whether this conformer can reassign a window's desktop at all. False means the move
    /// commands should stay inert rather than mutate the model and lie about the result.
    var canMoveWindows: Bool { get }
    func moveWindow(windowID: CGWindowID, toDesktop: Int,
                    completion: (@Sendable (Bool) -> Void)?)
}

public extension SpaceSwitching {
    func moveWindow(windowID: CGWindowID, toDesktop: Int) {
        moveWindow(windowID: windowID, toDesktop: toDesktop, completion: nil)
    }

    /// Desktop indexes for many windows at once. Windows with no single desktop are
    /// absent from the result; callers read absence as "macOS did not answer".
    func desktopIndexes(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: Int] {
        windowIDs.reduce(into: [:]) { result, windowID in
            result[windowID] = desktopIndex(forWindow: windowID)
        }
    }
}

/// Reads and changes which macOS Space is showing, and which Space a window lives on.
public final class SpaceService: SpaceSwitching {

    /// How long one desktop of travel takes. Clamped here rather than only at the slider,
    /// because a settings file edited by hand could otherwise schedule samples into the past.
    public var switchDuration: TimeInterval = AppSettings.defaultSpaceSwitchDuration {
        didSet {
            switchDuration = min(
                max(switchDuration, AppSettings.minimumSpaceSwitchDuration),
                AppSettings.maximumSpaceSwitchDuration
            )
        }
    }

    /// A driven slide blocks for its whole duration, and the main thread runs the event tap.
    private let switchQueue = DispatchQueue(label: "com.thomplth.debut.space-switch")

    /// Identifies the switch currently being drawn, so a newer one can cut it short instead
    /// of queueing behind it — otherwise a quick run through several stages plays every
    /// intermediate slide in full.
    private let generationLock = NSLock()
    private var switchGeneration = 0

    /// Confirming a move means re-reading the assignment until the window server catches up.
    /// That settles in single-digit milliseconds, but it is still a wait, and the main thread
    /// runs the event tap.
    private let moveQueue = DispatchQueue(label: "com.thomplth.debut.space-move")

    public init() {}

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

    /// `SLSCopySpacesForWindows` returns a flat space list with no per-window attribution,
    /// so windows are still resolved one at a time. What this avoids is the copy of the
    /// whole display topology that `userDesktops()` makes on every single lookup.
    public func desktopIndexes(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: Int] {
        let desktops = userDesktops()
        guard !desktops.isEmpty else { return [:] }
        return windowIDs.reduce(into: [:]) { result, windowID in
            result[windowID] = Self.soleIndex(of: spaces(forWindow: windowID), in: desktops)
        }
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

    /// Switches the visible desktop by forging a trackpad swipe.
    ///
    /// At a zero duration this is a single high-velocity flick per hop, which the Dock
    /// resolves by cutting straight to the target. At any other duration Debut drives the
    /// gesture's progress itself, and the switch takes `switchDuration` per desktop crossed.
    ///
    /// Returns whether the switch was started. A driven slide runs off the main thread, so
    /// the desktop has not changed by the time this returns — callers wanting the new desktop
    /// wait for `activeSpaceDidChangeNotification`, which they must do regardless.
    @discardableResult
    public func switchToDesktop(index target: Int) -> Bool {
        guard canSwitchSpaces else { return false }
        let desktops = userDesktops()
        guard let current = currentDesktopIndex(),
              let plan = SpaceSwitchPlan(from: current, to: target, desktopCount: desktops.count)
        else { return false }

        let samples = DockSwipeAnimation.samples(duration: switchDuration)
        guard !samples.isEmpty else {
            let velocity = plan.velocity(base: kInstantSwitchVelocity)
            for _ in 0..<plan.steps {
                guard DockSwipeEvent.postSwitch(direction: plan.direction,
                                                velocity: velocity) else { return false }
            }
            return true
        }

        // Progress saturates at one desktop per gesture, so a multi-desktop jump is that many
        // driven hops rather than one gesture ramped further.
        let generation = beginSwitch()
        switchQueue.async { [self] in
            for _ in 0..<plan.steps {
                guard isCurrentSwitch(generation) else { return }
                DockSwipeEvent.postDrivenSwitch(direction: plan.direction, samples: samples) {
                    !isCurrentSwitch(generation)
                }
            }
        }
        return true
    }

    private func beginSwitch() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        switchGeneration += 1
        return switchGeneration
    }

    private func isCurrentSwitch(_ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return switchGeneration == generation
    }

    // MARK: Moving

    public var canMoveWindows: Bool { BridgedWindowManagement.isAvailable }

    /// Puts a window on the desktop at `target`.
    ///
    /// The window does not have to be on the showing desktop, and nothing about the user's
    /// session moves: this is a reassignment in the window server, not a simulated drag.
    ///
    /// Dispatching is immediate but landing is not, so `completion` runs once the new
    /// assignment has been read back. That confirmation is what runs off the main thread —
    /// it is only a few milliseconds, but the main thread runs the event tap.
    public func moveWindow(windowID: CGWindowID,
                           toDesktop target: Int,
                           completion: (@Sendable (Bool) -> Void)? = nil) {
        let desktops = userDesktops()
        guard desktops.indices.contains(target),
              BridgedWindowManagement.moveWindows([windowID], toSpace: desktops[target])
        else {
            completion?(false)
            return
        }
        guard let completion else { return }
        moveQueue.async { [self] in
            completion(waitForWindow(windowID, toReachSpace: desktops[target]))
        }
    }

    /// Polls the window server until `windowID` reports `space`.
    ///
    /// There is no notification for this, and the operation is asynchronous, so a caller that
    /// wants to know whether the move landed has to look. The wait is bounded because a
    /// refused move never arrives and would otherwise hang the caller forever.
    func waitForWindow(_ windowID: CGWindowID,
                       toReachSpace space: CGSSpaceID,
                       timeout: TimeInterval = 0.25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if spaces(forWindow: windowID) == [space] { return true }
            usleep(1000)
        } while Date() < deadline
        return false
    }
}
