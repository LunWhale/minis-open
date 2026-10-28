//
//  ChatSearchController.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] State of "Search in Chat" for one conversation: the
//  query, the results, the current one, and the work that keeps them fresh.
//
//  Owned by the conversation's AIChatViewModel (`vm.chatSearch`), so the
//  search bar, the message list coordinator and every cell reach the same
//  instance. Kept out of the view model's own @Published state on purpose:
//  typing a query or stepping through results must redraw the search bar and
//  two highlighted texts, not the whole chat page.
//
//  Flow:
//    query edit --250 ms--> snapshot units (main) --> resolve + search (bg)
//      --> results on main: newest match becomes current, list scrolls to it
//    next / previous --> move current (wrapping), list scrolls
//    content change while active --300 ms throttle--> re-search; the current
//      match is kept by identity, nothing scrolls
//    done --> highlights cleared, scroll position left as it is
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine

@MainActor
final class ChatSearchController: ObservableObject {
    enum Notice: Equatable {
        case wrappedToFirst
        case wrappedToLast
    }

    /// The search bar is showing.
    @Published private(set) var isActive = false
    /// What is typed in the field. Writing it schedules a search.
    @Published var query: String = "" {
        didSet {
            guard query != oldValue, isActive, !suppressQueryObserver else { return }
            scheduleSearch(delay: Self.typingDebounce, landOnNewest: true)
        }
    }
    @Published private(set) var matchCount = 0
    @Published private(set) var isTruncated = false
    /// Index into the results of the current match; nil when there is none.
    @Published private(set) var currentIndex: Int?
    /// A search for the CURRENT query has not come back yet.
    @Published private(set) var isSearching = false
    /// Short-lived "wrapped round" message.
    @Published private(set) var notice: Notice?
    /// Bumped to ask the search field to take focus.
    @Published private(set) var focusRequest = 0

    private(set) var matches: [ChatSearchMatch] = []
    let highlights = ChatSearchHighlightCenter()

    /// Scrolls the list to a match. Set by the message list coordinator.
    var onNavigate: ((ChatSearchMatch) -> Void)?
    /// The conversation searched.
    weak var viewModel: AIChatViewModel?

    static let typingDebounce: TimeInterval = 0.25
    static let streamingThrottle: TimeInterval = 0.3

    private var suppressQueryObserver = false
    private var generation = 0
    private var pendingWork: DispatchWorkItem?
    private var searchTask: Task<Void, Never>?
    private var contentSub: AnyCancellable?
    private var contentRefreshScheduled = false
    private var noticeClear: DispatchWorkItem?
    /// Search text of assistant text blocks, keyed by block id. Rebuilt for a
    /// block only when its length or finalised state changes.
    private var textCache: [UUID: ChatSearchTextCacheEntry] = [:]
    private let logger = AppLogger(category: "ChatSearch")

    var currentMatch: ChatSearchMatch? {
        guard let i = currentIndex, matches.indices.contains(i) else { return nil }
        return matches[i]
    }

    var normalizedQuery: String { ChatSearchMatcher.normalizedQuery(query) }

    // MARK: - Open / close

    /// Shows the search bar. A non-empty `prefill` (the text selected when
    /// the user chose "Search in Chat") becomes the query and is searched at
    /// once; otherwise the previous query, if the bar is reopened, is kept
    /// empty and the field takes focus.
    func activate(prefill: String? = nil) {
        let trimmed = prefill.map { ChatSearchMatcher.normalizedQuery($0) } ?? ""
        let wasActive = isActive
        if !wasActive {
            isActive = true
            observeContent()
            logger.info("[ChatSearch] open prefill=\(trimmed.count) chars")
        }
        focusRequest += 1
        if !trimmed.isEmpty, trimmed != query {
            setQuerySilently(trimmed)
            scheduleSearch(delay: 0, landOnNewest: true)
        }
    }

    /// Closes the bar: highlights go, the scroll position stays.
    func deactivate() {
        guard isActive else { return }
        logger.info("[ChatSearch] close query=\(query.count) chars results=\(matches.count)")
        isActive = false
        contentSub = nil
        contentRefreshScheduled = false
        cancelSearch()
        setQuerySilently("")
        apply(result: .empty, query: "", landOnNewest: false)
        notice = nil
    }

    // MARK: - Moving between results

    /// Toward newer messages (down the list); wraps to the first.
    func next() { step(forward: true) }

    /// Toward older messages (up the list); wraps to the last.
    func previous() { step(forward: false) }

    private func step(forward: Bool) {
        guard let moved = ChatSearchNavigation.step(from: currentIndex, count: matches.count, forward: forward) else { return }
        let old = currentMatch
        currentIndex = moved.index
        highlights.setCurrent(from: old, to: currentMatch)
        if moved.wrapped { showNotice(forward ? .wrappedToFirst : .wrappedToLast) }
        navigateToCurrent()
    }

    // MARK: - Searching

    private func setQuerySilently(_ value: String) {
        suppressQueryObserver = true
        query = value
        suppressQueryObserver = false
    }

    private func cancelSearch() {
        pendingWork?.cancel()
        pendingWork = nil
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        isSearching = false
    }

    /// Runs a search after `delay`, replacing any search not yet finished.
    /// `landOnNewest`: a new query moves to the newest match and scrolls; a
    /// refresh after new content keeps the current match and does not scroll.
    private func scheduleSearch(delay: TimeInterval, landOnNewest: Bool) {
        pendingWork?.cancel()
        if landOnNewest {
            // A new query invalidates whatever is in flight right away, so a
            // slow old search can never land after the user typed on.
            searchTask?.cancel()
            generation += 1
            isSearching = !normalizedQuery.isEmpty
        }
        let work = DispatchWorkItem { [weak self] in
            self?.runSearch(landOnNewest: landOnNewest)
        }
        pendingWork = work
        if delay <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func runSearch(landOnNewest: Bool) {
        pendingWork = nil
        let query = normalizedQuery
        guard isActive, !query.isEmpty, let vm = viewModel else {
            cancelSearch()
            apply(result: .empty, query: query, landOnNewest: landOnNewest)
            return
        }
        searchTask?.cancel()
        generation += 1
        let gen = generation
        let started = CFAbsoluteTimeGetCurrent()
        // Strings are copied here, on the main thread; the models are
        // observable objects the UI keeps mutating, so the background task
        // must never read them.
        let pending = ChatSearchUnitBuilder.snapshot(messages: vm.messages)
        searchedSignature = contentSignature()
        let cache = textCache
        let snapshotMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let resolved = ChatSearchUnitBuilder.resolve(pending, cache: cache,
                                                               isCancelled: { Task.isCancelled }),
                  let result = ChatSearchEngine.search(units: resolved.units, query: query,
                                                       isCancelled: { Task.isCancelled }) else { return }
            let unitCount = resolved.units.count
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation, self.isActive else { return }
                self.textCache = resolved.cache
                self.searchTask = nil
                let totalMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
                self.logger.info("[ChatSearch] searched units=\(unitCount) matches=\(result.matches.count)\(result.truncated ? "+" : "") snapshot=\(String(format: "%.1f", snapshotMs))ms total=\(String(format: "%.1f", totalMs))ms landOnNewest=\(landOnNewest)")
                self.apply(result: result, query: query, landOnNewest: landOnNewest)
            }
        }
    }

    private func apply(result: ChatSearchResult, query: String, landOnNewest: Bool) {
        let old = currentMatch
        let oldIndex = currentIndex
        matches = result.matches
        matchCount = result.matches.count
        isTruncated = result.truncated
        isSearching = false
        if landOnNewest {
            currentIndex = ChatSearchNavigation.initialIndex(count: matches.count)
        } else {
            currentIndex = ChatSearchNavigation.relocate(previous: old, previousIndex: oldIndex, in: matches)
        }
        highlights.apply(result: result, query: query, current: currentMatch)
        if landOnNewest {
            navigateToCurrent()
        }
    }

    private func navigateToCurrent() {
        guard let match = currentMatch, let i = currentIndex else { return }
        onNavigate?(match)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement,
                                 argument: AppLocalized("Result \(i + 1) of \(matchCount)"))
        }
    }

    // MARK: - Content changes (streaming)

    /// While the bar is open, new or changed content re-runs the search at
    /// most every 300 ms. The current match is kept by identity and the list
    /// is not scrolled, so streaming never moves what the user is reading.
    private func observeContent() {
        guard let vm = viewModel else { return }
        contentSub = vm.objectWillChange
            .sink { [weak self] _ in self?.contentDidChange() }
    }

    private func contentDidChange() {
        guard isActive, !contentRefreshScheduled, !normalizedQuery.isEmpty else { return }
        contentRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamingThrottle) { [weak self] in
            guard let self else { return }
            self.contentRefreshScheduled = false
            // A query search still pending owns the next result; do not race it.
            guard self.isActive, self.pendingWork == nil, !self.isSearching else { return }
            // The view model also publishes for scroll flags, focus and the
            // like; only a change to what is shown is worth a search.
            let signature = self.contentSignature()
            guard signature != self.searchedSignature else { return }
            self.runSearch(landOnNewest: false)
        }
    }

    /// Signature of the content searched last.
    private var searchedSignature: Int?

    /// Cheap fingerprint of everything the unit snapshot reads: lengths and
    /// ids rather than the text itself, which is enough to notice streaming,
    /// new messages, compaction, errors and expanded cards.
    private func contentSignature() -> Int {
        guard let vm = viewModel else { return 0 }
        var h = Hasher()
        h.combine(vm.messages.count)
        for m in vm.messages {
            h.combine(m.id)
            h.combine(m.content.utf16.count)
            h.combine(m.error?.utf16.count ?? -1)
            h.combine(m.attachments.count)
            h.combine(m.blocks.count)
            for b in m.blocks {
                h.combine(b.id)
                h.combine(b.content.utf16.count)
                h.combine(b.toolSummary?.utf16.count ?? -1)
                h.combine(b.isThinkingExpanded)
                h.combine(b.cachedMarkdown != nil || b.cachedAttributedString != nil)
            }
        }
        return h.finalize()
    }

    // MARK: - Notices

    private func showNotice(_ n: Notice) {
        notice = n
        noticeClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: Self.noticeText(n))
        }
    }

    static func noticeText(_ n: Notice) -> String {
        switch n {
        case .wrappedToFirst: return AppLocalized("Wrapped to the first result")
        case .wrappedToLast: return AppLocalized("Wrapped to the last result")
        }
    }
}
