import AppKit
import ApplicationServices
import Combine
import SpaceSwitchLabCore

@MainActor
final class LabViewModel: NSObject, ObservableObject {
    struct PendingSwitch {
        var stackID: String
        var targetDesktopID: LabSpaceID
        var originDesktopID: LabSpaceID
        var expectedDesktopID: LabSpaceID
        var recipe: GestureRecipe
        var requestNanoseconds: UInt64
    }

    @Published private(set) var settings: LabSettings
    @Published private(set) var topology: LabSpaceTopology = .empty
    @Published var selectedStackID: String = ""
    @Published private(set) var logLines: [String] = []
    @Published private(set) var hotkeyRunning = false
    @Published private(set) var accessibilityTrusted = false

    private let reader = SpaceTopologyReader()
    private let hotkeyMonitor = NumberHotkeyMonitor()
    private var pending: PendingSwitch?
    private var observer: NSObjectProtocol?
    private var started = false
    private let defaultsKey = "SpaceSwitchLab.settings.v1"

    override init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(LabSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .defaults
        }
        super.init()
    }

    var canPostGestures: Bool { reader.canPostLegacyGestures }

    var selectedStack: LabSpaceStack? {
        topology.stacks.first { $0.id == selectedStackID } ?? topology.stacks.first
    }

    var logText: String { logLines.joined(separator: "\n") }

    func start() {
        guard !started else { return }
        started = true
        refreshTopology()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.desktopDidChange() }
        }
        restartHotkeyMonitor(prompt: false)
        appendLog("READY preset=\(settings.selectedPreset.title) shortcut=\(shortcutDescription)")
        if !canPostGestures {
            appendLog("BLOCKED macOS 27+ requires the augmented IOHID gesture path")
        }
    }

    func refreshTopology() {
        topology = reader.read()
        if !topology.stacks.contains(where: { $0.id == selectedStackID }) {
            selectedStackID = topology.stacks.first?.id ?? ""
        }
    }

    func selectPreset(_ preset: GesturePreset) {
        var updated = settings
        updated.selectedPreset = preset
        if preset != .custom { updated.recipe = .preset(preset) }
        settings = updated
        persist()
        appendLog("PRESET \(preset.title)")
    }

    func updateRecipe<Value>(_ keyPath: WritableKeyPath<GestureRecipe, Value>, _ value: Value) {
        var updated = settings
        updated.selectedPreset = .custom
        updated.recipe[keyPath: keyPath] = value
        updated.recipe = updated.recipe.sanitized()
        settings = updated
        persist()
    }

    func toggleModifier(_ modifier: LabModifiers) {
        var updated = settings
        if updated.requiredModifiers.contains(modifier) {
            updated.requiredModifiers.remove(modifier)
        } else {
            updated.requiredModifiers.insert(modifier)
        }
        settings = updated
        persist()
        hotkeyMonitor.update(requiredModifiers: updated.requiredModifiers)
        appendLog("SHORTCUT \(shortcutDescription)+1…9")
    }

    func requestAccessibility() {
        restartHotkeyMonitor(prompt: true)
    }

    func requestSwitch(to targetIndex: Int, source: String) {
        refreshTopology()
        guard canPostGestures else {
            appendLog("DECLINED target=\(targetIndex + 1) reason=unsupported-macOS")
            return
        }
        guard let stack = selectedStack,
              let current = stack.currentDesktopIndex,
              stack.desktopIDs.indices.contains(targetIndex),
              let route = SwitchRoute(
                  from: current,
                  to: targetIndex,
                  desktopCount: stack.desktopIDs.count
              )
        else {
            appendLog("NOOP source=\(source) target=\(targetIndex + 1)")
            return
        }

        if var inFlight = pending, inFlight.stackID == stack.id,
           settings.recipe.hopScheduling == .confirmedAdjacent {
            inFlight.targetDesktopID = stack.desktopIDs[targetIndex]
            inFlight.recipe = settings.recipe
            pending = inFlight
            appendLog("COALESCE source=\(source) target=\(targetIndex + 1)")
            return
        }

        let requestTime = DispatchTime.now().uptimeNanoseconds
        appendLog(
            "REQUEST source=\(source) from=\(current + 1) to=\(targetIndex + 1) " +
            "preset=\(settings.selectedPreset.title) schedule=\(settings.recipe.hopScheduling.title)"
        )

        switch settings.recipe.hopScheduling {
        case .confirmedAdjacent:
            let nextIndex = current + (route.direction == .right ? 1 : -1)
            pending = PendingSwitch(
                stackID: stack.id,
                targetDesktopID: stack.desktopIDs[targetIndex],
                originDesktopID: stack.desktopIDs[current],
                expectedDesktopID: stack.desktopIDs[nextIndex],
                recipe: settings.recipe,
                requestNanoseconds: requestTime
            )
            post(recipe: settings.recipe, directions: [route.direction], distance: 1, stack: stack)
        case .batched:
            pending = PendingSwitch(
                stackID: stack.id,
                targetDesktopID: stack.desktopIDs[targetIndex],
                originDesktopID: stack.desktopIDs[current],
                expectedDesktopID: stack.desktopIDs[targetIndex],
                recipe: settings.recipe,
                requestNanoseconds: requestTime
            )
            post(
                recipe: settings.recipe,
                directions: route.directions(for: .batched),
                distance: route.distance,
                stack: stack
            )
        }
    }

    func clearLog() { logLines.removeAll() }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "space-switch-lab.log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try logText.write(to: url, atomically: true, encoding: .utf8)
            appendLog("EXPORTED \(url.path)")
        } catch {
            appendLog("EXPORT_FAILED \(error.localizedDescription)")
        }
    }

    var shortcutDescription: String {
        let modifiers = settings.requiredModifiers
        var labels: [String] = []
        if modifiers.contains(.control) { labels.append("⌃") }
        if modifiers.contains(.option) { labels.append("⌥") }
        if modifiers.contains(.shift) { labels.append("⇧") }
        if modifiers.contains(.command) { labels.append("⌘") }
        return labels.isEmpty ? "No modifier" : labels.joined()
    }

    private func restartHotkeyMonitor(prompt: Bool) {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        accessibilityTrusted = AXIsProcessTrusted()
        hotkeyRunning = hotkeyMonitor.start(
            requiredModifiers: settings.requiredModifiers
        ) { [weak self] index in
            Task { @MainActor [weak self] in
                self?.requestSwitch(to: index, source: "hotkey")
            }
        }
        if !hotkeyRunning {
            appendLog("HOTKEY_UNAVAILABLE grant Accessibility permission, then retry")
        }
    }

    private func desktopDidChange() {
        refreshTopology()
        guard let inFlight = pending,
              let stack = topology.stacks.first(where: { $0.id == inFlight.stackID }),
              let currentID = stack.currentDesktopID,
              let currentIndex = stack.currentDesktopIndex
        else {
            appendLog("CONFIRM topology-unavailable")
            pending = nil
            return
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - inFlight.requestNanoseconds) / 1_000_000
        appendLog(String(format: "CONFIRM desktop=%d elapsed=%.3fms", currentIndex + 1, elapsed))

        if currentID == inFlight.targetDesktopID {
            appendLog(String(format: "COMPLETE desktop=%d total=%.3fms", currentIndex + 1, elapsed))
            pending = nil
            return
        }
        guard inFlight.recipe.hopScheduling == .confirmedAdjacent else {
            appendLog("BATCH_LANDED_UNEXPECTED expected target desktop")
            pending = nil
            return
        }
        guard currentID == inFlight.expectedDesktopID else {
            if currentID != inFlight.originDesktopID {
                appendLog("STOP unexpected desktop change")
                pending = nil
            }
            return
        }
        guard let targetIndex = stack.desktopIDs.firstIndex(of: inFlight.targetDesktopID),
              let route = SwitchRoute(
                  from: currentIndex,
                  to: targetIndex,
                  desktopCount: stack.desktopIDs.count
              )
        else {
            pending = nil
            return
        }
        let nextIndex = currentIndex + (route.direction == .right ? 1 : -1)
        pending = PendingSwitch(
            stackID: stack.id,
            targetDesktopID: inFlight.targetDesktopID,
            originDesktopID: currentID,
            expectedDesktopID: stack.desktopIDs[nextIndex],
            recipe: inFlight.recipe,
            requestNanoseconds: inFlight.requestNanoseconds
        )
        post(recipe: inFlight.recipe, directions: [route.direction], distance: 1, stack: stack)
    }

    private func post(
        recipe: GestureRecipe,
        directions: [SwitchDirection],
        distance: Int,
        stack: LabSpaceStack
    ) {
        guard let firstDirection = directions.first else { return }
        let location: CGPoint?
        switch recipe.eventLocation {
        case .displayCenter:
            if let displayID = stack.displayID {
                let bounds = CGDisplayBounds(displayID)
                location = CGPoint(x: bounds.midX, y: bounds.midY)
            } else {
                location = CGPoint(x: stack.frame.midX, y: stack.frame.midY)
            }
        case .pointer:
            location = CGEvent(source: nil)?.location
        case .unset:
            location = nil
        }

        appendLog(
            "POST phases=\(recipe.frames(direction: firstDirection, distance: distance).map(\.phase.rawValue).joined(separator: ">")) " +
            "hops=\(directions.count) velocity=\(recipe.velocity)"
        )
        Task { @MainActor [weak self] in
            let successes = await Task.detached(priority: .userInitiated) {
                directions.map { direction in
                    DockGesturePoster.post(
                        recipe: recipe,
                        direction: direction,
                        distance: distance,
                        location: location
                    )
                }
            }.value
            guard let self else { return }
            if successes.contains(false) {
                self.appendLog("POST_FAILED event allocation")
                self.pending = nil
            }
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logLines.append("\(formatter.string(from: Date()))  \(message)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
