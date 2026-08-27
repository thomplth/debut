import Foundation

public final class DebouncedSaver: @unchecked Sendable {
    private let store: StateStore
    private let delay: TimeInterval
    private let queue = DispatchQueue(label: "com.thomplth.Debut.debouncedSave")
    private var workItem: DispatchWorkItem?

    public init(store: StateStore, delay: TimeInterval = 0.5) {
        self.store = store
        self.delay = delay
    }

    public func scheduleSave(_ manager: SpaceManager) {
        workItem?.cancel()
        let item = DispatchWorkItem { [store] in
            try? store.save(manager)
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func flushNow(_ manager: SpaceManager) {
        workItem?.cancel()
        workItem = nil
        queue.sync { [store] in
            try? store.save(manager)
        }
    }
}
