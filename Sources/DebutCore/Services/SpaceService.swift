import AppKit
import CoreGraphics
import Darwin
import Foundation

// Real macOS Spaces as the backing store for spaces.
//
// Everything here was validated by measurement on macOS 26.5.2 arm64 with SIP enabled.
// Two findings shape the design:
//
//   1. The ordinary private *write* APIs that reassign a window's Space no-op across process
//      boundaries. Window reassignment therefore goes through BridgedWindowManagement; the
//      private symbols in this file are reads, while desktop switching uses Dock gestures.
//
//   2. Space *creation* is gated too. SLSSpaceCreate returns an id that no display manages,
//      which is why spaces map onto desktops the user made in Mission Control rather than
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

func skyLightSymbol<T>(_ name: String) -> T? {
    dlsym(skyLight, name).map { unsafeBitCast($0, to: T.self) }
}

private let cgsMainConnectionID: (@convention(c) () -> CGSConnectionID)? =
    skyLightSymbol("CGSMainConnectionID")
private let cgsCopyManagedDisplaySpaces: (@convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?)? =
    skyLightSymbol("CGSCopyManagedDisplaySpaces")
private let slsCopySpacesForWindows: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?)? =
    skyLightSymbol("SLSCopySpacesForWindows")
private let slsCopyWindowsWithOptionsAndTags: (@convention(c) (
    CGSConnectionID, UInt32, CFArray, UInt32,
    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
) -> Unmanaged<CFArray>?)? = skyLightSymbol("SLSCopyWindowsWithOptionsAndTags")

// The window server records which window a surface was raised over. A sheet or popup names its
// host; an ordinary window names nothing. Reached through the iterator rather than a per-window
// property call so the whole list costs one query.
private let slsWindowQueryWindows: (@convention(c)
    (CGSConnectionID, CFArray, Int32) -> UnsafeMutableRawPointer?)? =
    skyLightSymbol("SLSWindowQueryWindows")
private let slsWindowQueryResultCopyWindows: (@convention(c)
    (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?)? =
    skyLightSymbol("SLSWindowQueryResultCopyWindows")
private let slsWindowIteratorAdvance: (@convention(c) (UnsafeMutableRawPointer) -> Bool)? =
    skyLightSymbol("SLSWindowIteratorAdvance")
private let slsWindowIteratorGetWindowID: (@convention(c) (UnsafeMutableRawPointer) -> CGWindowID)? =
    skyLightSymbol("SLSWindowIteratorGetWindowID")
private let slsWindowIteratorGetParentID: (@convention(c) (UnsafeMutableRawPointer) -> CGWindowID)? =
    skyLightSymbol("SLSWindowIteratorGetParentID")
private let slsWindowIteratorGetAttributes: (@convention(c) (UnsafeMutableRawPointer) -> UInt64)? =
    skyLightSymbol("SLSWindowIteratorGetAttributes")
private let slsWindowIteratorGetTags: (@convention(c) (UnsafeMutableRawPointer) -> UInt64)? =
    skyLightSymbol("SLSWindowIteratorGetTags")

/// Set while the window server is willing to draw the surface. Clearing it is how minimizing,
/// hiding an app and ordering a window out are all expressed, so the bit alone names no reason.
private let orderedInAttribute: UInt64 = 0x2
/// Names minimizing as the reason the bit above is clear. There is a sibling tag for app-hiding,
/// but it is not reliable — see `orderedOutGhostWindowIDs`, which asks AppKit instead.
private let minimizedTag: UInt64 = 1 << 60
/// A positive per-window app-hide marker. Some genuine hidden windows lack it, so absence alone
/// cannot evict them; Accessibility identity supplies the second signal.
private let hiddenAppTag: UInt64 = 1 << 39

// Every Space remembers which process it shows as frontmost when it is revealed. Unlike
// `_SLPSSetFrontProcessWithOptions`, this writes that memory for one Space only: it does not set
// the global front and does not disturb the other Spaces where the app has windows. That is what
// makes it safe to aim at a desktop the user is not looking at yet.
private let slsSpaceSetFrontPSN: (@convention(c)
    (CGSConnectionID, CGSSpaceID, ProcessSerialNumber) -> CGError)? =
    skyLightSymbol("SLSSpaceSetFrontPSN")

// The global counterpart of the call above: it fronts a process everywhere, and naming a window
// fronts that one window rather than every window the app owns. This is the only way to move the
// front across processes. `NSRunningApplication.activate()` became advisory in macOS 14 and is
// declined for a background regular application, which is what Debut is while its Dock icon is on
// — the overlay is a borderless status-level window that never takes activation for itself.
private let slpsSetFrontProcessWithOptions: (@convention(c)
    (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError)? =
    skyLightSymbol("_SLPSSetFrontProcessWithOptions")

/// `kCPSUserGenerated`. The window server treats a front request attributed to the user as one it
/// must honour; the default mode is the advisory one this call exists to avoid.
private let kSLPSUserGenerated: UInt32 = 0x200

// Delivers a raw `CGSEventRecord` to one process. Fronting a process does not decide which of its
// windows takes the keyboard, so the chosen window is named by posting the event a click on it
// would have produced.
private let slpsPostEventRecordTo: (@convention(c)
    (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)? =
    skyLightSymbol("SLPSPostEventRecordTo")

// A PSN is not derivable from a pid — measured on macOS 26.5.2, `Finder` at pid 673 answered
// psn (0, 118813) — so it has to be asked for. `GetProcessForPID` is marked unavailable in the
// macOS 26 SDK and cannot be called directly from Swift, but the symbol is still exported, so it
// is resolved the same way the SkyLight ones are.
private let getProcessForPID: (@convention(c)
    (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)? =
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")
        .map { unsafeBitCast($0, to: (@convention(c)
            (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self) }

/// Moving the front between processes, which the public API no longer does.
public enum FrontProcessManagement {
    /// Which private symbols resolved. Fronting degrades silently when one goes missing, so this
    /// exists to be asserted rather than inferred from behaviour.
    public struct Readiness: Sendable {
        public let frontProcessResolved: Bool
        public let processSerialNumberResolved: Bool
        public let eventRecordPostResolved: Bool
    }

    public static var readiness: Readiness {
        Readiness(
            frontProcessResolved: slpsSetFrontProcessWithOptions != nil,
            processSerialNumberResolved: getProcessForPID != nil,
            eventRecordPostResolved: slpsPostEventRecordTo != nil
        )
    }

    /// Whether both symbols this needs resolved. A missing one makes every request a refusal,
    /// which the caller answers by falling back to the AppKit request rather than doing nothing.
    public static var isAvailable: Bool {
        slpsSetFrontProcessWithOptions != nil && getProcessForPID != nil
    }

    /// Fronts `windowID`'s process and makes that window key. Returns whether the window server
    /// took the front request — not whether the window arrived, which nothing here can observe.
    public static func front(windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        frontWithTrace(windowID: windowID, ownerPID: ownerPID).accepted
    }

    public static func frontWithTrace(
        windowID: CGWindowID,
        ownerPID: pid_t
    ) -> FrontWindowDeliveryTrace {
        let readiness = readiness
        guard let slpsSetFrontProcessWithOptions, let getProcessForPID else {
            return FrontWindowDeliveryTrace(
                accepted: false,
                processSerialNumberStatus: nil,
                frontRequestStatus: nil,
                keyWindowEventStatus: nil,
                frontProcessSymbolResolved: readiness.frontProcessResolved,
                processSerialNumberSymbolResolved: readiness.processSerialNumberResolved,
                keyWindowEventSymbolResolved: readiness.eventRecordPostResolved
            )
        }
        var psn = ProcessSerialNumber()
        let processStatus = getProcessForPID(ownerPID, &psn)
        guard processStatus == noErr else {
            return FrontWindowDeliveryTrace(
                accepted: false,
                processSerialNumberStatus: processStatus,
                frontRequestStatus: nil,
                keyWindowEventStatus: nil,
                frontProcessSymbolResolved: readiness.frontProcessResolved,
                processSerialNumberSymbolResolved: readiness.processSerialNumberResolved,
                keyWindowEventSymbolResolved: readiness.eventRecordPostResolved
            )
        }
        let frontStatus = slpsSetFrontProcessWithOptions(&psn, windowID, kSLPSUserGenerated)
        guard frontStatus == .success else {
            return FrontWindowDeliveryTrace(
                accepted: false,
                processSerialNumberStatus: processStatus,
                frontRequestStatus: frontStatus.rawValue,
                keyWindowEventStatus: nil,
                frontProcessSymbolResolved: readiness.frontProcessResolved,
                processSerialNumberSymbolResolved: readiness.processSerialNumberResolved,
                keyWindowEventSymbolResolved: readiness.eventRecordPostResolved
            )
        }
        let keyStatus = makeKeyWindow(windowID: windowID, of: &psn)
        return FrontWindowDeliveryTrace(
            accepted: true,
            processSerialNumberStatus: processStatus,
            frontRequestStatus: frontStatus.rawValue,
            keyWindowEventStatus: keyStatus?.rawValue,
            frontProcessSymbolResolved: readiness.frontProcessResolved,
            processSerialNumberSymbolResolved: readiness.processSerialNumberResolved,
            keyWindowEventSymbolResolved: readiness.eventRecordPostResolved
        )
    }

    /// Fronting a process does not decide which of its windows holds the keyboard, and naming the
    /// window in the front request is not enough on its own — measured on macOS 26.5 by
    /// alt-tab-macos, the front call alone leaves the app's previous window key, which reads to
    /// the user as the switch having done nothing. Posting the event a click on the window would
    /// have produced is what moves the keyboard, and the app answers nothing either way.
    private static func makeKeyWindow(
        windowID: CGWindowID,
        of psn: inout ProcessSerialNumber
    ) -> CGError? {
        guard let slpsPostEventRecordTo else { return nil }
        var record = keyWindowEventRecord(for: windowID)
        return slpsPostEventRecordTo(&psn, &record)
    }

    /// The `CGSEventRecord` a left click on `windowID` would have produced.
    ///
    /// Only a mouse-down is posted. A matching up cancels the down before the app has acted on
    /// it, leaving nothing keyed.
    static func keyWindowEventRecord(for windowID: CGWindowID) -> [UInt8] {
        // The buffer is far longer than the record it holds because `CGSEncodeEventRecord` reads
        // past the declared length; on uninitialized heap that aborts the process.
        var record = [UInt8](repeating: 0, count: 0x100)
        record[0x04] = 0xf8
        record[0x08] = UInt8(CGEventType.leftMouseDown.rawValue)
        record[0x3a] = 0x10

        // Window-relative, and deliberately past any content the window could have. A point apps
        // reject — negative, or non-finite — is sanitized back to the origin, which puts the
        // click on whatever control sits in the corner.
        var location = CGPoint(x: 300_000, y: 300_000)
        var windowID = windowID
        withUnsafeBytes(of: &location) { record.replaceSubrange(0x20 ..< 0x20 + $0.count, with: $0) }
        withUnsafeBytes(of: &windowID) { record.replaceSubrange(0x3c ..< 0x3c + $0.count, with: $0) }
        return record
    }
}

/// Selector for `SLSCopySpacesForWindows` meaning "all spaces the window belongs to".
private let kSpaceSelectorAll: Int32 = 7

/// Option bits for `SLSCopyWindowsWithOptionsAndTags`: include invisible/off-screen windows
/// (`1<<0`, `1<<2`) and windows at the screen-saver level (`1<<1`). Without these a window
/// on a desktop that is not showing is exactly the kind of window this call exists to find,
/// and the default options omit it.
private let kWindowEnumerationOptions: UInt32 = 0x7

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
//   - iss — https://github.com/joshuarli/iss
//     The reverse-engineered macOS 27 IOHID payload format and serialized field-4205 framing.
let kCGSEventTypeField = CGEventField(rawValue: 55)!
let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
let kCGEventGestureSwipeMask = CGEventField(rawValue: 115)!
let kCGEventGestureScrollY = CGEventField(rawValue: 119)!
let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
let kCGEventGesturePositionX = CGEventField(rawValue: 125)!
let kCGEventGesturePositionY = CGEventField(rawValue: 126)!
let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
let kCGEventGestureSwipeVelocityY = CGEventField(rawValue: 130)!
let kCGEventGesturePhase = CGEventField(rawValue: 132)!
let kCGEventGesturePhase2 = CGEventField(rawValue: 134)!
let kCGEventScrollGestureFlagBits = CGEventField(rawValue: 135)!
let kCGEventGestureFlavor = CGEventField(rawValue: 138)!
let kCGEventGestureZoomDeltaX = CGEventField(rawValue: 139)!
let kCGEventGestureTimestamp = CGEventField(rawValue: 169)!

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
/// macOS 27 raised the terminal-velocity threshold on its validated gesture path.
private let kAugmentedInstantSwitchVelocity: Double = 9_999
/// Released at the end of a driven slide, where progress has already reached the target and
/// the velocity only has to be enough to commit rather than rubber-band.
private let kAnimatedReleaseVelocity: Double = 60

/// macOS 27 validates a raw IOHID queue entry stored as binary CGEvent field 4205.
private let kCGEventIOHIDPayloadField: UInt16 = 4_205
private let kIOHIDEventTypeVelocity: UInt32 = 9
private let kIOHIDEventTypeFluidTouchGesture: UInt32 = 23
private let kIOHIDGestureFlavorDockPrimary: UInt16 = 3
private let kIOHIDFluidTouchGestureDataSize: UInt32 = 40
private let kIOHIDVelocityEventDataSize: UInt32 = 28
private let kIOHIDProgressEpsilon = 1.0 / 65_536.0

enum DockSwipePostingMode: Equatable {
    case legacy
    case augmented(invertSigns: Bool)
}

/// Selects the measured DockSwipe schema for the running macOS release.
///
/// macOS 27 requires a three-phase gesture whose fields are mirrored into a packed IOHID
/// payload. Its horizontal sign follows Natural Scrolling on release builds. Early 26A beta
/// seeds below 26A5416 used an always-inverted sign, but shipping 27.0 is 26A428: Apple's
/// release build numbers are lower than its 5000-series seed numbers, so it must not be
/// classified as an early beta merely because 428 is less than 5416.
enum DockSwipeCompatibility {
    static func mode(
        operatingSystemMajor: Int,
        build: String,
        naturalScrolling: Bool
    ) -> DockSwipePostingMode? {
        if operatingSystemMajor < 27 { return .legacy }
        guard operatingSystemMajor == 27 else { return nil }

        let parsed = parse(build: build)
        let isAlwaysInvertedSeed = parsed?.train == 26
            && parsed?.letter == "A"
            && (parsed?.number ?? 0) >= 5_000
            && (parsed?.number ?? Int.max) < 5_416
        return .augmented(invertSigns: isAlwaysInvertedSeed || naturalScrolling)
    }

    static var currentMode: DockSwipePostingMode? {
        mode(
            operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            build: operatingSystemBuild(),
            naturalScrolling: naturalScrollingEnabled()
        )
    }

    static func supports(operatingSystemMajor: Int) -> Bool {
        (26...27).contains(operatingSystemMajor)
    }

    private static func parse(build: String) -> (train: Int, letter: String, number: Int)? {
        var remainder = build[...]
        let trainText = remainder.prefix(while: \.isNumber)
        remainder = remainder.dropFirst(trainText.count)
        let letterText = remainder.prefix(while: \.isUppercase)
        remainder = remainder.dropFirst(letterText.count)
        let numberText = remainder.prefix(while: \.isNumber)
        guard let train = Int(trainText), !letterText.isEmpty, let number = Int(numberText)
        else { return nil }
        return (train, String(letterText), number)
    }

    private static func operatingSystemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0
        else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0
        else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func naturalScrollingEnabled() -> Bool {
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return CFPreferencesCopyAppValue(
            "com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication
        ) as? Bool ?? true
    }
}

// MARK: - Plan

enum SpaceSwitchDirection {
    case left
    case right

    var flagBits: Int64 { self == .right ? 1 : 0 }
    var sign: Double { self == .right ? 1 : -1 }
}

/// How to get from one native Space to another: which way, and how far.
///
/// Kept as a value type with no side effects so the arithmetic — which is where an
/// off-by-one would strand the user on the wrong desktop — is testable without a window
/// server.
struct SpaceSwitchPlan: Equatable {
    let direction: SpaceSwitchDirection
    let steps: Int

    /// - Returns: `nil` when there is nothing to do, which includes the case where the
    ///   target is the Space already showing. A zero-step gesture is not harmless: it
    ///   opens the Dock's gesture state and the Dock resolves the unmatched Began by
    ///   rubber-banding.
    init?(from current: Int, to target: Int, spaceCount: Int) {
        guard spaceCount > 1,
              (0..<spaceCount).contains(current),
              (0..<spaceCount).contains(target),
              current != target
        else { return nil }

        direction = target > current ? .right : .left
        steps = abs(target - current)
    }
}

extension SpaceSwitchDirection: Equatable {}

/// One adjacent, fully addressable Space transition. A far target remains a sequence of
/// adjacent transitions even when Instant mode posts the whole sequence as one batch.
enum SpaceSwitchAnimation: Equatable {
    case configured
    case system

    /// A normal macOS desktop slide is about four tenths of a second. Keep that timing
    /// independent of Debut's speed slider so disabling the feature actually disables the
    /// configured acceleration instead of merely routing through another activation API.
    static let systemDuration: TimeInterval = 0.4

    func duration(configuredDuration: TimeInterval) -> TimeInterval {
        switch self {
        case .configured: configuredDuration
        case .system: Self.systemDuration
        }
    }

    func scheduling(configuredDuration: TimeInterval) -> SpaceSwitchScheduling {
        duration(configuredDuration: configuredDuration) == 0
            ? .batchedInstant
            : .confirmedAdjacent
    }
}

enum SpaceSwitchScheduling: Equatable {
    case confirmedAdjacent
    case batchedInstant
}

struct SpaceSwitchHop: Equatable {
    let stackID: String
    let fromSpaceID: CGSSpaceID
    let toSpaceID: CGSSpaceID
    let direction: SpaceSwitchDirection
    let animation: SpaceSwitchAnimation

    init(
        stackID: String,
        fromSpaceID: CGSSpaceID,
        toSpaceID: CGSSpaceID,
        direction: SpaceSwitchDirection,
        animation: SpaceSwitchAnimation = .configured
    ) {
        self.stackID = stackID
        self.fromSpaceID = fromSpaceID
        self.toSpaceID = toSpaceID
        self.direction = direction
        self.animation = animation
    }

    /// Every adjacent instant hop is the same committed flick. Distance lives in the number
    /// of adjacent gestures, never in velocity — multiplying both caused the edge overshoot.
    var instantVelocity: Double { kInstantSwitchVelocity }
}

enum SpaceSwitchRequestResult: Equatable {
    case declined
    case noChange
    case coalesced
    case post([SpaceSwitchHop])

    var hops: [SpaceSwitchHop] {
        guard case .post(let hops) = self else { return [] }
        return hops
    }
}

struct SpaceSwitchRecoveryTicket: Equatable, Sendable {
    let stackID: String
    let generation: UInt64
}

enum SpaceSwitchRecoveryResult: Equatable {
    case stale
    case completed
    case abandoned
    case post([SpaceSwitchHop])
}

private struct SpaceNavigationTarget: Equatable {
    let stackID: String
    let spaceID: CGSSpaceID
    let index: Int
}

/// Keeps at most one unconfirmed Dock route in flight for each display Space stack.
///
/// WindowServer's current Space is the only completion signal. Rapid requests replace
/// `desiredTarget`; they never append another route before the posted endpoint is confirmed.
/// Animated routes post and confirm one adjacent hop at a time. Instant routes post all of
/// their adjacent hops together, then treat intermediate notifications as acknowledgements.
struct SpaceSwitchCoordinator {
    private struct PendingSwitch {
        var generation: UInt64
        var desiredTarget: SpaceNavigationTarget
        var originSpaceID: CGSSpaceID
        var expectedSpaceIDs: [CGSSpaceID]
        var animation: SpaceSwitchAnimation
        var scheduling: SpaceSwitchScheduling
    }

    private var pendingByStackID: [String: PendingSwitch] = [:]
    private var nextGeneration: UInt64 = 0

    func isInFlight(stackID: String) -> Bool {
        pendingByStackID[stackID] != nil
    }

    mutating func request(
        to target: DesktopLocation,
        in topology: SpaceTopology,
        animation: SpaceSwitchAnimation = .configured,
        scheduling: SpaceSwitchScheduling = .confirmedAdjacent
    ) -> SpaceSwitchRequestResult {
        guard let stack = topology.stack(id: target.stackID),
              stack.desktopIDs.indices.contains(target.index),
              stack.desktopIDs[target.index] == target.desktopID,
              let navigationIndex = stack.orderedSpaceIDs.firstIndex(of: target.desktopID)
        else { return .declined }
        return requestNavigation(
            to: SpaceNavigationTarget(
                stackID: target.stackID,
                spaceID: target.desktopID,
                index: navigationIndex
            ),
            in: topology,
            animation: animation,
            scheduling: scheduling
        )
    }

    /// Moves one position in Mission Control order. A pending route advances from its desired
    /// endpoint so consecutive swipes can cross a fullscreen Space before the first active-Space
    /// notification arrives.
    mutating func requestAdjacent(
        offset: Int,
        stackID: String,
        in topology: SpaceTopology,
        animation: SpaceSwitchAnimation = .configured,
        scheduling: SpaceSwitchScheduling = .confirmedAdjacent
    ) -> SpaceSwitchRequestResult {
        guard let target = Self.adjacentTarget(
            offset: offset,
            stackID: stackID,
            in: topology,
            after: pendingByStackID[stackID]?.desiredTarget
        )
        else { return .noChange }
        return requestNavigation(
            to: target,
            in: topology,
            animation: animation,
            scheduling: scheduling
        )
    }

    private static func adjacentTarget(
        offset: Int,
        stackID: String,
        in topology: SpaceTopology,
        after pendingTarget: SpaceNavigationTarget? = nil
    ) -> SpaceNavigationTarget? {
        guard abs(offset) == 1,
              let stack = topology.stack(id: stackID),
              let originIndex = pendingTarget?.index ?? stack.currentSpaceIndex,
              stack.orderedSpaceIDs.indices.contains(originIndex + offset)
        else { return nil }
        let index = originIndex + offset
        return SpaceNavigationTarget(
            stackID: stackID,
            spaceID: stack.orderedSpaceIDs[index],
            index: index
        )
    }

    private mutating func requestNavigation(
        to target: SpaceNavigationTarget,
        in topology: SpaceTopology,
        animation: SpaceSwitchAnimation,
        scheduling: SpaceSwitchScheduling
    ) -> SpaceSwitchRequestResult {
        guard let stack = topology.stack(id: target.stackID),
              stack.orderedSpaceIDs.indices.contains(target.index),
              stack.orderedSpaceIDs[target.index] == target.spaceID,
              let currentSpaceID = stack.currentDesktopID,
              let currentIndex = stack.currentSpaceIndex
        else { return .declined }

        if var pending = pendingByStackID[target.stackID] {
            pending.desiredTarget = target
            pending.animation = animation
            pending.scheduling = scheduling
            pendingByStackID[target.stackID] = pending
            return .coalesced
        }

        guard currentSpaceID != target.spaceID else { return .noChange }
        let hops = Self.hops(
            from: currentIndex,
            toward: target,
            in: stack,
            animation: animation,
            scheduling: scheduling
        )
        guard !hops.isEmpty else { return .declined }
        pendingByStackID[target.stackID] = makePendingSwitch(
            desiredTarget: target,
            hops: hops,
            animation: animation,
            scheduling: scheduling
        )
        return .post(hops)
    }

    /// Confirms completed routes and returns at most one next route per Space stack.
    ///
    /// A different current Space is a user action or a Dock result Debut did not request.
    /// Continuing from it would fight the user, so an unexpected landing stops safely.
    mutating func desktopDidChange(to topology: SpaceTopology) -> [SpaceSwitchHop] {
        var nextHops: [SpaceSwitchHop] = []

        for stackID in Array(pendingByStackID.keys) {
            guard let pending = pendingByStackID[stackID],
                  let stack = topology.stack(id: stackID),
                  let currentSpaceID = stack.currentDesktopID,
                  let currentIndex = stack.currentSpaceIndex,
                  let expectedSpaceID = pending.expectedSpaceIDs.last,
                  pending.expectedSpaceIDs.allSatisfy({ stack.orderedSpaceIDs.contains($0) }),
                  stack.orderedSpaceIDs.indices.contains(pending.desiredTarget.index),
                  stack.orderedSpaceIDs[pending.desiredTarget.index]
                    == pending.desiredTarget.spaceID
            else {
                pendingByStackID.removeValue(forKey: stackID)
                continue
            }

            guard currentSpaceID == pending.originSpaceID
                    || pending.expectedSpaceIDs.contains(currentSpaceID)
            else {
                pendingByStackID.removeValue(forKey: stackID)
                continue
            }

            // Every gesture in an Instant route has already been posted. Intermediate
            // notifications acknowledge the route but must neither finish it nor post again.
            guard currentSpaceID == expectedSpaceID else { continue }

            guard currentSpaceID != pending.desiredTarget.spaceID else {
                pendingByStackID.removeValue(forKey: stackID)
                continue
            }

            let hops = Self.hops(
                from: currentIndex,
                toward: pending.desiredTarget,
                in: stack,
                animation: pending.animation,
                scheduling: pending.scheduling
            )
            guard !hops.isEmpty else {
                pendingByStackID.removeValue(forKey: stackID)
                continue
            }
            pendingByStackID[stackID] = makePendingSwitch(
                desiredTarget: pending.desiredTarget,
                hops: hops,
                animation: pending.animation,
                scheduling: pending.scheduling
            )
            nextHops.append(contentsOf: hops)
        }
        return nextHops
    }

    func recoveryTicket(matching hops: [SpaceSwitchHop]) -> SpaceSwitchRecoveryTicket? {
        guard let first = hops.first,
              let last = hops.last,
              let pending = pendingByStackID[first.stackID],
              pending.originSpaceID == first.fromSpaceID,
              pending.expectedSpaceIDs.last == last.toSpaceID
        else { return nil }
        return SpaceSwitchRecoveryTicket(
            stackID: first.stackID,
            generation: pending.generation
        )
    }

    /// Resolves a route whose active-space notification never arrived.
    ///
    /// A watchdog may only continue when fresh topology proves the exact posted endpoint is
    /// showing. Any origin, intermediate, unresolved, or unexpected state is abandoned so a
    /// later physical gesture starts from WindowServer truth instead of replaying stale input.
    mutating func recover(
        _ ticket: SpaceSwitchRecoveryTicket,
        in topology: SpaceTopology
    ) -> SpaceSwitchRecoveryResult {
        guard let pending = pendingByStackID[ticket.stackID],
              pending.generation == ticket.generation
        else { return .stale }

        guard let stack = topology.stack(id: ticket.stackID),
              let currentSpaceID = stack.currentDesktopID,
              let currentIndex = stack.currentSpaceIndex,
              let expectedSpaceID = pending.expectedSpaceIDs.last,
              pending.expectedSpaceIDs.allSatisfy({ stack.orderedSpaceIDs.contains($0) }),
              stack.orderedSpaceIDs.indices.contains(pending.desiredTarget.index),
              stack.orderedSpaceIDs[pending.desiredTarget.index] == pending.desiredTarget.spaceID,
              currentSpaceID == expectedSpaceID
        else {
            pendingByStackID.removeValue(forKey: ticket.stackID)
            return .abandoned
        }

        guard currentSpaceID != pending.desiredTarget.spaceID else {
            pendingByStackID.removeValue(forKey: ticket.stackID)
            return .completed
        }

        let hops = Self.hops(
            from: currentIndex,
            toward: pending.desiredTarget,
            in: stack,
            animation: pending.animation,
            scheduling: pending.scheduling
        )
        guard !hops.isEmpty else {
            pendingByStackID.removeValue(forKey: ticket.stackID)
            return .abandoned
        }
        pendingByStackID[ticket.stackID] = makePendingSwitch(
            desiredTarget: pending.desiredTarget,
            hops: hops,
            animation: pending.animation,
            scheduling: pending.scheduling
        )
        return .post(hops)
    }

    /// Drops every unconfirmed gesture. A Dock overview owns desktop navigation while it is
    /// visible, so a synthetic hop interrupted by that overview has no completion signal and
    /// must not keep later requests coalesced behind it forever.
    mutating func cancelPendingSwitches() {
        pendingByStackID.removeAll()
    }

    @discardableResult
    mutating func postingFailed(
        _ hops: [SpaceSwitchHop],
        ticket: SpaceSwitchRecoveryTicket? = nil
    ) -> Bool {
        guard let first = hops.first,
              let last = hops.last,
              let pending = pendingByStackID[first.stackID],
              ticket == nil || ticket?.generation == pending.generation,
              pending.originSpaceID == first.fromSpaceID,
              pending.expectedSpaceIDs.last == last.toSpaceID
        else { return false }
        pendingByStackID.removeValue(forKey: first.stackID)
        return true
    }

    private mutating func makePendingSwitch(
        desiredTarget: SpaceNavigationTarget,
        hops: [SpaceSwitchHop],
        animation: SpaceSwitchAnimation,
        scheduling: SpaceSwitchScheduling
    ) -> PendingSwitch {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        return PendingSwitch(
            generation: nextGeneration,
            desiredTarget: desiredTarget,
            originSpaceID: hops[0].fromSpaceID,
            expectedSpaceIDs: hops.map(\.toSpaceID),
            animation: animation,
            scheduling: scheduling
        )
    }

    private static func hops(
        from currentIndex: Int,
        toward target: SpaceNavigationTarget,
        in stack: SpaceStackDescriptor,
        animation: SpaceSwitchAnimation,
        scheduling: SpaceSwitchScheduling
    ) -> [SpaceSwitchHop] {
        guard let plan = SpaceSwitchPlan(
            from: currentIndex,
            to: target.index,
            spaceCount: stack.orderedSpaceIDs.count
        ) else { return [] }
        let delta = plan.direction == .right ? 1 : -1
        let count = scheduling == .batchedInstant ? plan.steps : 1
        return (0..<count).compactMap { offset in
            let fromIndex = currentIndex + offset * delta
            let toIndex = fromIndex + delta
            guard stack.orderedSpaceIDs.indices.contains(fromIndex),
                  stack.orderedSpaceIDs.indices.contains(toIndex)
            else { return nil }
            return SpaceSwitchHop(
                stackID: stack.id,
                fromSpaceID: stack.orderedSpaceIDs[fromIndex],
                toSpaceID: stack.orderedSpaceIDs[toIndex],
                direction: plan.direction,
                animation: animation
            )
        }
    }
}

// MARK: - Gesture events

enum DockSwipePhase: Equatable {
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

    static func instantPhases(for mode: DockSwipePostingMode) -> [DockSwipePhase] {
        switch mode {
        case .legacy: [.began, .ended]
        case .augmented: [.began, .changed, .ended]
        }
    }

    private static func fixed1616(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = (value * 65_536).rounded(.towardZero)
        let bounded = min(max(scaled, Double(Int32.min)), Double(Int32.max))
        let fixed = Int32(bounded)
        if fixed == 0, value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Encodes the packed IOHID queue entry the macOS 27 Dock validates against the ordinary
    /// CGEvent fields. The layout is the 28-byte queue header followed by one 40-byte fluid
    /// touch record and, on Ended, a 28-byte velocity record.
    private static func iohidPayload(for event: CGEvent) -> Data {
        let phase = event.getIntegerValueField(kCGEventGesturePhase)
        let velocityX = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
        let velocityY = event.getDoubleValueField(kCGEventGestureSwipeVelocityY)
        let includesVelocity = velocityX != 0 || velocityY != 0 || phase == kCGSGesturePhaseEnded
        var payload = Data()

        appendLittleEndian(event.timestamp == 0 ? mach_absolute_time() : event.timestamp, to: &payload)
        appendLittleEndian(UInt64(0), to: &payload)
        appendLittleEndian(UInt32(0), to: &payload)
        appendLittleEndian(UInt32(0), to: &payload)
        appendLittleEndian(UInt32(includesVelocity ? 2 : 1), to: &payload)

        appendLittleEndian(kIOHIDFluidTouchGestureDataSize, to: &payload)
        appendLittleEndian(kIOHIDEventTypeFluidTouchGesture, to: &payload)
        appendLittleEndian(UInt32((phase & 0xFF) << 24), to: &payload)
        appendLittleEndian(UInt8(0), to: &payload)
        payload.append(contentsOf: [0, 0, 0])
        appendLittleEndian(fixed1616(event.getDoubleValueField(kCGEventGesturePositionX)), to: &payload)
        appendLittleEndian(fixed1616(event.getDoubleValueField(kCGEventGesturePositionY)), to: &payload)
        appendLittleEndian(Int32(0), to: &payload)
        appendLittleEndian(UInt32(truncatingIfNeeded:
            event.getIntegerValueField(kCGEventGestureSwipeMask)), to: &payload)
        appendLittleEndian(UInt16(truncatingIfNeeded:
            event.getIntegerValueField(kCGEventGestureSwipeMotion)), to: &payload)
        appendLittleEndian(kIOHIDGestureFlavorDockPrimary, to: &payload)
        appendLittleEndian(fixed1616(event.getDoubleValueField(kCGEventGestureSwipeProgress)),
                           to: &payload)

        if includesVelocity {
            appendLittleEndian(kIOHIDVelocityEventDataSize, to: &payload)
            appendLittleEndian(kIOHIDEventTypeVelocity, to: &payload)
            appendLittleEndian(UInt32(0), to: &payload)
            appendLittleEndian(UInt8(1), to: &payload)
            payload.append(contentsOf: [0, 0, 0])
            appendLittleEndian(fixed1616(velocityX), to: &payload)
            appendLittleEndian(fixed1616(velocityY), to: &payload)
            appendLittleEndian(Int32(0), to: &payload)
        }
        return payload
    }

    private static func appendingPayload(_ payload: Data, to serialized: Data) -> Data? {
        guard payload.count <= Int(UInt16.max) else { return nil }
        var augmented = serialized
        augmented.append(UInt8(payload.count >> 8))
        augmented.append(UInt8(payload.count & 0xFF))
        augmented.append(UInt8(kCGEventIOHIDPayloadField >> 8))
        augmented.append(UInt8(kCGEventIOHIDPayloadField & 0xFF))
        augmented.append(payload)
        return augmented
    }

    /// Replaces the payload in a physical event without disturbing its other serialized fields.
    /// Unknown record shapes abort the cleanup rather than risking a corrupt event.
    private static func replacingPayload(_ payload: Data, in serialized: Data) -> Data? {
        guard serialized.count >= 4 else { return nil }
        var result = Data(serialized.prefix(4))
        var offset = 4
        var foundPayload = false

        while offset < serialized.count {
            guard offset + 4 <= serialized.count else { return nil }
            let elementSize = (UInt16(serialized[offset]) << 8)
                | UInt16(serialized[offset + 1])
            let tagAndField = (UInt16(serialized[offset + 2]) << 8)
                | UInt16(serialized[offset + 3])
            let tag = tagAndField >> 14
            let field = tagAndField & 0x3FFF
            let valueSize: Int
            switch (tag, elementSize) {
            case (0, 1): valueSize = 8
            case (0, let size) where size > 1: valueSize = Int(size)
            case (1, 1), (3, 1): valueSize = 4
            case (3, 2): valueSize = 8
            default: return nil
            }
            let recordEnd = offset + 4 + valueSize
            guard recordEnd <= serialized.count else { return nil }
            if field == kCGEventIOHIDPayloadField {
                foundPayload = true
            } else {
                result.append(serialized.subdata(in: offset..<recordEnd))
            }
            offset = recordEnd
        }

        guard foundPayload else { return nil }
        return appendingPayload(payload, to: result)
    }

    /// Binary fields are not writable through CGEvent's field setters. Flatten the event,
    /// append or replace field 4205, then inflate a new event carrying the matching payload.
    private static func augment(_ event: CGEvent, replacingExistingPayload: Bool = false) -> CGEvent? {
        guard let serialized = event.data as Data?, serialized.count >= 4,
              serialized.prefix(4).elementsEqual([0, 0, 0, 2])
        else { return nil }

        let payload = iohidPayload(for: event)
        let augmented = replacingExistingPayload
            ? replacingPayload(payload, in: serialized)
            : appendingPayload(payload, to: serialized)
        guard let augmented else { return nil }
        return CGEvent(withDataAllocator: kCFAllocatorDefault, data: augmented as CFData)
    }

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
        event.setIntegerValueField(.eventSourceUserData, value: DesktopSwipeService.syntheticMarker)
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

    /// Builds the schema selected for the running release. Legacy events retain their exact
    /// pre-27 fields. macOS 27 events add the mirrored fields, use a non-zero Began progress,
    /// then carry the matching raw IOHID payload in field 4205.
    static func makeForPosting(
        phase: DockSwipePhase,
        direction: SpaceSwitchDirection,
        velocity: Double,
        progress: Double,
        location: CGPoint? = nil,
        mode: DockSwipePostingMode,
        markSynthetic: Bool = true
    ) -> CGEvent? {
        guard case .augmented(let invertSigns) = mode else {
            return make(
                phase: phase,
                direction: direction,
                velocity: velocity,
                progress: progress,
                location: location
            )
        }

        guard let event = CGEvent(source: nil) else { return nil }
        if let location { event.location = location }
        let sign = direction.sign * (invertSigns ? -1 : 1)
        let signedProgress = sign * (phase == .began ? kIOHIDProgressEpsilon : progress)

        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
        event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(kCGEventGesturePhase, value: phase.raw)
        event.setIntegerValueField(kCGEventGesturePhase2, value: phase.raw)
        event.setIntegerValueField(kCGEventGestureSwipeMotion, value: kGestureMotionHorizontal)
        event.setDoubleValueField(kCGEventGestureSwipeProgress, value: signedProgress)
        event.setDoubleValueField(kCGEventGestureFlavor,
                                  value: Double(kIOHIDGestureFlavorDockPrimary))
        event.setDoubleValueField(kCGEventGestureTimestamp, value: Double(mach_absolute_time()))
        event.setDoubleValueField(kCGEventGesturePositionX, value: 0.1)
        if phase == .ended {
            event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: sign * velocity)
        }

        guard let augmented = augment(event) else { return nil }
        if markSynthetic {
            augmented.setIntegerValueField(.eventSourceUserData,
                                           value: DesktopSwipeService.syntheticMarker)
        }
        return augmented
    }

    /// Rebuilds a physical macOS 27 terminal event with no movement in either representation.
    /// Dock still needs the Ended phase to close the gesture it saw begin; swallowing it leaves
    /// the next physical swipe attached to stale state.
    static func cleanupPhysicalEnded(_ event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(kCGEventGesturePhase) == kCGSGesturePhaseEnded,
              let cleanup = event.copy()
        else { return nil }
        cleanup.setDoubleValueField(kCGEventGestureSwipeProgress, value: 0)
        cleanup.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0)
        cleanup.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
        return augment(cleanup, replacingExistingPayload: true)
    }

    /// The envelope event the Dock expects alongside each dock-control event.
    static func makeEnvelope(location: CGPoint? = nil) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: DesktopSwipeService.syntheticMarker)
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
        location: CGPoint? = nil,
        mode: DockSwipePostingMode = .legacy
    ) -> Bool {
        postSwitches(
            directions: [direction],
            velocity: velocity,
            location: location,
            mode: mode
        )
    }

    /// Builds every event in an Instant route before posting any of them. A distant switch is
    /// several adjacent gestures, but presenting it as one batch keeps Dock from settling on an
    /// intermediate desktop. Preparing the whole batch first also makes allocation failure
    /// all-or-nothing instead of leaving the route half posted.
    @discardableResult
    static func postSwitches(
        directions: [SpaceSwitchDirection],
        velocity: Double,
        location: CGPoint? = nil,
        mode: DockSwipePostingMode = .legacy
    ) -> Bool {
        guard !directions.isEmpty else { return false }
        let phases = instantPhases(for: mode).map { phase -> (DockSwipePhase, Double, Double) in
            switch (mode, phase) {
            case (.legacy, .ended): (phase, velocity, kInstantSwitchProgress)
            case (.legacy, _): (phase, 0, kInstantSwitchProgress)
            case (.augmented, .ended): (phase, kAugmentedInstantSwitchVelocity, 1)
            case (.augmented, _): (phase, 0, 1)
            }
        }
        var events: [(CGEvent, CGEvent)] = []
        for direction in directions {
            let hopEvents = phases.compactMap {
                phase, phaseVelocity, progress -> (CGEvent, CGEvent)? in
                guard let control = makeForPosting(
                    phase: phase,
                    direction: direction,
                    velocity: phaseVelocity,
                    progress: progress,
                    location: location,
                    mode: mode
                ), let envelope = makeEnvelope(location: location) else { return nil }
                return (control, envelope)
            }
            guard hopEvents.count == phases.count else { return false }
            events.append(contentsOf: hopEvents)
        }

        for (control, envelope) in events {
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
                                 mode: DockSwipePostingMode = .legacy,
                                 isCancelled: () -> Bool = { false }) -> Bool {
        let releaseVelocity = mode == .legacy
            ? kAnimatedReleaseVelocity : kAugmentedInstantSwitchVelocity
        guard let began = makeForPosting(
            phase: .began, direction: direction, velocity: 0, progress: 1,
            location: location, mode: mode
        ), let beganEnvelope = makeEnvelope(location: location),
              let ended = makeForPosting(
                phase: .ended, direction: direction, velocity: releaseVelocity, progress: 1,
                location: location, mode: mode
              ),
              let endedEnvelope = makeEnvelope(location: location)
        else { return false }

        let start = DispatchTime.now()
        began.post(tap: .cgSessionEventTap)
        beganEnvelope.post(tap: .cgSessionEventTap)

        for sample in samples.dropLast() {
            guard !isCancelled() else { break }
            wait(untilElapsed: sample.delay, since: start)
            guard let changed = makeForPosting(
                    phase: .changed, direction: direction, velocity: 0,
                    progress: sample.progress, location: location, mode: mode
                  ),
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

/// What the window server says about a batch of surfaces that no other channel can see.
///
/// Both readings answer from any desktop, which is the point: Core Graphics describes a dismissed
/// popup exactly as it describes a real window, and Accessibility can only contradict one while
/// its own desktop is showing. These arrive on their own.
public struct WindowServerVerdicts: Sendable, Equatable {
    /// Surfaces raised over another window — sheets, and an app's own popups.
    public var parented: Set<CGWindowID> = []
    /// Surfaces the window server will not draw and does not attribute to minimizing. Hiding an
    /// app lands here too; `AccessibilityWindowService.orderedOutGhostWindowIDs` separates that.
    public var orderedOut: Set<CGWindowID> = []
    /// The app-hide tag belongs to this window, not merely to its process. A stale popup from
    /// the same hidden app can be ordered out without carrying this tag.
    public var hiddenByApp: Set<CGWindowID> = []

    public init(parented: Set<CGWindowID> = [], orderedOut: Set<CGWindowID> = [],
                hiddenByApp: Set<CGWindowID> = []) {
        self.parented = parented
        self.orderedOut = orderedOut
        self.hiddenByApp = hiddenByApp
    }
}

/// Where spaces get their desktops. Kept as a protocol so space-switching logic can be
/// tested without a window server — nothing else about a Space switch is observable in a
/// unit test.
public protocol SpaceSwitching: AnyObject, Sendable {
    func spaceTopology() -> SpaceTopology
    /// The most recently observed topology. Production uses this on the presentation path so a
    /// WindowServer round trip cannot delay an overlay; simple conformers may answer live.
    func cachedSpaceTopology() -> SpaceTopology?
    func desktopLocation(forWindow windowID: CGWindowID) -> DesktopLocation?
    func desktopLocations(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: DesktopLocation]
    /// Every window on every desktop, keyed by window ID. Unlike `desktopLocations(forWindows:)`
    /// this does not start from a set of window IDs to resolve — `kAXWindows` only reports
    /// windows on the active Space, so this is how a window on another desktop is discovered
    /// at all, not just located once already known.
    func windowLocations() -> [CGWindowID: DesktopLocation]
    /// Every window SkyLight puts on a desktop, including the ones on more than one that
    /// `windowLocations()` drops for having no single answer. Absence from this set is the
    /// difference between "on every desktop" and "on no desktop at all", which the location
    /// map alone collapses into the same missing key.
    func placedWindowIDs() -> Set<CGWindowID>
    /// What the window server volunteers about a batch of surfaces. Empty means nothing is known,
    /// which is why the default conformance can return nothing without evicting.
    func windowServerVerdicts(among candidates: [CGWindowID]) -> WindowServerVerdicts
    func desktopCount() -> Int
    func currentDesktopIndex() -> Int?
    func desktopIndex(forWindow windowID: CGWindowID) -> Int?
    /// Declared here, not only in the extension, so a conformer's faster batch
    /// implementation is reached through an `any SpaceSwitching` too.
    func desktopIndexes(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: Int]
    @discardableResult func switchToDesktop(index: Int) -> Bool
    @discardableResult func switchToDesktop(_ location: DesktopLocation) -> Bool
    /// Switches one position in Mission Control order, including fullscreen and tiled Spaces.
    @discardableResult func switchToAdjacentSpace(offset: Int, stackID: String) -> Bool
    /// Switches through Dock at macOS's standard slide duration, ignoring Debut's configured
    /// acceleration. This is used for Debut-owned selections while the speed feature is off;
    /// physical system shortcuts remain completely unhandled by Debut.
    @discardableResult func switchToDesktopWithSystemAnimation(_ location: DesktopLocation) -> Bool
    /// True from the first posted route until WindowServer confirms the final target Space.
    func isSwitchInFlight(stackID: String) -> Bool
    /// Confirms a route or advances an animated multi-hop switch from current topology.
    func spaceDidChange()
    /// Cancels unconfirmed synthetic hops before a Dock overview takes ownership of navigation.
    func cancelPendingSwitches()
    /// Whether this conformer can reassign a window's desktop at all. False means the move
    /// commands should stay inert rather than mutate the model and lie about the result.
    var canMoveWindows: Bool { get }
    func moveWindow(windowID: CGWindowID, toDesktop: Int,
                    completion: (@Sendable (Bool) -> Void)?)
    func moveWindow(windowID: CGWindowID, to location: DesktopLocation,
                    completion: (@Sendable (Bool) -> Void)?)
    /// Sets which process a desktop shows as frontmost the next time it is revealed.
    ///
    /// Aimed at a desktop that is not showing, so that a switch can land with the right app
    /// already forward instead of reordering in front of the user once the transition ends.
    @discardableResult
    func setFrontProcess(pid: pid_t, onDesktop desktopID: CGSSpaceID) -> Bool
}

public extension SpaceSwitching {
    func cachedSpaceTopology() -> SpaceTopology? { spaceTopology() }
    func windowServerVerdicts(among candidates: [CGWindowID]) -> WindowServerVerdicts {
        WindowServerVerdicts()
    }
    func placedWindowIDs() -> Set<CGWindowID> { Set(windowLocations().keys) }
    func isSwitchInFlight(stackID: String) -> Bool { false }
    func spaceDidChange() {}
    func cancelPendingSwitches() {}
    func setFrontProcess(pid: pid_t, onDesktop desktopID: CGSSpaceID) -> Bool { false }

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

    /// A conformer that has no per-Space enumeration of its own — every mock, and any future
    /// conformer that only ever resolves windows it already knows about — reports none rather
    /// than failing to build.
    func windowLocations() -> [CGWindowID: DesktopLocation] { [:] }

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

    @discardableResult
    func switchToDesktopWithSystemAnimation(_ location: DesktopLocation) -> Bool {
        switchToDesktop(location)
    }

    @discardableResult
    func switchToAdjacentSpace(offset: Int, stackID: String) -> Bool {
        guard abs(offset) == 1,
              let stack = spaceTopology().stack(id: stackID),
              let currentIndex = stack.currentSpaceIndex,
              stack.orderedSpaceIDs.indices.contains(currentIndex + offset),
              let desktopIndex = stack.desktopIDs.firstIndex(
                  of: stack.orderedSpaceIDs[currentIndex + offset]
              ),
              let location = stack.location(at: desktopIndex)
        else { return false }
        return switchToDesktop(location)
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
    private let switchQueue = DispatchQueue(
        label: "com.thomplth.debut.space-switch",
        qos: .userInteractive
    )
    private let switchCoordinatorLock = NSLock()
    private var switchCoordinator = SpaceSwitchCoordinator()
    var onSwitchRecovery: (@Sendable () -> Void)?

    /// Confirming a move means re-reading the assignment until the window server catches up.
    /// That settles in single-digit milliseconds, but it is still a wait, and the main thread
    /// runs the event tap.
    private let moveQueue = DispatchQueue(
        label: "com.thomplth.debut.space-move",
        qos: .userInteractive
    )
    private let topologyCacheLock = NSLock()
    private var storedTopology: SpaceTopology?

    let nativeDesktopShortcut: NativeDesktopShortcutSwitch
    private let nativeRouteLock = NSLock()
    private var nativeRoutes = NativeShortcutRouteTracker()

    public convenience init() {
        self.init(nativeDesktopShortcut: NativeDesktopShortcutSwitch(
            hotKeys: WindowServerSymbolicHotKeys(),
            scheduleRestore: { delay, restore in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: restore)
            }
        ))
    }

    init(nativeDesktopShortcut: NativeDesktopShortcutSwitch) {
        self.nativeDesktopShortcut = nativeDesktopShortcut
    }

    public func cachedSpaceTopology() -> SpaceTopology? {
        topologyCacheLock.withLock { storedTopology }
    }

    private func cache(_ topology: SpaceTopology) -> SpaceTopology {
        if !topology.stacks.isEmpty {
            topologyCacheLock.withLock { storedTopology = topology }
        }
        return topology
    }

    public func desktopCount() -> Int { spaceTopology().stacks.first?.desktopIDs.count ?? 0 }

    private var connection: CGSConnectionID? {
        guard let cgsMainConnectionID else { return nil }
        let cid = cgsMainConnectionID()
        return cid == 0 ? nil : cid
    }

    /// Future releases stay disabled until their private DockSwipe schema is measured.
    /// macOS 27 is supported through its validated, packed IOHID event path.
    public var canSwitchSpaces: Bool {
        DockSwipeCompatibility.supports(
            operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    // MARK: Reading

    private func managedDisplaySpaces() -> [[String: Any]] {
        guard let connection, let cgsCopyManagedDisplaySpaces else { return [] }
        return cgsCopyManagedDisplaySpaces(connection, nil)?
            .takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// The user desktops of one display, read once so the two identities cannot disagree
    /// about order or length.
    ///
    /// `id64` is a per-session counter — a fresh login renumbers it — while `uuid` is what
    /// `com.apple.spaces` persists, so the uuid is the identity that outlives a reboot and
    /// the id64 is what the switch machinery addresses. `uuids` comes back empty unless every
    /// desktop supplied one, because a partial list would join some spaces and silently
    /// mis-join the rest.
    static func spaceIdentities(
        in display: [String: Any]
    ) -> (
        desktopIDs: [CGSSpaceID],
        desktopUUIDs: [String],
        orderedSpaceIDs: [CGSSpaceID]
    ) {
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        var desktopIDs: [CGSSpaceID] = []
        var desktopUUIDs: [String] = []
        var orderedSpaceIDs: [CGSSpaceID] = []
        for space in spaces {
            guard let id = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            orderedSpaceIDs.append(id)
            guard (space["type"] as? NSNumber)?.intValue ?? 0 == 0 else { continue }
            desktopIDs.append(id)
            if let uuid = space["uuid"] as? String, !uuid.isEmpty {
                desktopUUIDs.append(uuid)
            }
        }
        return (
            desktopIDs,
            desktopUUIDs.count == desktopIDs.count ? desktopUUIDs : [],
            orderedSpaceIDs
        )
    }

    private static func currentDesktopID(in display: [String: Any]) -> CGSSpaceID? {
        ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
    }

    private static func currentDesktopUUID(in display: [String: Any]) -> String? {
        (display["Current Space"] as? [String: Any])?["uuid"] as? String
    }

    private static func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The display-scoped desktop lists Mission Control owns right now.
    public func spaceTopology() -> SpaceTopology {
        let managed = managedDisplaySpaces()
        guard !managed.isEmpty else {
            return SpaceTopology(separateSpaces: false, stacks: [])
        }

        let screens = NSScreen.screens
        let separate = NSScreen.screensHaveSeparateSpaces
        if !separate {
            let display = managed.first(where: {
                ($0["Display Identifier"] as? String) == "Main"
            }) ?? managed[0]
            let frames = screens.map(\.frame)
            let frame = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
            let spaces = Self.spaceIdentities(in: display)
            return cache(SpaceTopology(separateSpaces: false, stacks: [
                SpaceStackDescriptor(
                    id: SpaceTopology.sharedStackID,
                    displayID: NSScreen.main?.displayID,
                    displayName: "All Displays",
                    frame: frame,
                    desktopIDs: spaces.desktopIDs,
                    orderedSpaceIDs: spaces.orderedSpaceIDs,
                    desktopUUIDs: spaces.desktopUUIDs,
                    currentDesktopID: Self.currentDesktopID(in: display),
                    currentDesktopUUID: Self.currentDesktopUUID(in: display)
                ),
            ]))
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
            let spaces = Self.spaceIdentities(in: display)
            descriptors.append(SpaceStackDescriptor(
                id: uuid,
                displayID: screen.displayID,
                displayName: name,
                frame: screen.frame,
                desktopIDs: spaces.desktopIDs,
                orderedSpaceIDs: spaces.orderedSpaceIDs,
                desktopUUIDs: spaces.desktopUUIDs,
                currentDesktopID: Self.currentDesktopID(in: display),
                currentDesktopUUID: Self.currentDesktopUUID(in: display)
            ))
        }
        for display in remaining {
            guard let identifier = display["Display Identifier"] as? String else { continue }
            let spaces = Self.spaceIdentities(in: display)
            descriptors.append(SpaceStackDescriptor(
                id: identifier,
                displayID: nil,
                displayName: "Display \(descriptors.count + 1)",
                frame: .zero,
                desktopIDs: spaces.desktopIDs,
                orderedSpaceIDs: spaces.orderedSpaceIDs,
                desktopUUIDs: spaces.desktopUUIDs,
                currentDesktopID: Self.currentDesktopID(in: display),
                currentDesktopUUID: Self.currentDesktopUUID(in: display)
            ))
        }
        return cache(SpaceTopology(separateSpaces: true, stacks: descriptors))
    }

    /// User desktops on the first stack, retained for compatibility with index-only callers.
    ///
    /// Fullscreen and tiled Spaces are excluded — only `type == 0` entries are desktops a
    /// space can map onto.
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

    /// Which space a window belongs to, or `nil` when it does not belong to exactly one.
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

    /// Every window on every desktop, one `SLSCopyWindowsWithOptionsAndTags` call per desktop.
    /// `kAXWindows` cannot see a desktop that is not showing, so this is the only path that
    /// finds a window there at all.
    ///
    /// A window assigned to every Space (Finder, on some systems) is enumerated once per
    /// desktop queried, not once overall — the same way `desktopLocation(forWindow:)` treats
    /// more than one space as no single answer, a window seen on a second, different desktop
    /// here is dropped rather than left pointing at whichever desktop was queried last.
    public func windowLocations() -> [CGWindowID: DesktopLocation] {
        enumerateDesktopWindows().locations
    }

    public func placedWindowIDs() -> Set<CGWindowID> {
        let enumeration = enumerateDesktopWindows()
        return Set(enumeration.locations.keys).union(enumeration.shared)
    }

    private func enumerateDesktopWindows()
        -> (locations: [CGWindowID: DesktopLocation], shared: Set<CGWindowID>) {
        guard let connection, let slsCopyWindowsWithOptionsAndTags else { return ([:], []) }
        let topology = spaceTopology()
        var result: [CGWindowID: DesktopLocation] = [:]
        var ambiguous: Set<CGWindowID> = []
        for stack in topology.stacks {
            for (index, desktopID) in stack.desktopIDs.enumerated() {
                var setTags: UInt64 = 0
                var clearTags: UInt64 = 0
                guard let windowIDs = slsCopyWindowsWithOptionsAndTags(
                    connection, 0, [NSNumber(value: desktopID)] as CFArray,
                    kWindowEnumerationOptions, &setTags, &clearTags
                )?.takeRetainedValue() as? [NSNumber] else { continue }
                let location = DesktopLocation(stackID: stack.id, desktopID: desktopID, index: index)
                for number in windowIDs {
                    let windowID = number.uint32Value
                    if let existing = result[windowID], existing != location {
                        ambiguous.insert(windowID)
                    } else {
                        result[windowID] = location
                    }
                }
            }
        }
        for windowID in ambiguous { result.removeValue(forKey: windowID) }
        return (result, ambiguous)
    }

    /// What the window server itself says about a batch of surfaces: which it attaches to another
    /// window — sheets, and the popups an app raises over one of its own windows — and which it
    /// has ordered out for no reason it will name.
    ///
    /// An empty result means "nothing is known", never "nothing is true", so a failed query errs
    /// towards admitting a window rather than parking a real one.
    public func windowServerVerdicts(among candidates: [CGWindowID]) -> WindowServerVerdicts {
        guard let connection, !candidates.isEmpty,
              let slsWindowQueryWindows, let slsWindowQueryResultCopyWindows,
              let slsWindowIteratorAdvance, let slsWindowIteratorGetWindowID,
              let slsWindowIteratorGetParentID, let slsWindowIteratorGetAttributes,
              let slsWindowIteratorGetTags
        else { return WindowServerVerdicts() }

        let identifiers = candidates.map { NSNumber(value: $0) } as CFArray
        guard let query = slsWindowQueryWindows(connection, identifiers, Int32(candidates.count)),
              let iterator = slsWindowQueryResultCopyWindows(query)
        else { return WindowServerVerdicts() }

        var verdicts = WindowServerVerdicts()
        while slsWindowIteratorAdvance(iterator) {
            let windowID = slsWindowIteratorGetWindowID(iterator)
            if slsWindowIteratorGetParentID(iterator) != 0 {
                verdicts.parented.insert(windowID)
            }
            // Minimizing clears the same bit, so it is filtered out here rather than by the
            // caller: the tag that names it is only reachable from this iterator.
            let tags = slsWindowIteratorGetTags(iterator)
            if tags & hiddenAppTag != 0 {
                verdicts.hiddenByApp.insert(windowID)
            }
            if slsWindowIteratorGetAttributes(iterator) & orderedInAttribute == 0,
               tags & minimizedTag == 0 {
                verdicts.orderedOut.insert(windowID)
            }
        }
        return verdicts
    }

    // MARK: Switching

    /// Switches the visible Space by forging a trackpad swipe.
    ///
    /// At a zero duration this is a single high-velocity flick per hop, which the Dock
    /// resolves by cutting straight to the target. At any other duration Debut drives the
    /// gesture's progress itself, and the switch takes `switchDuration` per Space crossed.
    ///
    /// Returns whether the switch was started. A driven slide runs off the main thread, so
    /// the desktop has not changed by the time this returns — callers wanting the new desktop
    /// wait for `activeSpaceDidChangeNotification`, which they must do regardless.
    @discardableResult
    public func switchToDesktop(index target: Int) -> Bool {
        guard let location = spaceTopology().stacks.first?.location(at: target) else { return false }
        return switchToDesktop(location)
    }

    /// Switches a particular display's visible desktop. The synthetic gesture is located
    /// on that display so the Dock applies it to the matching Space list when displays use
    /// separate Spaces.
    @discardableResult
    public func switchToDesktop(_ location: DesktopLocation) -> Bool {
        requestSwitch(to: location, animation: .configured)
    }

    /// Prefers macOS's own Switch to Desktop N, which the Dock answers with one direct
    /// transition. The addressed swipe route stays as the fallback for a desktop the shortcut
    /// cannot reach, and for a shortcut the Dock did not act on.
    @discardableResult
    public func switchToDesktopWithSystemAnimation(_ location: DesktopLocation) -> Bool {
        let coalesced = nativeRouteLock.withLock { () -> Bool in
            guard nativeRoutes.isInFlight(stackID: location.stackID) else { return false }
            _ = nativeRoutes.request(location, originID: 0)
            return true
        }
        if coalesced {
            DiagnosticReporter.shared.report("desktop_switch_native_shortcut_coalesced", details: [
                "desktop": "\(location.index + 1)",
            ])
            return true
        }

        let topology = spaceTopology()
        let swipeRouteInFlight = switchCoordinatorLock.withLock {
            switchCoordinator.isInFlight(stackID: location.stackID)
        }
        guard !swipeRouteInFlight,
              let originID = topology.stack(id: location.stackID)?.currentDesktopID,
              let resolved = nativeDesktopShortcut.resolve(location, in: topology),
              case .start(let generation) = nativeRouteLock.withLock({
                  nativeRoutes.request(location, originID: originID)
              })
        else { return requestSwitch(to: location, animation: .system) }

        // A window raised to front for this reveal is reordered by its app on that app's next
        // screen update, measured landing about 6ms after the request returns. The transition
        // reveals the destination from its first frame, so it starts one frame later.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.nativeShortcutRevealDelay) {
            [weak self] in
            guard let self,
                  self.nativeRouteLock.withLock({
                      self.nativeRoutes.route(stackID: location.stackID)?.generation == generation
                  })
            else { return }
            let posted = self.nativeDesktopShortcut.post(resolved)
            DiagnosticReporter.shared.report("desktop_switch_native_shortcut_posted", details: [
                "desktop": "\(location.index + 1)",
                "hotKeyID": "\(resolved.hotKeyID)",
                "temporarilyEnabled": "\(resolved.temporarilyEnabled)",
                "posted": "\(posted)",
            ])
            guard posted else {
                if let target = self.nativeRouteLock.withLock({
                    self.nativeRoutes.postingFailed(generation: generation, stackID: location.stackID)
                }) {
                    _ = self.requestSwitch(to: target, animation: .system)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.nativeShortcutFallbackDelay) {
                [weak self] in
                self?.fallBackIfNativeShortcutMissed(stackID: location.stackID,
                                                     generation: generation)
            }
        }
        return true
    }

    /// One display frame.
    static let nativeShortcutRevealDelay: TimeInterval = 1.0 / 60

    /// Past the length of any Dock transition, including the Reduce Motion fade.
    static let nativeShortcutFallbackDelay: TimeInterval = 1.5

    /// A keystroke the Dock did not act on leaves the origin showing and nothing else to wait
    /// for, so the request continues on the swipe route. Any other desktop showing is a result
    /// — the requested one, or one the user chose meanwhile — and is left alone.
    private func fallBackIfNativeShortcutMissed(stackID: String, generation: UInt64) {
        let current = spaceTopology().stack(id: stackID)?.currentDesktopID
        guard let target = nativeRouteLock.withLock({
            nativeRoutes.missed(generation: generation, stackID: stackID, currentDesktopID: current)
        }) else { return }
        let continued = requestSwitch(to: target, animation: .system)
        DiagnosticReporter.shared.report("desktop_switch_native_shortcut_missed", details: [
            "desktop": "\(target.index + 1)",
            "fallbackPosted": "\(continued)",
        ])
    }

    @discardableResult
    public func switchToAdjacentSpace(offset: Int, stackID: String) -> Bool {
        guard canSwitchSpaces, abs(offset) == 1 else { return false }
        let topology = spaceTopology()
        let scheduling = SpaceSwitchAnimation.configured.scheduling(
            configuredDuration: switchDuration
        )
        let request = switchCoordinatorLock.withLock {
            switchCoordinator.requestAdjacent(
                offset: offset,
                stackID: stackID,
                in: topology,
                scheduling: scheduling
            )
        }
        return handleSwitchRequest(request, in: topology)
    }

    private func requestSwitch(
        to location: DesktopLocation,
        animation: SpaceSwitchAnimation
    ) -> Bool {
        guard canSwitchSpaces else { return false }
        let topology = spaceTopology()
        let scheduling = animation.scheduling(configuredDuration: switchDuration)
        let request = switchCoordinatorLock.withLock {
            switchCoordinator.request(
                to: location,
                in: topology,
                animation: animation,
                scheduling: scheduling
            )
        }

        return handleSwitchRequest(request, in: topology)
    }

    private func handleSwitchRequest(
        _ request: SpaceSwitchRequestResult,
        in topology: SpaceTopology
    ) -> Bool {
        switch request {
        case .declined, .noChange:
            return false
        case .coalesced:
            return true
        case .post(let hops):
            return postRoute(hops, in: topology)
        }
    }

    public func isSwitchInFlight(stackID: String) -> Bool {
        switchCoordinatorLock.withLock {
            switchCoordinator.isInFlight(stackID: stackID)
        } || nativeRouteLock.withLock {
            nativeRoutes.isInFlight(stackID: stackID)
        }
    }

    /// Called from `activeSpaceDidChangeNotification`, after WindowServer has settled one hop.
    public func spaceDidChange() {
        let topology = spaceTopology()
        let nextHops = switchCoordinatorLock.withLock {
            switchCoordinator.desktopDidChange(to: topology)
        }
        let routes = Dictionary(grouping: nextHops, by: \.stackID)
        for route in routes.values { _ = postRoute(route, in: topology) }

        let showing = Dictionary(uniqueKeysWithValues: topology.stacks.compactMap { stack in
            stack.currentDesktopID.map { (stack.id, $0) }
        })
        let arrivals = nativeRouteLock.withLock {
            nativeRoutes.desktopDidChange(currentDesktopIDs: showing)
        }
        for case .continueTo(let target) in arrivals.values {
            _ = switchToDesktopWithSystemAnimation(target)
        }
    }

    public func cancelPendingSwitches() {
        switchCoordinatorLock.withLock {
            switchCoordinator.cancelPendingSwitches()
        }
        nativeRouteLock.withLock { nativeRoutes.cancelAll() }
    }

    private func postRoute(_ hops: [SpaceSwitchHop], in topology: SpaceTopology) -> Bool {
        guard let ticket = switchCoordinatorLock.withLock({
            switchCoordinator.recoveryTicket(matching: hops)
        }) else { return false }
        guard post(hops, in: topology, ticket: ticket) else {
            _ = switchCoordinatorLock.withLock {
                switchCoordinator.postingFailed(hops, ticket: ticket)
            }
            return false
        }
        armSwitchRecovery(for: ticket, hops: hops)
        return true
    }

    private func armSwitchRecovery(
        for ticket: SpaceSwitchRecoveryTicket,
        hops: [SpaceSwitchHop]
    ) {
        guard let first = hops.first else { return }
        let routeDuration = first.animation.duration(configuredDuration: switchDuration)
        let delay = max(1.5, routeDuration + 1)
        let armedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.recoverSwitch(ticket, armedAt: armedAt)
        }
    }

    private func recoverSwitch(
        _ ticket: SpaceSwitchRecoveryTicket,
        armedAt: TimeInterval
    ) {
        let topology = spaceTopology()
        let result = switchCoordinatorLock.withLock {
            switchCoordinator.recover(ticket, in: topology)
        }
        let outcome: String
        switch result {
        case .stale:
            return
        case .completed:
            outcome = "completed"
        case .abandoned:
            outcome = "abandoned"
        case .post(let hops):
            outcome = postRoute(hops, in: topology) ? "continued" : "continuation_post_failed"
        }
        DiagnosticReporter.shared.report("desktop_switch_watchdog_recovered", details: [
            "elapsedMilliseconds": String(
                format: "%.1f",
                (ProcessInfo.processInfo.systemUptime - armedAt) * 1_000
            ),
            "generation": "\(ticket.generation)",
            "outcome": outcome,
            "stackID": ticket.stackID,
        ])
        onSwitchRecovery?()
    }

    /// Posts one confirmed animated hop or a complete Instant route. The coordinator never
    /// starts a second route while this one is unconfirmed, so batching the hops that belong to
    /// one requested endpoint does not restore the overlapping-request overshoot this replaced.
    private func post(
        _ hops: [SpaceSwitchHop],
        in topology: SpaceTopology,
        ticket: SpaceSwitchRecoveryTicket
    ) -> Bool {
        guard let first = hops.first,
              let stack = topology.stack(id: first.stackID),
              stack.currentDesktopID == first.fromSpaceID,
              hops.allSatisfy({ hop in
                  guard hop.stackID == first.stackID,
                        hop.animation == first.animation,
                        let from = stack.orderedSpaceIDs.firstIndex(of: hop.fromSpaceID),
                        let to = stack.orderedSpaceIDs.firstIndex(of: hop.toSpaceID)
                  else { return false }
                  return abs(to - from) == 1
                      && (hop.direction == .right ? to > from : to < from)
              }),
              zip(hops, hops.dropFirst()).allSatisfy({ pair in
                  pair.0.toSpaceID == pair.1.fromSpaceID
              }),
              let postingMode = DockSwipeCompatibility.currentMode
        else { return false }
        let eventLocation: CGPoint? = stack.displayID.map { displayID in
            let bounds = CGDisplayBounds(displayID)
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }

        let duration = first.animation.duration(configuredDuration: switchDuration)
        let samples = DockSwipeAnimation.samples(duration: duration)
        guard !samples.isEmpty else {
            return DockSwipeEvent.postSwitches(
                directions: hops.map(\.direction),
                velocity: first.instantVelocity,
                location: eventLocation,
                mode: postingMode
            )
        }

        guard hops.count == 1 else { return false }
        switchQueue.async { [self] in
            let posted = DockSwipeEvent.postDrivenSwitch(
                direction: first.direction,
                samples: samples,
                location: eventLocation,
                mode: postingMode
            )
            if !posted {
                let cleared = switchCoordinatorLock.withLock {
                    switchCoordinator.postingFailed(hops, ticket: ticket)
                }
                if cleared {
                    DiagnosticReporter.shared.report("desktop_switch_post_failed", details: [
                        "generation": "\(ticket.generation)",
                        "stackID": ticket.stackID,
                    ])
                    onSwitchRecovery?()
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

    /// Writes the destination desktop's front-process memory ahead of a switch.
    ///
    /// Returns whether the window server accepted the write. A refusal is not worth recovering
    /// from: the switch still happens, and the only cost is the reorder becoming visible again.
    @discardableResult
    public func setFrontProcess(pid: pid_t, onDesktop desktopID: CGSSpaceID) -> Bool {
        guard let getProcessForPID, let slsSpaceSetFrontPSN,
              let connection = cgsMainConnectionID?()
        else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        return slsSpaceSetFrontPSN(connection, desktopID, psn) == .success
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
