import Foundation

// MARK: - Todo Tools

extension AIChatViewModel {

    // MARK: - Tool Definitions

    /// The four todo tools appended to `makeAgentTools()`. Callers must also
    /// add the dispatch cases in `executeSingleToolUse` (ConcurrentTools).
    static func makeTodoToolDefinitions() -> [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "todo_create",
                description: "Create one or more todo items for the current session. Use for complex, multi-step work: break the task into concrete steps, create them all up front, then update each one as you complete it. Returns the created items with their IDs.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user."),
                    "items": AgentToolParam(type: .string, description: "A JSON array of items to create, each {\"title\": \"...\", \"detail\": \"optional\"}. Use a single item for one task."),
                ],
                required: ["tool_title", "items"]
            ),
            AgentToolDefinition(
                name: "todo_update",
                description: "Update a todo item's status, title, or detail. Status values: pending, in_progress, done, blocked. Use this to keep the todo list in sync as work progresses.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user."),
                    "id": AgentToolParam(type: .string, description: "The todo item ID (from todo_create or todo_list)."),
                    "status": AgentToolParam(type: .string, description: "New status: pending, in_progress, done, blocked (optional).", enumValues: ["pending", "in_progress", "done", "blocked"]),
                    "title": AgentToolParam(type: .string, description: "New title (optional)."),
                    "detail": AgentToolParam(type: .string, description: "New detail text (optional)."),
                ],
                required: ["tool_title", "id"]
            ),
            AgentToolDefinition(
                name: "todo_list",
                description: "List all todo items for the current session, ordered as created. Optionally filter by status. Use this to review what remains before starting or continuing work.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user."),
                    "status": AgentToolParam(type: .string, description: "Filter by status: pending, in_progress, done, blocked (optional; omit for all).", enumValues: ["pending", "in_progress", "done", "blocked"]),
                ],
                required: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "todo_clear",
                description: "Delete todo items. Pass an id to delete one item, or a status to delete all items with that status (e.g. 'done'). Use to tidy up completed work.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user."),
                    "id": AgentToolParam(type: .string, description: "Todo item ID to delete (optional)."),
                    "status": AgentToolParam(type: .string, description: "Delete all items with this status (optional).", enumValues: ["pending", "in_progress", "done", "blocked"]),
                ],
                required: ["tool_title"]
            ),
        ]
    }

    // MARK: - Executors

    func executeTodoCreate(from json: String) async -> TodoToolResult {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let itemsRaw = dict["items"] as? String,
              let itemsData = itemsRaw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: itemsData) as? [[String: Any]],
              !items.isEmpty else {
            return TodoToolResult(
                output: "Error: 'items' must be a JSON array of {\"title\": \"...\", \"detail\": \"...\"} objects",
                success: false
            )
        }

        var parsed: [(title: String, detail: String?)] = []
        for item in items {
            guard let title = item["title"] as? String, !title.isEmpty else {
                return TodoToolResult(output: "Error: each item needs a non-empty 'title'", success: false)
            }
            parsed.append((title: title, detail: item["detail"] as? String))
        }

        guard let sid = sessionId else {
            return TodoToolResult(output: "Error: no active session", success: false)
        }

        let created = await TodoStore.shared.create(sessionId: sid, titles: parsed)
        guard !created.isEmpty else {
            return TodoToolResult(output: "Error: could not create todos", success: false)
        }

        var out = "Created \(created.count) todo item(s):\n"
        for item in created {
            out += "- [\(item.status.rawValue)] \(item.title) (id: \(item.id.prefix(8)))\n"
        }
        out += "\nUse todo_update with an item's id to mark progress. Remaining counts: \(await pendingSummary(sid: sid))"
        return TodoToolResult(output: out, success: true)
    }

    func executeTodoUpdate(from json: String) async -> TodoToolResult {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = dict["id"] as? String else {
            return TodoToolResult(output: "Error: missing required 'id'", success: false)
        }
        guard let sid = sessionId else {
            return TodoToolResult(output: "Error: no active session", success: false)
        }

        var status: TodoItem.Status?
        if let raw = dict["status"] as? String {
            guard let parsed = TodoItem.Status(rawValue: raw) else {
                return TodoToolResult(
                    output: "Error: invalid status '\(raw)'. Valid: pending, in_progress, done, blocked",
                    success: false
                )
            }
            status = parsed
        }

        let updated = await TodoStore.shared.update(
            sessionId: sid, id: id,
            status: status,
            title: dict["title"] as? String,
            detail: dict["detail"] as? String
        )
        guard let updated else {
            return TodoToolResult(output: "Error: todo '\(id.prefix(8))' not found in this session", success: false)
        }

        let out = "Updated todo: [\(updated.status.rawValue)] \(updated.title) (id: \(updated.id.prefix(8)))\n\(await pendingSummary(sid: sid))"
        return TodoToolResult(output: out, success: true)
    }

    func executeTodoList(from json: String) async -> TodoToolResult {
        guard let sid = sessionId else {
            return TodoToolResult(output: "Error: no active session", success: false)
        }
        var filter: TodoItem.Status?
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = dict["status"] as? String {
            filter = TodoItem.Status(rawValue: raw)
        }

        let items = await TodoStore.shared.list(sessionId: sid, statusFilter: filter)
        guard !items.isEmpty else {
            return TodoToolResult(
                output: filter.map { "No \($0.rawValue) todos in this session." } ?? "No todos in this session. Use todo_create to add some.",
                success: true
            )
        }

        var out = "Todos (\(items.count)):\n"
        for item in items {
            let icon: String
            switch item.status {
            case .done: icon = "[x]"
            case .inProgress: icon = "[~]"
            case .blocked: icon = "[!]"
            case .pending: icon = "[ ]"
            }
            out += "- \(icon) \(item.title) (id: \(item.id.prefix(8)))\n"
            if let detail = item.detail, !detail.isEmpty {
                out += "    \(detail)\n"
            }
        }
        return TodoToolResult(output: out, success: true)
    }

    func executeTodoClear(from json: String) async -> TodoToolResult {
        guard let sid = sessionId else {
            return TodoToolResult(output: "Error: no active session", success: false)
        }
        var id: String?
        var status: TodoItem.Status?
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            id = dict["id"] as? String
            if let raw = dict["status"] as? String {
                status = TodoItem.Status(rawValue: raw)
            }
        }
        guard id != nil || status != nil else {
            return TodoToolResult(output: "Error: pass either 'id' or 'status' to todo_clear", success: false)
        }

        let deleted = await TodoStore.shared.delete(sessionId: sid, id: id, status: status)
        let what = id.map { "todo '\($0.prefix(8))'" } ?? status.map { "all \($0.rawValue) todos" } ?? "todos"
        return TodoToolResult(
            output: "Deleted \(deleted) \(what).\n\(await pendingSummary(sid: sid))",
            success: true
        )
    }

    // MARK: - Helpers

    private func pendingSummary(sid: String) async -> String {
        let items = await TodoStore.shared.list(sessionId: sid)
        let pending = items.filter { $0.status != .done }.count
        let done = items.count - pending
        return "\(done) done, \(pending) remaining."
    }
}
