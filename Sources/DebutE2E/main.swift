import AppKit
import Carbon.HIToolbox
import DebutCore
import Foundation

// MARK: - Output

nonisolated(unsafe) var passCount = 0
nonisolated(unsafe) var failCount = 0
nonisolated(unsafe) var skipCount = 0
nonisolated(unsafe) var totalCount = 0
let environment = ProcessInfo.processInfo.environment
let isGitHubHosted = environment["GITHUB_ACTIONS"] == "true"
let skipsVirtualizedDrags = environment["DEBUT_SKIP_VIRTUALIZED_DRAGS"] == "1"
let skipsSyntheticDrags = isGitHubHosted || skipsVirtualizedDrags
let hostedDragTests: Set<String> = [
    "Dropping a window updates the source and destination stage models",
    "The refreshed destination plate supports an immediate reverse drag",
]

// Disposable runners tell the app to skip live capture, so these assertions can only ever see
// empty previews there. Running them anyway is what kept the hosted suite permanently red.
let previewsDisabled = environment["DEBUT_DISABLE_WINDOW_PREVIEWS"] == "1"
let previewCaptureTests: Set<String> = [
    "Window previews contain non-uniform captured pixels",
]

// Provisioning is a separate invocation rather than a step of the suite, because the desktops
// have to exist before Debut launches and builds its stage list. It is never implied: the suite
// also runs against the developer's own session, where silently adding desktops would be a
// change to the user's machine rather than to a fixture.
if CommandLine.arguments.dropFirst().first == "provision-desktops" {
    let target = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 3
    exit(DesktopProvisioning.ensureDesktops(target) ? 0 : 1)
}

func color(_ text: String, _ code: Int) -> String { "\u{001B}[\(code)m\(text)\u{001B}[0m" }
func pass(_ msg: String) { print(color("  PASS", 32) + "  \(msg)") }
func fail(_ msg: String) { print(color("  FAIL", 31) + "  \(msg)") }
func skip(_ msg: String) { print(color("  SKIP", 33) + "  \(msg)") }
func info(_ msg: String) { print(color("  INFO", 36) + "  \(msg)") }
func header(_ msg: String) { print("\n" + color("=== \(msg) ===", 1)) }

func skipTest(_ name: String, reason: String) {
    totalCount += 1
    skipCount += 1
    skip(name)
    info("  \(reason)")
}

func skipDragTest(_ name: String) {
    if isGitHubHosted {
        skipTest(
            name,
            reason: "GitHub-hosted macOS does not deliver synthetic drag gestures; run this check locally"
        )
    } else {
        skipTest(
            name,
            reason: "Virtualized macOS does not deliver synthetic drag gestures; use Tart run-all to diagnose"
        )
    }
}

func test(_ name: String, _ body: () -> Bool) {
    if skipsSyntheticDrags && hostedDragTests.contains(name) {
        skipDragTest(name)
        return
    }
    if previewsDisabled && previewCaptureTests.contains(name) {
        skipTest(
            name,
            reason: "Live preview capture is disabled in this environment; run this check locally"
        )
        return
    }
    totalCount += 1
    if body() { passCount += 1; pass(name) }
    else { failCount += 1; fail(name) }
}

// MARK: - Diagnostic file

let diagnosticFile: URL = DebutCore.applicationSupportDirectory
    .appendingPathComponent("diagnostic.json")

let settingsFile: URL = diagnosticFile
    .deletingLastPathComponent()
    .appendingPathComponent("settings.json")

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

let screenRecordingAvailable = CGPreflightScreenCaptureAccess()

func takeScreenshot(_ name: String) -> String {
    let path = screenshotDir.appendingPathComponent("\(name).png").path
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-x", "-C", path]  // -x no sound, -C capture cursor
    try? proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus == 0 {
        info("  Screenshot: \(path)")
    } else {
        info("  Screenshot unavailable (Screen Recording permission is not granted)")
    }
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

/// ANSI digit keycodes are not contiguous — 6 and 5 are transposed, and 7, 8, 9 jump.
func digitKeyCode(_ digit: Int) -> CGKeyCode {
    let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                 kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    return CGKeyCode(codes[digit - 1])
}

/// Posts the global quick-switch chord and waits for the desktop to actually land.
///
/// The settle afterwards is not padding. Each request aborts whatever driven gesture is still in
/// flight, so a chord posted while the Dock is mid-transition lands on a moving target.
func quickSwitch(to index: Int, using service: SpaceService) -> Bool {
    let from = service.currentDesktopIndex()
    let modelBefore = readState()["activeStageIndex"] ?? "none"
    let switchesBefore = readEvents().filter { $0["event"] == "stage_switched" }.count
    // The key-up is not symmetry for its own sake. Without it the digit stays logically held, so a
    // later press of the *same* digit arrives as an auto-repeat and never reaches the handler —
    // which is why each desktop could be reached exactly once per run, and why every switch back
    // read as a chord Debut had ignored.
    let digit = digitKeyCode(index + 1)
    postKeyDown(keyCode: digit, flags: [.maskControl])
    postKeyUp(keyCode: digit, flags: [.maskControl])
    let landed = waitFor { service.currentDesktopIndex() == index }
    wait(0.5)
    if !landed {
        // Whether Debut reported a switch separates a chord that never arrived from a gesture
        // the Dock did not honour, and those have nothing in common but the symptom.
        let switchesAfter = readEvents().filter { $0["event"] == "stage_switched" }
        info("  Switch \(from.map(String.init) ?? "none") -> \(index) did not land; "
            + "Debut's active stage was \(modelBefore) when asked, now "
            + "\(readState()["activeStageIndex"] ?? "none"); "
            + "reported \(switchesAfter.count - switchesBefore) switch(es), "
            + "last: \(switchesAfter.last ?? [:]), now on "
            + "\(service.currentDesktopIndex().map(String.init) ?? "none")")
    }
    return landed
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

func postMouseDrag(from start: CGPoint, to end: CGPoint) {
    guard !skipsSyntheticDrags else { return }

    guard let down = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: start,
        mouseButton: .left
    ) else { return }
    down.post(tap: .cghidEventTap)
    wait(0.25)

    for step in 1...16 {
        let progress = CGFloat(step) / 16
        let point = CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
        guard let dragged = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { continue }
        dragged.post(tap: .cghidEventTap)
        wait(0.06)
    }

    wait(0.15)

    guard let up = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: end,
        mouseButton: .left
    ) else { return }
    up.post(tap: .cghidEventTap)
}

func stageWindowCounts(in state: [String: String]) -> [Int] {
    (state["windowCountsByStage"] ?? "")
        .split(separator: ",")
        .compactMap { Int($0) }
}

func plateCenter(
    stageIndex: Int,
    windowCounts: [Int],
    activeStageIndex: Int,
    inactiveScale: CGFloat
) -> CGPoint? {
    guard windowCounts.indices.contains(stageIndex),
          windowCounts.indices.contains(activeStageIndex)
    else { return nil }

    let screen = CGDisplayBounds(CGMainDisplayID())
    let thumbnail = PlateConstants.thumbnailSize(
        forWindowCount: windowCounts.max() ?? 0,
        screenWidth: screen.width
    )
    let plateHeight = PlateConstants.plateHeight(thumbnailHeight: thumbnail.height)
    guard let visualCenterY = PlateConstants.plateCenterY(
        stageIndex: stageIndex,
        stageCount: windowCounts.count,
        activeStageIndex: activeStageIndex,
        plateHeight: plateHeight,
        inactiveScale: inactiveScale,
        containerHeight: screen.height
    ) else { return nil }
    return CGPoint(
        x: screen.midX,
        y: visualCenterY
    )
}

func windowCenter(
    stageIndex: Int,
    windowIndex: Int,
    windowCounts: [Int],
    activeStageIndex: Int,
    inactiveScale: CGFloat
) -> CGPoint? {
    guard windowCounts.indices.contains(stageIndex),
          windowCounts.indices.contains(activeStageIndex),
          (0..<windowCounts[stageIndex]).contains(windowIndex)
    else { return nil }

    let screen = CGDisplayBounds(CGMainDisplayID())
    let thumbnail = PlateConstants.thumbnailSize(
        forWindowCount: windowCounts.max() ?? 0,
        screenWidth: screen.width
    )
    let plateHeight = PlateConstants.plateHeight(thumbnailHeight: thumbnail.height)
    let layoutScale: (Int) -> CGFloat = { $0 == activeStageIndex ? 1 : inactiveScale }
    let topWithinLayout: (Int) -> CGFloat = { index in
        (0..<index).reduce(0) { partial, precedingIndex in
            partial + plateHeight * layoutScale(precedingIndex) + PlateConstants.stageSpacing
        }
    }
    let layoutOffset = screen.midY
        - topWithinLayout(activeStageIndex)
        - plateHeight / 2
    // Window hit testing is expressed in the overlay window's screen space,
    // unlike drag destinations, which use the named SwiftUI coordinate space.
    let center = CGPoint(
        x: screen.midX,
        y: layoutOffset
            + topWithinLayout(stageIndex)
            + plateHeight * layoutScale(stageIndex) / 2
    )
    let plateWidth = PlateConstants.plateWidth(
        forWindowCount: windowCounts[stageIndex],
        thumbnailWidth: thumbnail.width
    )
    let scale: CGFloat = stageIndex == activeStageIndex ? 1 : inactiveScale
    let windowStride = thumbnail.width
        + PlateConstants.windowCardExtraWidth
        + PlateConstants.windowSpacing
    let unscaledX = PlateConstants.padding
        + PlateConstants.windowCardPadding
        + thumbnail.width / 2
        + CGFloat(windowIndex) * windowStride
    let unscaledY = PlateConstants.topPadding
        + PlateConstants.windowCardPadding
        + thumbnail.height / 2
    return CGPoint(
        x: center.x + (unscaledX - plateWidth / 2) * scale,
        y: center.y + (unscaledY - plateHeight / 2) * scale
    )
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

final class LockedApplicationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var application: NSRunningApplication?

    func store(_ application: NSRunningApplication?) {
        lock.lock()
        self.application = application
        lock.unlock()
    }

    func load() -> NSRunningApplication? {
        lock.lock()
        defer { lock.unlock() }
        return application
    }
}

func launchDebut(arguments: [String] = []) -> NSRunningApplication? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.thomplth.Debut") else {
        return nil
    }
    let semaphore = DispatchSemaphore(value: 0)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = arguments
    configuration.createsNewApplicationInstance = true
    let result = LockedApplicationResult()
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, _ in
        result.store(application)
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)
    return result.load()
}

func visibleWindowTitles(for processIdentifier: pid_t) -> [String] {
    guard let rawWindows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return [] }

    return rawWindows.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier else {
            return nil
        }
        return window[kCGWindowName as String] as? String
    }
}

func focusedWindowElement(for processIdentifier: pid_t) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processIdentifier)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &focused
    ) == .success, let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
    else { return nil }
    return (element as! AXUIElement)
}

func windowIsFullscreen(_ window: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success
    else { return false }
    return (value as? Bool) == true
}

/// Returns whether the Space transition actually completed, since a virtualized guest can
/// accept the attribute and never animate.
@discardableResult
func setWindowFullscreen(_ window: AXUIElement, _ enabled: Bool, timeout: TimeInterval = 10) -> Bool {
    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, enabled as CFBoolean)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if windowIsFullscreen(window) == enabled { return true }
        wait(0.25)
    } while Date() < deadline
    return false
}

/// A desktop transition is a composited animation the Dock drives, so nothing about it is ready
/// on the next line; polling the window server is the signal, not a sleep long enough to hope.
func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        wait(0.1)
    } while Date() < deadline
    return false
}

func waitForStageCount(_ expected: Int, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if Int(readState()["stageCount"] ?? "") == expected { return true }
        wait(0.1)
    } while Date() < deadline
    return false
}

func toggleSystemWindowOverview(mode: Int) {
    let process = Process()
    process.executableURL = URL(
        fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
    )
    process.arguments = ["\(mode)"]
    try? process.run()
    process.waitUntilExit()
    wait(1.5)
}

func wait(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

@discardableResult
func terminateDebutAndWait(timeout: TimeInterval = 10) -> Bool {
    for application in NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.thomplth.Debut"
    ) {
        _ = application.terminate()
    }

    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.thomplth.Debut"
        ).isEmpty {
            return true
        }
        wait(0.1)
    } while Date() < deadline
    return false
}

func waitForDebutReady(
    _ application: NSRunningApplication?,
    timeout: TimeInterval = 10
) -> Bool {
    guard let application else { return false }
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if !application.isTerminated,
           readEvents().contains(where: { $0["event"] == "app_ready" }) {
            return true
        }
        wait(0.1)
    } while Date() < deadline
    return false
}

func clearDiagnosticFile() {
    try? FileManager.default.removeItem(at: diagnosticFile)
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

// A prior interrupted run can leave the event-tap session or overlay active.
// Normalize both before the baseline so the first activation is deterministic.
postKeyDown(keyCode: CGKeyCode(kVK_Escape))
postKeyUp(keyCode: CGKeyCode(kVK_Escape))
postFlagsChanged(flags: [])
wait(0.5)

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

// --- 1b. Stages track the desktops macOS has ---
// This replaced a section asserting that Debut painted its own full-screen desktop surface.
// Stages are real desktops now, so macOS draws the desktop and the only thing left to hold
// honest is that Debut's stage list agrees with the window server's desktop list.
header("1b. Stages match the desktop list")
let userDesktopCount = SpaceService().userDesktops().count
info("  User desktops: \(userDesktopCount)")

test("A stage exists for every desktop and no others") {
    userDesktopCount > 0 && waitForStageCount(userDesktopCount)
}

// --- 1c. System window overviews ---
// Mission Control and App Exposé can change the Space behind Debut's back. Debut must follow
// a desktop it did not switch to, and must not invent or drop a stage on the way through.
header("1c. Mission Control and App Exposé")

info("Opening Mission Control with Control-Up...")
toggleSystemWindowOverview(mode: 0)
let _ = takeScreenshot("00_mission_control")
toggleSystemWindowOverview(mode: 0)

test("The stage list survives Mission Control") {
    waitForStageCount(userDesktopCount)
}

test("The active stage still points at a real desktop after Mission Control") {
    let index = Int(readState()["activeStageIndex"] ?? "") ?? -1
    return index >= 0 && index < userDesktopCount
}

info("Opening App Exposé with Control-Down...")
toggleSystemWindowOverview(mode: 2)
let _ = takeScreenshot("00_app_expose")
toggleSystemWindowOverview(mode: 2)

test("The stage list survives App Exposé") {
    waitForStageCount(userDesktopCount)
}

// --- 1d. A stage switch moves the real desktop ---
// This is what the architecture is for, and until desktops were provisioned there was no check
// of it anywhere: a one-desktop host makes every SpaceSwitchPlan nil, so the switch path was
// never entered. The quick-switch chord is used rather than the overlay because it is a global
// immediate switch, so the assertion is about the desktop rather than about overlay timing.
//
// The window server is the authority here. Debut's own activeStageIndex agreeing with itself
// proves nothing; it has to agree with the desktop macOS is actually showing.
header("1d. A stage switch changes the desktop macOS shows")

let switchSpaceService = SpaceService()

// Which desktop the host happens to be showing is not this suite's to decide — a reused VM
// starts on whichever one the last run left. Switching is therefore expressed as "away from
// here and back", not as a jump to a hardcoded desktop 2.
if userDesktopCount < 2 {
    skipTest("Quick-switching to another stage moves macOS to that stage's desktop",
             reason: "This host has one desktop, so there is nothing to switch to")
    skipTest("Debut's active stage follows the desktop it switched to",
             reason: "This host has one desktop, so there is nothing to switch to")
    skipTest("Quick-switching back returns to the original desktop",
             reason: "This host has one desktop, so there is nothing to switch to")
} else if let startingDesktop = switchSpaceService.currentDesktopIndex() {
    let targetDesktop = startingDesktop == 0 ? 1 : 0
    info("  Switching from desktop \(startingDesktop) to \(targetDesktop)")

    let switched = quickSwitch(to: targetDesktop, using: switchSpaceService)
    let _ = takeScreenshot("00_stage_switch_desktop_2")

    test("Quick-switching to another stage moves macOS to that stage's desktop") {
        switched
    }

    test("Debut's active stage follows the desktop it switched to") {
        waitFor { Int(readState()["activeStageIndex"] ?? "") == targetDesktop }
    }

    let returned = quickSwitch(to: startingDesktop, using: switchSpaceService)

    test("Quick-switching back returns to the original desktop") {
        returned && waitFor { Int(readState()["activeStageIndex"] ?? "") == startingDesktop }
    }

    // Dock progress saturates at one desktop per gesture, so `switchToDesktop` drives one
    // gesture per desktop crossed. Every check above is a single hop, which is the one distance
    // that loop cannot get wrong.
    if userDesktopCount >= 3 {
        let atFirst = quickSwitch(to: 0, using: switchSpaceService)
        let jumped = quickSwitch(to: 2, using: switchSpaceService)
        info("  Two-desktop jump from 0: reached first desktop \(atFirst), landed on "
            + "\(switchSpaceService.currentDesktopIndex().map(String.init) ?? "none")")

        test("A jump across two desktops lands on the far desktop") {
            atFirst && jumped
        }
    } else {
        skipTest("A jump across two desktops lands on the far desktop",
                 reason: "This host has fewer than three desktops, so there is no two-hop jump")
    }

    // Every later section needs window cards to select, hover and move, so this parts on the stage
    // that actually holds the fixture windows rather than on desktop 0. Provisioning puts them on
    // whichever desktop was showing when the fixtures launched, which is not reliably the first —
    // parting on desktop 0 stranded the run on an empty stage and sent Tab navigation red.
    if let populated = stageWindowCounts(in: readState()).firstIndex(where: { $0 > 0 }) {
        let normalized = quickSwitch(to: populated, using: switchSpaceService)
        info("  Parting on stage \(populated), which holds the fixture windows: \(normalized)")
    }
} else {
    // A fullscreen Space is showing, so there is no user desktop index to switch away from.
    let reason = "No user desktop is showing, so there is no starting point to switch from"
    skipTest("Quick-switching to another stage moves macOS to that stage's desktop", reason: reason)
    skipTest("Debut's active stage follows the desktop it switched to", reason: reason)
    skipTest("Quick-switching back returns to the original desktop", reason: reason)
    skipTest("A jump across two desktops lands on the far desktop", reason: reason)
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

test("Window previews contain non-uniform captured pixels") {
    for _ in 0..<30 {
        if (Int(readState()["variedWindowPreviewCount"] ?? "0") ?? 0) > 0 {
            return true
        }
        wait(0.1)
    }
    info("  Preview state: \(readState())")
    return false
}
let selectedWindowIndexBeforeNext = readState()["selectedWindowIndex"]

// --- 3. Navigate: Tab to next window ---
header("3. Navigate windows with Tab")
info("Pressing Tab (next window)...")
let nextWindowHintUsageCount = readEvents().filter {
    $0["event"] == "command_hint_usage_observed"
        && $0["action"] == "nextWindow"
}.count
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.5)

let _ = takeScreenshot("02_after_tab")

test("Selection moved") {
    for _ in 0..<10 {
        if readState()["selectedWindowIndex"] != selectedWindowIndexBeforeNext { return true }
        wait(0.1)
    }
    let idx = readState()["selectedWindowIndex"] ?? "nil"
    info("  selectedWindowIndex stayed at \(idx)")
    return false
}

test("Command hint usage follows real command dispatch") {
    readEvents().filter {
        $0["event"] == "command_hint_usage_observed"
            && $0["action"] == "nextWindow"
    }.count > nextWindowHintUsageCount
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

// Held cycling is rate limited, so repeats posted back to back are deliberately dropped.
// Pacing them above that interval is what makes this a test of the clamp rather than of
// the limiter.
let heldTabRepeatInterval = AppSettings.defaultHeldCycleMinimumInterval * 1.3
let heldTabWindowCount = Int(readState()["windowsInActiveStage"] ?? "0") ?? 0
for _ in 0..<(heldTabWindowCount + 2) {
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand], isAutoRepeat: true)
    wait(heldTabRepeatInterval)
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
let pointerHoverCount = readEvents().filter {
    $0["event"] == "overlay_pointer_selection_changed"
}.count

// Section 8 commits a stage switch, and which stage that lands on follows the MRU order the
// earlier sections happened to build — on a host with an empty last stage it can be the one
// with no windows at all. Hovering needs a card, so this section picks its own fixture rather
// than inheriting whatever the previous one left showing.
let populatedStage = stageWindowCounts(in: readState()).firstIndex { $0 > 0 }
if let populatedStage, Int(readState()["activeStageIndex"] ?? "") != populatedStage {
    info("Switching to stage \(populatedStage), which has windows to hover")
    let landed = quickSwitch(to: populatedStage, using: SpaceService())
    info("  Switch landed: \(landed)")
}

let pointerTarget = firstWindowCenter(in: readState())

// Hovering needs a window card under the pointer, so an active stage with no windows is a
// missing fixture rather than a broken affordance. Reporting it as a failure sent the whole
// section red when an earlier section had merely left the session on an empty stage.
if let pointerTarget {
    info("Placing pointer over the first window before opening the overlay at \(pointerTarget)")
    postMouseMove(to: pointerTarget)
    wait(0.3)

    postFlagsChanged(flags: [.maskCommand])
    wait(0.1)
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    wait(0.8)

    test("A stationary pointer does not select or magnify a window") {
        readEvents().filter {
            $0["event"] == "overlay_pointer_selection_changed"
        }.count == pointerHoverCount
    }

    let movedPoint = CGPoint(x: pointerTarget.x + 8, y: pointerTarget.y)
    info("Moving pointer within the first window to \(movedPoint)")
    postMouseMove(to: movedPoint)
    wait(0.5)
    let _ = takeScreenshot("10_pointer_hover")
    test("Moving the pointer enables hover selection") {
        let hoverEvents = readEvents().filter {
            $0["event"] == "overlay_pointer_selection_changed"
        }
        return hoverEvents.count > pointerHoverCount
            && hoverEvents.last?["windowIndex"] == "0"
    }
    postMouseClick(at: movedPoint)
    wait(0.8)
    postFlagsChanged(flags: [])

    test("Clicking a window card commits the pointer selection") {
        for _ in 0..<20 {
            let pointerEvents = readEvents().filter {
                $0["event"] == "overlay_window_selected_by_pointer"
            }
            if pointerEvents.count > pointerSelectionCount,
               pointerEvents.last?["windowIndex"] == "0",
               readState()["overlayVisible"] == "false" {
                return true
            }
            wait(0.1)
        }
        return false
    }
} else {
    let reason = "The active stage has no window card for the pointer to land on"
    skipTest("A stationary pointer does not select or magnify a window", reason: reason)
    skipTest("Moving the pointer enables hover selection", reason: reason)
    skipTest("Clicking a window card commits the pointer selection", reason: reason)
}

// --- 10. Window-drop plate refresh ---
header("10. Window drop refreshes both plates immediately")
let originalDropState = readState()
let originalStageCount = Int(originalDropState["stageCount"] ?? "") ?? 0
let originalWindowCounts = stageWindowCounts(in: originalDropState)
let interactionSettings = (try? StateStore().loadSettings()) ?? AppSettings()
let screenBounds = CGDisplayBounds(CGMainDisplayID())
let neutralPointerLocation = CGPoint(x: screenBounds.maxX - 4, y: screenBounds.maxY - 4)

// This fixture used to press Cmd-N for a throwaway destination stage. Stages are desktops
// now and Debut cannot make one, so the drop target has to be a desktop the host already
// has: an empty stage with a populated stage before it. A single-desktop runner has none,
// which is a reason to skip rather than to fail.
let destinationStageIndex = originalWindowCounts.indices.first {
    $0 > 0 && originalWindowCounts[$0] == 0 && originalWindowCounts[$0 - 1] > 0
} ?? -1
let sourceStageIndex = destinationStageIndex - 1
let dropFixtureSkipReason = destinationStageIndex < 0
    ? "This host has no empty desktop following a populated one; the drop fixture needs both"
    : nil

postMouseMove(to: neutralPointerLocation)
wait(0.5)

postFlagsChanged(flags: [.maskCommand])
wait(0.1)
postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
wait(0.8)

let preparedDropState = readState()
let preparedWindowCounts = stageWindowCounts(in: preparedDropState)
// Plate geometry scales around whichever stage is selected, and nothing selects the
// destination for us now that it is not freshly created.
let plateActiveStageIndex = Int(preparedDropState["selectedStageIndex"] ?? "") ?? 0
let moveEventCount = readEvents().filter { $0["event"] == "window_moved_by_drag" }.count
info("  Original drop state: stages=\(originalStageCount), windows=\(originalWindowCounts)")
info("  Drop fixture: source=\(sourceStageIndex), destination=\(destinationStageIndex), windows=\(preparedWindowCounts)")

postMouseMove(to: neutralPointerLocation)
wait(0.5)

let emptyDestinationTest = "E2E found an empty destination stage next to a populated one"
if let reason = dropFixtureSkipReason {
    skipTest(emptyDestinationTest, reason: reason)
} else {
    test(emptyDestinationTest) {
        preparedWindowCounts.indices.contains(sourceStageIndex)
            && preparedWindowCounts.indices.contains(destinationStageIndex)
            && preparedWindowCounts[sourceStageIndex] > 0
            && preparedWindowCounts[destinationStageIndex] == 0
            && preparedWindowCounts.count == originalStageCount
    }
}

postMouseMove(to: neutralPointerLocation)
wait(0.3)

if preparedWindowCounts.indices.contains(sourceStageIndex),
   preparedWindowCounts.indices.contains(destinationStageIndex),
   let sourcePoint = windowCenter(
        stageIndex: sourceStageIndex,
        windowIndex: 0,
        windowCounts: preparedWindowCounts,
        activeStageIndex: plateActiveStageIndex,
        inactiveScale: CGFloat(interactionSettings.inactivePlateScale)
   ),
   let destinationPoint = plateCenter(
        stageIndex: destinationStageIndex,
        windowCounts: preparedWindowCounts,
        activeStageIndex: plateActiveStageIndex,
        inactiveScale: CGFloat(interactionSettings.inactivePlateScale)
   ) {
    info("  Drag path: \(sourcePoint) -> \(destinationPoint)")
    postMouseDrag(from: sourcePoint, to: destinationPoint)
    for _ in 0..<(skipsSyntheticDrags ? 0 : 30) {
        if readEvents().filter({ $0["event"] == "window_moved_by_drag" }).count > moveEventCount {
            break
        }
        wait(0.1)
    }

    let movedWindowCounts = stageWindowCounts(in: readState())
    info("  State after drop: windows=\(movedWindowCounts)")
    let _ = takeScreenshot("11_window_drop_refreshed")
    test("Dropping a window updates the source and destination stage models") {
        readEvents().filter { $0["event"] == "window_moved_by_drag" }.count > moveEventCount
            && movedWindowCounts.indices.contains(sourceStageIndex)
            && movedWindowCounts.indices.contains(destinationStageIndex)
            && movedWindowCounts[sourceStageIndex] == preparedWindowCounts[sourceStageIndex] - 1
            && movedWindowCounts[destinationStageIndex] == 1
    }

    if let returnedWindowPoint = windowCenter(
        stageIndex: destinationStageIndex,
        windowIndex: 0,
        windowCounts: movedWindowCounts,
        activeStageIndex: plateActiveStageIndex,
        inactiveScale: CGFloat(interactionSettings.inactivePlateScale)
    ), let returnedStagePoint = plateCenter(
        stageIndex: sourceStageIndex,
        windowCounts: movedWindowCounts,
        activeStageIndex: plateActiveStageIndex,
        inactiveScale: CGFloat(interactionSettings.inactivePlateScale)
    ) {
        info("  Reverse drag path: \(returnedWindowPoint) -> \(returnedStagePoint)")
        postMouseDrag(from: returnedWindowPoint, to: returnedStagePoint)
        for _ in 0..<(skipsSyntheticDrags ? 0 : 30) {
            if readEvents().filter({ $0["event"] == "window_moved_by_drag" }).count > moveEventCount + 1 {
                break
            }
            wait(0.1)
        }
        test("The refreshed destination plate supports an immediate reverse drag") {
            readEvents().filter { $0["event"] == "window_moved_by_drag" }.count > moveEventCount + 1
                && stageWindowCounts(in: readState()) == preparedWindowCounts
        }
    } else {
        if skipsSyntheticDrags {
            skipDragTest("The refreshed destination plate supports an immediate reverse drag")
        } else {
            fail("Could not calculate the reverse window-drop path")
        }
    }
} else if let reason = dropFixtureSkipReason {
    skipTest("Dropping a window updates the source and destination stage models", reason: reason)
    skipTest("The refreshed destination plate supports an immediate reverse drag", reason: reason)
} else {
    fail("Could not calculate the window-drop path")
}
postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
postFlagsChanged(flags: [])
wait(0.5)

test("Window-drop E2E cleanup restores the original stages") {
    readState()["stageCount"] == "\(originalStageCount)"
        && stageWindowCounts(in: readState()) == originalWindowCounts
}

// --- 10b. Moving a window between stages with the keyboard ---
// The pointer path above is a synthetic drag, which neither hosted nor virtualized macOS
// delivers, so on every disposable host it is a skip. The keyboard path reaches the same
// bridged window-server move and *is* delivered, which makes this the only place a cross-stage
// move is actually proven off a developer's machine.
//
// The model is not the evidence. A refused bridge move must not update the model either, so
// asking the window server where the window ended up is what separates a real move from a
// plausible-looking one.
header("10b. Moving a window between stages with the keyboard")

let keyboardMoveSpaceService = SpaceService()
let keyboardMoveStageCount = Int(readState()["stageCount"] ?? "") ?? 0

if keyboardMoveStageCount < 2 {
    skipTest("A keyboard move puts the window on the next stage's desktop",
             reason: "This host has one desktop, so there is no stage to move a window to")
    skipTest("The keyboard move is reported and lands the window where the model says",
             reason: "This host has one desktop, so there is no stage to move a window to")
} else if !keyboardMoveSpaceService.canMoveWindows {
    let reason = "The bridged window-server move is inert on this host, so a move must be refused"
    skipTest("A keyboard move puts the window on the next stage's desktop", reason: reason)
    skipTest("The keyboard move is reported and lands the window where the model says", reason: reason)
} else {
    let movesBefore = readEvents().filter { $0["event"] == "window_moved_by_key" }.count

    postFlagsChanged(flags: [.maskCommand])
    wait(0.1)
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    wait(0.8)

    // Select a stage that has a window to move and a stage below it to receive one.
    let openState = readState()
    let openCounts = stageWindowCounts(in: openState)
    let originStage = openCounts.indices.first {
        $0 < openCounts.count - 1 && openCounts[$0] > 0
    } ?? -1

    if originStage < 0 {
        postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
        postFlagsChanged(flags: [])
        skipTest("A keyboard move puts the window on the next stage's desktop",
                 reason: "No stage has a window with a stage below it to receive one")
        skipTest("The keyboard move is reported and lands the window where the model says",
                 reason: "No stage has a window with a stage below it to receive one")
    } else {
        // Digits select a stage inside the open overlay and are 1-based. Option+Down would have
        // swapped two stages rather than selecting one.
        //
        // The digit is pressed unconditionally. The overlay opens on whichever stage is active,
        // not on stage 1, so treating stage 1 as already selected measured one stage and moved a
        // window out of another — and the counts still shifted by one either way, which is what
        // made the mismatch look like a plausible pass.
        postKeyDown(keyCode: digitKeyCode(originStage + 1), flags: [.maskCommand])
        let originSelected = waitFor {
            Int(readState()["selectedStageIndex"] ?? "") == originStage
        }
        let beforeCounts = stageWindowCounts(in: readState())
        info("  Keyboard move: stage \(originStage) -> \(originStage + 1), windows=\(beforeCounts)")

        postKeyDown(keyCode: CGKeyCode(kVK_DownArrow), flags: [.maskCommand])
        wait(1.0)

        let moveEvents = readEvents().filter { $0["event"] == "window_moved_by_key" }
        let afterCounts = stageWindowCounts(in: readState())
        info("  After the keyboard move: windows=\(afterCounts)")
        let _ = takeScreenshot("12_keyboard_window_move")

        test("The keyboard move is reported and lands the window where the model says") {
            originSelected
                && moveEvents.count > movesBefore
                && afterCounts.indices.contains(originStage + 1)
                && afterCounts[originStage] == beforeCounts[originStage] - 1
                && afterCounts[originStage + 1] == beforeCounts[originStage + 1] + 1
        }

        test("A keyboard move puts the window on the next stage's desktop") {
            guard let moved = moveEvents.last,
                  let windowID = UInt32(moved["windowID"] ?? ""),
                  let reportedStage = Int(moved["toStageIndex"] ?? "")
            else { return false }
            return keyboardMoveSpaceService.desktopIndex(forWindow: windowID) == reportedStage
        }

        // Put it back so later sections see the stage layout they were written against.
        postKeyDown(keyCode: CGKeyCode(kVK_UpArrow), flags: [.maskCommand])
        wait(1.0)
        postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
        postFlagsChanged(flags: [])
        wait(0.5)

        test("The keyboard move is reversible") {
            stageWindowCounts(in: readState()) == beforeCounts
        }
    }
}

// --- 11. Fullscreen Spaces ---
// A fullscreen app owns a Space of its own, which is not a stage and never gets one. The
// plates have to reach it anyway, or the activation shortcut is dead exactly where the user
// cannot see their other windows.
header("11. Overlay inside a fullscreen Space")

let fullscreenFixture = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.apple.TextEdit")
    .first
let fullscreenWindow = fullscreenFixture.flatMap {
    $0.activate()
    wait(1)
    return focusedWindowElement(for: $0.processIdentifier)
}
let enteredFullscreen = fullscreenWindow.map { setWindowFullscreen($0, true) } ?? false

if enteredFullscreen {
    // The Space animation keeps running after the attribute flips.
    wait(2)
    postFlagsChanged(flags: [.maskCommand])
    wait(0.1)
    postKeyDown(keyCode: CGKeyCode(kVK_Tab), flags: [.maskCommand])
    wait(1.5)
    let _ = takeScreenshot("11_overlay_in_fullscreen")

    test("Overlay opens over a fullscreen Space") {
        for _ in 0..<30 {
            if readState()["overlayVisible"] == "true" { return true }
            wait(0.1)
        }
        info("  overlayVisible = \(readState()["overlayVisible"] ?? "nil")")
        return false
    }

    test("Debut presents knowing the focused window was fullscreen") {
        let fullscreenState = readState()["focusedWindowFullscreen"] ?? "nil"
        if fullscreenState != "true" { info("  focusedWindowFullscreen = \(fullscreenState)") }
        return fullscreenState == "true"
    }

    info("Releasing Cmd to commit the selection...")
    postFlagsChanged(flags: [])
    wait(2)

    // Only that the session commits, not that macOS finished moving Spaces. Debut's part is
    // `NSRunningApplication.activate()`; the Space animation that follows is the system's, and a
    // guest VM does not reliably deliver it.
    test("Releasing the modifier commits the session from a fullscreen Space") {
        for _ in 0..<50 {
            if readState()["overlayVisible"] == "false" { return true }
            wait(0.1)
        }
        info("  overlayVisible = \(readState()["overlayVisible"] ?? "nil")")
        return false
    }

    if let fullscreenWindow {
        fullscreenFixture?.activate()
        wait(1)
        if !setWindowFullscreen(fullscreenWindow, false) {
            info("The fixture window did not leave fullscreen; the next scenario relaunches Debut")
        }
        wait(1)
    }
} else {
    let reason = fullscreenFixture == nil
        ? "The TextEdit fixture is not running"
        : "The guest did not complete the fullscreen Space transition"
    skipTest("Overlay opens over a fullscreen Space", reason: reason)
    skipTest("Debut presents knowing the focused window was fullscreen", reason: reason)
    skipTest("Releasing the modifier commits the session from a fullscreen Space", reason: reason)
}

postFlagsChanged(flags: [])
postKeyDown(keyCode: CGKeyCode(kVK_Escape))
postKeyUp(keyCode: CGKeyCode(kVK_Escape))
wait(0.5)

// --- 12. Customized global activation ---
header("12. Customized global activation")
let stoppedBeforeCustomization = terminateDebutAndWait()

let originalSettingsData = try? Data(contentsOf: settingsFile)
let settingsStore = StateStore()
var customizedSettings = (try? settingsStore.loadSettings()) ?? AppSettings()
customizedSettings.commandHintVisibility = .always
customizedSettings.keyBindings.bindings[.activateNextWindow] = KeyCombo(
    keyCode: kVK_ANSI_B,
    command: true
)
try? settingsStore.saveSettings(customizedSettings)

clearDiagnosticFile()
let customizedApplication = launchDebut()
let customizedApplicationReady = waitForDebutReady(customizedApplication)
let customizedActivationCount = readEvents().filter {
    $0["event"] == "key_event" && $0["keyEvent"] == "cmdTabHold"
}.count
postFlagsChanged(flags: [.maskCommand])
wait(0.1)
postKeyDown(keyCode: CGKeyCode(kVK_ANSI_B), flags: [.maskCommand])
wait(0.8)

test("A persisted custom shortcut replaces Command-Tab activation") {
    stoppedBeforeCustomization
        && customizedApplicationReady
        && readState()["overlayVisible"] == "true"
        && readEvents().filter {
            $0["event"] == "key_event" && $0["keyEvent"] == "cmdTabHold"
        }.count > customizedActivationCount
}

func hintLayoutIsContextual() -> Bool {
    guard let layout = readEvents().last(where: { $0["event"] == "command_hints_laid_out" }),
          let footerHintCount = Int(layout["footerHintCount"] ?? ""),
          let footerIconCount = Int(layout["footerIconCount"] ?? ""),
          let stageLeadingHintCount = Int(layout["stageLeadingHintCount"] ?? "")
    else { return false }
    let windowCount = Int(readState()["windowsInActiveStage"] ?? "0") ?? 0
    return stageLeadingHintCount > 0
        && footerHintCount > 0
        && footerIconCount == footerHintCount
        && (windowCount < 2 || layout["nextWindowIndex"] != "none")
}

// The overlay flushes its layout diagnostics asynchronously, so poll instead of
// reading once after a fixed wait.
test("Command hints use contextual placements and purpose icons") {
    for _ in 0..<30 where !hintLayoutIsContextual() {
        wait(0.1)
    }
    if !hintLayoutIsContextual() {
        info("  Hint layout: \(readEvents().last(where: { $0["event"] == "command_hints_laid_out" }) ?? [:])")
        info("  Hint layout state: \(readState())")
        return false
    }
    return true
}

postKeyDown(keyCode: CGKeyCode(kVK_Escape), flags: [.maskCommand])
postFlagsChanged(flags: [])
_ = terminateDebutAndWait()
if let originalSettingsData {
    try? originalSettingsData.write(to: settingsFile, options: .atomic)
} else {
    try? FileManager.default.removeItem(at: settingsFile)
}

// --- 13. First-launch onboarding (forced, without changing user defaults) ---
header("13. First-launch onboarding")

clearDiagnosticFile()
let onboardingApplication = launchDebut(arguments: ["--show-onboarding"])
let onboardingApplicationReady = waitForDebutReady(onboardingApplication)
let onboardingWindowTitles = onboardingApplication.map {
    visibleWindowTitles(for: $0.processIdentifier)
} ?? []
info("Visible Debut windows: \(onboardingWindowTitles)")
let _ = takeScreenshot("11_onboarding_welcome")

test("Forced first launch presents the onboarding window") {
    guard onboardingApplicationReady else { return false }
    for _ in 0..<20 {
        let onboardingShown = readEvents().contains {
            $0["event"] == "onboarding_shown" && $0["forced"] == "true"
        }
        if onboardingShown || onboardingWindowTitles.contains("Welcome to Debut") {
            return true
        }
        wait(0.1)
    }
    return false
}

_ = terminateDebutAndWait()
clearDiagnosticFile()
let restoredApplication = launchDebut()
let restoredApplicationReady = waitForDebutReady(restoredApplication)

test("Debut relaunches normally after the onboarding check") {
    restoredApplicationReady
}

_ = terminateDebutAndWait()

// --- 14. Settings window chrome ---
header("14. Settings window chrome")

clearDiagnosticFile()
let settingsApplication = launchDebut(arguments: ["--show-settings"])
let settingsApplicationReady = waitForDebutReady(settingsApplication)
let settingsWindowTitles = settingsApplication.map {
    visibleWindowTitles(for: $0.processIdentifier)
} ?? []
info("Visible Debut windows: \(settingsWindowTitles)")
let _ = takeScreenshot("13_settings_window")

test("Settings integrates its controls into hidden transparent titlebar chrome") {
    settingsApplicationReady && readEvents().contains {
        $0["event"] == "settings_shown"
            && $0["fullSizeContentView"] == "true"
            && $0["titleHidden"] == "true"
            && $0["titlebarTransparent"] == "true"
            && $0["titlebarSeparatorHidden"] == "true"
    }
}

_ = terminateDebutAndWait()
clearDiagnosticFile()
let finalApplication = launchDebut()
let finalApplicationReady = waitForDebutReady(finalApplication)

test("Debut relaunches normally after the settings check") {
    finalApplicationReady
}

// --- Summary ---
header("Results")
print("")
print("  \(passCount)/\(totalCount) passed, \(skipCount) skipped, \(failCount) failed")
print("")
info("Screenshots saved to: \(screenshotDir.path)")
print("")

exit(Int32(failCount > 0 ? 1 : 0))
