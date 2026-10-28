//
//  SessionContextMenu.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The session row's context menu: a closure-free, Equatable view (MenuKey +
//  SessionMenuActionChannel) so SwiftUI skips rebuilding it and no captured
//  ContentView can dangle.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Equatable-gated context menu

/// [T-ios-sidebar-contextmenu-memory] + [T-ios-crash-contextmenu-uaf]
///
/// Concrete, closure-free replacement for the old generic EquatableMenuContent.
/// The previous design stored a `@ViewBuilder () -> Content` closure that
/// captured ContentView's `self`; Equatable compared only the key, so SwiftUI
/// retained the OLD instance (and its stale closure) when the key was unchanged.
/// During attribute-graph transactions, `assignWithCopy` of the struct
/// retain/released the closure whose captures had already been deallocated →
/// use-after-free → KERN_PROTECTION_FAILURE (appears as CODESIGNING/Invalid
/// Page because the CPU jumped to a freed stack address).
///
/// This replacement stores ONLY value types (MenuKey) plus a stable class
/// reference (SessionMenuActionChannel, backed by @State in ContentView — alive
/// for the view-graph lifetime). `body` builds the menu from key fields +
/// singleton data; actions go through the channel. No escaping closure, no
/// captured `self`, nothing to dangle.
///
/// Memory optimization preserved: `.equatable()` at the call site still skips
/// `body` when the key is unchanged, so the 8+ Button/Menu/Label tree is NOT
/// rebuilt on every sidebar body pass.
struct SessionContextMenu: View, Equatable {
    let key: MenuKey
    let actions: SessionMenuActionChannel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View {
        Button {
            actions.send(.togglePin(key.sid))
        } label: {
            Label(LocalizedStringKey(key.pinned ? "Unpin" : "Pin"),
                  systemImage: key.pinned ? "pin.slash" : "pin")
        }
        Menu {
            Button {
                actions.send(.exportJSON(key.sid))
            } label: {
                Label("JSON", systemImage: "doc.text")
            }
            Button {
                actions.send(.exportText(key.sid))
            } label: {
                Label("Plain Text", systemImage: "text.alignleft")
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        Button {
            actions.send(.editTitle(key.sid))
        } label: {
            Label("Edit Title & Category", systemImage: "square.and.pencil")
        }
        Button {
            actions.send(.regenerateTitle(key.sid))
        } label: {
            Label("Regenerate Title", systemImage: "arrow.triangle.2.circlepath")
        }
        if BiometricAuth.isAvailable {
            if SessionLockStore.shared.isLocked(key.sid) {
                Button {
                    actions.send(.unlockSession(key.sid))
                } label: {
                    Label("Remove \(BiometricAuth.biometryDisplayName) Lock", systemImage: "lock.open")
                }
            } else if SessionLockStore.shared.globalEnabled {
                Button {
                    actions.send(.lockSession(key.sid))
                } label: {
                    Label(ContentView.lockWithBiometryLabel(), systemImage: "lock.fill")
                }
            }
        }
        Button {
            actions.send(.duplicate(key.sid))
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }
        // Single Button that opens the shared folder-picker sheet. Deliberately
        // NOT an inline submenu of folder names: this menu body is the
        // [T-ios-contextmenu-localized-mainthread-hang] site, and listing N
        // folders here would multiply every AttributeGraph recompute by N.
        // A static Label keeps the body cost constant, and keeps folder data
        // out of the menu entirely ([T-ios-crash-contextmenu-uaf]).
        Button {
            actions.send(.moveToFolder(key.sid))
        } label: {
            // Wording follows membership: a session already in a group is being
            // MOVED BETWEEN groups, not filed for the first time. Same idiom as
            // Pin/Unpin above — `LocalizedStringKey` so the chosen key is still
            // looked up in Localizable.xcstrings (a plain String would bypass
            // localization entirely).
            Label(LocalizedStringKey(key.filed ? "Change Group" : "Move to Group"),
                  systemImage: key.filed ? "folder.badge.gearshape" : "folder")
        }
        if iCloudSyncVisible {
            Button {
                actions.send(.forceSync(key.sid))
            } label: {
                Label("Force iCloud Sync", systemImage: "icloud.and.arrow.up")
            }
            Button {
                actions.send(.forcePull(key.sid))
            } label: {
                Label("Force Pull Messages", systemImage: "icloud.and.arrow.down")
            }
        }
        Button {
            actions.send(.select(key.sid))
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Button {
            let title = (key.title ?? "Untitled").prefix(60)
            let subject = "Content Report: \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let msgBody = "Session: \(key.sid)\n\nPlease describe the issue:\n".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:dev@openminis.app?subject=\(subject)&body=\(msgBody)") {
                UIApplication.shared.open(url)
            }
        } label: {
            Label("Report Content", systemImage: "exclamationmark.bubble")
        }
        Button(role: .destructive) {
            actions.send(.delete(key.sid))
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var iCloudSyncVisible: Bool {
        if #available(iOS 17.0, *) {
            return UserDefaults.standard.bool(forKey: "cloudSync.v2.enabled")
        }
        return false
    }
}

/// Value key for the sidebar session context menu — only these fields change what
/// the menu renders (Pin/Unpin label, title in Report/Delete). A change here is
/// the only reason to rebuild the menu tree.
struct MenuKey: Equatable {
    let sid: String
    let pinned: Bool
    let title: String?
    /// Whether the session currently belongs to a group. Drives the
    /// "Move to Group" / "Change Group" wording.
    ///
    /// Carried in the KEY rather than read from a store inside `body`: the menu
    /// is `.equatable()` precisely so `body` is skipped while the key is
    /// unchanged, so a value the label depends on must participate in equality
    /// or the wording would go stale after a move. It is also a plain `Bool`,
    /// keeping this a pure value type — see the type comment above about the
    /// use-after-free that closures/reference captures caused here.
    let filed: Bool
}
