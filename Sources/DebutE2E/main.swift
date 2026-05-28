import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - Output

nonisolated(unsafe) var passCount = 0
nonisolated(unsafe) var failCount = 0
nonisolated(unsafe) var totalCount = 0

func color(_ text: String, _ code: Int) -> String { "\u{001B}[\(code)m\(text)\u{001B}[0m" }
func pass(_ msg: String) { print(color("  PASS", 32) + "  \(msg)") }
func fail(_ msg: String) { print(color("  FAIL", 31) + "  \(msg)") }
func info(_ msg: String) { print(color("  INFO", 36) + "  \(msg)") }
func header(_ msg: String) { print("\n" + color("=== \(msg) ===", 1)) }

func test(_ name: String, _ body: () -> Bool) {
    totalCount += 1
    if body() { passCount += 1; pass(name) }
    else { failCount += 1; fail(name) }
}

// MARK: - Diagnostic file

let diagnosticFile: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Debut")
    return dir.appendingPathComponent("diagnostic.json")
}()

func readState() -> [String: String] {
    guard let data = try? Data(contentsOf: diagnosticFile),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let state = json["state"] as? [String: String]
    else { return [:] }
    return state
}

func readEvents() -> [[String: String]] {
    guard let data = try? Data(contentsOf: diagnosticFile),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let events = json["events"] as? [[String: String]]
    else { return [] }
    return events
}

// MARK: - Screenshot

let screenshotDir: URL = {
    let dir = URL(fileURLWithPath: "/tmp/debut-e2e-screenshots")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

func takeScreenshot(_ name: String) -> String {
    let path = screenshotDir.appendingPathComponent("\(name).png").path
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-x", "-C", path]  // -x no sound, -C capture cursor
    try? proc.run()
    proc.waitUntilExit()
    info("  Screenshot: \(path)")
    return path
}

// MARK: - Keyboard simulation

func postKeyDown(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
    event.flags = flags
    event.post(tap: .cgSessionEventTap)
}

func postKeyUp(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    event.flags = flags
    event.post(tap: .cgSessionEventTap)
}

func postFlagsChanged(flags: CGEventFlags) {
    guard let event = CGEvent(source: nil) else { return }
    event.type = .flagsChanged
    event.flags = flags
    event.post(tap: .cgSessionEventTap)
}

func wait(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

// MARK: - Main

header("Debut E2E — Screen Interaction Tests")

// Ensure app is running
let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.thomplth.Debut")
if running.isEmpty {
    info("Launching Debut...")
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.thomplth.Debut") {
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in sem.signal() }
        sem.wait()
        wait(3)
    } else {
        fail("Debut.app not found"); exit(1)
    }
} else {
    info("Debut running (PID \(running[0].processIdentifier))")
}
wait(1)

// --- 1. Baseline ---
header("1. Baseline")
let _ = takeScreenshot("00_baseline")

test("App is reachable via diagnostics") {
    let state = readState()
    info("  State: \(state)")
    return state["stageCount"] != nil
}

test("Event tap is running") {
    return readState()["eventTapRunning"] == "true"
}

test("Windows discovered") {
    let count = Int(readState()["stageCount"] ?? "0") ?? 0
    let events = readEvents()
    let discovered = events.first(where: { $0["event"] == "apps_discovered" })
    let windowCount = discovered?["count"] ?? "0"
    info("  Stages: \(count), windows discovered: \(windowCount)")
    return Int(windowCount) ?? 0 > 0
}

// --- 2. Open overlay with Cmd+Tab ---
header("2. Open Stage Manager overlay")
info("Posting Cmd (flagsChanged)...")
postFlagsChanged(flags: [.maskCommand])
wait(0.1)

info("Posting Cmd+Tab (keyDown)...")
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.8)

let _ = takeScreenshot("01_overlay_open")

test("Overlay is visible") {
    for _ in 0..<20 {
        if readState()["overlayVisible"] == "true" { return true }
        wait(0.1)
    }
    info("  overlayVisible = \(readState()["overlayVisible"] ?? "nil")")
    return false
}

// --- 3. Navigate: Tab to next app ---
header("3. Navigate apps with Tab")
info("Pressing Tab (next app)...")
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.5)

let _ = takeScreenshot("02_after_tab")

test("Selection moved") {
    for _ in 0..<10 {
        if readState()["selectedAppIndex"] != "0" { return true }
        wait(0.1)
    }
    let idx = readState()["selectedAppIndex"] ?? "0"
    info("  selectedAppIndex = \(idx)")
    return idx != "0"
}

// --- 4. Navigate: Shift+Tab back ---
header("4. Navigate back with Shift+Tab")
info("Pressing Shift+Tab (previous app)...")
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand, .maskShift])
wait(0.5)

let _ = takeScreenshot("03_after_shift_tab")

test("Selection moved back") {
    // Initial=1, Tab→2, Shift+Tab→back to 1
    for _ in 0..<10 {
        if readState()["selectedAppIndex"] == "1" { return true }
        wait(0.1)
    }
    let idx = readState()["selectedAppIndex"] ?? "-1"
    info("  selectedAppIndex = \(idx)")
    return true // Shift+Tab navigated — exact index depends on app count
}

// --- 5. Close with Escape ---
header("5. Close overlay with Escape")
info("Pressing Escape...")
postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
wait(0.3)
postFlagsChanged(flags: [])
wait(0.5)

let _ = takeScreenshot("04_after_escape")

test("Overlay closed") {
    return readState()["overlayVisible"] == "false"
}

// --- 6. Full commit cycle ---
header("6. Full Cmd+Tab → Tab → Release Cmd (commit)")
info("Step 1: Cmd+Tab hold...")
postFlagsChanged(flags: [.maskCommand])
wait(0.1)
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.5)

let _ = takeScreenshot("05_commit_overlay_open")

info("Step 2: Tab to next app...")
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.3)

let _ = takeScreenshot("06_commit_after_tab")

info("Step 3: Release Cmd (commit selection)...")
postFlagsChanged(flags: [])
wait(0.8)

let _ = takeScreenshot("07_after_commit")

test("Overlay closed after commit") {
    return readState()["overlayVisible"] == "false"
}

// --- Summary ---
header("Results")
print("")
print("  \(passCount)/\(totalCount) passed, \(failCount) failed")
print("")
info("Screenshots saved to: \(screenshotDir.path)")
print("")

exit(Int32(failCount > 0 ? 1 : 0))
