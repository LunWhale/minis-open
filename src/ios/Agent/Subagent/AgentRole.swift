import Foundation

// MARK: - Agent Roles (Sub-agent system)

/// A named, user-definable role for sub-agent delegation. Each role pairs a
/// system-prompt template with a default tool allowlist so the delegating
/// (parent) agent can say `agent_delegate(task: "...", role: "reviewer")`
/// and get a purpose-built sub-agent without hand-writing a system prompt.
///
/// Roles are user-editable: built-ins are seeded on first launch and can be
/// renamed/edited/duplicated; custom roles persist in UserDefaults.
struct AgentRole: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    /// System prompt template. May contain a `{{task}}` placeholder that is
    /// replaced with the delegated task text at run time.
    var systemPromptTemplate: String
    /// Tool names the sub-agent is allowed to call. Empty = allow all tools
    /// the parent passes in.
    var toolsAllow: [String]
    /// Hard cap on sub-agent turns (each turn = one LLM response + tool calls).
    var maxTurns: Int
    /// Default timeout in seconds for the whole sub-agent run.
    var timeoutSeconds: Int
    var isBuiltIn: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        systemPromptTemplate: String,
        toolsAllow: [String] = [],
        maxTurns: Int = 25,
        timeoutSeconds: Int = 600,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPromptTemplate = systemPromptTemplate
        self.toolsAllow = toolsAllow
        self.maxTurns = maxTurns
        self.timeoutSeconds = timeoutSeconds
        self.isBuiltIn = isBuiltIn
    }

    /// Resolve the effective system prompt for a task.
    func systemPrompt(for task: String) -> String {
        systemPromptTemplate.replacingOccurrences(of: "{{task}}", with: task)
    }

    // MARK: - Built-ins

    static let builtIns: [AgentRole] = [
        AgentRole(
            id: "role-researcher",
            name: "Researcher",
            systemPromptTemplate: """
            You are a focused research sub-agent. Your job is to gather and synthesize information on the delegated task, then report back a concise summary.

            Task: {{task}}

            Research thoroughly but stay on-topic. Use shell/file/browser tools as needed. When done, report: key findings, sources or files examined, and any open questions. Do not perform unrelated work.
            """,
            toolsAllow: [],
            maxTurns: 20,
            timeoutSeconds: 600,
            isBuiltIn: true
        ),
        AgentRole(
            id: "role-coder",
            name: "Coder",
            systemPromptTemplate: """
            You are a focused coding sub-agent. Implement the delegated task in the sandbox workspace, following good engineering practice: read relevant files first, write clear code, test what you can, and keep changes minimal and scoped.

            Task: {{task}}

            When done, report: what you changed (files), how you tested it, and any follow-up work the parent agent should know about.
            """,
            toolsAllow: [],
            maxTurns: 30,
            timeoutSeconds: 900,
            isBuiltIn: true
        ),
        AgentRole(
            id: "role-reviewer",
            name: "Reviewer",
            systemPromptTemplate: """
            You are an adversarial code reviewer sub-agent. Review the delegated code or plan for bugs, security issues, performance problems, and edge cases. Be specific and concrete.

            Review target: {{task}}

            When done, report: issues found (severity-tagged), concrete suggestions, and what looks solid. Do not rewrite code unless asked.
            """,
            toolsAllow: ["file_read", "file_edit", "shell_execute", "todo_list"],
            maxTurns: 15,
            timeoutSeconds: 600,
            isBuiltIn: true
        ),
        AgentRole(
            id: "role-planner",
            name: "Planner",
            systemPromptTemplate: """
            You are a planning sub-agent. Produce a concrete, ordered execution plan for the delegated task — steps, dependencies, tool usage, and risks. Prefer todo items for trackable steps.

            Task: {{task}}

            When done, report: the ordered plan with per-step expected outcomes, and any assumptions or risks.
            """,
            toolsAllow: ["todo_create", "todo_list", "file_read", "shell_execute"],
            maxTurns: 15,
            timeoutSeconds: 600,
            isBuiltIn: true
        ),
    ]

    // MARK: - Store

    static let storageKey = "subagent.roles.v1"

    static func loadAll() -> [AgentRole] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let custom = try? JSONDecoder().decode([AgentRole].self, from: data) {
            // Merge: built-ins always present (may be edited), plus customs.
            var result = builtIns
            for role in custom where !role.isBuiltIn {
                result.append(role)
            }
            // Apply edits to built-ins.
            for role in custom where role.isBuiltIn {
                if let idx = result.firstIndex(where: { $0.id == role.id }) {
                    result[idx] = role
                }
            }
            return result
        }
        return builtIns
    }

    static func saveAll(_ roles: [AgentRole]) {
        if let data = try? JSONEncoder().encode(roles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
