//
//  ContentView+SessionActions.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, session actions: what a delete removes (DeleteInfo), deleting
//  one or many sessions (also when deleted elsewhere), and regenerating a
//  session title.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    // MARK: - Delete Info

    struct DeleteInfo {
        let sessionCount: Int
        /// [T-child-delete-storage] Hidden agent child sessions that go with
        /// the selected ones — counted separately so the sheet can say so.
        var childCount: Int = 0
        let fileNames: [String]   // first 3 file names
        let totalFileCount: Int
        let totalSize: Int64      // bytes

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        }
    }

    /// [T-child-delete-storage] Expand the user's selection to everything
    /// that will actually be deleted (descendant agent sessions included),
    /// then measure. The database share uses the ALL-sessions count
    /// (children included) as denominator for a numerator that also
    /// includes children — one consistent basis.
    static func computeDeleteInfoExpanded(for selected: Set<String>) async -> DeleteInfo {
        let expanded = await ChatStore.shared.sessionIdsWithDescendants(selected)
        let total = await ChatStore.shared.sessionCount()
        let childCount = max(0, expanded.count - selected.count)
        return await Task.detached {
            var info = Self.computeDeleteInfo(for: Set(expanded), totalSessions: total)
            info.childCount = childCount
            return info
        }.value
    }

    private nonisolated static func computeDeleteInfo(for ids: Set<String>, totalSessions: Int) -> DeleteInfo {
        let fm = FileManager.default
        let libBase = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let minisBase = libBase.appendingPathComponent("MinisChat/minis", isDirectory: true)
        let dbPath = libBase.appendingPathComponent("MinisChat/minis.db")

        var totalSize: Int64 = 0

        // Estimate DB size contribution (rough: divide DB size by total sessions)
        let totalSessions = max(totalSessions, 1)
        if let dbAttrs = try? fm.attributesOfItem(atPath: dbPath.path),
           let dbSize = dbAttrs[.size] as? Int64 {
            totalSize += dbSize * Int64(ids.count) / Int64(totalSessions)
        }

        let m = SessionStorageCleanup.measure(ids, minisBase: minisBase)
        totalSize += m.bytes

        return DeleteInfo(
            sessionCount: ids.count,
            fileNames: m.sampleNames,
            totalFileCount: m.fileCount,
            totalSize: totalSize
        )
    }

    // MARK: - Actions

    func deleteSession(_ session: ChatSession) {
        // "Currently displayed" must use the same matching as the sidebar
        // highlight (isSessionHighlighted): a session created from a draft this
        // run keeps selectedSessionId at the DRAFT id while the sidebar row
        // carries the real id (newSessionRealId). Comparing only
        // selectedSessionId == session.id missed that case, so deleting the
        // conversation being viewed left the detail pane showing dead content
        // (user report: iPad/macOS split view). Clearing the selection resets
        // the detail pane to the empty state; onChange(selectedSessionId)
        // clears the draft tracking ids.
        if isSessionHighlighted(session.id) {
            selectedSessionId = nil
        }
        withAnimation {
            sessions.removeAll { $0.id == session.id }
        }
        Task { @MainActor in
            await Self.tearDownForDeletion([session.id])
            await ChatStore.shared.deleteSession(session.id)
        }
    }

    /// [T-storage-session-cache] See `.sessionsDeletedElsewhere`.
    func handleSessionsDeletedElsewhere(_ note: Notification) {
        guard let ids = (note.userInfo?["ids"] as? [String]).map(Set.init), !ids.isEmpty else { return }
        Task { @MainActor in
            if ids.contains(where: { isSessionHighlighted($0) }) {
                selectedSessionId = nil
            }
            if !isWideLayout, let current = currentStackSessionId, ids.contains(current) {
                navigationPath = NavigationPath()
                currentStackSessionId = nil
            }
            sessions.removeAll { ids.contains($0.id) }
            refreshSessionList()
        }
    }

    /// [T-child-delete-storage] Before the rows go: stop every running agent
    /// under these sessions and drop their in-memory state, for the
    /// selection AND its descendants (the store's delete funnel removes rows
    /// and the whole per-session directory for each of them).
    static func tearDownForDeletion(_ ids: Set<String>) async {
        let all = await ChatStore.shared.sessionIdsWithDescendants(ids)
        for sid in all {
            AgentJobRegistry.shared.cancelAll(parent: sid, reason: "sessionDeleted")
            AgentJobRegistry.shared.cancelAll(session: sid, reason: "sessionDeleted")
            // [T-scheduled-active-session] Timers this conversation CREATED.
            // `remove` below only reached them through `vm.cancel()` when the
            // VM happened to be cached; an uncached one left its loop firing
            // into a deleted chat (and keeping it active) forever.
            AgentJobRegistry.shared.cancelScheduled(createdBy: sid, reason: "sessionDeleted", silent: true)
            ViewModelCache.shared.remove(sessionId: sid)
            BrowserUseOffloadBridge.releasePool(forSession: sid)
        }
    }

    func deleteSelectedSessions() {
        let ids = selectedIds
        // Same draft-id-aware matching as deleteSession: clear the selection
        // when ANY deleted id is the one currently displayed (including a
        // draft-created session whose selection id differs from its row id).
        if ids.contains(where: { isSessionHighlighted($0) }) {
            selectedSessionId = nil
        }
        withAnimation {
            sessions.removeAll { ids.contains($0.id) }
        }
        // Clear deleteInfo to signal onDismiss that deletion occurred;
        // isSelecting and selectedIds are reset in sheet's onDismiss to avoid animation conflicts.
        deleteInfo = nil
        let folderToDrop = pendingDeleteFolderId
        pendingDeleteFolderId = nil
        Task { @MainActor in
            await Self.tearDownForDeletion(ids)
            for id in ids {
                await ChatStore.shared.deleteSession(id)
            }
            // Delete-all-in-folder: the folder is empty now; dissolving it
            // just drops the row (and pushes the FolderV2 tombstone).
            if let fid = folderToDrop {
                _ = await ChatStore.shared.dissolveFolder(fid)
                await MainActor.run { refreshSessionList() }
            }
        }
    }

    /// Remove persistent minis files for a session (Library/MinisChat/minis/<sessionId>/).
    func regenerateTitle(for session: ChatSession) {
        regenerateTitle(sessionId: session.id)
    }

    func regenerateTitle(sessionId: String) {
        guard regeneratingTitleSessionId == nil else { return }
        regeneratingTitleSessionId = sessionId

        // [T-ios-state-publish-offmain-crash] @MainActor for the @State writes
        Task { @MainActor in
            defer { regeneratingTitleSessionId = nil }
            do {
                try await AIChatViewModel.regenerateSessionTitle(sessionId: sessionId)
                refreshSessionList()
            } catch {
                AppLogger(category: "RegenerateTitle").error(
                    "session=\(sessionId) failed: \(error.localizedDescription) — \(String(describing: error))"
                )
            }
        }
    }
}
