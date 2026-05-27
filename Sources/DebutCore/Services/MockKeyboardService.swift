import Foundation

public final class MockKeyboardService: KeyboardService, @unchecked Sendable {
    public private(set) var isRunning: Bool = false
    public private(set) weak var delegate: KeyboardEventDelegate?
    public var events: [DebutKeyEvent] = []

    public init() {}

    public func start(delegate: KeyboardEventDelegate) -> Bool {
        self.delegate = delegate
        self.isRunning = true
        return true
    }

    public func stop() {
        isRunning = false
        delegate = nil
    }

    public func simulateEvent(_ event: DebutKeyEvent) {
        events.append(event)
        delegate?.handleKeyEvent(event)
    }
}
