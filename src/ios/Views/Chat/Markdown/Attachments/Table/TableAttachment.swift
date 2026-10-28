//
//  TableAttachment.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments / Table.
//
//  A markdown table. Computes a TableLayout for the width it is laid out at
//  (TableColumnPlanner, cached via TableWidthCache), renders the cell text,
//  and builds the grid view: TableScrollView hosting TableCellLabel /
//  TableCellTextView cells. Also owns the table's copy actions (as
//  tab-separated text and as an image).
//
//  contentGeneration changes when the table is mutated in place (rows arriving
//  while streaming); the text view folds it into its cell-size fingerprint.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Table Attachment

final class TableAttachment: NSTextAttachment {
    private(set) var alignments: [RawTableColumnAlignment]
    private(set) var rows: [RawTableRow]
    let theme: SelectableMarkdownTheme
    /// Handler for opening URLs from links in table cells.
    var onOpenURL: ((URL) -> Void)?

    /// Shared NSDataDetector used to find bare URLs that the markdown
    /// parser left as `.text` (cmark-gfm autolink misses on CJK / full-
    /// width adjacency). Compiled once — initializer can throw, hence
    /// the `try?`. Reused across every table cell in the app.
    static let linkDataDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    /// Set when `update(...)` mutates content in place. Tells the parent
    /// updateAttachmentViews path that the existing rendered TableScrollView
    /// needs to be rebuilt to reflect the new rows/alignments. Mirrors
    /// `ImageAttachment.needsViewRebuild`. Reset by the consumer after the
    /// view is recreated.
    var needsViewRebuild: Bool = false
    /// Set when the content/layout changed in place; updateUIView reads this
    /// to invalidate just the attachment's character range in the parent
    /// UITextView's layoutManager (instead of the whole document).
    var needsLayoutInvalidation: Bool = false

    /// Horizontal scroll offset the user last reached on this table,
    /// re-applied inside every freshly-built view so the left/right scroll
    /// position survives streaming redraws. In-memory only (lives on this
    /// attachment, which keeps its object identity across streaming
    /// `update(...)` calls); never persisted.
    ///
    /// [T-ios-table-hscroll-offset-lost] This is PERSISTENT, not one-shot:
    /// the previous consume-once `pendingScrollOffset` + async restore lost
    /// the position whenever the next streaming rebuild fired before the
    /// async restore landed — the capture then read a transient offset of 0,
    /// declined to re-capture, and the restore targeted the already-removed
    /// old view. Now the live TableScrollView pushes every user-driven
    /// offset change here (see `onUserScroll` wiring in `makeView`), and
    /// `makeView` re-applies it synchronously without clearing it.
    var preservedScrollOffset: CGPoint?

    /// Walk a `makeView`-produced wrapper to its inner TableScrollView so the
    /// rebuild path can read/restore `contentOffset`. The wrapper holds exactly
    /// one TableScrollView subview (see `makeView`).
    static func tableScrollView(in wrapper: UIView) -> TableScrollView? {
        if let direct = wrapper as? TableScrollView { return direct }
        return wrapper.subviews.compactMap { $0 as? TableScrollView }.first
    }

    /// Monotonic counter bumped on every `update(...)`. The parent textView's
    /// `invalidateCellSizeIfNeeded` includes the sum of all TableAttachments'
    /// generations in its dedup fingerprint — without this, a streaming
    /// table whose rows/cols change but whose surrounding text (and thus
    /// `textStorage.length`) doesn't would be skipped by the
    /// "storageLen+width unchanged → no remeasure" early-exit, leaving the
    /// layout manager with the original (smaller) attachment bounds and
    /// producing the "table renders single-column / extra rows missing"
    /// symptom we hit during the watchdog repro.
    private(set) var contentGeneration: UInt64 = 0

    init(alignments: [RawTableColumnAlignment], rows: [RawTableRow], theme: SelectableMarkdownTheme) {
        self.alignments = alignments
        self.rows = rows
        self.theme = theme
        super.init(data: nil, ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Replace the table's content while keeping the same NSTextAttachment
    /// object identity. Crucial during streaming markdown: when only the table
    /// grows (e.g. one more cell character per token), preserving identity
    /// keeps the SelectableMarkdownView fast-path's prefix `isEqual` check
    /// happy, so we no longer fall back to `ensureLayout` over the entire
    /// message every chunk.
    func update(alignments: [RawTableColumnAlignment], rows: [RawTableRow]) {
        // [T-ios-table-hscroll-stream-interrupt] No-op when the content is
        // identical. The caller's hash-based routing normally sends equal
        // content to the cache-hit path instead of here, but if it ever
        // lands here, setting needsViewRebuild would tear down (and cancel
        // any in-flight horizontal scroll on) an already up-to-date
        // TableScrollView for nothing.
        if alignments == self.alignments && rows == self.rows { return }
        // HangFix(2026-05-14) — During streaming, this method fires on every
        // token chunk while a partial table is on screen. Wiping cachedLayout
        // unconditionally means each subsequent attachmentBounds callback
        // (TextKit1 calls it many times per fillLayoutHole pass) re-runs a
        // full per-cell NSAttributedString.boundingRect measurement. Even
        // a 4-row × 2-col table at small attrLen amplifies into seconds of
        // main-thread time when the typesetter loops on width probing.
        //
        // The previous-pass layout is still visually accurate if no new row
        // arrived (only cell content grew), AND it's still close-enough to
        // accurate even when one row was appended (the typesetter will fix
        // up the final size on the next real layout). We retain it in both
        // cases — the cell will re-measure naturally when `computeLayout`
        // gets called on a different width or when an actual size change
        // forces it. The transient stale height for one frame is invisible
        // versus a 1-2s hang on every streaming chunk.
        let oldRowCount = self.rows.count
        let oldColCount = self.alignments.count
        self.hasStreamingUpdates = true
        self.alignments = alignments
        self.rows = rows
        let structureChanged = rows.count != oldRowCount || alignments.count != oldColCount

        // [T-ios-table-streaming-width] Check whether the cached column widths
        // are stale. The HangFix (2026-05-14) only invalidated on row/column
        // COUNT changes, but during streaming a row's content grows from
        // partial to complete (same row count). The cached column widths from
        // the partial content are too narrow → columns wrap / emoji get
        // clipped. We track the max character count per column at cache time;
        // when any column's widest cell grows longer, the cache is stale.
        // This is O(rows × cols) integer comparisons — no hashing, no layout,
        // no measurement — so it stays cheap on every streaming token.
        let colCount = alignments.count
        var currentMax = [Int](repeating: 0, count: colCount)
        for row in rows {
            for (ci, cell) in row.cells.enumerated() where ci < colCount {
                currentMax[ci] = max(currentMax[ci], cell.content.plainText.count)
            }
        }
        let contentGrew: Bool
        if cachedLayout == nil {
            contentGrew = false
        } else if currentMax.count != cachedMaxCharPerCol.count {
            contentGrew = true
        } else {
            contentGrew = zip(currentMax, cachedMaxCharPerCol).contains { $0 > $1 }
        }
        if structureChanged || contentGrew {
            self.cachedLayout = nil
        }
        // [T-table-layout-true-width] The content changed, so a layout kept for
        // any other width is stale. `cachedLayout` (the last persisted width) is
        // refreshed row by row below and re-stored.
        layoutsByWidth.removeAll()
        // [T-table-stream-row-height] Cells now wrap (TableColumnPlanner), so a
        // row's height depends on its OWN text, not just on each column's
        // widest cell. The streaming row is usually shorter than the widest
        // cells above it: it grew without tripping `contentGrew`, kept the
        // one-line height it had when it appeared, and its text was clipped at
        // the table's bottom edge — for good, since the final identical
        // content returns early above. Re-measure only the rows whose text
        // changed, at the cached column widths (column widths stay put, and
        // this costs one row's cells per token instead of the full re-layout
        // HangFix(2026-05-14) avoids).
        var rowHeightsChanged = false
        if !structureChanged, !contentGrew, let cached = cachedLayout,
           cached.rowHeights.count == rows.count {
            let current = Self.cellCharCounts(rows, colCount: colCount)
            var heights = cached.rowHeights
            for (rowIdx, row) in rows.enumerated()
            where rowIdx >= cachedCellChars.count || cachedCellChars[rowIdx] != current[rowIdx] {
                let h = measuredRowHeight(rowIdx: rowIdx, row: row, columnWidths: cached.columnWidths)
                if abs(h - heights[rowIdx]) >= 0.5 { heights[rowIdx] = h; rowHeightsChanged = true }
            }
            cachedCellChars = current
            if rowHeightsChanged {
                cachedLayout = TableLayout(width: cached.width, columnWidths: cached.columnWidths,
                                           rowHeights: heights, tableWidth: cached.tableWidth)
            }
            if let current = cachedLayout {
                layoutsByWidth.store(width: current.width, tableWidth: current.tableWidth, value: current)
            }
        }
        // Always mark for view rebuild so SelectableTableView's row VStack
        // can re-create row subviews with new cell content. Bounds reuse
        // is independent of view rebuild.
        self.needsViewRebuild = true
        // Layout invalidation needed when structure changes (rowHeights array
        // shape) or content grew wider (column widths stale) — even when
        // cachedLayout was already nil, the textView layout manager needs to
        // know the attachment bounds changed.
        self.needsLayoutInvalidation = structureChanged || contentGrew || rowHeightsChanged
        self.contentGeneration &+= 1
    }

    /// Tab-separated plain text representation of the table (rows joined by `\n`).
    func plainText() -> String {
        let colCount = alignments.count
        return rows.map { row in
            row.cells.prefix(colCount).map { $0.content.plainText }.joined(separator: "\t")
        }.joined(separator: "\n")
        // [T-md-cjk-emphasis-pairs] Strip flanking-fix spacers (see
        // plainTextWithTables) so table copies stay clean too.
        .replacingOccurrences(of: "\u{200B}", with: "")
        .replacingOccurrences(of: "\u{200A}", with: "")
    }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    /// Spacing controlled by RenderedBlock margins; no extra padding inside attachment
    static let verticalMargin: CGFloat = 0
    static let minRowHeight: CGFloat = 36
    /// [T-table-cell-padding-half] Left/right inset of each cell. Halved from
    /// 16: with columns capped (TableColumnPlanner) the 32pt per column was a
    /// quarter of a phone column's width, and the text wrapped earlier than
    /// it had to. Feeds the planner's natural widths, row-height measurement
    /// and the cell frames.
    static let cellPaddingH: CGFloat = 8
    static let cellPaddingV: CGFloat = 8

    /// Narrowest real (non-probe) attachment width observed process-wide, used as
    /// the height-measurement fallback for a first-appearance probe that races
    /// ahead of any real-width pass. Seeded below any real chat-bubble width so a
    /// probe never returns a height that clips the last table row.
    /// [ios_session_open_last_cell_occluded]
    nonisolated(unsafe) static var narrowestRealWidth: CGFloat = 380

    /// Cached layout computed for a given width, reused by both attachmentBounds and makeView.
    private var cachedLayout: TableLayout?
    /// [T-table-layout-true-width] Layouts at the other widths this table was
    /// asked about (SwiftUI's inner/outer probes, rotation), so each width gets
    /// its own plan without re-planning on every alternation. `cachedLayout`
    /// stays the last persisted width (streaming row refresh, probe fallback).
    private var layoutsByWidth = TableWidthCache<TableLayout>(capacity: 6)

    /// [T-table-layout-true-width] Set while a SwiftUI measurement runs at a width
    /// that is not the one this text will render at: a nil proposal measured at
    /// the screen width, or the cell's outer-width probe on a laid-out view. A
    /// table laid out then is returned but not persisted, so the probe can never
    /// become the width later requests fall back to. Main-thread only.
    nonisolated(unsafe) static var nonRenderWidthMeasureDepth = 0
    /// Per-column maximum cell character count at the time `cachedLayout` was
    /// computed. When any column's widest cell grows longer during streaming,
    /// the cached column widths may be too narrow → must recompute. Using
    /// character counts (not a full content hash) keeps the check O(cells)
    /// per token — cheaper than Hasher over all plainText.
    private var cachedMaxCharPerCol: [Int] = []
    /// [T-table-stream-row-height] Per-cell character counts when
    /// `cachedLayout` was computed or last row-refreshed.
    private var cachedCellChars: [[Int]] = []
    /// [T-table-column-width-plan] Set once `update(...)` has changed this
    /// table's content in place, i.e. it is (or was) streaming. From then on
    /// column widths only grow at a given width (`streamingFloorWidths`), so a
    /// later row can't make an earlier column jump narrower.
    private var hasStreamingUpdates = false
    private var streamingFloorWidths: [CGFloat]?
    private var streamingFloorWidth: CGFloat?

    // MARK: - [T-ios-attachbounds-cold-cache] Process-wide layout cache
    //
    // `cachedLayout` above is PER-INSTANCE. On scroll deceleration the
    // collection view recycles cells; the per-cell renderer wipes/rebuilds
    // attachments (isNewMessage CACHE-WIPE), so a TableAttachment landing into
    // view at decel-stop often starts with `cachedLayout == nil` and every
    // `attachmentBounds` typesetter probe is a cold miss → a burst of per-cell
    // `boundingRect` measurement on the landing frame (the 100–190ms decel
    // jank, confirmed via [ScrollDecel]+[AttachBoundsHot] device logs).
    //
    // `computeLayout` is a PURE function of (rows, alignments, theme font,
    // bucketed width). Cache its result process-wide keyed by that signature
    // so an identical table — same content, same width — that was measured by
    // ANY earlier cell is reused instantly instead of cold-measured again.
    // LRU-bounded; pure layout values (no view refs) so it's cheap to retain.
    private struct LayoutCacheKey: Hashable {
        let contentSig: Int
        let widthBucket: Int   // width snapped to 4pt to fold typesetter probe jitter
    }
    nonisolated(unsafe) private static var sharedLayoutCache: [LayoutCacheKey: TableLayout] = [:]
    nonisolated(unsafe) private static var sharedLayoutLRU: [LayoutCacheKey] = []
    private static let sharedLayoutCacheCap = 256
    nonisolated(unsafe) private static var sharedLayoutHits: Int = 0
    nonisolated(unsafe) private static var sharedLayoutMisses: Int = 0
    nonisolated(unsafe) private static var sharedLayoutLastFlush: CFAbsoluteTime = 0

    /// Stable content signature for the shared layout cache. Folds the full
    /// cell text + alignments + header-font size (layout depends on all three).
    private var layoutContentSignature: Int {
        var h = Hasher()
        h.combine(alignments)
        h.combine(theme.baseFontSize)
        for row in rows {
            for cell in row.cells { h.combine(cell.content.plainText) }
            h.combine(0x1E)  // row separator so cell regrouping changes the hash
        }
        return h.finalize()
    }

    /// Discard the cached layout so the next `computeLayout` / `attachmentBounds`
    /// recomputes column widths and row heights for whatever width is current.
    /// Called from `layoutSubviews` when the textContainer width changes
    /// (rotation, size-class change) — without it the table reuses the original
    /// portrait-width columns and the visible table frame stays at the old
    /// width on the new orientation.
    func invalidateCachedLayoutForWidthChange() {
        cachedLayout = nil
        layoutsByWidth.removeAll()
        needsViewRebuild = true
        needsLayoutInvalidation = true
        contentGeneration &+= 1
    }

    struct TableLayout {
        let width: CGFloat
        let columnWidths: [CGFloat]
        let rowHeights: [CGFloat]
        let tableWidth: CGFloat
        var totalHeight: CGFloat { rowHeights.reduce(0, +) + 2 }
    }

    /// Height of one row at the given column widths: the tallest cell's
    /// wrapped text plus vertical padding, never below `minRowHeight`.
    private func measuredRowHeight(rowIdx: Int, row: RawTableRow, columnWidths: [CGFloat]) -> CGFloat {
        var height = Self.minRowHeight
        for (colIdx, cell) in row.cells.enumerated() where colIdx < columnWidths.count {
            let font: UIFont = rowIdx == 0
                ? .systemFont(ofSize: theme.baseFontSize, weight: .semibold)
                : .systemFont(ofSize: theme.baseFontSize)
            let cellWidth = columnWidths[colIdx] - Self.cellPaddingH * 2
            let attrStr = renderCellInlines(cell.content, baseFont: font)
            let boundingRect = attrStr.boundingRect(
                with: CGSize(width: cellWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            height = max(height, ceil(boundingRect.height) + Self.cellPaddingV * 2)
        }
        return height
    }

    /// [T-table-stream-row-height] Character count of every cell, row-major.
    static func cellCharCounts(_ rows: [RawTableRow], colCount: Int) -> [[Int]] {
        rows.map { row in row.cells.prefix(colCount).map { $0.content.plainText.count } }
    }

    /// [T-table-column-width-plan] Longest run a line break should not split:
    /// consecutive characters that are neither whitespace nor CJK (CJK text
    /// can break between any two characters, so it never needs the room).
    /// Only the longest run by character count is measured, one text
    /// measurement per cell. nil when the cell has no such run.
    static func longestUnbreakableRun(in text: String) -> String? {
        var best: Substring?
        var start: String.Index?
        var idx = text.startIndex
        func close(_ end: String.Index) {
            guard let s = start else { return }
            let run = text[s..<end]
            if run.count > (best?.count ?? 0) { best = run }
            start = nil
        }
        while idx < text.endIndex {
            let ch = text[idx]
            let breaks = ch.isWhitespace || ch.unicodeScalars.contains { Self.isCJKScalar($0) }
            if breaks { close(idx) } else if start == nil { start = idx }
            idx = text.index(after: idx)
        }
        close(text.endIndex)
        guard let best, best.count > 1 else { return nil }
        return String(best)
    }

    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF,
             0x3100...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// Each column's single-line (natural) width and widest unbreakable word, padding
    /// included — the planner's input.
    private func measuredColumns() -> [TableColumnPlanner.Column] {
        let colCount = alignments.count
        let padH = Self.cellPaddingH * 2
        var measured = [TableColumnPlanner.Column](repeating: .init(natural: 0, minUnbreakable: 0), count: colCount)
        for (rowIdx, row) in rows.enumerated() {
            for (colIdx, cell) in row.cells.enumerated() where colIdx < colCount {
                let text = cell.content.plainText
                let font: UIFont = rowIdx == 0
                    ? .systemFont(ofSize: theme.baseFontSize, weight: .semibold)
                    : .systemFont(ofSize: theme.baseFontSize)
                let size = (text as NSString).size(withAttributes: [.font: font])
                // +12: the same single-line safety margin as before, so a cell
                // measured as fitting also fits once laid out in a UILabel.
                let natural = ceil(size.width) + padH + 12
                measured[colIdx].natural = max(measured[colIdx].natural, natural)
                if let word = Self.longestUnbreakableRun(in: text) {
                    let wordWidth = ceil((word as NSString).size(withAttributes: [.font: font]).width) + padH + 4
                    measured[colIdx].minUnbreakable = max(measured[colIdx].minUnbreakable, wordWidth)
                }
            }
        }
        return measured
    }

    /// [T-multi-select-share] The width at which every column fits on one line — what
    /// the planner's `.natural` plan needs. A probe at a huge width cannot answer
    /// this: `.natural` spreads the spare width, so the probe's table is as wide as
    /// the probe.
    func naturalTableWidth() -> CGFloat {
        measuredColumns().reduce(0) { $0 + max(TableColumnPlanner.floorWidth, $1.natural.rounded(.up)) }
    }

    func computeLayout(for width: CGFloat, persist: Bool = true) -> TableLayout {
        if let cached = cachedLayout, cached.width == width {
            return cached
        }

        // [T-table-layout-true-width] A measurement at a width this text will not
        // render at (`nonRenderWidthMeasureDepth`: a nil SwiftUI proposal, or the
        // cell's outer-width probe) is answered from the render-width layout
        // when there is one — nothing is planned, persisted or cached for it.
        // That keeps the probe from planting a wrong-width layout, and keeps it
        // free while a table streams (`update()` drops the per-width layouts on
        // every token; re-planning the whole table per token for a probe whose
        // height is never rendered is the cost HangFix(2026-05-14) removed).
        let isNonRenderWidthMeasure = !persist && Self.nonRenderWidthMeasureDepth > 0
        if isNonRenderWidthMeasure, let cached = cachedLayout, !cached.columnWidths.isEmpty {
            return TableLayout(width: width, columnWidths: cached.columnWidths,
                               rowHeights: cached.rowHeights, tableWidth: cached.tableWidth)
        }

        // [T-table-layout-true-width] Serve a layout computed at another width
        // only across typesetter jitter (`TableLayoutReuse.tolerance`).
        // Replaces HangFix(2026-05-13)'s "any cached layout within 25%" rule,
        // which predates wrapping cells: a table is now taller at a narrower
        // width, and SwiftUI's outer-width probe (402) planted a layout the
        // 369pt text column then reused — the cell self-sized ~50pt short and
        // its last lines ran under the next message. What the HangFix bought
        // (no re-measure per typesetter probe) is kept by `layoutsByWidth`:
        // each width is planned once, and re-asks at it hit the cache. A real
        // rotation is simply another width.
        if let cached = cachedLayout, !cached.columnWidths.isEmpty,
           TableLayoutReuse.canReuse(layoutWidth: cached.width, layoutTableWidth: cached.tableWidth, for: width) {
            return TableLayout(width: width, columnWidths: cached.columnWidths,
                               rowHeights: cached.rowHeights, tableWidth: cached.tableWidth)
        }
        if let kept = layoutsByWidth.lookup(width) {
            if persist { cachedLayout = kept }
            return TableLayout(width: width, columnWidths: kept.columnWidths,
                               rowHeights: kept.rowHeights, tableWidth: kept.tableWidth)
        }

        // [T-ios-attachbounds-cold-cache] Per-instance cachedLayout missed
        // (this is a freshly-built / recycled attachment). Before paying for a
        // full per-cell measurement, try the process-wide cache: an identical
        // table at this width measured by any earlier cell can be reused as-is.
        // computeLayout is a pure function of content+width, so this is safe.
        let sharedKey = Self.LayoutCacheKey(contentSig: layoutContentSignature, widthBucket: Int((width / 4).rounded()))
        // [T-table-column-width-plan] A table that has streamed carries a
        // width floor (widths only grow while it streams), so its layout is no
        // longer a pure function of content + width: bypass the shared cache
        // both ways.
        // [T-table-layout-true-width] The 4pt bucket can pair widths up to
        // ~4pt apart; hold shared hits to the same reuse rule as local ones.
        if !hasStreamingUpdates, let shared = Self.sharedLayoutCache[sharedKey],
           TableLayoutReuse.canReuse(layoutWidth: shared.width, layoutTableWidth: shared.tableWidth, for: width) {
            Self.sharedLayoutHits &+= 1
            Self.flushSharedLayoutStatsIfNeeded()
            // Rebuild a layout at the exact requested width sharing the cached
            // column widths / row heights.
            let reused = TableLayout(width: width, columnWidths: shared.columnWidths, rowHeights: shared.rowHeights, tableWidth: shared.tableWidth)
            if !isNonRenderWidthMeasure {
                layoutsByWidth.store(width: width, tableWidth: reused.tableWidth, value: reused)
            }
            if persist {
                cachedLayout = reused
                Self.touchSharedLayoutLRU(sharedKey)
            }
            logTableLayout(reused, source: "shared", persist: persist, mode: nil)
            return reused
        }
        Self.sharedLayoutMisses &+= 1

        let colCount = alignments.count

        // [T-table-column-width-plan] Measure each column once on a single
        // line (its natural width) and its widest unbreakable Latin word, then
        // let TableColumnPlanner split the width in proportion to content
        // ([T-table-width-by-content]): a table that fits wraps inside the
        // viewport, a wordier column is never narrower, and a table too wide
        // for readable wrapping scrolls with the next column peeking in.
        //
        // Replaces [TableColumnCap] (every column at its single-line width,
        // capped at 5× the viewport), under which a table of sentences was
        // ~5× the bubble wide and its third column never on screen. The
        // 2026-05-13 feedback that made that cap loose was about SHORT cells
        // wrapping under a tight uniform cap; here a column that fits on one
        // line keeps its natural width, and only content longer than its share
        // wraps.
        let measured = measuredColumns()
        var plan = TableColumnPlanner.plan(columns: measured, availableWidth: width)
        if persist, hasStreamingUpdates {
            let previous = (streamingFloorWidth.map { abs($0 - width) < 1 } ?? false) ? streamingFloorWidths : nil
            plan = TableColumnPlanner.applyingStreamingFloor(plan, previous: previous, availableWidth: width)
            streamingFloorWidths = plan.widths
            streamingFloorWidth = width
        }
        let columnWidths = plan.widths
        let tableWidth = plan.tableWidth

        // Calculate per-row heights based on text wrapping within column widths
        let rowHeights = rows.enumerated().map { rowIdx, row in
            measuredRowHeight(rowIdx: rowIdx, row: row, columnWidths: columnWidths)
        }

        let layout = TableLayout(width: width, columnWidths: columnWidths, rowHeights: rowHeights, tableWidth: tableWidth)
        if !isNonRenderWidthMeasure {
            layoutsByWidth.store(width: width, tableWidth: tableWidth, value: layout)
        }
        logTableLayout(layout, source: "fresh", persist: persist, mode: plan.mode.rawValue)
        if persist {
            cachedLayout = layout
            // Snapshot per-column max char counts so `update()` can detect
            // when streaming content grew wider than what was measured here.
            var maxChars = [Int](repeating: 0, count: colCount)
            for row in rows {
                for (ci, cell) in row.cells.enumerated() where ci < colCount {
                    maxChars[ci] = max(maxChars[ci], cell.content.plainText.count)
                }
            }
            cachedMaxCharPerCol = maxChars
            cachedCellChars = Self.cellCharCounts(rows, colCount: colCount)
            // [T-ios-attachbounds-cold-cache] Populate the process-wide cache
            // (only for real, persisted widths — never the 32_768 probe, which
            // computeLayout never persists) so the NEXT recycled cell showing
            // this same table at this width skips the measurement entirely.
            if !hasStreamingUpdates { Self.storeSharedLayout(layout, key: sharedKey) }
        }
        Self.flushSharedLayoutStatsIfNeeded()
        return layout
    }

    /// [T-table-layout-true-width] DEBUG trace of every layout this table plans
    /// or takes from the shared cache — which width asked, what it planned for,
    /// and the height the text view will reserve. Re-asks served from
    /// `cachedLayout` / `layoutsByWidth` are not logged.
    private func logTableLayout(_ layout: TableLayout, source: String, persist: Bool, mode: String?) {
        #if DEBUG
        let inst = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFFFF, radix: 16)
        let cols = layout.columnWidths.map { String(format: "%.0f", $0) }.joined(separator: "/")
        AppLogger(category: "TableLayout").info(
            "[TableLayout] inst=\(inst) src=\(source) persist=\(persist) req=\(String(format: "%.1f", layout.width)) "
            + "tableW=\(String(format: "%.0f", layout.tableWidth)) cols=\(cols) mode=\(mode ?? "-") "
            + "rows=\(rows.count) h=\(String(format: "%.1f", layout.totalHeight)) streamed=\(hasStreamingUpdates) "
            + "nonRenderDepth=\(Self.nonRenderWidthMeasureDepth)")
        #endif
    }

    /// [T-table-layout-true-width] Height of the layout this table last
    /// persisted — the width it renders at, since probes and non-render-width
    /// measurements no longer persist — without computing one (0 before it has
    /// one). Feeds the cell-height memo key (`asyncAttachmentRenderSignal`), so
    /// a height measured with one table layout is never seeded onto another.
    var persistedLayoutHeight: CGFloat { cachedLayout?.totalHeight ?? 0 }

    // MARK: - [T-ios-attachbounds-cold-cache] Shared layout cache helpers

    private static func touchSharedLayoutLRU(_ key: LayoutCacheKey) {
        if let pos = sharedLayoutLRU.firstIndex(of: key) { sharedLayoutLRU.remove(at: pos) }
        sharedLayoutLRU.append(key)
    }

    private static func storeSharedLayout(_ layout: TableLayout, key: LayoutCacheKey) {
        sharedLayoutCache[key] = layout
        touchSharedLayoutLRU(key)
        while sharedLayoutLRU.count > sharedLayoutCacheCap, let oldest = sharedLayoutLRU.first {
            sharedLayoutLRU.removeFirst()
            sharedLayoutCache.removeValue(forKey: oldest)
        }
    }

    /// [T-ios-attachbounds-cold-cache] 1Hz hit/miss summary so we can confirm
    /// the cold-cache storm is gone (high hit ratio during decel) without
    /// per-call log spam. DEBUG-only.
    private static func flushSharedLayoutStatsIfNeeded() {
        #if DEBUG
        let now = CACurrentMediaTime()
        guard now - sharedLayoutLastFlush > 1.0, (sharedLayoutHits + sharedLayoutMisses) > 0 else { return }
        AppLogger(category: "AttachBoundsHot").info("[SharedLayoutCache] last1s hits=\(sharedLayoutHits) misses=\(sharedLayoutMisses) size=\(sharedLayoutCache.count)/\(sharedLayoutCacheCap)")
        sharedLayoutHits = 0
        sharedLayoutMisses = 0
        sharedLayoutLastFlush = now
        #endif
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        // Use a slightly reduced width to prevent UIKit NSLayoutManager from
        // entering an infinite _fillLayoutHole loop when the attachment spans
        // the full line fragment width.  Also snap to 1pt grid so tiny floating-
        // point variations between layout passes hit the cached layout.
        let usableWidth = floor(lineFrag.width) - 1
        guard usableWidth > 0 else {
            return CGRect(x: 0, y: 0, width: lineFrag.width, height: Self.minRowHeight)
        }
        // [TableProbeFix] SwiftUI / UIHostingConfiguration's intrinsic-size
        // probing pass calls `attachmentBounds` with a synthesized lineFrag
        // width of `CGFloat.greatestFiniteMagnitude` (10_000_000pt). If we
        // cache the resulting layout — whose last column has been stretched
        // to fill ~10M points — the typesetter produces a glyph rect of
        // width 9_999_999 for the attachment, which then feeds `makeView`
        // and `updateAttachmentViews`. Clamp to 32_768pt and don't persist
        // the probe layout so subsequent real-width measurements aren't
        // poisoned.
        let isOversizedProbe = lineFrag.width >= 100_000
        let clampedWidth = isOversizedProbe ? min(usableWidth, 32_768) : usableWidth
        // [TableProbeHeightFix] The HEIGHT we return must reflect how the table
        // wraps at the REAL display width, not at the probe's 32_768pt. At 32_768
        // every column is wide enough that no cell wraps, so totalHeight collapses
        // to the single-line minimum — e.g. a 6-row table that is 238pt at the real
        // 369pt width measures only 218pt under the probe (one row's worth short).
        // SwiftUI's intrinsic-size probe consumes THIS returned height for the
        // cell's self-size, so on first appearance the table cell is laid out one
        // row too short and the bottom row is clipped until a scroll forces a
        // re-measure at the real width. Fix: on a probe, compute the height at a
        // realistic width, NOT the probe's 32_768pt. Width sources, in order:
        //   1. the real textContainer width — valid even during a probe (only the
        //      proposed lineFragment is synthesized to 10M, the container keeps its
        //      true width). This is the crucial first-appearance source: on the
        //      VERY first probe there is no cached layout yet, and the previous
        //      fallback (clampedWidth=32_768) still collapsed wrapping → one row
        //      short → the persistent "missing a row" the user still saw.
        //   2. the last real (non-probe) width we measured (cachedLayout).
        //   3. a conservative bubble-width cap as a last resort.
        // The RETURNED width stays the probe's clampedWidth so SwiftUI's max-width
        // discovery is unaffected. [ios_session_open_last_cell_occluded]
        let containerRealWidth: CGFloat? = {
            guard let w = textContainer?.size.width, w > 0, w < 100_000 else { return nil }
            return floor(w) - 1
        }()
        let lastRealWidth = cachedLayout.map { $0.width }.flatMap { $0 < 100_000 ? $0 : nil }
        // Remember the narrowest real width this attachment has ever been asked
        // about, across instances — the first non-probe pass records it, and any
        // probe that races AHEAD of that pass (the first-appearance case where
        // cachedLayout is still nil and textContainer reports no usable width)
        // falls back to it. A narrower width can only ADD wrapping (taller table),
        // so erring narrow guarantees we never return a height that is one row too
        // short — at worst the first frame reserves a little extra space, which a
        // later real-width measure trims. The seed (380) is < any real chat bubble
        // width on phone or pad, so it is a safe "never clip" floor.
        // [ios_session_open_last_cell_occluded]
        // [T-table-layout-true-width] A measurement at a width this text will not
        // render at (see `nonRenderWidthMeasureDepth`) is a probe as far as the
        // persisted layout goes: answered, never persisted.
        let isNonRenderWidth = Self.nonRenderWidthMeasureDepth > 0
        if !isOversizedProbe, !isNonRenderWidth, usableWidth > 0 {
            Self.narrowestRealWidth = min(Self.narrowestRealWidth, usableWidth)
        }
        let heightWidth = isOversizedProbe
            ? (containerRealWidth ?? lastRealWidth ?? Self.narrowestRealWidth)
            : clampedWidth
        // TEMP(2026-05-13) — count attachmentBounds invocations + elapsed
        // time so a 1Hz hang on a 6-table cell shows up as e.g.
        // "[AttachBoundsHot] tables=6 calls=180 totalMs=850" — 6 tables ×
        // 30 calls/sec × ~4ms each. This pinpoints the typesetter feedback
        // loop: each fillLayoutHole inside `setFrame` re-asks every
        // attachment for its bounds, and our cache only helps when width
        // didn't change.
        let t0 = CACurrentMediaTime()
        // REPRO-DIAG(2026-05-16): record cache hit BEFORE the call (computeLayout
        // mutates cachedLayout on first miss, so we must check first).
        let _diagCacheHit = (cachedLayout?.width == heightWidth)
        // Persist only for genuine real-width measurements (never for a probe,
        // and never when we substituted a different width for height-only use).
        let layout = computeLayout(for: heightWidth, persist: !isOversizedProbe && !isNonRenderWidth)
        let elapsed = CACurrentMediaTime() - t0
        Self.attachBoundsHotPath_record(elapsed: elapsed, cacheHit: _diagCacheHit, rows: rows.count, cols: alignments.count)
        let height = layout.totalHeight + Self.verticalMargin * 2
        let returnWidth = isOversizedProbe ? clampedWidth : usableWidth
        return CGRect(x: 0, y: 0, width: returnWidth, height: height)
    }

    // TEMP(2026-05-13) — bucket per-second invocation counts for
    // attachmentBounds. Flushed when the 1Hz fillLayoutHole loop hits.
    nonisolated(unsafe) private static var hotCallCount: Int = 0
    nonisolated(unsafe) private static var hotTotalMs: Double = 0
    nonisolated(unsafe) private static var hotLastFlush: CFAbsoluteTime = 0
    // REPRO-DIAG(2026-05-16): finer-grained counters — cache hit/miss and
    // max single-call ms so we can tell whether each call is fast (cache hit)
    // or expensive (computeLayout cell measurement on every call).
    nonisolated(unsafe) private static var hotCacheHits: Int = 0
    nonisolated(unsafe) private static var hotCacheMisses: Int = 0
    nonisolated(unsafe) private static var hotMaxMs: Double = 0
    nonisolated(unsafe) private static var hotSlowEmittedThisSec: Int = 0
    static func attachBoundsHotPath_record(elapsed: CFTimeInterval, cacheHit: Bool = false, rows: Int = 0, cols: Int = 0) {
        hotCallCount &+= 1
        let ms = elapsed * 1000
        hotTotalMs += ms
        if ms > hotMaxMs { hotMaxMs = ms }
        if cacheHit { hotCacheHits &+= 1 } else { hotCacheMisses &+= 1 }
        // REPRO-DIAG(2026-05-16): single-call slow path — anything ≥5ms is
        // unusual for cache-hit and worth investigating. Cap to 8 events/sec
        // so a true hang storm doesn't flood the log.
        if ms >= 5 && hotSlowEmittedThisSec < 8 {
            hotSlowEmittedThisSec &+= 1
            LoggingManager.shared.writeRawLine(
                category: "AttachBoundsHot",
                level: "WARN",
                message: "[TEMP-DIAG][AttachBoundsSlow] ms=\(String(format: "%.2f", ms)) cacheHit=\(cacheHit) rows=\(rows) cols=\(cols)"
            )
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - hotLastFlush >= 1.0, hotCallCount > 0 {
            // Emit when ≥20 calls OR ≥30ms cumulative in the last window.
            if hotCallCount >= 20 || hotTotalMs >= 30 {
                LoggingManager.shared.writeRawLine(
                    category: "AttachBoundsHot",
                    level: "WARN",
                    message: "[HangFix][AttachBoundsHot] TableAttachment.attachmentBounds calls=\(hotCallCount) totalMs=\(String(format: "%.1f", hotTotalMs)) avg=\(String(format: "%.2f", hotTotalMs / Double(hotCallCount)))ms max=\(String(format: "%.2f", hotMaxMs))ms hit=\(hotCacheHits) miss=\(hotCacheMisses) in last \(String(format: "%.1f", now - hotLastFlush))s"
                )
                LoggingManager.shared.flush()
            }
            hotCallCount = 0
            hotTotalMs = 0
            hotMaxMs = 0
            hotCacheHits = 0
            hotCacheMisses = 0
            hotSlowEmittedThisSec = 0
            hotLastFlush = now
        }
    }

    // MARK: - Inline rendering for table cells

    /// Renders an array of InlineNode into an NSAttributedString with proper styling
    /// (bold, italic, links, code, etc.) matching the project's standard link style.
    private func renderCellInlines(_ inlines: [InlineNode], baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in inlines {
            result.append(renderCellInline(node, font: baseFont))
        }
        return result
    }

    private func renderCellInline(_ node: InlineNode, font: UIFont) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        switch node {
        case .text(let text):
            return NSAttributedString(string: text, attributes: attrs)
        case .softBreak:
            return NSAttributedString(string: " ", attributes: attrs)
        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attrs)
        case .code(let code):
            var codeAttrs = attrs
            // [T-md-inline-code-context-font] Same context-relative rule as
            // body inline code, keyed to the cell's font.
            codeAttrs[.font] = theme.inlineCodeFont(matching: font)
            codeAttrs[.foregroundColor] = theme.inlineCodeColor
            // [T-ios-table-inline-code-rounded] Mark inline code with BOTH the
            // custom `.inlineCodeBackground` flag (drives the rounded painter)
            // and the standard `.backgroundColor` (the rect range the painter
            // keys off). Two cell render paths consume this:
            //   - Link cells -> TableCellTextView, now backed by a
            //     MinisLayoutManager whose fillBackgroundRectArray draws the
            //     same rounded rect as body inline code (theme.inlineCodeCornerRadius=5).
            //   - Link-inert cells -> TableCellLabel, which has no layout
            //     manager; it strips `.backgroundColor` (to avoid the square
            //     fill) and paints the rounded background itself in drawText.
            // Both resolve minisInlineCodeBackgroundColor at draw time and
            // repaint on trait changes, so light/dark stay correct.
            codeAttrs[.inlineCodeBackground] = true
            codeAttrs[.backgroundColor] = minisInlineCodeBackgroundColor
            return NSAttributedString(string: code, attributes: codeAttrs)
        case .html(let h):
            return NSAttributedString(string: h, attributes: attrs)
        case .emphasis(let children):
            let italicFont = font.withTraits(.traitItalic)
            return renderCellInlines(children, baseFont: italicFont)
        case .strong(let children):
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
            ])
            let boldFont = UIFont(descriptor: descriptor, size: font.pointSize)
            return renderCellInlines(children, baseFont: boldFont)
        case .strikethrough(let children):
            let result = NSMutableAttributedString(attributedString: renderCellInlines(children, baseFont: font))
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: result.length))
            return result
        case .link(let destination, let children):
            let result = NSMutableAttributedString(attributedString: renderCellInlines(children, baseFont: font))
            let range = NSRange(location: 0, length: result.length)
            if let url = URL(string: destination) {
                result.addAttribute(.link, value: url, range: range)
            }
            result.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            return result
        case .image(_, let children):
            return renderCellInlines(children, baseFont: font)
        case .inlineMath(let latex):
            // Render via MathAttachment so the formula appears as an inline
            // image. The attachment starts with a transparent 1×1 image;
            // MathRenderScheduler fills in `NSTextAttachment.image` on the
            // main queue (because `inlineDrawable = true`) and the hosting
            // cell view re-assigns its `attributedText` in `onLoad` so
            // UIKit redraws with the bitmap.
            let attach = MathAttachment(latex: latex, isBlock: false, theme: theme)
            attach.inlineDrawable = true
            let result = NSMutableAttributedString(attachment: attach)
            result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
            return result
        }
    }

    /// Walks an attributed string and collects every `MathAttachment`
    /// it contains. Used to post-wire async `onLoad` refreshes after the
    /// cell view is created.
    private static func collectMathAttachments(in attrStr: NSAttributedString) -> [MathAttachment] {
        var out: [MathAttachment] = []
        attrStr.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0, length: attrStr.length),
                                   options: []) { value, _, _ in
            if let math = value as? MathAttachment { out.append(math) }
        }
        return out
    }

    /// Kick off async rendering for every math attachment and arrange for
    /// `refresh` to fire once on the main queue after renders complete.
    /// Multiple onLoad callbacks are coalesced via a shared flag so hundreds
    /// of completions only trigger a single `refresh` per runloop tick.
    private static func wireMathAttachments(_ attachments: [MathAttachment],
                                            cellWidth: CGFloat,
                                            rowHeight: CGFloat,
                                            attrStr: NSAttributedString,
                                            refresh: @escaping () -> Void) {
        guard !attachments.isEmpty else { return }
        // Box holding a pending-refresh flag shared by all attachments in
        // this cell. Captured by each onLoad closure.
        final class RefreshState { var pending: Bool = false }
        let state = RefreshState()
        for attachment in attachments {
            attachment.onLoad = {
                guard !state.pending else { return }
                state.pending = true
                DispatchQueue.main.async {
                    state.pending = false
                    refresh()
                }
            }
            attachment.beginRenderingIfNeeded()
        }
    }

    /// Whether an InlineNode tree contains any `.link` nodes.
    private static func containsLinks(_ inlines: [InlineNode]) -> Bool {
        for node in inlines {
            switch node {
            case .link: return true
            case .emphasis(let ch), .strong(let ch), .strikethrough(let ch), .image(_, let ch):
                if containsLinks(ch) { return true }
            default: break
            }
        }
        return false
    }

    func makeView(width: CGFloat) -> UIView {
        #if DEBUG
        // [T-scroll-cell-build-diag] Cost of building the table's view tree.
        let makeViewStart = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - makeViewStart) * 1000
            if ms >= 1, ScrollMetricsRecorder.shared.isEnabled {
                ScrollMetricsRecorder.shared.record(kind: "tblv", a: ms, b: Double(width),
                    note: "rows=\(rows.count) cols=\(alignments.count)")
            }
        }
        #endif
        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        // CALayer.borderColor is a CGColor and CGColor doesn't track dynamic
        // UIColor traits — once we resolve `.cgColor`, it's frozen at the
        // light/dark mode that was active *at resolution time*. When this
        // attachment view is created off-window (typical for the first
        // streaming render of a table), the trait collection is the default
        // (light mode) and resolving `UIColor.label` at 25% alpha gives a
        // near-black border that disappears against the dark message
        // background. Re-entering the session creates the view while the
        // textView is on-window with the right trait collection, which is
        // why the border returns. Use a UIScrollView subclass that
        // re-applies the layer.borderColor in `traitCollectionDidChange`.
        let scrollView = TableScrollView()
        scrollView.borderColorProvider = { [theme] traits in
            theme.tableBorderColor.resolvedColor(with: traits).cgColor
        }
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.isScrollEnabled = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0

        let layout = computeLayout(for: width)
        let colCount = alignments.count
        let columnWidths = layout.columnWidths
        let rowHeights = layout.rowHeights
        let tableWidth = layout.tableWidth

        // Build a closure that copies the entire table as tab-separated text.
        let copyTable: () -> Void = { [weak self] in
            guard let self else { return }
            UIPasteboard.general.string = self.plainText()
            // [T-toast-feedback] Confirm the copy succeeded.
            MinisToast.show(AppLocalized("Table copied"))
        }

        // [T-ios-copy-table-image] Render the FULL table (all rows/cols, not
        // just the visible scroll region) to a PNG and put it on the pasteboard.
        // We snapshot the `stack` view — it lays out every row at the real
        // `tableWidth × stackHeight`, so long/wide tables come out complete.
        // Captured weakly to avoid retaining the view tree past its lifetime;
        // a fresh image-renderer draws its layer hierarchy at screen scale over
        // the resolved table background + rounded border.
        // No dedicated table-background in the theme; use the system background
        // so the copied image is legible (adapts to light/dark) behind the
        // cell text, which carries its own foreground colors.
        let tableBg = UIColor.systemBackground
        let tableBorder = theme.tableBorderColor
        let copyTableImage: () -> Void = { [weak stack] in
            guard let stack, stack.bounds.width > 0, stack.bounds.height > 0 else { return }

            // [T-ios-copy-table-image] Clear any active text selection first so
            // the snapshot doesn't capture the blue selection highlight. The
            // selection lives in a promoted TableCellTextView somewhere under
            // `stack`; walk the subtree, drop its selection, and force a synchronous
            // redraw before rendering.
            func clearSelections(_ view: UIView) {
                if let tv = view as? UITextView {
                    tv.selectedTextRange = nil
                    tv.resignFirstResponder()
                }
                view.subviews.forEach(clearSelections)
            }
            clearSelections(stack)
            stack.layoutIfNeeded()

            let bounds = stack.bounds
            // Opaque + resolve the bg for the CURRENT light/dark trait so the
            // rounded corners (and any sub-pixel gaps) are filled with the right
            // color instead of leaving transparent corners that show white on a
            // light paste target.
            let bg = tableBg.resolvedColor(with: stack.traitCollection)
            let border = tableBorder.resolvedColor(with: stack.traitCollection)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.opaque = true
            let renderer = UIGraphicsImageRenderer(bounds: bounds, format: fmt)
            let image = renderer.image { ctx in
                // Fill the ENTIRE rect (incl. the four corners outside the
                // rounded path) so there are no transparent/white corners.
                bg.setFill()
                ctx.fill(bounds)
                // Draw the table content (rows, cells, separators).
                stack.layer.render(in: ctx.cgContext)
                // Rounded outer border as visual chrome.
                let path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 8)
                border.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            UIPasteboard.general.image = image
            // [T-toast-feedback] Confirm the image copy succeeded.
            MinisToast.show(AppLocalized("Table image copied"))
        }

        var yOffset: CGFloat = 0
        for (rowIdx, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIdx]
            let rowView = UIView()
            rowView.translatesAutoresizingMaskIntoConstraints = false

            var x: CGFloat = 0
            for (colIdx, cell) in row.cells.enumerated() where colIdx < colCount {
                let cellContentWidth = columnWidths[colIdx] - Self.cellPaddingH * 2
                let cellFrame = CGRect(x: x + Self.cellPaddingH, y: 0, width: cellContentWidth, height: rowHeight)

                let alignment: NSTextAlignment
                switch alignments[colIdx] {
                case .center: alignment = .center
                case .right: alignment = .right
                default: alignment = .left
                }

                let baseFont: UIFont = rowIdx == 0
                    ? .systemFont(ofSize: theme.baseFontSize, weight: .semibold)
                    : .systemFont(ofSize: theme.baseFontSize)

                let attrStr = NSMutableAttributedString(attributedString: renderCellInlines(cell.content, baseFont: baseFont))
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.alignment = alignment
                attrStr.addAttribute(.paragraphStyle, value: paraStyle, range: NSRange(location: 0, length: attrStr.length))

                // Detect tappable links and ensure they carry an `.link`
                // attribute on the rendered string. cmark-gfm autolink
                // usually upgrades bare URLs to `.link` nodes, but boundary
                // cases (URL adjacent to CJK characters, full-width
                // punctuation, table cell edges) can leave them as `.text`
                // — in which case the AST-based `containsLinks` returns
                // false AND there's no `.link` attribute in attrStr, so we
                // fall through to TableCellLabel (link-inert) and taps die.
                // Run NSDataDetector as a belt-and-suspenders pass to add
                // `.link` attributes for any URL the parser missed, then
                // route the cell to TableCellTextView so taps work.
                // [T-table-cell-link-bug 2026-05-25]
                var hasLinks = Self.containsLinks(cell.content)
                if !hasLinks {
                    attrStr.enumerateAttribute(.link,
                                                in: NSRange(location: 0, length: attrStr.length),
                                                options: []) { value, _, stop in
                        if value != nil { hasLinks = true; stop.pointee = true }
                    }
                }
                if !hasLinks, let detector = Self.linkDataDetector {
                    let plain = attrStr.string
                    let fullRange = NSRange(location: 0, length: (plain as NSString).length)
                    let matches = detector.matches(in: plain, options: [], range: fullRange)
                    for m in matches {
                        guard let url = m.url else { continue }
                        // Don't clobber an existing `.link` attribute (e.g.
                        // from a `[text](url)` node that happened to match).
                        if attrStr.attribute(.link, at: m.range.location, effectiveRange: nil) != nil {
                            continue
                        }
                        attrStr.addAttribute(.link, value: url, range: m.range)
                        attrStr.addAttribute(.foregroundColor, value: theme.linkColor, range: m.range)
                        attrStr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
                        hasLinks = true
                    }
                }

                // Collect math attachments so we can re-kick the cell's view
                // when the async SwiftMath render finishes. Without this the
                // cell shows a 1×1 transparent placeholder forever.
                let mathAttachments = Self.collectMathAttachments(in: attrStr)

                if hasLinks {
                    let tv = TableCellTextView()
                    tv.isEditable = false
                    tv.isScrollEnabled = false
                    tv.backgroundColor = .clear
                    tv.textContainerInset = .zero
                    tv.textContainer.lineFragmentPadding = 0
                    tv.linkTextAttributes = [
                        .foregroundColor: theme.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                    tv.attributedText = attrStr

                    if let onOpenURL {
                        tv.onOpenURL = onOpenURL
                    }

                    tv.frame = cellFrame
                    let textSize = tv.sizeThatFits(CGSize(width: cellFrame.width, height: .greatestFiniteMagnitude))
                    // [T-table-column-width-plan] Top-aligned, sized to its text so
                    // it never overhangs into the next row's tap area.
                    tv.frame.origin.y = Self.cellPaddingV
                    tv.frame.size.height = min(textSize.height, max(0, rowHeight - Self.cellPaddingV))
                    rowView.addSubview(tv)

                    Self.wireMathAttachments(mathAttachments, cellWidth: cellFrame.width, rowHeight: rowHeight, attrStr: attrStr) { [weak tv] in
                        guard let tv else { return }
                        tv.attributedText = attrStr
                        let ts = tv.sizeThatFits(CGSize(width: cellFrame.width, height: .greatestFiniteMagnitude))
                        tv.frame.origin.y = Self.cellPaddingV
                        tv.frame.size.height = min(ts.height, max(0, rowHeight - Self.cellPaddingV))
                    }
                } else {
                    let label = TableCellLabel()
                    label.backgroundColor = .clear
                    label.numberOfLines = 0
                    label.attributedText = attrStr
                    label.selectableAttributedText = attrStr
                    label.copyTableAction = copyTable
                    label.copyTableImageAction = copyTableImage
                    label.frame = cellFrame
                    let textSize = label.sizeThatFits(CGSize(width: cellFrame.width, height: .greatestFiniteMagnitude))
                    label.frame.size.height = textSize.height
                    label.frame.origin.y = Self.cellPaddingV  // [T-table-column-width-plan] top-aligned
                    rowView.addSubview(label)

                    Self.wireMathAttachments(mathAttachments, cellWidth: cellFrame.width, rowHeight: rowHeight, attrStr: attrStr) { [weak label] in
                        guard let label else { return }
                        label.attributedText = attrStr
                        label.selectableAttributedText = attrStr
                        let ts = label.sizeThatFits(CGSize(width: cellFrame.width, height: .greatestFiniteMagnitude))
                        label.frame.size.height = ts.height
                        label.frame.origin.y = Self.cellPaddingV
                        label.setNeedsDisplay()
                    }
                }

                // Vertical separator — full height to connect across rows
                if colIdx < colCount - 1 {
                    let sep = UIView()
                    sep.backgroundColor = theme.tableBorderColor
                    sep.frame = CGRect(x: x + columnWidths[colIdx] - 0.25, y: 0, width: 0.5, height: rowHeight)
                    rowView.addSubview(sep)
                }
                x += columnWidths[colIdx]
            }

            // Horizontal separator between all rows (bottom edge of each row except last)
            if rowIdx < rows.count - 1 {
                let hSep = UIView()
                hSep.backgroundColor = theme.tableBorderColor
                hSep.frame = CGRect(x: 0, y: rowHeight - 0.25, width: tableWidth, height: 0.5)
                rowView.addSubview(hSep)
            }

            rowView.frame = CGRect(x: 0, y: yOffset, width: tableWidth, height: rowHeight)
            stack.addArrangedSubview(rowView)
            NSLayoutConstraint.activate([
                rowView.heightAnchor.constraint(equalToConstant: rowHeight),
                rowView.widthAnchor.constraint(equalToConstant: tableWidth),
            ])
            yOffset += rowHeight
        }

        let stackHeight = rowHeights.reduce(0, +)
        stack.frame = CGRect(x: 0, y: 0, width: tableWidth, height: stackHeight)
        scrollView.addSubview(stack)
        scrollView.contentSize = CGSize(width: tableWidth, height: stackHeight)
        scrollView.frame = CGRect(x: 0, y: Self.verticalMargin, width: width, height: stackHeight)

        // Border — borderColor is re-applied by TableScrollView on every
        // traitCollectionDidChange via `borderColorProvider`, so dark-mode
        // hosts always get the right resolved color even when the view was
        // initially created off-window.
        scrollView.layer.cornerRadius = 8
        scrollView.layer.borderWidth = 0.5
        scrollView.applyBorderColorForCurrentTraits()
        scrollView.clipsToBounds = true

        wrapper.addSubview(scrollView)
        wrapper.frame = CGRect(x: 0, y: 0, width: width, height: stackHeight + Self.verticalMargin * 2)

        // [T-ios-table-hscroll-offset-lost] Keep the attachment's persistent
        // offset in sync with every user-driven scroll on this view, then
        // restore it into the freshly-built view. Restore SYNCHRONOUSLY —
        // frame and contentSize are already final at this point — so a rapid
        // follow-up streaming rebuild reads the real position instead of a
        // transient 0 (the old consume-once + async-only restore lost the
        // offset exactly that way). The async re-clamp is belt-and-suspenders
        // for hosts that adjust bounds after attach. Never cleared: the next
        // rebuild needs the value again.
        scrollView.onUserScroll = { [weak self] offset in
            self?.preservedScrollOffset = offset
        }
        if let saved = preservedScrollOffset, saved.x > 0 {
            let applyClamped = { [weak scrollView] in
                guard let scrollView else { return }
                let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                let x = min(max(0, saved.x), maxX)
                scrollView.contentOffset = CGPoint(x: x, y: 0)
            }
            applyClamped()
            DispatchQueue.main.async(execute: applyClamped)
        }

        return wrapper
    }

}
