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

private func findDemoElement(_ root: AXUIElement, depth: Int = 0,
                             matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 16 else { return nil }
    if predicate(root) { return root }
    for child in axValue(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = findDemoElement(child, depth: depth + 1, matching: predicate) { return found }
    }
    return nil
}

/// Select a named city rather than the location inferred from the capture machine's network.
func prepareDemoWeather() {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.weather").first else {
        log("FAILED: Weather is not running"); exit(1)
    }
    app.activate(options: [])
    wait(1)
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let search = findDemoElement(root, matching: {
        (axValue($0, kAXRoleAttribute) as? String) == kAXTextFieldRole
    }) else { log("FAILED: Weather search is unavailable"); exit(1) }
    AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, "Cupertino" as CFString) == .success else {
        log("FAILED: Weather search could not be set"); exit(1)
    }
    let deadline = Date().addingTimeInterval(15)
    var result: AXUIElement?
    while result == nil, Date() < deadline {
        wait(0.25)
        result = findDemoElement(root, matching: {
            (axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole &&
            (axValue($0, kAXDescriptionAttribute) as? String)?.hasPrefix("Cupertino, CA") == true
        })
    }
    guard let result, AXUIElementPerformAction(result, kAXPressAction as CFString) == .success else {
        log("FAILED: Cupertino was not found in Weather"); exit(1)
    }
    wait(2)
    if let add = findDemoElement(root, matching: {
        (axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole &&
        (axValue($0, kAXDescriptionAttribute) as? String) == "Add"
    }) { AXUIElementPerformAction(add, kAXPressAction as CFString) }
    wait(1)
    // Selecting an already-saved city leaves search open; return to its normal sidebar.
    if let clear = findDemoElement(root, matching: {
        (axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole &&
        (axValue($0, kAXDescriptionAttribute) as? String) == "Clear text"
    }) { AXUIElementPerformAction(clear, kAXPressAction as CFString) }
    postTap(Key.escape)
    wait(0.5)
    // Dismiss both forecast and menu-bar tips, which can appear after first use.
    for _ in 0..<6 {
        guard let close = findDemoElement(root, matching: {
            (axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole &&
            (axValue($0, kAXIdentifierAttribute) as? String) == "xmark.circle.fill"
        }) else { break }
        AXUIElementPerformAction(close, kAXPressAction as CFString)
        wait(0.3)
    }
    // Stock VM images can include saved example cities. Keep this fixture's list singular.
    for _ in 0..<8 {
        guard let list = findDemoElement(root, matching: {
            (axValue($0, kAXDescriptionAttribute) as? String) == "Location List"
        }) else { wait(1); continue }
        guard let city = findDemoElement(list, matching: {
            guard (axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole,
                  let label = axValue($0, kAXDescriptionAttribute) as? String else { return false }
            return label.contains(",") && !label.hasPrefix("Cupertino,")
        }) else { break }
        guard AXUIElementPerformAction(city, kAXShowMenuAction as CFString) == .success else {
            log("FAILED: could not open the example city's menu"); exit(1)
        }
        wait(0.3)
        guard let delete = findDemoElement(root, matching: {
            (axValue($0, kAXRoleAttribute) as? String) == kAXMenuItemRole &&
            (axValue($0, kAXIdentifierAttribute) as? String) == "delete"
        }), AXUIElementPerformAction(delete, kAXPressAction as CFString) == .success else {
            log("FAILED: could not remove the extra example city"); exit(1)
        }
        wait(0.5)
        if let confirmation = findDemoElement(root, matching: {
            (axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole &&
            ((axValue($0, kAXTitleAttribute) as? String) == "Delete" ||
             (axValue($0, kAXDescriptionAttribute) as? String) == "Delete")
        }) {
            AXUIElementPerformAction(confirmation, kAXPressAction as CFString)
            // Weather rebuilds the sidebar after dismissing the confirmation sheet.
            wait(2)
        }
    }
    guard findDemoElement(root, matching: {
        (axValue($0, kAXRoleAttribute) as? String) == kAXSheetRole
    }) == nil, let list = findDemoElement(root, matching: {
        (axValue($0, kAXDescriptionAttribute) as? String) == "Location List"
    }), findDemoElement(list, matching: {
        guard (axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole,
              let label = axValue($0, kAXDescriptionAttribute) as? String else { return false }
        return label.contains(",") && !label.hasPrefix("Cupertino,")
    }) == nil else {
        func describe(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 12 else { return }
            let text = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { axValue(element, $0) as? String }.joined(separator: " | ")
            if !text.isEmpty { log("Weather AX: \(String(repeating: " ", count: depth))\(text)") }
            for child in axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { describe(child, depth: depth + 1) }
        }
        describe(root)
        try? captureDemoStill(to: outputDirectory.appendingPathComponent("weather-failure.png"))
        log("FAILED: Weather still has a dialog or extra cities"); exit(1)
    }
    guard let windows = axValue(root, kAXWindowsAttribute) as? [AXUIElement],
          windows.contains(where: { (axValue($0, kAXTitleAttribute) as? String) == "Cupertino" }) else {
        log("FAILED: Weather is not showing Cupertino"); exit(1)
    }
    log("verified Weather: Cupertino")
}

func setDemoAppearance(dark: Bool) {
    let value = dark ? "true" : "false"
    let script = """
    with timeout of 15 seconds
        tell application "System Events" to tell appearance preferences
            set dark mode to \(value)
            if dark mode is not \(value) then error "Appearance did not change"
        end tell
    end timeout
    """
    guard run("/usr/bin/osascript", ["-e", script]) == 0 else {
        log("FAILED: could not set the capture appearance"); exit(1)
    }
    wait(2)
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

    func startKeys(fontSize: Int = 64) {
        _ = run("/usr/bin/defaults", ["write", "io.github.keycastr", "default.fontSize", "-int", String(fontSize)])
        _ = run("/usr/bin/open", ["-g", "-a", "KeyCastr"])
        wait(1)
        focus(groups[1][0])
        wait(2)
    }
}

func releaseDemoModifier() {
    wait(0.4)
    postFlags([])
    wait(1.1)
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
    setDemoAppearance(dark: false)
    dismissDemoOnboarding()
    prepareDemoWeather()
    setDemoInstant(false)
    let scene = ReadmeScene()
    scene.restore()
    // Refresh captured window dimensions after resizing the fixture apps.
    setDemoInstant(false)
    scene.focus(scene.groups[1][0])
    clearNotifications()
    if requestedClips.contains("onboarding") {
        for previews in [true, false] {
            _ = run("/usr/bin/pkill", ["-x", "Debut"])
            wait(0.6)
            let settingsURL = DebutCore.applicationSupportDirectory.appendingPathComponent("settings.json")
            var settings = try! JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
            settings.features.windowPreviews = previews
            try! JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
            setDemoInstant(false)
            scene.restore()
            scene.focus(scene.groups[1][0])
            for command in [true, false] {
                let modifier: CGEventFlags = command ? .maskCommand : .maskAlternate
                let name = command ? (previews ? "onboarding-workspace" : "onboarding-workspace-no-previews")
                    : (previews ? "onboarding-previews" : "onboarding-no-previews")
                holding(modifier) {
                    postTap(Key.tab, flags: modifier, duration: 0.2)
                    wait(1.2)
                    if command { postTap(Key.digits[1], flags: modifier); wait(0.5) }
                    let backdrop = MainActor.assumeIsolated { () -> NSPanel in
                        let panel = NSPanel(contentRect: NSScreen.main!.frame,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                        panel.backgroundColor = .white
                        panel.isOpaque = true
                        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
                        panel.hidesOnDeactivate = false
                        panel.ignoresMouseEvents = true
                        panel.orderFrontRegardless()
                        return panel
                    }
                    wait(0.6)
                    do { try captureOverlayCover(to: outputDirectory.appendingPathComponent(name + ".png")) }
                    catch { log("FAILED \(name): \(error)"); exit(1) }
                    MainActor.assumeIsolated { backdrop.orderOut(nil) }
                    postTap(Key.escape, flags: modifier)
                    log("captured \(name)")
                }
            }
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("cover") {
        for dark in [false, true] {
            setDemoAppearance(dark: dark)
            // Refresh previews after the system appearance changes.
            setDemoInstant(false)
            scene.focus(scene.groups[1][0])
            holding(.maskCommand) {
                postTap(Key.tab, flags: .maskCommand, duration: 0.2)
                wait(1.0)
                postTap(Key.digits[1], flags: .maskCommand)
                wait(1.0)
                let backdrop = MainActor.assumeIsolated { () -> NSPanel in
                    let panel = NSPanel(contentRect: NSScreen.main!.frame,
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.backgroundColor = dark ? .black : .white
                    panel.isOpaque = true
                    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
                    panel.hidesOnDeactivate = false
                    panel.ignoresMouseEvents = true
                    panel.orderFrontRegardless()
                    panel.displayIfNeeded()
                    return panel
                }
                wait(0.8)
                do { try captureOverlayCover(to: outputDirectory.appendingPathComponent(dark ? "overlay-dark.png" : "overlay.png"), dark: dark) }
                catch { log("FAILED cover: \(error)"); exit(1) }
                MainActor.assumeIsolated { backdrop.orderOut(nil) }
                postTap(Key.escape, flags: .maskCommand)
            }
        }
        setDemoAppearance(dark: false)
        setDemoInstant(false)
    }
    if requestedClips.isEmpty || requestedClips.contains("command-tab") {
        scene.restore()
        // Start each interaction with fresh light glass; reused surfaces can retain a dark backing.
        setDemoAppearance(dark: false)
        setDemoInstant(false)
        scene.startKeys()
        clip("command-tab", seconds: 7) {
            postFlags(.maskCommand)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1)
            postTap(Key.digits[2], flags: .maskCommand, duration: 0.2)
            wait(1.1)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1.1)
            releaseDemoModifier()
            scene.verifyFocus(scene.groups[2][1], space: 2)
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("organize-windows") {
        scene.restore()
        setDemoAppearance(dark: false)
        setDemoInstant(false)
        scene.startKeys()
        scene.focus(scene.groups[1][1])
        scene.focus(scene.groups[1][0])
        clip("organize-windows", seconds: 6) {
            postFlags(.maskCommand)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1.2)
            postTap(Key.upArrow, flags: .maskCommand, duration: 0.2)
            wait(1.4)
            releaseDemoModifier()
            scene.verifyFocus(scene.groups[1][1], space: 0)
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("option-tab") {
        scene.restore()
        setDemoAppearance(dark: false)
        setDemoInstant(false)
        scene.startKeys()
        scene.focus(scene.groups[0][1])
        scene.focus(scene.groups[1][0])
        clip("option-tab", seconds: 5) {
            postFlags(.maskAlternate)
            postTap(Key.tab, flags: .maskAlternate, duration: 0.2)
            wait(1.5)
            releaseDemoModifier()
            scene.verifyFocus(scene.groups[0][1], space: 0)
        }
    }
    if requestedClips.contains("faster-space-switching") || requestedClips.isEmpty {
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")!
        var hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        hotkeys["79"] = ["enabled": true, "value": ["type": "standard", "parameters": [65535, 123, 262144]]]
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
            scene.startKeys(fontSize: 128)
            let name = instant ? "speed-instant" : "speed-native"
            do {
                let url = outputDirectory.appendingPathComponent(name + ".mov")
                try? FileManager.default.removeItem(at: url)
                let recorder = try startDemoMovie(at: url)
                wait(0.5)
                postFlags(.maskControl)
                postTap(124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad], duration: 0.15)
                postFlags([])
                wait(1.5)
                guard SpaceService().currentDesktopIndex() == 2 else { log("FAILED: \(name) did not reach space 3"); exit(1) }
                postFlags(.maskControl)
                postTap(123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad], duration: 0.15)
                postFlags([])
                wait(2.5)
                guard SpaceService().currentDesktopIndex() == 1 else { log("FAILED: \(name) did not return to space 2"); exit(1) }
                try awaitCapture { try await recorder.stop() }
                log("verified \(name), space 2 → 3 → 2")
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
