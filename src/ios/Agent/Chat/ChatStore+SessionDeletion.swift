//
//  ChatStore+SessionDeletion.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, per-session memory flag and session deletion: delete (local and
//  for the cloud), descendants, zombie child sweep, parent map, and marking
//  deleted sessions / files for cloud deletion. (In the single file this
//  code sat under the "Folders" mark.)
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")
private let memDiagLogger = AppLogger(category: "MemDiag")
private let iCloudLogger = AppLogger(category: "iCloud")

extension ChatStore {
    func getMemoryEnabled(sessionId: String) -> Bool {
        // [T-memory-global-toggle-settings-ui-ios] If the session row
        // already exists, return its stored per-session value. If no
        // row exists (genuinely new session — loadSession ran before
        // the session was persisted), fall back to the global default
        // from UserDefaults("memory.global.enabled"), defaulting to
        // true so users upgrading without the key set see no change.
        // Already-existing sessions keep their stored value when the
        // global toggle changes — only NEW sessions inherit it.
        let sql = "SELECT memory_enabled FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        var rowFound = false
        var enabled = true
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                enabled = sqlite3_column_int(stmt, 0) != 0
                rowFound = true
            }
        }
        sqlite3_finalize(stmt)
        // [T-memory-enabled-new-session-bug DIAG]
        let rawObj = UserDefaults.standard.object(forKey: "memory.global.enabled")
        if rowFound {
            memDiagLogger.info("[MemDiag] getMemoryEnabled sid=\(sessionId.prefix(8)) rowFound=true storedRow=\(enabled) (returning storedRow) globalRaw=\(String(describing: rawObj))")
            return enabled
        }
        // No row — apply global default. UserDefaults.bool returns false
        // for unset keys, so probe presence via object(forKey:) first
        // and treat absent as true (matches @AppStorage default).
        if let stored = UserDefaults.standard.object(forKey: "memory.global.enabled") as? Bool {
            memDiagLogger.info("[MemDiag] getMemoryEnabled sid=\(sessionId.prefix(8)) rowFound=false → global=\(stored)")
            return stored
        }
        memDiagLogger.info("[MemDiag] getMemoryEnabled sid=\(sessionId.prefix(8)) rowFound=false global unset → true")
        return true
    }

    func setMemoryEnabled(sessionId: String, enabled: Bool) {
        let sql = "UPDATE sessions SET memory_enabled = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteSession(_ id: String) {
        // FULL: removes a row from the set.
        invalidateSessionListCache()
        // [T-p1-delegate-task] Cascade to child (helper) sessions FIRST — they
        // are reachable only through this parent, so an orphaned child would
        // be invisible yet still occupy storage and sync. Each goes through
        // the full funnel (cloud tombstone + local rows + recent-delete mark).
        for childId in childSessionIds(of: id) {
            deleteSession(childId)
        }
        // Queue cloud deletions BEFORE removing local rows so the SELECTs
        // below can still enumerate child ids. Peers receive op=delete
        // for the session + each child and apply them as hard deletes
        // (see TombstoneManager.applyRemoteSessionDeletion).
        markSessionForCloudDeletion(id)

        deleteSessionLocalRowsOnly(id)

        // [T-icloud-deleted-session-resurrection] Record a recent-delete
        // tombstone so an inbound merge (e.g. fetchRecentV2 pulling the still-
        // present cloud record before our delete tombstone lands) refuses to
        // re-insert this session / its messages / its files. Pruned by the
        // 30-day TTL on launch (ids are UUIDs, so it never blocks a real
        // future session).
        recordDeletedSessionTombstone(id)
    }

    /// Hard-delete a session and its children locally without queuing any
    /// cloud delete rows. Used by the inbound side: when a peer device
    /// pushes a SessionV2 op=delete, we apply it locally and STOP — the
    /// cloud already has the deletion, re-queueing it would just create a
    /// noisy round-trip and risk a delete-loop with peers that haven't
    /// yet drained the same tombstone.
    func deleteSessionLocalOnly(_ id: String) {
        // Inbound peer delete: the peer already tombstoned the children, so
        // mirror the cascade locally without re-queueing cloud deletes.
        for childId in childSessionIds(of: id) {
            deleteSessionLocalOnly(childId)
        }
        deleteSessionLocalRowsOnly(id)
    }

    /// [T-p1-delegate-task] Ids of the hidden child sessions of `parentId`.
    /// `ids` plus every descendant child session, any depth.
    /// [T-child-delete-storage] The one query every delete / measure path
    /// uses to expand a user's selection to what really goes away.
    func sessionIdsWithDescendants(_ ids: some Sequence<String>) -> [String] {
        SessionTree.withDescendants(ids) { self.childSessionIds(of: $0) }
    }

    /// Single-integer query for the sweep's diagnostics. Binds its parameter
    /// rather than interpolating: these ids come from the DB and are UUIDs
    /// today, but a counting helper is exactly the place a future caller
    /// passes something less controlled.
    private func scalarCount(_ sql: String, bind: String? = nil) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        if let bind { sqlite3_bind_text(stmt, 1, (bind as NSString).utf8String, -1, nil) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// [T-zombie-child-sweep] Delete child sessions whose parent is gone.
    ///
    /// Truncating a conversation (retry, or deleting from a message) drops the
    /// message rows that carried the `subagent_task` blocks, but nothing ever
    /// touched the child sessions those blocks spawned. The children survive
    /// with a `parent_session_id` pointing at a parent whose block no longer
    /// exists: invisible in the UI — nothing links to them any more — yet
    /// still holding storage, still syncing to every other device, and
    /// impossible for the user to reach and delete.
    ///
    /// Two guards keep this from eating live data, because "the parent row is
    /// missing" is a much weaker claim than it looks:
    ///
    ///  1. **A one-month age floor.** iCloud delivers records in no particular
    ///     order, so a child can legitimately arrive before its parent. Judged
    ///     immediately, a freshly-synced child looks exactly like a zombie.
    ///     Anything touched within the last month is therefore left alone —
    ///     far longer than any sync convergence takes, and a zombie costs
    ///     nothing by waiting.
    ///  2. **The parent must be confirmed absent**, by id, right before the
    ///     delete. Never inferred from the sweep's own snapshot.
    ///
    /// Returns the number of sessions deleted.
    @discardableResult
    func sweepZombieChildSessions(olderThan cutoff: TimeInterval = 30 * 24 * 60 * 60) -> Int {
        let startedAt = Date()
        let deadline = startedAt.timeIntervalSince1970 - cutoff
        // Counted for the candidate line below: a large `children` with a
        // small `candidates` is the healthy shape, and the ratio is what makes
        // an unexpected sweep obvious. A clean run logs nothing — this is a
        // cold-start path, and a line on every launch saying "nothing to do"
        // is noise that would outnumber the events worth finding.
        let totalChildren = scalarCount("SELECT COUNT(*) FROM sessions WHERE parent_session_id IS NOT NULL AND parent_session_id != ''")

        // `updated_at` covers both the child's own activity and any inbound
        // merge that touched it, so a child still receiving sync traffic can
        // never be old enough to qualify.
        let sql = """
            SELECT c.id, c.parent_session_id, c.updated_at
            FROM sessions c
            WHERE c.parent_session_id IS NOT NULL AND c.parent_session_id != ''
              AND c.updated_at < ?
              AND NOT EXISTS (SELECT 1 FROM sessions p WHERE p.id = c.parent_session_id)
            """
        var stmt: OpaquePointer?
        var candidates: [(child: String, parent: String, updatedAt: Double)] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, deadline)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cid = Self.colText(stmt, 0), pid = Self.colText(stmt, 1)
                let upd = sqlite3_column_double(stmt, 2)
                if !cid.isEmpty, !pid.isEmpty { candidates.append((cid, pid, upd)) }
            }
        }
        sqlite3_finalize(stmt)
        guard !candidates.isEmpty else { return 0 }
        logger.warning("[ZombieSweep] \(candidates.count) candidate(s) of \(totalChildren) child session(s), cutoff \(Int(cutoff / 86400))d")

        var deleted = 0
        var spared = 0
        for (child, parent, updatedAt) in candidates {
            // Re-check by id. The NOT EXISTS above was evaluated over the whole
            // table at once; this asks the single question that authorises the
            // delete, and asks it now. A parent that arrived from iCloud in
            // between must save its child.
            guard !sessionExists(id: parent) else {
                spared += 1
                logger.warning("[ZombieSweep] SPARED child=\(child.prefix(8)) — parent \(parent.prefix(8)) reappeared between query and delete")
                continue
            }
            // Everything identifying the row goes in BEFORE the delete: once
            // deleteSession returns, this row is the only remaining record that
            // it existed. Age and message count are what a later "why did my
            // session vanish" report needs to judge whether the call was right.
            let msgCount = scalarCount("SELECT COUNT(*) FROM messages WHERE session_id = ?", bind: child)
            let ageDays = Int(startedAt.timeIntervalSince1970 - updatedAt) / 86400
            let descendants = childSessionIds(of: child).count
            // Ids and counts only — no title. This is an audit line for an
            // irreversible delete, and the session's title is the user's own
            // task text; the id is enough to identify the row.
            logger.warning("[ZombieSweep] DELETE child=\(child.prefix(8)) parent=\(parent.prefix(8)) age=\(ageDays)d msgs=\(msgCount) descendants=\(descendants)")
            // A zombie whose own children are still live would strand THEM, so
            // go through the normal funnel: it cascades to descendants, queues
            // the cloud tombstone (peers hard-delete their copies), and records
            // the recent-delete mark that stops fetchRecentV2 resurrecting it.
            deleteSession(child)
            deleted += 1
        }
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.warning("[ZombieSweep] done — deleted=\(deleted) spared=\(spared) of \(candidates.count) candidate(s) in \(ms)ms")
        return deleted
    }

    /// child id → parent id for every child session.
    func sessionParentMap() -> [String: String] {
        let sql = "SELECT id, parent_session_id FROM sessions WHERE parent_session_id IS NOT NULL AND parent_session_id != ''"
        var stmt: OpaquePointer?
        var out: [String: String] = [:]
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cid = Self.colText(stmt, 0), pid = Self.colText(stmt, 1)
                if !cid.isEmpty, !pid.isEmpty { out[cid] = pid }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    func childSessionIds(of parentId: String) -> [String] {
        let sql = "SELECT id FROM sessions WHERE parent_session_id = ?"
        var stmt: OpaquePointer?
        var ids: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (parentId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cid = Self.colText(stmt, 0)
                if !cid.isEmpty { ids.append(cid) }
            }
        }
        sqlite3_finalize(stmt)
        return ids
    }

    /// True if a session row exists locally. Lightweight existence check
    /// for inbound delete handlers — they need to know whether to log a
    /// real deletion or a no-op.
    func sessionExists(id: String) -> Bool {
        let sql = "SELECT 1 FROM sessions WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func deleteSessionLocalRowsOnly(_ id: String) {
        // [T-ios-listsessions-cache] Invalidate here (the low-level row delete)
        // so ALL callers are covered — deleteSession AND deleteSessionLocalOnly.
        // FULL: removes a row from the set.
        invalidateSessionListCache()
        // [T-child-delete-storage] Bottom of the delete funnel — every entry
        // (home list, RPC, iCloud inbound tombstone) ends here, for the
        // session and, through the recursive callers, each descendant:
        //  - a still-running agent job for this session (as parent or as
        //    the child itself) is cancelled, so it cannot keep writing;
        //  - the WHOLE per-session directory goes (workspace, offloads,
        //    browser, attachments …), not just the media subfolders, plus
        //    the persisted browser-tab file. Global buckets are untouched
        //    because only UUID-named directories are ever removed.
        Task { @MainActor in
            AgentJobRegistry.shared.dropQueuedDelegations(parent: id, reason: "sessionDeleted")
            AgentJobRegistry.shared.cancelAll(parent: id, reason: "sessionDeleted")
            AgentJobRegistry.shared.cancelAll(session: id, reason: "sessionDeleted")
            // [T-scheduled-active-session] …and the timers it created.
            AgentJobRegistry.shared.cancelScheduled(createdBy: id, reason: "sessionDeleted", silent: true)
        }
        deleteMessages(sessionId: id)
        deleteCompactMarkers(sessionId: id)
        deleteSessionMedia(id)
        SessionStorageCleanup.removeSessionDirectory(id, minisBase: minisBaseURL)
        BrowserTabPool.deletePersistedData(for: id)

        let sql = "DELETE FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Clean up per-session etag cache
        if #available(iOS 17.0, *) {
            Task { @MainActor in CloudSyncEngine.shared.removeSessionCache(id) }
        }
        // [T-ios-session-paused-badge] Drop any badge state for a deleted session
        // so a stale "paused" badge can't linger in the persisted store.
        Task { @MainActor in SessionBadgeStore.shared.clearAll(for: id) }
        // [T-ios-delete-session-live-activity] All delete funnels (swipe /
        // long-press / batch / RPC / inbound iCloud delete) converge here, so
        // this is the single place that guarantees a deleted conversation never
        // stays visible in the Dynamic Island / Lock Screen. Order matters:
        // setInactive first so the tracker (and any snapshot rebuild) no longer
        // contains the session, then let the Live Activity manager end or trim
        // the on-screen activity.
        Task { @MainActor in
            SessionActivityTracker.shared.setInactive(id, source: "sessionDeleted")
            AgentLiveActivityManager.shared.handleSessionDeleted(id)
        }
    }

    /// Mark a session and all its child records (messages, compact markers) as
    /// pending iCloud deletion. Called from deleteSession before the local rows
    /// disappear so we can still enumerate the ids.
    private func markSessionForCloudDeletion(_ sessionId: String) {
        guard !syncZoneName.isEmpty else { return }
        // Session itself
        markDirty(recordType: "Session", recordId: sessionId, operation: "delete")
        // Messages
        let msgSql = "SELECT id FROM messages WHERE session_id = ?"
        var msgStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, msgSql, -1, &msgStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(msgStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(msgStmt) == SQLITE_ROW {
                let msgId = String(cString: sqlite3_column_text(msgStmt, 0))
                markDirty(recordType: "Message", recordId: msgId, operation: "delete")
            }
        }
        sqlite3_finalize(msgStmt)
        // Compact markers
        let cmSql = "SELECT id FROM compact_markers WHERE session_id = ?"
        var cmStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cmSql, -1, &cmStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(cmStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(cmStmt) == SQLITE_ROW {
                let cmId = String(cString: sqlite3_column_text(cmStmt, 0))
                markDirty(recordType: "CompactMarker", recordId: cmId, operation: "delete")
            }
        }
        sqlite3_finalize(cmStmt)
        // SessionFile records — walk the workspace and queue a delete for
        // every file that lives on iCloud. MUST run before
        // deleteSessionMedia removes the local files. recordIds are
        // "<sessionId>:<rel>" matching appendMediaFile +
        // scanAndMarkSessionFilesForResurrect.
        let sessionDir = minisBaseURL.appendingPathComponent(sessionId, isDirectory: true)
        var fileDeleteCount = 0
        if let enumerator = FileManager.default.enumerator(
            at: sessionDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                      isFile else { continue }
                let rel = url.path.replacingOccurrences(of: sessionDir.path + "/", with: "")
                markDirty(recordType: "SessionFile", recordId: "\(sessionId):\(rel)", operation: "delete")
                fileDeleteCount += 1
            }
        }
        iCloudLogger.info("[iCloud] deleteSession \(sessionId.prefix(8)) → cloud delete queued: \(fileDeleteCount) SessionFile records (in addition to Session/Message/CompactMarker tombstones)")
    }

    /// Public entry: queue a SessionFile cloud delete for one file under
    /// a session's workspace. Used by FileBrowserView.deleteItem when the
    /// user removes a file inside `Library/MinisChat/minis/<sid>/...`.
    /// `relPath` must be "<subdir>/<rest>" matching the recordId scheme.
    func markSessionFileForCloudDeletion(sessionId: String, relPath: String) {
        guard !syncZoneName.isEmpty, !sessionId.isEmpty, !relPath.isEmpty else { return }
        markDirty(recordType: "SessionFile",
                  recordId: "\(sessionId):\(relPath)",
                  operation: "delete")
    }
}
