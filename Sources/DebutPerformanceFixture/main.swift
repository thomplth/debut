import AppKit
import DebutInputDriver
import Foundation

/// Drives the stage-cycling gesture the overlay jank report is about: Command and
/// Option held down while Tab is tapped. `InputDriver` never exercised this, so the
/// VM suite measured window cycling instead.
private enum PlateCycleDriver {
    static func run() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let outputIndex = arguments.firstIndex(of: "--drive-plate-cycle"),
              arguments.indices.contains(outputIndex + 1)
        else { return }
        let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1])
        let passes = Int(value(after: "--passes", in: arguments) ?? "") ?? 6
        let forward = Int(value(after: "--forward", in: arguments) ?? "") ?? 8
        let backward = Int(value(after: "--backward", in: arguments) ?? "") ?? 4
        let tapInterval = Double(value(after: "--tap-interval", in: arguments) ?? "") ?? 0.09

        var records: [String] = []
        for pass in 1...max(1, passes) {
            let events = PlateCycleSequence.events(forward: forward, backward: backward)
            let started = DispatchTime.now().uptimeNanoseconds
            for event in events {
                post(event)
                // Only pace the Tab release; modifier transitions belong to the
                // same instant as the tap they bracket.
                if case .key(PlateCycleKey.tab, down: false) = event.kind {
                    Thread.sleep(forTimeInterval: tapInterval)
                } else {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let steps = forward + backward
            records.append(
                "{\"scenario\":\"plate-cycle-input\",\"iteration\":\(pass),"
                + "\"steps\":\(steps),\"durationMilliseconds\":\(elapsed),"
                + "\"millisecondsPerStep\":\(elapsed / Double(max(steps, 1)))}"
            )
            Thread.sleep(forTimeInterval: 0.4)
        }
        try? (records.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Posts to the session tap, which is where Debut's own tap listens.
    private static func post(_ event: SyntheticKeyEvent) {
        let cgEvent: CGEvent?
        switch event.kind {
        case .key(let keyCode, let down):
            cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        case .flagsChanged:
            cgEvent = CGEvent(source: nil)
            cgEvent?.type = .flagsChanged
        }
        guard let cgEvent else { return }
        cgEvent.flags = event.flags
        cgEvent.post(tap: .cgSessionEventTap)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum InputDriver {
    static func run() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let outputIndex = arguments.firstIndex(of: "--drive"), arguments.indices.contains(outputIndex + 1) else {
            return
        }
        let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1])
        var records: [String] = []

        for iteration in 1...20 {
            let started = DispatchTime.now().uptimeNanoseconds
            commandTab(repetitions: iteration.isMultiple(of: 4) ? 3 : 1)
            records.append(record(scenario: "overlay-input", iteration: iteration, started: started))
            Thread.sleep(forTimeInterval: 0.08)
        }
        for iteration in 1...100 {
            let started = DispatchTime.now().uptimeNanoseconds
            controlDigit(iteration.isMultiple(of: 2) ? 19 : 18)
            records.append(record(scenario: "stage-switch-input", iteration: iteration, started: started))
            Thread.sleep(forTimeInterval: 0.01)
        }

        try? (records.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func commandTab(repetitions: Int) {
        post(keyCode: 55, keyDown: true, flags: .maskCommand)
        for _ in 0..<repetitions {
            post(keyCode: 48, keyDown: true, flags: .maskCommand)
            post(keyCode: 48, keyDown: false, flags: .maskCommand)
        }
        post(keyCode: 55, keyDown: false, flags: [])
    }

    private static func controlDigit(_ keyCode: CGKeyCode) {
        post(keyCode: 59, keyDown: true, flags: .maskControl)
        post(keyCode: keyCode, keyDown: true, flags: .maskControl)
        post(keyCode: keyCode, keyDown: false, flags: .maskControl)
        post(keyCode: 59, keyDown: false, flags: [])
    }

    private static func post(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func record(scenario: String, iteration: Int, started: UInt64) -> String {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return "{\"scenario\":\"\(scenario)\",\"iteration\":\(iteration),\"durationMilliseconds\":\(elapsed)}"
    }
}

private struct Profile {
    let processes: Int
    let windows: Int

    static func named(_ name: String) -> Profile {
        switch name {
        case "busy": Profile(processes: 7, windows: 21)
        case "stress": Profile(processes: 10, windows: 50)
        default: Profile(processes: 4, windows: 12)
        }
    }
}

private final class TextureView: NSView {
    let seed: Int
    init(seed: Int) { self.seed = seed; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedHue: CGFloat(seed % 20) / 20, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
        bounds.fill()
        for index in 0..<12 {
            let value = CGFloat((seed * 37 + index * 19) % 255) / 255
            NSColor(white: value, alpha: 0.7).setFill()
            NSRect(x: CGFloat(index * 31 % 280), y: CGFloat(index * 47 % 180), width: 80, height: 36).fill()
        }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private let arguments = ProcessInfo.processInfo.arguments
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let profileName = environment["DEBUT_PERFORMANCE_PROFILE"] ?? value(after: "--profile") ?? "typical"
        let profile = Profile.named(profileName)
        let processIndex = Int(value(after: "--process-index") ?? "0") ?? 0
        let count = max(1, profile.windows / profile.processes + (processIndex < profile.windows % profile.processes ? 1 : 0))
        for index in 0..<count { createWindow(index: index, processIndex: processIndex) }
        installCommands()
        installSignalCommands()
        writeReadiness(profile: profileName, processIndex: processIndex)
    }

    private func createWindow(index: Int, processIndex: Int) {
        let seed = processIndex * 100 + index
        let window = NSWindow(
            contentRect: NSRect(x: 80 + seed % 7 * 28, y: 90 + seed % 5 * 35, width: 420 + seed % 3 * 80, height: 280 + seed % 4 * 50),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = index % 3 == 0 ? "Duplicate Fixture" : "Fixture \(processIndex)-\(index)"
        window.contentView = TextureView(seed: seed)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    private func installCommands() {
        let center = DistributedNotificationCenter.default()
        for command in ["hide", "reveal", "close", "recreate", "dynamic-title", "hang", "exit"] {
            center.addObserver(forName: Notification.Name("com.thomplth.Debut.fixture.\(command)"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(command) }
            }
        }
    }

    private func installSignalCommands() {
        for (signalNumber, command) in [(SIGUSR1, "dynamic-title"), (SIGUSR2, "hang")] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.handle(command) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func handle(_ command: String) {
        switch command {
        case "hide": windows.forEach { $0.orderOut(nil) }
        case "reveal": windows.forEach { $0.orderFront(nil) }
        case "close": windows.last?.close(); if !windows.isEmpty { windows.removeLast() }
        case "recreate": createWindow(index: windows.count, processIndex: Int(getpid() % 100))
        case "dynamic-title": windows.first?.title = "Dynamic \(Int(Date().timeIntervalSince1970) % 1000)"
        case "hang": Thread.sleep(forTimeInterval: 5)
        case "exit": NSApp.terminate(nil)
        default: break
        }
    }

    private func writeReadiness(profile: String, processIndex: Int) {
        let url = URL(fileURLWithPath: "/tmp/debut-performance-fixture-\(getpid()).ready.json")
        let object: [String: Any] = ["pid": getpid(), "profile": profile, "processIndex": processIndex, "windows": windows.count]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }

    private func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

if ProcessInfo.processInfo.arguments.contains("--drive-plate-cycle") {
    PlateCycleDriver.run()
    exit(EXIT_SUCCESS)
}

if ProcessInfo.processInfo.arguments.contains("--drive") {
    InputDriver.run()
    exit(EXIT_SUCCESS)
}

private let app = NSApplication.shared
private let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
