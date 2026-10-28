//
//  ChatStore+Maintenance.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, housekeeping: pruning old messages and compaction markers, and
//  session repair (detect and fix inconsistent sessions).
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

extension ChatStore {
    /// Maximum messages per session. Oldest messages beyond this limit are
    /// deleted after each appendMessages call.
    private static let pruneThreshold = 2048

    /// Delete the oldest messages when a session exceeds `pruneThreshold`.
    ///
    /// Safety rules:
    /// - Only runs when message count strictly exceeds the threshold.
    /// - Uses `DELETE ... WHERE id IN (SELECT id ... LIMIT N)` to delete an
    ///   exact number of rows, immune to duplicate sort_order values.
    /// - Never deletes more than `totalCount - pruneThreshold` rows.
    /// - Verifies the count-to-delete is positive and less than totalCount
    ///   (always keeps at least `pruneThreshold` messages).
    /// - Also cleans up stale compact markers.
    func pruneOldMessages(sessionId: String) {
        // 1. Count total messages
        var countStmt: OpaquePointer?
        let countSql = "SELECT COUNT(*) FROM messages WHERE session_id = ?"
        guard sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(countStmt, 1, (sessionId as NSString).utf8String, -1, nil)
        guard sqlite3_step(countStmt) == SQLITE_ROW else {
            sqlite3_finalize(countStmt)
            return
        }
        let totalCount = Int(sqlite3_column_int64(countStmt, 0))
        sqlite3_finalize(countStmt)

        // Phase A: DO NOT call deleteOldCompactMarkers here. Compact markers are
        // append-only archive and must survive appendMessages. Old markers are only
        // removed when the session itself is deleted (deleteSession path).

        guard totalCount > Self.pruneThreshold else { return }

        let deleteCount = totalCount - Self.pruneThreshold

        // 2. Safety: deleteCount must be positive and must keep at least pruneThreshold rows
        guard deleteCount > 0 && deleteCount < totalCount else {
            logger.warning("[Prune] Unexpected deleteCount=\(deleteCount) total=\(totalCount) — skipping")
            return
        }

        // 3. Delete exactly deleteCount oldest rows by id (immune to sort_order duplicates)
        let delSql = """
            DELETE FROM messages WHERE id IN (
                SELECT id FROM messages WHERE session_id = ?
                ORDER BY sort_order ASC, created_at ASC, id ASC
                LIMIT ?
            )
        """
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(delStmt, 2, Int64(deleteCount))
            sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)

        let deleted = Int(sqlite3_changes(db))
        logger.info("[Prune] session \(sessionId.prefix(8)): deleted \(deleted) oldest messages (was \(totalCount), threshold \(Self.pruneThreshold))")
    }

    /// Delete all compact markers except the latest one.
    private func deleteOldCompactMarkers(sessionId: String) {
        let sql = """
            DELETE FROM compact_markers WHERE session_id = ? AND id != (
                SELECT id FROM compact_markers WHERE session_id = ? ORDER BY created_at DESC LIMIT 1
            )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Session Repair (Phase A)

    /// Return value for session repair operations.
    struct RepairReport {
        var sortOrderFixed: Int = 0
        var markersUpgraded: Int = 0
        var hadAnomaly: Bool { sortOrderFixed > 0 || markersUpgraded > 0 }
    }

    /// Cheap anomaly check: returns true if the session has duplicate sort_orders
    /// OR any compact marker lacks `first_kept_message_id`. Used to skip expensive
    /// repair when the session is already healthy.
    private func sessionNeedsRepair(sessionId: String) -> Bool {
        // 1. sortOrder duplicates
        let dupSql = "SELECT COUNT(*), COUNT(DISTINCT sort_order) FROM messages WHERE session_id = ?"
        var dupStmt: OpaquePointer?
        var hasDup = false
        if sqlite3_prepare_v2(db, dupSql, -1, &dupStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(dupStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(dupStmt) == SQLITE_ROW {
                let total = sqlite3_column_int64(dupStmt, 0)
                let unique = sqlite3_column_int64(dupStmt, 1)
                if total != unique { hasDup = true }
            }
        }
        sqlite3_finalize(dupStmt)
        if hasDup { return true }

        // 2. any marker without first_kept_message_id AND without last_compacted_message_id.
        // compactAll markers intentionally have first_kept_message_id = NULL (and a non-null
        // last_compacted_message_id) — they must NOT be treated as legacy/needing repair, or
        // step 3 below would overwrite them with a bogus message id from past-the-end sortOrder.
        let markerSql = "SELECT 1 FROM compact_markers WHERE session_id = ? AND first_kept_message_id IS NULL AND last_compacted_message_id IS NULL LIMIT 1"
        var mStmt: OpaquePointer?
        var hasLegacyMarker = false
        if sqlite3_prepare_v2(db, markerSql, -1, &mStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(mStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            hasLegacyMarker = sqlite3_step(mStmt) == SQLITE_ROW
        }
        sqlite3_finalize(mStmt)
        if hasLegacyMarker { return true }

        // 3. rank inversion: sort_order disagrees with the canonical (created_at, id)
        // order. Catches the case where a remote merge inserted with a hint integer
        // that didn't match local rank (legacy data from pre-fix builds), or any
        // other pathway that left out-of-order rows. Gaps are NOT an anomaly — see
        // SessionOrderRules.inversionProbeSQL for why.
        var invStmt: OpaquePointer?
        var hasInversion = false
        if sqlite3_prepare_v2(db, SessionOrderRules.inversionProbeSQL, -1, &invStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(invStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            hasInversion = sqlite3_step(invStmt) == SQLITE_ROW
        }
        sqlite3_finalize(invStmt)
        return hasInversion
    }

    /// Perform a session repair: rewrite sort_orders to a stable dense sequence and
    /// upgrade legacy compact markers (nil first_kept_message_id) by looking up the
    /// corresponding row via legacy firstKeptSortOrder.
    ///
    /// The dense sequence ends at the session's current maximum sort_order (or
    /// n-1 if that is larger), never below it: see
    /// SessionOrderRules.repairBaseSortOrder for why it must not move down.
    ///
    /// Safe to call unconditionally — no-op if session is already healthy.
    /// Wraps everything in a single transaction.
    @discardableResult
    func repairSession(sessionId: String) -> RepairReport {
        // PER-SESSION: rewrites one session's message rows in place; the row
        // set is unchanged.
        invalidateSessionListCache(sessionId: sessionId)
        var report = RepairReport()

        exec("BEGIN TRANSACTION")

        // Step 1: reload messages by a stable composite key to drive sortOrder rewrite.
        // Order by (created_at, id) ignoring the current sort_order entirely — this gives
        // us a canonical sequence independent of any existing duplicates.
        let selectSql = "SELECT id, sort_order FROM messages WHERE session_id = ? ORDER BY created_at ASC, id ASC"
        var rows: [(id: String, oldSortOrder: Int)] = []
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &selStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(selStmt) == SQLITE_ROW {
                let idC = sqlite3_column_text(selStmt, 0).map { String(cString: $0) } ?? ""
                let so = Int(sqlite3_column_int64(selStmt, 1))
                rows.append((id: idC, oldSortOrder: so))
            }
        }
        sqlite3_finalize(selStmt)

        // Step 2: compute new sortOrders and update any that changed.
        // We assign base..base+n-1 dense, using the canonical (created_at, id) order.
        let base = SessionOrderRules.repairBaseSortOrder(
            rowCount: rows.count, oldMaxSortOrder: rows.map(\.oldSortOrder).max() ?? -1)
        let updateSql = "UPDATE messages SET sort_order = ? WHERE id = ?"
        var updStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSql, -1, &updStmt, nil) == SQLITE_OK {
            for (idx, row) in rows.enumerated() where row.oldSortOrder != base + idx {
                let newSO = base + idx
                sqlite3_reset(updStmt)
                sqlite3_bind_int(updStmt, 1, Int32(newSO))
                sqlite3_bind_text(updStmt, 2, (row.id as NSString).utf8String, -1, nil)
                sqlite3_step(updStmt)
                report.sortOrderFixed += 1
            }
        }
        sqlite3_finalize(updStmt)

        // Step 3: upgrade legacy markers. Build a (oldSortOrder -> id) map first, then
        // find each nil-firstKeptMessageId marker and fill it in using firstKeptSortOrder.
        // NOTE: this lookup uses the NEW sortOrder (we just rewrote it), so we build
        // the map from the rewritten enumeration.
        var newSoToId: [Int: String] = [:]
        for (idx, row) in rows.enumerated() { newSoToId[base + idx] = row.id }
        // But legacy markers were written with OLD sortOrders. If rewrites happened,
        // the legacy firstKeptSortOrder may no longer point to anything sensible.
        // Strategy: try (a) newSO map, then (b) find old row whose OLD sort_order == legacy value.
        // Because step 2 just changed the sort_orders, approach (b) needs to query the
        // pre-update state — but we've already committed in memory. Instead, use the
        // original `rows` list: row index i now corresponds to new sort_order base+i. Find
        // any row where row.oldSortOrder == legacy value as a second-chance lookup.
        var oldSoToId: [Int: String] = [:]
        for row in rows { oldSoToId[row.oldSortOrder] = row.id }  // last write wins on dup

        // Only true legacy markers (no id-based fields at all) are upgraded.
        // compactAll markers (first_kept_message_id NULL but last_compacted_message_id set)
        // are intentional — leave them alone.
        let markerSelSql = "SELECT id, first_kept_sort_order FROM compact_markers WHERE session_id = ? AND first_kept_message_id IS NULL AND last_compacted_message_id IS NULL"
        var mSelStmt: OpaquePointer?
        var legacyMarkers: [(id: String, firstKeptSortOrder: Int)] = []
        if sqlite3_prepare_v2(db, markerSelSql, -1, &mSelStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(mSelStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(mSelStmt) == SQLITE_ROW {
                let mid = sqlite3_column_text(mSelStmt, 0).map { String(cString: $0) } ?? ""
                let fkso = Int(sqlite3_column_int64(mSelStmt, 1))
                legacyMarkers.append((id: mid, firstKeptSortOrder: fkso))
            }
        }
        sqlite3_finalize(mSelStmt)

        let mUpdSql = "UPDATE compact_markers SET first_kept_message_id = ? WHERE id = ?"
        var mUpdStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, mUpdSql, -1, &mUpdStmt, nil) == SQLITE_OK {
            for lm in legacyMarkers {
                // Try new map first (post-rewrite), then old map (pre-rewrite).
                let resolved = newSoToId[lm.firstKeptSortOrder] ?? oldSoToId[lm.firstKeptSortOrder]
                guard let fkmId = resolved else {
                    logger.warning("[Repair] marker id=\(lm.id.prefix(8)) firstKeptSortOrder=\(lm.firstKeptSortOrder) has no matching row — cannot upgrade")
                    continue
                }
                sqlite3_reset(mUpdStmt)
                sqlite3_bind_text(mUpdStmt, 1, (fkmId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(mUpdStmt, 2, (lm.id as NSString).utf8String, -1, nil)
                sqlite3_step(mUpdStmt)
                report.markersUpgraded += 1
                // Mark marker as dirty so the upgraded field propagates to iCloud.
                markDirty(recordType: "CompactMarker", recordId: lm.id)
            }
        }
        sqlite3_finalize(mUpdStmt)

        exec("COMMIT")

        // The list preview remembers the sort_order of the message it shows and
        // only ever moves forward (updateStoredPreview). Rows just moved, so
        // re-derive it from the rows rather than leave it pointing at a stale
        // position.
        if report.sortOrderFixed > 0 {
            recomputeStoredPreview(sessionId: sessionId)
        }

        if report.hadAnomaly {
            logger.warning("[Repair] session=\(sessionId.prefix(8)) sortOrderFixed=\(report.sortOrderFixed) markersUpgraded=\(report.markersUpgraded) totalRows=\(rows.count) base=\(base)")
        }
        return report
    }

    /// Cheap-check-then-repair. Safe to call on every session open; the check
    /// is a single SQL per session.
    ///
    /// Also heals a list preview left frozen by an older build, whose repair
    /// renumbered pruned sessions down to 0..n-1 without touching the stored
    /// preview: its preview_sort_order then sat above every row, so no later
    /// message could replace it (FD704863, 2026-10-04: the list kept showing an
    /// 11:50 reply while the chat had moved on to 12:35).
    @discardableResult
    func repairSessionIfNeeded(sessionId: String) -> RepairReport {
        if storedPreviewIsStale(sessionId: sessionId) {
            logger.warning("[Repair] session=\(sessionId.prefix(8)) stored preview points past the last message — recomputing")
            // PER-SESSION: rewrites this session's preview columns only.
            invalidateSessionListCache(sessionId: sessionId)
            recomputeStoredPreview(sessionId: sessionId)
        }
        guard sessionNeedsRepair(sessionId: sessionId) else { return RepairReport() }
        return repairSession(sessionId: sessionId)
    }

    /// True when the session's stored preview_sort_order is above its highest
    /// message sort_order — a position no message holds any more.
    private func storedPreviewIsStale(sessionId: String) -> Bool {
        var stmt: OpaquePointer?
        var stale = false
        if sqlite3_prepare_v2(db, SessionOrderRules.stalePreviewProbeSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            stale = sqlite3_step(stmt) == SQLITE_ROW
        }
        sqlite3_finalize(stmt)
        return stale
    }

    /// Read a CompactMarker from a prepared statement at current row.
    /// Column order: id(0), session_id(1), summary(2), first_kept_sort_order(3),
    /// compacted_count(4), created_at(5), ui_boundary_sort_order(6),
    /// boundary_message_id(7), first_kept_message_id(8), last_compacted_message_id(9),
    /// version(10).
    func readCompactMarker(from stmt: OpaquePointer?) -> CompactMarker {
        let uiBoundary: Int? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? Int(sqlite3_column_int64(stmt, 6))
            : nil
        let bmId: String? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 7))
            : nil
        let fkmId: String? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 8))
            : nil
        let lcmId: String? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 9))
            : nil
        // version may be absent on rows written before the column was added —
        // ALTER TABLE ... DEFAULT 1 covers the SQL side, but defensive fallback
        // here keeps tests and tooling happy.
        let version: Int = sqlite3_column_type(stmt, 10) != SQLITE_NULL
            ? Int(sqlite3_column_int64(stmt, 10))
            : 1
        return CompactMarker(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            sessionId: String(cString: sqlite3_column_text(stmt, 1)),
            summary: String(cString: sqlite3_column_text(stmt, 2)),
            firstKeptSortOrder: Int(sqlite3_column_int64(stmt, 3)),
            compactedCount: Int(sqlite3_column_int64(stmt, 4)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            uiBoundarySortOrder: uiBoundary,
            boundaryMessageId: bmId,
            firstKeptMessageId: fkmId,
            lastCompactedMessageId: lcmId,
            version: version
        )
    }
}

// BEGIN SessionOrderRules
/// The ordering rules session repair and the list preview share, as data a
/// standalone test can run against SQLite (MinisTests/Standalone/
/// SessionOrderRepairTests.swift compiles this block verbatim).
///
/// Background (FD704863, 2026-10-04): a session over ChatStore's 2048-row prune
/// threshold loses its oldest rows after every append, so its sort_orders start
/// above 0. The old repair check expected exactly 0..n-1, so EVERY open of such
/// a session (first open after each launch) rewrote all rows down to 0..2047.
/// Nothing was out of order; the rewrite only lowered every sort_order, which
/// left the stored list preview pointing past the end of the session (frozen
/// on an old reply) and invalidated every sort_order other state had kept.
enum SessionOrderRules {
    /// Returns a row iff some message's position by sort_order differs from
    /// its position in the canonical (created_at, id) order - the order every
    /// writer keeps (local appends get created_at at persist time; remote
    /// merges are slotted by (created_at, id) rank). Gaps are not an anomaly:
    /// pruning and tail deletes leave them, and nothing depends on sort_orders
    /// being dense or starting at 0. Bind 1: session_id.
    static let inversionProbeSQL = """
        SELECT 1 FROM (
          SELECT ROW_NUMBER() OVER (ORDER BY sort_order ASC, created_at ASC, id ASC) AS by_sort,
                 ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS by_time
          FROM messages WHERE session_id = ?
        ) WHERE by_sort != by_time LIMIT 1
        """

    /// First sort_order a repair assigns. Rows are renumbered densely in
    /// canonical order so they END at the old maximum (or at n-1 when
    /// duplicates left the maximum below that), never below it: sort_orders
    /// only ever grow, so the stored preview position, a view model's reload
    /// baseline and sort_orders already sent to iCloud stay valid.
    static func repairBaseSortOrder(rowCount: Int, oldMaxSortOrder: Int) -> Int {
        max(0, oldMaxSortOrder - (rowCount - 1))
    }

    /// The incremental preview update (ChatStore.updateStoredPreview). Binds:
    /// 1 preview text, 2 the message's sort_order, 3 session_id, 4 the
    /// message's sort_order again, 5 session_id again. `comparison` is ">=" for
    /// an assistant row (wins ties) and ">" for a user row. The last clause
    /// lets a newly written message replace a preview whose sort_order lies
    /// above every row of the session (stale; see stalePreviewProbeSQL).
    static func storedPreviewUpdateSQL(comparison: String) -> String {
        """
        UPDATE sessions
           SET preview_text = ?, preview_sort_order = ?
         WHERE id = ?
           AND (preview_sort_order IS NULL OR ? \(comparison) preview_sort_order
                OR preview_sort_order > (SELECT MAX(sort_order) FROM messages WHERE session_id = ?))
        """
    }

    /// Returns a row iff the session's stored preview_sort_order is above its
    /// highest message sort_order (a NULL on either side never matches).
    /// Bind 1: session_id.
    static let stalePreviewProbeSQL = """
        SELECT 1 FROM sessions s
         WHERE s.id = ?1
           AND s.preview_sort_order > (SELECT MAX(m.sort_order) FROM messages m WHERE m.session_id = ?1)
        """
}
// END SessionOrderRules
