//
//  SubagentRolesView.swift
//  MinisApp
//
//  Manage sub-agent roles: edit built-in role prompts, add/remove custom
//  roles, tweak max turns / timeouts. Backed by AgentRole's UserDefaults
//  store. Accessible from Settings → Agent → Sub-agent Roles.
//

import SwiftUI

struct SubagentRolesView: View {
    @State private var roles: [AgentRole] = AgentRole.loadAll()
    @State private var showingAdd = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($roles) { $role in
                        NavigationLink {
                            RoleEditorView(role: $role) {
                                persist()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(role.name)
                                        .font(.headline)
                                    if role.isBuiltIn {
                                        Text("built-in")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(role.maxTurns) turns · \(role.timeoutSeconds)s timeout")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        roles.remove(atOffsets: indexSet)
                        persist()
                    }
                } header: {
                    Text("Roles")
                } footer: {
                    Text("Sub-agents are delegated with agent_delegate. Each role defines the sub-agent's system prompt, tool allowlist, and safety limits.")
                }
            }
            .navigationTitle("Sub-agent Roles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        roles.append(AgentRole(
                            name: "New Role",
                            systemPromptTemplate: "You are a focused sub-agent.\n\nTask: {{task}}\n\nReport concisely when done."
                        ))
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                // The newly added role is the last element; edit it now.
                if let idx = roles.indices.last {
                    NavigationStack {
                        RoleEditorView(role: $roles[idx]) {
                            persist()
                            showingAdd = false
                        }
                    }
                }
            }
        }
    }

    private func persist() {
        AgentRole.saveAll(roles)
    }
}

/// Editor for a single role.
private struct RoleEditorView: View {
    @Binding var role: AgentRole
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Basics") {
                TextField("Name", text: $role.name)
                Stepper("Max turns: \(role.maxTurns)", value: $role.maxTurns, in: 1...100)
                Stepper("Timeout: \(role.timeoutSeconds)s", value: $role.timeoutSeconds, in: 30...3600, step: 30)
            }
            Section("System Prompt") {
                TextEditor(text: $role.systemPromptTemplate)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
                Text("Use {{task}} as the placeholder for the delegated task.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("Tool Allowlist") {
                Text("Comma-separated tool names. Empty = all sub-agent tools.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("shell_execute,file_read", text: toolsBinding)
            }
        }
        .navigationTitle(role.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    onSave()
                    dismiss()
                }
            }
        }
    }

    private var toolsBinding: Binding<String> {
        Binding(
            get: { role.toolsAllow.joined(separator: ", ") },
            set: {
                role.toolsAllow = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
