//
//  ExtensionSettingsView.swift
//  MinisApp
//
//  Per-extension Settings page. The extension author declares settings in
//  manifest.json (`settings: [{key,label,type,default,options?}]`); this
//  view renders a form from that schema and persists values through
//  ExtensionSettingsStore. Agent-side scripts read them via
//  `minis.api.settings.get(key)`.
//

import SwiftUI

struct ExtensionSettingsView: View {
    let extensionID: String
    let name: String
    let settings: [ExtensionManifest.SettingDef]

    @State private var values: [String: Any] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if settings.isEmpty {
                    Section {
                        Text("This extension does not declare any settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(settings, id: \.key) { def in
                        settingRow(def)
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { reset() }
                }
            }
            .onAppear { load() }
        }
    }

    private func load() {
        values = ExtensionSettingsStore.shared.values(extensionID: extensionID, settings: settings)
    }

    private func reset() {
        ExtensionSettingsStore.shared.reset(extensionID: extensionID)
        load()
    }

    // MARK: - Rows

    @ViewBuilder
    private func settingRow(_ def: ExtensionManifest.SettingDef) -> some View {
        switch def.type {
        case "boolean":
            Toggle(def.label, isOn: boolBinding(def))
        case "number":
            Section {
                LabeledContent(def.label) {
                    TextField(def.placeholder ?? "", value: numberBinding(def), format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                if let d = def.description {
                    Text(d).font(.caption2).foregroundStyle(.secondary)
                }
            }
        case "select":
            Section {
                Picker(def.label, selection: selectBinding(def)) {
                    ForEach(def.options ?? [], id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                if let d = def.description {
                    Text(d).font(.caption2).foregroundStyle(.secondary)
                }
            }
        default: // "text"
            Section {
                TextField(def.placeholder ?? def.label, text: textBinding(def))
                    .textInputAutocapitalization(.never)
                if let d = def.description {
                    Text(d).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Bindings

    private func boolBinding(_ def: ExtensionManifest.SettingDef) -> Binding<Bool> {
        Binding(
            get: { (values[def.key] as? Bool) ?? ((def.default?.value as? Bool) ?? false) },
            set: { newValue in
                values[def.key] = newValue
                ExtensionSettingsStore.shared.set(extensionID: extensionID, key: def.key, value: newValue)
            }
        )
    }

    private func textBinding(_ def: ExtensionManifest.SettingDef) -> Binding<String> {
        Binding(
            get: { (values[def.key] as? String) ?? ((def.default?.value as? String) ?? "") },
            set: { newValue in
                values[def.key] = newValue
                ExtensionSettingsStore.shared.set(extensionID: extensionID, key: def.key, value: newValue)
            }
        )
    }

    private func numberBinding(_ def: ExtensionManifest.SettingDef) -> Binding<Double> {
        Binding(
            get: {
                if let n = values[def.key] as? Double { return n }
                if let i = values[def.key] as? Int { return Double(i) }
                return (def.default?.value as? Double) ?? 0
            },
            set: { newValue in
                values[def.key] = newValue
                ExtensionSettingsStore.shared.set(extensionID: extensionID, key: def.key, value: newValue)
            }
        )
    }

    private func selectBinding(_ def: ExtensionManifest.SettingDef) -> Binding<String> {
        Binding(
            get: {
                let current = (values[def.key] as? String) ?? ""
                let options = def.options ?? []
                return options.contains(current) ? current : (options.first ?? "")
            },
            set: { newValue in
                values[def.key] = newValue
                ExtensionSettingsStore.shared.set(extensionID: extensionID, key: def.key, value: newValue)
            }
        )
    }
}
