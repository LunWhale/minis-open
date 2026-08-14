import Foundation

// MARK: - Extension Event Bus
//
// Cross-extension pub/sub. Extensions emit events via
// `minis.api.event.emit(name, data)` and any extension with a matching
// `minis.on(name, handler)` receives them. The agent lifecycle events
// (agent_start / agent_end) are fired by AIChatViewModel via
// ExtensionRegistry.emitLifecycleEvent, which also routes into this bus
// so extensions can subscribe to lifecycle events from Lua or JS.
//
// Kept simple and process-local: no persistence, no cross-session events.
final class ExtensionEventBus {
    static let shared = ExtensionEventBus()

    /// event name → subscribers [(extensionID, handlerID)].
    private var subscriptions: [String: [(extensionID: String, handlerID: UUID)]] = [:]
    private let lock = NSLock()

    private init() {}

    /// Subscribe an extension's handler (identified by extensionID +
    /// opaque handler token) to an event.
    func subscribe(_ event: String, extensionID: String, handlerID: UUID) {
        lock.lock()
        subscriptions[event, default: []].append((extensionID, handlerID))
        lock.unlock()
    }

    /// Unsubscribe all handlers of an extension (called on unload).
    func unsubscribeAll(extensionID: String) {
        lock.lock()
        for key in subscriptions.keys {
            subscriptions[key]?.removeAll { $0.extensionID == extensionID }
            if subscriptions[key]?.isEmpty == true {
                subscriptions[key] = nil
            }
        }
        lock.unlock()
    }

    /// Publish an event. Returns the subscriber list so the caller can
    /// invoke each handler's runtime directly (the bus itself is
    /// language-agnostic; ExtensionRegistry dispatches to JS/Lua runtimes).
    func subscribers(for event: String) -> [(extensionID: String, handlerID: UUID)] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions[event] ?? []
    }

    /// Number of live subscriptions (debug).
    var subscriptionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.values.reduce(0) { $0 + $1.count }
    }
}
