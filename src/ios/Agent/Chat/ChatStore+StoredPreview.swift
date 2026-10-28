//
//  ChatStore+StoredPreview.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, the persisted session preview: updating / recomputing the
//  stored list preview when messages change, so listSessions need not decode
//  messages.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

extension ChatStore {
    // MARK: - Persisted session preview [T-ios-listsessions-perf]

    /// Apply a freshly-written message to its session's stored preview.
    ///
    /// The rule reproduces exactly what listSessions used to derive by
    /// re-reading both candidate rows on every refresh: the latest ASSISTANT
    /// message with text or a tool_use wins, UNLESS the latest USER text
    /// message is strictly newer by sort_order (the user has just sent
    /// something the assistant has not answered yet). Ties go to the
    /// assistant, matching the old `uo > ao` comparison.
    ///
    /// Applied incrementally, that becomes: overwrite the stored preview when
    /// this message's sort_order is >= the stored one (it is at least as
    /// recent), and additionally require that a user message not displace an
    /// assistant message at the SAME sort_order. Because sort_order increases
    /// monotonically per session, a message arriving now always has the
    /// highest sort_order in its session, so the common path is a plain
    /// overwrite — the comparison only matters for out-of-order arrivals from
    /// an iCloud merge.
    ///
    /// Messages carrying no displayable part (a tool_result, an empty
    /// assistant row) leave the stored preview alone: they are exactly the
    /// rows the old SQL's part_flags filter excluded.
    func updateStoredPreview(
        sessionId: String, parts: [ContentPart], partsJSON: String,
        role: MessageRole, sortOrder: Int
    ) {
        let flags = Self.partFlags(for: parts)
        // Assistant rows qualify on text OR tool_use; user rows on text only.
        let qualifies = role == .assistant
            ? (flags & (Self.partFlagHasText | Self.partFlagHasToolUse)) != 0
            : (flags & Self.partFlagHasText) != 0
        guard qualifies else { return }

        // `partsJSON` is the string the caller just bound into the INSERT —
        // reuse it rather than encoding `parts` a second time per message.
        guard let preview = extractTextFromPartsJSON(partsJSON) else { return }

        // `>=` for an assistant row (it wins ties), `>` for a user row (it must
        // be strictly newer to displace the assistant).
        // A stored position above every row of the session is stale (an older
        // repair renumbered the rows below it) and loses to any new message.
        let comparison = role == .assistant ? ">=" : ">"
        let sql = SessionOrderRules.storedPreviewUpdateSQL(comparison: comparison)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (preview as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, Int64(sortOrder))
            sqlite3_bind_text(stmt, 3, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 4, Int64(sortOrder))
            sqlite3_bind_text(stmt, 5, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Recompute one session's preview from its messages the way listSessions
    /// always has, and store it. Used for the NULL fallback (rows written
    /// before the column existed) and after a delete, where the winning
    /// message may have been the one removed and the preview must move
    /// BACKWARDS — something the incremental rule deliberately cannot do.
    func recomputeStoredPreview(sessionId: String) {
        let asstMask = Self.partFlagHasText | Self.partFlagHasToolUse
        let userMask = Self.partFlagHasText
        let sql = """
            SELECT
              (SELECT m.parts_json FROM messages m
                WHERE m.session_id = ? AND m.role = 'assistant'
                  AND (m.part_flags & \(asstMask)) != 0
                ORDER BY m.sort_order DESC LIMIT 1),
              (SELECT m.parts_json FROM messages m
                WHERE m.session_id = ? AND m.role = 'user'
                  AND (m.part_flags & \(userMask)) != 0
                ORDER BY m.sort_order DESC LIMIT 1),
              (SELECT m.sort_order FROM messages m
                WHERE m.session_id = ? AND m.role = 'assistant'
                  AND (m.part_flags & \(asstMask)) != 0
                ORDER BY m.sort_order DESC LIMIT 1),
              (SELECT m.sort_order FROM messages m
                WHERE m.session_id = ? AND m.role = 'user'
                  AND (m.part_flags & \(userMask)) != 0
                ORDER BY m.sort_order DESC LIMIT 1)
            """
        var stmt: OpaquePointer?
        var preview: String?
        var order: Int?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for i in 1...4 {
                sqlite3_bind_text(stmt, Int32(i), (sessionId as NSString).utf8String, -1, nil)
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let asstRaw = Self.colTextOpt(stmt, 0)
                let userRaw = Self.colTextOpt(stmt, 1)
                let asstOrder: Int? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                    ? Int(sqlite3_column_int64(stmt, 2)) : nil
                let userOrder: Int? = sqlite3_column_type(stmt, 3) != SQLITE_NULL
                    ? Int(sqlite3_column_int64(stmt, 3)) : nil
                let asstText = asstRaw.flatMap { extractTextFromPartsJSON($0) }
                let userText = userRaw.flatMap { extractTextFromPartsJSON($0) }
                switch (asstText, userText) {
                case let (a?, u?):
                    if let ao = asstOrder, let uo = userOrder, uo > ao {
                        preview = u; order = uo
                    } else {
                        preview = a; order = asstOrder
                    }
                case let (a?, nil): preview = a; order = asstOrder
                case let (nil, u?): preview = u; order = userOrder
                default: break
                }
            }
        }
        sqlite3_finalize(stmt)
        // Empty-string sentinel rather than NULL when nothing is displayable —
        // NULL means "never computed" and would re-trigger the slow backfill
        // path on every refresh. See the backfill write in listSessions.
        storePreview(sessionId: sessionId, text: preview ?? "", sortOrder: order)
    }

    /// The session a message belongs to, or nil if the row is gone.
    func sessionIdForMessage(_ messageId: String) -> String? {
        let sql = "SELECT session_id FROM messages WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (messageId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let sid = Self.colText(stmt, 0)
        return sid.isEmpty ? nil : sid
    }

    /// Unconditional write of the preview pair (used by the recompute paths,
    /// which have already decided the winner).
    func storePreview(sessionId: String, text: String?, sortOrder: Int?) {
        let sql = "UPDATE sessions SET preview_text = ?, preview_sort_order = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindOptionalText(stmt, index: 1, value: text)
            if let sortOrder { sqlite3_bind_int64(stmt, 2, Int64(sortOrder)) }
            else { sqlite3_bind_null(stmt, 2) }
            sqlite3_bind_text(stmt, 3, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
}
