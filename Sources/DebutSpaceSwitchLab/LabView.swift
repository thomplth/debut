import SpaceSwitchLabCore
import SwiftUI

struct LabView: View {
    @StateObject private var model = LabViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                Form {
                    targetSection
                    recipeSection
                    timingSection
                    fieldsSection
                    keyboardSection
                }
                .formStyle(.grouped)
                .frame(minWidth: 500)

                logPanel
                    .frame(minWidth: 300, idealWidth: 340)
            }
        }
        .onAppear { model.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Space Switch Recipe Lab").font(.title2.weight(.semibold))
                Text("Private gesture test harness · Control-number is enabled by default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.canPostGestures {
                Label("Legacy gestures unavailable on macOS 27+", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    private var targetSection: some View {
        Section("Test switch") {
            if model.topology.stacks.isEmpty {
                Text("WindowServer did not return a managed desktop list.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Display stack", selection: $model.selectedStackID) {
                    ForEach(model.topology.stacks) { stack in
                        Text(stack.displayName).tag(stack.id)
                    }
                }
                if let stack = model.selectedStack {
                    LabeledContent("Current desktop") {
                        Text(stack.currentDesktopIndex.map { "\($0 + 1) of \(stack.desktopIDs.count)" } ?? "Unknown")
                    }
                    LabeledContent("Switch now") {
                        HStack(spacing: 6) {
                            ForEach(Array(stack.desktopIDs.indices), id: \.self) { index in
                                Button("\(index + 1)") {
                                    model.requestSwitch(to: index, source: "button")
                                }
                                .buttonStyle(.bordered)
                                .disabled(index == stack.currentDesktopIndex || !model.canPostGestures)
                            }
                        }
                    }
                }
                Button("Refresh topology") { model.refreshTopology() }
            }
        }
    }

    private var recipeSection: some View {
        Section("Approach") {
            Picker("Preset", selection: Binding(
                get: { model.settings.selectedPreset },
                set: { model.selectPreset($0) }
            )) {
                ForEach(GesturePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Text(model.settings.selectedPreset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Hop scheduling", selection: recipeBinding(\.hopScheduling)) {
                ForEach(HopScheduling.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Scale velocity by requested distance", isOn: recipeBinding(\.scaleVelocityByDistance))
        }
    }

    private var timingSection: some View {
        Section("Phases, progress, and timing") {
            Picker("Changed events", selection: recipeBinding(\.changedEvents)) {
                ForEach(ChangedEventMode.allCases) { Text($0.title).tag($0) }
            }
            if model.settings.recipe.changedEvents == .timed {
                numberRow("Duration", value: recipeBinding(\.durationMilliseconds), range: 0...1_000, suffix: "ms")
                numberRow("Sample rate", value: recipeBinding(\.sampleRate), range: 1...240, suffix: "Hz")
                Picker("Easing", selection: recipeBinding(\.easing)) {
                    ForEach(GestureEasing.allCases) { Text($0.title).tag($0) }
                }
            }
            numberRow("Began progress", value: recipeBinding(\.beganProgress), range: -10...10)
            if model.settings.recipe.changedEvents != .none {
                numberRow("Changed progress", value: recipeBinding(\.changedProgress), range: -10...10)
            }
            numberRow("Ended progress", value: recipeBinding(\.endedProgress), range: -10...10)
            numberRow("Velocity", value: recipeBinding(\.velocity), range: 0...10_000)
            LabeledContent("Known velocity values") {
                HStack(spacing: 5) {
                    ForEach([40, 50, 60, 70, 80, 400, 2_000], id: \.self) { velocity in
                        Button("\(velocity)") {
                            model.updateRecipe(\.velocity, Double(velocity))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Picker("Velocity phases", selection: recipeBinding(\.velocityPhases)) {
                ForEach(VelocityPhases.allCases) { Text($0.title).tag($0) }
            }
            Picker("Y velocity", selection: recipeBinding(\.yVelocity)) {
                ForEach(YVelocityMode.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var fieldsSection: some View {
        Section("Event payload") {
            Toggle("Generic gesture envelope after each phase", isOn: recipeBinding(\.includeEnvelope))
            Toggle("Horizontal swipe-motion field (123)", isOn: recipeBinding(\.includeHorizontalMotion))
            Toggle("Scroll-Y field (119)", isOn: recipeBinding(\.includeScrollY))
            Toggle("Direction flag field (135)", isOn: recipeBinding(\.includeDirectionFlag))
            Toggle("Zoom epsilon field (139)", isOn: recipeBinding(\.includeZoomEpsilon))
            Picker("Event location", selection: recipeBinding(\.eventLocation)) {
                ForEach(EventLocationMode.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var keyboardSection: some View {
        Section("Global 1–9 shortcut") {
            HStack {
                modifierToggle("⌃ Control", .control)
                modifierToggle("⌥ Option", .option)
                modifierToggle("⇧ Shift", .shift)
                modifierToggle("⌘ Command", .command)
            }
            LabeledContent("Active chord", value: "\(model.shortcutDescription)+1…9")
            HStack {
                Label(
                    model.hotkeyRunning ? "Keyboard monitor active" : "Keyboard monitor unavailable",
                    systemImage: model.hotkeyRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.hotkeyRunning ? .green : .orange)
                Spacer()
                if !model.accessibilityTrusted {
                    Button("Grant Accessibility") { model.requestAccessibility() }
                }
            }
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timing log").font(.headline)
                Spacer()
                Button("Copy") { model.copyLog() }
                Button("Export…") { model.exportLog() }
                Button("Clear") { model.clearLog() }
            }
            Text("REQUEST is recorded before posting; CONFIRM comes only from activeSpaceDidChangeNotification.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.logLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .padding(16)
    }

    private func recipeBinding<Value>(_ keyPath: WritableKeyPath<GestureRecipe, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.recipe[keyPath: keyPath] },
            set: { model.updateRecipe(keyPath, $0) }
        )
    }

    private func numberRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String = ""
    ) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range).frame(width: 190)
                TextField("", value: value, format: .number.precision(.fractionLength(0...6)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76)
                if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
            }
        }
    }

    private func modifierToggle(_ title: String, _ modifier: LabModifiers) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.settings.requiredModifiers.contains(modifier) },
            set: { _ in model.toggleModifier(modifier) }
        ))
        .toggleStyle(.button)
    }
}
