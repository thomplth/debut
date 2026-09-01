import AppKit
import SwiftUI

@MainActor
public final class SettingsWindow: NSWindow {
    public init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
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
    @State private var selectedSection: SettingsSection = .appearance
    @State private var showingResetConfirmation = false
    private let shortcutRecordingService: (any ShortcutRecordingService)?
    @State private var showingTelemetryPayload = false
    @State private var telemetryPayload = ""

    public init(
        viewModel: SettingsViewModel = SettingsViewModel(),
        shortcutRecordingService: (any ShortcutRecordingService)? = nil
    ) {
        self._viewModel = State(initialValue: viewModel)
        self.shortcutRecordingService = shortcutRecordingService
    }

    public var body: some View {
        settingsNavigation
            .frame(minWidth: 600, minHeight: 400)
            .onChange(of: viewModel.settings) { _, _ in saveSettings() }
    }

    private var settingsNavigation: some View {
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
                        selectorSection
                            .id(SettingsSection.selector)
                        excludedAppsSection
                            .id(SettingsSection.excludedApps)
                        appSection
                            .id(SettingsSection.app)
                        privacySection
                            .id(SettingsSection.privacy)
                        keyboardShortcutsSection
                            .id(SettingsSection.keyboardShortcuts)
                        troubleshootingSection
                            .id(SettingsSection.troubleshooting)
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
        .alert("Reset Window Cache?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Cache", role: .destructive) {
                viewModel.resetWindowCache()
            }
        } message: {
            Text("This removes all space window assignments, including dormant windows, and rebuilds one space from windows Debut can currently discover. Settings are preserved.")
        }
        .sheet(isPresented: $showingTelemetryPayload) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Data being shared").font(.title2.bold())
                Text("This is the exact current allowlisted session-summary payload.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(telemetryPayload).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 540, minHeight: 260)
                Text(viewModel.telemetryExcludedData).font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Close") { showingTelemetryPayload = false }.keyboardShortcut(.defaultAction) }
            }.padding(24)
        }
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

            Text("The overlay draws one stage per space. These controls set the stage surface and preview layout.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
                Text("Clear lets more of the wallpaper through. Regular frosts the stage for more contrast over busy backgrounds.")
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
                Text("How large window previews are drawn. Larger previews show fewer windows per row, and a space with too many to fit is scaled back down so its stage stays on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("How far spaces other than the current one shrink. Smaller values make the current space stand out more.")
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
    @State private var selectedQuickSwitchExcludedApp: String = ""

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
                Text("Debut has no Dock icon and only manages windows while it is running, so it is worth starting with your session. Reach it any time from the menu bar icon.")
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

            Text("Click any shortcut to record a replacement. Modifier-free global shortcuts show a warning because they intercept ordinary typing.")
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
                Text("Shortest gap between steps while a cycling shortcut is held, so a fast key-repeat setting cannot race the selection past what you can follow. Off falls back to your system key-repeat rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Space switch duration")
                    Spacer()
                    Text(Self.switchDurationLabel(viewModel.settings.spaceSwitchDuration))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.settings.spaceSwitchDuration,
                    in: AppSettings.minimumSpaceSwitchDuration...AppSettings.maximumSpaceSwitchDuration,
                    step: 0.01
                )
                Text("How long the desktop takes to slide across when switching spaces, per space crossed. Instant cuts straight to the space with no transition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Quick switch exclusions")
                .font(.headline)
                .padding(.top, 8)

            Text("Apps in this list keep shortcuts that overlap Debut's configured quick-switch keys while frontmost. Debut quick switching remains active in other apps.")
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

            Button("Restore Defaults") {
                viewModel.settings.keyBindings.restoreDefaults()
                viewModel.settings.quickSwitchModifiers = .control
                viewModel.settings.quickSwitchSameApplicationModifiers = ShortcutModifiers(
                    control: true,
                    option: true
                )
            }
            .padding(.top, 8)
        }
        .onChange(of: viewModel.settings.quickSwitchModifiers) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.quickSwitchSameApplicationModifiers) { _, _ in
            saveSettings()
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy").font(.title2.bold())
            settingsToggle(
                "Share anonymous usage and performance data",
                isOn: $viewModel.settings.shareAnonymousTelemetry
            )
            Text("Shares one bucketed aggregate session summary and a small number of rate-limited performance anomalies. The choice takes effect immediately and local diagnostics stay available.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("View data being shared…") {
                    telemetryPayload = (try? viewModel.telemetryPayloadPreview()) ?? "Payload unavailable."
                    showingTelemetryPayload = true
                }
                Button("Privacy Policy") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/thomplth/Debut/blob/main/docs/privacy.md")!)
                }
            }
            Text("Anonymous records contain no stable identifier, so they cannot later be located for per-user deletion. Disabling sharing deletes queued unsent records immediately.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        case .appearance: "paintbrush"
        case .selector: "scope"
        case .excludedApps: "eye.slash"
        case .app: "gearshape"
        case .privacy: "hand.raised"
        case .keyboardShortcuts: "keyboard"
        case .troubleshooting: "stethoscope"
        case .about: "info.circle"
        }
    }
}
