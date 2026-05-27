import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - Output helpers

func color(_ text: String, _ code: Int) -> String { "\u{001B}[\(code)m\(text)\u{001B}[0m" }
func pass(_ msg: String) { print(color("  PASS", 32) + "  \(msg)") }
func fail(_ msg: String) { print(color("  FAIL", 31) + "  \(msg)") }
func info(_ msg: String) { print(color("  INFO", 36) + "  \(msg)") }
func header(_ msg: String) { print("\n" + color("=== \(msg) ===", 1)) }

nonisolated(unsafe) var passCount = 0
nonisolated(unsafe) var failCount = 0
nonisolated(unsafe) var totalCount = 0

func test(_ name: String, _ body: () -> Bool) {
    totalCount += 1
    if body() {
        passCount += 1
        pass(name)
    } else {
        failCount += 1
        fail(name)
    }
}

// MARK: - Diagnostic file reader

let diagnosticFile: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Debut")
    return dir.appendingPathComponent("diagnostic.json")
}()

func readDiagnostic() -> [String: Any]? {
    guard let data = try? Data(contentsOf: diagnosticFile),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
}

func readState() -> [String: String] {
    guard let diag = readDiagnostic(),
          let state = diag["state"] as? [String: String]
    else { return [:] }
    return state
}

func readEvents() -> [[String: String]] {
    guard let diag = readDiagnostic(),
          let events = diag["events"] as? [[String: String]]
    else { return [] }
    return events
}

func waitForEvent(_ eventName: String, timeout: TimeInterval = 3) -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        let events = readEvents()
        if events.contains(where: { $0["event"] == eventName }) { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

// MARK: - CGEvent posting

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

// MARK: - Main

header("Debut E2E Test Harness")

// Check if app is running
info("Checking if Debut is running...")
let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.thomplth.Debut")
if running.isEmpty {
    info("Debut not running. Launching...")
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.thomplth.Debut") {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in sem.signal() }
        sem.wait()
        info("Waiting for app to initialize...")
        Thread.sleep(forTimeInterval: 3)
    } else {
        fail("Debut.app not found in /Applications")
        exit(1)
    }
} else {
    info("Debut already running (PID \(running[0].processIdentifier))")
}

// Wait for diagnostic file
Thread.sleep(forTimeInterval: 1)

// --- Test 1: Diagnostic file ---
header("1. App Communication (file-based IPC)")

test("Diagnostic file exists") {
    let exists = FileManager.default.fileExists(atPath: diagnosticFile.path)
    if !exists {
        info("  File not found at: \(diagnosticFile.path)")
    }
    return exists
}

test("Diagnostic file has valid state") {
    let state = readState()
    if state.isEmpty {
        info("  State is empty. Raw file:")
        if let data = try? Data(contentsOf: diagnosticFile), let str = String(data: data, encoding: .utf8) {
            info("  \(String(str.prefix(500)))")
        }
        return false
    }
    info("  State: \(state)")
    return state["stageCount"] != nil
}

// --- Test 2: Event tap ---
header("2. Event Tap Status")

test("Event tap was created successfully") {
    let state = readState()
    let started = state["eventTapStarted"] == "true"
    if !started {
        info("  eventTapStarted = \(state["eventTapStarted"] ?? "nil")")
        info("  CGEvent.tapCreate() returned nil — Accessibility permission not granted")
        info("")
        info("  TO FIX: Open System Settings > Privacy & Security > Accessibility")
        info("  Then enable 'Debut' in the list.")
        info("  If Debut is not listed, drag /Applications/Debut.app into the list.")
        info("  Then: pkill Debut && open /Applications/Debut.app")
    }
    return started
}

test("Event tap is currently running") {
    let state = readState()
    let active = state["eventTapRunning"] == "true"
    if !active {
        info("  eventTapRunning = \(state["eventTapRunning"] ?? "nil")")
        let events = readEvents()
        let tapEvents = events.filter { ($0["event"] ?? "").contains("event_tap") }
        if !tapEvents.isEmpty {
            info("  Event tap log: \(tapEvents)")
        }
    }
    return active
}

// --- Test 3: Accessibility permission (for this process) ---
header("3. Accessibility (E2E test process)")

test("This process can post CGEvents") {
    let canPost = AXIsProcessTrusted()
    if !canPost {
        info("  This terminal/process is NOT trusted for Accessibility")
        info("  CGEvent.post() will silently fail — keyboard simulation won't work")
        info("  Grant Accessibility to your terminal app too")
    }
    return canPost
}

// --- Test 4: Synthetic keyboard events ---
let eventTapOK = readState()["eventTapRunning"] == "true"
let canPost = AXIsProcessTrusted()

if eventTapOK && canPost {
    header("4. Synthetic Cmd+Tab via CGEvent")

    // Clear the diagnostic file's event log by noting the current count
    let eventsBefore = readEvents().count

    info("Posting Cmd keyDown (flagsChanged)...")
    postFlagsChanged(flags: [.maskCommand])
    Thread.sleep(forTimeInterval: 0.1)

    info("Posting Tab keyDown with Cmd flag...")
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    Thread.sleep(forTimeInterval: 0.5)

    test("App received key event and opened overlay") {
        let state = readState()
        let visible = state["overlayVisible"] == "true"
        if !visible {
            let events = readEvents()
            let newEvents = Array(events.dropFirst(eventsBefore))
            info("  overlayVisible = \(state["overlayVisible"] ?? "nil")")
            info("  New events since test start: \(newEvents.map { $0["event"] ?? "?" })")
        }
        return visible
    }

    // Tab to cycle apps
    info("Posting Tab (next app)...")
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    Thread.sleep(forTimeInterval: 0.3)

    // Escape to discard
    info("Posting Escape...")
    postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
    Thread.sleep(forTimeInterval: 0.3)

    // Release Cmd
    info("Releasing Cmd...")
    postFlagsChanged(flags: [])
    Thread.sleep(forTimeInterval: 0.5)

    test("Overlay closed after Escape + Cmd release") {
        let state = readState()
        return state["overlayVisible"] == "false"
    }
} else {
    header("4. Synthetic Cmd+Tab (SKIPPED)")
    if !eventTapOK {
        info("Skipped: Event tap not running (Accessibility not granted to Debut)")
    }
    if !canPost {
        info("Skipped: This process can't post CGEvents (Accessibility not granted to terminal)")
    }
}

// --- Summary ---
header("Results")
print("")
print("  \(passCount)/\(totalCount) passed, \(failCount) failed")

if failCount > 0 {
    print("")
    info("Next steps:")
    if !eventTapOK {
        info("  1. Grant Accessibility to Debut.app:")
        info("     System Settings > Privacy & Security > Accessibility > enable Debut")
        info("  2. Restart Debut: pkill Debut && open /Applications/Debut.app")
    }
    if !canPost {
        info("  3. Grant Accessibility to your terminal (for CGEvent.post to work):")
        info("     System Settings > Privacy & Security > Accessibility > enable your terminal app")
    }
    info("  4. Re-run: TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault swift run DebutE2E")
}
print("")

exit(Int32(failCount > 0 ? 1 : 0))
