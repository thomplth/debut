import Foundation
import CoreGraphics

public struct FrontWindowRequest: Equatable, Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t

    public init(windowID: CGWindowID, ownerPID: pid_t) {
        self.windowID = windowID
        self.ownerPID = ownerPID
    }
}

public final class MockWindowService: WindowService, @unchecked Sendable {
    public var apps: [AppInfo] = []
    public var windowList: [WindowInfo] = []
    public var untrackableWindowIDList: Set<CGWindowID> = []
    public var disqualifiedWindowIDList: Set<CGWindowID> = []
    public var undersizedWindowIDList: Set<CGWindowID> = []
    public var axContradictedWindowIDList: Set<CGWindowID> = []
    public var parentedWindowIDList: Set<CGWindowID> = []
    public var orderedOutWindowIDList: Set<CGWindowID> = []
    public var allWindowIDList: Set<CGWindowID>?
    public var raisedWindowIDs: [CGWindowID] = []
    public var raisedWindowID: CGWindowID?
    public var closedWindowIDs: [CGWindowID] = []
    public var closeWindowResult: Bool = true
    public var activatedBundleID: String?
    public var activatedPID: pid_t?
    public var frontedWindows: [FrontWindowRequest] = []
    /// The window server declines a fronting request for a window it no longer knows. A mock that
    /// cannot refuse can only ever prove Debut asked, never that it noticed the answer — which is
    /// how an activation that macOS had stopped honouring stayed green for a day.
    public var frontWindowResult: Bool = true
    public var frontWindowDeliveryTrace: FrontWindowDeliveryTrace?
    public var visibleFrontWindowID: CGWindowID?
    public var focusObservation: WindowFocusObservation?
    public var focusObservationCount = 0
    /// Holds deferred raises until `runHeldRaises`, the way the Accessibility service holds them on
    /// its own queue. Off by default, so a deferred raise lands before the caller returns.
    public var holdsDeferredRaises = false
    private var heldRaises: [() -> Void] = []
    /// Who macOS reports as frontmost afterwards, which is a separate answer from the one above:
    /// the window server takes a request it then does not honour, and reports success either way.
    public var frontmostPID: pid_t?
    public var activateAppResult: Bool = true
    public var terminatedPIDs: [pid_t] = []
    public var terminateAppResult: Bool = true
    public var capturedImages: [CGWindowID: CGImage] = [:]
    public var accessibilityEnabled: Bool = true

    private let captureLock = NSLock()
    private var recordedCaptureRequests: [[CGWindowID]] = []

    /// One entry per `captureWindowImages` call, in call order.
    public var captureRequests: [[CGWindowID]] {
        captureLock.withLock { recordedCaptureRequests }
    }

    public init() {}

    public func listRunningApps() -> [AppInfo] { apps }
    /// How often the full window list was read, so a test can prove a caller deferred the read.
    public private(set) var listWindowsCount = 0
    public func listWindows() -> [WindowInfo] {
        listWindowsCount += 1
        noteSweepRead("listWindows")
        return windowList
    }
    /// The owner sets each scoped listing asked for, in call order.
    public private(set) var scopedListRequests: [Set<pid_t>] = []
    public func listWindows(ownerPIDs: Set<pid_t>) -> [WindowInfo] {
        scopedListRequests.append(ownerPIDs)
        return windowList.filter { ownerPIDs.contains($0.ownerPID) }
    }
    public func windowOwnerPID(windowID: CGWindowID) -> pid_t? {
        windowList.first { $0.windowID == windowID }?.ownerPID
    }
    public func listUntrackableWindowIDs() -> Set<CGWindowID> {
        noteSweepRead("listUntrackableWindowIDs")
        return untrackableWindowIDList
    }

    /// How many shared passes were opened, and which AX-sweeping reads ran outside one.
    public private(set) var sharedSweepCount = 0
    public private(set) var sweepReadsOutsideSharedPass: [String] = []
    private var sharedSweepDepth = 0
    private func noteSweepRead(_ name: String) {
        if sharedSweepDepth == 0 { sweepReadsOutsideSharedPass.append(name) }
    }
    public func withSharedAccessibilitySweep<T>(_ body: () -> T) -> T {
        sharedSweepCount += 1
        sharedSweepDepth += 1
        defer { sharedSweepDepth -= 1 }
        return body()
    }
    public func listDisqualifiedWindows() -> [CGWindowID: WindowDisqualification] {
        var result = Dictionary(uniqueKeysWithValues: undersizedWindowIDList.map { ($0, WindowDisqualification.smallWidth) })
        for windowID in disqualifiedWindowIDList { result[windowID] = .nonApplicationLayer }
        return result
    }
    public func listAXContradictedWindowIDs() -> Set<CGWindowID> {
        noteSweepRead("listAXContradictedWindowIDs")
        return axContradictedWindowIDList
    }
    public func listWindowServerVerdicts() -> WindowServerVerdicts {
        noteSweepRead("listWindowServerVerdicts")
        return WindowServerVerdicts(parented: parentedWindowIDList, orderedOut: orderedOutWindowIDList)
    }
    public func listAllWindowIDs() -> Set<CGWindowID>? { allWindowIDList }

    public func captureWindowImages(
        windowIDs: [CGWindowID],
        onEnumerated: @escaping @Sendable ([CGWindowID]) -> Void,
        onCapture: @escaping @Sendable (WindowImageCapture) -> Void
    ) async {
        captureLock.withLock { recordedCaptureRequests.append(windowIDs) }
        onEnumerated(windowIDs.filter { capturedImages[$0] != nil })
        for windowID in windowIDs {
            guard let image = capturedImages[windowID] else { continue }
            onCapture(WindowImageCapture(windowID: windowID, image: image))
        }
    }

    /// Raises made ahead of a desktop's reveal, kept apart from `raisedWindowIDs`, which records
    /// focus actually applied.
    public var trackedRaisedWindowIDs: [CGWindowID] = []

    public func raiseTrackedWindow(windowID: CGWindowID) -> Bool {
        trackedRaisedWindowIDs.append(windowID)
        return true
    }

    public func raiseWindow(windowID: CGWindowID) -> Bool {
        raisedWindowID = windowID
        raisedWindowIDs.append(windowID)
        return true
    }

    public func raiseWindowDeferred(
        windowID: CGWindowID,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        let raise = { completion(self.raiseWindow(windowID: windowID)) }
        if holdsDeferredRaises { heldRaises.append(raise) } else { raise() }
    }

    public func runHeldRaises() {
        let raises = heldRaises
        heldRaises = []
        raises.forEach { $0() }
    }

    public func closeWindow(windowID: CGWindowID) -> Bool {
        closedWindowIDs.append(windowID)
        return closeWindowResult
    }

    public func frontWindow(windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        frontedWindows.append(FrontWindowRequest(windowID: windowID, ownerPID: ownerPID))
        return frontWindowResult
    }

    public func frontWindowWithTrace(
        windowID: CGWindowID,
        ownerPID: pid_t
    ) -> FrontWindowDeliveryTrace {
        frontedWindows.append(FrontWindowRequest(windowID: windowID, ownerPID: ownerPID))
        return frontWindowDeliveryTrace ?? FrontWindowDeliveryTrace(
            accepted: frontWindowResult,
            processSerialNumberStatus: nil,
            frontRequestStatus: nil,
            keyWindowEventStatus: nil,
            frontProcessSymbolResolved: true,
            processSerialNumberSymbolResolved: true,
            keyWindowEventSymbolResolved: true
        )
    }

    public func frontmostWindowID(ownerPID: pid_t) -> CGWindowID? {
        focusObservation?.frontmostLayerZeroWindowID ?? visibleFrontWindowID
    }

    public func focusObservation(ownerPID: pid_t) -> WindowFocusObservation {
        focusObservationCount += 1
        return focusObservation ?? WindowFocusObservation(
            frontmostApplicationPID: frontmostPID,
            axFocusedWindowID: nil,
            visibleWindows: visibleFrontWindowID.map {
                [WindowZOrderEntry(
                    orderIndex: 0,
                    windowID: $0,
                    layer: 0,
                    alpha: 1,
                    bounds: .zero,
                    title: ""
                )]
            } ?? []
        )
    }

    public func frontmostApplicationPID() -> pid_t? { frontmostPID }

    public func activateApp(bundleID: String) -> Bool {
        activatedBundleID = bundleID
        return activateAppResult
    }

    public func activateApp(pid: pid_t) -> Bool {
        activatedPID = pid
        return activateAppResult
    }

    public func terminateApp(pid: pid_t) -> Bool {
        terminatedPIDs.append(pid)
        return terminateAppResult
    }

    public func isAccessibilityEnabled() -> Bool { accessibilityEnabled }
}
