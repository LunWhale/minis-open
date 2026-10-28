//
//  FolderAlertsModifier.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Folder rename / dissolve / delete alerts, kept out of ContentView.body so
//  the body stays within the type-checker's budget.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

/// ContentView.body's type-check budget (adding them inline tipped the
/// compiler into "unable to type-check in reasonable time").
struct FolderAlertsModifier: ViewModifier {
    @Binding var folderToRename: ChatFolder?
    @Binding var renameFolderText: String
    @Binding var renameFolderDesc: String
    @Binding var folderToDissolve: ChatFolder?
    /// [T-folder-duplicate-name] Every existing group, so a rename can detect a
    /// name collision before writing.
    let allFolders: [ChatFolder]
    let memberCount: (String) -> Int
    let onRename: (ChatFolder, String, String) -> Void
    let onDissolve: (ChatFolder) -> Void
    /// Offer to merge `source` into the existing same-named `target`.
    let onMergeInto: (_ source: ChatFolder, _ target: ChatFolder) -> Void

    /// The rename was blocked because the typed name is already taken; holds
    /// the (renamed folder, existing folder) pair for the follow-up alert.
    @State private var renameCollision: (source: ChatFolder, target: ChatFolder)?

    /// [T-folder-duplicate-name] An OTHER group already carrying `name`.
    /// Excludes the folder being renamed so re-saving its own name (e.g. a
    /// description-only edit) is never treated as a collision.
    private func duplicate(of name: String, excluding id: String) -> ChatFolder? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return allFolders.first {
            $0.id != id
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Group",
                isPresented: Binding(
                    get: { folderToRename != nil },
                    set: { if !$0 { folderToRename = nil } }
                )
            ) {
                TextField("Group Name", text: $renameFolderText)
                // The one-sentence auto-grouping context — hidden in the
                // list, surfaced for editing exactly here as requested.
                TextField("Description (optional)", text: $renameFolderDesc)
                Button("Cancel", role: .cancel) { folderToRename = nil }
                Button("Rename") {
                    let name = renameFolderText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let folder = folderToRename, !name.isEmpty {
                        // [T-folder-duplicate-name] Renaming onto an existing
                        // name would leave two groups the picker cannot tell
                        // apart. Stop and offer the merge instead of writing.
                        if let clash = duplicate(of: name, excluding: folder.id) {
                            renameCollision = (source: folder, target: clash)
                        } else {
                            onRename(folder, name, renameFolderDesc)
                        }
                    }
                    folderToRename = nil
                }
            }
            // [T-folder-duplicate-name] Follow-up for a blocked rename. A plain
            // `.alert` cannot host a picker, so the choice is spelled out: go
            // back and pick another name, or move this group's chats into the
            // existing one (which is what "use the existing group" means when
            // the group already has members).
            .alert(
                "Group Already Exists",
                isPresented: Binding(
                    get: { renameCollision != nil },
                    set: { if !$0 { renameCollision = nil } }
                ),
                presenting: renameCollision
            ) { pair in
                Button("Change Name") {
                    // Reopen the rename dialog with the text still in place so
                    // the user edits rather than retypes.
                    folderToRename = pair.source
                    renameCollision = nil
                }
                Button("Move Chats There") {
                    onMergeInto(pair.source, pair.target)
                    renameCollision = nil
                }
                Button("Cancel", role: .cancel) { renameCollision = nil }
            } message: { pair in
                Text("A group named “\(pair.target.name)” already exists. Choose a different name, or move this group's chats into it.")
            }
            .alert(
                "Dissolve Group?",
                isPresented: Binding(
                    get: { folderToDissolve != nil },
                    set: { if !$0 { folderToDissolve = nil } }
                ),
                presenting: folderToDissolve
            ) { folder in
                Button("Cancel", role: .cancel) { folderToDissolve = nil }
                Button("Dissolve") {
                    onDissolve(folder)
                    folderToDissolve = nil
                }
            } message: { folder in
                // Spell out that no session is deleted — this action sits one
                // menu away from the one that deletes everything, and the
                // wording is what keeps them apart.
                Text("\(memberCount(folder.id)) sessions will move back to the main list. No session will be deleted.")
            }
    }
}
