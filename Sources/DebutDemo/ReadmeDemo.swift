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
    for bundle in ["com.apple.weather", "com.apple.stocks", "com.apple.Chess", "com.apple.Safari", "com.apple.Notes"] {
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

/// One window of the capture fixture: its app and a title fragment that identifies it.
struct CaptureFixtureWindow: Equatable, CustomStringConvertible {
    let bundle: String
    let title: String
    init(_ bundle: String, _ title: String = "") {
        self.bundle = bundle
        self.title = title
    }
    var description: String { title.isEmpty ? bundle : "\(bundle) / \(title)" }
}

/// The nine windows every README, onboarding and site capture shows, by desktop. Identical to
/// debut.site's `native/Sources/SpeedRecorder/ReadmeDemo.swift` and `scripts/capture-fixture.mjs`
/// (KHA-1119); change both repositories together.
let captureFixture: [[CaptureFixtureWindow]] = [
    [.init("com.apple.Safari", "Field Notes"), .init("com.apple.Terminal", "Research"),
     .init("com.apple.Notes", "Reading list")],
    [.init("com.apple.Safari", "Weekend Guide"), .init("com.apple.weather", "Cupertino"),
     .init("com.apple.stocks")],
    [.init("com.apple.Notes", "Project notes"), .init("com.apple.Chess"),
     .init("com.apple.Terminal", "Project")],
]

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
        func window(_ fixture: CaptureFixtureWindow) -> WindowInfo {
            guard let result = allWindows.first(where: {
                $0.ownerBundleID == fixture.bundle && (fixture.title.isEmpty || $0.title.contains(fixture.title))
            }) else {
                log("FAILED: missing fixture \(fixture); found \(allWindows.map { $0.ownerBundleID + "/" + $0.title })")
                exit(1)
            }
            return result
        }
        groups = captureFixture.map { $0.map(window) }
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

/// The window the open switcher has selected, read from Debut rather than inferred from a
/// Tab count: a space's cards follow its MRU order, not the fixture order.
func demoSelectedWindowID() -> CGWindowID? {
    let state = readState()
    let rows = (state["windowIDsBySpace"] ?? "").split(separator: ";", omittingEmptySubsequences: false)
    guard let space = Int(state["selectedSpaceIndex"] ?? ""), rows.indices.contains(space),
          let selection = Int(state["selectedWindowIndex"] ?? "") else { return nil }
    let ids = rows[space].split(separator: ",")
    guard ids.indices.contains(selection) else { return nil }
    return CGWindowID(ids[selection])
}

/// Confirms the selection before the modifier is released, so a wrong card fails the take
/// instead of focusing an unintended window.
func verifyDemoSelection(_ target: WindowInfo) {
    let deadline = Date().addingTimeInterval(2)
    while demoSelectedWindowID() != target.windowID, Date() < deadline { wait(0.05) }
    guard demoSelectedWindowID() == target.windowID else {
        log("FAILED: switcher selected \(demoSelectedWindowID().map(String.init) ?? "nothing") instead of "
            + "\(target.ownerName)/\(target.title) (\(target.windowID)); state \(readState())")
        exit(1)
    }
    log("verified overlay selection: \(target.ownerName)/\(target.title)")
}

func releaseDemoModifier() {
    wait(0.4)
    postFlags([])
    wait(1.1)
}

/// Restarts Debut from the fresh capture settings, so no earlier clip's choice carries over.
func setDemoInstant(_ enabled: Bool, windowPreviews: Bool = true) {
    _ = run("/usr/bin/pkill", ["-x", "Debut"])
    wait(0.6)
    do {
        try writeCaptureSettings(captureSettings(fasterDesktopSwitching: enabled, windowPreviews: windowPreviews))
    } catch { log("FAILED: could not write the capture settings: \(error)"); exit(1) }
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
        // Previews off is icon mode, drawn with its own fresh defaults.
        for previews in [true, false] {
            setDemoInstant(false, windowPreviews: previews)
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
        // Front Terminal in space 3 so its MRU order makes Project notes the second card.
        scene.focus(scene.groups[2][2])
        scene.startKeys()
        clip("command-tab", seconds: 7) {
            postFlags(.maskCommand)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1)
            postTap(Key.digits[2], flags: .maskCommand, duration: 0.2)
            wait(1.1)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(1.1)
            verifyDemoSelection(scene.groups[2][0])
            releaseDemoModifier()
            scene.verifyFocus(scene.groups[2][0], space: 2)
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
            verifyDemoSelection(scene.groups[1][1])
            postTap(Key.upArrow, flags: .maskCommand, duration: 0.2)
            wait(1.4)
            releaseDemoModifier()
            scene.verifyFocus(scene.groups[1][1], space: 0)
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("overview") {
        // README overview (KHA-1122): Command-Tab across spaces and a window move, out and back.
        // Space 2 opens Weekend Guide, Stocks, Weather, so Stocks is the first Tab and returns
        // to the same place, and Field Notes leads space 1.
        let (guide, weather, stocks) = (scene.groups[1][0], scene.groups[1][1], scene.groups[1][2])
        scene.restore()
        setDemoAppearance(dark: false)
        // Debut's default, Instant: with faster switching off, macOS 27 switches through the
        // system's Control-number shortcut, which KeyCastr would caption as a press.
        setDemoInstant(true)
        scene.focus(scene.groups[0][0])
        scene.focus(weather)
        // An Accessibility raise does not restack across apps on macOS 27, so the opening
        // order, the one the loop ends in, is set through Command-Tab before keys are shown.
        activateThroughSwitcher(stocks)
        activateThroughSwitcher(guide)
        scene.verifyFocus(guide, space: 1)
        scene.startKeys()
        waitForDemoIndicatorToHide()
        clip("overview", seconds: 11) {
            postFlags(.maskCommand)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(0.8)
            verifyDemoSelection(stocks)
            postTap(Key.upArrow, flags: .maskCommand, duration: 0.2)
            wait(1.0)
            verifyDemoSelection(stocks)
            releaseDemoModifier()
            scene.verifyFocus(stocks, space: 0)
            wait(1.2)
            postFlags(.maskCommand)
            postTap(Key.tab, flags: .maskCommand, duration: 0.2)
            wait(0.7)
            verifyDemoSelection(scene.groups[0][0])
            postTap(Key.tab, flags: [.maskCommand, .maskShift], duration: 0.16)
            wait(0.7)
            verifyDemoSelection(stocks)
            postTap(Key.downArrow, flags: .maskCommand, duration: 0.2)
            wait(0.8)
            verifyDemoSelection(stocks)
            postTap(Key.tab, flags: .maskCommand, duration: 0.16)
            wait(0.8)
            verifyDemoSelection(guide)
            releaseDemoModifier()
            scene.verifyFocus(guide, space: 1)
            guard scene.service.desktopIndex(forWindow: stocks.windowID) == 1 else {
                log("FAILED: Stocks did not return to space 2"); exit(1)
            }
            waitForDemoIndicatorToHide()
        }
    }
    if requestedClips.isEmpty || requestedClips.contains("option-tab") {
        scene.restore()
        setDemoAppearance(dark: false)
        setDemoInstant(false)
        scene.startKeys()
        scene.focus(scene.groups[0][0])
        scene.focus(scene.groups[1][0])
        clip("option-tab", seconds: 5) {
            postFlags(.maskAlternate)
            postTap(Key.tab, flags: .maskAlternate, duration: 0.2)
            wait(1.5)
            verifyDemoSelection(scene.groups[0][0])
            releaseDemoModifier()
            scene.verifyFocus(scene.groups[0][0], space: 0)
        }
    }
    if requestedClips.contains("faster-space-switching") || requestedClips.contains("onboarding-speed") || requestedClips.isEmpty {
        let onboarding = requestedClips.contains("onboarding-speed")
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
            clearNotifications()
            // Provisioning/Mission Control leaves Dock's carousel in recovery. Debut
            // deliberately yields that first shortcut to macOS. Settle it before
            // recording either side, then verify Debut owns both Instant transitions.
            for (key, desktop) in [(CGKeyCode(124), 2), (CGKeyCode(123), 1)] {
                postFlags(.maskControl)
                postTap(key, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad], duration: 0.15)
                postFlags([])
                wait(1.5)
                scene.verifyFocus(scene.groups[desktop][0], space: desktop)
            }
            // Each side is scaled to half width, so keep the final key text the same size.
            scene.startKeys(fontSize: 128)
            let name = (onboarding ? "onboarding-" : "") + (instant ? "speed-instant" : "speed-native")
            do {
                let switchesBefore = recordedDemoSwitches()
                let url = outputDirectory.appendingPathComponent(name + ".mov")
                try? FileManager.default.removeItem(at: url)
                let recorder = try startDemoMovie(at: url, framesPerSecond: onboarding ? 60 : 30)
                wait(0.5)
                postFlags(.maskControl)
                postTap(124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad], duration: 0.15)
                postFlags([])
                wait(1.5)
                guard SpaceService().currentDesktopIndex() == 2 else { log("FAILED: \(name) did not reach space 3"); exit(1) }
                scene.verifyFocus(scene.groups[2][0], space: 2)
                postFlags(.maskControl)
                postTap(123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad], duration: 0.15)
                postFlags([])
                wait(2.5)
                guard SpaceService().currentDesktopIndex() == 1 else { log("FAILED: \(name) did not return to space 2"); exit(1) }
                scene.verifyFocus(scene.groups[1][0], space: 1)
                try awaitCapture { try await recorder.stop() }
                let switches = recordedDemoSwitches().subtracting(switchesBefore).count
                guard switches == (instant ? 2 : 0) else {
                    log("FAILED: \(name) expected \(instant ? 2 : 0) Debut switches, observed \(switches)")
                    exit(1)
                }
                log("verified \(name), space 2 → 3 → 2")
            } catch { log("FAILED \(name): \(error)"); exit(1) }
        }
    }
    _ = run("/usr/bin/pkill", ["-x", "KeyCastr"])
    describeState("final")
}

/// Adjacent Control-arrow switches go straight through SpaceService and report no
/// `space_switched`. Count the distinct key events Debut handled instead, as debut.site's
/// recorder does; the destination desktop and focus are verified separately around each take.
func handledAdjacentSwitches(in snapshot: Data) -> Set<String> {
    guard let json = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
          let events = json["events"] as? [[String: String]] else { return [] }
    return Set(events.compactMap { event in
        guard event["event"] == "key_event",
              event["keyEvent"]?.hasPrefix("switchAdjacentSpace(") == true else { return nil }
        return event["uptimeNanoseconds"]
    })
}

private func recordedDemoSwitches() -> Set<String> {
    (try? Data(contentsOf: diagnosticFile)).map(handledAdjacentSwitches) ?? []
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

/// Waits for Debut's desktop indicator to finish, so a loop does not end on it.
func waitForDemoIndicatorToHide() {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let showing = windows.contains { window in
            guard window[kCGWindowOwnerName as String] as? String == "Debut",
                  window[kCGWindowLayer as String] as? Int == Int(NSWindow.Level.statusBar.rawValue),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return false }
            return width > 70 && width < 500 && height > 35 && height < 150
        }
        if !showing { wait(0.2); return }
        wait(0.1)
    }
    log("FAILED: desktop indicator did not finish before the loop boundary"); exit(1)
}

/// Brings `target` forward through Debut's Command-Tab, reading the selection back from Debut.
func activateThroughSwitcher(_ target: WindowInfo) {
    postFlags(.maskCommand)
    postTap(Key.tab, flags: .maskCommand, duration: 0.2)
    wait(0.6)
    for _ in 0..<8 where demoSelectedWindowID() != target.windowID {
        postTap(Key.tab, flags: .maskCommand, duration: 0.16)
        wait(0.4)
    }
    verifyDemoSelection(target)
    releaseDemoModifier()
}
