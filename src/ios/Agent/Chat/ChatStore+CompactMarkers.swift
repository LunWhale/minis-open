//
//  ChatStore+CompactMarkers.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, compaction markers: insert / update / read / merge, session
//  extras, the latest and previous marker, list and delete.
//
//  The doc comment of compactMarkers(sessionId:) had drifted above the
//  tombstone section in the single-file version; it sits on its function
//  again here.
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
    // MARK: - Compact Markers

    /// Insert a compact marker after a successful compaction.
    func insertCompactMarker(_ marker: CompactMarker) {
        let sql = """
            INSERT INTO compact_markers (id, session_id, summary, first_kept_sort_order, compacted_count, created_at, ui_boundary_sort_order, boundary_message_id, first_kept_message_id, last_compacted_message_id, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (marker.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (marker.sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (marker.summary as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 4, Int64(marker.firstKeptSortOrder))
            sqlite3_bind_int64(stmt, 5, Int64(marker.compactedCount))
            sqlite3_bind_double(stmt, 6, marker.createdAt.timeIntervalSince1970)
            if let uiBoundary = marker.uiBoundarySortOrder {
                sqlite3_bind_int64(stmt, 7, Int64(uiBoundary))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let bmId = marker.boundaryMessageId {
                sqlite3_bind_text(stmt, 8, (bmId as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let fkmId = marker.firstKeptMessageId {
                sqlite3_bind_text(stmt, 9, (fkmId as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            if let lcmId = marker.lastCompactedMessageId {
                sqlite3_bind_text(stmt, 10, (lcmId as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_int64(stmt, 11, Int64(marker.version))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        markDirty(recordType: "CompactMarker", recordId: marker.id)
    }

    /// Rewrite an existing compact marker in place (same id). Used by Phase 2.5
    /// self-heal when the original `lastCompactedMessageId` no longer resolves
    /// in the current rawMessages — we recompute the anchor by createdAt,
    /// upgrade the marker to v2, and persist so subsequent loads / agent sends
    /// find the corrected id directly.
    ///
    /// Implementation mirrors `mergeRemoteCompactMarker`: DELETE + INSERT in
    /// the same code path so all columns (including legacy migrations) flow
    /// through one INSERT.
    func updateCompactMarker(_ marker: CompactMarker) {
        let delSql = "DELETE FROM compact_markers WHERE id = ?"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, (marker.id as NSString).utf8String, -1, nil)
            sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)
        insertCompactMarker(marker)
    }

    /// Get a compact marker by ID (for iCloud sync buildCKRecord).
    func getCompactMarker(id: String) -> CompactMarker? {
        let sql = "SELECT id, session_id, summary, first_kept_sort_order, compacted_count, created_at, ui_boundary_sort_order, boundary_message_id, first_kept_message_id, last_compacted_message_id, version FROM compact_markers WHERE id = ?"
        var stmt: OpaquePointer?
        var marker: CompactMarker?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                marker = readCompactMarker(from: stmt)
            }
        }
        sqlite3_finalize(stmt)
        return marker
    }

    /// Merge a remote compact marker into local DB.
    /// Phase A: createdAt-based UPSERT — remote newer wins, otherwise keep local.
    /// This lets newer builds propagate upgraded boundary fields to older remote markers.
    func mergeRemoteCompactMarker(_ marker: CompactMarker) {
        // [T-icloud-record-delete-resurrection] A marker we just deleted
        // locally (revertCompact) coming back via fetchRecentV2 before the
        // cloud delete lands must not be re-inserted. Markers are immutable,
        // so createdAt is their only clock.
        if isRecentlyDeletedRecord(type: "CompactMarker", id: marker.id, remoteUpdatedAt: marker.createdAt) {
            iCloudLogger.info("[iCloud] mergeRemoteCompactMarker SKIP (recently deleted locally): id=\(marker.id.prefix(8))")
            return
        }
        // Only merge if the session exists locally
        let checkSql = "SELECT id FROM sessions WHERE id = ?"
        var checkStmt: OpaquePointer?
        var sessionExists = false
        if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, (marker.sessionId as NSString).utf8String, -1, nil)
            sessionExists = sqlite3_step(checkStmt) == SQLITE_ROW
        }
        sqlite3_finalize(checkStmt)
        guard sessionExists else { return }

        // If local already has this marker id, only overwrite when remote is strictly newer.
        if let existing = getCompactMarker(id: marker.id) {
            guard marker.createdAt > existing.createdAt else {
                iCloudLogger.info("[iCloud] mergeRemoteCompactMarker SKIP (local newer or equal): id=\(marker.id.prefix(8))")
                return
            }
            // DELETE existing row so the subsequent insertCompactMarker can re-insert
            // with all columns (including legacy migrations) in one place.
            let delSql = "DELETE FROM compact_markers WHERE id = ?"
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, (marker.id as NSString).utf8String, -1, nil)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)
            iCloudLogger.info("[iCloud] mergeRemoteCompactMarker UPDATE (remote newer): id=\(marker.id.prefix(8))")
        }

        insertCompactMarker(marker)
    }

    /// Extra session fields for iCloud sync (memory_enabled, model_binding).
    func getSessionExtras(_ sessionId: String) -> (memoryEnabled: Bool, modelBinding: String?) {
        let sql = "SELECT memory_enabled, model_binding FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        var memoryEnabled = true
        var modelBinding: String?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                memoryEnabled = sqlite3_column_int(stmt, 0) != 0
                modelBinding = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            }
        }
        sqlite3_finalize(stmt)
        return (memoryEnabled, modelBinding)
    }

    /// Return the most recent compact marker for a session, or nil if none.
    func latestCompactMarker(sessionId: String) -> CompactMarker? {
        let sql = """
            SELECT id, session_id, summary, first_kept_sort_order, compacted_count, created_at, ui_boundary_sort_order, boundary_message_id, first_kept_message_id, last_compacted_message_id, version
            FROM compact_markers WHERE session_id = ? ORDER BY created_at DESC LIMIT 1
        """
        var stmt: OpaquePointer?
        var marker: CompactMarker?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                marker = readCompactMarker(from: stmt)
            }
        }
        sqlite3_finalize(stmt)
        return marker
    }

    /// Bump `updated_at = now()` on a single message. Used by debug RPCs to
    /// force a content-change so a re-pushed Message record actually advances
    /// CloudKit's modificationDate (saving an unchanged etag is a no-op on
    /// the cloud side and peer devices won't see it as a "new change").
    /// Returns true if the row existed and was bumped.
    @discardableResult
    func bumpMessageUpdatedAt(id: String) -> Bool {
        let sql = "UPDATE messages SET updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    /// [T-error-persist-ios] Persist (or clear) the device-local error string on a
    /// single message. Lightweight UPDATE so the agent loop can write the error the
    /// instant it's set on the in-memory ChatMessage, without re-serializing the whole
    /// message. Pass nil to clear (e.g. a successful retry). Returns true if a row was
    /// updated. NOT marked dirty for iCloud — error_info is device-local.
    @discardableResult
    func updateMessageErrorInfo(messageId: String, errorInfo: String?) -> Bool {
        let sql = "UPDATE messages SET error_info = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        // Normalize empty/whitespace → NULL so a stray "" never persists (the UI
        // gates the error banner on `error != nil`, not emptiness, so an empty
        // string would render a blank banner). [T-error-persist-ios]
        let normalized = errorInfo?.trimmingCharacters(in: .whitespacesAndNewlines)
        bindOptionalText(stmt, index: 1, value: (normalized?.isEmpty == false) ? normalized : nil)
        sqlite3_bind_text(stmt, 2, (messageId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    /// Look up the parent sessionId for a message id, or nil if not found.
    /// Read-only — used by debug RPCs that re-mark individual messages dirty.
    func messageSessionId(id: String) -> String? {
        let sql = "SELECT session_id FROM messages WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cstr)
    }

    /// Return all compact markers for a session, ordered by created_at ascending.
    /// Read-only — used by debug RPCs to inspect sync state.
    func compactMarkers(sessionId: String) -> [CompactMarker] {
        let sql = """
            SELECT id, session_id, summary, first_kept_sort_order, compacted_count, created_at, ui_boundary_sort_order, boundary_message_id, first_kept_message_id, last_compacted_message_id, version
            FROM compact_markers WHERE session_id = ? ORDER BY created_at ASC
        """
        var stmt: OpaquePointer?
        var markers: [CompactMarker] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                markers.append(readCompactMarker(from: stmt))
            }
        }
        sqlite3_finalize(stmt)
        return markers
    }

    /// Return the second-most-recent compact marker (the one before the latest).
    func previousCompactMarker(sessionId: String) -> CompactMarker? {
        let sql = """
            SELECT id, session_id, summary, first_kept_sort_order, compacted_count, created_at, ui_boundary_sort_order, boundary_message_id, first_kept_message_id, last_compacted_message_id, version
            FROM compact_markers WHERE session_id = ? ORDER BY created_at DESC LIMIT 1 OFFSET 1
        """
        var stmt: OpaquePointer?
        var marker: CompactMarker?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                marker = readCompactMarker(from: stmt)
            }
        }
        sqlite3_finalize(stmt)
        return marker
    }

    /// Delete a single compact marker by id (for revert-compact). Marks dirty
    /// for iCloud sync so the deletion propagates. Returns true if a row was
    /// actually deleted.
    @discardableResult
    func deleteCompactMarker(id: String) -> Bool {
        markDirty(recordType: "CompactMarker", recordId: id, operation: "delete")
        return deleteLocalCompactMarker(id: id)
    }

    /// Local-only marker deletion — does NOT enqueue a cloud tombstone. Used
    /// by the sync hydrator when a remote device's revert tombstone arrives;
    /// re-marking it dirty here would bounce the deletion back to the cloud.
    @discardableResult
    func deleteLocalCompactMarker(id: String) -> Bool {
        let sql = "DELETE FROM compact_markers WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        let removed = sqlite3_changes(db) > 0
        if removed {
            iCloudLogger.info("[iCloud] deleteLocalCompactMarker: removed '\(id.prefix(8))' from local compact_markers")
        }
        return removed
    }

    /// Delete all compact markers for a session.
    func deleteCompactMarkers(sessionId: String) {
        // Mark every marker dirty for cloud deletion BEFORE the DELETE so iCloud
        // doesn't repopulate them. Mirrors the messages-side fix in
        // deleteMessages — required for Clear Chat to actually clear.
        let selSql = "SELECT id FROM compact_markers WHERE session_id = ?"
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selSql, -1, &selStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(selStmt) == SQLITE_ROW {
                let cmId = String(cString: sqlite3_column_text(selStmt, 0))
                markDirty(recordType: "CompactMarker", recordId: cmId, operation: "delete")
            }
        }
        sqlite3_finalize(selStmt)

        let sql = "DELETE FROM compact_markers WHERE session_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
}
