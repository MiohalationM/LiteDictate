import Foundation

/// Single `@MainActor` unidirectional projection store delivering immutable `AppStateSnapshot`s to the Thin AppKit UI Shell.
@MainActor
public final class AppStateStore {
    public private(set) var snapshot: AppStateSnapshot
    private var subscribers: [UUID: @MainActor (AppStateSnapshot) -> Void] = [:]

    public init(initialSnapshot: AppStateSnapshot = AppStateSnapshot()) {
        self.snapshot = initialSnapshot
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @MainActor (AppStateSnapshot) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        handler(snapshot)
        return id
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    public func publish(_ newSnapshot: AppStateSnapshot) {
        guard newSnapshot != snapshot else { return }
        snapshot = newSnapshot
        for handler in subscribers.values {
            handler(newSnapshot)
        }
    }
}
