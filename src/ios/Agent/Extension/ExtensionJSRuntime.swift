import Foundation
import JavaScriptCore

// MARK: - Extension JS Runtime

/// Hosts a single extension's agent-side JavaScript (tools, commands, hooks)
/// in a JavaScriptCore context with a `minis` global API. Each extension gets
/// its own isolated context so extensions can't touch each other's globals.
///
/// The `minis` API mirrors what the manifest declares:
/// ```js
/// minis.registerTool({ name, description, parameters, execute })
/// minis.registerCommand({ name, handler })
/// minis.on("agent_start" | "agent_end" | "tool_call" | "tool_result", (event) => {})
/// minis.api.shell(cmd, {timeout})            → Promise<string>
/// minis.api.file.read / write / list / delete → Promise<string>
/// minis.api.offload(name, args)              → Promise<any>
/// minis.api.permission.request(kind)         → Promise<boolean>
/// minis.api.ui(data) / ui.postMessage(data)  → broadcast to UI widgets
/// minis.api.event.emit(name, data)
/// minis.api.request.intercept(fn)            → rewrite outgoing AI requests
/// minis.api.settings.get / set / all
/// minis.log(...)                             → variadic (strings, objects, arrays)
/// minis.store.get/set(key, value)            → small KV persistence
/// minis.http.fetch(url, {method, headers, body}) → Promise<{status, headers, body}>
/// ```
/// Handler return values may be plain values or Promises (awaited).
/// ```
final class ExtensionJSRuntime {
    private let context: JSContext
    private let extensionID: String
    private let bridge: Bridge

    /// Native callbacks the JS bridge routes to.
    struct Bridge {
        var shell: @Sendable (String, [String: Any]) async -> (String, Bool)
        var fileRead: @Sendable (String) async -> (String, Bool)
        var fileWrite: @Sendable (String, String, Bool) async -> (String, Bool)
        var fileList: @Sendable (String) async -> (String, Bool)
        var fileDelete: @Sendable (String) async -> (String, Bool)
        var requestPermission: @Sendable (String) async -> Bool
        /// Check whether the extension declared a permission in its manifest.
        var hasPermission: @Sendable (String) -> Bool
        var postToUI: @Sendable (String, [String: Any]) -> Void
        var emitEvent: @Sendable (String, [String: Any]) -> Void
        /// Read one declared setting value (or its default).
        var settingsGet: @Sendable (String, String) -> Any?
        /// Persist one declared setting value.
        var settingsSet: @Sendable (String, String, Any) -> Void
        /// All declared settings with current values.
        var settingsAll: @Sendable (String) -> [String: Any]
    }

    init(extensionID: String, bridge: Bridge) {
        self.extensionID = extensionID
        self.bridge = bridge
        self.context = JSContext()!
        installMinisAPI()
    }

    // MARK: - Evaluation

    /// Evaluate a JS file from the extension bundle.
    func evaluateScript(_ js: String, fileName: String) throws {
        let result = context.evaluateScript(js, withSourceURL: URL(fileURLWithPath: fileName))
        if context.exception != nil {
            let msg = context.exception.toString() ?? "unknown JS error"
            context.exception = nil
            throw ExtensionError.runtime("\(fileName): \(msg)")
        }
        _ = result
    }

    // MARK: - Tool registry

    /// Registered tools collected from `minis.registerTool` calls.
    private(set) var registeredTools: [RegisteredTool] = []
    private(set) var registeredCommands: [RegisteredCommand] = []
    private(set) var eventHandlers: [String: [JSValue]] = [:]

    /// Outgoing provider-request interceptors registered via
    /// `minis.api.request.intercept`. Applied by ExtensionRegistry right
    /// before a model request is sent.
    struct RequestInterceptor {
        let id: String
        let name: String
        let handler: JSValue  // JS function: (req) => patch | Promise<patch>
    }
    private(set) var requestInterceptors: [RequestInterceptor] = []

    struct RegisteredTool {
        let name: String
        let description: String
        let execute: JSValue  // JS function
    }

    struct RegisteredCommand {
        let name: String
        let handler: JSValue  // JS function
    }

    /// Execute a registered slash command. Returns output string.
    /// Handlers may return a plain value or a Promise (awaited).
    func callCommand(_ command: RegisteredCommand, args: [String]) async -> (String, Bool) {
        let jsArgs = JSValue(object: args, in: context)!
        guard let result = command.handler.call(withArguments: [jsArgs]) else {
            return (Self.thrownException(context), true)
        }
        let outcome = await resolveJSResult(result)
        ExtensionLogStore.shared.log(
            "command \(command.name) \(outcome.1 ? "failed" : "ok")",
            level: outcome.1 ? .warn : .info,
            category: "ExtCmd"
        )
        return outcome
    }

    /// Fire an event to all registered `minis.on(event, handler)` hooks.
    /// Handlers run synchronously on the JS thread; results are logged.
    func emitEvent(_ event: String, data: [String: Any]) {
        guard let handlers = eventHandlers[event], !handlers.isEmpty else { return }
        let jsData = JSValue(object: data, in: context)!
        for handler in handlers {
            guard let result = handler.call(withArguments: [jsData]) else { continue }
            if result.isString, let str = result.toString(), !str.isEmpty {
                AppLogger(category: "ExtHook[\(event)]").info("\(str)")
            }
        }
    }


    /// Execute a registered tool. `args` is bridged to JS, result string
    /// returned (or an error string). Handlers may return a Promise (awaited).
    func callTool(_ tool: RegisteredTool, args: [String: Any]) async -> (String, Bool) {
        let jsArgs = JSValue(object: args, in: context)!
        guard let result = tool.execute.call(withArguments: [jsArgs]) else {
            return (Self.thrownException(context), true)
        }
        let outcome = await resolveJSResult(result)
        ExtensionLogStore.shared.log(
            "tool \(tool.name) \(outcome.1 ? "failed" : "ok")",
            level: outcome.1 ? .warn : .info,
            category: "ExtTool"
        )
        return outcome
    }

    /// Unwrap the model-facing extension-tool call payload into the argument
    /// object the extension's handler expects.
    ///
    /// The agent tool schema declares `{ tool_title, args }` for every
    /// extension tool (`args` is a JSON *string* so any argument shape can
    /// pass through, and `tool_title` is a UI-only summary). The registry
    /// calls this before dispatch so `execute(args)` receives only the
    /// extension's own arguments.
    ///
    /// - `args` as a JSON string → parsed object
    /// - `args` as an object     → used as-is
    /// - `args` present but not an object → empty arguments
    /// - no `args` property      → the raw object minus `tool_title`
    ///   (keeps direct callers and lenient models working)
    static func unwrapToolCallArgs(_ raw: [String: Any]) -> [String: Any] {
        guard let inner = raw["args"] else {
            var out = raw
            out.removeValue(forKey: "tool_title")
            return out
        }
        if let dict = inner as? [String: Any] { return dict }
        if let s = inner as? String {
            if let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parsed
            }
            return [:]
        }
        return [:]
    }

    // MARK: - Provider request interception

    /// Apply this extension's registered request interceptors, in
    /// registration order. Each handler receives
    /// `{provider, model, sessionId?, url, method, headers, body?}` and may
    /// mutate it and/or return a patch object with any of `url`, `method`,
    /// `headers`, `body`. Returns the possibly-rewritten request.
    func applyRequestInterceptors(
        to request: URLRequest,
        provider: String,
        model: String,
        sessionId: String?
    ) async -> URLRequest {
        guard !requestInterceptors.isEmpty else { return request }

        var urlString = request.url?.absoluteString ?? ""
        var method = request.httpMethod ?? "GET"
        var headers = request.allHTTPHeaderFields ?? [:]
        var bodyString: String? = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        // Binary bodies (multipart image edits, etc.) can't be represented as
        // a JS string. Track whether an interceptor actually returned a body
        // patch so untouched binary bodies are preserved verbatim.
        var bodyTouched = false

        for interceptor in requestInterceptors {
            var payload: [String: Any] = [
                "provider": provider,
                "model": model,
                "url": urlString,
                "method": method,
                "headers": headers,
            ]
            if let sessionId, !sessionId.isEmpty { payload["sessionId"] = sessionId }
            if let bodyString { payload["body"] = bodyString }

            guard let arg = JSValue(object: payload, in: context),
                  let raw = interceptor.handler.call(withArguments: [arg]) else { continue }

            var patch: JSValue?
            if isPromise(raw) {
                patch = await awaitPromiseValue(raw, timeout: 60)
            } else {
                patch = raw
            }
            // Merge in-place mutations first, then the returned patch last so
            // an explicit return value takes precedence. The payload object
            // always carries the original url/method/body, so merging it after
            // the patch would clobber the patch's rewrites.
            Self.merge(into: &urlString, method: &method, headers: &headers, body: &bodyString, bodyTouched: &bodyTouched, from: arg)
            Self.merge(into: &urlString, method: &method, headers: &headers, body: &bodyString, bodyTouched: &bodyTouched, from: patch)
        }

        var out = request
        if let url = URL(string: urlString) { out.url = url }
        out.httpMethod = method
        out.allHTTPHeaderFields = headers
        if bodyTouched {
            out.httpBody = bodyString?.data(using: .utf8)
        }
        return out
    }

    private static func merge(
        into urlString: inout String,
        method: inout String,
        headers: inout [String: String],
        body: inout String?,
        bodyTouched: inout Bool,
        from patch: JSValue?
    ) {
        guard let patch, patch.isObject else { return }
        let urlVal = patch.objectForKeyedSubscript("url")
        if let urlVal, urlVal.isString, let s = urlVal.toString(), !s.isEmpty { urlString = s }
        let methodVal = patch.objectForKeyedSubscript("method")
        if let methodVal, methodVal.isString, let s = methodVal.toString(), !s.isEmpty { method = s.uppercased() }
        let headersVal = patch.objectForKeyedSubscript("headers")
        if let headersVal, headersVal.isObject, let dict = headersVal.toObject() as? [String: Any] {
            for (key, value) in dict {
                if value is NSNull {
                    headers.removeValue(forKey: key)
                } else if let s = value as? String {
                    headers[key] = s
                } else {
                    headers[key] = "\(value)"
                }
            }
        }
        // `has` guard: reads a missing key as undefined; only an explicitly
        // present body/bodyJSON key marks the body as touched.
        let bodyVal = patch.objectForKeyedSubscript("body")
        if let bodyVal, !bodyVal.isUndefined {
            bodyTouched = true
            if bodyVal.isNull { body = nil }
            else if let s = bodyVal.toString() { body = s }
        }
        let bodyJSONVal = patch.objectForKeyedSubscript("bodyJSON")
        if let bodyJSONVal, bodyJSONVal.isObject, !isPromiseValue(bodyJSONVal), let ctx = bodyJSONVal.context,
           let json = ctx.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [bodyJSONVal]),
           let s = json.toString(), s != "undefined" {
            bodyTouched = true
            body = s
        }
    }

    private static func isPromiseValue(_ value: JSValue) -> Bool {
        guard value.isObject else { return false }
        let then = value.objectForKeyedSubscript("then")
        return then?.isUndefined == false && then?.isObject == true
    }

    // MARK: - Async result handling

    /// Await a handler result: plain values convert directly, Promises are
    /// awaited via `then` (with timeout). Returns (output, isError).
    func resolveJSResult(_ value: JSValue, timeout: TimeInterval = 900) async -> (String, Bool) {
        if let exception = context.exception {
            context.exception = nil
            return ("Error: \(exception.toString() ?? "unknown JS error")", true)
        }
        guard isPromise(value) else {
            if value.isUndefined || value.isNull { return ("", false) }
            return (Self.stringify(value), false)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<(String, Bool), Never>) in
            let waiter = PromiseBox(cont)
            let onFulfilled: @convention(block) (JSValue) -> Void = { v in
                waiter.resume((Self.stringify(v), false))
            }
            let onRejected: @convention(block) (JSValue) -> Void = { e in
                waiter.resume((Self.stringify(e), true))
            }
            _ = value.invokeMethod("then", withArguments: [onFulfilled, onRejected])
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                waiter.resume(("Error: async handler timed out after \(Int(timeout))s", true))
            }
        }
    }

    /// Await a JS Promise and return its fulfilled value (nil on
    /// rejection/timeout). Used by request interception where patches are
    /// optional and failures should simply skip the interceptor.
    func awaitPromiseValue(_ promise: JSValue, timeout: TimeInterval) async -> JSValue? {
        await withCheckedContinuation { (cont: CheckedContinuation<JSValue?, Never>) in
            let waiter = ValueBox(cont)
            let onFulfilled: @convention(block) (JSValue) -> Void = { v in waiter.resume(v) }
            let onRejected: @convention(block) (JSValue) -> Void = { _ in waiter.resume(nil) }
            _ = promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                waiter.resume(nil)
            }
        }
    }

    private func isPromise(_ value: JSValue) -> Bool {
        guard value.isObject else { return false }
        let then = value.objectForKeyedSubscript("then")
        return then?.isUndefined == false && then?.isObject == true
    }

    private static func thrownException(_ context: JSContext) -> String {
        if let exception = context.exception {
            context.exception = nil
            return "Error: \(exception.toString() ?? "unknown JS error")"
        }
        return "Error: handler execution failed"
    }

    /// Convert a JS value to a display string: strings verbatim, objects and
    /// arrays via JSON.stringify, everything else via toString.
    private static func stringify(_ value: JSValue) -> String {
        if value.isUndefined { return "" }
        if value.isNull { return "null" }
        if value.isString { return value.toString() ?? "" }
        if value.isObject, let ctx = value.context,
           let json = ctx.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value]),
           json.isString, let s = json.toString(), s != "undefined" {
            return s
        }
        return value.toString() ?? ""
    }

    /// Bootstrap injected after the native API objects are installed. Keeps
    /// JS-side ergonomics (variadic minis.log) in JS where they belong.
    private static let bootstrapJS = """
    (function () {
      var rawLog = minis.__log;
      function stringify(v) {
        try {
          if (typeof v === "string") return v;
          if (v === undefined) return "undefined";
          if (v === null) return "null";
          if (Object.prototype.toString.call(v) === "[object Array]") {
            var parts = [];
            for (var i = 0; i < v.length; i++) parts.push(stringify(v[i]));
            return parts.join(" ");
          }
          return JSON.stringify(v);
        } catch (e) { return String(v); }
      }
      minis.log = function () {
        try {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) parts.push(stringify(arguments[i]));
          rawLog(parts.join(" "));
        } catch (e) {}
      };
      try { delete minis.__log; } catch (e) {}
    })();
    """

    // MARK: - minis global API

    private func installMinisAPI() {
        let minis = JSValue(newObjectIn: context)!

        // registerTool
        let registerTool: @convention(block) (JSValue) -> Void = { [weak self] def in
            guard let self else { return }
            let name = def.objectForKeyedSubscript("name").toString() ?? ""
            let desc = def.objectForKeyedSubscript("description").toString() ?? ""
            let execute = def.objectForKeyedSubscript("execute")
            guard !name.isEmpty, let execute, !execute.isUndefined else { return }
            self.registeredTools.append(RegisteredTool(name: name, description: desc, execute: execute))
        }
        minis.setObject(registerTool, forKeyedSubscript: "registerTool" as NSString)

        // registerCommand
        let registerCommand: @convention(block) (JSValue) -> Void = { [weak self] def in
            guard let self else { return }
            let name = def.objectForKeyedSubscript("name").toString() ?? ""
            let handler = def.objectForKeyedSubscript("handler")
            guard !name.isEmpty, let handler, !handler.isUndefined else { return }
            self.registeredCommands.append(RegisteredCommand(name: name, handler: handler))
        }
        minis.setObject(registerCommand, forKeyedSubscript: "registerCommand" as NSString)

        // on(event, handler) — event hook subscription
        let on: @convention(block) (JSValue, JSValue) -> Void = { [weak self] nameVal, handlerVal in
            guard let self else { return }
            let name = nameVal.toString() ?? ""
            guard !name.isEmpty, !handlerVal.isUndefined else { return }
            self.eventHandlers[name, default: []].append(handlerVal)
        }
        minis.setObject(on, forKeyedSubscript: "on" as NSString)

        // log — variadic on the JS side (see bootstrapJS); this native block
        // receives the final formatted string only.
        let log: @convention(block) (JSValue) -> Void = { [extensionID] value in
            let text = value.toString() ?? ""
            AppLogger(category: "Ext[\(extensionID)]").info("\(text)")
            ExtensionLogStore.shared.log(text, category: "Ext[\(extensionID)]")
        }
        minis.setObject(log, forKeyedSubscript: "__log" as NSString)

        // api.* — file is an object {read, write}; others are functions.
        let api = JSValue(newObjectIn: context)!
        api.setObject(makeShellBridge(), forKeyedSubscript: "shell" as NSString)
        let fileObj = JSValue(newObjectIn: context)!
        fileObj.setObject(makeFileReadBridge(), forKeyedSubscript: "read" as NSString)
        fileObj.setObject(makeFileWriteBridge(), forKeyedSubscript: "write" as NSString)
        fileObj.setObject(makeFileListBridge(), forKeyedSubscript: "list" as NSString)
        fileObj.setObject(makeFileDeleteBridge(), forKeyedSubscript: "delete" as NSString)
        api.setObject(fileObj, forKeyedSubscript: "file" as NSString)
        api.setObject(makePermissionBridge(), forKeyedSubscript: "permission" as NSString)
        api.setObject(makeEventBridge(), forKeyedSubscript: "event" as NSString)
        api.setObject(makeOffloadBridge(), forKeyedSubscript: "offload" as NSString)
        // `ui` is both directly callable (`minis.api.ui(data)`) and exposes
        // the documented `minis.api.ui.postMessage(data)` method — the
        // bridge block is a JS function object, so the property just gets
        // attached to the same callable. [M3-extensions]
        if let uiVal = JSValue(object: makeUIBridge(), in: context) {
            uiVal.setObject(makeUIBridge(), forKeyedSubscript: "postMessage" as NSString)
            api.setObject(uiVal, forKeyedSubscript: "ui" as NSString)
        }
        let settingsObj = JSValue(newObjectIn: context)!
        settingsObj.setObject(makeSettingsGetBridge(), forKeyedSubscript: "get" as NSString)
        settingsObj.setObject(makeSettingsSetBridge(), forKeyedSubscript: "set" as NSString)
        settingsObj.setObject(makeSettingsAllBridge(), forKeyedSubscript: "all" as NSString)
        api.setObject(settingsObj, forKeyedSubscript: "settings" as NSString)

        // minis.api.request = { intercept, unintercept, clear } — intercepts
        // outgoing model requests so plugins can rewrite URL/headers/body.
        let requestObj = JSValue(newObjectIn: context)!
        requestObj.setObject(makeInterceptBridge(), forKeyedSubscript: "intercept" as NSString)
        requestObj.setObject(makeUninterceptBridge(), forKeyedSubscript: "unintercept" as NSString)
        requestObj.setObject(makeUninterceptAllBridge(), forKeyedSubscript: "clear" as NSString)
        api.setObject(requestObj, forKeyedSubscript: "request" as NSString)
        minis.setObject(api, forKeyedSubscript: "api" as NSString)

        // minis.store = { get, set } — small KV persistence scoped to the
        // extension (UserDefaults keyed by extension id).
        let store = JSValue(newObjectIn: context)!
        store.setObject(makeStoreGetBridge(), forKeyedSubscript: "get" as NSString)
        store.setObject(makeStoreSetBridge(), forKeyedSubscript: "set" as NSString)
        minis.setObject(store, forKeyedSubscript: "store" as NSString)

        // minis.http = { fetch } — HTTP via URLSession (network permission).
        let http = JSValue(newObjectIn: context)!
        http.setObject(makeHTTPBridge(), forKeyedSubscript: "fetch" as NSString)
        minis.setObject(http, forKeyedSubscript: "http" as NSString)

        context.setObject(minis, forKeyedSubscript: "minis" as NSString)

        // JS-side bootstrap: variadic minis.log + small glue that is simpler
        // to express in JS than through the ObjC block bridge.
        context.evaluateScript(Self.bootstrapJS,
                               withSourceURL: URL(fileURLWithPath: "minis-bootstrap.js"))
        if context.exception != nil {
            let msg = context.exception.toString() ?? "unknown"
            context.exception = nil
            AppLogger(category: "Ext[\(extensionID)]").error("bootstrap failed: \(msg)")
        }
    }

    private func makeShellBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { cmdVal, optsVal in
            let cmd = cmdVal.toString() ?? ""
            let timeout = optsVal.objectForKeyedSubscript("timeout").toInt32() > 0
                ? Int(optsVal.objectForKeyedSubscript("timeout").toInt32()) : 900
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.shell(cmd, ["timeout": timeout])
                    if isErr {
                        reject?.call(withArguments: [out])
                    } else {
                        resolve?.call(withArguments: [out])
                    }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeFileReadBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { pathVal in
            let path = pathVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.fileRead(path)
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeFileWriteBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { pathVal, contentVal in
            let path = pathVal.toString() ?? ""
            let content = contentVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.fileWrite(path, content, false)
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeFileListBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { pathVal in
            let path = pathVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.fileList(path)
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeFileDeleteBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { pathVal in
            let path = pathVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.fileDelete(path)
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeOffloadBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        // Reserved surface: routes to the shell bridge (apple-* CLIs run in
        // the sandbox like any other command). Returns a promise.
        let bridge = self.bridge
        let context = self.context
        return { nameVal, argsVal in
            let name = nameVal.toString() ?? ""
            let args = argsVal.toString() ?? ""
            let cmd = "\(name) \(args)".trimmingCharacters(in: .whitespaces)
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                Task {
                    let (out, isErr) = await bridge.shell(cmd, [:])
                    if isErr { reject?.call(withArguments: [out]) } else { resolve?.call(withArguments: [out]) }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeUIBridge() -> @convention(block) (JSValue) -> Void {
        let bridge = self.bridge
        let extID = self.extensionID
        return { dataVal in
            let payload = dataVal.toObject() as? [String: Any] ?? [:]
            bridge.postToUI(extID, payload)
        }
    }

    private func makeSettingsGetBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let extID = self.extensionID
        return { keyVal in
            let key = keyVal.toString() ?? ""
            let value = bridge.settingsGet(extID, key)
            if let value {
                return JSValue(object: value, in: self.context) ?? JSValue(undefinedIn: self.context)
            }
            return JSValue(undefinedIn: self.context)
        }
    }

    private func makeSettingsSetBridge() -> @convention(block) (JSValue, JSValue) -> Void {
        let bridge = self.bridge
        let extID = self.extensionID
        return { keyVal, valueVal in
            let key = keyVal.toString() ?? ""
            let value = valueVal.toObject()
            bridge.settingsSet(extID, key, value as Any)
        }
    }

    private func makeSettingsAllBridge() -> @convention(block) () -> JSValue {
        let bridge = self.bridge
        let extID = self.extensionID
        return {
            let all = bridge.settingsAll(extID)
            return JSValue(object: all, in: self.context) ?? JSValue(undefinedIn: self.context)
        }
    }

    private func makeStoreGetBridge() -> @convention(block) (JSValue) -> JSValue {
        let extID = self.extensionID
        return { keyVal in
            let key = keyVal.toString() ?? ""
            let fullKey = "ext.kv.\(extID).\(key)"
            let value = UserDefaults.standard.string(forKey: fullKey)
            return JSValue(object: value as Any, in: self.context)!
        }
    }

    private func makeStoreSetBridge() -> @convention(block) (JSValue, JSValue) -> Void {
        let extID = self.extensionID
        return { keyVal, valueVal in
            let key = keyVal.toString() ?? ""
            let fullKey = "ext.kv.\(extID).\(key)"
            if valueVal.isUndefined || valueVal.isNull {
                UserDefaults.standard.removeObject(forKey: fullKey)
            } else {
                UserDefaults.standard.set(valueVal.toString() ?? "", forKey: fullKey)
            }
        }
    }

    private func makeHTTPBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let context = self.context
        let bridge = self.bridge
        return { urlVal, optsVal in
            let urlStr = urlVal.toString() ?? ""
            // Network permission gate (declared in manifest).
            guard bridge.hasPermission("network") else {
                let promise = JSValue(newPromiseIn: context) { _, reject in
                    reject?.call(withArguments: ["Error: extension needs 'network' permission (declare it in manifest.json)"])
                }
                return promise ?? JSValue(undefinedIn: context)
            }
            let method = (optsVal.objectForKeyedSubscript("method").toString() ?? "GET").uppercased()
            let body = optsVal.objectForKeyedSubscript("body").toString()
            let headersVal = optsVal.objectForKeyedSubscript("headers")
            let headers = (headersVal?.toObject() as? [String: Any]) ?? [:]
            let promise = JSValue(newPromiseIn: context) { resolve, reject in
                guard let url = URL(string: urlStr) else {
                    reject?.call(withArguments: ["Error: invalid URL"])
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                for (key, value) in headers {
                    if let s = value as? String {
                        request.setValue(s, forHTTPHeaderField: key)
                    } else if let n = value as? NSNumber {
                        request.setValue(n.stringValue, forHTTPHeaderField: key)
                    }
                }
                if let body, !body.isEmpty {
                    request.httpBody = body.data(using: .utf8)
                }
                Task {
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let text = String(data: data, encoding: .utf8) ?? ""
                        var responseHeaders: [String: String] = [:]
                        if let http = response as? HTTPURLResponse {
                            for (key, value) in http.allHeaderFields {
                                responseHeaders["\(key)"] = "\(value)"
                            }
                        }
                        let result: [String: Any] = ["status": status, "headers": responseHeaders, "body": text]
                        resolve?.call(withArguments: [JSValue(object: result, in: context)!])
                    } catch {
                        reject?.call(withArguments: [error.localizedDescription])
                    }
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makePermissionBridge() -> @convention(block) (JSValue) -> JSValue {
        let bridge = self.bridge
        let context = self.context
        return { kindVal in
            let kind = kindVal.toString() ?? ""
            let promise = JSValue(newPromiseIn: context) { resolve, _ in
                Task {
                    let granted = await bridge.requestPermission(kind)
                    resolve?.call(withArguments: [granted])
                }
            }
            return promise ?? JSValue(undefinedIn: context)
        }
    }

    private func makeEventBridge() -> @convention(block) (JSValue, JSValue) -> JSValue {
        let bridge = self.bridge
        return { nameVal, dataVal in
            let name = nameVal.toString() ?? ""
            let data = dataVal.toObject() as? [String: Any] ?? [:]
            bridge.emitEvent(name, data)
            return JSValue(undefinedIn: self.context)
        }
    }

    // MARK: - Request interceptor registration

    /// `minis.api.request.intercept(fn)` or
    /// `minis.api.request.intercept({name, handler})` → registration id.
    private func makeInterceptBridge() -> @convention(block) (JSValue) -> JSValue {
        let context = self.context
        return { [weak self] defVal in
            guard let self else { return JSValue(undefinedIn: context) }
            var name = ""
            var handler: JSValue?
            if defVal.isObject {
                let named = defVal.objectForKeyedSubscript("handler")
                if let named, named.isObject {
                    handler = named
                    name = defVal.objectForKeyedSubscript("name").toString() ?? ""
                } else {
                    handler = defVal
                }
            }
            guard let handler, !handler.isUndefined else {
                return JSValue(undefinedIn: context)
            }
            let id = "ri-" + String(UUID().uuidString.prefix(8))
            self.requestInterceptors.append(RequestInterceptor(id: id, name: name, handler: handler))
            ExtensionRegistry.shared.refreshInterceptorFlag()
            return JSValue(object: id, in: context) ?? JSValue(undefinedIn: context)
        }
    }

    private func makeUninterceptBridge() -> @convention(block) (JSValue) -> Void {
        return { [weak self] idVal in
            guard let self else { return }
            let id = idVal.toString() ?? ""
            self.requestInterceptors.removeAll { $0.id == id }
            ExtensionRegistry.shared.refreshInterceptorFlag()
        }
    }

    private func makeUninterceptAllBridge() -> @convention(block) () -> Void {
        return { [weak self] in
            self?.requestInterceptors.removeAll()
            ExtensionRegistry.shared.refreshInterceptorFlag()
        }
    }
}

// MARK: - Resume-once continuation guards

/// A JS promise may settle after the timeout already fired (or vice versa);
/// these boxes guarantee the continuation resumes exactly once.
private final class PromiseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumable: CheckedContinuation<(String, Bool), Never>?

    init(_ cont: CheckedContinuation<(String, Bool), Never>) { resumable = cont }

    func resume(_ value: (String, Bool)) {
        lock.lock()
        let cont = resumable
        resumable = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}

private final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumable: CheckedContinuation<JSValue?, Never>?

    init(_ cont: CheckedContinuation<JSValue?, Never>) { resumable = cont }

    func resume(_ value: JSValue?) {
        lock.lock()
        let cont = resumable
        resumable = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
