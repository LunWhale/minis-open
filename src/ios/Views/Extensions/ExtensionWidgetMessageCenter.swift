//
//  ExtensionWidgetMessageCenter.swift
//  MinisApp
//
//  Routes native → widget messages from extension agent code to the
//  rendered WebView widgets of the same extension.
//
//  Path: extension JS calls minis.api.ui.postMessage(data)
//    → ExtensionJSRuntime.makeUIBridge → Bridge.postToUI
//    → ExtensionRegistry.postToUI closure → ExtensionWidgetMessageCenter.post
//    → all registered receivers for that extension id
//    → ExtensionWebView.Coordinator.sendToWidget
//    → evaluateJavaScript(window.minisBridge._dispatch)
//
//  Receivers register while their ExtensionWebView is alive (Coordinator
//  init) and unregister on deinit, so the message path is real end-to-end
//  (no dead code). Thread-safe via NSLock — register/unregister happen from
//  a deinit (non-main), post happens from the JS bridge (any thread).
//

import Foundation

final class ExtensionWidgetMessageCenter {
    static let shared = ExtensionWidgetMessageCenter()

    /// receiverKey → (extensionID, delivery closure). Key is a stable id the
    /// widget view owns (e.g. "widget:<extID>:<file>").
    private var receivers: [String: (extensionID: String, deliver: ([String: Any]) -> Void)] = [:]
    private let lock = NSLock()

    private init() {}

    /// Register a widget receiver. Returns the key (the view/coordinator
    /// stores it for unregister).
    @discardableResult
    func register(extensionID: String, key: String, deliver: @escaping ([String: Any]) -> Void) -> String {
        lock.lock()
        receivers[key] = (extensionID, deliver)
        lock.unlock()
        return key
    }

    func unregister(key: String) {
        lock.lock()
        receivers.removeValue(forKey: key)
        lock.unlock()
    }

    /// Publish a message to all widgets of `extensionID`.
    func post(to extensionID: String, payload: [String: Any]) {
        lock.lock()
        let targets = receivers.values.filter { $0.extensionID == extensionID }
        lock.unlock()
        for target in targets {
            target.deliver(payload)
        }
    }

    /// Number of live receivers (debug/audit).
    var receiverCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivers.count
    }
}
