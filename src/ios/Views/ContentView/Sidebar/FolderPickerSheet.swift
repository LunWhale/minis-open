//
//  FolderPickerSheet.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Move-to-Group picker: FolderPickerOrder (most recently active group first),
//  the pending request and the sheet shared by multi-select, the row context
//  menu and other entry points.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - [T-folder-picker-recency] Move-to-Group picker order

/// Order of the Move-to-Group picker: most recently active group first.
///
/// A group's last activity is the newest of:
/// - its newest member session's `updatedAt` (a new message, an edit);
/// - the group's own `updatedAt` / `createdAt` (renamed, re-described, or just
///   created — which is also all an EMPTY group has).
/// Ties keep the incoming order (the home list's group order), so equal
/// groups never jitter between presentations.
enum FolderPickerOrder {
    static func lastActive(folderUpdatedAt: Date, folderCreatedAt: Date,
                           newestMemberUpdatedAt: Date?) -> Date {
        max(folderUpdatedAt, folderCreatedAt, newestMemberUpdatedAt ?? .distantPast)
    }

    /// Stable: equal activity keeps the original relative order.
    static func byRecentActivity<T>(_ items: [T], lastActive: (T) -> Date) -> [T] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, at: lastActive($0.element)) }
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.offset < $1.offset }
            .map(\.item)
    }
}
// END FolderPickerOrder

/// A pending "move sessions to folder" interaction, presented as a sheet.
struct FolderPickerRequest: Identifiable {
    let id = UUID()
    let sessionIds: Set<String>
    let fromMultiSelect: Bool
    let anyFiled: Bool
}

/// Shared folder picker: existing folders, inline "new folder" creation, and
/// (when a target is already filed) "remove from folder". One sheet serves the
/// multi-select toolbar, the row context menu, and later entry points, so the
/// flows can't drift apart.
struct FolderPickerSheet: View {
    enum Choice {
        case existing(String)                    // folder id
        case create(name: String, desc: String?) // new group name + optional description
        case removeFromFolder
    }

    /// One pickable folder with the display aggregates the row needs — the
    /// same composed icon and "N chats · context" subtitle the home group
    /// card shows, so the picker and the list describe a group identically.
    /// Computed by the presenter (which owns sessions), not here.
    struct FolderItem: Identifiable {
        let folder: ChatFolder
        let glyphs: [FolderGlyph]   // top-3 distinct member category glyphs
        let count: Int
        let subtitle: String?       // desc if set, else newest member title
        /// [T-folder-summary-lock] Set when `subtitle` is that member's title
        /// (not the folder's description), so a locked member stays blurred.
        var subtitleSessionId: String? = nil
        var id: String { folder.id }
    }

    let items: [FolderItem]
    let sessionIds: [String]
    let anyFiled: Bool
    let onChoose: (Choice) -> Void

    @State private var newFolderName = ""
    @State private var newFolderDesc = ""
    @FocusState private var nameFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var suggesting = false
    @State private var suggestedMerge: (folderId: String, folderName: String)?
    @State private var suggestFailed = false

    private var sessionCount: Int { sessionIds.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(Color.accentColor)
                        TextField("New Group Name", text: $newFolderName)
                            .focused($nameFieldFocused)
                            .submitLabel(.next)
                    }
                    // One-sentence auto-grouping context (≤100 chars). Typed
                    // here or prefilled by AI Suggest; never shown in the
                    // list, editable later from Rename Group.
                    TextField("Description (optional, guides auto-grouping)", text: $newFolderDesc, axis: .vertical)
                        .lineLimit(1...2)
                        .font(.subheadline)
                        .onChange(of: newFolderDesc) { v in
                            if v.count > 100 { newFolderDesc = String(v.prefix(100)) }
                        }
                    // ✨ AI suggest — nothing auto-applies. A merge suggestion
                    // renders as its own confirm row below; a create
                    // suggestion prefills the name field and waits for the
                    // user's Create tap. Failure degrades silently to the
                    // manual flow (the sheet is already the manual flow).
                    // Bottom row of the create area: AI Suggest leading,
                    // Create trailing. Two independent tap targets in one
                    // List row need .borderless — a plain Button row would
                    // swallow the whole-row tap.
                    HStack {
                        Button {
                            runSuggest()
                        } label: {
                            HStack {
                                if suggesting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(suggestFailed ? "AI Suggest (failed — try again)" : "AI Suggest")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(suggesting)
                        Spacer()
                        Button("Create", action: createIfNamed)
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                            .disabled(trimmedName.isEmpty || duplicateFolder != nil)
                    }
                    // [T-folder-duplicate-name] Name already taken. Says so, and
                    // offers the one-tap way out — filing into the existing group
                    // is almost always what was meant. Create is disabled above,
                    // so this is a real choice rather than a warning to ignore.
                    if let dup = duplicateFolder {
                        Button {
                            onChoose(.existing(dup.id))
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    // Folder name is user data — interpolated, not a key.
                                    Text("“\(dup.name)” already exists")
                                        .font(.subheadline)
                                    Text("Rename to something else, or tap to use it")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    if let merge = suggestedMerge {
                        Button {
                            onChoose(.existing(merge.folderId))
                        } label: {
                            Label {
                                // Folder name is user data — interpolated, not a key.
                                Text("Move into “\(merge.folderName)”?")
                            } icon: {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }

                // Rendered when there is anything to put in it: existing groups to
                // pick from, or a membership the "No Group" row can clear. Both
                // empty (no folders and the target is unfiled) means no section at
                // all, rather than a bare "Groups" header over nothing.
                if !items.isEmpty || anyFiled {
                    Section("Groups") {
                    // "No Group" — the explicit way to end up ungrouped.
                    //
                    // FIRST row of the Groups section, not a trailing section, for
                    // two reasons. (1) Reachability: measured on an iPhone 11, a
                    // trailing section put this row at y≈940 while the .medium
                    // detent ends at 896 — the accessibility tree reported
                    // `hittable: false`, i.e. the option existed but could not be
                    // tapped without first scrolling or expanding the sheet.
                    // (2) Semantics: it is a peer choice among "where does this
                    // chat live", so it belongs with the destinations rather than
                    // formatted like a destructive afterthought.
                    //
                    // Gated on `anyFiled`: for an already-ungrouped session it
                    // would be a no-op row, which reads as a broken control.
                    if anyFiled {
                        Button {
                            onChoose(.removeFromFolder)
                        } label: {
                            HStack(spacing: 8) {
                                // Sized to match FolderComposedIcon below so the
                                // row's text baseline lines up with the group rows.
                                ZStack {
                                    Circle()
                                        .fill(Color(UIColor.tertiarySystemFill))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "folder.badge.minus")
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("No Group")
                                        .foregroundStyle(Color(UIColor.label))
                                        .lineLimit(1)
                                    Text("Remove from its current group")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(UIColor.secondaryLabel))
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        // VoiceOver reads label + hint as ONE action; without this
                        // the two stacked Texts are announced as unrelated elements.
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("No Group"))
                        .accessibilityHint(Text("Remove from its current group"))
                    }
                    ForEach(items) { item in
                            Button {
                                onChoose(.existing(item.folder.id))
                            } label: {
                                // Mirrors the home group card's identity row:
                                // same composed circle icon, same
                                // "N chats · context" subtitle (and thus the
                                // same localization keys).
                                HStack(spacing: 8) {
                                    FolderComposedIcon(glyphs: item.glyphs, diameter: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        // Folder names are user data — verbatim.
                                        Text(item.folder.name)
                                            .foregroundStyle(Color(UIColor.label))
                                            .lineLimit(1)
                                        Group {
                                            if let sub = item.subtitle {
                                                FolderSummaryLine(count: item.count, title: sub,
                                                                  sessionId: item.subtitleSessionId)
                                            } else if item.count > 0 {
                                                Text("\(item.count) chats")
                                            } else {
                                                Text("Empty group")
                                            }
                                        }
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(UIColor.secondaryLabel))
                                        .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            // Explicitly typed: a bare ternary of two literals infers `String`,
            // which would pick the non-localizing navigationTitle overload and
            // ship the English source text to every locale. As
            // `LocalizedStringKey` both branches keep their `%lld` interpolation
            // and resolve through Localizable.xcstrings.
            .navigationTitle(anyFiled
                             ? LocalizedStringKey("Change Group for \(sessionCount)")
                             : LocalizedStringKey("Move \(sessionCount) to Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var trimmedName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// [T-folder-duplicate-name] The existing group whose name matches what the
    /// user is typing, if any.
    ///
    /// Case- and whitespace-insensitive because "Work" / "work " are the same
    /// group to a person, and silently creating a second one is how a list ends
    /// up with two identically-labelled folders that are impossible to tell
    /// apart in the picker.
    private var duplicateFolder: ChatFolder? {
        let key = trimmedName.lowercased()
        guard !key.isEmpty else { return nil }
        return items.first { $0.folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == key }?.folder
    }

    private func createIfNamed() {
        guard !trimmedName.isEmpty else { return }
        // Never silently create a second group with an existing name — the
        // inline notice below offers the existing one instead.
        guard duplicateFolder == nil else { return }
        let d = newFolderDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        onChoose(.create(name: trimmedName, desc: d.isEmpty ? nil : d))
    }

    private func runSuggest() {
        suggesting = true
        suggestFailed = false
        suggestedMerge = nil
        let ids = sessionIds
        Task { @MainActor in
            defer { suggesting = false }
            do {
                switch try await AIChatViewModel.suggestFolder(forSessionIds: ids) {
                case .merge(let folderId, let folderName):
                    suggestedMerge = (folderId, folderName)
                case .create(let name, let desc):
                    newFolderName = name
                    if let desc { newFolderDesc = desc }
                    nameFieldFocused = true
                }
            } catch {
                // [T-ios-folder-suggest-retry] This catch used to swallow the
                // error entirely — the user saw "failed — try again" and the
                // log had nothing. Keep the UI flag, but record why.
                AppLogger(category: "AIChatVM").error("[FolderSuggest] UI caught error=\(error)")
                suggestFailed = true
            }
        }
    }
}
