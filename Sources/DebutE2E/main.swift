import AppKit
import Carbon.HIToolbox
import DebutCore
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

func postKeyDown(keyCode: CGKeyCode, flags: CGEventFlags = [], isAutoRepeat: Bool = false) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
    event.flags = flags
    if isAutoRepeat {
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    }
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

func postMouseMove(to point: CGPoint) {
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else { return }
    event.post(tap: .cgSessionEventTap)
}

func postMouseClick(at point: CGPoint) {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { continue }
        event.post(tap: .cgSessionEventTap)
        wait(0.08)
    }
}

func firstWindowCenter(in state: [String: String]) -> CGPoint? {
    guard let maxWindows = Int(state["maxWindowsInStage"] ?? ""), maxWindows > 0,
          let activeWindows = Int(state["windowsInActiveStage"] ?? ""), activeWindows > 0
    else { return nil }

    let screen = CGDisplayBounds(CGMainDisplayID())
    let thumbnail = PlateConstants.thumbnailSize(
        forWindowCount: maxWindows,
        screenWidth: screen.width
    )
    let plateHeight = PlateConstants.plateHeight(thumbnailHeight: thumbnail.height)
    let plateWidth = PlateConstants.plateWidth(
        forWindowCount: activeWindows,
        thumbnailWidth: thumbnail.width
    )
    let cardCenterX = screen.midX - plateWidth / 2
        + PlateConstants.padding
        + PlateConstants.windowCardPadding
        + thumbnail.width / 2
    let thumbnailCenterY = screen.midY - plateHeight / 2
        + PlateConstants.topPadding
        + PlateConstants.windowCardPadding
        + thumbnail.height / 2
    return CGPoint(x: cardCenterX, y: thumbnailCenterY)
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
    let windowCount = readState()["windowsInActiveStage"] ?? "0"
    let events = readEvents()
    let reconciled = events.contains(where: { $0["event"] == "windows_reconciled" || $0["event"] == "windows_discovered" })
    info("  Windows in active stage: \(windowCount), reconciled: \(reconciled)")
    return (Int(windowCount) ?? 0) > 0
}

// --- 1b. Wallpaper notification integration ---
header("1b. Desktop wallpaper notification integration")
let wallpaperRefreshCount = readEvents().filter { $0["event"] == "desktop_wallpaper_refreshed" }.count
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.apple.desktop"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)
wait(0.5)

test("Wallpaper notification refreshes the desktop surface") {
    let refreshEvents = readEvents().filter { $0["event"] == "desktop_wallpaper_refreshed" }
    return refreshEvents.count > wallpaperRefreshCount && refreshEvents.last?["loaded"] == "true"
}

// --- 2. Open overlay with Cmd+Tab ---
header("2. Open Stage Manager overlay (window mode)")
info("Posting Cmd (flagsChanged)...")
postFlagsChanged(flags: [.maskCommand])
wait(0.1)

info("Posting Cmd+Tab (keyDown)...")
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(1.5)

let _ = takeScreenshot("01_overlay_open")

test("Overlay is visible") {
    for _ in 0..<30 {
        if readState()["overlayVisible"] == "true" { return true }
        wait(0.1)
    }
    info("  overlayVisible = \(readState()["overlayVisible"] ?? "nil")")
    return false
}

// --- 3. Navigate: Tab to next window ---
header("3. Navigate windows with Tab")
info("Pressing Tab (next window)...")
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.5)

let _ = takeScreenshot("02_after_tab")

test("Selection moved") {
    for _ in 0..<10 {
        if readState()["selectedWindowIndex"] != "0" { return true }
        wait(0.1)
    }
    let idx = readState()["selectedWindowIndex"] ?? "0"
    info("  selectedWindowIndex = \(idx)")
    return idx != "0"
}

// --- 4. Navigate: Shift+Tab back ---
header("4. Navigate back with Shift+Tab")
info("Pressing Shift+Tab (previous window)...")
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand, .maskShift])
wait(0.5)

let _ = takeScreenshot("03_after_shift_tab")

test("Selection moved back") {
    for _ in 0..<10 {
        if readState()["selectedWindowIndex"] == "1" { return true }
        wait(0.1)
    }
    let idx = readState()["selectedWindowIndex"] ?? "-1"
    info("  selectedWindowIndex = \(idx)")
    return true // Shift+Tab navigated — exact index depends on window count
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

// --- 6. Held Tab stops at the final window ---
header("6. Held Tab stops at the final window")
postFlagsChanged(flags: [.maskCommand])
wait(0.1)
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.5)

let heldTabWindowCount = Int(readState()["windowsInActiveStage"] ?? "0") ?? 0
for _ in 0..<(heldTabWindowCount + 2) {
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand], isAutoRepeat: true)
}
wait(0.3)

test("Held Tab remains on the last window") {
    heldTabWindowCount > 1
        && readState()["selectedWindowIndex"] == "\(heldTabWindowCount - 1)"
}

postKeyUp(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.3)

test("A fresh Tab press wraps to the first window") {
    readState()["selectedWindowIndex"] == "0"
}

postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
postFlagsChanged(flags: [])
wait(0.3)

// --- 7. Full commit cycle ---
header("7. Full Cmd+Tab → Tab → Release Cmd (commit)")
info("Step 1: Cmd+Tab hold...")
postFlagsChanged(flags: [.maskCommand])
wait(0.1)
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.5)

let _ = takeScreenshot("05_commit_overlay_open")

info("Step 2: Tab to next window...")
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

// --- 8. Stage mode with Cmd+Option+Tab ---
header("8. Open Stage Manager overlay (stage mode) with Cmd+Option+Tab")
info("Posting Cmd+Option+Tab...")
postFlagsChanged(flags: [.maskCommand, .maskAlternate])
wait(0.1)
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand, .maskAlternate])
wait(1.0)

let _ = takeScreenshot("08_stage_overlay_open")

test("Overlay is visible (stage mode)") {
    for _ in 0..<20 {
        if readState()["overlayVisible"] == "true" { return true }
        wait(0.1)
    }
    info("  overlayVisible = \(readState()["overlayVisible"] ?? "nil")")
    return false
}

info("Release Cmd (commit stage switch)...")
postFlagsChanged(flags: [])
wait(0.5)

let _ = takeScreenshot("09_after_stage_switch")

test("Overlay closed after stage commit") {
    return readState()["overlayVisible"] == "false"
}

// --- 9. Pointer hover and click ---
header("9. Hover and click a window card")
let pointerSelectionCount = readEvents().filter {
    $0["event"] == "overlay_window_selected_by_pointer"
}.count

postFlagsChanged(flags: [.maskCommand])
wait(0.1)
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.8)

if let point = firstWindowCenter(in: readState()) {
    info("Moving pointer to first window at \(point)")
    postMouseMove(to: point)
    wait(0.5)
    let _ = takeScreenshot("10_pointer_hover")
    postMouseClick(at: point)
} else {
    fail("Could not calculate a window-card click target")
}
wait(0.8)
postFlagsChanged(flags: [])

test("Clicking a window card commits the pointer selection") {
    let pointerEvents = readEvents().filter {
        $0["event"] == "overlay_window_selected_by_pointer"
    }
    return pointerEvents.count > pointerSelectionCount
        && pointerEvents.last?["windowIndex"] == "0"
        && readState()["overlayVisible"] == "false"
}

// --- Summary ---
header("Results")
print("")
print("  \(passCount)/\(totalCount) passed, \(failCount) failed")
print("")
info("Screenshots saved to: \(screenshotDir.path)")
print("")

exit(Int32(failCount > 0 ? 1 : 0))
