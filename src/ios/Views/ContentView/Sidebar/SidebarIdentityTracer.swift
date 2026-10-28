//
//  SidebarIdentityTracer.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  DEBUG-only: logs the sidebar ForEach identity sequence when it changes, to
//  attribute ForEach LazyEdits crashes. Instrumentation only.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - [T-ios-foreach-lazyedits-dup-guard] Sidebar identity tracer

#if DEBUG
/// Records the sidebar's ForEach IDENTITY SEQUENCE on every body evaluation, so
/// the last line before a crash is the actual state SwiftUI was diffing.
///
/// Why this exists: the `ForEachState.LazyEdits` crash
/// (EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE at 0x24, CODESIGNING/Invalid Page)
/// has been seen three times — 2026-08-26, and twice on 2026-09-17 — and its
/// stack carries **zero app frames**: frames 0-39 are libswiftCore /
/// SwiftUICore / AttributeGraph / UIKitCore, with only `MinisApp.$main()` and
/// `main` at the bottom. A .ips therefore cannot name the offending view, and
/// the one structural guess already tried (duplicate session ids) was falsified
/// when the crash recurred on a build that contained the dedup guard.
///
/// So instead of guessing again, record what ForEach was actually handed. A
/// LazyEdits fault is an edit-list fault: it happens while SwiftUI applies
/// inserts/removes/moves computed from the identity sequence. Logging that
/// sequence's TRANSITIONS gives the crash a cause to point at.
///
/// Deliberately DEBUG-only and transition-gated:
///  * the sidebar body re-evaluates on every activity tick and, in the
///    2026-09-17 report, under a display-link driven render — logging every
///    pass would be both a flood and a measurable drag on the very path being
///    diagnosed;
///  * it logs only when the identity sequence CHANGES, which is exactly when an
///    edit list is produced, i.e. the only passes that can crash this way.
///
/// This is instrumentation, not a fix. It must not alter what the body returns:
/// `note(...)` is a plain function called from the `let groups = …` binding
/// site, and its result is discarded — no extra view is inserted into the
/// ViewBuilder, so the view tree's shape is unchanged.
enum SidebarIdentityTracer {
    private static let logger = AppLogger(category: "SidebarIdentity")
    /// Per-list previous state, keyed by call site ("sidebar" / "selection").
    nonisolated(unsafe) private static var previous: [String: (sections: [String], rows: [String])] = [:]

    /// - Parameter site: which of the two sidebar lists is reporting.
    static func note(_ groups: [SidebarGroup], site: String) {
        let sections = groups.map(\.id)
        // Flattened row identities, in the order ForEach receives them. The
        // inner `ForEach(group.ids, id: \.self)` keys rows by the session id,
        // so this IS the identity sequence SwiftUI diffs.
        let rows = groups.flatMap(\.ids)

        guard let old = previous[site] else {
            previous[site] = (sections, rows)
            logger.debug("[\(site)] first pass — sections=\(sections.count) rows=\(rows.count)")
            return
        }
        guard old.sections != sections || old.rows != rows else { return }
        previous[site] = (sections, rows)

        // Describe the transition the way an edit list would: what left, what
        // arrived, and whether anything merely moved. A pure reorder is the
        // shape that historically crashed here (c86add406 was an index-keyed
        // reorder), so it is called out explicitly.
        let oldSectionSet = Set(old.sections), newSectionSet = Set(sections)
        let oldRowSet = Set(old.rows), newRowSet = Set(rows)
        let sectionsRemoved = oldSectionSet.subtracting(newSectionSet)
        let sectionsInserted = newSectionSet.subtracting(oldSectionSet)
        let rowsRemoved = oldRowSet.subtracting(newRowSet)
        let rowsInserted = newRowSet.subtracting(oldRowSet)
        let sectionsReordered = sectionsRemoved.isEmpty && sectionsInserted.isEmpty
            && old.sections != sections
        let rowsReordered = rowsRemoved.isEmpty && rowsInserted.isEmpty && old.rows != rows

        func brief(_ ids: Set<String>) -> String {
            ids.isEmpty ? "-" : ids.prefix(6).map { String($0.prefix(8)) }.joined(separator: ",")
                + (ids.count > 6 ? "+\(ids.count - 6)" : "")
        }

        logger.debug(
            "[\(site)] sections \(old.sections.count)->\(sections.count)"
            + " (-\(brief(sectionsRemoved)) +\(brief(sectionsInserted))"
            + "\(sectionsReordered ? " REORDER" : ""))"
            + " rows \(old.rows.count)->\(rows.count)"
            + " (-\(brief(rowsRemoved)) +\(brief(rowsInserted))"
            + "\(rowsReordered ? " REORDER" : ""))"
            + " sectionOrder=[\(sections.map { String($0.prefix(10)) }.joined(separator: "|"))]")

        // A duplicate here would mean SidebarGroup.ids' guard was bypassed —
        // impossible through the setter, but if it ever shows up it is the
        // whole answer, so check rather than assume.
        if rows.count != newRowSet.count {
            logger.error(
                "[\(site)] DUPLICATE ROW IDENTITY reached ForEach — "
                + "rows=\(rows.count) unique=\(newRowSet.count). "
                + "SidebarGroup.ids' dedup was bypassed; this is the crash shape.")
        }
    }
}
#endif

// MARK: - [T-crash-breadcrumbs] Release-safe structure breadcrumb

/// The Release-safe sibling of SidebarIdentityTracer: when a sidebar list's
/// SECTION sequence or ROW COUNT changes, one crash breadcrumb with the kind
/// (reorder / regroup = sections added or removed / rows) and the counts - no ids, no
/// titles. The 2026-10-01 main-thread SwiftUI crash came ~105 ms after a
/// 15-section REORDER of this list, which only the DEBUG tracer could show.
///
/// Cheap enough for every body pass: it compares the section-id array (one
/// entry per group) and a row count, never the 2,000+ row ids; a reorder of
/// rows inside a section is therefore not reported. Called from the same
/// `let _ =` binding as the tracer, so the ViewBuilder's shape is unchanged.
enum SidebarStructureCrumb {
    nonisolated(unsafe) private static var previous: [String: (sections: [String], rows: Int)] = [:]

    static func note(_ groups: [SidebarGroup], site: String) {
        let sections = groups.map(\.id)
        let rows = groups.reduce(0) { $0 + $1.ids.count }
        guard let old = previous[site] else {
            previous[site] = (sections, rows)
            return
        }
        guard old.sections != sections || old.rows != rows else { return }
        previous[site] = (sections, rows)
        let kind: String
        if old.sections != sections {
            kind = Set(old.sections) == Set(sections) ? "reorder" : "regroup"
        } else {
            kind = "rows"
        }
        CrashBreadcrumbs.record("sidebar",
                                detail: "\(site) \(kind) sections \(old.sections.count)->\(sections.count) rows \(old.rows)->\(rows)")
    }
}
