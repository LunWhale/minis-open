//
//  ContentView+SessionMenu.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, session context menu: the biometry-aware lock label and the
//  wiring of the row-menu and FAB action channels (SessionMenuActionChannel,
//  FABActionChannel) to ContentView's methods. The menu view itself is
//  Sidebar/SessionContextMenu.swift.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    // MARK: - Session Context Menu

    /// Cached, language-aware "Lock with <biometry>" menu label.
    ///
    /// [T-ios-contextmenu-localized-mainthread-hang] `String(localized:)` is an
    /// EAGER Foundation catalog lookup (unlike `LocalizedStringKey`, which
    /// SwiftUI resolves lazily at render). The lock label is the only eager
    /// `String(localized:)` on the contextMenu body-build path. With ~2000
    /// sessions, every AttributeGraph recompute re-ran this lookup once per
    /// cell on the main thread, accumulating into multi-hundred-second hangs
    /// (measured 226s / 106s). The string depends only on the active app
    /// language and the device biometry name — both fixed for a given render
    /// generation — so we compute it once and reuse it.
    ///
    /// Invalidation: keyed on `appLanguage` (the UserDefaults source of truth
    /// the language picker writes; switching it also re-keys the root via
    /// `.id(appLanguage)`, so the whole tree re-mounts) plus the biometry name.
    /// When the key changes the value is recomputed under the new
    /// `languageBundle`, so a language switch is never locked to the old string.
    private static let lockLabelLock = NSLock()
    private nonisolated(unsafe) static var cachedLockLabel: String?
    private nonisolated(unsafe) static var cachedLockLabelKey: String?

    static func lockWithBiometryLabel() -> String {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        let biometry = BiometricAuth.biometryDisplayName
        let key = "\(lang)\u{1F}\(biometry)"
        lockLabelLock.lock()
        defer { lockLabelLock.unlock() }
        if cachedLockLabelKey == key, let cached = cachedLockLabel {
            return cached
        }
        let value = AppLocalized("Lock with \(biometry)")
        cachedLockLabel = value
        cachedLockLabelKey = key
        return value
    }

    // MARK: - Menu action wiring

    /// [T-ios-crash-contextmenu-uaf] Connect the stable action channel to
    /// ContentView's instance methods. Called once from onAppear; the closure
    /// captures `self` whose @State backing is stable for the view-graph
    /// lifetime, so the handler remains valid even if body re-evaluates.
    /// [T-ios-crash-objectdestroy-fab-uaf] Same wiring for the FAB channel.
    /// Reading `fabDidDrag` / `searchDidDrag` HERE rather than in the stored
    /// closure is the point: this handler runs against live @State, so the drag
    /// guard behaves exactly as before while the closure the FAB holds captures
    /// no view struct.
    func wireFABActions() {
        fabActions.handler = { [self] action in
            switch action {
            // [T-nav-ghost-row-link] The FABs live on the home list, so a new
            // chat is the ONLY page the stack should hold: replace the path
            // rather than append to it, so nothing left on it can end up
            // underneath the new chat.
            case .newChat:
                if !fabDidDrag { switchToSession(Self.makeNewSessionId()) }
            case .newChatInGroup(let groupId):
                switchToSession(Self.makeNewSessionId(groupId: groupId))
            case .openSearch:
                if !searchDidDrag {
                    withAnimation(.easeInOut(duration: 0.2)) { showSearchBar = true }
                }
            }
        }
    }

    func wireMenuActions() {
        menuActions.handler = { [self] action in
            switch action {
            case .open(let sid):
                // [T-nav-row-push-animation] A row tap keeps the push animation
                // its NavigationLink used to give it (only when the stack is
                // empty; see shouldAnimateSessionPush).
                switchToSession(sid, animated: true)
            case .togglePin(let sid):
                Task { @MainActor in
                    await ChatStore.shared.toggleSessionPin(sid)
                    refreshSessionList()
                }
            case .exportJSON(let sid):
                exportSessions(ids: [sid], format: .json)
            case .exportText(let sid):
                exportSessions(ids: [sid], format: .plainText)
            case .editTitle(let sid):
                if let current = sessions.first(where: { $0.id == sid }) {
                    sessionToEdit = current
                }
            case .regenerateTitle(let sid):
                regenerateTitle(sessionId: sid)
            case .lockSession(let sid):
                SessionLockStore.shared.lock(sid)
            case .unlockSession(let sid):
                Task {
                    let reason = AppLocalized("Unlock this session to remove \(BiometricAuth.biometryDisplayName) protection")
                    let ok = await BiometricAuth.authenticate(reason: reason)
                    if ok { SessionLockStore.shared.unlockPermanently(sid) }
                }
            case .duplicate(let sid):
                Task { @MainActor in
                    if let dup = await SessionForkManager.shared.duplicateSession(sessionId: sid) {
                        refreshSessionList()
                        selectedSessionId = dup.id
                    }
                }
            case .forceSync(let sid):
                runForceSyncOnSelection(singleSession: sid)
            case .forcePull(let sid):
                runForcePullOnSession(sid)
            case .select(let sid):
                isSelecting = true
                selectedIds = [sid]
                scrollToId = sid
            case .moveToFolder(let sid):
                let filed = sessions.first(where: { $0.id == sid })?.isFiled ?? false
                folderPickerRequest = FolderPickerRequest(
                    sessionIds: [sid], fromMultiSelect: false, anyFiled: filed)
            case .delete(let sid):
                print("[DELETE] Context menu tapped for session: \(sid)")
                Task { @MainActor in
                    let info = await Self.computeDeleteInfoExpanded(for: [sid])
                    print("[DELETE] computeDeleteInfo returned: sessionCount=\(info.sessionCount) children=\(info.childCount), fileCount=\(info.totalFileCount), size=\(info.totalSize)")
                    singleDeleteInfo = info
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    print("[DELETE] singleDeleteInfo set, now setting sessionToDelete")
                    if let current = sessions.first(where: { $0.id == sid }) {
                        sessionToDelete = current
                    }
                    print("[DELETE] sessionToDelete set, sheet should appear")
                }
            }
        }
    }
}
