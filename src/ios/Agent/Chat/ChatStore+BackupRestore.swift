//
//  ChatStore+BackupRestore.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, backup restore writes (docs/backup-restore-design.md section
//  8): restoring sessions, messages and compaction markers, and clearing
//  restore tombstones.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

// MARK: - Backup Restore (docs/backup-restore-design.md §8)

/// Restore-side writes for the backup importer (docs/backup-restore-design.md §8.3).
///
/// These deliberately do NOT reuse `mergeRemoteSession` / `mergeRemoteMessage`.
/// Those are the CloudKit inbound path and carry three behaviours that are
/// correct for sync and wrong for a restore:
///
///  1. **`remote_origin_device_id`** — the sync insert stamps the originating
///     device, which makes the row render with a ☁️ remote badge and become
///     eligible for `deleteLocalSessionIfFromDevice`. Restored data is THIS
///     device's data; it must be indistinguishable from locally-authored rows,
///     so this column stays NULL. (The parameter is a non-optional `String`, so
///     the sync path physically cannot write NULL — passing "" would read back
///     as non-nil and still show the badge.)
///  2. **Tombstone resurrection guards** — `isResurrectionOfDeleted` silently
///     drops a record whose id was recently deleted locally. That is right for
///     a late CloudKit echo and wrong for a user explicitly asking to restore a
///     backup: they would get a "success" report with rows missing. The
///     importer clears the tombstone first (see `clearRestoreTombstone`).
///  3. **`SessionActivityTracker` deferral** — a running agent loop makes the
///     sync path skip the session entirely. A restore must not silently skip;
///     the importer refuses to touch a running session up front and reports it
///     instead.
///
/// Everything here is "last-writer-wins by updated_at", matching §8.2's Merge
/// semantics, and none of it writes `sync_pushed_records` or tombstones (§8.3).
extension ChatStore {

    enum RestoreOutcome {
        case inserted
        case updated
        /// Local copy is newer — Merge mode keeps it (§8.2).
        case skippedLocalNewer
        /// Parent session missing, so the row would dangle.
        case skippedNoParent
    }

    // MARK: - Sessions

    /// Upsert a session as locally-authored data.
    ///
    /// LWW on `updated_at`, so re-running a restore is a no-op and a newer local
    /// edit survives.
    func restoreSession(_ session: ChatSession,
                        memoryEnabled: Bool,
                        modelBinding: String?) -> RestoreOutcome {
        // FULL: backup restore rewrites rows in bulk and can add sessions.
        invalidateSessionListCache()

        let incoming = session.updatedAt.timeIntervalSince1970
        var localUpdatedAt: Double?
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT updated_at FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (session.id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                localUpdatedAt = sqlite3_column_double(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)

        if let local = localUpdatedAt {
            guard incoming > local else { return .skippedLocalNewer }
            let sql = """
                UPDATE sessions SET title = ?, category = ?, model_id = ?, updated_at = ?,
                                    memory_enabled = ?, model_binding = ?, pinned_at = ?, folder_id = ?,
                                    parent_session_id = ?, parent_tool_use_id = ?
                WHERE id = ?
                """
            var up: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &up, nil) == SQLITE_OK {
                bindText(up, 1, session.title)
                bindText(up, 2, session.category)
                sqlite3_bind_text(up, 3, (session.modelId as NSString).utf8String, -1, nil)
                sqlite3_bind_double(up, 4, incoming)
                sqlite3_bind_int(up, 5, memoryEnabled ? 1 : 0)
                bindText(up, 6, modelBinding)
                if let p = session.pinnedAt { sqlite3_bind_double(up, 7, p.timeIntervalSince1970) }
                else { sqlite3_bind_null(up, 7) }
                bindText(up, 8, session.folderId)
                bindText(up, 9, session.parentSessionId)
                bindText(up, 10, session.parentToolUseId)
                sqlite3_bind_text(up, 11, (session.id as NSString).utf8String, -1, nil)
                sqlite3_step(up)
            }
            sqlite3_finalize(up)
            return .updated
        }

        // NOTE: remote_origin_device_id is intentionally omitted from the column
        // list so it defaults to NULL — see the type doc above.
        let sql = """
            INSERT INTO sessions (id, title, category, model_id, created_at, updated_at,
                                  memory_enabled, model_binding, pinned_at, folder_id,
                                  parent_session_id, parent_tool_use_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var ins: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &ins, nil) == SQLITE_OK {
            sqlite3_bind_text(ins, 1, (session.id as NSString).utf8String, -1, nil)
            bindText(ins, 2, session.title)
            bindText(ins, 3, session.category)
            sqlite3_bind_text(ins, 4, (session.modelId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(ins, 5, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(ins, 6, incoming)
            sqlite3_bind_int(ins, 7, memoryEnabled ? 1 : 0)
            bindText(ins, 8, modelBinding)
            if let p = session.pinnedAt { sqlite3_bind_double(ins, 9, p.timeIntervalSince1970) }
            else { sqlite3_bind_null(ins, 9) }
            bindText(ins, 10, session.folderId)
            bindText(ins, 11, session.parentSessionId)
            bindText(ins, 12, session.parentToolUseId)
            sqlite3_step(ins)
        }
        sqlite3_finalize(ins)
        return .inserted
    }

    // MARK: - Messages

    /// Upsert one message, preserving its id and its ORIGINAL `sort_order`.
    ///
    /// The append path (`appendMessages`) can't be used: it re-derives
    /// `sort_order` from the local tail and bumps the session's `updated_at` to
    /// now, which would both reorder a restored transcript and destroy the
    /// timestamps the session LWW depends on.
    func restoreMessage(id: String, sessionId: String, role: String, partsJson: String,
                        createdAt: Date, tokenUsageJson: String?, sortOrder: Int,
                        reasoningContent: String?, streamInterruptCount: Int,
                        updatedAt: Date,
                        // [T-token-attribution-snapshot] Carried through backup
                        // restore so a restored package keeps its attribution.
                        // nil for packages written before the fields existed.
                        modelId: String? = nil, modelDisplayName: String? = nil,
                        providerType: String? = nil, providerInstanceId: String? = nil) -> RestoreOutcome {
        var exists = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            exists = sqlite3_step(stmt) == SQLITE_ROW
        }
        sqlite3_finalize(stmt)
        guard exists else { return .skippedNoParent }

        var localUpdated: Double?
        var chk: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT updated_at FROM messages WHERE id = ?", -1, &chk, nil) == SQLITE_OK {
            sqlite3_bind_text(chk, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(chk) == SQLITE_ROW {
                localUpdated = sqlite3_column_double(chk, 0)
            }
        }
        sqlite3_finalize(chk)

        let incoming = updatedAt.timeIntervalSince1970
        if let local = localUpdated, incoming <= local { return .skippedLocalNewer }

        // part_flags is a derived column the list query uses for previews; it is
        // computed from parts_json by the same SQL expression the sync backfill
        // uses, so restored rows behave identically in listSessions.
        let sql = """
            INSERT OR REPLACE INTO messages
              (id, session_id, role, parts_json, created_at, token_usage, sort_order,
               reasoning_content, stream_interrupt_count, updated_at, part_flags,
               model_id, model_display_name, provider_type, provider_instance_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(Self.partFlagsSQLExpr("?4")), ?, ?, ?, ?)
            """
        var ins: OpaquePointer?
        var outcome: RestoreOutcome = localUpdated == nil ? .inserted : .updated
        if sqlite3_prepare_v2(db, sql, -1, &ins, nil) == SQLITE_OK {
            sqlite3_bind_text(ins, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(ins, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(ins, 3, (role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(ins, 4, (partsJson as NSString).utf8String, -1, nil)
            sqlite3_bind_double(ins, 5, createdAt.timeIntervalSince1970)
            bindText(ins, 6, tokenUsageJson)
            sqlite3_bind_int(ins, 7, Int32(sortOrder))
            bindText(ins, 8, reasoningContent)
            sqlite3_bind_int(ins, 9, Int32(streamInterruptCount))
            sqlite3_bind_double(ins, 10, incoming)
            bindText(ins, 11, modelId)
            bindText(ins, 12, modelDisplayName)
            bindText(ins, 13, providerType)
            bindText(ins, 14, providerInstanceId)
            if sqlite3_step(ins) != SQLITE_DONE {
                logger.warning("[Restore] message insert failed id=\(id.prefix(8)): \(String(cString: sqlite3_errmsg(db)))")
                outcome = .skippedNoParent
            }
        }
        sqlite3_finalize(ins)
        return outcome
    }

    // MARK: - Compact markers

    /// Markers are immutable, so presence alone decides — no LWW needed.
    ///
    /// Delegates the write to `insertCompactMarker` rather than re-deriving its
    /// column list: that table has eleven columns including four legacy
    /// migration fields, and a hand-written copy here would silently rot the
    /// next time one is added. Its internal `markDirty` is exactly what §8.3
    /// asks for, so it is left in place.
    func restoreCompactMarker(_ marker: CompactMarker) -> RestoreOutcome {
        var parentExists = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (marker.sessionId as NSString).utf8String, -1, nil)
            parentExists = sqlite3_step(stmt) == SQLITE_ROW
        }
        sqlite3_finalize(stmt)
        guard parentExists else { return .skippedNoParent }

        var exists = false
        var chk: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM compact_markers WHERE id = ?", -1, &chk, nil) == SQLITE_OK {
            sqlite3_bind_text(chk, 1, (marker.id as NSString).utf8String, -1, nil)
            exists = sqlite3_step(chk) == SQLITE_ROW
        }
        sqlite3_finalize(chk)
        if exists { return .skippedLocalNewer }

        insertCompactMarker(marker)
        return .inserted
    }

    // MARK: - Tombstones

    /// Clear any local delete tombstone for `sessionId` so a restore can put the
    /// session back.
    ///
    /// Without this the resurrection guards would silently drop exactly the rows
    /// a user is asking to recover — the "I deleted it, then restored an older
    /// backup to get it back" case, which is a primary reason to have backups at
    /// all. Restoring is an explicit user action, so it outranks the guard.
    func clearRestoreTombstone(sessionId: String) {
        // Both tables: the session tombstone blocks the session itself, and the
        // per-record table (keyed by record_type + record_id) blocks its
        // messages / compact markers. Matching on record_id alone clears every
        // type for this id, which is what a full-session restore needs.
        for sql in ["DELETE FROM deleted_session_tombstones WHERE session_id = ?",
                    "DELETE FROM deleted_record_tombstones WHERE record_id = ?"] {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// True when a session is mid agent-loop. The importer refuses to write into
    /// one rather than silently skipping it the way the sync path does.
    nonisolated func isSessionRunning(_ sessionId: String) -> Bool {
        SessionActivityTracker.isActiveThreadSafe(sessionId)
    }

    // MARK: - Helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

}
