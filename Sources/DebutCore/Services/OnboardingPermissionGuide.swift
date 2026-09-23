import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class OnboardingPermissionGuide {
    private let permissionClient: SystemOnboardingPermissionClient
    private var panel: NSPanel?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var positioningRetries: [DispatchWorkItem] = []
    private var permission: OnboardingPermission?
    private var requiresRelaunch = false
    private var onReturn: (() -> Void)?
    private var onCancel: ((OnboardingPermission) -> Void)?

    init(permissionClient: SystemOnboardingPermissionClient) {
        self.permissionClient = permissionClient
    }

    func present(
        permission: OnboardingPermission,
        onReturn: @escaping () -> Void,
        onCancel: @escaping (OnboardingPermission) -> Void
    ) {
        dismiss()
        self.permission = permission
        self.onReturn = onReturn
        self.onCancel = onCancel
        installObservers()
        permissionClient.openSettings(for: permission)
        for delay in [0.2, 0.55, 1.1, 2.0, 3.5] {
            let retry = DispatchWorkItem { [weak self] in self?.positionOrShowPanel() }
            positioningRetries.append(retry)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
        }
    }

    func update(permissionState: OnboardingPermissionState, requiresRelaunch: Bool) {
        guard let permission else { return }
        self.requiresRelaunch = permission == .screenRecording && requiresRelaunch
        let isGranted = permission == .accessibility
            ? permissionState.accessibilityGranted
            : permissionState.screenRecordingGranted
        if isGranted && !self.requiresRelaunch {
            dismiss()
            return
        }
        updatePanelContent()
    }

    func dismiss() {
        for retry in positioningRetries { retry.cancel() }
        positioningRetries.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.contentView = nil
        panel?.close()
        panel = nil
        permission = nil
        requiresRelaunch = false
        onReturn = nil
        onCancel = nil
    }

    private func installObservers() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionOrShowPanel() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionOrShowPanel() }
        }
    }

    private func positionOrShowPanel() {
        guard permission != nil, let frame = Self.systemSettingsFrame() else { return }
        let targetFrame = Self.panelFrame(near: frame)
        if panel == nil {
            let panel = NSPanel(
                contentRect: targetFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            self.panel = panel
            updatePanelContent()
            panel.setFrame(targetFrame, display: true)
            panel.orderFrontRegardless()
            return
        }
        panel?.setFrame(targetFrame, display: true, animate: true)
    }

    private func updatePanelContent() {
        guard let panel, let permission else { return }
        panel.contentView = NSHostingView(rootView: PermissionGuideView(
            permission: permission,
            requiresRelaunch: requiresRelaunch,
            onReturn: { [weak self] in
                guard let self else { return }
                let action = self.onReturn
                self.dismiss()
                action?()
            },
            onRestart: { [weak self] in
                guard let self else { return }
                self.permissionClient.restartDebut()
            },
            onCancel: { [weak self] in
                guard let self, let permission = self.permission else { return }
                let action = self.onCancel
                self.dismiss()
                action?(permission)
            }
        ))
    }

    private static func systemSettingsFrame() -> CGRect? {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systempreferences"
        }) else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 400, height > 300 else { continue }
            let screenFrame = CGRect(x: x, y: y, width: width, height: height)
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    continue
                }
                let displayFrame = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
                guard displayFrame.intersects(screenFrame) else { continue }
                let localX = x - displayFrame.minX
                let localY = y - displayFrame.minY
                return CGRect(
                    x: screen.frame.minX + localX,
                    y: screen.frame.maxY - localY - height,
                    width: width,
                    height: height
                )
            }
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(screenFrame) }) {
                return CGRect(x: x, y: screen.frame.maxY - y - height, width: width, height: height)
            }
        }
        return nil
    }

    private static func panelFrame(near settingsFrame: CGRect) -> CGRect {
        let size = CGSize(width: 420, height: 154)
        let gap: CGFloat = 12
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(settingsFrame) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let below = settingsFrame.minY - size.height - gap
        let above = settingsFrame.maxY + gap
        let y = below >= visibleFrame.minY + 12 ? below : min(above, visibleFrame.maxY - size.height - 12)
        let x = min(max(settingsFrame.minX + 16, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private struct PermissionGuideView: View {
    let permission: OnboardingPermission
    let requiresRelaunch: Bool
    let onReturn: () -> Void
    let onRestart: () -> Void
    let onCancel: () -> Void

    private var appURL: URL { Bundle.main.bundleURL }
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Debut"
    }
    private var instruction: String {
        requiresRelaunch
            ? "Quit and reopen Debut to use Screen Recording. Setup will continue there."
            : "Drag Debut into the list, or turn it on if it's already listed."
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: requiresRelaunch ? "arrow.clockwise" : "arrow.up")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text(instruction)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close permission guide")
            }

            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable().frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text(appName).font(.system(size: 14, weight: .semibold))
                Spacer()
                if requiresRelaunch {
                    Button("Restart Debut", action: onRestart)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Drag into the list above")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 52)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onDrag { NSItemProvider(object: appURL as NSURL) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drag \(appName) into the System Settings permission list")

            HStack {
                Button("Return to Debut", action: onReturn)
                    .buttonStyle(.borderless)
                Spacer()
                Text(permission == .accessibility ? "Accessibility" : "Screen Recording")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(15)
        .frame(width: 420, height: 154)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12)))
    }
}
