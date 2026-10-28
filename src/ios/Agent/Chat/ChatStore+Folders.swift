//
//  ChatStore+Folders.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, folders (groups): list / create / rename / pin / dissolve,
//  membership, last activity, and applying remote folder changes.
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
    // MARK: - Folders

    /// All folders, most recently updated first.
    func listFolders() -> [ChatFolder] {
        let sql = """
            SELECT id, name, icon, color, origin, sort_index, created_at, updated_at, pinned_at, description
            FROM folders ORDER BY updated_at DESC
            """
        var stmt: OpaquePointer?
        var folders: [ChatFolder] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Self.colText(stmt, 0)
                // Same guard as listSessions: a row with no primary key can't be
                // opened, moved into, or synced by id — skip rather than surface.
                guard !id.isEmpty else { continue }
                let pinnedAt: Date? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil
                folders.append(ChatFolder(
                    id: id,
                    name: Self.colText(stmt, 1),
                    icon: Self.colTextOpt(stmt, 2),
                    color: Self.colTextOpt(stmt, 3),
                    origin: Self.colTextOpt(stmt, 4) ?? "manual",
                    sortIndex: Int(sqlite3_column_int64(stmt, 5)),
                    pinnedAt: pinnedAt,
                    desc: Self.colTextOpt(stmt, 9),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return folders
    }

    /// Create a folder and return it. `id` is a fresh UUID. `desc` is the
    /// one-sentence auto-grouping context, capped at 100 characters.
    @discardableResult
    func createFolder(name: String, icon: String? = nil, color: String? = nil, origin: String = "manual", desc: String? = nil) -> ChatFolder {
        let cappedDesc = desc.flatMap { d -> String? in
            let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(100))
        }
        let folder = ChatFolder(name: name, icon: icon, color: color, origin: origin, desc: cappedDesc)
        let sql = """
            INSERT INTO folders (id, name, icon, color, origin, sort_index, description, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (folder.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (folder.name as NSString).utf8String, -1, nil)
            if let icon = folder.icon {
                sqlite3_bind_text(stmt, 3, (icon as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let color = folder.color {
                sqlite3_bind_text(stmt, 4, (color as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, (folder.origin as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 6, Int64(folder.sortIndex))
            bindOptionalText(stmt, index: 7, value: folder.desc)
            sqlite3_bind_double(stmt, 8, folder.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, folder.updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        markDirty(recordType: "Folder", recordId: folder.id)
        return folder
    }

    /// Rename a folder and (optionally) update its description. Field edits
    /// only — the UUID key is what keeps members untouched and lets the
    /// change merge as LWW fields rather than delete+create+migrate across
    /// devices. `desc: nil` leaves the stored description alone; an empty
    /// string clears it.
    func renameFolder(_ id: String, name: String, desc: String? = nil) {
        let cappedDesc = desc.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
        let sql = cappedDesc != nil
            ? "UPDATE folders SET name = ?, description = ?, updated_at = ? WHERE id = ?"
            : "UPDATE folders SET name = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            if let d = cappedDesc {
                if d.isEmpty {
                    sqlite3_bind_null(stmt, 2)
                } else {
                    sqlite3_bind_text(stmt, 2, (d as NSString).utf8String, -1, nil)
                }
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
            }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        markDirty(recordType: "Folder", recordId: id)
    }

    /// Toggle a folder's pin. Mirrors toggleSessionPin; also bumps
    /// updated_at so the change rides FolderV2's LWW cleanly.
    @discardableResult
    func toggleFolderPin(_ id: String) -> Bool {
        // FULL: folder ordering affects how the whole list is arranged.
        invalidateSessionListCache()
        var isPinned = false
        var checkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT pinned_at FROM folders WHERE id = ?", -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                isPinned = sqlite3_column_type(checkStmt, 0) != SQLITE_NULL
            }
        }
        sqlite3_finalize(checkStmt)

        let newPinned = !isPinned
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE folders SET pinned_at = ?, updated_at = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            if newPinned {
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        markDirty(recordType: "Folder", recordId: id)
        return newPinned
    }

    /// Dissolve a folder: delete the folder row and clear its members'
    /// `folder_id`. **No session is deleted.** Returns the ids of the sessions
    /// that were moved back to ungrouped.
    ///
    /// The same clearing runs when a peer's FolderV2 tombstone arrives, so
    /// "folder deleted" always means "members become ungrouped", never
    /// "members are deleted".
    @discardableResult
    func dissolveFolder(_ id: String) -> [String] {
        // FULL: re-homes every member session at once.
        invalidateSessionListCache()
        let memberIds = sessionIdsInFolder(id)

        var stmt: OpaquePointer?
        let clearSql = "UPDATE sessions SET folder_id = NULL WHERE folder_id = ?"
        if sqlite3_prepare_v2(db, clearSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        stmt = nil
        let deleteSql = "DELETE FROM folders WHERE id = ?"
        if sqlite3_prepare_v2(db, deleteSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Each freed session needs its own push — folder_id lives on SessionV2.
        for sid in memberIds {
            markDirty(recordType: "Session", recordId: sid)
        }
        markDirty(recordType: "Folder", recordId: id, operation: "delete")
        return memberIds
    }

    /// Session ids belonging to `folderId`, most recently updated first.
    func sessionIdsInFolder(_ folderId: String) -> [String] {
        let sql = "SELECT id FROM sessions WHERE folder_id = ? ORDER BY updated_at DESC"
        var stmt: OpaquePointer?
        var ids: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (folderId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Self.colText(stmt, 0)
                if !id.isEmpty { ids.append(id) }
            }
        }
        sqlite3_finalize(stmt)
        return ids
    }

    /// Move sessions into `folderId`, or out of any folder when it is nil.
    func setFolder(_ folderId: String?, forSessions sessionIds: [String]) {
        guard !sessionIds.isEmpty else { return }
        // FULL: a folder move changes grouping for a whole set of rows.
        invalidateSessionListCache()
        let sql = "UPDATE sessions SET folder_id = ? WHERE id = ?"
        for sid in sessionIds {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let folderId {
                    sqlite3_bind_text(stmt, 1, (folderId as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 1)
                }
                sqlite3_bind_text(stmt, 2, (sid as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            markDirty(recordType: "Session", recordId: sid)
        }
    }

    /// Set a session's folder only if it is currently ungrouped. Returns true
    /// if the write happened.
    ///
    /// This is the automatic-grouping write path: a user who has already filed
    /// a session by hand must never have that overridden by the sub-model's
    /// guess, and the check has to be part of the same statement rather than a
    /// read-then-write in the caller.
    @discardableResult
    func setFolderIfUnfiled(_ folderId: String, forSession sessionId: String) -> Bool {
        // FULL: folder membership feeds the sidebar's grouping, which is part
        // of how rows are arranged rather than a field of one row.
        invalidateSessionListCache()
        let sql = "UPDATE sessions SET folder_id = ? WHERE id = ? AND folder_id IS NULL"
        var changed = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (folderId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            changed = sqlite3_changes(db) > 0
        }
        sqlite3_finalize(stmt)
        if changed {
            markDirty(recordType: "Session", recordId: sessionId)
        }
        return changed
    }

    /// Resolve a folder *name* to a folder, for the sub-model paths that emit
    /// names rather than ids.
    ///
    /// Matching is trimmed and case-insensitive so a model answering "work"
    /// still finds "Work". Because duplicate names are allowed by design, this
    /// can match several folders; the most recently *active* one wins — active
    /// meaning the folder with the newest member session, NOT the newest
    /// `folders.updated_at` (which only tracks renames, so a long-abandoned
    /// folder renamed yesterday would otherwise beat one in daily use).
    func findFolderByName(_ name: String) -> ChatFolder? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let matches = listFolders().filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
        guard matches.count > 1 else { return matches.first }

        let activity = folderLastActivity()
        return matches.max { a, b in
            let aKey = activity[a.id]
            let bKey = activity[b.id]
            switch (aKey, bKey) {
            case let (x?, y?): return x < y
            // A folder with any member outranks an empty one.
            case (nil, _?): return true
            case (_?, nil): return false
            // Both empty — fall back to the older folder, which is more likely
            // to be the one the user thinks of as "the" folder by that name.
            case (nil, nil): return a.createdAt > b.createdAt
            }
        }
    }

    /// folderId → newest member `updated_at`. Folders with no members are absent.
    func folderLastActivity() -> [String: Date] {
        let sql = """
            SELECT folder_id, MAX(updated_at) FROM sessions
            WHERE folder_id IS NOT NULL GROUP BY folder_id
            """
        var stmt: OpaquePointer?
        var out: [String: Date] = [:]
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let fid = Self.colText(stmt, 0)
                guard !fid.isEmpty else { continue }
                out[fid] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Apply an inbound FolderV2 upsert: LWW by updatedAt against the local
    /// row; missing locally → insert. Local-only — never marks dirty (the
    /// cloud already holds this state; re-queueing would ping-pong).
    func applyRemoteFolder(_ f: ChatFolder) {
        var localUpdatedAt: Double?
        var checkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT updated_at FROM folders WHERE id = ?", -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, (f.id as NSString).utf8String, -1, nil)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                localUpdatedAt = sqlite3_column_double(checkStmt, 0)
            }
        }
        sqlite3_finalize(checkStmt)

        if let localTs = localUpdatedAt, localTs >= f.updatedAt.timeIntervalSince1970 {
            iCloudLogger.info("[iCloud] applyRemoteFolder SKIP (local newer/equal): id=\(f.id.prefix(8))")
            return
        }
        // FULL: a remote folder create/rename re-groups the sidebar.
        invalidateSessionListCache()
        let sql = """
            INSERT INTO folders (id, name, icon, color, origin, sort_index, pinned_at, description, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, icon = excluded.icon, color = excluded.color,
                origin = excluded.origin, sort_index = excluded.sort_index,
                pinned_at = excluded.pinned_at,
                description = excluded.description,
                updated_at = excluded.updated_at
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (f.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (f.name as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, index: 3, value: f.icon)
            bindOptionalText(stmt, index: 4, value: f.color)
            sqlite3_bind_text(stmt, 5, (f.origin as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 6, Int64(f.sortIndex))
            if let pinTs = f.pinnedAt {
                sqlite3_bind_double(stmt, 7, pinTs.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            bindOptionalText(stmt, index: 8, value: f.desc)
            sqlite3_bind_double(stmt, 9, f.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 10, f.updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        iCloudLogger.info("[iCloud] applyRemoteFolder APPLIED: id=\(f.id.prefix(8)) name=\(f.name)")
    }

    /// Apply an inbound FolderV2 tombstone: clear members' folder_id and drop
    /// the folder row. **Never deletes a session** — folder deletion means
    /// "members become ungrouped" on every device. Local-only (no markDirty):
    /// the deleting peer already pushed both its tombstone and its members'
    /// folder_id=NULL session updates; re-queueing here would delete-loop.
    func applyRemoteFolderDeletion(id: String) {
        // FULL: unfiles every session that was in the deleted folder.
        invalidateSessionListCache()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE sessions SET folder_id = NULL WHERE folder_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        stmt = nil
        if sqlite3_prepare_v2(db, "DELETE FROM folders WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Match dissolveFolder's local behavior: leave a tombstone so a
        // fetchRecentV2 race can't resurrect the folder record we just dropped.
        recordDeletedRecordTombstone(type: "Folder", id: id)
        iCloudLogger.info("[iCloud] applyRemoteFolderDeletion: id=\(id.prefix(8))")
    }

    /// Fetch one folder (sync builder path).
    func getFolder(_ id: String) -> ChatFolder? {
        listFolders().first(where: { $0.id == id })
    }
}
