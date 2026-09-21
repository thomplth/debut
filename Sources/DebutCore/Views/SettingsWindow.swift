import AppKit
import SwiftUI

@MainActor
public final class SettingsWindow: NSWindow {
    public init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "Debut Settings"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: rootView)
    }
}

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var selectedSection: SettingsSection = .features
    @State private var showingResetConfirmation = false
    @State private var showingRestoreDefaultsConfirmation = false
    private let shortcutRecordingService: (any ShortcutRecordingService)?
    @State private var externallyAppliedSettings: AppSettings?

    public init(
        viewModel: SettingsViewModel = SettingsViewModel(),
        selectedSection: SettingsSection = .features,
        shortcutRecordingService: (any ShortcutRecordingService)? = nil
    ) {
        self._selectedSection = State(initialValue: selectedSection)
        self._viewModel = State(initialValue: viewModel)
        self.shortcutRecordingService = shortcutRecordingService
    }

    public var body: some View {
        settingsNavigation
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(minWidth: 600, minHeight: 400)
            .onChange(of: viewModel.settings) { _, settings in
                if settings != externallyAppliedSettings { saveSettings() }
                externallyAppliedSettings = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .debutSettingsChanged)) { note in
                if let settings = note.object as? AppSettings, settings != viewModel.settings {
                    externallyAppliedSettings = settings
                    viewModel.settings = settings
                }
            }
    }

    private var settingsNavigation: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: sectionIcon(section))
            }
            .navigationSplitViewColumnWidth(180)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedSection {
                    case .features: featuresSection
                    case .excludedApps: excludedAppsSection
                    case .app: appSection
                    case .keyboardShortcuts: keyboardShortcutsSection
                    case .advanced:
                        appearanceSection
                        Divider()
                        selectorSection
                    case .troubleshooting: troubleshootingSection
                    case .about: aboutSection
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selectedSection)
        }
        .alert("Reset Window Cache?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Cache", role: .destructive) {
                viewModel.resetWindowCache()
            }
        } message: {
            Text("This removes all space window assignments, including dormant windows, and rebuilds assignments from your current macOS desktops. Settings are preserved.")
        }
    }

    // MARK: - Helpers

    private func saveSettings() {
        viewModel.onSettingsChanged?(viewModel.settings)
    }

    // MARK: - Sections

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make each desktop a workspace").font(.title2.bold())
            FeatureControlsView(features: $viewModel.settings.features)
            Divider()
            SwitchDurationControl(duration: $viewModel.settings.spaceSwitchDuration)
                .disabled(!viewModel.settings.features.fasterDesktopSwitching)
            VStack(alignment: .leading, spacing: 4) {
                settingsToggle(
                    "Show desktop switch indicator",
                    isOn: $viewModel.settings.showsDesktopSwitchIndicator
                )
                Text("Briefly shows the desktop number after a switch finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.title2.bold())

            Text("Fine-tune the space cards and window previews.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle(
                    "Show overlay only on main display",
                    isOn: $viewModel.settings.overlayOnMainDisplayOnly
                )
                Text("Always use the main display, even when the focused window is on another monitor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
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
                Text("Regular adds contrast over busy wallpapers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Stage corner radius")
                    Spacer()
                    Text("\(Int(viewModel.settings.stageCornerRadius)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.stageCornerRadius, in: 0...40, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Window size")
                    Spacer()
                    Text("\(Int((viewModel.settings.stageScale * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.settings.stageScale,
                    in: AppSettings.minimumStageScale...AppSettings.maximumStageScale,
                    step: AppSettings.stageScaleStep
                )
                Text("Large workspaces scale down automatically to fit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle(
                    "Match each preview to its window",
                    isOn: $viewModel.settings.adaptiveCardSizing
                )
                Text("Use each window’s proportions instead of a uniform card size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Inactive stage scale")
                    Spacer()
                    Text("\(Int((viewModel.settings.inactiveStageScale * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.inactiveStageScale, in: 0.4...1.0, step: 0.05)
                Text("Size of the other spaces relative to the selected space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Window previews")
                .font(.headline)
                .padding(.top, 8)

            HStack {
                Text("Refresh")
                Spacer()
                Picker("", selection: $viewModel.settings.previewRefreshPolicy) {
                    ForEach(PreviewRefreshPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .frame(width: 250)
            }

            if viewModel.settings.previewRefreshPolicy == .all {
                Label(
                    "Capturing every window on every activation delays the overlay, especially with many windows open.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Re-capture previews older than")
                    Spacer()
                    Text("\(Int(viewModel.settings.previewCacheTTL.rounded())) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.previewCacheTTL, in: 5...600, step: 5)
                Text("Keeps previews current for windows that change on their own, such as video or chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(viewModel.settings.previewRefreshPolicy == .all)
        }
    }

    private var selectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selector")
                .font(.title2.bold())

            Text("Choose how the selected window stands out inside its stage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text("Style")
                Spacer()
                Picker("", selection: $viewModel.settings.windowSelectionStyle) {
                    ForEach(WindowSelectionStyle.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if viewModel.settings.windowSelectionStyle == .filled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Surrounding space")
                        Spacer()
                        Text("\(Int(viewModel.settings.selectorOutset.rounded())) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $viewModel.settings.selectorOutset,
                        in: AppSettings.minimumSelectorOutset...AppSettings.maximumSelectorOutset,
                        step: 1
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Selector corner radius")
                        Spacer()
                        Text("\(Int(viewModel.settings.selectorCornerRadius.rounded())) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $viewModel.settings.selectorCornerRadius,
                        in: AppSettings.minimumSelectorCornerRadius...AppSettings.maximumSelectorCornerRadius,
                        step: 1
                    )
                }

                Text("The filled selector sits behind the preview and app icon. It follows macOS contrast: RGB 103 on dark appearances and RGB 167 on light appearances, and is hidden while dragging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Selected window size")
                        Spacer()
                        Text("\(Int((viewModel.settings.magnifyScale * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $viewModel.settings.magnifyScale,
                        in: AppSettings.minimumMagnifyScale...AppSettings.maximumMagnifyScale,
                        step: AppSettings.magnifyScaleStep
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Shadow strength")
                        Spacer()
                        Text("\(Int((viewModel.settings.magnifyShadowStrength * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $viewModel.settings.magnifyShadowStrength,
                        in: AppSettings.minimumMagnifyShadowStrength...AppSettings.maximumMagnifyShadowStrength,
                        step: 0.1
                    )
                }

                Text("Magnify enlarges the selected preview and casts a depth shadow, matching Debut's original selection treatment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @State private var selectedAppToExclude: String = ""

    private var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded Apps")
                .font(.title2.bold())

            Text("Excluded apps are invisible to the space manager. They won't appear in any space and won't trigger space switches.")
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

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle("Launch at login", isOn: $viewModel.settings.launchAtLogin)
                Text("Start Debut when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle("Show in Dock", isOn: $viewModel.settings.showsDockIcon)
                Text("Debut is always available in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Debut follows the system Reduce Motion setting for overlay animations. Turn it on in System Settings ▸ Accessibility ▸ Display to remove them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    static func switchDurationLabel(_ duration: TimeInterval) -> String {
        duration <= 0 ? "Instant" : "\(Int((duration * 1000).rounded())) ms"
    }

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.title2.bold())

            Text("Click a shortcut to change it. Feature switches are in Features.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Global activation")
                .font(.headline)
                .padding(.top, 4)

            ForEach(KeyAction.activationActions, id: \.self) { action in
                ShortcutRecorderRow(
                    action: action,
                    keyBindings: $viewModel.settings.keyBindings,
                    recordingService: shortcutRecordingService
                )
            }

            Text("All-windows switcher")
                .font(.headline)
                .padding(.top, 4)

            Text("Opens one flat list of every window on every space, in the order you last used them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(KeyAction.altTabActions, id: \.self) { action in
                ShortcutRecorderRow(
                    action: action,
                    keyBindings: $viewModel.settings.keyBindings,
                    recordingService: shortcutRecordingService
                )
            }

            Text("Same-app window cycling")
                .font(.headline)
                .padding(.top, 4)

            ForEach(KeyAction.sameAppActions, id: \.self) { action in
                ShortcutRecorderRow(
                    action: action,
                    keyBindings: $viewModel.settings.keyBindings,
                    recordingService: shortcutRecordingService
                )
            }

            Text("Move focused window")
                .font(.headline)
                .padding(.top, 4)

            HStack {
                Text("Move to previous stage")
                Spacer()
                Text("⌥⌘← / ⌥⌘↑").foregroundStyle(.secondary)
            }
            HStack {
                Text("Move to next stage")
                Spacer()
                Text("⌥⌘→ / ⌥⌘↓").foregroundStyle(.secondary)
            }
            Text("Follow the window to its desktop and keep it focused. Requires workspace isolation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Quick switch")
                .font(.headline)
                .padding(.top, 4)

            HStack {
                Text("Switch directly to space")
                Spacer()
                Picker("", selection: $viewModel.settings.quickSwitchModifiers) {
                    ForEach(ShortcutModifiers.choices, id: \.self) { modifiers in
                        Text("\(modifiers.displayString)+1–9").tag(modifiers)
                    }
                }
                .frame(width: 220)
            }

            HStack {
                Text("Switch to space with current app")
                Spacer()
                Picker("", selection: $viewModel.settings.quickSwitchSameApplicationModifiers) {
                    ForEach(ShortcutModifiers.choices, id: \.self) { modifiers in
                        Text("\(modifiers.displayString)+1–9").tag(modifiers)
                    }
                }
                .frame(width: 220)
            }

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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Held cycling pace")
                    Spacer()
                    Text(
                        viewModel.settings.heldCycleMinimumInterval > 0
                            ? "\(Int((viewModel.settings.heldCycleMinimumInterval * 1000).rounded())) ms"
                            : "Off"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Slider(
                    value: $viewModel.settings.heldCycleMinimumInterval,
                    in: 0...0.3,
                    step: 0.01
                )
                Text("Minimum time between held-key steps. Off uses your system repeat rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Space Manager session")
                .font(.headline)
                .padding(.top, 8)

            Text("These keys are pressed while the modifier from the activation shortcut remains held.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(KeyAction.sessionActions, id: \.self) { action in
                ShortcutRecorderRow(
                    action: action,
                    keyBindings: $viewModel.settings.keyBindings,
                    recordingService: shortcutRecordingService
                )
            }

            shortcutRow(
                "Commit selection",
                shortcut: "Release activation modifier",
                configurable: false
            )

            Button("Restore Defaults…", role: .destructive) {
                showingRestoreDefaultsConfirmation = true
            }
            .padding(.top, 8)
        }
        .onChange(of: viewModel.settings.quickSwitchModifiers) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.quickSwitchSameApplicationModifiers) { _, _ in
            saveSettings()
        }
        .alert("Restore Default Shortcuts?", isPresented: $showingRestoreDefaultsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) {
                viewModel.restoreDefaultShortcuts()
            }
        } message: {
            Text("This resets all keyboard shortcuts and shortcut modifiers to their defaults. Other settings are preserved.")
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.title2.bold())

            HStack(spacing: 16) {
                Image(nsImage: DebutGlyph.image(size: 44))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Debut")
                        .font(.title3.bold())
                    Text("Version \(DebutCore.version)")
                        .foregroundStyle(.secondary)
                    Text("Space-based workspace manager for macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Check for Updates…") {
                viewModel.checkForUpdates()
            }
        }
    }

    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Troubleshooting")
                .font(.title2.bold())

            Text("Export a snapshot before resetting so window assignments, Accessibility tracking, lifecycle events, and persisted state can be investigated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostic data")
                    Text("Includes app and window names and window titles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export Diagnostic Data…") {
                    viewModel.exportDiagnosticData()
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Window cache")
                    Text("Use this when closed or duplicate windows remain in Debut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Window Cache…", role: .destructive) {
                    showingResetConfirmation = true
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
        case .features: "square.stack.3d.up"
        case .advanced: "slider.horizontal.3"
        case .excludedApps: "eye.slash"
        case .app: "gearshape"
        case .keyboardShortcuts: "keyboard"
        case .troubleshooting: "stethoscope"
        case .about: "info.circle"
        }
    }
}
