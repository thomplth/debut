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
}
