//
//  ChatStore+UsageStats.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, usage statistics: per-model token usage records and the most
//  used model.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

extension ChatStore {
    // MARK: - Usage Statistics

    /// A single usage record from a message with token usage data.
    struct UsageRecord {
        let modelId: String
        let sessionId: String
        let date: Date
        let usage: StoredTokenUsage
        /// [T-token-attribution-snapshot] Display name captured at write time.
        /// Non-nil only when `hasSnapshot` — and then it is the only reliable
        /// name for a model whose provider has since been deleted.
        let modelDisplayName: String?
        /// `ProviderType` rawValue captured at write time.
        let providerType: String?
        /// True when this row carries a per-message snapshot. False means the
        /// model was inferred from the session's CURRENT model and may be
        /// wrong; the UI must present it as an estimate.
        let hasSnapshot: Bool
    }

    /// Fetch all messages that have token usage, joined with their session's model_id.
    /// [T-ios-usage-orphan-rows GH#168] LEFT JOIN, not INNER JOIN.
    ///
    /// The Usage page is built entirely from this query, so any row it drops is
    /// silently missing from the user's reported totals. With an INNER JOIN, a
    /// message whose `sessions` row is gone — deleted, orphaned by a failed
    /// sync/migration, or never written — vanished from the totals even though
    /// its `token_usage` is still sitting in the table. The tokens were really
    /// billed by the provider, so the page under-reported with no way to tell.
    ///
    /// LEFT JOIN keeps those rows; `model_id` then comes back NULL, which
    /// `UsageStatsView` already handles (unknown ids fall back to the raw id
    /// for the display name and to the "Other" provider group).
    ///
    /// This does NOT recover usage from sessions the user deleted outright —
    /// `deleteSession` removes the message rows themselves (:2960). It only
    /// stops orphaned-but-present rows from being discarded.
    func fetchUsageStats() -> [UsageRecord] {
        // [T-token-attribution-snapshot] Prefer the per-message snapshot; fall
        // back to the session's model only for rows written before it existed.
        // `s.model_id` alone is what caused a session's whole history to be
        // re-attributed on every model switch — it is a mutable column and the
        // join has no time dimension. `has_snapshot` travels with the row so
        // the UI can label fallback rows as estimates instead of passing them
        // off as measurements.
        let sql = """
            SELECT COALESCE(m.model_id, s.model_id), m.token_usage, m.created_at, m.session_id,
                   m.model_display_name, m.provider_type, (m.model_id IS NOT NULL)
            FROM messages m LEFT JOIN sessions s ON m.session_id = s.id
            WHERE m.token_usage IS NOT NULL
        """
        var stmt: OpaquePointer?
        var records: [UsageRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                // `model_id` is NULL for an orphaned message (no sessions row).
                // sqlite3_column_text returns a NULL pointer there, and
                // String(cString:) on NULL is undefined behaviour — so the
                // LEFT JOIN above REQUIRES this guarded read, not the bare
                // String(cString:) the INNER JOIN could get away with.
                let modelId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                guard let usagePtr = sqlite3_column_text(stmt, 1) else { continue }
                let usageStr = String(cString: usagePtr)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let sessionId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let displayName = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let providerType = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let hasSnapshot = sqlite3_column_int(stmt, 6) != 0

                guard let usageData = usageStr.data(using: .utf8),
                      let usage = try? JSONDecoder().decode(StoredTokenUsage.self, from: usageData) else {
                    continue
                }

                records.append(UsageRecord(
                    modelId: modelId, sessionId: sessionId,
                    date: createdAt, usage: usage,
                    modelDisplayName: displayName, providerType: providerType,
                    hasSnapshot: hasSnapshot
                ))
            }
        }
        sqlite3_finalize(stmt)
        return records
    }

    /// Return the model_id most frequently used (by message count with token usage) since `date`.
    func fetchMostUsedModelId(since date: Date) -> String? {
        // [T-token-attribution-snapshot] Same fix as fetchUsageStats: group by
        // the per-message snapshot where present. Grouping purely on
        // `s.model_id` made "most used" follow whatever each session currently
        // points at rather than what actually ran.
        let sql = """
            SELECT COALESCE(m.model_id, s.model_id) AS mid, COUNT(*) as cnt
            FROM messages m JOIN sessions s ON m.session_id = s.id
            WHERE m.created_at >= ? AND m.token_usage IS NOT NULL
            GROUP BY mid
            ORDER BY cnt DESC
            LIMIT 1
        """
        var stmt: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let cStr = sqlite3_column_text(stmt, 0) {
                result = String(cString: cStr)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }
}
