import CoreGraphics
import Foundation

/// What one WindowServer focus or order-in event means for the MRU order.
public enum WindowServerFocusVerdict: String, Sendable {
    case credited
    /// The app raising the rest of its windows after the activation's focus already spoke.
    case activationRaise = "activation_raise"
    /// The window's app is not frontmost and no activation of it is in flight.
    case backgroundApp = "background_app"
    /// Kept for an activation of the window's app that has not been reported yet.
    case heldForActivation = "held_for_activation"
    /// The window came back on screen rather than being raised over its own app's windows.
    case returnedOnScreen = "returned_on_screen"
    case spaceTransition = "space_transition"
    /// The window was already credited, through the other event of the same raise.
    case alreadyCredited = "already_credited"
}

/// Decides which WindowServer window events are the user's focus, after AltTab's
/// `ActivationFocusResolver` (KHA-1166).
///
/// Measured on macOS 27 with Dia: an activation from outside Debut emits a focus event (808) for
/// the window macOS focused, then one for each other window the app raises, about 110ms apart;
/// the on-screen order kept the first one in front. Debut's own switch raises one window and
/// emits one event. An in-app switch emits an order-in (815) and an 808 for the new window.
///
/// Main-queue confined. Pure: it holds the state the decisions need and reads nothing.
struct WindowServerFocusRules {
    static let activationRaiseInterval: TimeInterval = 0.5
    /// How long before its activation notification an app's own focus event still belongs to it.
    /// Debut's raise goes straight to the window server, so its 808 can beat the notification.
    static let heldFocusInterval: TimeInterval = 0.25
    static let focusRequestFailsafe: TimeInterval = 1
    static let spaceTransitionInterval: TimeInterval = 0.5
    static let duplicateInterval: TimeInterval = 0.5

    struct Activation: Equatable {
        let pid: pid_t
        let until: TimeInterval
        var answeredWindowID: CGWindowID?
        /// The app's windows this activation may still raise. Each raise spends its window, so a
        /// later focus of the same window is a real choice.
        var raiseCandidates: Set<CGWindowID>
        /// `raiseCandidates` as built, for the order-ins that trail the focus events which spend it.
        let raiseTail: Set<CGWindowID>
        /// A newer activation of another app took over, so this one's first focus is no longer
        /// the user's.
        var isCurrent = true
    }

    private struct FocusRequest {
        let windowID: CGWindowID
        let pid: pid_t
        let at: TimeInterval
    }

    private(set) var activations: [pid_t: Activation] = [:]
    private var focusRequest: FocusRequest?
    private var heldFocus: [pid_t: (windowID: CGWindowID, at: TimeInterval)] = [:]
    private var onScreenWindowIDs: Set<CGWindowID> = []
    private var spaceTransitionUntil: TimeInterval = 0
    private var lastCredited: (windowID: CGWindowID, at: TimeInterval)?

    /// Debut is about to front `windowID`. Recorded only when an activation will follow: an app
    /// already frontmost sends none to consume it, and a leftover request would hand a later
    /// genuine activation of that app a stale target and no raises to mute.
    mutating func focusRequested(
        windowID: CGWindowID,
        pid: pid_t,
        frontmostPID: pid_t?,
        now: TimeInterval
    ) {
        guard frontmostPID != pid else { return }
        focusRequest = FocusRequest(windowID: windowID, pid: pid, at: now)
    }

    /// Opens the activation's window for raises, and returns the app's focus event that arrived
    /// just before this notification, which is the activation's answer.
    ///
    /// A Debut-initiated activation raises exactly one window, so it mutes nothing: the user's own
    /// in-app switch a moment later is a real focus (AltTab #5875).
    mutating func activationBegan(
        pid: pid_t,
        windowIDs: Set<CGWindowID>,
        now: TimeInterval
    ) -> CGWindowID? {
        prune(now: now)
        for otherPID in activations.keys where otherPID != pid {
            activations[otherPID]?.isCurrent = false
        }
        let held = heldFocus.removeValue(forKey: pid)
            .flatMap { now - $0.at <= Self.heldFocusInterval ? $0.windowID : nil }
        let request = focusRequest.flatMap {
            $0.pid == pid && now - $0.at < Self.focusRequestFailsafe ? $0 : nil
        }
        if request != nil { focusRequest = nil }
        if let request {
            activations[pid] = Activation(
                pid: pid,
                until: now + Self.activationRaiseInterval,
                answeredWindowID: request.windowID,
                raiseCandidates: [],
                raiseTail: []
            )
            return held
        }
        let candidates = windowIDs.subtracting(held.map { [$0] } ?? [])
        activations[pid] = Activation(
            pid: pid,
            until: now + Self.activationRaiseInterval,
            answeredWindowID: held,
            raiseCandidates: candidates,
            raiseTail: windowIDs
        )
        if let held { lastCredited = (held, now) }
        return held
    }

    mutating func windowFocused(
        windowID: CGWindowID,
        pid: pid_t,
        frontmostPID: pid_t?,
        now: TimeInterval
    ) -> WindowServerFocusVerdict {
        prune(now: now)
        if var activation = activations[pid] {
            defer { activations[pid] = activation }
            if activation.isCurrent, activation.answeredWindowID == nil {
                activation.answeredWindowID = windowID
                activation.raiseCandidates.remove(windowID)
                return credit(windowID, now: now)
            }
            if activation.raiseCandidates.remove(windowID) != nil { return .activationRaise }
        }
        guard frontmostPID == pid else {
            heldFocus[pid] = (windowID, now)
            return .heldForActivation
        }
        return credit(windowID, now: now)
    }

    /// An order-in is a raise only for a window that was already on screen: the OS also orders
    /// in every window of a desktop it shows again, and no Space notification reliably precedes
    /// that (AltTab #5849). Windows not yet known to be on screen are taken as returning.
    mutating func windowOrderedIn(
        windowID: CGWindowID,
        pid: pid_t,
        frontmostPID: pid_t?,
        now: TimeInterval
    ) -> WindowServerFocusVerdict {
        prune(now: now)
        let wasOnScreen = !onScreenWindowIDs.insert(windowID).inserted
        guard wasOnScreen else { return .returnedOnScreen }
        guard now >= spaceTransitionUntil else { return .spaceTransition }
        if let activation = activations[pid], activation.raiseTail.contains(windowID) {
            return .activationRaise
        }
        guard frontmostPID == pid else { return .backgroundApp }
        return credit(windowID, now: now)
    }

    mutating func windowOrderedOut(windowID: CGWindowID) {
        onScreenWindowIDs.remove(windowID)
    }

    mutating func windowsSeenOnScreen(_ windowIDs: Set<CGWindowID>) {
        onScreenWindowIDs.formUnion(windowIDs)
    }

    mutating func forget(windowIDs: Set<CGWindowID>) {
        onScreenWindowIDs.subtract(windowIDs)
        for pid in activations.keys {
            activations[pid]?.raiseCandidates.subtract(windowIDs)
        }
    }

    mutating func spaceTransitionBegan(now: TimeInterval) {
        spaceTransitionUntil = now + Self.spaceTransitionInterval
    }

    func isOnScreen(_ windowID: CGWindowID) -> Bool {
        onScreenWindowIDs.contains(windowID)
    }

    private mutating func credit(_ windowID: CGWindowID, now: TimeInterval) -> WindowServerFocusVerdict {
        if let lastCredited, lastCredited.windowID == windowID,
           now - lastCredited.at < Self.duplicateInterval {
            self.lastCredited = (windowID, now)
            return .alreadyCredited
        }
        lastCredited = (windowID, now)
        return .credited
    }

    private mutating func prune(now: TimeInterval) {
        activations = activations.filter { $0.value.until > now }
        heldFocus = heldFocus.filter { now - $0.value.at <= Self.heldFocusInterval }
    }
}
