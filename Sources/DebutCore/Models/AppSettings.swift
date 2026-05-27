import Foundation

public struct AppSettings: Codable, Sendable {
    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    public var defaultStageName: String
    public var newStagePlacement: StageInsertPosition
    public var confirmStageDeletion: Bool
    public var animationsEnabled: Bool

    public init() {
        self.launchAtLogin = false
        self.showInMenuBar = true
        self.defaultStageName = "Stage"
        self.newStagePlacement = .below
        self.confirmStageDeletion = true
        self.animationsEnabled = true
    }
}

