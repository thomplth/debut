import CoreGraphics
import Foundation

/// A transient view of real desktops. Filtering this copy never changes live assignments.
public struct TutorialSwitcherScope: Sendable, Equatable {
    public let presentationID = UUID()
    public let lessonWindowID: CGWindowID
    public let target: OnboardingTarget
    public let practice: OnboardingPractice
    public var windowIDs: Set<CGWindowID> { [lessonWindowID, target.windowID] }
    public var desktopIndices: [Int] { Set([target.originDesktop, target.destinationDesktop]).sorted() }

    public init(lessonWindowID: CGWindowID, target: OnboardingTarget, practice: OnboardingPractice) {
        self.lessonWindowID = lessonWindowID
        self.target = target
        self.practice = practice
    }

    public func filtering(_ manager: SpaceManager) -> SpaceManager {
        var result = manager
        for window in manager.allSpaces.flatMap(\.windows) where !windowIDs.contains(window.windowID) {
            result.removeLiveWindowFromAllSpaces(windowID: window.windowID)
        }
        return result
    }

    public func coachmark(mode: OverlayMode, selectedWindowID: CGWindowID?, selectedDesktop: Int, targetDesktop: Int?) -> TutorialCoachmark {
        let modifier = practice == .allWindows ? "Option" : "Command"
        let title: String = switch practice {
        case .workspace: "Switch windows"
        case .desktop: "Switch desktops"
        case .moveWindow: "Move a window"
        case .allWindows: "Window previews"
        }
        let action: String
        let detail: String
        if targetDesktop == nil {
            action = "Press Esc and try again when the next lesson is ready."
            detail = "Preparing the tutorial window."
        } else if (mode == .altTab) != (practice == .allWindows) {
            action = "Press Esc, then hold \(modifier) and press Tab."
            detail = "Use \(modifier)-Tab for this exercise."
        } else if practice == .desktop && selectedDesktop != target.destinationDesktop {
            action = "Keep Command held. Hold Option and press Tab."
            detail = "Select Desktop \(target.destinationDesktop + 1), where “\(target.title)” is waiting."
        } else if mode == .stages, let targetDesktop, selectedDesktop != targetDesktop {
            action = "Keep Command held. Hold Option and press Tab."
            detail = "Return to Desktop \(targetDesktop + 1) to select “\(target.title)”."
        } else if selectedWindowID != target.windowID {
            action = "Keep \(modifier) held. Press Tab to select “\(target.title)”."
            detail = practice == .desktop ? "Release Option first. Stay on Desktop \(target.destinationDesktop + 1)." : "Only tutorial windows are shown."
        } else if practice == .moveWindow && targetDesktop != target.destinationDesktop {
            action = "Keep Command held. Press \(target.destinationDesktop > target.originDesktop ? "Down Arrow" : "Up Arrow")."
            detail = "Move “\(target.title)” to Desktop \(target.destinationDesktop + 1)."
        } else {
            action = "Release \(modifier) to open “\(target.title)”."
            detail = practice == .workspace ? "This window becomes your next lesson." : "You will land on Desktop \(target.destinationDesktop + 1)."
        }
        return .init(title: title, action: action, detail: detail)
    }
}

public struct TutorialCoachmark: Sendable, Equatable {
    public let title: String
    public let action: String
    public let detail: String
}
