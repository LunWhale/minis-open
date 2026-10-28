//
//  ChatStore+Tombstones.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, delete tombstones (resurrection guard): recording recent local
//  deletes so an inbound merge cannot re-insert them, resurrecting a
//  tombstoned session tree, and the parent / session-id lookups the sync dirty
//  marks use.
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
    // MARK: - Recent-delete tombstones (resurrection guard)
    // [T-icloud-deleted-session-resurrection]

    /// Record that `sessionId` was just deleted locally, so an inbound merge
    /// arriving before the cloud delete tombstone lands won't re-insert it.
    func recordDeletedSessionTombstone(_ sessionId: String, at: Date = Date()) {
        let sql = "INSERT OR REPLACE INTO deleted_session_tombstones (session_id, deleted_at) VALUES (?, ?)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, at.timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    /// The timestamp `sessionId` was locally deleted, or nil if it has no
    /// recent-delete tombstone. Inbound merges consult this to refuse
    /// resurrecting a session/message/file that isn't newer than the deletion.
    func deletedSessionTombstone(_ sessionId: String) -> Date? {
        let sql = "SELECT deleted_at FROM deleted_session_tombstones WHERE session_id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    /// True when `sessionId` has a recent-delete tombstone at least as new as
    /// `remoteUpdatedAt` — i.e. the inbound record is the just-deleted one
    /// coming back, not a genuine newer re-create. The merge should refuse it.
    /// A small slack absorbs server/client clock skew (the resurrected record's
    /// updatedAt is the pre-deletion value, so it is always <= deletedAt in
    /// practice; slack only guards against minor forward skew).
    func isResurrectionOfDeleted(_ sessionId: String, remoteUpdatedAt: Date) -> Bool {
        guard let deletedAt = deletedSessionTombstone(sessionId) else { return false }
        return remoteUpdatedAt.timeIntervalSince1970 <= deletedAt.timeIntervalSince1970 + 5
    }

    // [T-icloud-record-delete-resurrection] Generic per-record variant of the
    // session tombstones above, for types whose op=delete propagates but whose
    // inbound merge would re-insert a stale live record that fetchRecentV2
    // pulled back before the cloud delete landed (Skill / EnvVarItem /
    // CompactMarker). Written automatically by markDirty(op=delete).

    /// Record that record `id` of `type` was just deleted locally.
    func recordDeletedRecordTombstone(type: String, id: String, at: Date = Date()) {
        let sql = "INSERT OR REPLACE INTO deleted_record_tombstones (record_type, record_id, deleted_at) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (type as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, at.timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    /// The timestamp record `id` of `type` was locally deleted, or nil.
    private func deletedRecordTombstone(type: String, id: String) -> Date? {
        let sql = "SELECT deleted_at FROM deleted_record_tombstones WHERE record_type = ? AND record_id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (type as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    /// True when the inbound record is the just-deleted one coming back (its
    /// remote timestamp is not newer than the local deletion, +5s skew slack)
    /// rather than a genuine newer re-create. The merge should refuse it.
    func isRecentlyDeletedRecord(type: String, id: String, remoteUpdatedAt: Date) -> Bool {
        guard let deletedAt = deletedRecordTombstone(type: type, id: id) else { return false }
        return remoteUpdatedAt.timeIntervalSince1970 <= deletedAt.timeIntervalSince1970 + 5
    }

    /// Set or clear the v2 soft-delete tombstone on a session row. Pass
    /// `at = nil` to clear (after a resurrect cascade re-pushes the tree).
    func setSessionTombstone(sessionId: String, at: Date?) {
        // PER-SESSION: the tombstone column is not consulted by the list query
        // (see the note in listSessions), so this only marks the row dirty.
        invalidateSessionListCache(sessionId: sessionId)
        let sql = "UPDATE sessions SET remote_tombstoned_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        if let date = at {
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
        _ = sqlite3_step(stmt)
    }

    /// Returns the tombstone timestamp (or nil if not tombstoned / row
    /// missing).
    func sessionTombstone(sessionId: String) -> Date? {
        let sql = "SELECT remote_tombstoned_at FROM sessions WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    /// All currently-tombstoned session ids — diagnostic.
    func tombstonedSessionIds() -> [String] {
        let sql = "SELECT id FROM sessions WHERE remote_tombstoned_at IS NOT NULL"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ids }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: cstr))
            }
        }
        return ids
    }

    /// Cascade-mark every record in a session's tree dirty (Session +
    /// Messages + CompactMarkers) for v2 push, and clear the tombstone.
    /// Called by `markDirty` whenever a tombstoned session takes a new
    /// upsert. Doesn't hop actors — pure SQL inside the ChatStore actor.
    /// Returns true if a cascade actually ran.
    @discardableResult
    func resurrectSessionTreeIfTombstoned(sessionId: String) -> Bool {
        guard sessionTombstone(sessionId: sessionId) != nil else { return false }
        // 1. Session itself.
        markDirtyRowOnly(recordType: "SessionV2", recordId: sessionId)
        // 2. Every message id in the session.
        let msgSql = "SELECT id FROM messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        var msgCount = 0
        if sqlite3_prepare_v2(db, msgSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    let mid = String(cString: cstr)
                    markDirtyRowOnly(recordType: "MessageV2", recordId: mid)
                    msgCount += 1
                }
            }
        }
        sqlite3_finalize(stmt)
        // 3. Every compact marker.
        let markers = compactMarkers(sessionId: sessionId)
        for m in markers {
            markDirtyRowOnly(recordType: "CompactMarkerV2", recordId: m.id)
        }
        // 4. Every SessionFile under this session — scan the workspace
        //    directory and mark each file's v2 dirty row. Mirrors v1's
        //    scanAndMarkSessionFiles(sessionId:).
        let fileCount = scanAndMarkSessionFilesForResurrect(sessionId: sessionId)
        // 5. Clear tombstone.
        setSessionTombstone(sessionId: sessionId, at: nil)
        iCloudLogger.info("[SyncConflict] resurrect cascade auto: sessionId=\(sessionId.prefix(8)) Session=1 Messages=\(msgCount) CompactMarkers=\(markers.count) SessionFiles=\(fileCount)")
        return true
    }

    /// Resurrect-time SessionFile scanner. Walks the session's workspace
    /// directory and writes a v2 dirty row for each file (composite key
    /// = "sessionId:relativePath"). Returns the count.
    private func scanAndMarkSessionFilesForResurrect(sessionId: String) -> Int {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let sessionDir = library.appendingPathComponent("MinisChat/minis/\(sessionId)")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile, isFile else { continue }
            let relativePath = url.path.replacingOccurrences(of: sessionDir.path + "/", with: "")
            let recordId = "\(sessionId):\(relativePath)"
            markDirtyRowOnly(recordType: "SessionFileV2", recordId: recordId)
            count += 1
        }
        return count
    }

    /// Internal helper: write a v2 dirty row directly without scheduling
    /// a send (the caller's outer markDirty already triggered it).
    private func markDirtyRowOnly(recordType: String, recordId: String) {
        guard !syncZoneName.isEmpty else { return }
        let zoneName = syncZoneName
        let sql = """
            INSERT OR REPLACE INTO sync_dirty_records (record_type, record_id, zone_name, operation)
            VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (recordType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (recordId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (zoneName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, ("upsert" as NSString).utf8String, -1, nil)
        _ = sqlite3_step(stmt)
    }

    /// Resolve the parent sessionId for a v1/v2 record being marked dirty,
    /// when it falls under a session-scoped record type. Used by markDirty
    /// to detect "this write belongs to a tombstoned session → cascade".
    /// Returns nil for global / non-session-scoped types.
    private func parentSessionId(forV1 recordType: String, recordId: String) -> String? {
        switch recordType {
        case "Session":
            return recordId
        case "Message":
            return messageSessionId(id: recordId)
        case "CompactMarker":
            return compactMarkerSessionId(id: recordId)
        case "SessionFile":
            // SessionFile recordId is "sessionId:relativePath".
            let parts = recordId.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return String(parts[0])
        default:
            return nil
        }
    }

    /// SessionId of the parent for a CompactMarker id. Light wrapper —
    /// keeps the SQL away from callers.
    private func compactMarkerSessionId(id: String) -> String? {
        let sql = "SELECT session_id FROM compact_markers WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cstr)
    }

    /// Returns every locally-stored session id (for §3.6.0 scenario E
    /// fullFetch reconciliation).
    func allSessionIds() -> [String] {
        let sql = "SELECT id FROM sessions"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ids }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: cstr))
            }
        }
        return ids
    }
}
