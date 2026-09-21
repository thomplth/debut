import Foundation
import Testing
@testable import DebutCore

@Suite("Responsiveness policy")
struct ResponsivenessPolicyTests {
    @Test("The process activity prevents App Nap without preventing idle system sleep")
    func processActivityPolicy() {
        var starts: [(ProcessInfo.ActivityOptions, String)] = []
        let activity = ProcessResponsivenessActivity { options, reason in
            starts.append((options, reason))
            return NSObject()
        }

        activity.start()
        activity.start()

        #expect(starts.count == 1)
        #expect(starts[0].0.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(starts[0].1.contains("responsiveness"))
    }

    @Test("Latency-sensitive external calls have bounded differentiated lanes")
    func externalCallLanePolicies() {
        let scheduler = ExternalCallScheduler()

        #expect(scheduler.configuration(for: .accessibility).qualityOfService == .userInteractive)
        #expect(scheduler.configuration(for: .accessibility).maximumConcurrency == 4)
        #expect(scheduler.configuration(for: .windowServer).qualityOfService == .userInitiated)
        #expect(scheduler.configuration(for: .windowServer).maximumConcurrency == 4)
        #expect(scheduler.configuration(for: .process).qualityOfService == .userInitiated)
        #expect(scheduler.configuration(for: .process).maximumConcurrency == 2)
    }

    @Test("The event tap and its main-queue delivery use interactive QoS")
    func interactiveInputPolicy() {
        #expect(EventTapKeyboardService.eventTapQualityOfService == .userInteractive)
        #expect(EventTapKeyboardService.deliveryQualityOfService == .userInteractive)
    }
}
