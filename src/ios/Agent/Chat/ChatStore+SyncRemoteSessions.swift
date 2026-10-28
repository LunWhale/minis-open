//
//  ChatStore+SyncRemoteSessions.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, inbound sync of sessions and messages: upsert / merge a remote
//  session or message into local tables, delete, list and load remote rows.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let iCloudLogger = AppLogger(category: "iCloud")

extension ChatStore {
    // MARK: - Remote Session CRUD

    func upsertRemoteSession(_ session: ChatSession, deviceId: String) {
        iCloudLogger.info("[iCloud] upsertRemoteSession: id=\(session.id) title=\(session.title ?? "nil") deviceId=\(deviceId) model=\(session.modelId)")
        let sql = """
            INSERT OR REPLACE INTO remote_sessions (id, device_id, title, category, model_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (session.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, index: 3, value: session.title)
            bindOptionalText(stmt, index: 4, value: session.category)
            sqlite3_bind_text(stmt, 5, (session.modelId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 6, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, session.updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Merge a remote session into local sessions table (last-write-wins).
    /// If local doesn't have this session → insert with remote_origin_device_id.
    /// If local has it but remote updated_at is newer → update title/category/updated_at.
    /// If local has it and is newer → skip.
    /// Merge a remote session into local sessions table.
    /// - `remotePinnedAtRaw`: The raw pinnedAt Date from CKRecord. nil = old device (field absent),
    ///   epoch 0 = explicitly unpinned, positive = pinned timestamp.
    /// - `remoteHasFolderField`: whether the inbound record carried the
    ///   folderId key AT ALL. Old-build peers omit it entirely; for them the
    ///   local folder assignment must be preserved, whereas a new-build peer
    ///   sending an explicit nil means "ungrouped on that device" and, when
    ///   remote is newer, that wins (folder_id rides the session's LWW).
    func mergeRemoteSession(_ session: ChatSession, fromDeviceId: String, memoryEnabled: Bool = true, modelBinding: String? = nil, remotePinnedAtRaw: Date? = nil, remoteFolderId: String? = nil, remoteHasFolderField: Bool = false,
                            remoteParentSessionId: String? = nil, remoteParentToolUseId: String? = nil, remoteHasParentField: Bool = false) {
        // FULL: a remote session may be one this device has never seen, so it
        // can ADD a row to the set — the incremental patch cannot express that.
        invalidateSessionListCache()
        // [T-p1-delegate-task] Parent linkage is immutable for the life of a
        // child (only a future "promote" clears it), so the merge rule is
        // simple: adopt the peer's value whenever the peer's record carries
        // the field. An old-build peer omitting it must not clear ours.
        defer {
            if remoteHasParentField {
                let pSql = "UPDATE sessions SET parent_session_id = ?, parent_tool_use_id = ? WHERE id = ?"
                var pStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, pSql, -1, &pStmt, nil) == SQLITE_OK {
                    bindOptionalText(pStmt, index: 1, value: remoteParentSessionId)
                    bindOptionalText(pStmt, index: 2, value: remoteParentToolUseId)
                    sqlite3_bind_text(pStmt, 3, (session.id as NSString).utf8String, -1, nil)
                    sqlite3_step(pStmt)
                }
                sqlite3_finalize(pStmt)
            }
        }
        // Check if local session exists and its updated_at + pinned_at
        var localUpdatedAt: Double?
        var localPinnedAt: Double?
        var localFolderId: String?
        let checkSql = "SELECT updated_at, pinned_at, folder_id FROM sessions WHERE id = ?"
        var checkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, (session.id as NSString).utf8String, -1, nil)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                localUpdatedAt = sqlite3_column_double(checkStmt, 0)
                if sqlite3_column_type(checkStmt, 1) != SQLITE_NULL {
                    localPinnedAt = sqlite3_column_double(checkStmt, 1)
                }
                localFolderId = sqlite3_column_text(checkStmt, 2).map { String(cString: $0) }
            }
        }
        sqlite3_finalize(checkStmt)

        let remoteUpdated = session.updatedAt.timeIntervalSince1970

        // Resolve pinned_at merge:
        // - remotePinnedAtRaw == nil → old device, don't touch local pin state
        // - remotePinnedAtRaw == epoch 0 → explicit unpin from remote
        // - remotePinnedAtRaw > 0 → pin from remote
        // Rule: most recent pin/unpin wins (by timestamp). If remote has no pin info, keep local.
        let resolvedPinnedAt: Double? = {
            guard let rawDate = remotePinnedAtRaw else {
                // Old device didn't send pinnedAt — preserve local state
                return localPinnedAt
            }
            let remoteTs = rawDate.timeIntervalSince1970
            if remoteTs <= 0 {
                // Remote explicitly unpinned
                if let localTs = localPinnedAt {
                    // Local is pinned — keep local pin (local action is more recent if user pinned locally)
                    // We can't know which is newer without a dedicated pin_updated_at, so keep local pin
                    // to avoid accidental unpin from stale remote state
                    return localTs
                }
                return nil // both unpinned
            } else {
                // Remote is pinned
                if let localTs = localPinnedAt {
                    // Both pinned — keep the more recent pin timestamp
                    return max(remoteTs, localTs)
                }
                // Local not pinned, remote is pinned — adopt remote pin
                return remoteTs
            }
        }()

        if let localTs = localUpdatedAt {
            // Local exists — only update title/category/etc if remote is newer
            if remoteUpdated > localTs {
                iCloudLogger.info("[iCloud] mergeRemoteSession UPDATE (remote newer): id=\(session.id) remoteTs=\(remoteUpdated) localTs=\(localTs)")
                // folder_id is written ONLY when the peer's record carried
                // the field — an old build's record omitting it must not wipe
                // a local folder assignment (same tolerance pinnedAt got).
                let sql = remoteHasFolderField
                    ? "UPDATE sessions SET title = ?, category = ?, updated_at = ?, memory_enabled = ?, model_binding = ?, pinned_at = ?, folder_id = ? WHERE id = ?"
                    : "UPDATE sessions SET title = ?, category = ?, updated_at = ?, memory_enabled = ?, model_binding = ?, pinned_at = ? WHERE id = ?"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    bindOptionalText(stmt, index: 1, value: session.title)
                    bindOptionalText(stmt, index: 2, value: session.category)
                    sqlite3_bind_double(stmt, 3, remoteUpdated)
                    sqlite3_bind_int(stmt, 4, memoryEnabled ? 1 : 0)
                    bindOptionalText(stmt, index: 5, value: modelBinding)
                    if let pinTs = resolvedPinnedAt {
                        sqlite3_bind_double(stmt, 6, pinTs)
                    } else {
                        sqlite3_bind_null(stmt, 6)
                    }
                    if remoteHasFolderField {
                        bindOptionalText(stmt, index: 7, value: remoteFolderId)
                        sqlite3_bind_text(stmt, 8, (session.id as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_text(stmt, 7, (session.id as NSString).utf8String, -1, nil)
                    }
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                // Wake the home list. ContentView observes
                // .sessionDidUpdate (debounce 3s — fine for title/pin
                // edits arriving from a peer). Without this post a
                // remote-newer merge silently updated SQLite while the
                // list kept showing the stale snapshot until the user
                // backgrounded the app or pulled-to-refresh
                // (T-inbound-session-no-refresh).
                NotificationCenter.default.post(name: .sessionDidUpdate, object: session.id)
            } else {
                let delta = localTs - remoteUpdated
                iCloudLogger.info("[iCloud] mergeRemoteSession SKIP (local newer): id=\(session.id) localTs=\(localTs) remoteTs=\(remoteUpdated) delta=\(String(format: "%+.3f", delta))s from=\(fromDeviceId)")
                if remoteUpdated > localTs {
                    iCloudLogger.warning("[iCloud] mergeRemoteSession SKIP despite remote-newer: id=\(session.id) localTs=\(localTs) remoteTs=\(remoteUpdated) — should not happen")
                }
                // Folder membership needs the same skip-branch sub-merge as
                // pin state, and for the same root cause: filing a session
                // does NOT bump updated_at (an organizational move must not
                // resort the list), so a peer's folder move arrives with an
                // unchanged session timestamp, lands in THIS branch, and
                // would otherwise never apply anywhere.
                //
                // Conservative rule, mirroring the stale-unpin guard below:
                // adopt the remote folder only when we have no local opinion
                // (local NULL). remote-NULL-vs-local-set and set-vs-set-
                // different keep local — without a per-field timestamp we
                // can't rank the two writes, and this is the local-newer
                // branch. Known accepted limitation (same class as pin's):
                // a bare "move out of folder" with no other session activity
                // does not propagate; the dissolve path is unaffected since
                // it also ships a FolderV2 tombstone that clears members.
                if remoteHasFolderField, localFolderId == nil, let remoteFid = remoteFolderId {
                    let fSql = "UPDATE sessions SET folder_id = ? WHERE id = ? AND folder_id IS NULL"
                    var fStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, fSql, -1, &fStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(fStmt, 1, (remoteFid as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(fStmt, 2, (session.id as NSString).utf8String, -1, nil)
                        sqlite3_step(fStmt)
                    }
                    sqlite3_finalize(fStmt)
                    iCloudLogger.info("[iCloud] mergeRemoteSession folder sub-merge: id=\(session.id.prefix(8)) -> folder \(remoteFid.prefix(8))")
                    NotificationCenter.default.post(name: .sessionDidUpdate, object: session.id)
                }
                // Even if we skip the main update, still merge pin state if remote has pin info
                // and the resolved pin differs from local
                if remotePinnedAtRaw != nil, resolvedPinnedAt != localPinnedAt {
                    let pinSql = "UPDATE sessions SET pinned_at = ? WHERE id = ?"
                    var pinStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, pinSql, -1, &pinStmt, nil) == SQLITE_OK {
                        if let pinTs = resolvedPinnedAt {
                            sqlite3_bind_double(pinStmt, 1, pinTs)
                        } else {
                            sqlite3_bind_null(pinStmt, 1)
                        }
                        sqlite3_bind_text(pinStmt, 2, (session.id as NSString).utf8String, -1, nil)
                        sqlite3_step(pinStmt)
                    }
                    sqlite3_finalize(pinStmt)
                }
            }
        } else {
            // [T-icloud-deleted-session-resurrection] Refuse to resurrect a
            // session the user just deleted locally. fetchRecentV2 can pull the
            // still-present cloud record back before our delete tombstone lands;
            // without this guard the session reappears (with a ☁️ remote-origin
            // marker). Only block when the inbound record isn't newer than the
            // deletion — a genuine newer re-create of the same id still applies.
            if isResurrectionOfDeleted(session.id, remoteUpdatedAt: Date(timeIntervalSince1970: remoteUpdated)) {
                iCloudLogger.info("[iCloud] mergeRemoteSession SKIP (recently deleted locally — resurrection blocked): id=\(session.id) remoteTs=\(remoteUpdated)")
                return
            }
            // Local doesn't have this session — insert
            iCloudLogger.info("[iCloud] mergeRemoteSession INSERT: id=\(session.id) title=\(session.title ?? "nil") from=\(fromDeviceId)")
            let sql = "INSERT INTO sessions (id, title, category, model_id, created_at, updated_at, remote_origin_device_id, memory_enabled, model_binding, pinned_at, folder_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (session.id as NSString).utf8String, -1, nil)
                bindOptionalText(stmt, index: 2, value: session.title)
                bindOptionalText(stmt, index: 3, value: session.category)
                sqlite3_bind_text(stmt, 4, (session.modelId as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 5, session.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 6, remoteUpdated)
                sqlite3_bind_text(stmt, 7, (fromDeviceId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 8, memoryEnabled ? 1 : 0)
                bindOptionalText(stmt, index: 9, value: modelBinding)
                if let pinTs = resolvedPinnedAt {
                    sqlite3_bind_double(stmt, 10, pinTs)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                // A folder_id referencing a folder we don't have yet is fine —
                // the list renders it as ungrouped until FolderV2 arrives
                // (fetchRecentV2 ordering gives no cross-type guarantees).
                bindOptionalText(stmt, index: 11, value: remoteHasFolderField ? remoteFolderId : nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            // Brand-new remote session — post `.sessionDidCreate` so the
            // home list reloads immediately (no debounce on this name).
            // Matches the local-create path at AIChatViewModel.swift:4266
            // (T-inbound-session-no-refresh).
            NotificationCenter.default.post(name: .sessionDidCreate, object: session.id)
        }

        // Backfill: messages may have arrived before this session was merged,
        // or the session already existed locally and remote messages were stored
        // only in remote_messages. Always try to backfill missing messages.
        // [T-ios-listsessions-part-flags] inline bitmask (see backfillRemoteToLocal).
        let backfillSql = """
            INSERT OR IGNORE INTO messages (id, session_id, role, parts_json, created_at, token_usage, sort_order, reasoning_content, stream_interrupt_count, updated_at, part_flags)
            SELECT rm.id, rm.session_id, rm.role, rm.parts_json, rm.created_at, rm.token_usage, rm.sort_order, rm.reasoning_content, rm.stream_interrupt_count, rm.created_at, \(Self.partFlagsSQLExpr("rm.parts_json"))
            FROM remote_messages rm WHERE rm.session_id = ? AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.id = rm.id)
        """
        var bfStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, backfillSql, -1, &bfStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(bfStmt, 1, (session.id as NSString).utf8String, -1, nil)
            sqlite3_step(bfStmt)
        }
        sqlite3_finalize(bfStmt)
        let backfilled = sqlite3_changes(db)
        if backfilled > 0 {
            iCloudLogger.info("[iCloud] mergeRemoteSession backfilled \(backfilled) messages for \(session.id)")
        }
    }

    /// Delete a local session if it originated from the given device (remote deletion propagation).
    func deleteLocalSessionIfFromDevice(id: String, deviceId: String) {
        // FULL: may remove a row from the set.
        invalidateSessionListCache()
        let sql = "DELETE FROM sessions WHERE id = ? AND remote_origin_device_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                iCloudLogger.info("[iCloud] deleteLocalSessionIfFromDevice: deleted session \(id) (origin: \(deviceId))")
                // Also clean up messages
                let delMsgSql = "DELETE FROM messages WHERE session_id = ?"
                var delMsgStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, delMsgSql, -1, &delMsgStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(delMsgStmt, 1, (id as NSString).utf8String, -1, nil)
                    sqlite3_step(delMsgStmt)
                }
                sqlite3_finalize(delMsgStmt)
            }
        }
        sqlite3_finalize(stmt)
    }

    /// Merge a remote message into local messages table if the session exists locally.
    /// Uses conditional upsert: INSERT if new, UPDATE if remote updated_at is newer.
    func mergeRemoteMessage(
        id: String, sessionId: String, role: String, partsJson: String,
        createdAt: Date, tokenUsageJson: String?, sortOrder: Int,
        reasoningContent: String?, streamInterruptCount: Int,
        updatedAt: Date? = nil,
        // [T-token-attribution-snapshot] nil when the sending device predates
        // these fields. nil means "the remote told us nothing", NOT "the remote
        // says this is empty" — the UPDATE below preserves the local value in
        // that case. See the COALESCE note there.
        modelId: String? = nil, modelDisplayName: String? = nil,
        providerType: String? = nil, providerInstanceId: String? = nil
    ) {
        // PER-SESSION: a remote message lands in one known session. If that
        // session does not exist locally yet it arrives through
        // mergeRemoteSession first, which invalidates fully.
        invalidateSessionListCache(sessionId: sessionId)
        // Defer merging into a session that's actively running locally. While
        // an agent loop is streaming / running tools, the message list is
        // volatile and locally authoritative: appends bump sort_order and
        // updated_at every tool round. A remote message arriving mid-run (often
        // this device's own just-pushed rows echoed back by CloudKit) would
        // win LWW or, worse, re-rank sort_order via the insert path's shift —
        // scrambling the running session so listSessions can't resolve its
        // preview ("No messages yet") and stale pre-retry content reappears.
        // CloudKit re-delivers unmerged changes on the next fetch, so skipping
        // here is safe: the session re-syncs once the run finishes and the
        // tracker clears. [T-sync-clobbers-running-session]
        if SessionActivityTracker.isActiveThreadSafe(sessionId) {
            iCloudLogger.info("[iCloud] mergeRemoteMessage DEFER (session running locally): id=\(id.prefix(8)) sid=\(sessionId.prefix(8))")
            return
        }

        // Only merge if the session exists in local sessions table
        let checkSql = "SELECT id FROM sessions WHERE id = ?"
        var checkStmt: OpaquePointer?
        var sessionExists = false
        if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sessionExists = sqlite3_step(checkStmt) == SQLITE_ROW
        }
        sqlite3_finalize(checkStmt)
        guard sessionExists else {
            // [T-icloud-sync-tier1-parents-first] The only early return in
            // this function that used to say nothing. It fires when a
            // message arrives before its session row; SyncCore now orders
            // batches parents-first so this should be rare, and when it is
            // not, the log is what tells us why a session looks empty.
            iCloudLogger.info("[iCloud] mergeRemoteMessage SKIP (session row not present yet): id=\(id.prefix(8)) sid=\(sessionId.prefix(8)) — will apply on next fetch")
            return
        }

        // [T-icloud-deleted-session-resurrection] Defence in depth: even if the
        // parent session row somehow exists, refuse to re-insert a message whose
        // session was just deleted locally and isn't newer than the deletion —
        // so a stale inbound message can't resurrect content under a tombstoned
        // session. (The session guard above normally already blocks this, since
        // a deleted session has no row.)
        let msgUpdatedAt = updatedAt ?? createdAt
        if isResurrectionOfDeleted(sessionId, remoteUpdatedAt: msgUpdatedAt) {
            iCloudLogger.info("[iCloud] mergeRemoteMessage SKIP (parent session recently deleted — resurrection blocked): id=\(id.prefix(8)) sid=\(sessionId.prefix(8))")
            return
        }
        // [T-sync-message-resurrection] Same guard at message granularity.
        // Retry / edit / delete-from remove rows locally and queue delete
        // tombstones; the remote copy (often this device's own push that
        // was still in flight) must not come back as a "new" row. A genuinely
        // newer re-create (remote updated after the local delete) still merges.
        if isRecentlyDeletedRecord(type: "Message", id: id, remoteUpdatedAt: msgUpdatedAt) {
            iCloudLogger.info("[iCloud] mergeRemoteMessage SKIP (message recently deleted locally — resurrection blocked): id=\(id.prefix(8)) sid=\(sessionId.prefix(8))")
            return
        }

        // Effective updated_at: use provided value, or fall back to created_at
        // (old devices don't send updated_at)
        let effectiveUpdatedAt = (updatedAt ?? createdAt).timeIntervalSince1970

        // Check if message already exists locally and its updated_at
        var localUpdatedAt: Double?
        let existSql = "SELECT COALESCE(updated_at, created_at) FROM messages WHERE id = ?"
        var existStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, existSql, -1, &existStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(existStmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(existStmt) == SQLITE_ROW {
                localUpdatedAt = sqlite3_column_double(existStmt, 0)
            }
        }
        sqlite3_finalize(existStmt)

        if let localTs = localUpdatedAt {
            // Message exists — only update if remote is strictly newer
            guard effectiveUpdatedAt > localTs else {
                let delta = localTs - effectiveUpdatedAt
                // Even when LWW says skip, opportunistically heal a
                // stale local sort_order if the remote value disagrees.
                // Common case: a previous build pushed sortOrder=0 for
                // every message and the receiver's collision-by-arrival
                // path stamped them with arbitrary positions. New build
                // pushes correct sortOrder but updatedAt is unchanged
                // (force-sync just re-uploads the same content), so
                // strict-newer LWW would otherwise stay forever wrong.
                // Note: previous builds healed local sort_order from the remote integer
                // here. That's now intentionally dropped — remote sortOrder is a
                // best-effort hint; the receiver derives its own from (created_at, id)
                // rank on insert, and `repairSession` fixes any rank inversions on
                // session open. See sessionNeedsRepair / mergeRemoteMessage insert path.
                iCloudLogger.info("[iCloud] mergeRemoteMessage SKIP (local newer): id=\(id) localTs=\(localTs) remoteTs=\(effectiveUpdatedAt) delta=\(String(format: "%+.3f", delta))s")
                return
            }
            iCloudLogger.info("[iCloud] mergeRemoteMessage UPDATE (remote newer): id=\(id) remoteTs=\(effectiveUpdatedAt) localTs=\(localTs)")
            // Don't overwrite local sort_order from remote — receivers own ordering
            // (derived from created_at rank on insert; repaired by repairSession).
            // [T-ios-listsessions-part-flags] recompute from the inbound JSON.
            let partFlags = Self.partFlags(fromPartsJSON: partsJson)
            // [T-token-attribution-snapshot] The four attribution columns use
            // COALESCE(?, col) rather than a plain assignment.
            //
            // A device running an older build re-sends this message WITHOUT
            // these fields. A plain `model_id = ?` would then bind NULL and
            // erase a snapshot this device recorded correctly — and because
            // conflict resolution is last-write-wins on updated_at, the older
            // device can legitimately win. The result would be attribution that
            // silently disappears at random, which is close to impossible to
            // diagnose from a bug report.
            //
            // COALESCE encodes the real semantics: absent means "no opinion",
            // so keep what we have. Note this is only correct for snapshot-type
            // columns; parts_json and friends must still be overwritten, since
            // for those an incoming value genuinely is the newer truth.
            let updateSql = """
                UPDATE messages SET parts_json = ?, token_usage = ?, reasoning_content = ?,
                    stream_interrupt_count = ?, updated_at = ?, part_flags = ?,
                    model_id = COALESCE(?, model_id),
                    model_display_name = COALESCE(?, model_display_name),
                    provider_type = COALESCE(?, provider_type),
                    provider_instance_id = COALESCE(?, provider_instance_id)
                WHERE id = ?
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (partsJson as NSString).utf8String, -1, nil)
                if let tu = tokenUsageJson { sqlite3_bind_text(stmt, 2, (tu as NSString).utf8String, -1, nil) }
                else { sqlite3_bind_null(stmt, 2) }
                if let r = reasoningContent { sqlite3_bind_text(stmt, 3, (r as NSString).utf8String, -1, nil) }
                else { sqlite3_bind_null(stmt, 3) }
                sqlite3_bind_int(stmt, 4, Int32(streamInterruptCount))
                sqlite3_bind_double(stmt, 5, effectiveUpdatedAt)
                sqlite3_bind_int64(stmt, 6, Int64(partFlags))
                // 7-10 feed the COALESCE guards: binding NULL leaves the
                // existing column untouched, which is what an older sender
                // (who knows nothing of these fields) must not disturb.
                bindOptionalText(stmt, index: 7, value: modelId)
                bindOptionalText(stmt, index: 8, value: modelDisplayName)
                bindOptionalText(stmt, index: 9, value: providerType)
                bindOptionalText(stmt, index: 10, value: providerInstanceId)
                sqlite3_bind_text(stmt, 11, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        } else {
            // Message doesn't exist — insert.
            // Always derive finalSortOrder from (created_at, id) rank against
            // existing local rows; never trust the wire integer. The remote
            // sortOrder is a best-effort hint that's wrong whenever sender
            // and receiver have differing message counts (sender's larger
            // values would otherwise stick on the receiver and push synced
            // messages past the local tail). Tiebreak by id lexicographic
            // to match the canonical (created_at ASC, id ASC) order used by
            // repairSession at line ~2408.
            let createdAtTs = createdAt.timeIntervalSince1970
            let earlierSql = """
                SELECT COALESCE(MAX(sort_order), -1)
                FROM messages
                WHERE session_id = ?
                  AND (created_at < ? OR (created_at = ? AND id < ?))
            """
            var earlierStmt: OpaquePointer?
            var earlierMax: Int32 = -1
            if sqlite3_prepare_v2(db, earlierSql, -1, &earlierStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(earlierStmt, 1, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_double(earlierStmt, 2, createdAtTs)
                sqlite3_bind_double(earlierStmt, 3, createdAtTs)
                sqlite3_bind_text(earlierStmt, 4, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(earlierStmt) == SQLITE_ROW {
                    earlierMax = sqlite3_column_int(earlierStmt, 0)
                }
            }
            sqlite3_finalize(earlierStmt)

            let laterSql = """
                SELECT MIN(sort_order)
                FROM messages
                WHERE session_id = ?
                  AND (created_at > ? OR (created_at = ? AND id > ?))
            """
            var laterStmt: OpaquePointer?
            var hasLater = false
            var laterMin: Int32 = 0
            if sqlite3_prepare_v2(db, laterSql, -1, &laterStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(laterStmt, 1, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_double(laterStmt, 2, createdAtTs)
                sqlite3_bind_double(laterStmt, 3, createdAtTs)
                sqlite3_bind_text(laterStmt, 4, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(laterStmt) == SQLITE_ROW {
                    if sqlite3_column_type(laterStmt, 0) != SQLITE_NULL {
                        hasLater = true
                        laterMin = sqlite3_column_int(laterStmt, 0)
                    }
                }
            }
            sqlite3_finalize(laterStmt)

            let finalSortOrder: Int
            if !hasLater {
                // Append: nothing comes after.
                finalSortOrder = Int(earlierMax) + 1
            } else if earlierMax + 1 < laterMin {
                // Gap available — slot in without shifting.
                finalSortOrder = Int(earlierMax) + 1
            } else {
                // Shift all later rows up by 1 to make room.
                let shiftSql = "UPDATE messages SET sort_order = sort_order + 1 WHERE session_id = ? AND sort_order >= ?"
                var shiftStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, shiftSql, -1, &shiftStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(shiftStmt, 1, (sessionId as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(shiftStmt, 2, laterMin)
                    sqlite3_step(shiftStmt)
                }
                sqlite3_finalize(shiftStmt)
                finalSortOrder = Int(laterMin)
            }

            iCloudLogger.info("[iCloud] mergeRemoteMessage INSERT: id=\(id) session=\(sessionId) sortOrder=\(finalSortOrder) (remoteHint=\(sortOrder))")
            // [T-ios-listsessions-part-flags] recompute from the inbound JSON.
            let partFlags = Self.partFlags(fromPartsJSON: partsJson)
            let insertSql = """
                INSERT INTO messages (id, session_id, role, parts_json, created_at, token_usage, sort_order, reasoning_content, stream_interrupt_count, updated_at, part_flags, model_id, model_display_name, provider_type, provider_instance_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (role as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (partsJson as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 5, createdAt.timeIntervalSince1970)
                if let tu = tokenUsageJson { sqlite3_bind_text(stmt, 6, (tu as NSString).utf8String, -1, nil) }
                else { sqlite3_bind_null(stmt, 6) }
                sqlite3_bind_int(stmt, 7, Int32(finalSortOrder))
                if let r = reasoningContent { sqlite3_bind_text(stmt, 8, (r as NSString).utf8String, -1, nil) }
                else { sqlite3_bind_null(stmt, 8) }
                sqlite3_bind_int(stmt, 9, Int32(streamInterruptCount))
                sqlite3_bind_double(stmt, 10, effectiveUpdatedAt)
                sqlite3_bind_int64(stmt, 11, Int64(partFlags))
                // [T-token-attribution-snapshot] Carried through so a message
                // that first arrives from another device keeps the attribution
                // that device measured. Plain binds (not COALESCE) — on INSERT
                // there is no local value to protect.
                bindOptionalText(stmt, index: 12, value: modelId)
                bindOptionalText(stmt, index: 13, value: modelDisplayName)
                bindOptionalText(stmt, index: 14, value: providerType)
                bindOptionalText(stmt, index: 15, value: providerInstanceId)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        // Notify the in-process ViewModel cache that this session's
        // messages have changed via iCloud merge. The foreground-visible
        // VM already reloads via `.cloudSyncDidFetchChanges` at the end
        // of the batch (AIChatViewModel:666), but a cached background VM
        // for a non-active session would otherwise render its stale
        // messages snapshot the next time the user opens it. The flag
        // is consumed on the next getOrCreate HIT
        // (T-inbound-message-cached-vm-stale).
        // [T-ios-listsessions-perf] An inbound merge can land a message at any
        // sort_order (including behind what this device already has) and can
        // rewrite an existing row's parts, so recompute rather than fold
        // forward. Sync batches are far rarer than agent appends, so the extra
        // query is not on a hot path.
        recomputeStoredPreview(sessionId: sessionId)

        let sid = sessionId
        Task { @MainActor in
            ViewModelCache.shared.markStale(sessionId: sid)
        }
    }

    func deleteRemoteSession(id: String, deviceId: String) {
        // Parameterized deletes to avoid SQL injection
        for table in ["remote_messages", "remote_media"] {
            let sql = "DELETE FROM \(table) WHERE session_id = ? AND device_id = ?"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        let sql = "DELETE FROM remote_sessions WHERE id = ? AND device_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func listRemoteSessions(deviceId: String) -> [ChatSession] {
        iCloudLogger.info("[iCloud] listRemoteSessions: querying deviceId=\(deviceId)")
        let sql = """
            SELECT id, title, category, model_id, created_at, updated_at
            FROM remote_sessions WHERE device_id = ? ORDER BY updated_at DESC
        """
        var stmt: OpaquePointer?
        var sessions: [ChatSession] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                sessions.append(ChatSession(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    title: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                    category: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    modelId: String(cString: sqlite3_column_text(stmt, 3)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                ))
            }
        }
        sqlite3_finalize(stmt)
        iCloudLogger.info("[iCloud] listRemoteSessions: deviceId=\(deviceId) returned \(sessions.count) sessions")
        for s in sessions {
            iCloudLogger.info("[iCloud]   session: id=\(s.id) title=\(s.title ?? "nil")")
        }
        return sessions
    }

    // MARK: - Remote Message CRUD

    func upsertRemoteMessage(
        id: String, deviceId: String, sessionId: String, role: String,
        partsJson: String, createdAt: Date, tokenUsageJson: String?,
        sortOrder: Int, reasoningContent: String?, streamInterruptCount: Int
    ) {
        // Create placeholder session if it doesn't exist yet — messages may arrive
        // before the Session record on the receiving device.
        let placeholderSQL = """
            INSERT OR IGNORE INTO remote_sessions (id, device_id, title, category, model_id, created_at, updated_at)
            VALUES (?, ?, NULL, NULL, 'unknown', ?, ?)
        """
        var pStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, placeholderSQL, -1, &pStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(pStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(pStmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(pStmt, 3, createdAt.timeIntervalSince1970)
            sqlite3_bind_double(pStmt, 4, createdAt.timeIntervalSince1970)
            sqlite3_step(pStmt)
        }
        sqlite3_finalize(pStmt)

        let sql = """
            INSERT OR REPLACE INTO remote_messages
            (id, device_id, session_id, role, parts_json, created_at, token_usage, sort_order, reasoning_content, stream_interrupt_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (partsJson as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 6, createdAt.timeIntervalSince1970)
            bindOptionalText(stmt, index: 7, value: tokenUsageJson)
            sqlite3_bind_int64(stmt, 8, Int64(sortOrder))
            bindOptionalText(stmt, index: 9, value: reasoningContent)
            sqlite3_bind_int64(stmt, 10, Int64(streamInterruptCount))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Delete a single message from the local messages table by its message ID.
    /// Used when a remote device signals a message-level deletion (retry / manual delete)
    /// that should propagate across devices.
    func deleteLocalMessage(messageId: String) {
        // [T-ios-listsessions-perf] Resolve the session BEFORE the delete —
        // afterwards the row is gone and the lookup would fail — then
        // recompute, since the deleted message may have been the preview.
        let previewSession = sessionIdForMessage(messageId)
        // PER-SESSION: the session is in hand from that lookup, and deleting a
        // message never changes the row set. A nil lookup means there is no
        // local row, so the DELETE below is a no-op and nothing the sidebar
        // shows can change — invalidate nothing. That matters: an inbound
        // tombstone batch is mostly such no-ops (~6.4k per batch, see the log
        // note below), and a FULL rebuild per call would be the wholesale
        // invalidation this phase removed.
        if let sid = previewSession {
            // PER-SESSION: message delete on a known session.
            invalidateSessionListCache(sessionId: sid)
        }
        defer { previewSession.map { recomputeStoredPreview(sessionId: $0) } }
        let sql = "DELETE FROM messages WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (messageId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        let changes = Int(sqlite3_changes(db))
        sqlite3_finalize(stmt)
        if changes > 0 {
            iCloudLogger.warning("[EditSync] [iCloud] deleteLocalMessage: removed '\(messageId.prefix(8))' from local messages (inbound tombstone applied)")
        } else {
            // [T-ios-log-noise-reduction] Downgraded WARN→DEBUG: a delete for a
            // message that never landed locally (synced from another device that
            // both created and deleted it while we were away) is the normal
            // tombstone path, not a warning. Was ~6.4k WARN lines per batch sync.
            iCloudLogger.debug("[EditSync] [iCloud] deleteLocalMessage: NO-OP '\(messageId.prefix(8))' — message not present locally (already gone or never arrived)")
        }
    }

    func deleteRemoteMessage(id: String, deviceId: String) {
        let sql = "DELETE FROM remote_messages WHERE id = ? AND device_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func loadRemoteMessages(sessionId: String, deviceId: String) -> [RawMessage] {
        let sql = """
            SELECT id, session_id, role, parts_json, created_at, token_usage, reasoning_content, stream_interrupt_count
            FROM remote_messages WHERE session_id = ? AND device_id = ? ORDER BY sort_order ASC, created_at ASC, id ASC
        """
        var stmt: OpaquePointer?
        var messages: [RawMessage] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let sessionId = String(cString: sqlite3_column_text(stmt, 1))
                let roleStr = String(cString: sqlite3_column_text(stmt, 2))
                let partsJson = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let tokenUsageStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let reasoningContent = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let streamInterruptCount = Int(sqlite3_column_int(stmt, 7))

                let role = MessageRole(rawValue: roleStr) ?? .user
                let parts = (try? JSONDecoder().decode([ContentPart].self, from: Data(partsJson.utf8))) ?? []
                let tokenUsage = tokenUsageStr.flatMap { str in
                    try? JSONDecoder().decode(StoredTokenUsage.self, from: Data(str.utf8))
                }

                messages.append(RawMessage(
                    id: id, sessionId: sessionId, role: role, parts: parts,
                    createdAt: createdAt, tokenUsage: tokenUsage,
                    reasoningContent: reasoningContent,
                    streamInterruptCount: streamInterruptCount
                ))
            }
        }
        sqlite3_finalize(stmt)
        return messages
    }
}
