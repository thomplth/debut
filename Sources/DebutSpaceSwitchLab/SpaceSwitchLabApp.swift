import AppKit
import SwiftUI

@main
struct DebutSpaceSwitchLabApp: App {
    @NSApplicationDelegateAdaptor(LabAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Debut Space Switch Lab") {
            LabView()
                .frame(minWidth: 820, minHeight: 720)
        }
        .defaultSize(width: 920, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class LabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
