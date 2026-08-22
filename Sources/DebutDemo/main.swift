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
    let result = CGDisplaySetDisplayMode(display, best, nil)
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

func stageWindowCounts() -> [Int] {
    (readState()["windowCountsByStage"] ?? "").split(separator: ",").compactMap { Int($0) }
}

func describeState(_ label: String) {
    let state = readState()
    log("\(label): stages=\(state["stageCount"] ?? "?") counts=\(state["windowCountsByStage"] ?? "?") "
        + "active=\(state["activeStageIndex"] ?? "?") selected=\(state["selectedWindowIndex"] ?? "?")")
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
    let path = outputDirectory.appendingPathComponent("\(name).png").path
    let status = run("/usr/sbin/screencapture", ["-x", "-r", path])
    log(status == 0 ? "still \(name).png" : "still \(name) FAILED (status \(status))")
}

/// `screencapture -v` returns only when the recording stops, so it runs detached while the
/// scripted input plays underneath it. `-V` bounds the clip; the caller's actions must fit.
func clip(_ name: String, seconds: Int, _ body: () -> Void) {
    guard requestedClips.isEmpty || requestedClips.contains(name) else {
        log("clip \(name) skipped")
        return
    }
    let path = outputDirectory.appendingPathComponent("\(name).mov").path
    try? FileManager.default.removeItem(atPath: path)

    let recorder = Process()
    recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    recorder.arguments = ["-v", "-x", "-V", "\(seconds)", path]
    do {
        try recorder.run()
    } catch {
        log("clip \(name) FAILED to start: \(error)")
        return
    }
    // screencapture spends about a second negotiating the stream before the first frame.
    wait(1.5)
    body()
    recorder.waitUntilExit()
    let exists = FileManager.default.fileExists(atPath: path)
    log(exists ? "clip \(name).mov" : "clip \(name) FAILED (no file)")
}

// MARK: - Stage arrangement

/// Splits the single startup stage into three, driving Debut's own overlay commands rather
/// than writing state.json, because window IDs are ephemeral and would not survive a write.
func arrangeStages(windowsPerStage: Int) {
    describeState("before arrange")
    describeWindows("before arrange")

    // Every in-overlay command carries only the held activation modifier. Adding Option
    // turns Tab into stage cycling and stops N and the digits matching at all.
    let held: CGEventFlags = .maskCommand
    holding(held) {
        postTap(Key.tab, flags: held)
        wait(0.8)
        // N creates a stage below the active one and makes it active, so two taps leave
        // the startup stage at index 0 with two empty stages under it.
        postTap(Key.n, flags: held)
        wait(0.6)
        describeState("  after first new stage")
        postTap(Key.n, flags: held)
        wait(0.6)
        describeState("  after second new stage")
        describeWindows("  after second new stage")

        // A moved window drags the selection with it, so reaching stage 2 is two hops and
        // every hop starts by jumping back to stage 1.
        let plan = Array(repeating: 1, count: windowsPerStage)
            + Array(repeating: 2, count: windowsPerStage)
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

    describeState("after arrange")
    describeWindows("after arrange")
    let counts = stageWindowCounts()
    if counts.count != 3 || counts.contains(0) {
        log("WARNING: expected three non-empty stages, got \(counts)")
    }
}

// MARK: - Clips

func recordStageSwitch() {
    clip("stage-switch", seconds: 11) {
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

// MARK: - Main

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard CGPreflightScreenCaptureAccess() else {
    log("Screen Recording is not granted to the demo driver; nothing can be captured.")
    exit(1)
}

log("output: \(outputDirectory.path)")
selectDisplayMode(value(after: "--display"))

arrangeStages(windowsPerStage: Int(value(after: "--windows-per-stage") ?? "") ?? 3)
wait(1.0)

// After the arrangement, not before: Debut's login-item banner arrives on its first launch and
// the arrangement takes a minute, so an early sweep would clear a store that then refills.
clearNotifications()

captureStills()
wait(1.0)
recordStageSwitch()
wait(1.0)
recordWindowCycle()
wait(1.0)
recordQuickSwitch()
wait(1.0)
recordWindowMove()

describeState("final")
log("done")
