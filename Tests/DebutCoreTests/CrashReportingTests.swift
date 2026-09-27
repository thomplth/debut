import Testing
import Foundation
@testable import DebutCore

@Suite("Crash reporting consent")
struct CrashReportingTests {

    @Test("Automatic crash reports are off on a fresh install and in older settings")
    func automaticSendingDefaultsOff() throws {
        #expect(!AppSettings().sendsCrashReportsAutomatically)

        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sendsCrashReportsAutomatically")
        // The removed usage-sharing opt-in must not carry over into crash reporting.
        object["shareAnonymousTelemetry"] = true
        let legacy = try JSONSerialization.data(withJSONObject: object)

        #expect(!(try JSONDecoder().decode(AppSettings.self, from: legacy)).sendsCrashReportsAutomatically)
    }

    @Test("A saved automatic-sending choice survives a round trip")
    func automaticSendingRoundTrips() throws {
        var settings = AppSettings()
        settings.sendsCrashReportsAutomatically = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.sendsCrashReportsAutomatically)
    }

    @Test("General owns the crash report preference")
    func generalOwnsCrashReports() {
        #expect(SettingsSection.general.options.contains(.crashReports))
    }

    @Test("Without consent a crash is held and nothing else is admitted")
    func gateHoldsCrashesUntilDecided() {
        let gate = CrashReportConsentGate<String>(sendsAutomatically: false)

        #expect(gate.admit("crash", isCrash: true) == nil)
        #expect(gate.admit("hang", isCrash: false) == nil)
        #expect(gate.send() == ["crash"])
        #expect(gate.admit("late crash", isCrash: true) == "late crash")
        #expect(gate.admit("hang", isCrash: false) == nil)
    }

    @Test("Discarding drops the held crash and any that arrive afterwards")
    func gateDiscards() {
        let gate = CrashReportConsentGate<String>(sendsAutomatically: false)
        #expect(gate.admit("crash", isCrash: true) == nil)

        gate.discard()

        #expect(gate.admit("late crash", isCrash: true) == nil)
        #expect(gate.send().isEmpty)
    }

    @Test("Automatic sending admits crashes and hangs, and turning it off stops both")
    func gateAutomatic() {
        let gate = CrashReportConsentGate<String>(sendsAutomatically: true)
        #expect(gate.admit("crash", isCrash: true) == "crash")
        #expect(gate.admit("hang", isCrash: false) == "hang")

        gate.setSendsAutomatically(false)

        #expect(gate.admit("hang", isCrash: false) == nil)
    }

    @Test("Home folder names are removed from report paths")
    func redactsHomeDirectories() {
        #expect(
            CrashReportRedaction.redactingHomeDirectories(
                "/Users/jane.doe/Applications/Debut.app/Contents/MacOS/Debut"
            ) == "/Users/<redacted>/Applications/Debut.app/Contents/MacOS/Debut"
        )
        #expect(
            CrashReportRedaction.redactingHomeDirectories("/Applications/Debut.app")
                == "/Applications/Debut.app"
        )
        #expect(CrashReportRedaction.redactingHomeDirectories("/Users/Shared/x") == "/Users/Shared/x")
    }
}

@MainActor
@Suite("Crash report prompt")
struct CrashReportCoordinatorTests {

    @MainActor
    final class FakeReporter: CrashReporting {
        var isAvailable = true
        var hasUnsentCrashReport = false
        var events: [String] = []

        func start(sendsAutomatically: Bool) { events.append("start(\(sendsAutomatically))") }
        func setSendsAutomatically(_ enabled: Bool) { events.append("automatic(\(enabled))") }
        func sendUnsentCrashReport() { events.append("send") }
        func discardUnsentCrashReport() { events.append("discard") }
    }

    private func coordinator(
        _ reporter: FakeReporter,
        answer: CrashReportDecision,
        asked: @escaping @MainActor () -> Void = {},
        enabledAutomatic: @escaping @MainActor () -> Void = {}
    ) -> CrashReportCoordinator {
        CrashReportCoordinator(
            reporter: reporter,
            askToSend: { asked(); return answer },
            enableAutomaticSending: enabledAutomatic
        )
    }

    @Test("A clean previous run starts reporting without asking")
    func noCrashNoPrompt() {
        let reporter = FakeReporter()
        var asked = false
        coordinator(reporter, answer: .send, asked: { asked = true })
            .startAndResolve()

        #expect(!asked)
        #expect(reporter.events == ["start(false)"])
    }

    @Test("After a crash, Send sends only that report")
    func sendOnce() {
        let reporter = FakeReporter()
        reporter.hasUnsentCrashReport = true
        var enabled = false
        coordinator(reporter, answer: .send, enabledAutomatic: { enabled = true })
            .startAndResolve()

        #expect(reporter.events == ["start(false)", "send"])
        #expect(!enabled)
    }

    @Test("After a crash, Always Send sends it and saves the preference")
    func alwaysSend() {
        let reporter = FakeReporter()
        reporter.hasUnsentCrashReport = true
        var enabled = false
        coordinator(reporter, answer: .alwaysSend, enabledAutomatic: { enabled = true })
            .startAndResolve()

        #expect(reporter.events == ["start(false)", "automatic(true)", "send"])
        #expect(enabled)
    }

    @Test("After a crash, Don't Send discards it")
    func dontSend() {
        let reporter = FakeReporter()
        reporter.hasUnsentCrashReport = true
        coordinator(reporter, answer: .dontSend).startAndResolve()

        #expect(reporter.events == ["start(false)", "discard"])
    }

    @Test("Builds without a reporting destination never ask")
    func unavailableNeverAsks() {
        let reporter = FakeReporter()
        reporter.isAvailable = false
        reporter.hasUnsentCrashReport = true
        var asked = false
        coordinator(reporter, answer: .send, asked: { asked = true })
            .startAndResolve()

        #expect(!asked)
        #expect(reporter.events.isEmpty)
    }

    @Test("Changing the preference reaches the reporter only when it changes")
    func settingsChanges() {
        let reporter = FakeReporter()
        let coordinator = coordinator(reporter, answer: .send)
        coordinator.startAndResolve()

        coordinator.settingsChanged(sendsAutomatically: false)
        coordinator.settingsChanged(sendsAutomatically: true)

        #expect(reporter.events == ["start(false)", "automatic(true)"])
    }
}

private extension CrashReportCoordinator {
    func startAndResolve() {
        start(sendsAutomatically: false)
        resolveUnsentCrashReport()
    }
}
