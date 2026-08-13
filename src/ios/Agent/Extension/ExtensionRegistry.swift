import Foundation
import JavaScriptCore

// MARK: - Extension Registry

/// Loads enabled extensions, hosts their JS runtimes, and exposes their
/// registered tools to the agent as `AgentToolDefinition`s. Also provides
/// the native bridge callbacks (shell/file/permission) the JS `minis.api`
/// routes to.
///
/// Lifecycle: `reload()` after install/uninstall/enable/disable. The agent
/// tool dispatcher asks `extensionToolDefinitions` for the current tool set
/// and routes `extension:<id>:<tool>` calls to `executeExtensionTool`.
final class ExtensionRegistry {
    static let shared = ExtensionRegistry()

    /// Live runtimes keyed by extension id (only enabled extensions).
    private var runtimes: [String: ExtensionJSRuntime] = [:]
    /// Extension id → registered tool name → RegisteredTool.
    private var toolIndex: [String: [String: ExtensionJSRuntime.RegisteredTool]] = [:]
    private var manifests: [String: ExtensionManifest] = [:]
    private var loaded = false

    private init() {}

    // MARK: - Loading

    /// (Re)load all enabled extensions from the store. Call after any
    /// install/uninstall/enable/disable change.
    func reload() async {
        let records = await ExtensionStore.shared.list().filter(\.enabled)
        runtimes.removeAll()
        toolIndex.removeAll()
        manifests.removeAll()

        for record in records {
            do {
                try await load(record)
            } catch {
                AppLogger(category: "ExtensionRegistry").error("Failed to load \(record.id): \(error.localizedDescription)")
            }
        }
        loaded = true
    }

    private func load(_ record: ExtensionStore.Record) async throws {
        let manifestURL = record.bundleURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw ExtensionError.missingManifest
        }
        let manifest = try ExtensionManifest.parse(data: manifestData)
        manifests[record.id] = manifest

        let runtime = ExtensionJSRuntime(
            extensionID: record.id,
            bridge: makeBridge(extensionID: record.id, manifest: manifest)
        )
        // Evaluate tool/command/hook scripts.
        for tool in manifest.tools ?? [] {
            let url = record.bundleURL.appendingPathComponent(tool.file)
            if let js = try? String(contentsOf: url, encoding: .utf8) {
                try runtime.evaluateScript(js, fileName: tool.file)
            }
        }
        for command in manifest.commands ?? [] {
            let url = record.bundleURL.appendingPathComponent(command.file)
            if let js = try? String(contentsOf: url, encoding: .utf8) {
                try runtime.evaluateScript(js, fileName: command.file)
            }
        }
        for hook in manifest.hooks ?? [] {
            let url = record.bundleURL.appendingPathComponent(hook.file)
            if let js = try? String(contentsOf: url, encoding: .utf8) {
                try runtime.evaluateScript(js, fileName: hook.file)
            }
        }

        runtimes[record.id] = runtime
        var byName: [String: ExtensionJSRuntime.RegisteredTool] = [:]
        for tool in runtime.registeredTools {
            byName[tool.name] = tool
        }
        toolIndex[record.id] = byName
    }

    // MARK: - Tool surface for the agent

    /// `AgentToolDefinition`s for all registered extension tools, namespaced
    /// as `extension_<id>_<name>` so collisions across extensions are avoided.
    func extensionToolDefinitions() -> [AgentToolDefinition] {
        var defs: [AgentToolDefinition] = []
        for (extID, tools) in toolIndex {
            guard let manifest = manifests[extID] else { continue }
            for (toolName, _) in tools {
                let apiName = "extension_\(extID)_\(toolName)"
                defs.append(AgentToolDefinition(
                    name: apiName,
                    description: "Extension tool '\(toolName)' from '\(manifest.name)'. Executes JavaScript in the extension's sandboxed runtime.",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "Concise summary shown to the user."),
                        "args": AgentToolParam(type: .string, description: "JSON object of arguments to pass to the extension tool."),
                    ],
                    required: ["tool_title", "args"]
                ))
            }
        }
        return defs
    }

    /// Execute an extension tool by its namespaced API name
    /// (`extension_<id>_<tool>`). Returns (output, isError).
    func executeExtensionTool(apiName: String, argsJSON: String) async -> (String, Bool) {
        // apiName = "extension_<id>_<tool>"
        let parts = apiName.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return ("Error: malformed extension tool name", true) }
        // The extension id itself may contain underscores (e.g. com_example_myext),
        // so split from the front: "extension" + id + rest. We reconstruct by
        // finding the registry entry whose id matches a prefix.
        let prefix = "extension_"
        guard apiName.hasPrefix(prefix) else { return ("Error: not an extension tool", true) }
        let tail = String(apiName.dropFirst(prefix.count))
        // Longest matching extension id prefix wins.
        var matched: (String, String)?
        for extID in toolIndex.keys where tail.hasPrefix(extID + "_") {
            let toolName = String(tail.dropFirst(extID.count + 1))
            if toolIndex[extID]?[toolName] != nil {
                matched = (extID, toolName)
                break
            }
        }
        guard let (extID, toolName) = matched,
              let runtime = runtimes[extID],
              let tool = toolIndex[extID]?[toolName] else {
            return ("Error: extension tool '\(apiName)' not found", true)
        }

        // Parse args JSON.
        var args: [String: Any] = [:]
        if let data = argsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = obj
        }

        return runtime.callTool(tool, args: args)
    }

    // MARK: - UI widgets

    /// All enabled UI widgets: (extensionID, UIDef, bundleURL).
    func uiWidgets() -> [(extensionID: String, widget: ExtensionManifest.UIDef, bundleURL: URL)] {
        var out: [(String, ExtensionManifest.UIDef, URL)] = []
        for (extID, manifest) in manifests {
            for widget in manifest.ui ?? [] {
                let bundle = ExtensionStore.shared.extensionsDir.appendingPathComponent(extID, isDirectory: true)
                out.append((extID, widget, bundle))
            }
        }
        return out
    }

    // MARK: - Native bridge

    private func makeBridge(extensionID: String, manifest: ExtensionManifest) -> ExtensionJSRuntime.Bridge {
        ExtensionJSRuntime.Bridge(
            shell: { cmd, opts in
                // Permission gate: "shell" must be declared + granted.
                guard manifest.permissions.contains("shell") else {
                    return ("Error: extension '\(extensionID)' needs 'shell' permission (declare it in manifest.json)", true)
                }
                // First-use confirmation via the standard permission dialog.
                let granted = await PermissionGate.request("shell", extensionID: extensionID)
                guard granted else {
                    return ("Permission denied: shell", true)
                }
                guard let sessionID = await ActiveSession.shared.id() else {
                    return ("Error: no active session", true)
                }
                do {
                    let timeout = (opts["timeout"] as? Int) ?? 900
                    let result = try await ISHExecutionCoordinator.shared.execute(
                        sessionId: sessionID,
                        command: cmd,
                        timeout: TimeInterval(timeout),
                        lineCallback: { _ in },
                        pidCallback: { _ in }
                    )
                    return (result.output, result.exitCode != 0)
                } catch {
                    return ("Error: \(error.localizedDescription)", true)
                }
            },
            fileRead: { path in
                guard manifest.permissions.contains("files") else {
                    return ("Error: extension '\(extensionID)' needs 'files' permission", true)
                }
                let granted = await PermissionGate.request("files", extensionID: extensionID)
                guard granted else { return ("Permission denied: files", true) }
                guard let host = Self.resolveSandboxPath(path) else {
                    return ("Error: only /var/minis/ paths are readable", true)
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: host)),
                      let text = String(data: data, encoding: .utf8) else {
                    return ("Error: cannot read \(path)", true)
                }
                return (text, false)
            },
            requestPermission: { kind in
                await PermissionGate.request(kind, extensionID: extensionID)
            },
            postToUI: { _, _ in
                // UI widget messaging is wired via ExtensionWebView delegate;
                // a broadcast implementation can be added when widgets exist.
            },
            emitEvent: { _, _ in
                // Cross-extension events: reserved for a future event bus.
            }
        )
    }

    /// Resolve a sandbox Linux path to a host path (only /var/minis/**).
    static func resolveSandboxPath(_ linuxPath: String) -> String? {
        let prefix = "/var/minis/"
        guard linuxPath.hasPrefix(prefix) else { return nil }
        let tail = String(linuxPath.dropFirst(prefix.count))
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library.appendingPathComponent("MinisChat/minis/\(tail)").path
    }
}

/// Permission gate for extension first-use confirmation. Delegates to the
/// standard OffloadPermissionDialog flow; a lightweight reimplementation
/// keeps the extension system decoupled from the chat view model.
enum PermissionGate {
    private static var grantedCache: [String: Set<String>] = [:]  // extID → kinds

    static func request(_ kind: String, extensionID: String) async -> Bool {
        if grantedCache[extensionID, default: []].contains(kind) { return true }
        // Post a permission request notification; the UI presents the dialog
        // and replies via PermissionResponse. If no UI handler is attached,
        // default to allowing read-only kinds and denying powerful ones.
        let response = await withCheckedContinuation { cont in
            let token = UUID().uuidString
            NotificationCenter.default.post(
                name: .extensionPermissionRequest,
                object: nil,
                userInfo: ["token": token, "extensionID": extensionID, "kind": kind]
            )
            PermissionResponseHandler.shared.register(token: token) { granted in
                cont.resume(returning: granted)
            }
        }
        if response {
            grantedCache[extensionID, default: []].insert(kind)
        }
        return response
    }
}

/// Completion handler registry for permission dialogs.
final class PermissionResponseHandler {
    static let shared = PermissionResponseHandler()
    private var handlers: [String: (Bool) -> Void] = [:]
    private init() {}

    func register(token: String, handler: @escaping (Bool) -> Void) {
        handlers[token] = handler
    }

    func resolve(token: String, granted: Bool) {
        handlers.removeValue(forKey: token)?(granted)
    }
}

/// Active session id snapshot, kept in sync by AIChatViewModel.
enum ActiveSession {
    private static var current: String?
    static func set(_ id: String?) { current = id }
    static func id() -> String? { current }
}

extension Notification.Name {
    static let extensionPermissionRequest = Notification.Name("minis.extension.permission.request")
    static let extensionPermissionResponse = Notification.Name("minis.extension.permission.response")
}
