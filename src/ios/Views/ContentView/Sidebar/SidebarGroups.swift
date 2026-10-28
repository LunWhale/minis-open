//
//  SidebarGroups.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The sidebar's data model: SidebarGroup (one date bucket or folder section,
//  ids only so the list diffs cheaply), FolderGlyph, and the memo key / box
//  that lets an unchanged session list reuse the previous grouping.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

/// One sidebar section: a date bucket (folderId == nil) or a folder section.
/// Equatable and cheap on purpose — the sidebar ForEach diffs this on every
/// transaction flush, so it must stay a [String] + small scalars, never a
/// [ChatSession] ([T-ios-session-list-equatable-jank]).
struct SidebarGroup: Equatable, Identifiable {
    /// [T-ios-sidebar-foreach-index-id] Stable identity for the section ForEach.
    ///
    /// The list was keyed by `\.offset` — the array INDEX. Group order is not
    /// stable: `groupedSessionIDs` emits "Pinned" only when a pinned session
    /// exists, folder groups sort by pin state and newest member, and date
    /// buckets appear and disappear as sessions age. Pinning one chat, or a
    /// background sync bumping a folder's newest `updatedAt`, renumbers every
    /// group after it, so SwiftUI sees the sections it already has under new
    /// identities and rebuilds them as remove+insert rather than an update.
    ///
    /// That is the churn the 2026-08-26 crash lands in: EXC_BAD_ACCESS in
    /// `assignWithTake for ForEachState.LazyEdits` inside a graph transaction,
    /// i.e. a double release while ForEach applied its edit list. The
    /// folderId/label pair is what actually names a group, and it survives
    /// reordering — an update stays an update.
    var id: String { folderId.map { "f:\($0)" } ?? "b:\(label)" }

    var label: String            // English key for date buckets; folder name otherwise

    /// Member session ids, in display order. Emptied when the folder is
    /// collapsed.
    ///
    /// [T-ios-foreach-lazyedits-dup-guard] DEFENSIVE: writes are de-duplicated,
    /// first occurrence wins. This is NOT a diagnosed fix — see the property's
    /// full rationale on `dedupedPreservingOrder` below.
    ///
    /// The invariant lives here, on the property, rather than at the two
    /// construction sites, so a third site added later cannot bypass it and so
    /// the `g.ids = []` collapse write is covered by the same rule.
    var ids: [String] {
        get { _ids }
        set { _ids = Self.dedupedPreservingOrder(newValue) }
    }
    private var _ids: [String] = []

    /// First occurrence wins, order otherwise untouched.
    ///
    /// Why this guard exists: the sidebar renders members with
    /// `ForEach(group.ids, id: \.self)`, i.e. keyed by the session id itself.
    /// A repeated id would hand SwiftUI two rows with the SAME identity inside
    /// one ForEach, which is a documented trigger for the double release this
    /// app has already crashed on twice —
    /// `assignWithTake for ForEachState.LazyEdits` →
    /// `_swift_release_dealloc`, EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE at
    /// 0x24 (2026-08-26 on iOS 26.6.1, again 2026-09-17 on iOS 27.0, both
    /// iPhone18,1).
    ///
    /// Honest status: an audit on 2026-09-17 could NOT find a way to reach a
    /// duplicate. `groupedSessions` partitions with `continue`/`else if`,
    /// `filteredSessions` is a filter, both writes to `sessions` are
    /// @MainActor from `listSessions()`, and ChatStore's incremental
    /// `patchedSessionList` appends at most one row per cached entry. The
    /// crashing stack carries no app frames at all (frames 0-39 are
    /// libswiftCore / SwiftUICore / AttributeGraph / UIKitCore), so the .ips
    /// cannot name the offending view either. This is therefore a cheap
    /// backstop against one specific, known-fatal input shape — not a claim
    /// about the cause.
    ///
    /// If the crash STOPS after this ships, duplicates were reachable and the
    /// real bug is whatever produced them (a merge/restore path appending
    /// without deduping is the likeliest candidate); the `#if DEBUG` report in
    /// `computeGroupedSessionIDs` is what would name it. If the crash
    /// CONTINUES, duplicate identity was not the trigger and this guard should
    /// stay only as belt-and-braces while the search moves elsewhere.
    /// Explicit memberwise-equivalent init. Needed because the private `_ids`
    /// backing store suppresses the synthesised one, and required anyway so
    /// every construction path goes through the de-duplicating setter.
    init(label: String, ids: [String], folderId: String? = nil) {
        self.label = label
        self.folderId = folderId
        self.ids = ids          // via the setter — dedup applies here too
    }

    static func dedupedPreservingOrder(_ input: [String]) -> [String] {
        // Fast path: the overwhelmingly common case is already unique, and
        // this runs inside a hot AttributeGraph aggregation pass.
        var seen = Set<String>(minimumCapacity: input.count)
        var hasDuplicate = false
        for id in input where !seen.insert(id).inserted {
            hasDuplicate = true
            break
        }
        guard hasDuplicate else { return input }

        seen.removeAll(keepingCapacity: true)
        var out: [String] = []
        out.reserveCapacity(input.count)
        for id in input where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
    var folderId: String? = nil
    var totalCount: Int = 0      // member count incl. hidden-by-collapse rows
    var glyphs: [FolderGlyph] = []   // top-3 distinct member category glyphs
    var anyUnread = false
    var anyActive = false
    var anyPaused = false
    var isCollapsed = false
    var isFolderPinned = false
    var latestDate: Date? = nil      // newest member updatedAt (nil = empty folder)
    var summaryTitle: String? = nil  // newest member's title, for the subtitle line
    /// [T-folder-summary-lock] The member `summaryTitle` came from, so the
    /// line can be blurred while that session is Face ID locked.
    var summarySessionId: String? = nil
    /// True on the FIRST folder group only: renders the "Groups" divider
    /// label (styled like the date-bucket headers) above the folder block.
    var showsGroupsHeader = false
    /// [T-search-folder-pages] Matches of a search-expanded folder not yet
    /// shown; > 0 renders the "Show more" row below `ids`.
    var hiddenMatchCount = 0

    /// The member row that closes the folder card (bottom segment). With a
    /// "Show more" row below, that row closes it instead.
    func isLastMemberRow(_ id: String) -> Bool { hiddenMatchCount == 0 && id == ids.last }
}

/// A single composed-icon glyph. Small struct instead of a tuple because
/// tuples can't satisfy Equatable inside SidebarGroup's array.
struct FolderGlyph: Equatable {
    var systemName: String
    var color: Color
}

/// Projection of EXACTLY the per-session fields the sidebar grouping reads —
/// the memo key's session component. Deliberately excludes `lastMessage`
/// (the expensive field at the heart of [T-ios-session-list-equatable-jank]);
/// comparing N of these is a handful of short-string compares per element,
/// far cheaper than re-running the grouping.
struct SidebarSessionKey: Equatable {
    let id: String
    let updatedAt: Date
    let pinnedAt: Date?
    let isPinned: Bool
    let folderId: String?
    let category: String?
    let title: String?
}

/// Every input `groupedSessionIDs` depends on. Compared (not hashed) so a
/// hit is provably identical input — no collision risk. The badge/activity
/// sets are IN the key on purpose: they're both the aggregation inputs and
/// the invalidation signal (a badge aging past the 24h window changes the
/// freshly-built set, which misses the memo — same "next ambient refresh"
/// timing the unmemoized per-member query had). `dayStamp` invalidates the
/// date buckets when the calendar day flips.
struct SidebarGroupsMemoKey: Equatable {
    let sessions: [SidebarSessionKey]
    let folders: [ChatFolder]
    let collapsedFolderIds: Set<String>
    let pendingDraftId: String?
    let pendingDraftFolderId: String?
    let isSearching: Bool
    let searchResultsActive: Bool
    let searchMatchedFolderIds: Set<String>
    let searchFolderPages: [String: Int]
    let unreadIds: Set<String>
    let freshCornerIds: Set<String>
    let activeIds: Set<String>
    let dayStamp: Date
}

/// Reference-type memo box held in @State: mutating its contents during a
/// body evaluation is legal (no observed value changes, so no re-entrant
/// invalidation), and identity survives ContentView struct re-inits. A memo
/// hit returns the SAME [SidebarGroup] array instance, so the downstream
/// ForEach diff takes the identical-storage fast path instead of comparing
/// element-wise.
final class SidebarGroupsMemo {
    var key: SidebarGroupsMemoKey?
    var groups: [SidebarGroup] = []
}
