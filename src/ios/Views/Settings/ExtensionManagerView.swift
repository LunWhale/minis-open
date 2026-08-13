//
//  ExtensionManagerView.swift
//  MinisApp
//
//  Manage .minisx extensions: install from zip, enable/disable, uninstall,
//  view declared permissions and kinds. Extensions can add agent tools,
//  commands, event hooks, UI widgets, and themes.
//

import SwiftUI
import UniformTypeIdentifiers

struct ExtensionManagerView: View {
    @State private var records: [ExtensionStore.Record] = []
    @State private var showFilePicker = false
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var showInfo: ExtensionStore.Record?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No extensions installed")
                                .font(.headline)
                            Text("Extensions are .minisx bundles (zip) with a manifest.json. They can add agent tools, slash commands, event hooks, UI widgets, and themes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                } else {
                    ForEach(records) { record in
                        extensionRow(record)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Extensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isInstalling)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.zip, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .task { await reload() }
        }
    }

    // MARK: - Row

    private func extensionRow(_ record: ExtensionStore.Record) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.name)
                        .font(.headline)
                    Text("v\(record.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(record.id)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    ForEach(record.kinds, id: \.self) { kind in
                        Text(kind)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { record.enabled },
                set: { newValue in
                    toggle(record, enabled: newValue)
                }
            ))
            .labelsHidden()
            .onTapGesture {
                showInfo = record
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                showInfo = record
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button(role: .destructive) {
                uninstall(record)
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                uninstall(record)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sheet(item: $showInfo) { record in
            ExtensionDetailView(record: record)
        }
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            // fileImporter gives a security-scoped URL.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            isInstalling = true
            errorMessage = nil
            Task {
                do {
                    let manifest = try await ExtensionInstaller.install(from: url)
                    await ExtensionRegistry.shared.reload()
                    await reload()
                    isInstalling = false
                    AppLogger(category: "Extension").info("Installed \(manifest.id) v\(manifest.version)")
                } catch {
                    errorMessage = error.localizedDescription
                    isInstalling = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ record: ExtensionStore.Record, enabled: Bool) {
        Task {
            do {
                try await ExtensionStore.shared.setEnabled(id: record.id, enabled: enabled)
                await ExtensionRegistry.shared.reload()
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func uninstall(_ record: ExtensionStore.Record) {
        Task {
            do {
                try await ExtensionStore.shared.uninstall(id: record.id)
                await ExtensionRegistry.shared.reload()
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reload() async {
        records = await ExtensionStore.shared.list()
    }
}

// MARK: - Detail

private struct ExtensionDetailView: View {
    let record: ExtensionStore.Record
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Name", value: record.name)
                    LabeledContent("ID", value: record.id)
                    LabeledContent("Version", value: record.version)
                    LabeledContent("Installed", value: record.installedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section("Capabilities") {
                    ForEach(record.kinds, id: \.self) { kind in
                        Label(kind, systemImage: capabilityIcon(kind))
                    }
                }
                Section("Declared Permissions") {
                    if record.permissions.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(record.permissions, id: \.self) { perm in
                            Label(perm, systemImage: "checkmark.shield")
                        }
                    }
                }
            }
            .navigationTitle(record.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func capabilityIcon(_ kind: String) -> String {
        switch kind {
        case "agent-tool": return "wrench.and.screwdriver"
        case "command": return "terminal"
        case "event-hook": return "bolt"
        case "ui-widget": return "rectangle.inset.filled.and.person.filled"
        case "theme": return "paintpalette"
        default: return "puzzlepiece"
        }
    }
}

extension ExtensionStore.Record: Identifiable {}
