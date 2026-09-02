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
    @State private var showSettings: ExtensionStore.Record?
    @State private var settingsDefs: [String: [ExtensionManifest.SettingDef]] = [:]
    @State private var showDebugLog = false
    @Environment(\.dismiss) private var dismiss

    /// True when this page is pushed from the Settings list, where an
    /// ambient NavigationStack already exists. Opening a second stack there
    /// leaves the row sheets without a valid presentation anchor, which used
    /// to tear down the enclosing Settings sheet instead of showing the
    /// plugin's settings. False = sheet root, so provide the bar + Done.
    var embedded: Bool = false

    var body: some View {
        Group {
            if embedded {
                stackContent
            } else {
                NavigationStack { stackContent }
            }
        }
    }

    private var stackContent: some View {
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
                    if !embedded {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showDebugLog = true
                        } label: {
                            Image(systemName: "scroll")
                        }
                        .accessibilityLabel("Extension Debug Log")
                        Button {
                            showFilePicker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(isInstalling)
                    }
                }
            }
            .sheet(isPresented: $showDebugLog) {
                ExtensionDebugView()
            }
            // NOTE: these two sheets must stay at List level (single
            // declaration). Attaching `.sheet(item:)` inside `extensionRow`
            // registers one presenter per ForEach row against the same
            // @State, so setting it made every row present at once; the
            // conflicting presentation tore down the enclosing Settings
            // sheet instead of showing the plugin's settings.
            .sheet(item: $showInfo) { record in
                ExtensionDetailView(record: record)
            }
            .sheet(item: $showSettings) { record in
                ExtensionSettingsView(
                    extensionID: record.id,
                    name: record.name,
                    settings: settingsDefs[record.id] ?? []
                )
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
                    if BuiltinExtension.isBuiltin(record.id) {
                        Text("Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
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
                if !record.description.isEmpty {
                    Text(record.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if hasSettings(record) {
                Button {
                    showSettings = record
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(record.name) Settings")
            }
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
            if hasSettings(record) {
                Button {
                    showSettings = record
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            if !BuiltinExtension.isBuiltin(record.id) {
                Button(role: .destructive) {
                    uninstall(record)
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
            }
        }
        .swipeActions {
            if !BuiltinExtension.isBuiltin(record.id) {
                Button(role: .destructive) {
                    uninstall(record)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Whether this extension declares any author settings (manifest
    /// `settings` array) — controls the ⚙️ button visibility.
    private func hasSettings(_ record: ExtensionStore.Record) -> Bool {
        !(settingsDefs[record.id] ?? []).isEmpty
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            isInstalling = true
            errorMessage = nil
            Task {
                // [T-filepick-ingest] The scope bracket used to sit in the OUTER
                // function with a `defer`, so it stopped accessing as soon as
                // handleFileImport returned — while this Task was still reading
                // the zip. Bundles from a document provider therefore failed with
                // a read error that looked like a corrupt extension. The bracket
                // now covers the read itself, and a false return is tolerated
                // because .fileImporter usually hands back an in-container copy.
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
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
            // Dismissing the picker arrives as a failure; don't show it as an
            // install error.
            if !FilePickIngest.isUserCancellation(error) {
                errorMessage = error.localizedDescription
            }
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
        // Load settings schemas for the ⚙️ buttons. Built-in plugins declare
        // their settings via BuiltinExtension.settings(id:) (native code);
        // .minisx bundles declare them in their manifest.json.
        var defs: [String: [ExtensionManifest.SettingDef]] = [:]
        for record in records {
            if BuiltinExtension.isBuiltin(record.id) {
                defs[record.id] = BuiltinExtension.settings(id: record.id)
                continue
            }
            let url = record.bundleURL.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: url),
               let manifest = try? ExtensionManifest.parse(data: data) {
                defs[record.id] = manifest.settings ?? []
            } else {
                defs[record.id] = []
            }
        }
        settingsDefs = defs
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
                    if !record.description.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What it does")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.description)
                                .font(.body)
                        }
                    }
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
        case "prompt": return "text.bubble"
        default: return "puzzlepiece"
        }
    }
}
