import AppKit
import CoreGraphics
import Foundation

// Real macOS Spaces as the backing store for stages.
//
// Everything here was validated by measurement on macOS 26.5.2 arm64 with SIP enabled.
// Two findings shape the design:
//
//   1. The ordinary private *write* APIs that reassign a window's Space no-op across process
//      boundaries. Window reassignment therefore goes through BridgedWindowManagement; the
//      private symbols in this file are reads, while desktop switching uses Dock gestures.
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

private let cgsMainConnectionID: (@convention(c) () -> CGSConnectionID)? =
    skyLightSymbol("CGSMainConnectionID")
private let cgsCopyManagedDisplaySpaces: (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? =
    skyLightSymbol("CGSCopyManagedDisplaySpaces")
private let slsCopySpacesForWindows: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?)? =
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
}

extension SpaceSwitchDirection: Equatable {}

/// One adjacent, fully addressable desktop transition.
///
/// A far target is deliberately not represented as one large gesture. Dock owns an
/// asynchronous state machine, so Debut confirms this hop before planning another one.
struct SpaceSwitchHop: Equatable {
    let stackID: String
    let fromDesktopID: CGSSpaceID
    let toDesktopID: CGSSpaceID
    let direction: SpaceSwitchDirection

    /// Every adjacent instant hop is the same committed flick. Distance lives in the number
    /// of confirmed hops, never in velocity — multiplying both caused the edge overshoot.
    var instantVelocity: Double { kInstantSwitchVelocity }
}

enum SpaceSwitchRequestResult: Equatable {
    case declined
    case noChange
    case coalesced
    case post(SpaceSwitchHop)

    var hop: SpaceSwitchHop? {
        guard case .post(let hop) = self else { return nil }
        return hop
    }
}

/// Keeps at most one unconfirmed Dock gesture in flight for each display Space stack.
///
/// WindowServer's current desktop is the only completion signal. Rapid requests merely
/// replace `desiredTarget`; they never append another blind gesture to Dock's queue. Once
/// `activeSpaceDidChangeNotification` arrives, the coordinator either finishes or derives
/// exactly one new adjacent hop from the topology macOS now reports.
struct SpaceSwitchCoordinator {
    private struct PendingSwitch {
        var desiredTarget: DesktopLocation
        var originDesktopID: CGSSpaceID
        var expectedDesktopID: CGSSpaceID
    }

    private var pendingByStackID: [String: PendingSwitch] = [:]

    func isInFlight(stackID: String) -> Bool {
        pendingByStackID[stackID] != nil
    }

    mutating func request(
        to target: DesktopLocation,
        in topology: SpaceTopology
    ) -> SpaceSwitchRequestResult {
        guard let stack = topology.stack(id: target.stackID),
              stack.desktopIDs.indices.contains(target.index),
              stack.desktopIDs[target.index] == target.desktopID,
              let currentDesktopID = stack.currentDesktopID,
              let currentIndex = stack.currentDesktopIndex
        else { return .declined }

        if var pending = pendingByStackID[target.stackID] {
            pending.desiredTarget = target
            pendingByStackID[target.stackID] = pending
            return .coalesced
        }

        guard currentDesktopID != target.desktopID else { return .noChange }
        guard let hop = Self.nextHop(from: currentIndex, toward: target, in: stack) else {
            return .declined
        }
        pendingByStackID[target.stackID] = PendingSwitch(
            desiredTarget: target,
            originDesktopID: hop.fromDesktopID,
            expectedDesktopID: hop.toDesktopID
        )
        return .post(hop)
    }

    /// Confirms completed hops and returns at most one next hop per Space stack.
    ///
    /// A different current desktop is a user action or a Dock result Debut did not request.
    /// Continuing from it would fight the user, so an unexpected landing stops safely.
    mutating func desktopDidChange(to topology: SpaceTopology) -> [SpaceSwitchHop] {
        var nextHops: [SpaceSwitchHop] = []

        for stackID in Array(pendingByStackID.keys) {
            guard let pending = pendingByStackID[stackID],
                  let stack = topology.stack(id: stackID),
                  let currentDesktopID = stack.currentDesktopID,
                  let currentIndex = stack.currentDesktopIndex,
                  stack.desktopIDs.indices.contains(pending.desiredTarget.index),
                  stack.desktopIDs[pending.desiredTarget.index]
                    == pending.desiredTarget.desktopID
            else {
                pendingByStackID.removeValue(forKey: stackID)
                continue
            }

            guard currentDesktopID == pending.expectedDesktopID else {
                if currentDesktopID != pending.originDesktopID {
                    pendingByStackID.removeValue(forKey: stackID)
                }
                continue
            }

            guard currentDesktopID != pending.desiredTarget.desktopID else {
                pendingByStackID.removeValue(forKey: stackID)
                continue
            }

            guard let hop = Self.nextHop(
                from: currentIndex,
                toward: pending.desiredTarget,
                in: stack
            ) else {
                pendingByStackID.removeValue(forKey: stackID)
                continue
            }
            pendingByStackID[stackID] = PendingSwitch(
                desiredTarget: pending.desiredTarget,
                originDesktopID: hop.fromDesktopID,
                expectedDesktopID: hop.toDesktopID
            )
            nextHops.append(hop)
        }
        return nextHops
    }

    mutating func postingFailed(_ hop: SpaceSwitchHop) {
        guard let pending = pendingByStackID[hop.stackID],
              pending.originDesktopID == hop.fromDesktopID,
              pending.expectedDesktopID == hop.toDesktopID
        else { return }
        pendingByStackID.removeValue(forKey: hop.stackID)
    }

    private static func nextHop(
        from currentIndex: Int,
        toward target: DesktopLocation,
        in stack: SpaceStackDescriptor
    ) -> SpaceSwitchHop? {
        guard let plan = SpaceSwitchPlan(
            from: currentIndex,
            to: target.index,
            desktopCount: stack.desktopIDs.count
        ) else { return nil }
        let nextIndex = currentIndex + (plan.direction == .right ? 1 : -1)
        guard stack.desktopIDs.indices.contains(nextIndex) else { return nil }
        return SpaceSwitchHop(
            stackID: stack.id,
            fromDesktopID: stack.desktopIDs[currentIndex],
            toDesktopID: stack.desktopIDs[nextIndex],
            direction: plan.direction
        )
    }
}

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
                     progress: Double = kInstantSwitchProgress,
                     location: CGPoint? = nil) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        if let location { event.location = location }

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
    static func makeEnvelope(location: CGPoint? = nil) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        if let location { event.location = location }
        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)
        return event
    }

    /// Posts one complete Began+Ended pair. Both phases are built before either is posted,
    /// so an allocation failure cannot leave the Dock holding an unmatched Began.
    @discardableResult
    static func postSwitch(
        direction: SpaceSwitchDirection,
        velocity: Double,
        location: CGPoint? = nil
    ) -> Bool {
        guard let began = make(
            phase: .began, direction: direction, velocity: 0, location: location
        ), let beganEnvelope = makeEnvelope(location: location),
              let ended = make(
                phase: .ended, direction: direction, velocity: velocity, location: location
              ), let endedEnvelope = makeEnvelope(location: location)
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
                                 location: CGPoint? = nil,
                                 isCancelled: () -> Bool = { false }) -> Bool {
        guard let began = make(
            phase: .began, direction: direction, velocity: 0, location: location
        ), let beganEnvelope = makeEnvelope(location: location),
              let ended = make(phase: .ended, direction: direction,
                               velocity: kAnimatedReleaseVelocity, progress: 1,
                               location: location),
              let endedEnvelope = makeEnvelope(location: location)
        else { return false }

        let start = DispatchTime.now()
        began.post(tap: .cgSessionEventTap)
        beganEnvelope.post(tap: .cgSessionEventTap)

        for sample in samples.dropLast() {
            guard !isCancelled() else { break }
            wait(untilElapsed: sample.delay, since: start)
            guard let changed = make(phase: .changed, direction: direction,
                                     progress: sample.progress, location: location),
                  let envelope = makeEnvelope(location: location)
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
    func spaceTopology() -> SpaceTopology
    func desktopLocation(forWindow windowID: CGWindowID) -> DesktopLocation?
    func desktopLocations(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: DesktopLocation]
    func desktopCount() -> Int
    func currentDesktopIndex() -> Int?
    func desktopIndex(forWindow windowID: CGWindowID) -> Int?
    /// Declared here, not only in the extension, so a conformer's faster batch
    /// implementation is reached through an `any SpaceSwitching` too.
    func desktopIndexes(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: Int]
    @discardableResult func switchToDesktop(index: Int) -> Bool
    @discardableResult func switchToDesktop(_ location: DesktopLocation) -> Bool
    /// True from the first posted hop until WindowServer confirms the final target.
    func isSwitchInFlight(stackID: String) -> Bool
    /// Advances a confirmed multi-hop switch from the topology macOS now reports.
    func spaceDidChange()
    /// Whether this conformer can reassign a window's desktop at all. False means the move
    /// commands should stay inert rather than mutate the model and lie about the result.
    var canMoveWindows: Bool { get }
    func moveWindow(windowID: CGWindowID, toDesktop: Int,
                    completion: (@Sendable (Bool) -> Void)?)
    func moveWindow(windowID: CGWindowID, to location: DesktopLocation,
                    completion: (@Sendable (Bool) -> Void)?)
}

public extension SpaceSwitching {
    func isSwitchInFlight(stackID: String) -> Bool { false }
    func spaceDidChange() {}

    func spaceTopology() -> SpaceTopology {
        let count = desktopCount()
        let desktops = (0..<count).map(CGSSpaceID.init)
        return SpaceTopology(separateSpaces: false, stacks: [
            SpaceStackDescriptor(
                id: SpaceTopology.sharedStackID,
                displayID: nil,
                displayName: "All Displays",
                frame: .zero,
                desktopIDs: desktops,
                currentDesktopID: currentDesktopIndex().flatMap { index in
                    desktops.indices.contains(index) ? desktops[index] : nil
                }
            ),
        ])
    }

    func desktopLocation(forWindow windowID: CGWindowID) -> DesktopLocation? {
        guard let index = desktopIndex(forWindow: windowID),
              let stack = spaceTopology().stacks.first,
              stack.desktopIDs.indices.contains(index)
        else { return nil }
        return stack.location(at: index)
    }

    func desktopLocations(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: DesktopLocation] {
        windowIDs.reduce(into: [:]) { result, windowID in
            result[windowID] = desktopLocation(forWindow: windowID)
        }
    }

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

    @discardableResult
    func switchToDesktop(_ location: DesktopLocation) -> Bool {
        switchToDesktop(index: location.index)
    }

    func moveWindow(windowID: CGWindowID, to location: DesktopLocation,
                    completion: (@Sendable (Bool) -> Void)?) {
        moveWindow(windowID: windowID, toDesktop: location.index, completion: completion)
    }
}

/// Reads and changes which macOS Space is showing, and which Space a window lives on.
public final class SpaceService: SpaceSwitching, @unchecked Sendable {

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
    private let switchCoordinatorLock = NSLock()
    private var switchCoordinator = SpaceSwitchCoordinator()

    /// Confirming a move means re-reading the assignment until the window server catches up.
    /// That settles in single-digit milliseconds, but it is still a wait, and the main thread
    /// runs the event tap.
    private let moveQueue = DispatchQueue(label: "com.thomplth.debut.space-move")

    public init() {}

    public func desktopCount() -> Int { spaceTopology().stacks.first?.desktopIDs.count ?? 0 }

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

    private func managedDisplaySpaces() -> [[String: Any]] {
        guard let connection, let cgsCopyManagedDisplaySpaces else { return [] }
        return cgsCopyManagedDisplaySpaces(connection, nil)?
            .takeRetainedValue() as? [[String: Any]] ?? []
    }

    private static func desktopIDs(in display: [String: Any]) -> [CGSSpaceID] {
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        return spaces.compactMap { space in
            guard (space["type"] as? NSNumber)?.intValue ?? 0 == 0 else { return nil }
            return (space["id64"] as? NSNumber)?.uint64Value
        }
    }

    private static func currentDesktopID(in display: [String: Any]) -> CGSSpaceID? {
        ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
    }

    private static func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The display-scoped desktop lists Mission Control owns right now.
    public func spaceTopology() -> SpaceTopology {
        let managed = managedDisplaySpaces()
        guard !managed.isEmpty else { return SpaceTopology(separateSpaces: false, stacks: []) }

        let screens = NSScreen.screens
        let separate = NSScreen.screensHaveSeparateSpaces
        if !separate {
            let display = managed.first(where: {
                ($0["Display Identifier"] as? String) == "Main"
            }) ?? managed[0]
            let frames = screens.map(\.frame)
            let frame = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
            return SpaceTopology(separateSpaces: false, stacks: [
                SpaceStackDescriptor(
                    id: SpaceTopology.sharedStackID,
                    displayID: NSScreen.main?.displayID,
                    displayName: "All Displays",
                    frame: frame,
                    desktopIDs: Self.desktopIDs(in: display),
                    currentDesktopID: Self.currentDesktopID(in: display)
                ),
            ])
        }

        var remaining = managed
        var descriptors: [SpaceStackDescriptor] = []
        for screen in screens {
            guard let uuid = Self.displayUUID(screen.displayID),
                  let index = remaining.firstIndex(where: {
                      ($0["Display Identifier"] as? String) == uuid
                  })
            else { continue }
            let display = remaining.remove(at: index)
            let name = screen.localizedName.isEmpty ? "Display \(descriptors.count + 1)" : screen.localizedName
            descriptors.append(SpaceStackDescriptor(
                id: uuid,
                displayID: screen.displayID,
                displayName: name,
                frame: screen.frame,
                desktopIDs: Self.desktopIDs(in: display),
                currentDesktopID: Self.currentDesktopID(in: display)
            ))
        }
        for display in remaining {
            guard let identifier = display["Display Identifier"] as? String else { continue }
            descriptors.append(SpaceStackDescriptor(
                id: identifier,
                displayID: nil,
                displayName: "Display \(descriptors.count + 1)",
                frame: .zero,
                desktopIDs: Self.desktopIDs(in: display),
                currentDesktopID: Self.currentDesktopID(in: display)
            ))
        }
        return SpaceTopology(separateSpaces: true, stacks: descriptors)
    }

    /// User desktops on the first stack, retained for compatibility with index-only callers.
    ///
    /// Fullscreen and tiled Spaces are excluded — only `type == 0` entries are desktops a
    /// stage can map onto.
    public func userDesktops() -> [CGSSpaceID] {
        spaceTopology().stacks.first?.desktopIDs ?? []
    }

    public func currentDesktop() -> CGSSpaceID? {
        spaceTopology().stacks.first?.currentDesktopID
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
        desktopLocation(forWindow: windowID)?.index
    }

    public func desktopLocation(forWindow windowID: CGWindowID) -> DesktopLocation? {
        let topology = spaceTopology()
        let locations = spaces(forWindow: windowID).compactMap(topology.location(ofSpace:))
        guard locations.count == 1 else { return nil }
        return locations[0]
    }

    /// `SLSCopySpacesForWindows` returns a flat space list with no per-window attribution,
    /// so windows are still resolved one at a time. What this avoids is the copy of the
    /// whole display topology that `userDesktops()` makes on every single lookup.
    public func desktopIndexes(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: Int] {
        desktopLocations(forWindows: windowIDs).mapValues(\.index)
    }

    public func desktopLocations(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: DesktopLocation] {
        let topology = spaceTopology()
        return windowIDs.reduce(into: [:]) { result, windowID in
            let locations = spaces(forWindow: windowID).compactMap(topology.location(ofSpace:))
            if locations.count == 1 { result[windowID] = locations[0] }
        }
    }

    static func index(of space: CGSSpaceID, in desktops: [CGSSpaceID]) -> Int? {
        desktops.firstIndex(of: space)
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
        guard let location = spaceTopology().stacks.first?.location(at: target) else { return false }
        return switchToDesktop(location)
    }

    /// Dock gestures are display-scoped only when macOS maintains an independent Space stack
    /// per display. With shared Spaces, attaching the main display's coordinates to the event
    /// can leave the wall's desktop transition only partially composited: wallpaper changes,
    /// while destination windows remain ordered out until an app activation repairs it.
    static func gestureLocation(
        for stack: SpaceStackDescriptor,
        separateSpaces: Bool,
        displayBounds: (CGDirectDisplayID) -> CGRect = CGDisplayBounds
    ) -> CGPoint? {
        guard separateSpaces, let displayID = stack.displayID else { return nil }
        let bounds = displayBounds(displayID)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Switches a particular display's visible desktop. The synthetic gesture is located
    /// on that display so the Dock applies it to the matching Space list when displays use
    /// separate Spaces.
    @discardableResult
    public func switchToDesktop(_ location: DesktopLocation) -> Bool {
        guard canSwitchSpaces else { return false }
        let topology = spaceTopology()
        let request = switchCoordinatorLock.withLock {
            switchCoordinator.request(to: location, in: topology)
        }

        switch request {
        case .declined, .noChange:
            return false
        case .coalesced:
            return true
        case .post(let hop):
            guard post(hop, in: topology) else {
                switchCoordinatorLock.withLock {
                    switchCoordinator.postingFailed(hop)
                }
                return false
            }
            return true
        }
    }

    public func isSwitchInFlight(stackID: String) -> Bool {
        switchCoordinatorLock.withLock {
            switchCoordinator.isInFlight(stackID: stackID)
        }
    }

    /// Called from `activeSpaceDidChangeNotification`, after WindowServer has settled one hop.
    public func spaceDidChange() {
        let topology = spaceTopology()
        let nextHops = switchCoordinatorLock.withLock {
            switchCoordinator.desktopDidChange(to: topology)
        }
        for hop in nextHops where !post(hop, in: topology) {
            switchCoordinatorLock.withLock {
                switchCoordinator.postingFailed(hop)
            }
        }
    }

    /// Posts exactly one adjacent hop. Far targets return here only after each preceding hop
    /// has generated `activeSpaceDidChangeNotification`, so Dock never receives overlapping
    /// gesture streams and an edge is rechecked before every post.
    private func post(_ hop: SpaceSwitchHop, in topology: SpaceTopology) -> Bool {
        guard let stack = topology.stack(id: hop.stackID),
              stack.currentDesktopID == hop.fromDesktopID,
              stack.desktopIDs.contains(hop.toDesktopID)
        else { return false }
        let eventLocation = Self.gestureLocation(
            for: stack,
            separateSpaces: topology.separateSpaces
        )

        let samples = DockSwipeAnimation.samples(duration: switchDuration)
        guard !samples.isEmpty else {
            return DockSwipeEvent.postSwitch(
                direction: hop.direction,
                velocity: hop.instantVelocity,
                location: eventLocation
            )
        }

        switchQueue.async { [self] in
            let posted = DockSwipeEvent.postDrivenSwitch(
                direction: hop.direction,
                samples: samples,
                location: eventLocation
            )
            if !posted {
                switchCoordinatorLock.withLock {
                    switchCoordinator.postingFailed(hop)
                }
            }
        }
        return true
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
        guard let location = spaceTopology().stacks.first?.location(at: target) else {
            completion?(false)
            return
        }
        moveWindow(windowID: windowID, to: location, completion: completion)
    }

    public func moveWindow(windowID: CGWindowID,
                           to location: DesktopLocation,
                           completion: (@Sendable (Bool) -> Void)? = nil) {
        guard let stack = spaceTopology().stack(id: location.stackID),
              stack.desktopIDs.indices.contains(location.index),
              stack.desktopIDs[location.index] == location.desktopID,
              BridgedWindowManagement.moveWindows([windowID], toSpace: location.desktopID)
        else {
            completion?(false)
            return
        }
        guard let completion else { return }
        moveQueue.async { [self] in
            completion(waitForWindow(windowID, toReachSpace: location.desktopID))
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
