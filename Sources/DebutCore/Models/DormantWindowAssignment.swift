import Foundation

public struct DormantWindowAssignment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID { window.id }
    public let spaceID: UUID
    public let windowIndex: Int
    public let window: SpaceWindow

    public init(spaceID: UUID, windowIndex: Int, window: SpaceWindow) {
        self.spaceID = spaceID
        self.windowIndex = windowIndex
        self.window = window
    }
}
