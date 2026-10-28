//
//  TableLayoutPlanning.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments / Table - pure layout policy.
//
//  - TableColumnPlanner: column widths from how much text each column holds.
//  - TableLayoutReuse, TableWidthCache: when a computed table layout may be
//    reused at another width.
//
//  The `// BEGIN ...` / `// END ...` marker comments are load-bearing:
//  MinisTests/Standalone/TableColumnPlannerTests and TableLayoutWidthTests
//  compile the code between them on its own. Keep these blocks free of UIKit
//  and app types (CoreGraphics only).
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Table column width planner

// BEGIN TableColumnPlanner
/// [T-table-width-by-content] Decides markdown table column widths from how
/// much text each column holds.
///
/// History: [TableColumnCap] sized every column to its single-line width
/// (up to 5× the viewport), so prose tables were ~5 screens wide;
/// [T-table-column-width-plan] then guaranteed 3, and [T-table-two-plus-peek]
/// 2 full columns — both capped every visible column at the SAME width, so a
/// column with three times the text came out as narrow as its neighbour and
/// wrapped into five lines while the other had room to spare. User: widths
/// must follow the content ratio, a wordier column must never look narrower,
/// and showing two full columns is not required.
///
/// Per column (all widths include the cell's horizontal padding):
///   n = natural width: widest cell on one line, never below `floorWidth`
///   h = hard minimum: min(n, max(floorWidth, min(longest Latin word, scrollCap)))
///   c = comfortable width: min(n, max(h, comfortFraction · W))
/// Modes:
///   1. Σn ≤ W          → natural: every column grows in proportion to n to fill W.
///   2. Σc ≤ W          → wrapped: max(h, min(n, C + (n − C) · t)) with
///                        C = comfortFraction · W and one t ∈ [0, 1] chosen so the
///                        table exactly fills W — the CSS auto-layout split.
///   3. otherwise       → scrolls: clamp(n, c, max(c, scrollCap)); the column
///                        crossing the right edge shows at least `peekMin`.
/// Invariant (tested): within a table, n_i ≥ n_j ⇒ width_i ≥ width_j, except
/// where a long Latin word forces a minimum.
///
/// Pure (CoreGraphics only) so MinisTests/Standalone/TableColumnPlannerTests
/// compiles this block by itself.
enum TableColumnPlanner {
    struct Column: Equatable {
        /// Widest cell of the column on a single line, padding included.
        var natural: CGFloat
        /// Widest run that should not be split (longest Latin word), padding included.
        var minUnbreakable: CGFloat
    }

    enum Mode: String, Equatable { case natural, wrapped, scrolls }

    struct Plan: Equatable {
        var widths: [CGFloat]
        var tableWidth: CGFloat
        var mode: Mode
    }

    /// Narrowest column (the long-standing minimum).
    static let floorWidth: CGFloat = 80
    /// A prose column gets at least this share of the viewport before the table
    /// scrolls instead — so three prose columns never squeeze into one screen.
    static let comfortFraction: CGFloat = 0.35
    /// No column (and no unbreakable word) is wider than this share when the table scrolls.
    static let scrollCapFraction: CGFloat = 0.7
    /// Least visible width of the column crossing the right edge, the cue that the table scrolls.
    static let peekMin: CGFloat = 24

    static func plan(columns: [Column], availableWidth: CGFloat) -> Plan {
        let n = columns.count
        let w = max(availableWidth, 0)
        guard n > 0, w > 0 else { return Plan(widths: [], tableWidth: w, mode: .natural) }
        let floorW = min(floorWidth, w)
        let scrollCap = (w * scrollCapFraction).rounded(.down)
        let comfortW = (w * comfortFraction).rounded(.down)
        let natural = columns.map { max(floorW, $0.natural.rounded(.up)) }
        let hard = columns.indices.map { i in
            min(natural[i], max(floorW, min(columns[i].minUnbreakable.rounded(.up), scrollCap)))
        }
        let comfort = columns.indices.map { i in min(natural[i], max(hard[i], comfortW)) }
        let sumNatural = natural.reduce(0, +)
        let sumComfort = comfort.reduce(0, +)

        if sumNatural <= w {
            // Everything fits on one line: spread the spare width in proportion
            // to content, so no column ends up wider than a wordier one.
            let widths = natural.map { $0 * w / sumNatural }
            return Plan(widths: widths, tableWidth: w, mode: .natural)
        }
        if sumComfort <= w {
            // One growth factor for every column, so width stays a function of
            // content alone; a long word only ever raises its own column to
            // that word, never gives it a bigger share of the spare width.
            func widths(_ t: CGFloat) -> [CGFloat] {
                natural.indices.map { max(hard[$0], min(natural[$0], comfortW + (natural[$0] - comfortW) * t)) }
            }
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if widths(mid).reduce(0, +) < w { lo = mid } else { hi = mid }
            }
            var result = widths(hi)
            // Bisection lands within a hair of `w`; give the remainder to the
            // widest column so the table fills the viewport exactly.
            if let i = result.indices.max(by: { natural[$0] < natural[$1] }) {
                result[i] += w - result.reduce(0, +)
            }
            return Plan(widths: result, tableWidth: w, mode: .wrapped)
        }
        var widths = natural.indices.map { max(comfort[$0], min(natural[$0], scrollCap)) }
        applyPeek(&widths, natural: natural, comfort: comfort, viewport: w)
        return Plan(widths: widths, tableWidth: max(widths.reduce(0, +), w), mode: .scrolls)
    }

    /// If a column boundary lands just inside the right edge, the next column
    /// shows as a sliver (or not at all) and the table reads as finished.
    /// Narrow the column before it — never below its comfortable width and
    /// never below a column with no more text — so at least `peekMin` shows.
    static func applyPeek(_ widths: inout [CGFloat], natural: [CGFloat], comfort: [CGFloat], viewport w: CGFloat) {
        var x: CGFloat = 0
        for k in widths.indices {
            if x + widths[k] > w {
                let visible = w - x
                guard k >= 1, visible < peekMin else { return }
                let j = k - 1
                let lessText = widths.indices.filter { $0 != j && natural[$0] <= natural[j] }.map { widths[$0] }.max() ?? 0
                let give = min(peekMin - visible, widths[j] - max(comfort[j], lessText))
                if give > 0 { widths[j] -= give }
                return
            }
            x += widths[k]
        }
    }

    /// [T-table-column-width-plan] Streaming stability: column widths only grow
    /// while a table streams in (a later row can't make an earlier column jump
    /// narrower). A table the plan fits in the viewport stays within it: any
    /// overshoot from the lift is taken back from the most-lifted columns, never
    /// below the plan. A scrolling table keeps its lifted widths.
    static func applyingStreamingFloor(_ plan: Plan, previous: [CGFloat]?, availableWidth: CGFloat) -> Plan {
        guard let previous, previous.count == plan.widths.count, !plan.widths.isEmpty else { return plan }
        var widths = zip(plan.widths, previous).map { max($0, $1) }
        if plan.mode != .scrolls {
            var over = widths.reduce(0, +) - max(availableWidth, plan.widths.reduce(0, +))
            while over >= 0.5 {
                guard let i = widths.indices.max(by: { (widths[$0] - plan.widths[$0]) < (widths[$1] - plan.widths[$1]) }),
                      widths[i] - plan.widths[i] > 0 else { break }
                let take = min(over, widths[i] - plan.widths[i])
                widths[i] -= take
                over -= take
            }
        }
        return Plan(widths: widths, tableWidth: max(widths.reduce(0, +), availableWidth), mode: plan.mode)
    }
}
// END TableColumnPlanner

// BEGIN TableLayoutWidthCache
/// [T-table-layout-true-width] When a table layout computed at one width may be
/// served for another.
///
/// Since [T-table-column-width-plan] cells wrap, so a table's height depends on
/// the width it was planned for: the 4-row reply in the 2026-09-29 overlap
/// report measured ~485pt at the 369pt text column but ~430-447pt at 401pt.
/// SwiftUI sizes every markdown cell at two widths per pass — the inner text
/// column (370) and the cell's outer width (402, see [JitterFix]) — and the
/// old rule reused any cached layout within 25% of the request, so whichever
/// width asked first decided the table for both. The 402 probe won, the
/// cell self-sized ~50pt short and its last lines ran under the next message.
///
/// Now a layout is only reused across typesetter jitter (`tolerance`), and a
/// layout that fit its own width is never reused at a narrower one (its
/// columns would run past the edge). Other widths get their own entry in a
/// small per-table cache, so alternating 370/402 probes stay cheap instead of
/// re-planning on every pass (the HangFix(2026-05-13) concern).
///
/// Pure (CoreGraphics only) so MinisTests/Standalone/TableLayoutWidthTests
/// compiles this block by itself.
enum TableLayoutReuse {
    /// Widths differing by at most this much share a layout.
    static let tolerance: CGFloat = 2

    static func canReuse(layoutWidth: CGFloat, layoutTableWidth: CGFloat, for width: CGFloat) -> Bool {
        guard abs(layoutWidth - width) <= tolerance else { return false }
        let fitItsWidth = layoutTableWidth <= layoutWidth + 0.5
        return !(fitItsWidth && layoutTableWidth > width + 0.5)
    }
}

/// Layouts of one table at a few widths, oldest evicted first.
struct TableWidthCache<Value> {
    struct Entry {
        let width: CGFloat
        let tableWidth: CGFloat
        let value: Value
    }
    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int) { self.capacity = capacity }

    /// The entry closest to `width` that may be reused there.
    func lookup(_ width: CGFloat) -> Value? {
        entries
            .filter { TableLayoutReuse.canReuse(layoutWidth: $0.width, layoutTableWidth: $0.tableWidth, for: width) }
            .min { abs($0.width - width) < abs($1.width - width) }?
            .value
    }

    mutating func store(width: CGFloat, tableWidth: CGFloat, value: Value) {
        entries.removeAll { abs($0.width - width) < 0.5 }
        entries.append(Entry(width: width, tableWidth: tableWidth, value: value))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    mutating func removeAll() { entries.removeAll() }
}
// END TableLayoutWidthCache
