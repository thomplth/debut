import Foundation

public struct DormantWindowAssignment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID { window.id }
    public let stageID: UUID
    public let windowIndex: Int
    public let window: StageWindow

    public init(stageID: UUID, windowIndex: Int, window: StageWindow) {
        self.stageID = stageID
        self.windowIndex = windowIndex
        self.window = window
    }
}
