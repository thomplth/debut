import AppKit
import SwiftUI
import Testing
@testable import DebutCore

@MainActor
@Suite("Settings window")
struct SettingsWindowTests {
    @Test("Settings content extends beneath hidden transparent titlebar chrome")
    func settingsUsesIntegratedSidebarChrome() {
        let window = SettingsWindow(
            rootView: AnyView(Color.clear)
        )

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
    }

    @Test("Bug reports open the public GitHub issue form")
    func bugReportOpensGitHubIssueForm() throws {
        let components = try #require(
            URLComponents(url: AboutLinks.bugReport, resolvingAgainstBaseURL: false)
        )

        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(components.path == "/thomplth/Debut/issues/new")
        #expect(components.queryItems?.contains(
            URLQueryItem(name: "template", value: "bug_report.yml")
        ) == true)
    }
}
