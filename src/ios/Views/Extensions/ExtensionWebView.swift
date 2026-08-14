//
//  ExtensionWebView.swift
//  MinisApp
//
//  Host for extension UI widgets (.minisx `ui/widget.html` rendered in a
//  WKWebView). Injects `window.minisBridge` for bidirectional messaging:
//
//    window.minisBridge.postMessage(data)   // widget → native
//    window.minisBridge.onMessage = fn      // native → widget
//    window.minisBridge.onReady = fn        // called after bridge is injected
//
//  Native → widget delivery (from minis.api.ui.postMessage) goes through
//  ExtensionWidgetMessageCenter → sendToWidget → evaluateJavaScript, so the
//  path is live end-to-end.
//

import SwiftUI
import WebKit

// MARK: - SwiftUI Wrapper

/// SwiftUI host for one extension widget. `extensionID` scopes the bridge;
/// `htmlURL` points at the unpacked ui/widget.html.
struct ExtensionWebView: UIViewRepresentable {
    let extensionID: String
    let htmlURL: URL
    /// Widget → native messages (extensionID, payload).
    var onMessage: ((String, [String: Any]) -> Void)?

    func makeCoordinator() -> Coordinator {
        // Stable receiver key so the widget message center can route native →
        // widget messages to this widget instance.
        let key = "widget:\(extensionID):\(htmlURL.lastPathComponent)"
        return Coordinator(extensionID: extensionID, receiverKey: key, onMessage: onMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()

        // Bridge injection: define window.minisBridge before page scripts run.
        let bridgeJS = """
        (function() {
          if (window.minisBridge) return;
          var queue = [];
          window.minisBridge = {
            postMessage: function(data) {
              window.webkit.messageHandlers.minisBridge.postMessage(
                typeof data === 'string' ? data : JSON.stringify(data)
              );
            },
            _nativeQueue: queue,
            onMessage: null,
            onReady: function(fn) { if (typeof fn === 'function') { this._onReady = fn; } },
            _flush: function() {
              if (window.minisBridge._onReady) {
                var q = window.minisBridge._nativeQueue;
                window.minisBridge._nativeQueue = [];
                q.forEach(function(m) { window.minisBridge._dispatch(m); });
              }
            },
            _dispatch: function(m) {
              if (window.minisBridge.onMessage) window.minisBridge.onMessage(m);
            }
          };
          window.webkit.messageHandlers.minisBridgeReady.postMessage('ready');
        })();
        """
        let script = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContent.addUserScript(script)
        userContent.add(context.coordinator, name: "minisBridge")
        userContent.add(context.coordinator, name: "minisBridgeReady")
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Give the coordinator a handle so sendToWidget can reach the webview.
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url?.absoluteString != htmlURL.absoluteString {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
        context.coordinator.webView = webView
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let extensionID: String
        let receiverKey: String
        var onMessage: ((String, [String: Any]) -> Void)?
        /// Live handle to the backing WKWebView (set in makeUIView/updateUIView).
        weak var webView: WKWebView?

        init(extensionID: String, receiverKey: String, onMessage: ((String, [String: Any]) -> Void)?) {
            self.extensionID = extensionID
            self.receiverKey = receiverKey
            self.onMessage = onMessage
            super.init()
            // Register with the widget message center so native → widget
            // messages (from minis.api.ui.postMessage) reach this widget.
            let center = ExtensionWidgetMessageCenter.shared
            center.register(extensionID: extensionID, key: receiverKey) { [weak self] payload in
                self?.sendToWidget(payload: payload)
            }
        }

        deinit {
            ExtensionWidgetMessageCenter.shared.unregister(key: receiverKey)
        }

        /// Deliver a native → widget message (from the widget message center).
        /// Serializes to JSON and dispatches through window.minisBridge._dispatch.
        func sendToWidget(payload: [String: Any]) {
            guard let webView,
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "if (window.minisBridge) { window.minisBridge._dispatch(\(json)); }"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "minisBridgeReady" {
                // Widget page signaled ready — native could flush here.
                return
            }
            guard message.name == "minisBridge", let body = message.body as? String else { return }
            // Try JSON object, else pass raw string.
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onMessage?(extensionID, obj)
            } else {
                onMessage?(extensionID, ["text": body])
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Flush any native-queued messages after the page finished loading.
            webView.evaluateJavaScript("if (window.minisBridge) window.minisBridge._flush();", completionHandler: nil)
        }
    }
}

// MARK: - Widget Permission Gate

/// UI-side permission check for rendering extension widgets. Declared
/// "ui" permission in manifest.json is required; reuse PermissionGate so
/// first use surfaces the standard confirm dialog.
enum ExtensionWidgetGate {
    static func canRender(extensionID: String, permissions: [String]) async -> Bool {
        guard permissions.contains("ui") else {
            AppLogger(category: "ExtensionWidget").error("\(extensionID) missing 'ui' permission")
            return false
        }
        return await PermissionGate.request("ui", extensionID: extensionID)
    }
}
