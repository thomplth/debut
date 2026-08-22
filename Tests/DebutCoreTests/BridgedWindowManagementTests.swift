import Testing
import AppKit
import CoreGraphics
@testable import DebutCore

/// The bridged move transport fails by doing nothing, never by returning an error, so these
/// tests assert the two preconditions that go silently wrong rather than only the happy path.
@Suite(.serialized)
struct BridgedWindowManagementTests {

    @Test("The bridged operation class and its client entry point both resolve")
    func entryPointsResolve() {
        let readiness = BridgedWindowManagement.readiness
        #expect(readiness.operationClassAvailable)
        // Internal linkage: dlsym cannot see this, so a failure here means the LC_SYMTAB scan
        // broke, not that the function was removed.
        #expect(readiness.performSymbolResolved)
    }

    @Test("The window-management bridge is live, not the inert fallback")
    func bridgeIsLive() {
        // SkyLight's default delegate forwards to a nil inner bridge, which swallows every
        // operation in two instructions. Loading the WindowManager frameworks is what makes
        // it real, and nothing else in Debut would notice if that stopped happening.
        #expect(BridgedWindowManagement.readiness.bridgeDelegateLive)
        #expect(BridgedWindowManagement.readiness.isReady)
    }

    /// A hosted CI runner logs in with a single Space, so the only test here that needs a
    /// second desktop has to skip rather than fail — it is asserting the window server's
    /// behaviour, and there is no window server answer to assert against.
    static var hasSecondDesktop: Bool {
        SpaceService().userDesktops().count >= 2
    }

    @Test("A window is reassigned to another desktop and reads back there",
          .enabled(if: hasSecondDesktop, "needs at least two user desktops"))
    @MainActor func movesAWindow() throws {
        let service = SpaceService()
        let desktops = service.userDesktops()

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // Closing an NSWindow releases it by default, which over-releases the reference this
        // test still holds and segfaults the *next* test rather than this one.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let windowID = CGWindowID(window.windowNumber)
        let origin = try #require(service.spaces(forWindow: windowID).first)
        let target = try #require(desktops.first { $0 != origin })

        #expect(BridgedWindowManagement.moveWindows([windowID], toSpace: target))
        #expect(service.waitForWindow(windowID, toReachSpace: target))
        #expect(service.spaces(forWindow: windowID) == [target])
    }

    @Test("Moving to a desktop the window is already on is not reported as failure")
    @MainActor func moveToSameDesktopSucceeds() throws {
        let service = SpaceService()
        try #require(!service.userDesktops().isEmpty)

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // Closing an NSWindow releases it by default, which over-releases the reference this
        // test still holds and segfaults the *next* test rather than this one.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let windowID = CGWindowID(window.windowNumber)
        let origin = try #require(service.spaces(forWindow: windowID).first)
        #expect(BridgedWindowManagement.moveWindows([windowID], toSpace: origin))
        #expect(service.spaces(forWindow: windowID) == [origin])
    }

    @Test("An empty window list is refused rather than sent")
    func emptyListIsRefused() {
        #expect(!BridgedWindowManagement.moveWindows([], toSpace: 1))
    }
}
