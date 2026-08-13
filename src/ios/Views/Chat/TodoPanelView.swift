//
//  TodoPanelView.swift
//  MinisApp
//
//  Session-scoped todo list panel: reflects the agent's todo_create /
//  todo_update / todo_clear tool calls in real time. The agent drives the
//  data via TodoStore; this view is read-mostly with quick status toggles.
//

import SwiftUI

struct TodoPanelView: View {
    /// Real session id, or nil for a draft that hasn't sent its first message.
    let sessionId: String?
    /// Materializes a draft session and returns its real id (same contract as
    /// SessionSkillsView). Called lazily on first interaction.
    var ensureSessionId: (() async -> String)?
    @Environment(\.dismiss) private var dismiss

    @State private var items: [TodoItem] = []
    @State private var loading = false
    @State private var errorMessage: String?

    private let statusOrder: [TodoItem.Status] = [.pending, .inProgress, .blocked, .done]

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading todos…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "No todos",
                        systemImage: "checklist",
                        description: Text("Ask the agent to break a task into steps and it will track them here.")
                    )
                } else {
                    List {
                        ForEach(statusOrder, id: \.self) { status in
                            let sectionItems = items.filter { $0.status == status }
                            if !sectionItems.isEmpty {
                                Section {
                                    ForEach(sectionItems) { item in
                                        todoRow(item)
                                    }
                                } header: {
                                    Label(status.displayName, systemImage: statusIcon(status))
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Todos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    // MARK: - Row

    private func todoRow(_ item: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Status toggle: tap cycles pending → in_progress → done.
            Button {
                cycleStatus(item)
            } label: {
                Image(systemName: statusIcon(item.status))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor(item.status))
                    .frame(width: 28, height: 28)
                    .background(statusColor(item.status).opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle \(item.title) status")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .strikethrough(item.status == .done, color: .secondary)
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text("ID \(item.id.prefix(8))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if item.status == .blocked {
                Button {
                    unblock(item)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unblock \(item.title)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func cycleStatus(_ item: TodoItem) {
        let next: TodoItem.Status
        switch item.status {
        case .pending: next = .inProgress
        case .inProgress: next = .done
        case .done: next = .pending
        case .blocked: next = .inProgress
        }
        mutate(item, status: next)
    }

    private func unblock(_ item: TodoItem) {
        mutate(item, status: .inProgress)
    }

    private func mutate(_ item: TodoItem, status: TodoItem.Status) {
        Task { await mutateAsync(item, status: status) }
    }

    private func mutateAsync(_ item: TodoItem, status: TodoItem.Status) async {
        guard let sid = await resolveSessionIdAsync() else { return }
        _ = await TodoStore.shared.update(sessionId: sid, id: item.id, status: status, title: nil, detail: nil)
        await reload()
    }
    // MARK: - Data

    private func reload() async {
        guard let sid = await resolveSessionIdAsync() else { return }
        loading = true
        defer { loading = false }
        items = await TodoStore.shared.list(sessionId: sid)
    }

    private func resolveSessionIdAsync() async -> String? {
        if let sessionId { return sessionId }
        guard let ensureSessionId else { return nil }
        return await ensureSessionId()
    }

    // MARK: - Style

    private func statusIcon(_ status: TodoItem.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.inset.filled"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .done: return .green
        case .blocked: return .orange
        }
    }
}
