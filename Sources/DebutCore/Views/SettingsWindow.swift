import SwiftUI

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var selectedSection: SettingsSection = .templates

    public init(viewModel: SettingsViewModel = SettingsViewModel()) {
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: sectionIcon(section))
            }
            .navigationSplitViewColumnWidth(180)
            .listStyle(.sidebar)
        } detail: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        appearanceSection
                            .id(SettingsSection.appearance)
                        templatesSection
                            .id(SettingsSection.templates)
                        excludedAppsSection
                            .id(SettingsSection.excludedApps)
                        appSection
                            .id(SettingsSection.app)
                        keyboardShortcutsSection
                            .id(SettingsSection.keyboardShortcuts)
                        aboutSection
                            .id(SettingsSection.about)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedSection) { _, newValue in
                    withAnimation {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onChange(of: viewModel.settings.excludedBundleIDs) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.quickSwitchExcludedBundleIDs) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.launchAtLogin) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.showInMenuBar) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.confirmStageDeletion) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.animationsEnabled) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.glassStyle) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.plateCornerRadius) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.selectionOpacity) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.selectionBorderWidth) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.selectionBorderOpacity) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.inactivePlateScale) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.overlayPresentationDelay) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.keyBindings) { _, _ in saveSettings() }
    }

    // MARK: - Helpers

    private func saveSettings() {
        viewModel.onSettingsChanged?(viewModel.settings)
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.title2.bold())

            HStack {
                Text("Glass style")
                Spacer()
                Picker("", selection: $viewModel.settings.glassStyle) {
                    Text("Clear").tag(GlassStyle.clear)
                    Text("Regular").tag(GlassStyle.regular)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Corner radius")
                    Spacer()
                    Text("\(Int(viewModel.settings.plateCornerRadius))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.plateCornerRadius, in: 0...40, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Inactive plate scale")
                    Spacer()
                    Text("\(viewModel.settings.inactivePlateScale, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.inactivePlateScale, in: 0.4...1.0, step: 0.05)
            }

            Text("Selection")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fill opacity")
                    Spacer()
                    Text("\(viewModel.settings.selectionOpacity, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.selectionOpacity, in: 0...0.5, step: 0.01)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Border width")
                    Spacer()
                    Text("\(viewModel.settings.selectionBorderWidth, specifier: "%.1f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.selectionBorderWidth, in: 0...4, step: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Border opacity")
                    Spacer()
                    Text("\(viewModel.settings.selectionBorderOpacity, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.selectionBorderOpacity, in: 0...0.5, step: 0.01)
            }
        }
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Templates")
                .font(.title2.bold())

            if viewModel.stageManager.templates.isEmpty {
                Text("No templates saved. Use Space in the Stage Manager to save a stage as a template.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.stageManager.templates) { template in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(template.name)
                                .font(.headline)
                            Text(template.appBundleIDs.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.stageManager.deleteTemplate(id: template.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @State private var selectedAppToExclude: String = ""
    @State private var selectedQuickSwitchExcludedApp: String = ""

    private var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded Apps")
                .font(.title2.bold())

            Text("Excluded apps are invisible to the stage manager. They won't appear in any stage and won't trigger stage switches.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Add app", selection: $selectedAppToExclude) {
                    Text("Select an app...").tag("")
                    ForEach(
                        runningAppNames(excluding: viewModel.settings.excludedBundleIDs),
                        id: \.bundleID
                    ) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .frame(maxWidth: 250)

                Button("Add") {
                    guard !selectedAppToExclude.isEmpty,
                          !viewModel.settings.excludedBundleIDs.contains(selectedAppToExclude)
                    else { return }
                    viewModel.settings.excludedBundleIDs.append(selectedAppToExclude)
                    selectedAppToExclude = ""
                }
                .disabled(selectedAppToExclude.isEmpty)
            }

            if !viewModel.settings.excludedBundleIDs.isEmpty {
                ForEach(viewModel.settings.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        AppIconImage(bundleID: bundleID, name: bundleID, iconSize: 20)
                            .frame(width: 20, height: 20)
                        Text(appName(for: bundleID))
                        Spacer()
                        Text(bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            viewModel.settings.excludedBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private struct RunningApp: Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    private func runningAppNames(excluding bundleIDs: [String]) -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != "com.thomplth.Debut" }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      !bundleIDs.contains(bundleID)
                else { return nil }
                return RunningApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App")
                .font(.title2.bold())

            settingsToggle("Launch at login", isOn: $viewModel.settings.launchAtLogin)
            settingsToggle("Show in menu bar", isOn: $viewModel.settings.showInMenuBar)

            HStack {
                Text("New stage placement")
                Spacer()
                Picker("", selection: $viewModel.settings.newStagePlacement) {
                    Text("Above").tag(StageInsertPosition.above)
                    Text("Below").tag(StageInsertPosition.below)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            settingsToggle("Confirm stage deletion", isOn: $viewModel.settings.confirmStageDeletion)
            settingsToggle("Stage Manager animations", isOn: $viewModel.settings.animationsEnabled)
        }
    }

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.title2.bold())

            Text("Stage Manager shortcuts (while Cmd is held)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            shortcutRow("Switch windows (hold)", shortcut: "Cmd+Tab", configurable: false)
            shortcutRow("Quick switch last window", shortcut: "Cmd+Tab (tap)", configurable: false)
            shortcutRow("Switch stages (hold)", shortcut: "Cmd+Opt+Tab", configurable: false)
            shortcutRow("Quick switch stages", shortcut: "Ctrl+1…9 / Ctrl+0", configurable: false)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Overlay hold delay")
                    Spacer()
                    Text("\(Int((viewModel.settings.overlayPresentationDelay * 1000).rounded())) ms")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.settings.overlayPresentationDelay,
                    in: 0...0.5,
                    step: 0.025
                )
            }

            Text("Quick switch exclusions")
                .font(.headline)
                .padding(.top, 8)

            Text("Apps in this list keep their own Ctrl+number shortcuts while frontmost. Debut quick switching remains active in other apps.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Add app", selection: $selectedQuickSwitchExcludedApp) {
                    Text("Select an app...").tag("")
                    ForEach(
                        runningAppNames(
                            excluding: viewModel.settings.quickSwitchExcludedBundleIDs
                        ),
                        id: \.bundleID
                    ) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .frame(maxWidth: 250)

                Button("Add") {
                    guard !selectedQuickSwitchExcludedApp.isEmpty,
                          !viewModel.settings.quickSwitchExcludedBundleIDs.contains(
                            selectedQuickSwitchExcludedApp
                          )
                    else { return }
                    viewModel.settings.quickSwitchExcludedBundleIDs.append(
                        selectedQuickSwitchExcludedApp
                    )
                    selectedQuickSwitchExcludedApp = ""
                }
                .disabled(selectedQuickSwitchExcludedApp.isEmpty)
            }

            if !viewModel.settings.quickSwitchExcludedBundleIDs.isEmpty {
                ForEach(viewModel.settings.quickSwitchExcludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        AppIconImage(bundleID: bundleID, name: bundleID, iconSize: 20)
                            .frame(width: 20, height: 20)
                        Text(appName(for: bundleID))
                        Spacer()
                        Text(bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            viewModel.settings.quickSwitchExcludedBundleIDs.removeAll {
                                $0 == bundleID
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text("Click a shortcut to rebind it")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            ForEach(KeyAction.allCases, id: \.self) { action in
                ShortcutRecorderRow(
                    action: action,
                    keyBindings: $viewModel.settings.keyBindings
                )
            }

            shortcutRow("Commit selection", shortcut: "Release Cmd", configurable: false)
            shortcutRow("Discard selection", shortcut: "Esc", configurable: false)

            Button("Restore Defaults") {
                viewModel.settings.keyBindings.restoreDefaults()
            }
            .padding(.top, 8)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.title2.bold())

            HStack(spacing: 16) {
                Image(systemName: "theatermask.and.paintbrush")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Debut")
                        .font(.title3.bold())
                    Text("Version \(DebutCore.version)")
                        .foregroundStyle(.secondary)
                    Text("Stage-based workspace manager for macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func settingsToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
    }

    private func shortcutRow(_ label: String, shortcut: String, configurable: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(configurable ? .primary : .secondary)
        }
    }

    private func sectionIcon(_ section: SettingsSection) -> String {
        switch section {
        case .appearance: "paintbrush"
        case .templates: "rectangle.stack"
        case .excludedApps: "eye.slash"
        case .app: "gearshape"
        case .keyboardShortcuts: "keyboard"
        case .about: "info.circle"
        }
    }
}
