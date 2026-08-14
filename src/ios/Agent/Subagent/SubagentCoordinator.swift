import Foundation

// MARK: - Sub-Agent Coordinator

/// Orchestrates sub-agent runs: resolves a provider, builds the sub-agent
/// tool set, wires a tool executor (shell + files), and runs `AgentRunner`
/// in foreground (await) or background (Task handle).
///
/// Sub-agents share the parent's provider config and the same sandbox shell,
/// but each run has its own in-memory conversation — they never touch the
/// parent session's history or the UI message list.
enum SubagentCoordinator {

    // MARK: - Run Registry

    /// A completed/in-flight sub-agent run, kept so the parent session can
    /// inspect what sub-agents did (agent_status tool + SubagentBlockView).
    struct RunRecord: Identifiable, Sendable {
        let id: String
        let roleName: String
        let task: String
        let status: String          // running / done / error / cancelled
        let startedAt: Date
        var finishedAt: Date?
        var summary: String?
        var toolCalls: Int
        var turns: Int
        var error: String?

        var idString: String { id }
    }

    /// Process-local run log (in-memory; survives within the session).
    /// Capped at 50 records, newest first.
    private static let lock = NSLock()
    private static var runLog: [RunRecord] = []

    static func record(_ run: RunRecord) {
        lock.lock()
        runLog.insert(run, at: 0)
        if runLog.count > 50 { runLog.removeLast(runLog.count - 50) }
        lock.unlock()
    }

    static func updateRecord(id: String, mutate: (inout RunRecord) -> Void) {
        lock.lock()
        if let idx = runLog.firstIndex(where: { $0.id == id }) {
            mutate(&runLog[idx])
        }
        lock.unlock()
    }

    /// Recent runs, newest first.
    static func recentRuns(limit: Int = 20) -> [RunRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(runLog.prefix(limit))
    }

    static func runRecord(id: String) -> RunRecord? {
        lock.lock()
        defer { lock.unlock() }
        return runLog.first(where: { $0.id == id })
    }

    static func newRunID() -> String {
        UUID().uuidString.prefix(8).lowercased()
    }
    /// Tool names the sub-agent sees. Kept deliberately small and focused:
    /// shell for everything, plus direct file tools for reading/writing
    /// without shell overhead (mirrors the parent's core tool set).
    static let subagentToolNames: [String] = [
        "shell_execute",
        "file_read",
        "file_write",
        "file_edit",
        "todo_create",
        "todo_update",
        "todo_list",
    ]

    /// Build the `AgentToolDefinition` list for a sub-agent, honoring the
    /// role's tool allowlist (empty = all subagent tools).
    static func toolDefinitions(role: AgentRole) -> [AgentToolDefinition] {
        let all = makeSubagentTools()
        if role.toolsAllow.isEmpty { return all }
        return all.filter { role.toolsAllow.contains($0.name) }
    }

    /// Resolve a provider. Prefers the entry currently active in the parent
    /// session; falls back to the first available agent-loop entry.
    static func resolveProvider(activeEntry: ModelEntry?) async -> AgentProvider? {
        if let activeEntry {
            return await AIChatViewModel.makeAgentProvider(for: activeEntry)
        }
        let store = ProviderConfigStore.shared
        guard let entry = store.resolvedAgentLoopEntries.first else { return nil }
        return await AIChatViewModel.makeAgentProvider(for: entry)
    }

    /// Run a sub-agent and await its result (foreground).
    static func run(
        task: String,
        role: AgentRole,
        activeEntry: ModelEntry?,
        sessionId: String?,
        extraTools: [AgentToolDefinition] = []
    ) async -> AgentRunner.Result {
        let runID = newRunID()
        record(RunRecord(
            id: runID, roleName: role.name, task: task,
            status: "running", startedAt: Date(),
            finishedAt: nil, summary: nil, toolCalls: 0, turns: 0, error: nil
        ))

        guard let provider = await resolveProvider(activeEntry: activeEntry) else {
            let errResult = AgentRunner.Result(
                text: "", toolCalls: 0, turns: 0,
                usage: nil, stopReason: nil,
                error: "No model provider configured"
            )
            updateRecord(id: runID) { $0.status = "error"; $0.finishedAt = Date(); $0.error = errResult.error }
            return errResult
        }

        var tools = toolDefinitions(role: role)
        tools.append(contentsOf: extraTools)

        let runner = AgentRunner(
            provider: provider,
            systemPrompt: role.systemPrompt(for: task),
            tools: tools,
            executor: Executor(sessionId: sessionId),
            config: AgentRunner.Config(
                maxTurns: role.maxTurns,
                timeoutSeconds: TimeInterval(role.timeoutSeconds)
            )
        )
        let result = await runner.run(task: task)
        updateRecord(id: runID) {
            $0.status = result.error == nil ? "done" : "error"
            $0.finishedAt = Date()
            $0.summary = result.text
            $0.toolCalls = result.toolCalls
            $0.turns = result.turns
            $0.error = result.error
        }
        return result
    }

    /// Launch a sub-agent in the background. Returns a `Task` the caller can
    /// await or cancel; the result carries the full run summary.
    static func runInBackground(
        task: String,
        role: AgentRole,
        activeEntry: ModelEntry?,
        sessionId: String?
    ) -> Task<AgentRunner.Result, Never> {
        Task {
            await run(task: task, role: role, activeEntry: activeEntry, sessionId: sessionId)
        }
    }
}

// MARK: - Sub-agent tool definitions + executor

extension SubagentCoordinator {

    /// The canonical sub-agent tool set (subset of the parent's tools).
    private static func makeSubagentTools() -> [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "shell_execute",
                description: "Execute a command in the sandbox Linux shell. Each invocation is an isolated process; stdout/stderr captured. Use for most work: installing packages (apk add), running scripts, managing files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Concise 5-10 word summary of the command, shown to the user."),
                    "command": AgentToolParam(type: .string, description: "The shell command to execute. Multi-line OK. Keep under 1000 chars."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default 900)."),
                ],
                required: ["tool_title", "command"]
            ),
            AgentToolDefinition(
                name: "file_read",
                description: "Read a file from the sandbox Linux filesystem. Faster than shell for reading. Rejects binary files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Concise summary."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path, e.g. /var/minis/workspace/data.csv"),
                    "max_length": AgentToolParam(type: .integer, description: "Max characters returned (default 15000)."),
                ],
                required: ["tool_title", "path"]
            ),
            AgentToolDefinition(
                name: "file_write",
                description: "Write content to a file on the sandbox Linux filesystem. Creates the file if missing. Use append mode to add to existing files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Concise summary."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to write."),
                    "content": AgentToolParam(type: .string, description: "Text content to write."),
                    "append": AgentToolParam(type: .boolean, description: "Append instead of overwrite (default false)."),
                ],
                required: ["tool_title", "path", "content"]
            ),
            AgentToolDefinition(
                name: "file_edit",
                description: "Make targeted edits to an existing file using exact string replacement. Read the file first with file_read.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Concise summary."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path."),
                    "old_string": AgentToolParam(type: .string, description: "Exact text to find (must be unique)."),
                    "new_string": AgentToolParam(type: .string, description: "Replacement text (empty deletes)."),
                    "replace_all": AgentToolParam(type: .boolean, description: "Replace all occurrences (default false)."),
                ],
                required: ["tool_title", "path", "old_string", "new_string"]
            ),
            AgentToolDefinition(
                name: "todo_create",
                description: "Create todo item(s) for the parent session. Use to track multi-step work.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Concise summary."),
                    "items": AgentToolParam(type: .string, description: "JSON array of {\"title\":\"...\", \"detail\":\"...\"}."),
                ],
                required: ["tool_title", "items"]
            ),
            AgentToolDefinition(
                name: "todo_update",
                description: "Update a todo item's status: pending, in_progress, done, blocked.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Concise summary."),
                    "id": AgentToolParam(type: .string, description: "Todo item id."),
                    "status": AgentToolParam(type: .string, description: "New status."),
                ],
                required: ["tool_title", "id"]
            ),
            AgentToolDefinition(
                name: "todo_list",
                description: "List todo items for the parent session.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Concise summary."),
                    "status": AgentToolParam(type: .string, description: "Optional status filter."),
                ],
                required: ["tool_title"]
            ),
        ]
    }

    /// Executor that routes tool calls to the sandbox (shell) and filesystem.
    /// Todo tools route to TodoStore so sub-agent tracking lands in the
    /// parent session's todo list.
    private struct Executor: AgentRunner.Executor {
        let sessionId: String?

        func execute(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
            switch name {
            case "shell_execute":
                return await runShell(args)
            case "file_read":
                return await readFile(args)
            case "file_write":
                return await writeFile(args)
            case "file_edit":
                return await editFile(args)
            case "todo_create", "todo_update", "todo_list":
                return await runTodo(name: name, args: args)
            default:
                return ("Error: unknown tool '\(name)'", true)
            }
        }

        private func runShell(_ args: [String: Any]) async -> (String, Bool) {
            guard let command = args["command"] as? String else {
                return ("Error: missing 'command'", true)
            }
            guard let sessionId else {
                return ("Error: no session", true)
            }
            do {
                let result = try await ISHExecutionCoordinator.shared.execute(
                    sessionId: sessionId,
                    command: command,
                    timeout: 900,
                    lineCallback: { _ in },
                    pidCallback: { _ in }
                )
                return (result.output, result.exitCode != 0)
            } catch {
                return ("Error: \(error.localizedDescription)", true)
            }
        }

        private func readFile(_ args: [String: Any]) async -> (String, Bool) {
            guard let path = args["path"] as? String else {
                return ("Error: missing 'path'", true)
            }
            guard let hostPath = resolveLinuxPath(path) else {
                return ("Error: cannot resolve '\(path)' — only /var/minis/ paths are readable", true)
            }
            guard FileManager.default.fileExists(atPath: hostPath) else {
                return ("Error: file not found: \(path)", true)
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: hostPath))
                let maxLen = (args["max_length"] as? Int) ?? 15000
                var text = String(data: data, encoding: .utf8) ?? "<binary or non-UTF8>"
                if text.count > maxLen {
                    text = String(text.prefix(maxLen)) + "\n... [truncated, \(text.count - maxLen) more chars]"
                }
                return (text, false)
            } catch {
                return ("Error: \(error.localizedDescription)", true)
            }
        }

        private func writeFile(_ args: [String: Any]) async -> (String, Bool) {
            guard let path = args["path"] as? String, let content = args["content"] as? String else {
                return ("Error: missing 'path' or 'content'", true)
            }
            guard let hostPath = resolveLinuxPath(path) else {
                return ("Error: cannot resolve '\(path)' — only /var/minis/ paths are writable", true)
            }
            do {
                let url = URL(fileURLWithPath: hostPath)
                if (args["append"] as? Bool) == true {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        handle.write(Data(content.utf8))
                        try handle.close()
                    } else {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                    }
                } else {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
                return ("Wrote \(content.count) bytes to \(path)", false)
            } catch {
                return ("Error: \(error.localizedDescription)", true)
            }
        }

        private func editFile(_ args: [String: Any]) async -> (String, Bool) {
            guard let path = args["path"] as? String,
                  let old = args["old_string"] as? String else {
                return ("Error: missing 'path' or 'old_string'", true)
            }
            guard let hostPath = resolveLinuxPath(path) else {
                return ("Error: cannot resolve '\(path)'", true)
            }
            do {
                let url = URL(fileURLWithPath: hostPath)
                var text = try String(contentsOf: url, encoding: .utf8)
                let replaceAll = (args["replace_all"] as? Bool) == true
                let new = (args["new_string"] as? String) ?? ""
                if !replaceAll {
                    guard let range = text.range(of: old) else {
                        return ("Error: old_string not found in \(path)", true)
                    }
                    text.replaceSubrange(range, with: new)
                } else {
                    text = text.replacingOccurrences(of: old, with: new)
                }
                try text.write(to: url, atomically: true, encoding: .utf8)
                return ("Edited \(path)", false)
            } catch {
                return ("Error: \(error.localizedDescription)", true)
            }
        }

        private func runTodo(name: String, args: [String: Any]) async -> (String, Bool) {
            guard let sessionId else {
                return ("Error: no session for todo tools", true)
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: args)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                // Reuse the same logic as the parent's todo tools via a small
                // local reimplementation to avoid coupling to AIChatViewModel.
                switch name {
                case "todo_create":
                    guard let itemsRaw = args["items"] as? String,
                          let itemsData = itemsRaw.data(using: .utf8),
                          let items = try? JSONSerialization.jsonObject(with: itemsData) as? [[String: Any]] else {
                        return ("Error: 'items' must be a JSON array", true)
                    }
                    var parsed: [(title: String, detail: String?)] = []
                    for item in items {
                        guard let title = item["title"] as? String else { return ("Error: item needs 'title'", true) }
                        parsed.append((title: title, detail: item["detail"] as? String))
                    }
                    let created = await TodoStore.shared.create(sessionId: sessionId, titles: parsed)
                    return ("Created \(created.count) todo(s)", false)
                case "todo_update":
                    guard let id = args["id"] as? String else { return ("Error: missing 'id'", true) }
                    var status: TodoItem.Status?
                    if let raw = args["status"] as? String { status = TodoItem.Status(rawValue: raw) }
                    let updated = await TodoStore.shared.update(
                        sessionId: sessionId, id: id,
                        status: status, title: nil, detail: nil
                    )
                    return (updated.map { "Updated: \($0.title) → \($0.status.rawValue)" } ?? "Error: not found", updated == nil)
                case "todo_list":
                    let items = await TodoStore.shared.list(sessionId: sessionId)
                    if items.isEmpty { return ("No todos in this session", false) }
                    let out = items.map { "[\($0.status.rawValue)] \($0.title)" }.joined(separator: "\n")
                    return (out, false)
                default:
                    return ("Error: unknown todo tool", true)
                }
            } catch {
                return ("Error: \(error.localizedDescription)", true)
            }
        }
    }

    /// Resolve a Linux sandbox path to a host path. Only /var/minis/** and
    /// a few safe roots are allowed (mirrors the parent's sandbox routing).
    private static func resolveLinuxPath(_ linuxPath: String) -> String? {
        // /var/minis → Library/MinisChat/minis/...
        let prefix = "/var/minis/"
        if linuxPath.hasPrefix(prefix) {
            let tail = String(linuxPath.dropFirst(prefix.count))
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            let base = library.appendingPathComponent("MinisChat/minis", isDirectory: true)
            let url = base.appendingPathComponent(tail)
            return url.path
        }
        return nil
    }
}
