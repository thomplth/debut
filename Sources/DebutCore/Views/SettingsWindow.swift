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
                        templatesSection
                            .id(SettingsSection.templates)
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
    }

    // MARK: - Sections

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

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App")
                .font(.title2.bold())

            settingsToggle("Launch at login", isOn: $viewModel.settings.launchAtLogin)
            settingsToggle("Show in menu bar", isOn: $viewModel.settings.showInMenuBar)

            HStack {
                Text("Default stage name")
                Spacer()
                TextField("Stage", text: $viewModel.settings.defaultStageName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }

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

            shortcutRow("Open Stage Manager", shortcut: "Cmd+Tab (hold)", configurable: false)
            shortcutRow("Quick switch last app", shortcut: "Cmd+Tab (tap)", configurable: false)
            shortcutRow("Next app", shortcut: "Tab", configurable: true)
            shortcutRow("Previous app", shortcut: "Shift+Tab", configurable: true)
            shortcutRow("Next stage", shortcut: "Option+Tab", configurable: true)
            shortcutRow("Previous stage", shortcut: "Shift+Option+Tab", configurable: true)
            shortcutRow("Jump to stage 1–9", shortcut: "1–9", configurable: true)
            shortcutRow("New stage below", shortcut: "N", configurable: true)
            shortcutRow("New stage above", shortcut: "Shift+N", configurable: true)
            shortcutRow("Delete stage", shortcut: "Delete", configurable: true)
            shortcutRow("Rename stage", shortcut: "R", configurable: true)
            shortcutRow("Save as template", shortcut: "Space", configurable: true)
            shortcutRow("Move app up/down", shortcut: "Arrow Up/Down", configurable: true)
            shortcutRow("Swap stage up/down", shortcut: "Option+Arrow Up/Down", configurable: true)
            shortcutRow("Commit selection", shortcut: "Release Cmd", configurable: false)
            shortcutRow("Discard selection", shortcut: "Esc", configurable: false)
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
        case .templates: "rectangle.stack"
        case .app: "gearshape"
        case .keyboardShortcuts: "keyboard"
        case .about: "info.circle"
        }
    }
}
