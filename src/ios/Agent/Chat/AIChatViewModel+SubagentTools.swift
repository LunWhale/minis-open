import Foundation

// MARK: - Sub-agent Tools (agent_delegate)

extension AIChatViewModel {

    /// Canonical `agent_delegate` tool definition, appended to the parent
    /// agent's tool set. The sub-agent runs with its own in-memory context;
    /// the parent receives a structured summary as the tool result.
    static func makeSubagentToolDefinition() -> AgentToolDefinition {
        let roleNames = AgentRole.loadAll().map(\.name).joined(separator: ", ")
        return AgentToolDefinition(
            name: "agent_delegate",
            description: """
            Delegate a well-scoped subtask to a sub-agent that runs with its own conversation context \
            (separate history, same model provider, same sandbox). Use for research, isolated coding \
            tasks, reviews, or planning that would bloat the current context. The sub-agent returns a \
            summary you can act on. Sub-agents run at most ~25 turns and cannot spawn further sub-agents.

            Roles: \(roleNames). You can also pass a custom system_prompt.
            mode: "foreground" (wait for the result) or "background" (fire and continue; check later with agent_status).
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Concise 5-10 word summary of what this delegate does, shown to the user."),
                "task": AgentToolParam(type: .string, description: "The concrete subtask for the sub-agent. Be specific: what to investigate/build/review, what to return."),
                "role": AgentToolParam(type: .string, description: "Role name (researcher/coder/reviewer/planner/custom). Defaults to a general assistant if omitted."),
                "system_prompt": AgentToolParam(type: .string, description: "Optional custom system prompt overriding the role's template."),
                "mode": AgentToolParam(type: .string, description: "foreground (default) or background.", enumValues: ["foreground", "background"]),
                "tools_allow": AgentToolParam(type: .string, description: "Optional comma-separated tool allowlist (e.g. 'shell_execute,file_read'). Default: all sub-agent tools."),
                "timeout_seconds": AgentToolParam(type: .integer, description: "Optional timeout override (default 600)."),
            ],
            required: ["tool_title", "task"]
        )
    }

    /// Execute an agent_delegate tool call. Returns the sub-agent summary as
    /// the tool result text so the parent agent can act on it.
    func executeAgentDelegate(from json: String) async -> TodoToolResult {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let task = dict["task"] as? String, !task.isEmpty else {
            return TodoToolResult(output: "Error: missing required 'task'", success: false)
        }

        // Resolve role.
        let roleName = dict["role"] as? String
        var role: AgentRole
        if let roleName, let found = AgentRole.loadAll().first(where: { $0.name.lowercased() == roleName.lowercased() }) {
            role = found
        } else {
            role = AgentRole(
                name: "General",
                systemPromptTemplate: """
                You are a capable sub-agent. Complete the delegated task, staying focused and concise.

                Task: {{task}}

                When done, report: what you did, key findings or outputs, and anything the parent agent should know.
                """
            )
        }

        // Custom system prompt override.
        if let customPrompt = dict["system_prompt"] as? String, !customPrompt.isEmpty {
            role = AgentRole(
                id: role.id, name: role.name,
                systemPromptTemplate: customPrompt,
                toolsAllow: role.toolsAllow,
                maxTurns: role.maxTurns,
                timeoutSeconds: role.timeoutSeconds,
                isBuiltIn: role.isBuiltIn
            )
        }

        // Timeout override.
        if let timeout = dict["timeout_seconds"] as? Int, timeout > 0 {
            role = AgentRole(
                id: role.id, name: role.name,
                systemPromptTemplate: role.systemPromptTemplate,
                toolsAllow: role.toolsAllow,
                maxTurns: role.maxTurns,
                timeoutSeconds: timeout,
                isBuiltIn: role.isBuiltIn
            )
        }

        // Mode.
        let mode = dict["mode"] as? String ?? "foreground"
        let activeEntry = resolveCurrentEntry()
        let sid = sessionId

        if mode == "background" {
            // Fire and forget; parent continues. The result is logged and a
            // notification surfaces it. (Full background-result surfacing is
            // a follow-up; foreground is the primary path.)
            _ = SubagentCoordinator.runInBackground(
                task: task, role: role,
                activeEntry: activeEntry, sessionId: sid
            )
            return TodoToolResult(
                output: "Delegated to sub-agent (role: \(role.name), background). The sub-agent is running; you may continue with other work.",
                success: true
            )
        }

        // Foreground: await the result.
        let result = await SubagentCoordinator.run(
            task: task, role: role,
            activeEntry: activeEntry, sessionId: sid
        )

        var out = "Sub-agent (\(role.name)) completed in \(result.turns) turn(s), \(result.toolCalls) tool call(s).\n\n"
        if let err = result.error {
            out += "⚠️ \(err)\n\n"
        }
        let summary = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            out += summary
        } else {
            out += "(no text output)"
        }
        return TodoToolResult(output: out, success: result.error == nil)
    }
}
