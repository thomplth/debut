import AppKit
import Foundation

/// An app whose focused-window AX read is slow, the way Dia's long-lived windows were: Dia missed
/// Debut's 50ms read for one of them 126 times in 147, so every switch to it was dropped while
/// the WindowServer saw each one (KHA-1166). Only that read stalls; the app's windows, their
/// order and every other AX answer stay prompt.
///
/// It runs as a copy of this harness wrapped in a bundle, because Debut only manages windows of
/// regular apps with a bundle identity.
enum StalledFocusFixture {
    static let subcommand = "stalled-focus-fixture"
    static let bundleIdentifier = "com.thomplth.debut.e2e.stalled-focus"
    static let focusRequest = Notification.Name("com.thomplth.debut.e2e.stalled-focus.focus")
    static let titles = ["Stalled focus A", "Stalled focus B"]
    static let focusReadStall: TimeInterval = 0.3

    static func run() -> Never {
        let application = StalledFocusApplication.shared
        application.setActivationPolicy(.regular)
        let windows = titles.enumerated().map { index, title in
            let window = NSWindow(
                contentRect: NSRect(x: 160 + index * 80, y: 160 + index * 60, width: 640, height: 420),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            return window
        }
        DistributedNotificationCenter.default().addObserver(
            forName: focusRequest,
            object: nil,
            queue: .main
        ) { notification in
            guard let title = notification.object as? String,
                  let window = windows.first(where: { $0.title == title })
            else { return }
            MainActor.assumeIsolated { window.makeKeyAndOrderFront(nil) }
        }
        application.run()
        exit(0)
    }

    static func requestFocus(_ title: String) {
        DistributedNotificationCenter.default().postNotificationName(
            focusRequest,
            object: title,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Writes `StalledFocus.app` around a copy of this executable and returns it.
    static func makeBundle() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let bundle = URL(fileURLWithPath: "/tmp/debut-e2e-fixtures/StalledFocus.app")
        let contents = bundle.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: bundle)
        do {
            try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fileManager.copyItem(at: executable, to: macOS.appendingPathComponent("StalledFocus"))
            let plist: [String: Any] = [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": "StalledFocus",
                "CFBundleName": "Stalled Focus",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "NSHighResolutionCapable": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        } catch {
            return nil
        }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", bundle.path]
        try? sign.run()
        sign.waitUntilExit()
        return bundle
    }
}

final class StalledFocusApplication: NSApplication {
    override func accessibilityFocusedWindow() -> Any? {
        Thread.sleep(forTimeInterval: StalledFocusFixture.focusReadStall)
        return super.accessibilityFocusedWindow()
    }
}
