//
//  ChatStore+SyncDirty.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, iCloud sync dirty tracking: marking records dirty (v1 / v2
//  record types), re-upload staging, the historical backlog scan, loading /
//  counting / clearing dirty records, force sync / force pull of a session,
//  and scanning a session's file directories for dirty files (used when the
//  deferred sync marks are flushed).
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

// MARK: - Sync Support

private let iCloudLogger = AppLogger(category: "iCloud")

extension ChatStore {

    // MARK: - Sync Dirty Tracking

    /// Mark a record as needing sync to iCloud. Only active in DEBUG builds.
    func markDirty(recordType: String, recordId: String, operation: String = "upsert", priority: Int = 0) {
        // DIAG: log every silent early-return so "I added a Skill but
        // no markDirty appears in logs" can be diagnosed without
        // re-instrumenting. Previously both guards returned silently,
        // making it impossible to distinguish "code path not reached"
        // from "user toggled the category off in Settings".
        guard !syncZoneName.isEmpty else {
            iCloudLogger.info("[iCloudTrace] markDirty SKIP type=\(recordType) id=\(recordId.prefix(20)) op=\(operation) reason=zoneEmpty(syncNotInitialized)")
            return
        }
        // User-configurable upload policy: skip categories the user has
        // disabled in iCloud Sync settings (Chat Sessions / Skills /
        // Providers / Environments / Session Files). SyncDeviceV2 is
        // always allowed because peer discovery depends on it.
        guard UploadPolicy.allowsRecordType(recordType) else {
            iCloudLogger.info("[iCloudTrace] markDirty SKIP type=\(recordType) id=\(recordId.prefix(20)) op=\(operation) reason=uploadPolicyDisabled(user-toggled-off-in-Settings)")
            return
        }
        // [T-icloud-record-delete-resurrection] A local op=delete on these
        // types must leave a recent-delete tombstone so an inbound merge that
        // races ahead of the cloud delete (fetchRecentV2 re-pulling the still-
        // live record) can't resurrect it. Session/Message/SessionFile have
        // their own session-level tombstone path (recordDeletedSessionTombstone).
        // [T-sync-message-resurrection] `Message` is on this list so that
        // mergeRemoteMessage can refuse the echo of a just-deleted row (see
        // that function): without a local tombstone, CloudKit handing back
        // the record this device pushed moments before the delete re-inserts
        // the whole turn the user had just retried away.
        if operation == "delete",
           ["Skill", "EnvVarItem", "CompactMarker", "MCPServerItem", "Folder",
            "ProviderInstanceV3", "ProviderModelEntryV3", "ProviderModelGroupV3",
            "ProviderThinkingRuleV3", "SubAgentV3", "Message"].contains(recordType) {
            recordDeletedRecordTombstone(type: recordType, id: recordId)
        }
        // Trace priority=0 (user-driven) writes so we can follow a
        // freshly-typed message from local INSERT through CK push and
        // peer hydrate. priority=1 (migration backlog) is too noisy to
        // log at this granularity.
        if priority == 0 {
            // [T-ios-log-noise-reduction] INFO→DEBUG: per-record markDirty
            // trace (~876 lines/day). The SKIP-reason variants above stay INFO
            // since they indicate sync NOT happening (more diagnostic value).
            iCloudLogger.debug("[iCloudTrace] markDirty type=\(recordType) id=\(recordId.prefix(20)) op=\(operation)")
        }
        let zoneName = syncZoneName
        let now = Date().timeIntervalSince1970
        let sql = """
            INSERT OR REPLACE INTO sync_dirty_records (record_type, record_id, zone_name, operation, priority, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        // When V2 is the active sync engine and this recordType has a v2
        // counterpart, skip the v1 row entirely. The legacy dual-write was
        // meant to keep both engines coexisting during rollout, but with
        // v1 paused (SyncV2Bootstrap.shouldPauseV1) the v1 row has no
        // consumer — SyncCore filters via v2Only:true, the v1 engine is
        // off, and nothing ever clears it. The orphan row then poisons
        // any code path that loads dirty rows without the v2-only filter
        // (e.g. CloudSyncEngine.mergeProviderConfig's in-flight guard),
        // pinning their state to "always skip" for the rest of the install.
        //
        // Mirror SyncV2Bootstrap.shouldPauseV1() so we stop writing the v1
        // row exactly when nobody will consume it. shouldPauseV1 returns
        // true whenever v2 is enabled AND migration status is one of
        // .pending / .inProgress / .completed (i.e. anything except
        // .failed, which falls back to v1). The launch path uses the
        // same predicate to decide whether to start the v1 engine; we
        // mirror it here so the two decisions stay aligned.
        // UserDefaults is thread-safe; the actor isolation on
        // SyncV2Bootstrap.* is a Swift-6 concurrency annotation, not a
        // real main-thread requirement.
        let v2Type = Self.v2RecordType(forV1: recordType)
        let v2Enabled = UserDefaults.standard.bool(forKey: "cloudSync.v2.enabled")
        let migStatus = UserDefaults.standard.string(forKey: "cloudSync.v2.migrationStatus") ?? "pending"
        let v1Paused = v2Enabled && migStatus != "failed"
        let writeV1Row = !(v1Paused && v2Type != recordType)
        // v1 dirty row.
        var stmt: OpaquePointer?
        // DIAG (T-memory-row-vanish): rows for MemoryGlobalV2/MemoryDailyV2
        // appear in the markDirty INFO log but never show up in
        // countDirtyRecords or SyncCore.loadDirtyRecords. Capture
        // prepare/step errcodes + post-step changes() so we can tell
        // which layer is dropping the write.
        var prepareRC: Int32 = 0
        var stepRC: Int32 = -999
        var changesAfter: Int32 = -1
        if writeV1Row {
            prepareRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            if prepareRC == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (recordType as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (recordId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (zoneName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (operation as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 5, Int32(priority))
                sqlite3_bind_double(stmt, 6, now)
                stepRC = sqlite3_step(stmt)
                changesAfter = Int32(sqlite3_changes(db))
            }
            sqlite3_finalize(stmt)
        }
        if recordType.hasPrefix("Memory") || recordType == "SoulV2" {
            let errMsg = String(cString: sqlite3_errmsg(db))
            iCloudLogger.info("[iCloudTrace] markDirty SQL type=\(recordType) id=\(recordId.prefix(20)) prepareRC=\(prepareRC) stepRC=\(stepRC) changes=\(changesAfter) errmsg=\(errMsg) v1RowWritten=\(writeV1Row)")
        }
        // v2 dirty row — same record, different recordType name. SyncCore
        // looks up by V2-suffixed type names, so dual-writing here lets
        // both engines coexist during the v2 rollout. v1 ignores rows it
        // doesn't recognize; v2 ignores the un-suffixed names.
        if v2Type != recordType {
            var v2Stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &v2Stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(v2Stmt, 1, (v2Type as NSString).utf8String, -1, nil)
                sqlite3_bind_text(v2Stmt, 2, (recordId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(v2Stmt, 3, (zoneName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(v2Stmt, 4, (operation as NSString).utf8String, -1, nil)
                sqlite3_bind_int(v2Stmt, 5, Int32(priority))
                sqlite3_bind_double(v2Stmt, 6, now)
                sqlite3_step(v2Stmt)
            }
            sqlite3_finalize(v2Stmt)

            // Resurrect cascade was needed under the old soft-tombstone
            // policy. Now that inbound SessionV2 deletes hard-delete the
            // row + children, there's no tombstoned state to resurrect
            // from — if the row is gone, there's no parent for any new
            // child write to attach to anyway, so the SQL FK / lookups
            // upstream of markDirty would have already rejected it.
        }
        // Schedule a debounced send so local changes are uploaded promptly
        // without triggering a full sync on every individual write.
        // Skip during agent processing (syncSendDeferred) — flushPendingSyncDirty
        // will trigger a single send when the agent loop finishes.
        if !syncSendDeferred {
            if #available(iOS 17.0, *) {
                Task { @MainActor in
                    // Drive whichever engine the user is currently on.
                    if SyncV2Bootstrap.isEnabled {
                        SyncCore.shared.scheduleSend()
                    } else {
                        CloudSyncEngine.shared.scheduleSend()
                    }
                }
            }
        }
    }

    /// Map a v1 record type name to its v2 counterpart for dual-writing.
    /// Returns the input unchanged when no mapping exists (e.g. unknown
    /// types from future code paths).
    private static func v2RecordType(forV1 v1Type: String) -> String {
        switch v1Type {
        case "Session":         return "SessionV2"
        case "Message":         return "MessageV2"
        case "CompactMarker":   return "CompactMarkerV2"
        case "SessionFile":     return "SessionFileV2"
        case "Skill":           return "SkillV2"
        case "ProviderConfig":  return "ProviderConfigV2"
        case "EnvVar":          return "EnvVarV2"
        case "SyncDevice":      return "SyncDeviceV2"
        case "Soul":            return "SoulV2"
        case "Folder":          return "FolderV2"
        default:                return v1Type
        }
    }

    /// Force-mark everything locally syncable as dirty for a full re-upload to iCloud.
    /// Used by the "Delete iCloud Data" flow to repopulate a freshly-emptied cloud from
    /// local state. Does NOT touch local data. Category toggles in CloudSyncEngine still
    /// filter what actually gets uploaded.
    ///
    /// Two-phase staging to keep cold-launch CPU bounded:
    ///   • Phase A (synchronous, fast): singleton records — Skills,
    ///     ProviderConfig, EnvVar, the latest active sessions and their
    ///     children. These are small and the user wants them on cloud
    ///     ASAP.
    ///   • Phase B (background, paginated): historical sessions in
    ///     created_at-DESC windows of 100. Each window scans a
    ///     bounded subset and yields between windows. The scan cursor
    ///     is persisted so a cold launch resumes where the previous
    ///     pass stopped, never re-walking already-staged history.
    ///
    /// Idempotent across launches: once Phase A finishes, the
    /// once-per-install guard (`initialBacklogMarked`) flips. Future
    /// calls bail out unless `force: true` (the "Delete iCloud Data"
    /// recovery path). Phase B continues independently via its own
    /// cursor until the entire backlog is staged.
    ///
    /// Why this matters: pre-fix, every cold launch re-marked 89k+
    /// session files + 290k SQLite INSERTs unconditionally, sustaining
    /// 90%+ CPU. Logs showed 60 calls per day, all redundant.
    func markAllLocalForReupload(force: Bool = false) {
        guard !syncZoneName.isEmpty else { return }
        let initialDoneKey = "cloudSync.v2.initialBacklogMarked"
        let alreadyDone = UserDefaults.standard.bool(forKey: initialDoneKey)
        if !force && alreadyDone {
            let counts = countDirtyRecords()
            iCloudLogger.info("[iCloud] markAllLocalForReupload skipped (initial backlog already marked, dirty=\(counts.total)). Pass force=true to re-mark.")
            // Even when Phase A is done, Phase B may still be paginating
            // older sessions across launches. Kick its async loop so
            // it picks up where it left off (no-op if cursor is past
            // the oldest session).
            kickHistoricalBacklogScan(force: false)
            return
        }
        let backlogPriority = 1

        // ─── Phase A — fast path, ship the small / important stuff ───
        // Singleton records first so user-visible config (skills,
        // providers, env vars) syncs in the first push regardless of
        // how long the historical scan takes.
        // [T-icloud-drop-wholefile-producers] ProviderConfig / EnvVar
        // whole-file records are no longer queued here: providers and env
        // vars travel as per-record v3 / EnvVarItem records, which the
        // backlog scan below already enumerates. A v3 peer discards the
        // whole-file forms on receipt, so queuing them only inflated the
        // first push by ~900 KB.
        // Skills are stored in SkillStore's own DB; CloudSyncEngine /
        // its v2 caller enumerates SkillStore separately. ChatStore
        // doesn't see them.

        // Most-recent active sessions + children: top-100 by
        // updated_at. The rest goes to Phase B.
        let recentLimit = 100
        let recentSessSql = """
            SELECT s.id FROM sessions s
            WHERE EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id)
            ORDER BY s.updated_at DESC
            LIMIT \(recentLimit)
            """
        var recentIds: [String] = []
        var rsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, recentSessSql, -1, &rsStmt, nil) == SQLITE_OK {
            while sqlite3_step(rsStmt) == SQLITE_ROW {
                recentIds.append(String(cString: sqlite3_column_text(rsStmt, 0)))
            }
        }
        sqlite3_finalize(rsStmt)
        for sid in recentIds {
            stageSessionAndChildrenForReupload(sessionId: sid, priority: backlogPriority)
        }
        iCloudLogger.info("[iCloud] markAllLocalForReupload Phase A: staged \(recentIds.count) recent sessions + singletons (priority=\(backlogPriority))")
        // Reset the historical cursor so Phase B starts at the
        // boundary just below the most-recent set.
        if let oldestRecent = recentIds.last,
           let oldestUpdatedAt = sessionUpdatedAt(id: oldestRecent) {
            UserDefaults.standard.set(oldestUpdatedAt.timeIntervalSince1970,
                                      forKey: "cloudSync.v2.backlogScanCursorAt")
        } else {
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: "cloudSync.v2.backlogScanCursorAt")
        }
        UserDefaults.standard.set(true, forKey: initialDoneKey)

        // ─── Phase B — paginated background scan of older history ───
        kickHistoricalBacklogScan(force: true)
    }

    /// Look up `sessions.updated_at` for a single session. Used by the
    /// markAllLocalForReupload Phase A→B handoff to set the initial
    /// pagination cursor.
    private func sessionUpdatedAt(id: String) -> Date? {
        let sql = "SELECT updated_at FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    /// Stage one session + all its messages/markers/files dirty.
    /// Pulled out so Phase A and Phase B share the per-session work.
    /// Returns the number of SessionFile records staged (used by the
    /// migration progress UI to grow its denominator dynamically as
    /// the scan progresses, rather than pre-walking the whole tree).
    @discardableResult
    private func stageSessionAndChildrenForReupload(sessionId: String, priority: Int) -> Int {
        markDirty(recordType: "Session", recordId: sessionId, priority: priority)
        let msgSql = "SELECT id FROM messages WHERE session_id = ?"
        var msgStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, msgSql, -1, &msgStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(msgStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(msgStmt) == SQLITE_ROW {
                markDirty(recordType: "Message",
                          recordId: String(cString: sqlite3_column_text(msgStmt, 0)),
                          priority: priority)
            }
        }
        sqlite3_finalize(msgStmt)
        let cmSql = "SELECT id FROM compact_markers WHERE session_id = ?"
        var cmStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cmSql, -1, &cmStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(cmStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(cmStmt) == SQLITE_ROW {
                markDirty(recordType: "CompactMarker",
                          recordId: String(cString: sqlite3_column_text(cmStmt, 0)),
                          priority: priority)
            }
        }
        sqlite3_finalize(cmStmt)
        let fileCount = scanAndMarkSessionFiles(sessionId: sessionId, priority: priority)
        // Bump the running session-file estimate so MigrationEngine can
        // grow the denominator monotonically as Phase B paginates.
        if fileCount > 0 {
            let key = "cloudSync.v2.estimatedExtraSessionFiles"
            let prev = UserDefaults.standard.integer(forKey: key)
            UserDefaults.standard.set(prev + fileCount, forKey: key)
        }
        return fileCount
    }

    /// Baseline record count for the migration progress UI's denominator.
    /// Counts only what we can know cheaply from SQLite: sessions
    /// (non-empty), messages, compact markers, plus singletons. Does
    /// NOT include SessionFiles — those are filesystem-discovered and
    /// get added to the denominator incrementally by Phase B as it
    /// pages through sessions. SkillStore / EnvVarStore counts are
    /// added by the migration UI on top.
    func countBacklogBaseline() -> (sessions: Int, messages: Int, compactMarkers: Int, singletons: Int) {
        var sessions = 0, messages = 0, markers = 0
        var stmt: OpaquePointer?
        let sessSql = "SELECT COUNT(*) FROM sessions s WHERE EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id)"
        if sqlite3_prepare_v2(db, sessSql, -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            sessions = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        stmt = nil
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            messages = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        stmt = nil
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM compact_markers", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            markers = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        // ProviderConfig + EnvVar (legacy whole-file). Per-key
        // EnvVarItem records are counted by EnvVarStore separately
        // when the migration UI assembles the denominator.
        return (sessions: sessions, messages: messages, compactMarkers: markers, singletons: 2)
    }

    /// Phase B: paginated background scan of older sessions.
    ///
    /// Reads the cursor at `cloudSync.v2.backlogScanCursorAt` (a
    /// session.updated_at value), pulls the next 100 sessions strictly
    /// older than it, stages each, advances the cursor, yields, and
    /// loops. Stops when no sessions remain. Persistent cursor means a
    /// cold launch resumes where the previous pass stopped — no
    /// repeated work even if migration takes multiple sessions to
    /// finish.
    ///
    /// Triggered from markAllLocalForReupload (after Phase A) and
    /// re-kicked on every subsequent invocation that short-circuits
    /// the once-per-install guard, since the pagination state is
    /// independent of `initialBacklogMarked`.
    nonisolated(unsafe) private static var historicalScanInFlight = false
    private func kickHistoricalBacklogScan(force: Bool) {
        if !force && Self.historicalScanInFlight { return }
        Self.historicalScanInFlight = true
        Task { [weak self] in
            await self?.runHistoricalBacklogScan()
            await MainActor.run { Self.historicalScanInFlight = false }
        }
    }

    private func runHistoricalBacklogScan() async {
        let cursorKey = "cloudSync.v2.backlogScanCursorAt"
        let cancelKey = "cloudSync.v2.backlogScanCanceled"
        let windowSize = 100
        let backlogPriority = 1
        var totalStaged = 0
        var passes = 0
        while !Task.isCancelled {
            // Honor explicit user cancel from MigrationEngine.cancelMigration.
            // Without this, the loop would keep paginating older sessions and
            // immediately re-stage the priority=1 dirty rows that
            // clearMigrationBacklog() just removed — the user sees migration
            // "still running" because it really is.
            if UserDefaults.standard.bool(forKey: cancelKey) {
                iCloudLogger.info("[iCloud] historicalBacklogScan: cancel flag set, stopping. totalStaged=\(totalStaged) passes=\(passes)")
                return
            }
            let cursor = UserDefaults.standard.double(forKey: cursorKey)
            // Cursor sentinel: negative or zero means "no work" only if
            // we've also recorded at least one Phase B pass. Default 0
            // would otherwise pull *all* sessions on first call — but
            // markAllLocalForReupload sets the cursor to the oldest
            // recent session before kicking us, so 0 here means
            // pagination already drained completely.
            guard cursor > 0 else {
                iCloudLogger.info("[iCloud] historicalBacklogScan: cursor=0 (drained), totalStaged=\(totalStaged) passes=\(passes)")
                return
            }
            let sql = """
                SELECT id, updated_at FROM sessions
                WHERE updated_at < ?
                  AND EXISTS (SELECT 1 FROM messages m WHERE m.session_id = sessions.id)
                ORDER BY updated_at DESC
                LIMIT \(windowSize)
                """
            var batch: [(id: String, updatedAt: Double)] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cursor)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let sid = String(cString: sqlite3_column_text(stmt, 0))
                    let updatedAt = sqlite3_column_double(stmt, 1)
                    batch.append((sid, updatedAt))
                }
            }
            sqlite3_finalize(stmt)
            if batch.isEmpty {
                iCloudLogger.info("[iCloud] historicalBacklogScan: window empty, finished. totalStaged=\(totalStaged) passes=\(passes)")
                // Sentinel to mark fully drained — next launch's
                // kickHistoricalBacklogScan returns immediately.
                UserDefaults.standard.set(0.0, forKey: cursorKey)
                return
            }
            for (sid, _) in batch {
                stageSessionAndChildrenForReupload(sessionId: sid, priority: backlogPriority)
                totalStaged += 1
            }
            // Advance cursor to the OLDEST in this window so the next
            // pass picks up strictly older sessions.
            if let oldest = batch.last?.updatedAt {
                UserDefaults.standard.set(oldest, forKey: cursorKey)
            }
            passes += 1
            iCloudLogger.info("[iCloud] historicalBacklogScan: pass=\(passes) staged=\(batch.count) cumulative=\(totalStaged) cursorNext=\(batch.last?.updatedAt ?? 0)")

            // Wait for the previous batch to drain before staging the
            // next one. Otherwise the dirty queue grows monotonically
            // (12 windows × 100 sessions = 1200 staged in ~3s, push
            // hasn't kept up) and we lose the "small bites" benefit —
            // SyncCore would just see the same single-shot 200k+
            // backlog at the end. Threshold is one-window-worth of
            // children: ~100 sessions × ~70 messages + files, give it
            // room without letting it stall forever.
            //
            // Poll every 5s; bail with a hard cap of 30 min per window
            // so a stuck push doesn't permanently freeze pagination.
            // Note: countDirtyRecords includes user-driven priority=0
            // writes, but those are usually a tiny fraction of the
            // backlog priority=1 rows during initial migration.
            let drainThreshold = 5_000
            let drainDeadline = Date().addingTimeInterval(30 * 60)
            while Date() < drainDeadline, !Task.isCancelled {
                let dirty = countDirtyRecords()
                if dirty.total < drainThreshold { break }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            // Brief pause between successful drains so other actor work
            // (chat writes, view loads) gets cycles even if push is
            // saturating CK.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Force-mark a session and all its messages/compact markers as dirty for iCloud sync.
    func forceMarkSessionDirty(sessionId: String) {
        markDirty(recordType: "Session", recordId: sessionId)
        // Mark all messages in this session as dirty
        let msgSql = "SELECT id FROM messages WHERE session_id = ?"
        var msgStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, msgSql, -1, &msgStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(msgStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(msgStmt) == SQLITE_ROW {
                let msgId = String(cString: sqlite3_column_text(msgStmt, 0))
                markDirty(recordType: "Message", recordId: msgId)
            }
        }
        sqlite3_finalize(msgStmt)
        // Mark compact markers
        let cmSql = "SELECT id FROM compact_markers WHERE session_id = ?"
        var cmStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cmSql, -1, &cmStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(cmStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(cmStmt) == SQLITE_ROW {
                let cmId = String(cString: sqlite3_column_text(cmStmt, 0))
                markDirty(recordType: "CompactMarker", recordId: cmId)
            }
        }
        sqlite3_finalize(cmStmt)
        // Mark session files (workspace/offloads/attachments)
        scanAndMarkSessionFiles(sessionId: sessionId)
    }

    /// Backfill: merge all remote_sessions and remote_messages into local tables.
    /// Called after code change that introduced mergeRemoteSession, to retroactively merge
    /// data that was fetched before the merge logic existed.
    func backfillRemoteToLocal() {
        iCloudLogger.info("[iCloud] backfillRemoteToLocal: starting")
        // 1. Merge remote sessions that don't exist locally
        let sCount = execCount("""
            INSERT OR IGNORE INTO sessions (id, title, category, model_id, created_at, updated_at, remote_origin_device_id)
            SELECT rs.id, rs.title, rs.category, rs.model_id, rs.created_at, rs.updated_at, rs.device_id
            FROM remote_sessions rs
            WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.id = rs.id)
        """)
        iCloudLogger.info("[iCloud] backfillRemoteToLocal: inserted \(sCount) sessions")

        // 2. Merge remote messages into local messages for sessions that exist locally
        // [T-ios-listsessions-part-flags] compute the bitmask inline so remote-
        // inserted rows carry correct flags (never left at DEFAULT 0).
        let mCount = execCount("""
            INSERT OR IGNORE INTO messages (id, session_id, role, parts_json, created_at, token_usage, sort_order, reasoning_content, stream_interrupt_count, updated_at, part_flags)
            SELECT rm.id, rm.session_id, rm.role, rm.parts_json, rm.created_at, rm.token_usage, rm.sort_order, rm.reasoning_content, rm.stream_interrupt_count, rm.created_at, \(Self.partFlagsSQLExpr("rm.parts_json"))
            FROM remote_messages rm
            WHERE EXISTS (SELECT 1 FROM sessions s WHERE s.id = rm.session_id)
              AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.id = rm.id)
        """)
        iCloudLogger.info("[iCloud] backfillRemoteToLocal: inserted \(mCount) messages")

        iCloudLogger.info("[iCloud] backfillRemoteToLocal: done")
    }

    /// Execute SQL and return number of changes. Returns 0 on error.
    private func execCount(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            return Int(sqlite3_changes(db))
        }
        sqlite3_finalize(stmt)
        return 0
    }

    /// Mark a session as successfully synced to iCloud.
    func markSessionSynced(id: String) {
        let sql = "UPDATE sessions SET last_synced_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    struct DirtyRecord {
        let recordType: String
        let recordId: String
        let zoneName: String
        let operation: String
    }

    /// Record types belonging to the V2 sync surface. Used to filter
    /// dirty rows so v1-only / dual-write rows don't starve V2 sends.
    /// Note: `EnvVarItem` has no V2 suffix but IS v2 — the per-key env
    /// var record introduced after EnvVarV2 (which is legacy whole-file
    /// and being phased out, but kept here so any remaining dirty rows
    /// can still drain).
    fileprivate static let v2SyncRecordTypes: [String] = [
        "SessionV2", "MessageV2", "CompactMarkerV2", "SessionFileV2",
        "FolderV2",
        "SkillV2", "ProviderConfigV2", "EnvVarV2", "EnvVarItem",
        "EnvVarStateItem",  // [T-envvar-disable]
        "SyncDeviceV2", "SoulV2",
        // File-backed singletons. Without these in the whitelist,
        // markDirty wrote a dirty row but loadDirtyRecords(v2Only:true)'s
        // WHERE-IN clause filtered them out, so they never got pushed
        // and the CloudKit Dev schema never got auto-created — root
        // cause of the dashboard's persistent NOT_FOUND on these types
        // (T-soulv2-memory-whitelist).
        "MemoryGlobalV2", "MemoryDailyV2",
        // v3 per-record provider sync (T-provider-sync-v3). The legacy
        // "ProviderConfigV2" remains in the whitelist too — outbound is
        // dual-written until all peers upgrade; inbound v2 is dropped
        // on v3 builds (ProviderV3Bootstrap.isEnabled gate).
        "ProviderInstanceV3", "ProviderModelEntryV3", "ProviderModelGroupV3",
        // [T-icloud-thinking-rules-sync] Per-rule custom thinking rules. Omitting a
        // type here is the exact failure MCPServersV2 hit below: dirty rows get
        // written but loadDirtyRecords filters them out, so nothing ever uploads
        // and the type fails SILENTLY.
        "ProviderThinkingRuleV3",
        // [T-subagent-own-store] Same rule: omit the type here and its dirty
        // rows are written but filtered out by loadDirtyRecords, so the roster
        // would never upload and the failure would be SILENT.
        "SubAgentV3",
        // [T-mcp-per-server-sync] Per-server MCP records. The legacy
        // whole-file MCPServersV2 type is gone: it never uploaded once (it was
        // never in this whitelist), so no cloud record of it exists to drain.
        "MCPServerItem",
    ]

    /// Pre-built SQL IN-list fragment for `v2SyncRecordTypes`. Values
    /// are static identifiers, no user input — safe to interpolate.
    fileprivate static let v2SyncRecordTypesSQL: String =
        v2SyncRecordTypes.map { "'\($0)'" }.joined(separator: ",")

    /// Load dirty records for sync. `v2Only=true` filters to record types
    /// the v2 SyncCore knows how to build (suffix `V2`). Without the filter,
    /// v1 dual-write rows (Session/Message/...) sit at the head of the
    /// priority+created_at ordering forever — v2 has no builder for them so
    /// they get kept-as-dirty every round, starving real V2 rows behind them.
    /// DIAG (T-memory-row-vanish): one-shot probe — call from SyncCore to
    /// dump every distinct record_type currently sitting in
    /// sync_dirty_records, regardless of any v2/v1 whitelist filter.
    /// Lets us confirm whether MemoryGlobalV2 / MemoryDailyV2 are in the
    /// table at all when v2Only's WHERE-IN filter would hide them.
    func dumpAllDirtyTypes() -> [(type: String, count: Int)] {
        var result: [(type: String, count: Int)] = []
        var stmt: OpaquePointer?
        let sql = "SELECT record_type, COUNT(*) FROM sync_dirty_records GROUP BY record_type"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let t = String(cString: sqlite3_column_text(stmt, 0))
                let c = Int(sqlite3_column_int(stmt, 1))
                result.append((t, c))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func loadDirtyRecords(v2Only: Bool = false) -> [DirtyRecord] {
        // Order Sessions first so receiving device creates sessions before messages arrive
        // Order:
        //   1. priority ASC — user-driven writes (priority=0) before
        //      migration backlog (priority=1). Critical so a freshly
        //      typed message is never starved by 28k legacy rows.
        //   2. parent type before child type — Session/SessionV2 before
        //      Message/MessageV2, so a peer applying the inbound batch
        //      sees parents before their children.
        //   3. created_at ASC within the same priority/type — push the
        //      oldest dirty first so the queue drains FIFO.
        let whereClause = v2Only ? "WHERE record_type IN (\(Self.v2SyncRecordTypesSQL))" : ""
        // [T-icloud-sync-tier2-fifo] Oldest first within each priority+type
        // group, as the numbered comment above always said. The code had
        // `created_at DESC`, which meant a backlog of N > 100 rows never
        // drained its oldest entries: every send took the 100 newest, new
        // writes kept arriving, and the tail aged forever. "What the user
        // just touched" is already prioritised by priority=0 vs the
        // migration backlog at priority=1; within one priority, FIFO is the
        // only order that guarantees every row eventually ships.
        let sql = """
            SELECT record_type, record_id, zone_name, operation FROM sync_dirty_records
            \(whereClause)
            ORDER BY priority ASC,
                CASE record_type
                    WHEN 'Session' THEN 0
                    WHEN 'SessionV2' THEN 0
                    WHEN 'Message' THEN 1
                    WHEN 'MessageV2' THEN 1
                    ELSE 2
                END,
                created_at ASC
            LIMIT 100
        """
        var stmt: OpaquePointer?
        var records: [DirtyRecord] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(DirtyRecord(
                    recordType: String(cString: sqlite3_column_text(stmt, 0)),
                    recordId: String(cString: sqlite3_column_text(stmt, 1)),
                    zoneName: String(cString: sqlite3_column_text(stmt, 2)),
                    operation: String(cString: sqlite3_column_text(stmt, 3))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return records
    }

    /// V2-only dirty counts split by priority. priority=0 → user writes,
    /// priority=1 → migration backlog. Used by the iCloud Sync sheet to
    /// show 'Pending push (new)' vs 'Pending push (migration)' rows.
    func countDirtyV2ByPriority() -> (newCount: Int, migrationCount: Int) {
        let sql = "SELECT priority, COUNT(*) FROM sync_dirty_records WHERE record_type IN (\(Self.v2SyncRecordTypesSQL)) GROUP BY priority"
        var stmt: OpaquePointer?
        var newCount = 0, migrationCount = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let p = Int(sqlite3_column_int(stmt, 0))
                let c = Int(sqlite3_column_int(stmt, 1))
                if p == 0 { newCount = c } else { migrationCount += c }
            }
        }
        sqlite3_finalize(stmt)
        return (newCount, migrationCount)
    }

    func countDirtyRecords() -> (total: Int, byType: [String: Int]) {
        let sql = "SELECT record_type, COUNT(*) FROM sync_dirty_records GROUP BY record_type"
        var stmt: OpaquePointer?
        var byType: [String: Int] = [:]
        var total = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let type = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                byType[type] = count
                total += count
            }
        }
        sqlite3_finalize(stmt)
        return (total, byType)
    }

    /// Mark every record belonging to a session — Session itself, all its
    /// Messages, CompactMarkers, and SessionFiles — as dirty so they will
    /// be re-pushed to iCloud on the next send pass. Idempotent. Used by
    /// the user-facing Force Sync action (long-press a message in chat).
    /// Returns total dirty rows added.
    @discardableResult
    func forceSyncSession(_ sessionId: String) -> Int {
        guard !syncZoneName.isEmpty else { return 0 }
        var count = 0
        markDirty(recordType: "Session", recordId: sessionId)
        count += 1
        // Messages
        var mStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM messages WHERE session_id = ?", -1, &mStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(mStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(mStmt) == SQLITE_ROW {
                markDirty(recordType: "Message", recordId: String(cString: sqlite3_column_text(mStmt, 0)))
                count += 1
            }
        }
        sqlite3_finalize(mStmt)
        // CompactMarkers
        var cStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM compact_markers WHERE session_id = ?", -1, &cStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(cStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(cStmt) == SQLITE_ROW {
                markDirty(recordType: "CompactMarker", recordId: String(cString: sqlite3_column_text(cStmt, 0)))
                count += 1
            }
        }
        sqlite3_finalize(cStmt)
        // SessionFiles via the existing scan
        let fileCount = scanAndMarkSessionFiles(sessionId: sessionId, priority: 0)
        count += fileCount
        iCloudLogger.info("[iCloud] forceSyncSession(\(sessionId.prefix(8))) marked \(count) records dirty")
        return count
    }

    /// Outcome of a Force Pull attempt.
    enum ForcePullOutcome {
        /// Cloud returned ≥1 record; local was wiped and replaced. localDeleted
        /// counts messages+markers that existed locally before the swap.
        case applied(pulledFromCloud: Int, localDeleted: Int)
        /// Cloud returned 0 records or threw — local rows are preserved
        /// untouched. The chat view should surface a warning to the user.
        case cloudEmpty
        /// Underlying transport threw an error. Local rows preserved.
        case failed(String)
    }

    /// Reconcile a session against cloud truth.
    ///
    /// New (safe) flow:
    ///   1. Pull from cloud first — does NOT touch local rows yet.
    ///   2. If cloud returned 0 records → bail out, keep local intact,
    ///      surface .cloudEmpty so the UI can warn the user that there
    ///      is no remote copy to fall back to (avoids the "Force Pull
    ///      silently wipes everything" footgun).
    ///   3. If cloud returned ≥1 record → only NOW wipe local rows +
    ///      clear dirty/pushed bookkeeping, then re-emit the cached cloud
    ///      portables through the inbound path so they land in SQLite.
    ///
    /// This means the pull network round-trip happens with local
    /// untouched, and the swap is committed atomically only after we
    /// know cloud has something to give us.
    func forcePullSession(sessionId: String) async -> ForcePullOutcome {
        // PER-SESSION: re-pulls one known session's messages. It cannot add or
        // remove a sidebar row — the session already exists locally, which is
        // what makes a force-pull meaningful.
        invalidateSessionListCache(sessionId: sessionId)
        iCloudLogger.warning("[ForcePull] sid=\(sessionId.prefix(8)) START — pulling cloud first, local untouched")

        // 1. Cloud first (no local mutation yet). Returns the portables
        //    so we can replay them after the swap. If the transport
        //    can't be reached we treat it as a hard failure rather than
        //    "empty cloud" so the caller can distinguish.
        let pullResult: ([PortableRecord], Error?)
        if #available(iOS 17.0, *) {
            pullResult = await SyncCore.shared.fetchSessionPortables(sessionId: sessionId)
        } else {
            iCloudLogger.warning("[ForcePull] sid=\(sessionId.prefix(8)) iOS < 17 — pull unavailable")
            return .failed(AppLocalized("Force Pull requires iOS 17 or newer."))
        }
        let portables = pullResult.0
        if let err = pullResult.1 {
            iCloudLogger.warning("[ForcePull] sid=\(sessionId.prefix(8)) transport err: \(err.localizedDescription) — keeping local intact")
            return .failed(err.localizedDescription)
        }
        if portables.isEmpty {
            iCloudLogger.warning("[ForcePull] sid=\(sessionId.prefix(8)) cloud returned 0 records — keeping local intact")
            return .cloudEmpty
        }
        iCloudLogger.warning("[ForcePull] sid=\(sessionId.prefix(8)) cloud returned \(portables.count) records — committing swap")

        // 2. Now safe to swap. Collect ids for bookkeeping cleanup.
        var messageIds: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM messages WHERE session_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                messageIds.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        var markerIds: [String] = []
        var mStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM compact_markers WHERE session_id = ?", -1, &mStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(mStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(mStmt) == SQLITE_ROW {
                markerIds.append(String(cString: sqlite3_column_text(mStmt, 0)))
            }
        }
        sqlite3_finalize(mStmt)

        // 3. Hard-delete local rows (cloud truth will be replayed below).
        var locallyDeleted = 0
        var dStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM messages WHERE session_id = ?", -1, &dStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(dStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(dStmt)
            locallyDeleted += Int(sqlite3_changes(db))
        }
        sqlite3_finalize(dStmt)
        var dmStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM compact_markers WHERE session_id = ?", -1, &dmStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(dmStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(dmStmt)
            locallyDeleted += Int(sqlite3_changes(db))
        }
        sqlite3_finalize(dmStmt)

        // 4. Clear sync_dirty_records and sync_pushed_records so the
        // replay treats incoming portables as fresh, and so we don't
        // immediately re-push stale rows.
        for id in messageIds {
            clearDirtyRecord(recordName: "Message:\(id)")
        }
        for id in markerIds {
            clearDirtyRecord(recordName: "CompactMarker:\(id)")
        }
        clearDirtyRecord(recordName: "Session:\(sessionId)")

        var pushedClearStmt: OpaquePointer?
        let clearPushedSQL = "DELETE FROM sync_pushed_records WHERE record_name = ?"
        if sqlite3_prepare_v2(db, clearPushedSQL, -1, &pushedClearStmt, nil) == SQLITE_OK {
            for id in messageIds {
                sqlite3_bind_text(pushedClearStmt, 1, ("Message:\(id)" as NSString).utf8String, -1, nil)
                sqlite3_step(pushedClearStmt)
                sqlite3_reset(pushedClearStmt)
            }
            for id in markerIds {
                sqlite3_bind_text(pushedClearStmt, 1, ("CompactMarker:\(id)" as NSString).utf8String, -1, nil)
                sqlite3_step(pushedClearStmt)
                sqlite3_reset(pushedClearStmt)
            }
            sqlite3_bind_text(pushedClearStmt, 1, ("Session:\(sessionId)" as NSString).utf8String, -1, nil)
            sqlite3_step(pushedClearStmt)
        }
        sqlite3_finalize(pushedClearStmt)

        iCloudLogger.warning("[ForcePull] sid=\(sessionId.prefix(8)) local cleared: messages=\(messageIds.count) markers=\(markerIds.count) deletedRows=\(locallyDeleted)")

        // 5. Replay cloud portables through SyncCore (same path normal
        // inbound traffic uses, so hydrators land them in SQLite).
        await SyncCore.shared.applyPortables(portables, transportName: "ForcePull")
        iCloudLogger.warning("[ForcePull] sid=\(sessionId.prefix(8)) DONE pulled=\(portables.count) localDeleted=\(locallyDeleted)")
        return .applied(pulledFromCloud: portables.count, localDeleted: locallyDeleted)
    }

    /// Drop all priority=1 dirty rows (migration backlog). Used by Cancel
    /// Migration in the Sync sheet — keeps user-driven (priority=0) rows
    /// so freshly typed messages keep flowing while history backfill stops.
    /// Returns the number of rows deleted.
    @discardableResult
    func clearMigrationBacklog() -> Int {
        let sql = "DELETE FROM sync_dirty_records WHERE priority = 1"
        var stmt: OpaquePointer?
        var deleted = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            deleted = Int(sqlite3_changes(db))
        }
        sqlite3_finalize(stmt)
        iCloudLogger.info("[iCloud] clearMigrationBacklog: dropped \(deleted) priority=1 rows")
        return deleted
    }

    /// Count V2 records that exist locally but have not yet been pushed
    /// to v2's shared zone (i.e. would be backfilled if migration ran).
    /// We approximate by total local row counts minus the cumulative
    /// pushedCumulative counter — exact enough for the "Historical Data"
    /// label in the Sync sheet.
    func countLocalV2Eligible() -> Int {
        let sessions = queryInt64("SELECT COUNT(*) FROM sessions")
        let messages = queryInt64("SELECT COUNT(*) FROM messages")
        let markers = queryInt64("SELECT COUNT(*) FROM compact_markers")
        // session files = (rough heuristic) sum of file_count column if it exists; otherwise 0
        return Int(sessions + messages + markers)
    }

    /// Clear a dirty row after the transport acknowledged it.
    ///
    /// [T-sync-message-resurrection] `ifOperation` is the operation that was
    /// actually sent. `sync_dirty_records` is keyed by (type, id) and
    /// `markDirty` is INSERT OR REPLACE, so a delete marked while an upsert
    /// of the same record was in flight *replaces* that row; clearing
    /// unconditionally on the upsert's success then destroyed the delete —
    /// the tombstone was never pushed and the remote copy lived on. With
    /// the guard, a row whose operation no longer matches what was sent is
    /// left for the next batch.
    func clearDirtyRecord(recordName: String, ifOperation: String? = nil) {
        // recordName format is "Type:id"
        let parts = recordName.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let recordType = String(parts[0])
        let recordId = String(parts[1])
        let sql = ifOperation == nil
            ? "DELETE FROM sync_dirty_records WHERE record_type = ? AND record_id = ?"
            : "DELETE FROM sync_dirty_records WHERE record_type = ? AND record_id = ? AND operation = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (recordType as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (recordId as NSString).utf8String, -1, nil)
            if let op = ifOperation {
                sqlite3_bind_text(stmt, 3, (op as NSString).utf8String, -1, nil)
            }
            sqlite3_step(stmt)
            if let op = ifOperation, sqlite3_changes(db) == 0 {
                iCloudLogger.info("[iCloudTrace] clearDirty KEPT \(recordType):\(recordId.prefix(8)) — operation changed while in flight (sent=\(op))")
            }
        }
        sqlite3_finalize(stmt)
    }

    /// Record one or more record names as confirmed saved on iCloud.
    /// Idempotent — INSERT OR IGNORE on the recordName primary key.
    /// Used by the v2 transport to feed the migration UI's accurate
    /// "unique records pushed" counter, which is otherwise inflated by
    /// every relaunch re-marking already-pushed records dirty.
    func markRecordsPushed(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        exec("BEGIN TRANSACTION")
        let sql = "INSERT OR IGNORE INTO sync_pushed_records (record_name) VALUES (?)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for name in recordNames {
                sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
    }

    /// [T-icloud-migration-reset] Wipe the pushed-record ledger so a migration
    /// restarted from scratch re-counts (and re-pushes) everything.
    ///
    /// Only for the explicit "reset migration progress" action. Clearing this
    /// on any other path would make already-uploaded records look un-pushed and
    /// send them again. Returns the row count removed, for the log.
    @discardableResult
    func clearAllPushedRecords() -> Int {
        let before = countPushedRecords()
        exec("DELETE FROM sync_pushed_records")
        iCloudLogger.info("[iCloud] clearAllPushedRecords: removed \(before) rows")
        return before
    }

    /// Distinct count of recordNames in `sync_pushed_records`. The
    /// migration UI's "Records pushed" numerator.
    func countPushedRecords() -> Int {
        var count = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sync_pushed_records", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    // Directories to skip when scanning session files for iCloud sync.
    // These contain build artifacts, caches, and VCS internals that should not be synced.
    private static let syncSkipDirNames: Set<String> = [
        "__pycache__", ".git", ".svn", ".hg",
        "node_modules", ".tox", ".venv", "venv",
        ".build", ".eggs",
        ".mypy_cache", ".pytest_cache", ".ruff_cache",
        "__pypackages__", ".gradle", ".idea",
    ]

    /// Scan workspace/offloads/attachments dirs for a session and markDirty for each file.
    /// Returns number of files marked.
    @discardableResult
    func scanAndMarkSessionFiles(sessionId: String, priority: Int = 0) -> Int {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let sessionDir = library.appendingPathComponent("MinisChat/minis/\(sessionId)")
        guard fm.fileExists(atPath: sessionDir.path) else { return 0 }
        // Standardize to resolve /private/var vs /var symlink differences
        let sessionDirStd = sessionDir.standardizedFileURL.path

        let subdirs = ["workspace", "offloads", "attachments", "browser"]
        var count = 0
        var subdirCounts: [String: Int] = [:]
        var totalBytes: Int = 0
        var skippedOversize = 0
        var skippedDisabled = 0
        var skippedJunkDir = 0
        for subdir in subdirs {
            let dirURL = sessionDir.appendingPathComponent(subdir)
            guard let enumerator = fm.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var subdirCount = 0
            for case let fileURL as URL in enumerator {
                // Skip entire junk directories (build artifacts, caches, VCS internals)
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir {
                    if Self.syncSkipDirNames.contains(fileURL.lastPathComponent) {
                        enumerator.skipDescendants()
                        skippedJunkDir += 1
                    }
                    continue
                }
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                // Skip files exceeding max sync size (single source of truth: UploadPolicy)
                let maxSize = UploadPolicy.maxFileSizeBytes
                if fileSize > maxSize { skippedOversize += 1; continue }
                // recordId format: "sessionId:subdir/relativePath"
                let fileStd = fileURL.standardizedFileURL.path
                let prefix = sessionDirStd + "/"
                let relativePath = fileStd.hasPrefix(prefix) ? String(fileStd.dropFirst(prefix.count)) : fileURL.lastPathComponent
                markDirty(recordType: "SessionFile", recordId: "\(sessionId):\(relativePath)", priority: priority)
                count += 1
                subdirCount += 1
                totalBytes += fileSize
            }
            if subdirCount > 0 { subdirCounts[subdir] = subdirCount }
        }
        if count > 0 || skippedOversize > 0 || skippedJunkDir > 0 {
            let breakdown = subdirCounts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            iCloudLogger.info("[iCloud] ⏱ scanAndMarkSessionFiles[\(sessionId.prefix(8))]: \(count) files (\(totalBytes / 1024)KB) cap=\(UploadPolicy.maxFileSizeBytes / 1024)KB skippedOversize=\(skippedOversize) skippedJunkDirs=\(skippedJunkDir) [\(breakdown)]")
        }
        _ = skippedDisabled
        return count
    }
}
