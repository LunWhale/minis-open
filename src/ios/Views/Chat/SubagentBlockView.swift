//
//  SubagentBlockView.swift
//  MinisApp
//
//  View of sub-agent runs: role badge, status, turns/tool calls, and an
//  expandable summary. Surfaced from the chat "…" menu (like TodoPanelView)
//  so the user can inspect what sub-agents did — including background runs
//  that finish after the parent turn ended.
//

import SwiftUI

struct SubagentBlockView: View {
    @State private var runs: [SubagentCoordinator.RunRecord] = []
    @State private var expandedID: String?

    var body: some View {
        NavigationStack {
            List {
                if runs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "person.2")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No sub-agent runs yet")
                                .font(.headline)
                            Text("Delegate work with agent_delegate and it will appear here — including background runs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                } else {
                    ForEach(runs) { run in
                        runRow(run)
                    }
                }
            }
            .navigationTitle("Sub-agent Runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { runs = SubagentCoordinator.recentRuns() }
                }
            }
            .task { runs = SubagentCoordinator.recentRuns() }
        }
    }

    private func runRow(_ run: SubagentCoordinator.RunRecord) -> some View {
        let isExpanded = expandedID == run.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expandedID = isExpanded ? nil : run.id }
            } label: {
                HStack(spacing: 10) {
                    Text(statusIcon(run.status))
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.roleName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(run.id) · \(run.status)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(run.turns) turns · \(run.toolCalls) tools")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(run.task)
                        .font(.footnote)
                    if let summary = run.summary, !summary.isEmpty {
                        Text("Summary")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Text(summary)
                            .font(.footnote)
                    }
                    if let err = run.error {
                        Text("Error: \(err)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let finished = run.finishedAt {
                        Text("Finished \(finished.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "running": return "🔄"
        case "done": return "✅"
        case "error": return "❌"
        default: return "⏹️"
        }
    }
}
