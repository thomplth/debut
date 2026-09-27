import AppKit
import SwiftUI
import Testing
@testable import DebutCore

@Suite("Host environment", .serialized)
@MainActor
struct HostEnvironmentTests {
    @Test("Tests see a fixed profile whatever the host's Reduce Motion says")
    func testsSeeFixedProfile() {
        #expect(!HostEnvironment.isDebutApp)
        #expect(!HostEnvironment.current.reducesMotion(host: true))
        #expect(!HostEnvironment.current.reducesMotion)
    }

    @Test("The shipped app follows the host's Reduce Motion")
    func liveProfileFollowsHost() {
        #expect(HostEnvironment.live.reducesMotion(host: true))
        #expect(!HostEnvironment.live.reducesMotion(host: false))
    }

    @Test("SwiftUI views resolve Reduce Motion through the host profile")
    func viewsResolveThroughProfile() {
        var observed: Bool?
        let view = ReduceMotionProbe { observed = $0 }
        let hostingView = NSHostingView(rootView: view.frame(width: 10, height: 10))
        hostingView.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        hostingView.layoutSubtreeIfNeeded()

        // Locally the host is off too, so this only discriminates on a host with Reduce Motion on;
        // Tests/CI/HostEnvironmentTests.sh is what keeps views from reading the host directly.
        #expect(observed == false)
    }

    @Test("A new overlay window takes its motion branch from the host profile")
    func overlayDefaultsToProfile() {
        #expect(OverlayWindow().reducesMotion() == HostEnvironment.current.reducesMotion)
    }
}

private struct ReduceMotionProbe: View {
    @HostReducesMotion private var reduceMotion
    let report: (Bool) -> Void

    var body: some View {
        report(reduceMotion)
        return Color.clear
    }
}
