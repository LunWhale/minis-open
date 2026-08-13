import Foundation

// MARK: - Todo Models

/// A single todo item, scoped to a chat session.
struct TodoItem: Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done
        case blocked

        var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .inProgress: return "In Progress"
            case .done: return "Done"
            case .blocked: return "Blocked"
            }
        }
    }

    let id: String
    let sessionId: String
    var title: String
    var detail: String?
    var status: Status
    var order: Int
    var parentId: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        title: String,
        detail: String? = nil,
        status: Status = .pending,
        order: Int = 0,
        parentId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.detail = detail
        self.status = status
        self.order = order
        self.parentId = parentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Result payload returned to the model from a todo tool call.
struct TodoToolResult {
    let output: String
    let success: Bool
}
