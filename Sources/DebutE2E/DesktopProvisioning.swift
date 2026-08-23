import AppKit
import ApplicationServices
import DebutCore

/// Adds user desktops to a disposable host until it has `target` of them.
///
/// Stages are desktops, so a host with one desktop cannot exercise a stage switch, a cross-stage
/// window move, or the switch duration — the entire subject of this architecture. Hosted CI
/// runners and freshly cloned VMs all log in with exactly one, which is why those checks used to
/// be skips rather than results.
///
/// The desktop has to come from Mission Control's own button. Seeding the Dock's
/// `com.apple.spaces` plist looks like it works — the entry survives a reboot and the window
/// server does report a second Space — but every seeded desktop comes back carrying the *first*
/// desktop's `id64`, so `SpaceService.index(of:in:)` maps them all to stage 0. A duplicate
/// identity is worse than no second desktop, because the suite goes green against a broken map.
enum DesktopProvisioning {

    /// Mission Control's add-desktop button. This is an accessibility identifier rather than the
    /// button's description, which is localized.
    private static let addButtonIdentifier = "mc.spaces.add"

    static func ensureDesktops(_ target: Int) -> Bool {
        let service = SpaceService()
        var desktops = service.userDesktops()
        print("Desktops before provisioning: \(desktops)")

        guard AXIsProcessTrusted() else {
            print("Cannot provision desktops: this process is not trusted for Accessibility.")
            return false
        }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            print("Cannot provision desktops: the Dock is not running.")
            return false
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)

        while desktops.count < target {
            let before = desktops.count
            toggleMissionControl()
            guard let addButton = element(in: dockElement, identifier: addButtonIdentifier) else {
                print("Cannot provision desktops: Mission Control has no \(addButtonIdentifier).")
                toggleMissionControl()
                return false
            }
            AXUIElementPerformAction(addButton, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1)
            toggleMissionControl()

            desktops = service.userDesktops()
            guard desktops.count > before else {
                print("Cannot provision desktops: pressing add left \(desktops.count) desktops.")
                return false
            }
        }

        print("Desktops after provisioning: \(desktops)")
        guard Set(desktops).count == desktops.count else {
            print("Provisioned desktops do not have distinct identifiers.")
            return false
        }
        return true
    }

    private static func toggleMissionControl() {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        )
        process.arguments = ["0"]
        try? process.run()
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.5)
    }

    private static func element(
        in root: AXUIElement,
        identifier: String,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth <= 8 else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, "AXIdentifier" as CFString, &value) == .success,
           value as? String == identifier {
            return root
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root, kAXChildrenAttribute as CFString, &children
        ) == .success, let elements = children as? [AXUIElement] else { return nil }

        for child in elements {
            if let found = element(in: child, identifier: identifier, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}
