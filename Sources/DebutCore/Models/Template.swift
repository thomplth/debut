import Foundation

public struct Template: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var appBundleIDs: [String]

    public init(name: String, appBundleIDs: [String]) {
        self.id = UUID()
        self.name = name
        self.appBundleIDs = appBundleIDs
    }

    public static func == (lhs: Template, rhs: Template) -> Bool {
        lhs.id == rhs.id
    }
}
