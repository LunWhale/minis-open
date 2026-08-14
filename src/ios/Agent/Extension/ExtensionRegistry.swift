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
    /// Extension id → registered command name → RegisteredCommand.
    private var commandIndex: [String: [String: ExtensionJSRuntime.RegisteredCommand]] = [:]
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
        commandIndex.removeAll()
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
        var cmdByName: [String: ExtensionJSRuntime.RegisteredCommand] = [:]
        for command in runtime.registeredCommands {
            cmdByName[command.name] = command
        }
        commandIndex[record.id] = cmdByName

        // Apply the extension's theme (if any) — last loaded wins. Uses
        // ThemeManager so ChatColors (which observes it) re-evaluates
        // immediately.
        if let themeDef = manifest.theme {
            let themeURL = record.bundleURL.appendingPathComponent(themeDef.file)
            if let data = try? Data(contentsOf: themeURL),
               let theme = ThemeTokens.parse(data: data) {
                ThemeManager.shared.apply(theme)
                AppLogger(category: "ExtensionTheme").info("Applied theme '\(theme.name)' from \(record.id)")
            }
        }
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

    // MARK: - Commands

    /// All registered extension slash commands: [(name, extensionID)]
    /// Names are prefixed with `ext-` by the extension author; exposed as-is.
    func extensionCommands() -> [(name: String, extensionID: String)] {
        var out: [(String, String)] = []
        for (extID, cmds) in commandIndex {
            for (cmdName, _) in cmds {
                out.append((cmdName, extID))
            }
        }
        return out
    }

    /// Execute a registered extension command by name. Returns (output, isError).
    func executeExtensionCommand(name: String, args: [String]) async -> (String, Bool) {
        for (extID, cmds) in commandIndex {
            if let cmd = cmds[name], let runtime = runtimes[extID] {
                return runtime.callCommand(cmd, args: args)
            }
        }
        return ("Error: extension command '\(name)' not found", true)
    }

    // MARK: - Events

    /// Fire an agent lifecycle event to all extensions with matching hooks.
    func emitLifecycleEvent(_ event: String, data: [String: Any]) {
        for runtime in runtimes.values {
            runtime.emitEvent(event, data: data)
        }
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

/// Permission gate for extension first-use confirmation. Reuses the
/// standard OffloadPermissionDialog sheet: constructs a PermissionRequest
/// into `OffloadPermissionManager.pendingRequest` (the dialog modifier is
/// attached to AIChatView), awaits the Allow/Deny continuation, and caches
/// per-extension grants for the session. Times out after 30s (deny).
enum PermissionGate {
    private static var grantedCache: [String: Set<String>] = [:]  // extID → kinds
    private static let logger = AppLogger(category: "ExtensionPermission")

    static func request(_ kind: String, extensionID: String) async -> Bool {
        if grantedCache[extensionID, default: []].contains(kind) { return true }

        let allowed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let request = PermissionRequest(
                id: UUID().uuidString,
                commandName: "extension:\(extensionID)",
                displayLabel: extensionID,
                description: "The extension requests **\(kind)** access. This lets its agent-side code \(kindDescription(kind)).",
                fullCommand: "extension \(extensionID) requests \(kind) access",
                continuation: cont
            )
            Task { @MainActor in
                OffloadPermissionManager.shared.pendingRequest = request
                // 30s timeout (mirrors OffloadPermissionManager.checkPermission)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if OffloadPermissionManager.shared.pendingRequest?.id == request.id {
                        OffloadPermissionManager.shared.pendingRequest = nil
                        cont.resume(returning: false)
                    }
                }
            }
        }

        logger.info("\(extensionID) \(kind) -> \(allowed ? "granted" : "denied")")
        if allowed {
            grantedCache[extensionID, default: []].insert(kind)
        }
        return allowed
    }

    private static func kindDescription(_ kind: String) -> String {
        switch kind {
        case "shell": return "run shell commands in the sandbox"
        case "files": return "read and write files under /var/minis/"
        case "network": return "make network requests"
        case "ui": return "render UI widgets in this session"
        default: return "use device capabilities"
        }
    }
}

/// Active session id snapshot, kept in sync by AIChatViewModel.
enum ActiveSession {
    private static var current: String?
    static func set(_ id: String?) { current = id }
    static func id() -> String? { current }
}
