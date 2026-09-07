import AppKit
import CoreGraphics
import DebutCore
import Foundation

// Captures the README media inside the Tart guest. It shares no code with DebutE2E on
// purpose: the suite asserts, this one performs, and a demo that fails a capture should
// say so and move on rather than fail a build.

let arguments = ProcessInfo.processInfo.arguments
let outputDirectory = URL(fileURLWithPath: value(after: "--output") ?? "/tmp/debut-demo-media")
let requestedClips = Set(value(after: "--clips")?.split(separator: ",").map(String.init) ?? [])

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

func log(_ message: String) {
    print("[demo] \(message)")
    fflush(stdout)
}

func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - Display

/// Tart's `--display` is a hint the guest is free to ignore, and this one does: it boots at
/// 1024x768 whatever the VM is set to, which is a dated 4:3 frame for README media. The mode
/// is therefore selected from inside the session, where the virtual display does offer the
/// widescreen sizes. HiDPI wins ties so the capture is retina.
func selectDisplayMode(_ requested: String?) {
    let display = CGMainDisplayID()
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
        log("no display modes are enumerable")
        return
    }
    log("current mode: \(CGDisplayCopyDisplayMode(display).map(describe) ?? "unknown")")
    log("available: " + modes.map(describe).joined(separator: " "))

    guard let requested else { return }
    let parts = requested.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else {
        log("ignoring unparsable display request '\(requested)'")
        return
    }
    let matching = modes.filter { $0.width == parts[0] && $0.height == parts[1] }
    guard let best = matching.max(by: { $0.pixelWidth < $1.pixelWidth }) else {
        log("no mode matches \(requested); staying put")
        return
    }
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return }
    let configured = CGConfigureDisplayWithDisplayMode(configuration, display, best, nil)
    let result: CGError
    if configured == .success {
        result = CGCompleteDisplayConfiguration(configuration, .forSession)
    } else {
        CGCancelDisplayConfiguration(configuration)
        result = configured
    }
    log("set mode \(describe(best)): \(result == .success ? "ok" : "failed (\(result.rawValue))")")
    wait(2.0)
}

func describe(_ mode: CGDisplayMode) -> String {
    "\(mode.width)x\(mode.height)@\(mode.pixelWidth / max(mode.width, 1))x"
}

// MARK: - Debut state

let diagnosticFile = DebutCore.applicationSupportDirectory
    .appendingPathComponent("diagnostic.json")

func readState() -> [String: String] {
    guard let data = try? Data(contentsOf: diagnosticFile),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let state = json["state"] as? [String: String]
    else { return [:] }
    return state
}

func spaceWindowCounts() -> [Int] {
    (readState()["windowCountsBySpace"] ?? "").split(separator: ",").compactMap { Int($0) }
}

func describeState(_ label: String) {
    let state = readState()
    log("\(label): spaces=\(state["spaceCount"] ?? "?") counts=\(state["windowCountsBySpace"] ?? "?") "
        + "active=\(state["activeSpaceIndex"] ?? "?") selected=\(state["selectedWindowIndex"] ?? "?")")
}

func describeWindows(_ label: String) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let named = info.compactMap { window -> String? in
        guard let owner = window[kCGWindowOwnerName as String] as? String,
              let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
              let title = window[kCGWindowName as String] as? String, !title.isEmpty
        else { return nil }
        return "\(owner)/\(title)"
    }
    log("\(label) windows (\(named.count)): \(named.joined(separator: " | "))")
}

// MARK: - Input

enum Key {
    static let tab: CGKeyCode = 48
    static let escape: CGKeyCode = 53
    static let n: CGKeyCode = 45
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126
    static let digits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
}

func postFlags(_ flags: CGEventFlags) {
    guard let event = CGEvent(source: nil) else { return }
    event.type = .flagsChanged
    event.flags = flags
    event.post(tap: .cgSessionEventTap)
}

func postTap(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }
}

/// Holds `flags` for the duration of `body`, then releases cleanly. Debut commits the
/// selection on the release, so an early return must not leave the modifier asserted.
func holding(_ flags: CGEventFlags, _ body: () -> Void) {
    postFlags(flags)
    wait(0.1)
    body()
    postFlags([])
    wait(0.6)
}

// MARK: - Capture

func run(_ launchPath: String, _ commandArguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = commandArguments
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Focus does not silence the banner macOS posts when Debut is added as a login item, and
/// that banner sits in the top-right of every frame. Emptying the notification store and
/// restarting its two agents clears what is on screen and what is queued behind it.
func clearNotifications() {
    // usernoted owns the store, so it has to go first or every delete comes back "database
    // is locked" and the banner survives.
    _ = run("/usr/bin/killall", ["usernoted"])
    wait(1.0)

    // Tahoe keeps this in the usernoted group container. The `DARWIN_USER_DIR` location that
    // every "clear macOS notifications" recipe names does not exist here at all.
    let database = NSHomeDirectory()
        + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    let status = run("/usr/bin/sqlite3", [
        database,
        "delete from record; delete from delivered; delete from displayed; delete from requests;",
    ])
    log("cleared notifications: \(database) -> \(status == 0 ? "ok" : "status \(status)")")

    _ = run("/usr/bin/killall", ["NotificationCenter"])
    wait(2.5)
}

func still(_ name: String) {
    let url = outputDirectory.appendingPathComponent("\(name).png")
    do {
        try captureDemoStill(to: url)
        log("still \(name).png")
    } catch {
        log("still \(name) FAILED: \(error)")
        exit(1)
    }
}

func clip(_ name: String, seconds: Int, _ body: () -> Void) {
    guard requestedClips.isEmpty || requestedClips.contains(name) else { return }
    let url = outputDirectory.appendingPathComponent("\(name).mov")
    try? FileManager.default.removeItem(at: url)
    do {
        let recorder = try startDemoMovie(at: url)
        let started = Date()
        wait(0.5)
        body()
        wait(max(0, Double(seconds) - Date().timeIntervalSince(started)))
        try awaitCapture { try await recorder.stop() }
        log("clip \(name).mov")
    } catch {
        log("clip \(name) FAILED: \(error)")
        exit(1)
    }
}

// MARK: - Space arrangement

/// Distributes windows across three provisioned desktops using Debut's overlay rather
/// than writing state.json, because window IDs are ephemeral and would not survive a write.
func arrangeSpaces(windowsPerSpace: Int) {
    guard SpaceService().userDesktops().count >= 3 else {
        log("Demo requires three real desktops. Run the guest provisioning step first.")
        exit(1)
    }
    describeState("before arrange")
    describeWindows("before arrange")

    // Every in-overlay command carries only the held activation modifier. Adding Option
    // turns Tab into space cycling and stops the digits matching.
    let held: CGEventFlags = .maskCommand
    holding(held) {
        postTap(Key.tab, flags: held)
        wait(0.8)
        // A moved window drags the selection with it, so reaching space 2 is two hops and
        // every hop starts by jumping back to space 1.
        let plan = Array(repeating: 1, count: windowsPerSpace)
            + Array(repeating: 2, count: windowsPerSpace)
        for hops in plan {
            postTap(Key.digits[0], flags: held)
            wait(0.4)
            for _ in 0..<hops {
                postTap(Key.downArrow, flags: held)
                wait(0.4)
            }
            describeState("  after \(hops)-hop move")
        }

        postTap(Key.digits[0], flags: held)
        wait(0.5)
    }

    wait(2)
    describeState("after arrange")
    describeWindows("after arrange")
    let counts = spaceWindowCounts()
    if counts.count != 3 || counts.contains(0) {
        log("FAILED: expected three non-empty desktops, got \(counts)")
        exit(1)
    }
}

// MARK: - Clips

func recordSpaceSwitch() {
    clip("space-switch", seconds: 11) {
        holding([.maskCommand, .maskAlternate]) {
            postTap(Key.tab, flags: [.maskCommand, .maskAlternate])
            wait(1.6)
            postTap(Key.tab, flags: [.maskCommand, .maskAlternate])
            wait(1.4)
            postTap(Key.tab, flags: [.maskCommand, .maskAlternate])
            wait(1.6)
            postTap(Key.tab, flags: [.maskCommand, .maskAlternate, .maskShift])
            wait(1.6)
        }
        wait(2.0)
    }
}

func recordWindowCycle() {
    clip("window-cycle", seconds: 9) {
        holding(.maskCommand) {
            postTap(Key.tab, flags: .maskCommand)
            wait(1.5)
            postTap(Key.tab, flags: .maskCommand)
            wait(1.3)
            postTap(Key.tab, flags: .maskCommand)
            wait(1.5)
        }
        wait(2.0)
    }
}

func recordAllWindows() {
    clip("all-windows", seconds: 10) {
        holding(.maskAlternate) {
            postTap(Key.tab, flags: .maskAlternate)
            wait(1.5)
            still("all-windows")
            for _ in 0..<3 {
                postTap(Key.tab, flags: .maskAlternate)
                wait(1.3)
            }
        }
        wait(2)
    }
}

func recordQuickSwitch() {
    clip("quick-switch", seconds: 9) {
        for digit in [1, 2, 0, 2] {
            postFlags(.maskControl)
            wait(0.1)
            postTap(Key.digits[digit], flags: .maskControl)
            postFlags([])
            wait(1.7)
        }
    }
}

func recordWindowMove() {
    clip("window-move", seconds: 10) {
        holding(.maskCommand) {
            postTap(Key.tab, flags: .maskCommand)
            wait(1.8)
            postTap(Key.downArrow, flags: .maskCommand)
            wait(2.2)
            postTap(Key.upArrow, flags: .maskCommand)
            wait(1.8)
        }
        wait(1.5)
    }
}

func captureStills() {
    holding([.maskCommand, .maskAlternate]) {
        postTap(Key.tab, flags: [.maskCommand, .maskAlternate])
        wait(1.5)
        still("overlay")
        postTap(Key.escape, flags: [.maskCommand, .maskAlternate])
        wait(0.5)
    }
}

func resetOnboardingDesktop() {
    let service = SpaceService()
    service.switchDuration = 0
    service.switchToDesktop(index: 0)
    wait(1)
    guard service.currentDesktopIndex() == 0 else { log("FAILED: comparison did not reset to Desktop 1"); exit(1) }
}

func arrangeOnboardingWindows() {
    let windows = AccessibilityWindowService().listWindows()
    let service = SpaceService()
    for window in windows where window.ownerBundleID == "com.apple.TextEdit" {
        let desktop = window.title.contains("Notes") ? 1 : 0
        service.moveWindow(windowID: window.windowID, toDesktop: desktop) { _ in }
        wait(0.3)
        guard service.desktopIndex(forWindow: window.windowID) == desktop else {
            log("FAILED: example window did not reach its desktop"); exit(1)
        }
    }
    resetOnboardingDesktop()
    _ = run("/usr/bin/pkill", ["-x", "Debut"])
    wait(0.7)
    _ = run("/usr/bin/open", ["/Applications/Debut.app"])
    wait(3)
    guard let notes = windows.first(where: { $0.title.contains("Notes") }) else { exit(1) }
    let row = (readState()["windowIDsBySpace"] ?? "").split(separator: ";", omittingEmptySubsequences: false)
    guard row.count > 1, row[1].split(separator: ",").contains(Substring(String(notes.windowID))) else {
        log("FAILED: Debut's screenshot would show Notes on the wrong desktop"); exit(1)
    }
    if let work = windows.first(where: { $0.title.contains("Work") }) {
        _ = AccessibilityWindowService().raiseWindow(windowID: work.windowID)
    }
    wait(1)
}

// Dedicated first-use media, always recorded in the disposable guest.
func recordOnboarding() {
    guard requestedClips.contains("onboarding") else { return }
    _ = run("/usr/bin/killall", ["Dock"])
    wait(3)
    holding(.maskCommand) {
        // Keep Tab down long enough to open the visual switcher.
        let down = CGEvent(keyboardEventSource: nil, virtualKey: Key.tab, keyDown: true)!
        down.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        wait(1.2)
        still("onboarding-workspace")
        let up = CGEvent(keyboardEventSource: nil, virtualKey: Key.tab, keyDown: false)!
        up.flags = .maskCommand
        up.post(tap: .cgSessionEventTap)
        postTap(Key.escape, flags: .maskCommand)
    }
    holding(.maskAlternate) {
        postTap(Key.tab, flags: .maskAlternate)
        wait(1.2)
        still("onboarding-previews")
        postTap(Key.escape, flags: .maskAlternate)
    }
    // The comparison uses an unmodified OS shortcut while Debut is stopped.
    // Each path starts on the same desktop and records both directions.
    _ = run("/usr/bin/pkill", ["-x", "Debut"])
    wait(1)
    let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")!
    var hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
    for (id, code) in [("79", 123), ("81", 124)] {
        hotkeys[id] = ["enabled": true, "value": ["type": "standard", "parameters": [65535, code, 262144]]]
    }
    defaults.set(hotkeys, forKey: "AppleSymbolicHotKeys")
    defaults.synchronize()
    _ = run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    _ = run("/usr/bin/killall", ["Dock"])
    wait(3)
    for native in [true, false] {
        resetOnboardingDesktop()
        let url = outputDirectory.appendingPathComponent(native ? "onboarding-native.mov" : "onboarding-instant.mov")
        do {
            let recorder = try startDemoMovie(at: url)
            wait(0.8)
            for destination in [1, 0] {
                let started = Date()
                if native {
                    let source = CGEventSource(stateID: .hidSystemState)
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: source, virtualKey: destination == 1 ? 124 : 123, keyDown: down)!
                        // Physical arrow keys carry the function-key and numeric-pad flags.
                        // A session event with only Control is ignored by the native shortcut.
                        event.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
                        event.post(tap: .cghidEventTap)
                    }
                    wait(0.6)
                } else {
                    // A fresh service owns one gesture. Reusing an unsettled coordinator would
                    // queue the reset forever and record a still image on the second trial.
                    let service = SpaceService()
                    service.switchDuration = 0
                    service.switchToDesktop(index: destination)
                    wait(0.6)
                }
                guard SpaceService().currentDesktopIndex() == destination else {
                    log("FAILED: \(native ? "macOS default" : "Instant") never reached desktop \(destination)")
                    exit(1)
                }
                log("verified \(native ? "macOS default" : "Instant") desktop \(destination)")
                wait(max(0, 2 - Date().timeIntervalSince(started)))
            }
            try awaitCapture { try await recorder.stop() }
        } catch { log("onboarding movie failed: \(error)"); exit(1) }
    }
    _ = run("/usr/bin/pkill", ["-x", "Debut"])
    wait(1)
    let withoutPreviews = Process()
    withoutPreviews.executableURL = URL(fileURLWithPath: "/Applications/Debut.app/Contents/MacOS/Debut")
    var environment = ProcessInfo.processInfo.environment
    environment["DEBUT_DISABLE_WINDOW_PREVIEWS"] = "1"
    withoutPreviews.environment = environment
    try! withoutPreviews.run()
    wait(4)
    holding(.maskAlternate) {
        postTap(Key.tab, flags: .maskAlternate)
        wait(1)
        still("onboarding-no-previews")
        postTap(Key.escape, flags: .maskAlternate)
    }
    withoutPreviews.terminate()
}

// MARK: - Main

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard CGPreflightScreenCaptureAccess() else {
    log("Screen Recording is not granted to the demo driver; nothing can be captured.")
    exit(1)
}

log("output: \(outputDirectory.path)")
selectDisplayMode(value(after: "--display"))
if arguments.contains("--prepare-display") { exit(0) }

if requestedClips.contains("onboarding") { arrangeOnboardingWindows() }
else { arrangeSpaces(windowsPerSpace: Int(value(after: "--windows-per-space") ?? "") ?? 3) }
wait(1.0)

// After the arrangement, not before: Debut's login-item banner arrives on its first launch and
// the arrangement takes a minute, so an early sweep would clear a store that then refills.
clearNotifications()

if requestedClips.contains("onboarding") {
    recordOnboarding()
    log("done")
    exit(0)
}
captureStills()
wait(1.0)
recordSpaceSwitch()
wait(1.0)
recordWindowCycle()
wait(1.0)
recordQuickSwitch()
wait(1.0)
recordAllWindows()
wait(1.0)
recordWindowMove()

describeState("final")
log("done")
