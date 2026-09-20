import AppKit
import CoreGraphics
import SwiftUI

/// A desktop movement macOS has confirmed, reduced to the copy and display placement the
/// transient indicator needs. Positions are one-based at this boundary so neither the view nor
/// accessibility has to reinterpret a desktop index.
public struct DesktopSwitchIndicatorPresentation: Equatable, Sendable {
    public let stackID: String
    public let displayID: CGDirectDisplayID?
    public let displayName: String
    public let desktopPosition: Int
    public let desktopCount: Int

    public init(
        stackID: String,
        displayID: CGDirectDisplayID?,
        displayName: String,
        desktopPosition: Int,
        desktopCount: Int
    ) {
        self.stackID = stackID
        self.displayID = displayID
        self.displayName = displayName
        self.desktopPosition = desktopPosition
        self.desktopCount = desktopCount
    }

    public var title: String { "Desktop \(desktopPosition) of \(desktopCount)" }

    public var accessibilityLabel: String {
        "\(displayName), desktop \(desktopPosition) of \(desktopCount)"
    }
}

/// Holds the last desktop identity WindowServer confirmed. The SpaceManager is intentionally not
/// the baseline: Debut updates that model optimistically when it requests a switch, before the
/// Dock has moved, which would make the eventual confirmation look unchanged.
struct DesktopSwitchIndicatorTracker {
    private var confirmedDesktopIDs: [String: CGSSpaceID] = [:]

    mutating func seed(with topology: SpaceTopology) {
        confirmedDesktopIDs = Self.desktopIDs(in: topology)
    }

    mutating func recordConfirmedChanges(
        in topology: SpaceTopology
    ) -> [DesktopSwitchIndicatorPresentation] {
        let previous = confirmedDesktopIDs
        confirmedDesktopIDs = Self.desktopIDs(in: topology)

        return topology.stacks.compactMap { stack in
            guard let currentID = stack.currentDesktopID,
                  let previousID = previous[stack.id],
                  currentID != previousID,
                  let index = stack.desktopIDs.firstIndex(of: currentID)
            else { return nil }
            return DesktopSwitchIndicatorPresentation(
                stackID: stack.id,
                displayID: stack.displayID,
                displayName: stack.displayName,
                desktopPosition: index + 1,
                desktopCount: stack.desktopIDs.count
            )
        }
    }

    private static func desktopIDs(in topology: SpaceTopology) -> [String: CGSSpaceID] {
        topology.stacks.reduce(into: [:]) { result, stack in
            result[stack.id] = stack.currentDesktopID
        }
    }
}

public enum DesktopSwitchIndicatorPolicy {
    public static func presentations(
        for changes: [DesktopSwitchIndicatorPresentation],
        isEnabled: Bool,
        overlayVisible: Bool
    ) -> [DesktopSwitchIndicatorPresentation] {
        guard isEnabled, !overlayVisible else { return [] }
        return changes
    }
}

public struct DesktopSwitchIndicatorView: View {
    public let presentation: DesktopSwitchIndicatorPresentation

    public init(presentation: DesktopSwitchIndicatorPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        Text(presentation.title)
            .font(.system(.callout, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// A small nonactivating panel that shares the stage overlay's top-center header position. A
/// generation guards its delayed dismissal so another confirmed hop can replace the label and
/// restart the one-second dwell without an older timer hiding it.
@MainActor
public final class DesktopSwitchIndicatorWindow: NSPanel {
    public static let visibleDuration: TimeInterval = 1.0
    public static let fadeDuration: TimeInterval = 0.15
    public static let topPadding: CGFloat = 18

    private var presentationGeneration: UInt = 0
    private var dismissal: DispatchWorkItem?

    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hidesOnDeactivate = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    public static func frame(
        screenFrame: CGRect,
        topContentInset: CGFloat,
        indicatorSize: CGSize
    ) -> CGRect {
        CGRect(
            x: screenFrame.midX - indicatorSize.width / 2,
            y: screenFrame.maxY - topContentInset - topPadding - indicatorSize.height,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
    }

    @discardableResult
    func beginPresentation() -> UInt {
        dismissal?.cancel()
        presentationGeneration &+= 1
        return presentationGeneration
    }

    public func present(
        _ presentation: DesktopSwitchIndicatorPresentation,
        on screen: NSScreen,
        visibleDuration: TimeInterval = visibleDuration
    ) {
        let generation = beginPresentation()
        let hostingView = NSHostingView(
            rootView: DesktopSwitchIndicatorView(presentation: presentation)
        )
        let fittingSize = hostingView.fittingSize
        let size = CGSize(
            width: max(1, fittingSize.width),
            height: max(1, fittingSize.height)
        )
        setFrame(Self.frame(
            screenFrame: screen.frame,
            topContentInset: screen.overlayTopContentInset,
            indicatorSize: size
        ), display: false)
        hostingView.frame = CGRect(origin: .zero, size: size)
        contentView = hostingView

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            _ = self?.dismissIfCurrent(generation: generation, animated: true)
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, visibleDuration),
            execute: work
        )
    }

    @discardableResult
    func dismissIfCurrent(generation: UInt, animated: Bool) -> Bool {
        guard generation == presentationGeneration else { return false }
        dismissal?.cancel()
        dismissal = nil
        guard animated else {
            alphaValue = 0
            orderOut(nil)
            contentView = nil
            return true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == generation else { return }
                self.orderOut(nil)
                self.contentView = nil
            }
        }
        return true
    }

    public func hideImmediately() {
        _ = dismissIfCurrent(generation: presentationGeneration, animated: false)
    }
}
