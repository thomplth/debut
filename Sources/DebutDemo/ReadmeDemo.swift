import AppKit
import DebutCore
import ImageIO
import UniformTypeIdentifiers

@_silgen_name("_AXUIElementGetWindow")
private func demoWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private func axValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return value
}

func dismissDemoOnboarding() {
    let dismiss = Set(["Continue", "Get Started", "Start Using Weather", "Not Now", "No Thanks", "Don't Allow", "Done", "Turn Off Personalized Ads"])
    func walk(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 16 else { return false }
        let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { axValue(element, $0) as? String }.first(where: { !$0.isEmpty }) ?? ""
        if (axValue(element, kAXRoleAttribute) as? String) == kAXButtonRole, dismiss.contains(title) {
            log("dismiss onboarding: \(title)")
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        for child in axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if walk(child, depth: depth + 1) { return true }
        }
        return false
    }
    for bundle in ["com.apple.weather", "com.apple.stocks", "com.apple.Chess", "com.apple.Safari"] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
        app.activate(options: [])
        wait(1)
        for _ in 0..<10 {
            let dismissed = walk(AXUIElementCreateApplication(app.processIdentifier), depth: 0)
            wait(dismissed ? 2 : 0.4)
        }
    }
}

struct ReadmeScene {
    let windows: [WindowInfo]
    let groups: [[WindowInfo]]
    let service = SpaceService()
    let accessibility = AccessibilityWindowService()

    init() {
        let discovery = AccessibilityWindowService()
        // A partial recapture starts with windows already spread across spaces.
        discovery.spaceSwitcher = SpaceService()
        let allWindows = discovery.listWindows()
        windows = allWindows
        func window(_ bundle: String, _ title: String = "") -> WindowInfo {
            guard let result = allWindows.first(where: {
                $0.ownerBundleID == bundle && (title.isEmpty || $0.title.contains(title))
            }) else {
                log("FAILED: missing fixture \(bundle) / \(title); found \(allWindows.map { $0.ownerBundleID + "/" + $0.title })")
                exit(1)
            }
            return result
        }
        groups = [
            [window("com.apple.Terminal", "Research"), window("com.apple.Safari", "Field Notes"), window("com.apple.Chess")],
            [window("com.apple.Safari", "Weekend Guide"), window("com.apple.weather"), window("com.apple.stocks")],
            [window("com.apple.Terminal", "Project"), window("com.apple.TextEdit", "Project notes"), window("com.apple.TextEdit", "Reading list")],
        ]
    }

    func focus(_ window: WindowInfo) {
        guard let target = service.desktopIndex(forWindow: window.windowID) else { exit(1) }
        if service.currentDesktopIndex() != target {
            let switcher = SpaceService()
            switcher.switchDuration = 0
            switcher.switchToDesktop(index: target)
            let deadline = Date().addingTimeInterval(4)
            while service.currentDesktopIndex() != target, Date() < deadline { wait(0.05) }
            guard service.currentDesktopIndex() == target else {
                log("FAILED: fixture did not switch to space \(target + 1)"); exit(1)
            }
            wait(0.25)
        }
        guard accessibility.frontWindow(windowID: window.windowID, ownerPID: window.ownerPID) else {
            log("FAILED: could not front \(window.title)"); exit(1)
        }
        wait(0.9)
    }

    func verifyFocus(_ window: WindowInfo, space: Int) {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let observed = accessibility.focusObservation(ownerPID: window.ownerPID)
            if service.currentDesktopIndex() == space,
               service.desktopIndex(forWindow: window.windowID) == space,
               observed.frontmostApplicationPID == window.ownerPID,
               observed.frontmostLayerZeroWindowID == window.windowID { break }
            wait(0.05)
        }
        let observation = accessibility.focusObservation(ownerPID: window.ownerPID)
        guard service.currentDesktopIndex() == space,
              service.desktopIndex(forWindow: window.windowID) == space,
              observation.frontmostApplicationPID == window.ownerPID,
              observation.frontmostLayerZeroWindowID == window.windowID else {
            log("FAILED focus: \(window.title), space \(space + 1), observation \(observation)")
            exit(1)
        }
        log("verified space \(space + 1), focused \(window.ownerName)/\(window.title)")
    }

    func restore() {
        _ = run("/usr/bin/pkill", ["-x", "KeyCastr"])
        for (space, group) in groups.enumerated() {
            for (position, window) in group.enumerated() {
                service.moveWindow(windowID: window.windowID, toDesktop: space) { _ in }
                wait(0.15)
                guard service.desktopIndex(forWindow: window.windowID) == space else {
                    log("FAILED: fixture did not reach space \(space + 1)"); exit(1)
                }
                focus(window)
                if position == 0 { prepareReadmeBackdrop() }
                // Every app remains large enough to recognize in its preview.
                let app = AXUIElementCreateApplication(window.ownerPID)
                for element in axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                    var id: CGWindowID = 0
                    guard demoWindowID(element, &id) == .success, id == window.windowID else { continue }
                    var point = CGPoint(x: 100 + position * 95, y: 90 + position * 45)
                    var size = CGSize(width: 950, height: 620)
                    if window.ownerBundleID == "com.apple.Chess" { size = CGSize(width: 640, height: 620) }
                    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
                    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
                }
            }
            for window in group.reversed() { focus(window) }
        }
        focus(groups[1][0])
        verifyFocus(groups[1][0], space: 1)
        wait(1)
        guard spaceWindowCounts() == [3, 3, 3] else {
            describeState("unexpected fixture"); exit(1)
        }
    }

    func startKeys(fontSize: Int = 32) {
        _ = run("/usr/bin/defaults", ["write", "io.github.keycastr", "default.fontSize", "-int", String(fontSize)])
        _ = run("/usr/bin/open", ["-g", "-a", "KeyCastr"])
        wait(1)
        focus(groups[1][0])
        wait(2)
    }
}

/// KeyCastr owns the keystrokes; a short caption makes modifier release explicit.
@MainActor
final class ReleaseCaption {
    let panel: NSPanel
    init(_ text: String) {
        let screen = NSScreen.main!.frame
        panel = NSPanel(contentRect: NSRect(x: screen.maxX - 430, y: 38, width: 390, height: 54),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 9, width: 374, height: 36)
        panel.contentView?.addSubview(label)
        panel.orderFrontRegardless()
    }
}

func releaseWithCaption(_ modifier: String) {
    let caption = MainActor.assumeIsolated { ReleaseCaption("Release \(modifier)") }
    wait(0.4)
    postFlags([])
    wait(1.1)
    MainActor.assumeIsolated { caption.panel.orderOut(nil) }
}

func setDemoInstant(_ enabled: Bool) {
    _ = run("/usr/bin/pkill", ["-x", "Debut"])
    wait(0.6)
    let url = DebutCore.applicationSupportDirectory.appendingPathComponent("settings.json")
    var settings = (try? JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))) ?? AppSettings()
    settings.features.fasterDesktopSwitching = enabled
    settings.spaceSwitchDuration = 0
    try! JSONEncoder().encode(settings).write(to: url, options: .atomic)
    _ = run("/usr/bin/open", ["/Applications/Debut.app"])
    wait(3)
}

func recordReadme() {
    guard AXIsProcessTrusted() else { log("FAILED: demo driver needs Accessibility"); exit(1) }
    log("requested README clips: \(requestedClips.sorted().joined(separator: ", "))")
    dismissDemoOnboarding()
    setDemoInstant(false)
    let scene = ReadmeScene()
    scene.restore()
    // Refresh captured window dimensions after resizing the fixture apps.
    setDemoInstant(false)
    scene.focus(scene.groups[1][0])
    clearNotifications()
    if requestedClips.isEmpty || requestedClips.contains("cover") {
        holding(.maskCommand) {
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1.0)
            postTap(Key.digits[1], flags: .maskCommand)
            wait(1.0)
            let backdrop = MainActor.assumeIsolated { () -> NSPanel in
                let panel = NSPanel(contentRect: NSScreen.main!.frame,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.backgroundColor = .white
                panel.isOpaque = true
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.orderFrontRegardless()
                panel.displayIfNeeded()
                return panel
            }
            wait(0.8)
            do { try captureOverlayCover(to: outputDirectory.appendingPathComponent("overlay.png")) }
            catch { log("FAILED cover: \(error)"); exit(1) }
            MainActor.assumeIsolated { backdrop.orderOut(nil) }
            postTap(Key.escape, flags: .maskCommand)
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("command-tab") {
        scene.restore()
        scene.startKeys()
        clip("command-tab", seconds: 7) {
            postFlags(.maskCommand)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1)
            postTap(Key.digits[2], flags: .maskCommand, duration: 0.2)
            wait(1.1)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1.1)
            releaseWithCaption("⌘")
            scene.verifyFocus(scene.groups[2][1], space: 2)
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("organize-windows") {
        scene.restore()
        scene.startKeys()
        scene.focus(scene.groups[1][1])
        scene.focus(scene.groups[1][0])
        clip("organize-windows", seconds: 6) {
            postFlags(.maskCommand)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1.2)
            postTap(Key.upArrow, flags: .maskCommand, duration: 0.2)
            wait(1.4)
            releaseWithCaption("⌘")
            scene.verifyFocus(scene.groups[1][1], space: 0)
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("option-tab") {
        scene.restore()
        scene.startKeys()
        scene.focus(scene.groups[0][1])
        scene.focus(scene.groups[1][0])
        clip("option-tab", seconds: 5) {
            postFlags(.maskAlternate)
            postTap(Key.tab, flags: .maskAlternate, duration: 0.2)
            wait(1.5)
            releaseWithCaption("⌥")
            scene.verifyFocus(scene.groups[0][1], space: 0)
        }
    }
    if requestedClips.contains("faster-space-switching") || requestedClips.isEmpty {
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")!
        var hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        hotkeys["81"] = ["enabled": true, "value": ["type": "standard", "parameters": [65535, 124, 262144]]]
        defaults.set(hotkeys, forKey: "AppleSymbolicHotKeys")
        defaults.synchronize()
        _ = run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
        _ = run("/usr/bin/killall", ["Dock"])
        wait(3)
        for instant in [false, true] {
            setDemoInstant(instant)
            scene.restore()
            // Each side is scaled to half width, so keep the final key text the same size.
            scene.startKeys(fontSize: 64)
            let name = instant ? "speed-instant" : "speed-native"
            do {
                let url = outputDirectory.appendingPathComponent(name + ".mov")
                try? FileManager.default.removeItem(at: url)
                let recorder = try startDemoMovie(at: url)
                wait(0.5)
                postFlags(.maskControl)
                postTap(124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad], duration: 0.15)
                postFlags([])
                wait(2.5)
                guard SpaceService().currentDesktopIndex() == 2 else { log("FAILED: \(name) did not switch"); exit(1) }
                try awaitCapture { try await recorder.stop() }
                log("verified \(name), space 3")
            } catch { log("FAILED \(name): \(error)"); exit(1) }
        }
    }
    _ = run("/usr/bin/pkill", ["-x", "KeyCastr"])
    describeState("final")
}

/// A quiet, identical backdrop makes the windows and keys clear and GIF deltas compact.
func prepareReadmeBackdrop() {
    let url = URL(fileURLWithPath: "/tmp/debut-demo-desk/Backdrop.png")
    if !FileManager.default.fileExists(atPath: url.path) {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.78, green: 0.82, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
    }
    for screen in NSScreen.screens {
        try! NSWorkspace.shared.setDesktopImageURL(url, for: screen,
            options: [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue])
    }
    wait(0.2)
}
