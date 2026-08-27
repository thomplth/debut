import Foundation

@MainActor
public protocol ApplicationUpdating: AnyObject {
    func start()
    func checkForUpdates()
}

@MainActor
public final class DisabledApplicationUpdater: ApplicationUpdating {
    public init() {}
    public func start() {}
    public func checkForUpdates() {}
}
