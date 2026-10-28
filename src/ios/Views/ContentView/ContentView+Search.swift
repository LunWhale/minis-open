//
//  ContentView+Search.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, search: debounced session search (titles, then message
//  content), dismissing it, and focusing the field (Cmd-F).
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    // MARK: - Search Bar

    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchMatchedIds = nil
            searchMatchSnippets = [:]
            searchMatchedFolderIds = []
            searchFolderPages = [:]
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            let results = await ChatStore.shared.searchSessions(query: query)
            if !Task.isCancelled {
                // [T-search-folder-expand] A folder whose name matches brings
                // all its members along — the folder is the reason they match.
                // [T-search-multi-keyword] ... for any of the keywords, the
                // same OR rule the sessions are matched by.
                let terms = SearchKeywords.terms(query)
                let folderHits = Set(folders.filter {
                    SearchKeywords.firstHit(in: $0.name, terms: terms) != nil
                }.map(\.id))
                var ids = Set(results.map(\.session.id))
                if !folderHits.isEmpty {
                    ids.formUnion(sessions.filter { $0.folderId.map(folderHits.contains) == true }.map(\.id))
                }
                searchMatchedFolderIds = folderHits
                searchFolderPages = [:]
                searchMatchedIds = ids
                // [T-search-hit-line] sessionId → the line that holds the
                // query, for every session with a message hit — including
                // those whose title matched too, so the row shows where in the
                // conversation the keyword is. Title-only matches keep the
                // normal preview under the highlighted title.
                var snippets: [String: String] = [:]
                for r in results {
                    if let snip = r.matchSnippet, !snip.isEmpty {
                        snippets[r.session.id] = snip
                    }
                }
                searchMatchSnippets = snippets
            }
        }
    }

    func dismissSearch() {
        withAnimation(.easeInOut(duration: 0.2)) { showSearchBar = false }
        searchText = ""
        searchMatchedIds = nil
        searchMatchSnippets = [:]
        searchMatchedFolderIds = []
        searchFolderPages = [:]
        searchTask?.cancel()
        searchFocused = false
    }

    /// [T-ios-search-focus-sticky] Auto-exit the search bar when the user
    /// navigates into a session (or starts a new chat) WITHOUT having typed an
    /// actual query. Rationale: tapping the search field then tapping a chat
    /// without searching used to leave the field revealed + focused on return,
    /// forcing a manual tap on the ✕. If there IS a non-blank query, we keep the
    /// search state intact so the user returns to their results. Whitespace-only
    /// text counts as empty. No-op when the search bar isn't shown.
    func dismissSearchIfEmptyOnNavigate() {
        guard showSearchBar else { return }
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissSearch()
    }

    /// Reveal the search bar (if hidden) and focus its text field. Bound to the
    /// hardware ⌘F shortcut while the session list is on screen. Focusing inside
    /// the reveal animation is unreliable, so set focus on the next runloop tick
    /// once the field exists in the view tree.
    func focusSearch() {
        if !showSearchBar {
            withAnimation(.easeInOut(duration: 0.2)) { showSearchBar = true }
        }
        DispatchQueue.main.async { searchFocused = true }
    }
}
