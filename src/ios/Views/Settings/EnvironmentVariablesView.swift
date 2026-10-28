import SwiftUI
import UIKit

struct EnvironmentVariablesView: View {
    @StateObject private var store = EnvVarStore.shared
    @StateObject private var privacy = EnvVarPrivacyStore.shared
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var editingEntry: EnvVarEntry?
    @State private var revealedKeys: Set<String> = []
    @State private var copiedId: String?
    @State private var prefillKey = ""
    @State private var prefillValue = ""
    @State private var prefillNote = ""
    /// [T-envvar-disable] A `create_key` deep link for a name that already
    /// exists opens that variable's editor; these carry the link's value (if
    /// any) and whether to call out its "Enabled" switch (it is off).
    @State private var deepLinkValue: String?
    @State private var highlightEnabledFor: String?

    private var filteredEntries: [EnvVarEntry] {
        if searchText.isEmpty {
            return store.entries
        }
        return store.entries.filter { $0.key.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Privacy Mode", isOn: $privacy.enabled)
            } footer: {
                Text("When enabled, any environment variable value that appears in shell-execute output is replaced with a masked form (e.g. `sk-1********ajhks`) before reaching the model. Values shorter than 8 characters become all `*`. The user-visible output in chat is unchanged.")
            }

            if store.entries.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Environment Variables")
                            .font(.headline)
                        Text("Add variables like API keys or tokens that will be available in the shell environment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                ForEach(filteredEntries) { entry in
                    envVarRow(entry)
                }
                .onDelete(perform: deleteEntries)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Filter by name")
        .navigationTitle("Environment Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            EnvVarFormSheet(mode: .add, initialKey: prefillKey, initialValue: prefillValue, initialNote: prefillNote) { key, value, note, _ in
                store.add(key: key, value: value, note: note)
            }
            .onDisappear {
                prefillKey = ""
                prefillValue = ""
                prefillNote = ""
            }
        }
        .onAppear {
            if let pending = deepLink.pendingEnvVarCreate {
                let normalizedKey = pending.key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                deepLink.pendingEnvVarCreate = nil
                if let existing = store.entries.first(where: { $0.key == normalizedKey }) {
                    // [T-envvar-disable] Open the existing variable's editor
                    // instead of writing to it: the user sees (and decides
                    // about) its current value and its Enabled switch. Saving
                    // never turns a disabled variable back on by itself.
                    deepLinkValue = pending.value.isEmpty ? nil : pending.value
                    highlightEnabledFor = store.isEnabled(id: existing.id) ? nil : existing.id
                    editingEntry = existing
                } else {
                    prefillKey = pending.key
                    prefillValue = pending.value
                    prefillNote = pending.note
                    showingAddSheet = true
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            EnvVarFormSheet(
                mode: .edit,
                initialKey: entry.key,
                initialValue: deepLinkValue ?? store.value(forKey: entry.key) ?? "",
                initialNote: entry.note,
                initialEnabled: store.isEnabled(id: entry.id),
                highlightEnabled: highlightEnabledFor == entry.id,
                onSave: { key, value, note, enabled in
                    store.update(id: entry.id, key: key, value: value, note: note)
                    if let enabled { store.setEnabled(id: entry.id, enabled) }
                },
                onDelete: {
                    store.delete(id: entry.id)
                }
            )
            .onDisappear {
                deepLinkValue = nil
                highlightEnabledFor = nil
            }
        }
    }

    @ViewBuilder
    private func envVarRow(_ entry: EnvVarEntry) -> some View {
        let isRevealed = revealedKeys.contains(entry.id)
        let currentValue = store.value(forKey: entry.key) ?? ""
        // [T-envvar-disable]
        let isEnabled = store.isEnabled(id: entry.id)
        let isDuplicate = store.duplicateKeys.contains(entry.key)

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.key)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    if !isEnabled {
                        // Own key, not the shared "Disabled": zh-Hans reads 已禁用
                        // here (matching Android), while other screens keep 已停用.
                        EnvVarBadge(text: AppLocalized("Disabled (environment variable)"), color: .secondary)
                    }
                    if isDuplicate {
                        EnvVarBadge(text: AppLocalized("Duplicate name"), color: .orange)
                    }
                }
                Text(isRevealed ? currentValue : String(repeating: "\u{2022}", count: min(currentValue.count, 20)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // [T-shortcut-envvar] Shortcut-stored values can be long,
                    // multi-line text; keep the row compact when revealed.
                    .lineLimit(6)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    if isRevealed {
                        revealedKeys.remove(entry.id)
                    } else {
                        revealedKeys.insert(entry.id)
                    }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    UIPasteboard.general.string = "\(entry.key)=\(currentValue)"
                    withAnimation { copiedId = entry.id }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { if copiedId == entry.id { copiedId = nil } }
                    }
                } label: {
                    Image(systemName: copiedId == entry.id ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 13))
                        .foregroundStyle(copiedId == entry.id ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(isEnabled ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            editingEntry = entry
        }
        // [T-envvar-disable] Swiping left shows Delete and, beside it,
        // Disable / Enable. Declaring swipeActions replaces the implicit
        // onDelete swipe, so Delete is listed here (first = full swipe, as
        // before).
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.delete(id: entry.id)
            } label: {
                Label(AppLocalized("Delete"), systemImage: "trash")
            }
            Button {
                store.setEnabled(id: entry.id, !isEnabled)
            } label: {
                Label(isEnabled ? AppLocalized("Disable") : AppLocalized("Enable"),
                      systemImage: isEnabled ? "pause.circle" : "play.circle")
            }
            .tint(isEnabled ? .gray : .green)
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        let entriesToDelete = offsets.map { filteredEntries[$0] }
        for entry in entriesToDelete {
            store.delete(id: entry.id)
        }
    }
}

// MARK: - Form Sheet

private struct EnvVarFormSheet: View {
    enum Mode { case add, edit }

    let mode: Mode
    var initialKey: String = ""
    var initialValue: String = ""
    var initialNote: String = ""
    /// [T-envvar-disable] nil in add mode (a new variable starts enabled).
    var initialEnabled: Bool? = nil
    /// Call out the switch (a deep link landed on a disabled variable).
    var highlightEnabled: Bool = false
    /// key, value, note, enabled (nil in add mode).
    let onSave: (String, String, String, Bool?) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var note = ""
    @State private var enabled = true
    @State private var showingDeleteConfirm = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case key, value, note }

    private var isValid: Bool {
        EnvVarStore.isValidKey(key)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("NAME", text: Binding(
                        get: { key },
                        set: { key = $0.uppercased() }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .key)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .value }
                } header: {
                    Text("Name")
                } footer: {
                    if !key.isEmpty && !isValid {
                        Text("Must start with a letter and contain only letters, digits, and underscores.")
                            .foregroundStyle(.red)
                    }
                }

                Section("Value") {
                    if EnvVarStore.isShortcutKey(key) {
                        // [T-shortcut-envvar] Shortcut-stored text (an SMS, a
                        // note) can span lines; a single-line field would
                        // flatten it on save.
                        TextField("Value", text: $value, axis: .vertical)
                            .lineLimit(1...8)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .value)
                    } else {
                        TextField("Value", text: $value)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .value)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .note }
                    }
                }

                Section("Note") {
                    ZStack(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("Describe what this variable is for (optional)")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $note)
                            .frame(minHeight: 80)
                            .focused($focusedField, equals: .note)
                            .scrollContentBackground(.hidden)
                    }
                }

                if mode == .edit, initialEnabled != nil {
                    Section {
                        Toggle(AppLocalized("Enabled"), isOn: $enabled)
                            .listRowBackground(highlightEnabled && !enabled
                                               ? Color.orange.opacity(0.18) : nil)
                    }
                }

                if mode == .edit, onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label {
                                Text("Delete Variable")
                            } icon: {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white)
                                    .frame(width: 21, height: 21)
                                    .background(.red, in: Circle())
                            }
                        }
                    }
                }
            }
            .navigationTitle(mode == .add ? "Add Variable" : "Edit Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .add ? "Add" : "Save") {
                        onSave(key, value, note.trimmingCharacters(in: .whitespacesAndNewlines),
                               initialEnabled == nil ? nil : enabled)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert(
            AppLocalized("Delete this variable?"),
            isPresented: $showingDeleteConfirm
        ) {
            Button(AppLocalized("Delete"), role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        }
        .onAppear {
            key = initialKey
            value = initialValue
            note = initialNote
            enabled = initialEnabled ?? true
        }
        // Use .task instead of onAppear+DispatchQueue: the wait is cancellable
        // (sheet dismissed mid-animation cancels cleanly) and we can resign any
        // existing first responder in the parent view tree first — otherwise
        // the chat input / iSH terminal can keep firstResponder and iOS
        // suppresses the sheet's keyboard intermittently.
        .task {
            // Resign any first responder owned by the presenting view tree so
            // UIKit doesn't hand the keyboard back to it when the sheet's
            // TextField asks for focus.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            // Wait for the sheet's present/detent animation to settle before
            // requesting focus. 0.45s covers both .medium and .large detents
            // on slower devices; if the sheet is dismissed sooner, .task is
            // cancelled and focus is never set.
            try? await Task.sleep(nanoseconds: 450_000_000)
            if mode == .add {
                focusedField = .key
            }
        }
    }
}

/// [T-envvar-disable] Small capsule tag on a variable row.
private struct EnvVarBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}
