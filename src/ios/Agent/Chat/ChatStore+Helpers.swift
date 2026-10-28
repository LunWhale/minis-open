//
//  ChatStore+Helpers.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, small helpers shared by the other ChatStore files: next sort
//  order, touching a session's updated_at, optional text binding, file
//  extension for a MIME type. Kept out of the actor body so calls to them stay
//  direct, as they were while they were private.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

extension ChatStore {
    // MARK: - Private Helpers

    func nextSortOrder(sessionId: String) -> Int {
        let sql = "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        var order = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                order = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return order
    }

    func touchSession(_ sessionId: String) {
        // PER-SESSION: bumps updated_at only. This is the single hottest
        // invalidation on the agent path (every message write touches its
        // session), and the reordering it causes is precisely what the patch's
        // re-sort handles.
        invalidateSessionListCache(sessionId: sessionId)
        let sql = "UPDATE sessions SET updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "text/html": return "html"
        case "application/json": return "json"
        default: return "bin"
        }
    }
}
