import CoreGraphics
import Testing
@testable import DebutCore

@Suite("WindowServerFocusRules")
struct WindowServerFocusRulesTests {
    private let dia: pid_t = 4433
    private let orca: pid_t = 31138
    private let develop: CGWindowID = 59667
    private let debutTab: CGWindowID = 86144
    private let orcaWindow: CGWindowID = 81160

    @Test("The first focus event of an outside activation is credited before the app reads as frontmost")
    func firstFocusOfActivationIsCredited() {
        var rules = WindowServerFocusRules()
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10)

        #expect(rules.windowFocused(windowID: develop, pid: dia, frontmostPID: orca, now: 10.07) == .credited)
        #expect(rules.activations[dia]?.answeredWindowID == develop)
    }

    @Test("The windows an activation raises after its focus are not credited")
    func activationRaisesAreIgnored() {
        var rules = WindowServerFocusRules()
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10)
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10.07)

        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.18) == .activationRaise)
    }

    @Test("A raise is muted once, so a later switch to that window is credited")
    func raiseIsMutedOnlyOnce() {
        var rules = WindowServerFocusRules()
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10)
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10.07)
        _ = rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.18)

        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.3) == .credited)
        #expect(rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10.4) == .credited)
    }

    @Test("A repeated focus event for the window just credited changes nothing")
    func repeatedFocusIsNotCreditedTwice() {
        var rules = WindowServerFocusRules()
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10)

        #expect(rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10.2) == .alreadyCredited)
    }

    @Test("A focus event after the activation window closes follows the frontmost app")
    func expiredActivationFollowsFrontmostApp() {
        var rules = WindowServerFocusRules()
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10)
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10.07)

        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 11) == .credited)
        #expect(rules.activations[dia] == nil)
    }

    @Test("A focus change inside the frontmost app with no activation in flight is credited")
    func inAppFocusChangeIsCredited() {
        var rules = WindowServerFocusRules()

        #expect(rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10) == .credited)
        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.6) == .credited)
    }

    @Test("A background app focusing its own window is not credited")
    func backgroundFocusIsNotCredited() {
        var rules = WindowServerFocusRules()

        #expect(rules.windowFocused(windowID: develop, pid: dia, frontmostPID: orca, now: 10) == .heldForActivation)
    }

    @Test("A focus event that beats its app's activation notification answers that activation")
    func heldFocusAnswersTheActivation() {
        var rules = WindowServerFocusRules()
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: orca, now: 10)

        #expect(rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10.05) == develop)
        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.15) == .activationRaise)
    }

    @Test("A focus event long before its app activates does not answer the activation")
    func staleHeldFocusIsDropped() {
        var rules = WindowServerFocusRules()
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: orca, now: 10)

        #expect(rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 11) == nil)
    }

    @Test("An activation superseded by another app's no longer credits its first focus")
    func supersededActivationDoesNotCredit() {
        var rules = WindowServerFocusRules()
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10)
        _ = rules.activationBegan(pid: orca, windowIDs: [orcaWindow], now: 10.1)

        #expect(rules.windowFocused(windowID: develop, pid: dia, frontmostPID: orca, now: 10.2) == .activationRaise)
    }

    @Test("A Debut-initiated activation mutes nothing, so an in-app switch right after it is credited")
    func debutInitiatedActivationMutesNothing() {
        var rules = WindowServerFocusRules()
        rules.focusRequested(windowID: develop, pid: dia, frontmostPID: orca, now: 10)
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10.01)

        #expect(rules.activations[dia]?.answeredWindowID == develop)
        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.2) == .credited)
    }

    @Test("A focus request for the app already in front leaves the next outside activation's raises muted")
    func requestForFrontmostAppIsNotRecorded() {
        var rules = WindowServerFocusRules()
        rules.focusRequested(windowID: develop, pid: dia, frontmostPID: dia, now: 10)
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10.2)
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10.25)

        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.35) == .activationRaise)
    }

    @Test("An expired focus request does not belong to a later activation")
    func expiredFocusRequestIsDropped() {
        var rules = WindowServerFocusRules()
        rules.focusRequested(windowID: develop, pid: dia, frontmostPID: orca, now: 10)
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 12)

        #expect(rules.activations[dia]?.answeredWindowID == nil)
    }

    @Test("An order-in of a window already on screen in the frontmost app is credited")
    func inAppRaiseIsCredited() {
        var rules = WindowServerFocusRules()
        rules.windowsSeenOnScreen([develop, debutTab])

        #expect(rules.windowOrderedIn(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10) == .credited)
    }

    @Test("An order-in of a window coming back on screen is not a raise")
    func returningWindowIsNotCredited() {
        var rules = WindowServerFocusRules()
        rules.windowsSeenOnScreen([develop])
        rules.windowOrderedOut(windowID: develop)

        #expect(rules.windowOrderedIn(windowID: develop, pid: dia, frontmostPID: dia, now: 10) == .returnedOnScreen)
        #expect(rules.windowOrderedIn(windowID: develop, pid: dia, frontmostPID: dia, now: 11) == .credited)
    }

    @Test("An order-in of a window never seen on screen is not a raise")
    func unknownWindowIsNotCredited() {
        var rules = WindowServerFocusRules()

        #expect(rules.windowOrderedIn(windowID: develop, pid: dia, frontmostPID: dia, now: 10) == .returnedOnScreen)
    }

    @Test("Order-ins during a desktop change are not raises")
    func spaceTransitionMutesOrderIns() {
        var rules = WindowServerFocusRules()
        rules.windowsSeenOnScreen([develop])
        rules.spaceTransitionBegan(now: 10)

        #expect(rules.windowOrderedIn(windowID: develop, pid: dia, frontmostPID: dia, now: 10.2) == .spaceTransition)
        #expect(rules.windowOrderedIn(windowID: develop, pid: dia, frontmostPID: dia, now: 10.6) == .credited)
    }

    @Test("Order-ins of an activation's windows are its raises")
    func activationOrderInsAreRaises() {
        var rules = WindowServerFocusRules()
        rules.windowsSeenOnScreen([develop, debutTab])
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10)
        _ = rules.windowFocused(windowID: develop, pid: dia, frontmostPID: dia, now: 10.07)
        _ = rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.18)

        #expect(rules.windowOrderedIn(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.19) == .activationRaise)
    }

    @Test("A background app ordering in its own window is not credited")
    func backgroundOrderInIsNotCredited() {
        var rules = WindowServerFocusRules()
        rules.windowsSeenOnScreen([develop])

        #expect(rules.windowOrderedIn(windowID: develop, pid: dia, frontmostPID: orca, now: 10) == .backgroundApp)
    }

    @Test("The order-in and focus event of one raise credit the window once")
    func oneRaiseCreditsOnce() {
        var rules = WindowServerFocusRules()
        rules.windowsSeenOnScreen([develop, debutTab])

        #expect(rules.windowOrderedIn(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10) == .credited)
        #expect(rules.windowFocused(windowID: debutTab, pid: dia, frontmostPID: dia, now: 10.08) == .alreadyCredited)
    }

    @Test("A forgotten window is no longer a raise candidate or known on screen")
    func forgottenWindowsLeaveTheRules() {
        var rules = WindowServerFocusRules()
        rules.windowsSeenOnScreen([develop, debutTab])
        _ = rules.activationBegan(pid: dia, windowIDs: [develop, debutTab], now: 10)
        rules.forget(windowIDs: [debutTab])

        #expect(rules.activations[dia]?.raiseCandidates == [develop])
        #expect(!rules.isOnScreen(debutTab))
    }
}
