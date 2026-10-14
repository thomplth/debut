import AppKit
import SwiftUI

extension Notification.Name {
    static let debutSettingsChanged = Notification.Name("DebutSettingsChanged")
}

enum AboutLinks {
    static let github = URL(string: "https://github.com/thomplth/debut")!
    static let bugReport = URL(string: "https://github.com/thomplth/Debut/issues/new?template=bug_report.yml")!
    static let twitter = URL(string: "https://twitter.com/thomplth")!
    static let privacy = URL(string: "https://github.com/thomplth/Debut/blob/main/docs/privacy.md")!
}

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

/// Stops the enclosing split view's sidebar from collapsing. SwiftUI has no setting for it:
/// a constant `columnVisibility` binding still lets View > Hide Sidebar and a divider drag hide it.
private struct UncollapsibleSidebar: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                    for item in controller.splitViewItems where item.behavior == .sidebar {
                        item.canCollapse = false
                    }
                    return
                }
                view = current.superview
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) {}
}

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var selectedSection: SettingsSection = .general
    @State private var showingResetConfirmation = false
    @State private var showingResetAllSettingsConfirmation = false
    /// The page whose settings are about to be restored, while its confirmation shows.
    @State private var restoringSection: SettingsSection?
    private let shortcutRecordingService: (any ShortcutRecordingService)?
    @State private var externallyAppliedSettings: AppSettings?

    public init(
        viewModel: SettingsViewModel = SettingsViewModel(),
        selectedSection: SettingsSection = .general,
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
            .listStyle(.sidebar)
            // The sidebar is the only way between pages, so it can never be hidden (KHA-1093).
            .toolbar(removing: .sidebarToggle)
            .background(UncollapsibleSidebar())
        } detail: {
            VStack(spacing: 0) {
                if selectedSection == .appearance {
                    // Pinned above the scrolling controls, so it stays in view while adjusting.
                    VStack(spacing: 8) {
                        // The picker overlays the title row rather than sharing an HStack with
                        // it: it is taller than the title, and centring the title on it dropped
                        // the title below every other page's (KHA-1070).
                        Text("Appearance")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .trailing) {
                                Picker("Backdrop", selection: $previewBackdrop) {
                                    ForEach(AppearancePreviewBackdrop.allCases) { backdrop in
                                        Text(backdrop.rawValue).tag(backdrop)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        AppearancePreview(
                            settings: viewModel.settings,
                            cardStyle: viewModel.overlayCardStyle,
                            backdrop: previewBackdrop
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                    Divider()
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedSection {
                    case .general: generalSection
                    case .desktops: desktopsSection
                    case .switcher: switcherSection
                    case .appearance:
                        appearanceSection
                        Divider()
                        liquidGlassSection
                        Divider()
                        selectorSection
                    case .shortcuts: keyboardShortcutsSection
                    case .support: supportSection
                    case .about: aboutSection
                    }
                    if !selectedSection.options.isEmpty {
                        restoreDefaultsButton(for: selectedSection)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selectedSection)
            }
            // Every page uses the title bar's height too; the window has no title to clear.
            .ignoresSafeArea(.container, edges: .top)
        }
        .alert("Reset Window Cache?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Cache", role: .destructive) {
                viewModel.resetWindowCache()
            }
        } message: {
            Text("This removes all space window assignments, including dormant windows, and rebuilds assignments from your current macOS desktops. Settings are preserved.")
        }
        .confirmationDialog(
            "Reset All Settings?",
            isPresented: $showingResetAllSettingsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All Settings", role: .destructive) {
                viewModel.restoreDefaultSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets every Debut preference, including ignored apps, shortcuts, Dock visibility, and launch-at-login. Window assignments and system permissions are preserved.")
        }
    }

    // MARK: - Helpers

    private func saveSettings() {
        viewModel.onSettingsChanged?(viewModel.settings)
    }

    // MARK: - Sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.title2.bold())

            Text("App")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle("Launch at login", isOn: $viewModel.settings.launchAtLogin)
                Text("Start Debut when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle("Show in Dock", isOn: $viewModel.settings.showsDockIcon)
                Text("Debut remains available in the menu bar when this is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.crashReportingAvailable {
                VStack(alignment: .leading, spacing: 4) {
                    settingsToggle(
                        "Send crash reports automatically",
                        isOn: $viewModel.settings.sendsCrashReportsAutomatically
                    )
                    Text("Sends crash and hang reports to Sentry without asking. When this is off, Debut asks after a crash and sends nothing else. Reports contain no window titles or screenshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Privacy notice", destination: AboutLinks.privacy)
                        .font(.caption)
                }
            }

            Text("Debut follows the system Reduce Motion setting in System Settings ▸ Accessibility ▸ Display.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            excludedAppsGroup
        }
    }

    private var desktopsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Desktops")
                .font(.title2.bold())

            Text("Choose how Debut moves between macOS desktops.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                settingsToggle(
                    "Faster desktop switching",
                    isOn: Binding(
                        get: { viewModel.settings.features.fasterDesktopSwitching },
                        set: { viewModel.settings.features.setFasterDesktopSwitching($0) }
                    )
                )
                Text("Turn this off to use the original macOS desktop transition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Ways to switch")
                    .font(.headline)

                settingsToggle(
                    "Number keys · Control + 1–9 by default",
                    isOn: $viewModel.settings.features.numberShortcuts
                )
                settingsToggle(
                    "Control + Left / Right Arrow",
                    isOn: $viewModel.settings.features.controlArrows
                )
                VStack(alignment: .leading, spacing: 4) {
                    settingsToggle(
                        "Trackpad desktop swipe",
                        isOn: $viewModel.settings.features.trackpadSwipes
                    )
                    Text("Uses your macOS three- or four-finger desktop gesture. Other gestures keep their normal behavior.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!viewModel.settings.features.fasterDesktopSwitching)

            Divider()

            Text("Timing and feedback")
                .font(.headline)

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

    private var switcherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switcher")
                .font(.title2.bold())

            Text("Control which windows appear and where the switcher opens.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Behavior")
                .font(.headline)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle(
                    "Keep Command–Tab in the current desktop",
                    isOn: $viewModel.settings.features.workspaceIsolation
                )
                Text("Cycle windows on this desktop. Off restores native Command–Tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle("Enable Debut Option–Tab", isOn: $viewModel.settings.features.optionTab)
                Text("Switch between windows across all desktops.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                settingsToggle(
                    "Show window previews",
                    isOn: $viewModel.settings.features.windowPreviews
                )
                Text("Show screenshots in the workspace and all-windows switchers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            Text("Preview freshness")
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

            Text("Switcher timing")
                .font(.headline)
                .padding(.top, 8)

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
                    step: AppSettings.overlayPresentationDelayStep
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Held cycling pace")
                    Spacer()
                    Text(viewModel.settings.heldCycleMinimumInterval > 0
                         ? "\(Int((viewModel.settings.heldCycleMinimumInterval * 1000).rounded())) ms"
                         : "Off")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.settings.heldCycleMinimumInterval, in: 0...0.3, step: 0.01)
                Text("Minimum time between held-key or scroll steps. Off uses your system repeat rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout")
                .font(.headline)

            Text(viewModel.overlayCardStyle == .icons
                ? "Without window previews, windows show as app icons. These settings style the icon switcher; previews keep their own."
                : "These settings style the switcher with window previews; the icon switcher, used without previews, keeps its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Stage corner radius")
                    Spacer()
                    Text("\(viewModel.appearance.stageCornerRadius.formatted(.number.precision(.fractionLength(0...1)))) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.appearance.stageCornerRadius,
                    in: AppSettings.minimumStageCornerRadius...AppSettings.maximumStageCornerRadius,
                    step: 0.5
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(viewModel.overlayCardStyle == .icons ? "Icon size" : "Window size")
                    Spacer()
                    Text("\(Int((viewModel.appearance.stageScale * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.appearance.stageScale,
                    in: AppSettings.minimumStageScale...AppSettings.maximumStageScale,
                    step: AppSettings.stageScaleStep
                )
                Text(viewModel.overlayCardStyle == .icons
                    ? "100% matches the macOS app switcher."
                    : "100% matches the macOS app switcher. Large workspaces scale down automatically to fit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.showsPreviewOnlyAppearance {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("App icon position")
                        Spacer()
                        Picker("", selection: $viewModel.settings.badgePlacement) {
                            Text("Corner").tag(BadgePlacement.corner)
                            Text("Bottom").tag(BadgePlacement.bottom)
                            Text("Title").tag(BadgePlacement.titleRow)
                            Text("Top").tag(BadgePlacement.top)
                        }
                        .pickerStyle(.segmented)
                        // A fixed width squeezed it below its natural width; AppKit then drew it
                        // past its frame, at a different size on each relayout as sliders moved
                        // (KHA-1071).
                        .fixedSize()
                    }
                    Text("Where each preview shows its app's icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("App icon growth")
                        Spacer()
                        Text(viewModel.settings.badgeGrowth.formatted(.number.precision(.fractionLength(2))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $viewModel.settings.badgeGrowth,
                        in: AppSettings.minimumBadgeGrowth...AppSettings.maximumBadgeGrowth,
                        step: 0.05
                    )
                    Text("How the app icon on each preview grows with the window size: 0 keeps it at its native size, 1 grows it with the preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    settingsToggle(
                        "Match each preview to its window",
                        isOn: $viewModel.settings.adaptiveCardSizing
                    )
                    Text("Use each window’s proportions up to the display-shaped card size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Inactive stage scale")
                    Spacer()
                    Text("\(Int((viewModel.appearance.inactiveStageScale * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.appearance.inactiveStageScale, in: 0.4...1.0, step: 0.05)
                Text("Size of the other spaces relative to the selected space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liquidGlassSection: some View {
        let usesNativeGlass = viewModel.appearance.glassStyle.usesDockGlass
        let usesHalo = viewModel.appearance.glassStyle != .regular
        return VStack(alignment: .leading, spacing: 12) {
            Text("Liquid Glass")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Material")
                    Spacer()
                    Picker("", selection: $viewModel.appearance.glassStyle) {
                        Text("Native").tag(GlassStyle.native)
                        Text("Clear").tag(GlassStyle.clear)
                        Text("Regular").tag(GlassStyle.regular)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text("Native matches the macOS app switcher. Regular adds contrast over busy wallpapers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            percentSlider(
                "Rim",
                value: $viewModel.appearance.glassRimStrength,
                in: AppSettings.minimumGlassRimStrength...AppSettings.maximumGlassRimStrength
            )
            .disabled(!usesNativeGlass)

            percentSlider(
                "Edge refraction",
                value: $viewModel.appearance.glassEdgeRefraction,
                in: AppSettings.minimumGlassEdgeRefraction...AppSettings.maximumGlassEdgeRefraction
            )
            .disabled(!usesNativeGlass)

            VStack(alignment: .leading, spacing: 4) {
                percentSlider("Title halo", value: $viewModel.appearance.titleHaloStrength, in: 0...1)
                    .disabled(!usesHalo)
                HStack {
                    Text("Title halo size")
                    Spacer()
                    Text("\(viewModel.appearance.titleHaloSize.formatted(.number.precision(.fractionLength(0...2)))) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.appearance.titleHaloSize,
                    in: AppSettings.minimumTitleHaloSize...AppSettings.maximumTitleHaloSize,
                    step: 0.25
                )
                .disabled(!usesHalo || viewModel.appearance.titleHaloStrength == 0)
                Text("A glow behind window titles in the opposite colour, so they stay legible over clear glass. Regular glass has none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // macOS 26 cannot draw a fixed tint, so its glass always follows the system's.
            if AppSettings.supportsFixedGlassTint {
                VStack(alignment: .leading, spacing: 4) {
                    settingsToggle(
                        "Follow system tint",
                        isOn: $viewModel.appearance.followsSystemGlassTint
                    )
                    if !viewModel.appearance.followsSystemGlassTint {
                        percentSlider("Tint", value: $viewModel.appearance.glassTintAmount, in: 0...1)
                    }
                    Text("System Settings › Appearance › Liquid Glass sets the system tint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !usesNativeGlass {
                Text("Rim and edge refraction apply to the Native material.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percentSlider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.05)
        }
    }

    private var selectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.showsPreviewOnlyAppearance ? "Preview & selection highlight" : "Selection highlight")
                .font(.headline)

            Text("The selected window sits on a highlight that darkens the glass in light mode and lightens it in dark mode, as the macOS app switcher does. It hides while you drag a window.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            percentSlider(
                "Strength",
                value: $viewModel.appearance.selectionHighlightStrength,
                in: AppSettings.minimumSelectionHighlightStrength...AppSettings.maximumSelectionHighlightStrength
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Surrounding space")
                    Spacer()
                    Text("\(Int(viewModel.appearance.selectorOutset.rounded())) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.appearance.selectorOutset,
                    in: AppSettings.minimumSelectorOutset...AppSettings.maximumSelectorOutset,
                    step: 1
                )
            }

            if viewModel.showsPreviewOnlyAppearance {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Corner radius")
                        Spacer()
                        Text("\(Int(viewModel.settings.previewCornerRadius.rounded())) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $viewModel.settings.previewCornerRadius,
                        in: AppSettings.minimumPreviewCornerRadius...AppSettings.maximumPreviewCornerRadius,
                        step: 1
                    )
                    Text("Rounds every preview, selected or not. The highlight keeps the same curve around it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A per-window viewing choice, not a Debut setting.
    @AppStorage("appearancePreviewBackdrop") private var previewBackdrop = AppearancePreviewBackdrop.highContrast
    @State private var selectedAppToExclude: String = ""

    private var excludedAppsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ignored apps")
                .font(.headline)

            Text("Ignored apps do not appear in Debut and do not trigger desktop switches.")
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
                        if StageMotion.showsAppIcon(bundleID: bundleID) {
                            AppIconImage(bundleID: bundleID, name: bundleID, iconSize: 20)
                                .frame(width: 20, height: 20)
                        }
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

    static func switchDurationLabel(_ duration: TimeInterval) -> String {
        duration <= 0 ? "Instant" : "\(Int((duration * 1000).rounded())) ms"
    }

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts")
                .font(.title2.bold())

            Text("Click a shortcut to change it, or press Delete while recording to disable it. Desktop navigation switches are in Desktops.")
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

            Text("Move focused window")
                .font(.headline)
                .padding(.top, 4)

            ForEach(KeyAction.focusedWindowMoveActions, id: \.self) { action in
                ShortcutRecorderRow(
                    action: action,
                    keyBindings: $viewModel.settings.keyBindings,
                    recordingService: shortcutRecordingService
                )
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
                        Text(modifiers == .disabled ? "Disabled" : "\(modifiers.displayString)+1–9")
                            .tag(modifiers)
                    }
                }
                .frame(width: 220)
            }

            HStack {
                Text("Switch to space with current app")
                Spacer()
                Picker("", selection: $viewModel.settings.quickSwitchSameApplicationModifiers) {
                    ForEach(ShortcutModifiers.choices, id: \.self) { modifiers in
                        Text(modifiers == .disabled ? "Disabled" : "\(modifiers.displayString)+1–9")
                            .tag(modifiers)
                    }
                }
                .frame(width: 220)
            }

            Text("Space Manager session")
                .font(.headline)
                .padding(.top, 8)

            Text("These keys are pressed while the modifier from the activation shortcut remains held. H/J/K/L move the selector; arrow keys move windows instead.")
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

        }
        .onChange(of: viewModel.settings.quickSwitchModifiers) { _, _ in saveSettings() }
        .onChange(of: viewModel.settings.quickSwitchSameApplicationModifiers) { _, _ in
            saveSettings()
        }
    }

    /// Resets only this page's settings, after a confirmation that names the page.
    private func restoreDefaultsButton(for section: SettingsSection) -> some View {
        HStack {
            Spacer()
            Button("Restore \(section.rawValue) Defaults…", role: .destructive) {
                restoringSection = section
            }
        }
        .padding(.top, 8)
        .alert(
            "Restore \(restoringSection?.rawValue ?? "") Defaults?",
            isPresented: Binding(
                get: { restoringSection != nil },
                set: { if !$0 { restoringSection = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { restoringSection = nil }
            Button("Restore Defaults", role: .destructive) {
                if let section = restoringSection {
                    viewModel.restoreDefaults(for: section)
                }
                restoringSection = nil
            }
        } message: {
            Text("This resets the settings on the \(restoringSection?.rawValue ?? "") page to their defaults. Settings on other pages are kept.")
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Support")
                .font(.title2.bold())

            Text("Bug reports")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Report a bug")
                    Text("Opens a public issue. A GitHub account is required to submit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("Report a Bug…", destination: AboutLinks.bugReport)
                    .buttonStyle(.bordered)
            }

            Divider()

            Text("Troubleshooting")
                .font(.headline)

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

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("All settings")
                    Text("Restore Debut preferences to their defaults. Window assignments are preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset All Settings…", role: .destructive) {
                    showingResetAllSettingsConfirmation = true
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(spacing: 28) {
            aboutIdentity

            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        aboutVersion
                        Spacer(minLength: 0)
                        aboutUpdateButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        aboutVersion
                        aboutUpdateButton
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)

                Divider().padding(.horizontal, 20)

                HStack(spacing: 0) {
                    aboutLink("GitHub", subtitle: "Source code", destination: AboutLinks.github)
                    Divider().frame(height: 32)
                    aboutLink("Contact", subtitle: "Get in touch", destination: AboutLinks.twitter)
                }
                .padding(8)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var aboutIdentity: some View {
        VStack(spacing: 12) {
            Group {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                } else {
                    Image(nsImage: DebutGlyph.image(size: 96))
                        .renderingMode(.template)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, height: 96)
                }
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Debut")
                    .font(.system(size: 30, weight: .bold))
                Text("Space-based workspace manager for macOS")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutVersion: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Version")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(DebutCore.version)
                .font(.body.weight(.medium))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var aboutUpdateButton: some View {
        Button("Check for Updates…") {
            viewModel.checkForUpdates()
        }
        .controlSize(.large)
        .fixedSize()
    }

    private func aboutLink(_ title: String, subtitle: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func settingsToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 16)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
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
        case .general: "gearshape"
        case .desktops: "rectangle.3.group"
        case .switcher: "macwindow.on.rectangle"
        case .appearance: "paintbrush"
        case .shortcuts: "keyboard"
        case .support: "questionmark.circle"
        case .about: "info.circle"
        }
    }
}
